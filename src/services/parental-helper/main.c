#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_POLICY_SIZE (64 * 1024)

static gboolean
unprivileged_test_mode(void)
{
	return getuid() != 0 && geteuid() == getuid() && g_getenv("PKEXEC_UID") == NULL;
}

static const char *
policy_dir(void)
{
	const char *override = g_getenv("SINGULARITY_PARENTAL_DIR");
	if (override && *override && unprivileged_test_mode()) {
		return override;
	}
	return SINGULARITY_PARENTAL_DIR;
}

static gboolean
valid_user(const char *name)
{
	size_t len = strlen(name);
	if (len == 0 || len > 64 || name[0] == '-' || name[0] == '.') {
		return FALSE;
	}
	for (size_t i = 0; i < len; i++) {
		char c = name[i];
		if (!(g_ascii_isalnum(c) || c == '_' || c == '-' || c == '.')) {
			return FALSE;
		}
	}
	if (unprivileged_test_mode()) {
		return TRUE;
	}
	struct passwd *pw = getpwnam(name);
	return pw != NULL && pw->pw_uid != 0;
}

static gboolean
valid_policy(const char *data, gsize len)
{
	static const char *groups[] = { "Apps", "Time", "Web", NULL };
	g_autoptr(GKeyFile) kf = g_key_file_new();
	g_autoptr(GError) error = NULL;
	if (!g_key_file_load_from_data(kf, data, len, G_KEY_FILE_NONE, &error)) {
		fprintf(stderr, "Invalid policy: %s\n", error->message);
		return FALSE;
	}
	gsize n = 0;
	g_auto(GStrv) names = g_key_file_get_groups(kf, &n);
	for (gsize i = 0; i < n; i++) {
		if (!g_strv_contains(groups, names[i])) {
			fprintf(stderr, "Invalid policy group: %s\n", names[i]);
			return FALSE;
		}
	}
	return TRUE;
}

static char *
read_stdin(gsize *len)
{
	GString *buf = g_string_new(NULL);
	char chunk[4096];
	ssize_t n;
	while ((n = read(STDIN_FILENO, chunk, sizeof(chunk))) > 0) {
		g_string_append_len(buf, chunk, n);
		if (buf->len > MAX_POLICY_SIZE) {
			g_string_free(buf, TRUE);
			return NULL;
		}
	}
	if (n < 0) {
		g_string_free(buf, TRUE);
		return NULL;
	}
	*len = buf->len;
	return g_string_free(buf, FALSE);
}

static int
write_policy(const char *user)
{
	gsize len = 0;
	g_autofree char *data = read_stdin(&len);
	if (data == NULL) {
		fprintf(stderr, "Cannot read the policy\n");
		return 1;
	}
	if (!valid_policy(data, len)) {
		return 1;
	}
	const char *dir = policy_dir();
	if (g_mkdir_with_parents(dir, 0755) != 0) {
		fprintf(stderr, "Cannot create %s: %s\n", dir, g_strerror(errno));
		return 1;
	}
	g_autofree char *path = g_strdup_printf("%s/%s.conf", dir, user);
	g_autofree char *tmp = g_strdup_printf("%s/.%s.conf.XXXXXX", dir, user);
	int fd = g_mkstemp_full(tmp, O_WRONLY | O_CLOEXEC, 0644);
	if (fd < 0) {
		fprintf(stderr, "Cannot write %s: %s\n", dir, g_strerror(errno));
		return 1;
	}
	gsize off = 0;
	while (off < len) {
		ssize_t w = write(fd, data + off, len - off);
		if (w < 0) {
			if (errno == EINTR) {
				continue;
			}
			close(fd);
			g_unlink(tmp);
			fprintf(stderr, "Cannot write %s: %s\n", tmp, g_strerror(errno));
			return 1;
		}
		off += w;
	}
	if (fchmod(fd, 0644) != 0 || fsync(fd) != 0 || close(fd) != 0 || g_rename(tmp, path) != 0) {
		g_unlink(tmp);
		fprintf(stderr, "Cannot save %s: %s\n", path, g_strerror(errno));
		return 1;
	}
	return 0;
}

static int
clear_policy(const char *user)
{
	g_autofree char *path = g_strdup_printf("%s/%s.conf", policy_dir(), user);
	if (g_unlink(path) != 0 && errno != ENOENT) {
		fprintf(stderr, "Cannot remove %s: %s\n", path, g_strerror(errno));
		return 1;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc != 3 || (strcmp(argv[1], "set") != 0 && strcmp(argv[1], "clear") != 0)) {
		fprintf(stderr, "Usage: %s set|clear USER\n", argv[0]);
		return 2;
	}
	if (geteuid() != 0 && !unprivileged_test_mode()) {
		fprintf(stderr, "This helper must run as root\n");
		return 1;
	}
	if (!valid_user(argv[2])) {
		fprintf(stderr, "Unknown or invalid user: %s\n", argv[2]);
		return 1;
	}
	umask(022);
	if (strcmp(argv[1], "set") == 0) {
		return write_policy(argv[2]);
	}
	return clear_policy(argv[2]);
}
