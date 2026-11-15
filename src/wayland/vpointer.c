#include <stdint.h>
#include <string.h>
#include <linux/input-event-codes.h>

#include <wayland-client.h>
#include <glib.h>
#include <gdk/gdk.h>
#include <gdk/wayland/gdkwayland.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "vpointer.h"

static struct zwlr_virtual_pointer_manager_v1 *manager = NULL;
static struct zwlr_virtual_pointer_v1 *pointer = NULL;
static struct wl_display *display = NULL;

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *iface, uint32_t version) {
    (void) data; (void) version;
    if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void) data; (void) registry; (void) name;
}

static const struct wl_registry_listener registry_listener = { registry_global, registry_remove };

static gboolean ensure_pointer(void) {
    if (pointer != NULL) return TRUE;
    GdkDisplay *gdk = gdk_display_get_default();
    if (gdk == NULL || !GDK_IS_WAYLAND_DISPLAY(gdk)) return FALSE;
    display = gdk_wayland_display_get_wl_display(gdk);
    if (manager == NULL) {
        struct wl_registry *registry = wl_display_get_registry(display);
        wl_registry_add_listener(registry, &registry_listener, NULL);
        wl_display_roundtrip(display);
    }
    if (manager == NULL) return FALSE;
    struct wl_seat *seat = gdk_wayland_seat_get_wl_seat(gdk_display_get_default_seat(gdk));
    pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    return pointer != NULL;
}

static uint32_t now_ms(void) {
    return (uint32_t) (g_get_monotonic_time() / 1000);
}

gboolean singularity_vpointer_available(void) {
    return ensure_pointer();
}

void singularity_vpointer_move(double dx, double dy) {
    if (!ensure_pointer()) return;
    zwlr_virtual_pointer_v1_motion(pointer, now_ms(), wl_fixed_from_double(dx), wl_fixed_from_double(dy));
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_flush(display);
}

void singularity_vpointer_button(guint button, gboolean pressed) {
    if (!ensure_pointer()) return;
    zwlr_virtual_pointer_v1_button(pointer, now_ms(), button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_flush(display);
}

void singularity_vpointer_click(guint button) {
    singularity_vpointer_button(button, TRUE);
    singularity_vpointer_button(button, FALSE);
}

void singularity_vpointer_scroll(double dx, double dy) {
    if (!ensure_pointer()) return;
    uint32_t t = now_ms();
    zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_FINGER);
    if (dy != 0) zwlr_virtual_pointer_v1_axis(pointer, t, WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(dy));
    if (dx != 0) zwlr_virtual_pointer_v1_axis(pointer, t, WL_POINTER_AXIS_HORIZONTAL_SCROLL, wl_fixed_from_double(dx));
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_flush(display);
}
