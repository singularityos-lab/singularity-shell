#ifndef SINGULARITY_IME_H
#define SINGULARITY_IME_H

#include <glib.h>

#define SINGULARITY_IME_SHIFT (1u << 0)
#define SINGULARITY_IME_CTRL (1u << 1)
#define SINGULARITY_IME_ALT (1u << 2)
#define SINGULARITY_IME_SUPER (1u << 3)

typedef gboolean (*SingularityImeKeyFunc)(guint key, guint keysym, const char *text,
                                          gboolean pressed, guint modifiers, gpointer data);
typedef void (*SingularityImeStateFunc)(gboolean active, const char *surrounding,
                                        guint cursor, guint purpose, guint hint, gpointer data);
typedef void (*SingularityImePointerFunc)(double x, double y, gpointer data);

gboolean singularity_ime_start(SingularityImeKeyFunc key_func, gpointer key_data,
                               SingularityImeStateFunc state_func, gpointer state_data,
                               SingularityImePointerFunc pointer_func, gpointer pointer_data);
void singularity_ime_set_grab(gboolean grab);
void singularity_ime_forward_key(guint key, gboolean pressed);
void singularity_ime_replace(guint delete_before, guint delete_after, const char *text);
void singularity_ime_popup_show(const guint8 *pixels, int width, int height, int stride, int scale);
void singularity_ime_popup_hide(void);

#endif
