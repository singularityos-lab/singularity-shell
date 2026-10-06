#ifndef SINGULARITY_CLIPBOARD_WATCH_H
#define SINGULARITY_CLIPBOARD_WATCH_H

#include <glib.h>

typedef void (*SingularityClipboardFunc)(const char *mime, GBytes *data, gboolean sensitive, gpointer user_data);

gboolean singularity_clipboard_watch_start(SingularityClipboardFunc func, gpointer user_data);
gboolean singularity_clipboard_watch_available(void);
gboolean singularity_clipboard_set(const char *mime, GBytes *data);
gboolean singularity_clipboard_send_paste(void);

#endif
