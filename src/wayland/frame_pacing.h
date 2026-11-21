#ifndef FRAME_PACING_H
#define FRAME_PACING_H

#include <stdint.h>

int singularity_frame_pacing_init(void);
void singularity_frame_pacing_set(const char *connector, uint32_t rate);

#endif
