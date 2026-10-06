#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef FIREWALL_STATE_FILE
#define FIREWALL_STATE_FILE "/var/lib/singularity/firewall.state"
#endif

#define MAX_RULES 64
#define TABLE "inet singularity_firewall"

struct rule {
	char id[33];
	int public_too;
	char ports[256];
	char label[65];
};

struct state {
	int enabled;
	int public_profile;
	int count;
	struct rule rules[MAX_RULES];
};

static const char *state_file = FIREWALL_STATE_FILE;
static const char *nft_path = NULL;
static int dry_run = 0;

static int
overrides_allowed(void)
{
	return getuid() == geteuid() && getenv("PKEXEC_UID") == NULL;
}

static int
valid_id(const char *id)
{
	size_t len = strlen(id);
	if (len == 0 || len > 32) {
		return 0;
	}
	for (size_t i = 0; i < len; i++) {
		char c = id[i];
		if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) {
			return 0;
		}
	}
	return 1;
}

static int
valid_label(const char *label)
{
	size_t len = strlen(label);
	if (len == 0 || len > 64) {
		return 0;
	}
	for (size_t i = 0; i < len; i++) {
		unsigned char c = (unsigned char) label[i];
		if (c < 0x20 || c == '"' || c == '\\' || c == 0x7f) {
			return 0;
		}
	}
	return 1;
}

static int
valid_number(const char *s, size_t len, long *out)
{
	if (len == 0 || len > 5) {
		return 0;
	}
	long v = 0;
	for (size_t i = 0; i < len; i++) {
		if (s[i] < '0' || s[i] > '9') {
			return 0;
		}
		v = v * 10 + (s[i] - '0');
	}
	if (v < 1 || v > 65535) {
		return 0;
	}
	*out = v;
	return 1;
}

static int
valid_port_item(const char *item, size_t len)
{
	const char *slash = memchr(item, '/', len);
	if (slash == NULL) {
		return 0;
	}
	size_t plen = (size_t) (slash - item);
	size_t proto_len = len - plen - 1;
	if (!((proto_len == 3 && strncmp(slash + 1, "tcp", 3) == 0) ||
			(proto_len == 3 && strncmp(slash + 1, "udp", 3) == 0))) {
		return 0;
	}
	const char *dash = memchr(item, '-', plen);
	long a, b;
	if (dash == NULL) {
		return valid_number(item, plen, &a);
	}
	return valid_number(item, (size_t) (dash - item), &a) &&
		valid_number(dash + 1, plen - (size_t) (dash - item) - 1, &b) && a < b;
}

static int
valid_ports(const char *ports)
{
	size_t len = strlen(ports);
	if (len == 0 || len > 255) {
		return 0;
	}
	const char *start = ports;
	for (;;) {
		const char *comma = strchr(start, ',');
		size_t item_len = comma ? (size_t) (comma - start) : strlen(start);
		if (!valid_port_item(start, item_len)) {
			return 0;
		}
		if (comma == NULL) {
			return 1;
		}
		start = comma + 1;
	}
}

static int
load_state(struct state *st)
{
	memset(st, 0, sizeof(*st));
	FILE *f = fopen(state_file, "re");
	if (f == NULL) {
		return errno == ENOENT ? 0 : -1;
	}
	char line[512];
	while (fgets(line, sizeof(line), f) != NULL) {
		line[strcspn(line, "\n")] = '\0';
		if (strncmp(line, "enabled ", 8) == 0) {
			st->enabled = strcmp(line + 8, "1") == 0;
		} else if (strncmp(line, "profile ", 8) == 0) {
			st->public_profile = strcmp(line + 8, "public") == 0;
		} else if (strncmp(line, "rule ", 5) == 0 && st->count < MAX_RULES) {
			struct rule r;
			char *save = NULL;
			char *id = strtok_r(line + 5, " ", &save);
			char *pub = strtok_r(NULL, " ", &save);
			char *ports = strtok_r(NULL, " ", &save);
			char *label = save;
			if (id == NULL || pub == NULL || ports == NULL || label == NULL || !valid_id(id) ||
					!valid_ports(ports) || !valid_label(label)) {
				continue;
			}
			snprintf(r.id, sizeof(r.id), "%s", id);
			r.public_too = strcmp(pub, "1") == 0;
			snprintf(r.ports, sizeof(r.ports), "%s", ports);
			snprintf(r.label, sizeof(r.label), "%s", label);
			st->rules[st->count++] = r;
		}
	}
	fclose(f);
	return 0;
}

