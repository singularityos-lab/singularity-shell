#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t hups;
static volatile sig_atomic_t done;

static void
on_hup(int sig)
{
	(void)sig;
	hups++;
}

static void
on_term(int sig)
{
	(void)sig;
	done = 1;
}

int
main(void)
{
	const char *log = getenv("FAKE_XSETTINGSD_LOG");
	signal(SIGHUP, on_hup);
	signal(SIGTERM, on_term);
	sig_atomic_t seen = 0;
	while (!done) {
		pause();
		while (log && seen < hups) {
			int fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0600);
			if (fd >= 0) {
				char line[32];
				int n = snprintf(line, sizeof(line), "%d\n", (int)getpid());
				if (write(fd, line, n) < 0) {
					seen = hups;
				}
				close(fd);
			}
			seen++;
		}
	}
	return 0;
}
