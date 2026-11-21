#ifndef SINGULARITY_MOTION_CARD_H
#define SINGULARITY_MOTION_CARD_H

#include <glib.h>

typedef void (*SingularityMotionCardDone)(gpointer user_data);

gboolean singularity_motion_card_available(void);
gpointer singularity_motion_card_new(gpointer toplevel,
	SingularityMotionCardDone done, gpointer user_data, GDestroyNotify notify);
void singularity_motion_card_set_rect(gpointer card, int x, int y,
	int width, int height, int radius);
void singularity_motion_card_release(gpointer card, gboolean minimize,
	int x, int y, int width, int height, int radius,
	int velocity_x, int velocity_y);
void singularity_motion_card_free(gpointer card);

#endif
