#include <string.h>
#include <wayland-client.h>

#include "snap_layouts.h"
#include "wayland_integration.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "singularity-snap-unstable-v1-client-protocol.h"

static struct zsingularity_snap_manager_v1 *manager;
static SingularitySnapEventFunc callback;
static gpointer callback_data;

static void
emit(SingularitySnapEventKind kind, void *toplevel, guint source, int x, int y,
     int width, int height, int ax, int ay, int aw, int ah)
{
    if (callback)
        callback(kind, toplevel, source, x, y, width, height, ax, ay, aw, ah, callback_data);
}

static void
handle_show(void *data, struct zsingularity_snap_manager_v1 *mgr,
            struct zwlr_foreign_toplevel_handle_v1 *toplevel, uint32_t source,
            int32_t anchor_x, int32_t anchor_y, int32_t anchor_width, int32_t anchor_height,
            int32_t area_x, int32_t area_y, int32_t area_width, int32_t area_height)
{
    (void)data; (void)mgr;
    emit(SINGULARITY_SNAP_EVENT_SHOW, toplevel, source, anchor_x, anchor_y,
         anchor_width, anchor_height, area_x, area_y, area_width, area_height);
}

static void
handle_motion(void *data, struct zsingularity_snap_manager_v1 *mgr, int32_t x, int32_t y)
{
    (void)data; (void)mgr;
    emit(SINGULARITY_SNAP_EVENT_MOTION, NULL, 0, x, y, 0, 0, 0, 0, 0, 0);
}

static void
handle_hide(void *data, struct zsingularity_snap_manager_v1 *mgr, uint32_t source)
{
    (void)data; (void)mgr;
    emit(SINGULARITY_SNAP_EVENT_HIDE, NULL, source, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void
handle_drop(void *data, struct zsingularity_snap_manager_v1 *mgr,
            struct zwlr_foreign_toplevel_handle_v1 *toplevel, int32_t x, int32_t y)
{
    (void)data; (void)mgr;
    emit(SINGULARITY_SNAP_EVENT_DROP, toplevel, 1, x, y, 0, 0, 0, 0, 0, 0);
}

static const struct zsingularity_snap_manager_v1_listener manager_listener = {
    .picker_show = handle_show,
    .picker_motion = handle_motion,
    .picker_hide = handle_hide,
    .picker_drop = handle_drop,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
    (void)version;
    struct zsingularity_snap_manager_v1 **out = data;
    if (strcmp(interface, zsingularity_snap_manager_v1_interface.name) != 0)
        return;
    *out = wl_registry_bind(registry, name, &zsingularity_snap_manager_v1_interface, 1);
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void
flush(void)
{
    struct wl_display *display = singularity_wayland_display();
    if (display)
        wl_display_flush(display);
}

gboolean
singularity_snap_bridge_start(SingularitySnapEventFunc func, gpointer user_data)
{
    callback = func;
    callback_data = user_data;
    if (manager)
        return TRUE;
    struct wl_display *display = singularity_wayland_display();
    if (!display)
        return FALSE;
    struct zsingularity_snap_manager_v1 *found = NULL;
    struct wl_event_queue *queue = wl_display_create_queue(display);
    if (!queue)
        return FALSE;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_proxy_set_queue((struct wl_proxy *)registry, queue);
    wl_registry_add_listener(registry, &registry_listener, &found);
    wl_display_roundtrip_queue(display, queue);
    wl_registry_destroy(registry);
    if (found) {
        wl_proxy_set_queue((struct wl_proxy *)found, NULL);
        zsingularity_snap_manager_v1_add_listener(found, &manager_listener, NULL);
    }
    wl_event_queue_destroy(queue);
    manager = found;
    return manager != NULL;
}

gboolean
singularity_snap_bridge_available(void)
{
    return manager != NULL;
}

void
singularity_snap_bridge_set_enabled(gboolean enabled)
{
    if (!manager)
        return;
    zsingularity_snap_manager_v1_set_enabled(manager, enabled ? 1 : 0);
    flush();
}

void
singularity_snap_bridge_set_picker_area(int x, int y, int width, int height)
{
    if (!manager)
        return;
    zsingularity_snap_manager_v1_set_picker_area(manager, x, y, width, height);
    flush();
}

void
singularity_snap_bridge_set_zone_preview(int x, int y, int width, int height, gboolean visible)
{
    if (!manager)
        return;
    zsingularity_snap_manager_v1_set_zone_preview(manager, x, y, width, height, visible ? 1 : 0);
    flush();
}

void
singularity_snap_bridge_snap_to_zone(void *toplevel, int ref_x, int ref_y,
                                     int x, int y, int width, int height)
{
    if (!manager || !singularity_wayland_handle_is_valid(toplevel))
        return;
    zsingularity_snap_manager_v1_snap_to_zone(manager, toplevel, ref_x, ref_y,
        (uint32_t)x, (uint32_t)y, (uint32_t)width, (uint32_t)height);
    flush();
}
