#ifndef SINGULARITY_PROJECTION_H
#define SINGULARITY_PROJECTION_H

#include <glib.h>

gboolean singularity_projection_available(void);
void *singularity_projection_create(const char *name, int width, int height,
	int refresh, const char *form_factor, char **output_name, int *out_width, int *out_height);
void singularity_projection_map_touch(void *projection, const char *device_name);
gboolean singularity_projection_set_mode(void *projection, int width, int height, int refresh);
void singularity_projection_destroy(void *projection);

#endif