static int
save_state(const struct state *st)
{
	char tmp[4096];
	snprintf(tmp, sizeof(tmp), "%s.tmp", state_file);
	char dir[4096];
	snprintf(dir, sizeof(dir), "%s", state_file);
	char *slash = strrchr(dir, '/');
	if (slash != NULL && slash != dir) {
		*slash = '\0';
		mkdir(dir, 0755);
	}
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0644);
	if (fd < 0) {
		return -1;
	}
	FILE *f = fdopen(fd, "w");
	if (f == NULL) {
		close(fd);
		return -1;
	}
	fprintf(f, "enabled %d\nprofile %s\n", st->enabled, st->public_profile ? "public" : "home");
	for (int i = 0; i < st->count; i++) {
		fprintf(f, "rule %s %d %s %s\n", st->rules[i].id, st->rules[i].public_too, st->rules[i].ports,
			st->rules[i].label);
	}
	if (fclose(f) != 0) {
		return -1;
	}
	return rename(tmp, state_file);
}

static void
append(char **buf, size_t *len, size_t *cap, const char *text)
{
	size_t n = strlen(text);
	if (*len + n + 1 > *cap) {
		*cap = (*len + n + 1) * 2;
		*buf = realloc(*buf, *cap);
		if (*buf == NULL) {
			exit(1);
		}
	}
	memcpy(*buf + *len, text, n + 1);
	*len += n;
}

static char *
build_ruleset(const struct state *st)
{
	char *buf = NULL;
	size_t len = 0, cap = 0;
	char line[512];
	append(&buf, &len, &cap, "table " TABLE "\ndelete table " TABLE "\n");
	if (!st->enabled) {
		return buf;
	}
	append(&buf, &len, &cap,
		"table " TABLE " {\n"
		"\tchain input {\n"
		"\t\ttype filter hook input priority filter; policy drop;\n"
		"\t\tct state established,related accept\n"
		"\t\tct state invalid drop\n"
		"\t\tiifname \"lo\" accept\n"
		"\t\tmeta l4proto { icmp, ipv6-icmp } accept\n"
		"\t\tudp dport 68 accept\n"
		"\t\tudp dport 546 accept\n");
	if (!st->public_profile) {
		append(&buf, &len, &cap, "\t\tudp dport 5353 accept comment \"mDNS\"\n");
	}
	for (int i = 0; i < st->count; i++) {
		const struct rule *r = &st->rules[i];
		if (st->public_profile && !r->public_too) {
			continue;
		}
		char ports[256];
		snprintf(ports, sizeof(ports), "%s", r->ports);
		char *save = NULL;
		for (char *item = strtok_r(ports, ",", &save); item != NULL; item = strtok_r(NULL, ",", &save)) {
			char *slash = strchr(item, '/');
			*slash = '\0';
			snprintf(line, sizeof(line), "\t\t%s dport %s accept comment \"%s\"\n", slash + 1, item, r->label);
			append(&buf, &len, &cap, line);
		}
	}
	append(&buf, &len, &cap, "\t}\n}\n");
	return buf;
}

static const char *
find_nft(void)
{
	if (nft_path != NULL) {
		return nft_path;
	}
	static const char *candidates[] = { "/usr/sbin/nft", "/sbin/nft", "/usr/bin/nft", NULL };
	for (int i = 0; candidates[i] != NULL; i++) {
		if (access(candidates[i], X_OK) == 0) {
			return candidates[i];
		}
	}
	return NULL;
}

static int
apply(const struct state *st)
{
	char *ruleset = build_ruleset(st);
	if (dry_run) {
		fputs(ruleset, stdout);
		free(ruleset);
		return 0;
	}
	const char *nft = find_nft();
	if (nft == NULL) {
		fprintf(stderr, "nft is not installed\n");
		free(ruleset);
		return 3;
	}
	int fds[2];
	if (pipe(fds) != 0) {
		free(ruleset);
		return 1;
	}
	pid_t pid = fork();
	if (pid < 0) {
		free(ruleset);
		return 1;
	}
	if (pid == 0) {
		dup2(fds[0], STDIN_FILENO);
		close(fds[0]);
		close(fds[1]);
		char *const env[] = { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", NULL };
		execle(nft, nft, "-f", "-", (char *) NULL, env);
		_exit(127);
	}
	close(fds[0]);
	size_t total = strlen(ruleset), done = 0;
	while (done < total) {
		ssize_t n = write(fds[1], ruleset + done, total - done);
		if (n < 0 && errno == EINTR) {
			continue;
		}
		if (n <= 0) {
			break;
		}
		done += (size_t) n;
	}
	close(fds[1]);
	free(ruleset);
	int status = 0;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
	}
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 4;
}

