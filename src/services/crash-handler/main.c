#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef SINGULARITY_CRASH_CONFIG_FILE
#define SINGULARITY_CRASH_CONFIG_FILE "/etc/xdg/singularity/crash-reporter.conf"
#endif

#ifndef SINGULARITY_CRASH_SPOOL_DIR
#define SINGULARITY_CRASH_SPOOL_DIR "/var/lib/singularity/crashes"
#endif

struct config {
	char spool_dir[PATH_MAX];
	int enabled;
	long min_uid;
	int keep_core;
	long max_core_mb;
	long max_reports;
	long max_cores;
};

struct entry {
	char name[256];
};

static void
trim(char *s)
{
	size_t len = strlen(s);
	while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ' || s[len - 1] == '\t')) {
		s[--len] = '\0';
	}
	size_t start = 0;
	while (s[start] == ' ' || s[start] == '\t') {
		start++;
	}
	if (start > 0) {
		memmove(s, s + start, strlen(s + start) + 1);
	}
}

static int
parse_bool(const char *value)
{
	return strcasecmp(value, "true") == 0 || strcmp(value, "1") == 0 || strcasecmp(value, "yes") == 0;
}

static const char *
config_path(void)
{
	const char *override = getenv("SINGULARITY_CRASH_CONFIG");
	if (override && *override && geteuid() != 0 && getuid() == geteuid()) {
		return override;
	}
	return SINGULARITY_CRASH_CONFIG_FILE;
}

static void
load_config(struct config *cfg)
{
	snprintf(cfg->spool_dir, sizeof(cfg->spool_dir), "%s", SINGULARITY_CRASH_SPOOL_DIR);
	cfg->enabled = 1;
	cfg->min_uid = 1000;
	cfg->keep_core = 1;
	cfg->max_core_mb = 256;
	cfg->max_reports = 20;
	cfg->max_cores = 3;

	FILE *f = fopen(config_path(), "re");
	if (!f) {
		return;
	}
	char line[1024];
	char group[128] = "";
	while (fgets(line, sizeof(line), f)) {
		trim(line);
		if (line[0] == '\0' || line[0] == '#' || line[0] == ';') {
			continue;
		}
		if (line[0] == '[') {
			char *end = strchr(line, ']');
			if (end) {
				*end = '\0';
				snprintf(group, sizeof(group), "%.127s", line + 1);
			}
			continue;
		}
		char *eq = strchr(line, '=');
		if (!eq) {
			continue;
		}
		*eq = '\0';
		char *key = line;
		char *value = eq + 1;
		trim(key);
		trim(value);
		if (strcmp(group, "Crash Reporter") == 0 && strcmp(key, "SpoolDir") == 0 && value[0] == '/') {
			snprintf(cfg->spool_dir, sizeof(cfg->spool_dir), "%s", value);
		} else if (strcmp(group, "Handler") == 0) {
			if (strcmp(key, "Enabled") == 0) {
				cfg->enabled = parse_bool(value);
			} else if (strcmp(key, "MinUid") == 0) {
				cfg->min_uid = strtol(value, NULL, 10);
			} else if (strcmp(key, "KeepCore") == 0) {
				cfg->keep_core = parse_bool(value);
			} else if (strcmp(key, "MaxCoreSizeMB") == 0) {
				cfg->max_core_mb = strtol(value, NULL, 10);
			} else if (strcmp(key, "MaxReports") == 0) {
				cfg->max_reports = strtol(value, NULL, 10);
			} else if (strcmp(key, "MaxCores") == 0) {
				cfg->max_cores = strtol(value, NULL, 10);
			}
		}
	}
	fclose(f);
	if (cfg->max_reports < 1) {
		cfg->max_reports = 1;
	}
	if (cfg->max_cores < 0) {
		cfg->max_cores = 0;
	}
	if (cfg->max_core_mb < 0) {
		cfg->max_core_mb = 0;
	}
}

static int
parse_long(const char *s, long *out)
{
	if (!s || !*s) {
		return -1;
	}
	char *end = NULL;
	errno = 0;
	long v = strtol(s, &end, 10);
	if (errno != 0 || *end != '\0') {
		return -1;
	}
	*out = v;
	return 0;
}

static void
sanitize(char *s)
{
	for (; *s; s++) {
		unsigned char c = (unsigned char)*s;
		if (c < 0x20 || c == 0x7f || c == '\\') {
			*s = '?';
		}
	}
}

static ssize_t
read_proc(long pid, const char *what, char *buf, size_t size)
{
	char path[64];
	snprintf(path, sizeof(path), "/proc/%ld/%s", pid, what);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		return -1;
	}
	size_t total = 0;
	while (total < size - 1) {
		ssize_t n = read(fd, buf + total, size - 1 - total);
		if (n <= 0) {
			break;
		}
		total += (size_t)n;
	}
	close(fd);
	buf[total] = '\0';
	return (ssize_t)total;
}

