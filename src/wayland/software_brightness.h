#ifndef SOFTWARE_BRIGHTNESS_H
#define SOFTWARE_BRIGHTNESS_H

#include <stdint.h>

typedef void (*SingularitySoftwareBrightnessReset)(void *data);

int singularity_software_brightness_init(SingularitySoftwareBrightnessReset reset, void *data);
int singularity_software_brightness_supported(void);
void singularity_software_brightness_set(const char *connector, uint32_t level);

#endif
