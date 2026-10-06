#ifndef SINGULARITY_PROCESS_INFO_H
#define SINGULARITY_PROCESS_INFO_H

#include <glib.h>

gboolean singularity_process_info_available(void);
gboolean singularity_process_info_get_pid(void *toplevel, int *pid,
	guint *source);

#endif
