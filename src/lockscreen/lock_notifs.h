#ifndef SINGULARITY_LOCK_NOTIFS_H
#define SINGULARITY_LOCK_NOTIFS_H

#include <stdint.h>

#define LOCK_NOTIFS_MAX 4

typedef struct {
    char app_name[128];
    char summary[256];
    char body[512];
    int64_t timestamp;
} LockNotification;

typedef struct {
    int count;
    LockNotification items[LOCK_NOTIFS_MAX];
} LockNotifsState;

void lock_notifs_init(void (*on_change)(void));
const LockNotifsState *lock_notifs_get(void);

#endif
