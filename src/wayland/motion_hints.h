#ifndef MOTION_HINTS_H
#define MOTION_HINTS_H

#include <gtk/gtk.h>

void singularity_motion_hints_set_icon_rect(GtkWidget *window, const char *app_id,
	int x, int y, int width, int height);
void singularity_motion_hints_clear(GtkWidget *window);
void singularity_motion_hints_launch(GtkWidget *window, const char *app_id);
gboolean singularity_motion_hints_available(GtkWidget *window);

#endif
