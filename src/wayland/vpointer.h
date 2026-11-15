#ifndef SINGULARITY_VPOINTER_H
#define SINGULARITY_VPOINTER_H

#include <glib.h>

gboolean singularity_vpointer_available(void);
void singularity_vpointer_move(double dx, double dy);
void singularity_vpointer_button(guint button, gboolean pressed);
void singularity_vpointer_click(guint button);
void singularity_vpointer_scroll(double dx, double dy);

#endif