static void
read_executable(long pid, char *out, size_t size)
{
	char path[64];
	snprintf(path, sizeof(path), "/proc/%ld/exe", pid);
	ssize_t n = readlink(path, out, size - 1);
	if (n < 0) {
		out[0] = '\0';
		return;
	}
	out[n] = '\0';
	const char *deleted = " (deleted)";
	size_t len = strlen(out);
	size_t dlen = strlen(deleted);
	if (len > dlen && strcmp(out + len - dlen, deleted) == 0) {
		out[len - dlen] = '\0';
	}
	sanitize(out);
}

static void
read_cmdline(long pid, char *out, size_t size)
{
	ssize_t n = read_proc(pid, "cmdline", out, size);
	if (n <= 0) {
		out[0] = '\0';
		return;
	}
	for (ssize_t i = 0; i < n; i++) {
		if (out[i] == '\0') {
			out[i] = ' ';
		}
	}
	out[n] = '\0';
	trim(out);
	sanitize(out);
}

static void
read_desktop_file(long pid, char *out, size_t size)
{
	static char env[65536];
	out[0] = '\0';
	ssize_t n = read_proc(pid, "environ", env, sizeof(env));
	if (n <= 0) {
		return;
	}
	const char *key = "GIO_LAUNCHED_DESKTOP_FILE=";
	size_t klen = strlen(key);
	for (ssize_t i = 0; i < n;) {
		const char *item = env + i;
		size_t len = strnlen(item, (size_t)(n - i));
		if (len > klen && strncmp(item, key, klen) == 0) {
			snprintf(out, size, "%s", item + klen);
			sanitize(out);
			return;
		}
		i += (ssize_t)len + 1;
	}
}

static int
open_user_dir(const struct config *cfg, uid_t uid, gid_t gid)
{
	if (mkdir(cfg->spool_dir, 0755) < 0 && errno != EEXIST) {
		return -1;
	}
	int root = open(cfg->spool_dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (root < 0) {
		return -1;
	}
	char name[32];
	snprintf(name, sizeof(name), "%u", (unsigned)uid);
	if (mkdirat(root, name, 0700) < 0 && errno != EEXIST) {
		close(root);
		return -1;
	}
	int dir = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	close(root);
	if (dir < 0) {
		return -1;
	}
	struct stat st;
	if (fstat(dir, &st) < 0 || !S_ISDIR(st.st_mode)) {
		close(dir);
		return -1;
	}
	if (geteuid() == 0) {
		if (st.st_uid != uid && fchown(dir, uid, gid) < 0) {
			close(dir);
			return -1;
		}
		fchmod(dir, 0700);
	} else if (st.st_uid != geteuid()) {
		close(dir);
		return -1;
	}
	return dir;
}

static int
compare_entries(const void *a, const void *b)
{
	return strcmp(((const struct entry *)a)->name, ((const struct entry *)b)->name);
}

static void
prune(int dir, const char *suffix, long keep)
{
	int fd = dup(dir);
	if (fd < 0) {
		return;
	}
	DIR *d = fdopendir(fd);
	if (!d) {
		close(fd);
		return;
	}
	struct entry *list = NULL;
	size_t count = 0;
	size_t cap = 0;
	struct dirent *de;
	size_t slen = strlen(suffix);
	while ((de = readdir(d)) != NULL) {
		size_t len = strlen(de->d_name);
		if (len <= slen || strcmp(de->d_name + len - slen, suffix) != 0 || len >= sizeof(list->name)) {
			continue;
		}
		if (count == cap) {
			size_t ncap = cap ? cap * 2 : 32;
			struct entry *grown = realloc(list, ncap * sizeof(*list));
			if (!grown) {
				break;
			}
			list = grown;
			cap = ncap;
		}
		snprintf(list[count++].name, sizeof(list->name), "%s", de->d_name);
	}
	closedir(d);
	if (count > (size_t)keep) {
		qsort(list, count, sizeof(*list), compare_entries);
		for (size_t i = 0; i < count - (size_t)keep; i++) {
			unlinkat(dir, list[i].name, 0);
		}
	}
	free(list);
}

static int
write_core(int dir, const char *name, uid_t uid, gid_t gid, long max_bytes)
{
	char tmp[300];
	snprintf(tmp, sizeof(tmp), "%s.tmp", name);
	int fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd < 0) {
		return -1;
	}
	char buf[65536];
	long total = 0;
	int ok = 1;
	for (;;) {
		ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
		if (n < 0) {
			if (errno == EINTR) {
				continue;
			}
			ok = 0;
			break;
		}
		if (n == 0) {
			break;
		}
		total += n;
		if (total > max_bytes) {
			ok = 0;
			break;
		}
		ssize_t off = 0;
		while (off < n) {
			ssize_t w = write(fd, buf + off, (size_t)(n - off));
			if (w < 0) {
				if (errno == EINTR) {
					continue;
				}
				ok = 0;
				break;
			}
			off += w;
		}
		if (!ok) {
			break;
		}
	}
	if (ok && total > 0 && geteuid() == 0 && fchown(fd, uid, gid) < 0) {
		ok = 0;
	}
	close(fd);
	if (!ok || total == 0) {
		unlinkat(dir, tmp, 0);
		return -1;
	}
	if (renameat(dir, tmp, dir, name) < 0) {
		unlinkat(dir, tmp, 0);
		return -1;
	}
	return 0;
}

