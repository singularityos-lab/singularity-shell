#ifndef SINGULARITY_SNAP_LAYOUTS_H
#define SINGULARITY_SNAP_LAYOUTS_H

#include <glib.h>

typedef enum {
    SINGULARITY_SNAP_EVENT_SHOW,
    SINGULARITY_SNAP_EVENT_MOTION,
    SINGULARITY_SNAP_EVENT_HIDE,
    SINGULARITY_SNAP_EVENT_DROP
} SingularitySnapEventKind;

typedef void (*SingularitySnapEventFunc)(SingularitySnapEventKind kind, void *toplevel,
    guint source, int x, int y, int width, int height,
    int area_x, int area_y, int area_width, int area_height, gpointer user_data);

gboolean singularity_snap_bridge_start(SingularitySnapEventFunc func, gpointer user_data);
gboolean singularity_snap_bridge_available(void);
void singularity_snap_bridge_set_enabled(gboolean enabled);
void singularity_snap_bridge_set_picker_area(int x, int y, int width, int height);
void singularity_snap_bridge_set_zone_preview(int x, int y, int width, int height, gboolean visible);
void singularity_snap_bridge_snap_to_zone(void *toplevel, int ref_x, int ref_y,
    int x, int y, int width, int height);

#endif
