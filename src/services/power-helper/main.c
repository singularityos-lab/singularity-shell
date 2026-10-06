#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SYSFS_ROOT "/sys/class/power_supply"

static const char *
sysfs_root(void)
{
	const char *override = getenv("SINGULARITY_POWER_SYSFS");
	if (override && *override && geteuid() != 0 && getuid() == geteuid()) {
		return override;
	}
	return SYSFS_ROOT;
}

static int
valid_name(const char *name)
{
	size_t len = strlen(name);
	if (len == 0 || len > 64 || name[0] == '.') {
		return 0;
	}
	for (size_t i = 0; i < len; i++) {
		char c = name[i];
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
				c == '_' || c == '-')) {
			return 0;
		}
	}
	return 1;
}

static int
read_attr(const char *dir, const char *attr, char *buf, size_t size)
{
	char path[512];
	snprintf(path, sizeof(path), "%s/%s", dir, attr);
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0) {
		return -1;
	}
	ssize_t n = read(fd, buf, size - 1);
	close(fd);
	if (n < 0) {
		return -1;
	}
	buf[n] = '\0';
	while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) {
		buf[--n] = '\0';
	}
	return 0;
}

static int
write_attr(const char *dir, const char *attr, int value)
{
	char path[512];
	char text[16];
	snprintf(path, sizeof(path), "%s/%s", dir, attr);
	int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_TRUNC);
	if (fd < 0) {
		return -1;
	}
	int len = snprintf(text, sizeof(text), "%d\n", value);
	ssize_t n = write(fd, text, (size_t)len);
	int saved = errno;
	close(fd);
	errno = saved;
	return n == len ? 0 : -1;
}

static int
charge_limit(const char *battery, const char *percent_text)
{
	char *end = NULL;
	long percent = strtol(percent_text, &end, 10);
	if (!end || *end != '\0' || percent < 50 || percent > 100) {
		fprintf(stderr, "The charge limit must be between 50 and 100\n");
		return 2;
	}
	if (!valid_name(battery)) {
		fprintf(stderr, "Invalid battery name\n");
		return 2;
	}
	char dir[384];
	char buf[64];
	snprintf(dir, sizeof(dir), "%s/%s", sysfs_root(), battery);
	if (read_attr(dir, "type", buf, sizeof(buf)) != 0 || strcmp(buf, "Battery") != 0) {
		fprintf(stderr, "%s is not a battery\n", battery);
		return 2;
	}
	if (read_attr(dir, "charge_control_end_threshold", buf, sizeof(buf)) != 0) {
		fprintf(stderr, "%s does not support a charge limit\n", battery);
		return 3;
	}
	if (read_attr(dir, "charge_control_start_threshold", buf, sizeof(buf)) == 0) {
		long start = strtol(buf, NULL, 10);
		if (start >= percent && write_attr(dir, "charge_control_start_threshold", (int)percent - 5) != 0) {
			fprintf(stderr, "Cannot lower the charge start threshold: %s\n", strerror(errno));
			return 4;
		}
	}
	if (write_attr(dir, "charge_control_end_threshold", (int)percent) != 0) {
		fprintf(stderr, "Cannot write the charge limit: %s\n", strerror(errno));
		return 4;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 4 && strcmp(argv[1], "charge-limit") == 0) {
		return charge_limit(argv[2], argv[3]);
	}
	fprintf(stderr, "usage: singularity-power-helper charge-limit BATTERY PERCENT\n");
	return 2;
}