static int
usage(void)
{
	fprintf(stderr,
		"usage: singularity-firewall-helper status | apply | enable | disable | profile home|public |\n"
		"       allow ID PUBLIC PORTS LABEL | revoke ID\n");
	return 2;
}

int
main(int argc, char **argv)
{
	int i = 1;
	for (; i < argc && strncmp(argv[i], "--", 2) == 0; i++) {
		if (!overrides_allowed()) {
			fprintf(stderr, "options are not accepted here\n");
			return 2;
		}
		if (strcmp(argv[i], "--dry-run") == 0) {
			dry_run = 1;
		} else if (strcmp(argv[i], "--state") == 0 && i + 1 < argc) {
			state_file = argv[++i];
		} else if (strcmp(argv[i], "--nft") == 0 && i + 1 < argc) {
			nft_path = argv[++i];
		} else {
			return usage();
		}
	}
	if (i >= argc) {
		return usage();
	}
	const char *cmd = argv[i];
	int rest = argc - i - 1;
	char **args = argv + i + 1;
	struct state st;
	if (load_state(&st) != 0) {
		fprintf(stderr, "cannot read %s: %s\n", state_file, strerror(errno));
		return 1;
	}

	if (strcmp(cmd, "status") == 0 && rest == 0) {
		printf("enabled %d\nprofile %s\n", st.enabled, st.public_profile ? "public" : "home");
		for (int r = 0; r < st.count; r++) {
			printf("rule %s %d %s %s\n", st.rules[r].id, st.rules[r].public_too, st.rules[r].ports,
				st.rules[r].label);
		}
		return 0;
	} else if (strcmp(cmd, "apply") == 0 && rest == 0) {
		return apply(&st);
	} else if (strcmp(cmd, "enable") == 0 && rest == 0) {
		st.enabled = 1;
	} else if (strcmp(cmd, "disable") == 0 && rest == 0) {
		st.enabled = 0;
	} else if (strcmp(cmd, "profile") == 0 && rest == 1 &&
			(strcmp(args[0], "home") == 0 || strcmp(args[0], "public") == 0)) {
		st.public_profile = strcmp(args[0], "public") == 0;
	} else if (strcmp(cmd, "allow") == 0 && rest == 4) {
		if (!valid_id(args[0]) || (strcmp(args[1], "0") != 0 && strcmp(args[1], "1") != 0) ||
				!valid_ports(args[2]) || !valid_label(args[3])) {
			fprintf(stderr, "invalid rule\n");
			return 2;
		}
		int slot = -1;
		for (int r = 0; r < st.count; r++) {
			if (strcmp(st.rules[r].id, args[0]) == 0) {
				slot = r;
			}
		}
		if (slot < 0) {
			if (st.count >= MAX_RULES) {
				fprintf(stderr, "too many rules\n");
				return 1;
			}
			slot = st.count++;
		}
		snprintf(st.rules[slot].id, sizeof(st.rules[slot].id), "%s", args[0]);
		st.rules[slot].public_too = strcmp(args[1], "1") == 0;
		snprintf(st.rules[slot].ports, sizeof(st.rules[slot].ports), "%s", args[2]);
		snprintf(st.rules[slot].label, sizeof(st.rules[slot].label), "%s", args[3]);
	} else if (strcmp(cmd, "revoke") == 0 && rest == 1 && valid_id(args[0])) {
		int w = 0;
		for (int r = 0; r < st.count; r++) {
			if (strcmp(st.rules[r].id, args[0]) != 0) {
				st.rules[w++] = st.rules[r];
			}
		}
		st.count = w;
	} else {
		return usage();
	}

	if (!dry_run && save_state(&st) != 0) {
		fprintf(stderr, "cannot write %s: %s\n", state_file, strerror(errno));
		return 1;
	}
	return apply(&st);
}