static int
write_report(int dir, const char *name, const char *content, uid_t uid, gid_t gid)
{
	char tmp[300];
	snprintf(tmp, sizeof(tmp), "%s.tmp", name);
	int fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd < 0) {
		return -1;
	}
	size_t len = strlen(content);
	size_t off = 0;
	int ok = 1;
	while (off < len) {
		ssize_t w = write(fd, content + off, len - off);
		if (w < 0) {
			if (errno == EINTR) {
				continue;
			}
			ok = 0;
			break;
		}
		off += (size_t)w;
	}
	if (ok && geteuid() == 0 && fchown(fd, uid, gid) < 0) {
		ok = 0;
	}
	close(fd);
	if (!ok || renameat(dir, tmp, dir, name) < 0) {
		unlinkat(dir, tmp, 0);
		return -1;
	}
	return 0;
}

static void
drain_stdin(void)
{
	char buf[65536];
	while (read(STDIN_FILENO, buf, sizeof(buf)) > 0) {
	}
}

int
main(int argc, char **argv)
{
	if (argc < 7) {
		fprintf(stderr, "usage: %s PID UID GID SIGNAL TIME DUMPABLE [COMM]\n", argv[0]);
		return 2;
	}
	long pid, uid_l, gid_l, sig, when, dumpable;
	if (parse_long(argv[1], &pid) < 0 || parse_long(argv[2], &uid_l) < 0 || parse_long(argv[3], &gid_l) < 0 ||
			parse_long(argv[4], &sig) < 0 || parse_long(argv[5], &when) < 0 ||
			parse_long(argv[6], &dumpable) < 0 || pid <= 0 || uid_l < 0 || gid_l < 0) {
		fprintf(stderr, "singularity-crash-handler: invalid arguments\n");
		return 2;
	}
	uid_t uid = (uid_t)uid_l;
	gid_t gid = (gid_t)gid_l;

	struct config cfg;
	load_config(&cfg);
	if (!cfg.enabled || uid_l < cfg.min_uid) {
		drain_stdin();
		return 0;
	}
	if (geteuid() != 0 && geteuid() != uid) {
		drain_stdin();
		return 1;
	}

	umask(077);
	int dir = open_user_dir(&cfg, uid, gid);
	if (dir < 0) {
		drain_stdin();
		return 1;
	}

	char exe[PATH_MAX];
	char cmdline[2048];
	char desktop[PATH_MAX];
	read_executable(pid, exe, sizeof(exe));
	read_cmdline(pid, cmdline, sizeof(cmdline));
	read_desktop_file(pid, desktop, sizeof(desktop));
	if (exe[0] == '\0' && argc > 7) {
		snprintf(exe, sizeof(exe), "%s", argv[7]);
		sanitize(exe);
	}

	char base[96];
	snprintf(base, sizeof(base), "%010ld-%ld", when, pid);
	char core_name[128] = "";
	prune(dir, ".crash", cfg.max_reports - 1);
	if (cfg.keep_core && cfg.max_cores > 0 && dumpable == 1 && cfg.max_core_mb > 0) {
		char candidate[128];
		snprintf(candidate, sizeof(candidate), "%s.core", base);
		if (write_core(dir, candidate, uid, gid, cfg.max_core_mb * 1024L * 1024L) == 0) {
			snprintf(core_name, sizeof(core_name), "%s", candidate);
			prune(dir, ".core", cfg.max_cores);
		} else {
			drain_stdin();
		}
	} else {
		drain_stdin();
	}

	static char report[8192];
	snprintf(report, sizeof(report),
		"[Crash]\n"
		"Source=handler\n"
		"Pid=%ld\n"
		"Uid=%ld\n"
		"Signal=%ld\n"
		"Time=%ld\n"
		"Executable=%s\n"
		"CommandLine=%s\n"
		"DesktopFile=%s\n"
		"Core=%s\n",
		pid, uid_l, sig, when, exe, cmdline, desktop, core_name);
	char report_name[128];
	snprintf(report_name, sizeof(report_name), "%s.crash", base);
	int rc = write_report(dir, report_name, report, uid, gid);
	close(dir);
	return rc == 0 ? 0 : 1;
}
