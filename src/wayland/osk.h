#ifndef SINGULARITY_OSK_H
#define SINGULARITY_OSK_H

#include <glib.h>

#define SINGULARITY_OSK_SHIFT (1u << 0)
#define SINGULARITY_OSK_CTRL (1u << 1)
#define SINGULARITY_OSK_ALT (1u << 2)
#define SINGULARITY_OSK_SUPER (1u << 3)

gboolean singularity_osk_set_layout(const char *layout, const char *variant);
void singularity_osk_press(guint evdev_code, guint modifiers);
char *singularity_osk_label(guint evdev_code, gboolean shifted);

#endif
