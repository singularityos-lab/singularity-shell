#ifndef IDLE_NOTIFY_H
#define IDLE_NOTIFY_H

#include <stdint.h>

typedef void (*SingularityIdleCallback)(int id, int idle, void *data);

int singularity_idle_init(void);
int singularity_idle_input_only_supported(void);
int singularity_output_power_supported(void);
void singularity_idle_watch(int id, uint32_t timeout_ms, int input_only,
		SingularityIdleCallback callback, void *data);
void singularity_idle_unwatch(int id);
void singularity_output_power_set(int on);

#endif
