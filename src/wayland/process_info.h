#ifndef SINGULARITY_PROCESS_INFO_H
#define SINGULARITY_PROCESS_INFO_H

#include <glib.h>

gboolean singularity_process_info_available(void);
gboolean singularity_process_info_get_pid(void *toplevel, int *pid,
	guint *source);

typedef void (*SingularityProcessInfoResumeFunc)(void *toplevel, gpointer user_data);

gboolean singularity_process_info_watch_resume(SingularityProcessInfoResumeFunc func,
	gpointer user_data);

#endif
