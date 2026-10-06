#ifndef SINGULARITY_STAGE_H
#define SINGULARITY_STAGE_H

#include <glib.h>

gboolean singularity_stage_available(void);
void singularity_stage_set_hidden(void *toplevel, gboolean hidden,
	int x, int y, int width, int height);

gboolean singularity_stage_groups_supported(void);
void singularity_stage_set_group(void *toplevel, guint group);
gboolean singularity_stage_get_group(void *toplevel, guint *group,
	gboolean *hidden);

#endif
