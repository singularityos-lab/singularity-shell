#ifndef SINGULARITY_LOCK_FPRINT_H
#define SINGULARITY_LOCK_FPRINT_H

#include <stdbool.h>

typedef void (*LockFprintMatch)(void);
typedef void (*LockFprintStatus)(const char *text, bool error);

void lock_fprint_start(const char *user, LockFprintMatch on_match, LockFprintStatus on_status);
void lock_fprint_stop(void);
bool lock_fprint_active(void);

#endif
