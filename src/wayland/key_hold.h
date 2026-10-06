#ifndef KEY_HOLD_H
#define KEY_HOLD_H

#include <stdint.h>

typedef void (*SingularityKeyHoldCallback)(int started, int cancelled, void *data);

int singularity_key_hold_init(SingularityKeyHoldCallback callback, void *data);
int singularity_key_hold_supported(void);
void singularity_key_hold_set_delay(uint32_t delay_ms);
void singularity_key_hold_finish(void);

#endif
