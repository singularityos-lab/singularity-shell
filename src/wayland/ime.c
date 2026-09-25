#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <glib.h>
#include <gdk/gdk.h>
#include <gdk/wayland/gdkwayland.h>

#include "input-method-unstable-v2-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "ime.h"

#define KEY_COUNT 1024

struct ime_state {
    gboolean active;
    char *surrounding;
    uint32_t cursor;
    uint32_t purpose;
    uint32_t hint;
};

static struct wl_display *display = NULL;
static struct wl_seat *seat = NULL;
static struct zwp_input_method_manager_v2 *im_manager = NULL;
static struct zwp_virtual_keyboard_manager_v1 *vk_manager = NULL;
static struct wl_compositor *compositor = NULL;
static struct wl_shm *shm = NULL;
static struct wl_seat *pointer_seat = NULL;

static struct zwp_input_method_v2 *input_method = NULL;
static struct zwp_input_method_keyboard_grab_v2 *keyboard_grab = NULL;
static struct zwp_virtual_keyboard_v1 *forward_keyboard = NULL;
static struct wl_surface *popup_surface = NULL;
static struct zwp_input_popup_surface_v2 *popup = NULL;
static struct wl_pointer *pointer = NULL;

static struct xkb_context *xkb = NULL;
static struct xkb_keymap *keymap = NULL;
static struct xkb_state *xkb_state = NULL;
static gboolean forward_keymap_set = FALSE;
static gboolean forwarded[KEY_COUNT];

static struct ime_state pending = { 0 };
static struct ime_state current = { 0 };
static uint32_t serial = 0;
static gboolean want_grab = FALSE;

static gboolean pointer_inside = FALSE;
static double pointer_x = 0;
static double pointer_y = 0;

static SingularityImeKeyFunc key_func = NULL;
static gpointer key_data = NULL;
static SingularityImeStateFunc state_func = NULL;
static gpointer state_data = NULL;
static SingularityImePointerFunc pointer_func = NULL;
static gpointer pointer_data = NULL;

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *iface, uint32_t version) {
    (void) data;
    if (strcmp(iface, zwp_input_method_manager_v2_interface.name) == 0) {
        im_manager = wl_registry_bind(registry, name, &zwp_input_method_manager_v2_interface, 1);
    } else if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        vk_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    } else if (strcmp(iface, wl_compositor_interface.name) == 0) {
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, MIN(version, 4));
    } else if (strcmp(iface, wl_shm_interface.name) == 0) {
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, wl_seat_interface.name) == 0 && pointer_seat == NULL) {
        pointer_seat = wl_registry_bind(registry, name, &wl_seat_interface, MIN(version, 5));
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void) data; (void) registry; (void) name;
}

static const struct wl_registry_listener registry_listener = { registry_global, registry_remove };

static guint current_modifiers(void) {
    if (xkb_state == NULL) return 0;
    guint mods = 0;
    if (xkb_state_mod_name_is_active(xkb_state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0)
        mods |= SINGULARITY_IME_SHIFT;
    if (xkb_state_mod_name_is_active(xkb_state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0)
        mods |= SINGULARITY_IME_CTRL;
    if (xkb_state_mod_name_is_active(xkb_state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0)
        mods |= SINGULARITY_IME_ALT;
    if (xkb_state_mod_name_is_active(xkb_state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0)
        mods |= SINGULARITY_IME_SUPER;
    return mods;
}

static void send_forward(guint key, gboolean pressed) {
    if (forward_keyboard == NULL || !forward_keymap_set) return;
    zwp_virtual_keyboard_v1_key(forward_keyboard, (uint32_t) (g_get_monotonic_time() / 1000), key,
                                pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
}

static void release_forwarded_keys(void) {
    for (guint key = 0; key < KEY_COUNT; key++) {
        if (forwarded[key]) {
            send_forward(key, FALSE);
            forwarded[key] = FALSE;
        }
    }
}

static void grab_keymap(void *data, struct zwp_input_method_keyboard_grab_v2 *grab,
                        uint32_t format, int32_t fd, uint32_t size) {
    (void) data; (void) grab;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        close(fd);
        return;
    }
    char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return;
    }
    if (xkb == NULL) xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *next = xkb_keymap_new_from_string(xkb, map, XKB_KEYMAP_FORMAT_TEXT_V1,
                                                         XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    if (next != NULL) {
        if (xkb_state != NULL) xkb_state_unref(xkb_state);
        if (keymap != NULL) xkb_keymap_unref(keymap);
        keymap = next;
        xkb_state = xkb_state_new(keymap);
    }
    if (forward_keyboard != NULL) {
        zwp_virtual_keyboard_v1_keymap(forward_keyboard, format, fd, size);
        forward_keymap_set = TRUE;
    }
    close(fd);
}

static void grab_key(void *data, struct zwp_input_method_keyboard_grab_v2 *grab,
                     uint32_t key_serial, uint32_t time, uint32_t key, uint32_t state) {
    (void) data; (void) grab; (void) key_serial; (void) time;
    gboolean pressed = state == WL_KEYBOARD_KEY_STATE_PRESSED;
    guint sym = 0;
    char text[16] = { 0 };
    if (xkb_state != NULL) {
        sym = xkb_state_key_get_one_sym(xkb_state, key + 8);
        xkb_state_key_get_utf8(xkb_state, key + 8, text, sizeof text);
    }
    gboolean consumed = FALSE;
    if (key_func != NULL) {
        consumed = key_func(key, sym, text, pressed, current_modifiers(), key_data);
    }
    if (key >= KEY_COUNT) {
        if (!consumed) send_forward(key, pressed);
    } else if (pressed) {
        if (!consumed) {
            send_forward(key, TRUE);
            forwarded[key] = TRUE;
        }
    } else if (forwarded[key]) {
        send_forward(key, FALSE);
        forwarded[key] = FALSE;
    }
    wl_display_flush(display);
}

static void grab_modifiers(void *data, struct zwp_input_method_keyboard_grab_v2 *grab,
                           uint32_t mod_serial, uint32_t depressed, uint32_t latched,
                           uint32_t locked, uint32_t group) {
    (void) data; (void) grab; (void) mod_serial;
    if (xkb_state != NULL) xkb_state_update_mask(xkb_state, depressed, latched, locked, 0, 0, group);
    if (forward_keyboard != NULL && forward_keymap_set) {
        zwp_virtual_keyboard_v1_modifiers(forward_keyboard, depressed, latched, locked, group);
        wl_display_flush(display);
    }
}

static void grab_repeat_info(void *data, struct zwp_input_method_keyboard_grab_v2 *grab,
                             int32_t rate, int32_t delay) {
    (void) data; (void) grab; (void) rate; (void) delay;
}

static const struct zwp_input_method_keyboard_grab_v2_listener grab_listener = {
    grab_keymap, grab_key, grab_modifiers, grab_repeat_info,
};

static void update_grab(void) {
    gboolean grab = want_grab && current.active && input_method != NULL;
    if (grab && keyboard_grab == NULL) {
        keyboard_grab = zwp_input_method_v2_grab_keyboard(input_method);
        zwp_input_method_keyboard_grab_v2_add_listener(keyboard_grab, &grab_listener, NULL);
    } else if (!grab && keyboard_grab != NULL) {
        release_forwarded_keys();
        zwp_input_method_keyboard_grab_v2_release(keyboard_grab);
        keyboard_grab = NULL;
    }
    wl_display_flush(display);
}

static void im_activate(void *data, struct zwp_input_method_v2 *im) {
    (void) data; (void) im;
    g_free(pending.surrounding);
    pending = (struct ime_state) { .active = TRUE };
}

static void im_deactivate(void *data, struct zwp_input_method_v2 *im) {
    (void) data; (void) im;
    pending.active = FALSE;
}

static void im_surrounding_text(void *data, struct zwp_input_method_v2 *im, const char *text,
                                uint32_t cursor, uint32_t anchor) {
    (void) data; (void) im; (void) anchor;
    g_free(pending.surrounding);
    pending.surrounding = g_strdup(text);
    pending.cursor = cursor;
}

static void im_text_change_cause(void *data, struct zwp_input_method_v2 *im, uint32_t cause) {
    (void) data; (void) im; (void) cause;
}

static void im_content_type(void *data, struct zwp_input_method_v2 *im, uint32_t hint,
                            uint32_t purpose) {
    (void) data; (void) im;
    pending.hint = hint;
    pending.purpose = purpose;
}

static void im_done(void *data, struct zwp_input_method_v2 *im) {
    (void) data; (void) im;
    serial++;
    g_free(current.surrounding);
    current = pending;
    current.surrounding = g_strdup(pending.surrounding);
    update_grab();
    if (state_func != NULL) {
        state_func(current.active, current.surrounding != NULL ? current.surrounding : "",
                   current.cursor, current.purpose, current.hint, state_data);
    }
}

static void im_unavailable(void *data, struct zwp_input_method_v2 *im) {
    (void) data;
    g_warning("Input method: another input method is already running");
    zwp_input_method_v2_destroy(im);
    input_method = NULL;
}

static const struct zwp_input_method_v2_listener im_listener = {
    im_activate, im_deactivate, im_surrounding_text, im_text_change_cause,
    im_content_type, im_done, im_unavailable,
};

static void popup_rectangle(void *data, struct zwp_input_popup_surface_v2 *surface,
                            int32_t x, int32_t y, int32_t width, int32_t height) {
    (void) data; (void) surface; (void) x; (void) y; (void) width; (void) height;
}

static const struct zwp_input_popup_surface_v2_listener popup_listener = { popup_rectangle };

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t s, struct wl_surface *surface,
                          wl_fixed_t x, wl_fixed_t y) {
    (void) data; (void) p; (void) s;
    pointer_inside = surface != NULL && surface == popup_surface;
    pointer_x = wl_fixed_to_double(x);
    pointer_y = wl_fixed_to_double(y);
}

static void pointer_leave(void *data, struct wl_pointer *p, uint32_t s, struct wl_surface *surface) {
    (void) data; (void) p; (void) s; (void) surface;
    pointer_inside = FALSE;
}

static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void) data; (void) p; (void) time;
    if (!pointer_inside) return;
    pointer_x = wl_fixed_to_double(x);
    pointer_y = wl_fixed_to_double(y);
}

static void pointer_button(void *data, struct wl_pointer *p, uint32_t s, uint32_t time,
                           uint32_t button, uint32_t state) {
    (void) data; (void) p; (void) s; (void) time; (void) button;
    if (pointer_inside && state == WL_POINTER_BUTTON_STATE_PRESSED && pointer_func != NULL) {
        pointer_func(pointer_x, pointer_y, pointer_data);
    }
}

static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t value) {
    (void) data; (void) p; (void) time; (void) axis; (void) value;
}

static void pointer_frame(void *data, struct wl_pointer *p) {
    (void) data; (void) p;
}

static void pointer_axis_source(void *data, struct wl_pointer *p, uint32_t source) {
    (void) data; (void) p; (void) source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis) {
    (void) data; (void) p; (void) time; (void) axis;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *p, uint32_t axis, int32_t discrete) {
    (void) data; (void) p; (void) axis; (void) discrete;
}

static void pointer_axis_value120(void *data, struct wl_pointer *p, uint32_t axis, int32_t value) {
    (void) data; (void) p; (void) axis; (void) value;
}

static void pointer_axis_relative_direction(void *data, struct wl_pointer *p, uint32_t axis,
                                            uint32_t direction) {
    (void) data; (void) p; (void) axis; (void) direction;
}

static const struct wl_pointer_listener pointer_listener = {
    pointer_enter, pointer_leave, pointer_motion, pointer_button, pointer_axis, pointer_frame,
    pointer_axis_source, pointer_axis_stop, pointer_axis_discrete, pointer_axis_value120,
    pointer_axis_relative_direction,
};

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
    (void) data;
    gboolean has_pointer = (caps & WL_SEAT_CAPABILITY_POINTER) != 0;
    if (has_pointer && pointer == NULL) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    } else if (!has_pointer && pointer != NULL) {
        wl_pointer_release(pointer);
        pointer = NULL;
        pointer_inside = FALSE;
    }
}

static void seat_name(void *data, struct wl_seat *s, const char *name) {
    (void) data; (void) s; (void) name;
}

static const struct wl_seat_listener seat_listener = { seat_capabilities, seat_name };

gboolean singularity_ime_start(SingularityImeKeyFunc kf, gpointer kd, SingularityImeStateFunc sf,
                               gpointer sd, SingularityImePointerFunc pf, gpointer pd) {
    if (input_method != NULL) return TRUE;
    GdkDisplay *gdk = gdk_display_get_default();
    if (gdk == NULL || !GDK_IS_WAYLAND_DISPLAY(gdk)) return FALSE;
    display = gdk_wayland_display_get_wl_display(gdk);
    seat = gdk_wayland_seat_get_wl_seat(gdk_display_get_default_seat(gdk));
    if (seat == NULL) return FALSE;

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (im_manager == NULL || vk_manager == NULL || compositor == NULL || shm == NULL) {
        g_warning("Input method: compositor lacks input method support");
        return FALSE;
    }

    key_func = kf;
    key_data = kd;
    state_func = sf;
    state_data = sd;
    pointer_func = pf;
    pointer_data = pd;

    forward_keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vk_manager, seat);
    input_method = zwp_input_method_manager_v2_get_input_method(im_manager, seat);
    zwp_input_method_v2_add_listener(input_method, &im_listener, NULL);

    if (pointer_seat != NULL) wl_seat_add_listener(pointer_seat, &seat_listener, NULL);
    wl_display_flush(display);
    return TRUE;
}

void singularity_ime_set_grab(gboolean grab) {
    want_grab = grab;
    if (display != NULL) update_grab();
}

void singularity_ime_forward_key(guint key, gboolean pressed) {
    send_forward(key, pressed);
    if (display != NULL) wl_display_flush(display);
}

void singularity_ime_replace(guint delete_before, guint delete_after, const char *text) {
    if (input_method == NULL || !current.active) return;
    if (delete_before > 0 || delete_after > 0) {
        zwp_input_method_v2_delete_surrounding_text(input_method, delete_before, delete_after);
    }
    if (text != NULL && *text != '\0') zwp_input_method_v2_commit_string(input_method, text);
    zwp_input_method_v2_commit(input_method, serial);
    wl_display_flush(display);
}

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void) data;
    wl_buffer_destroy(buffer);
}

static const struct wl_buffer_listener buffer_listener = { buffer_release };

void singularity_ime_popup_show(const guint8 *pixels, int width, int height, int stride, int scale) {
    if (input_method == NULL || pixels == NULL || width <= 0 || height <= 0) return;
    if (popup_surface == NULL) {
        popup_surface = wl_compositor_create_surface(compositor);
        popup = zwp_input_method_v2_get_input_popup_surface(input_method, popup_surface);
        zwp_input_popup_surface_v2_add_listener(popup, &popup_listener, NULL);
    }

    size_t size = (size_t) stride * (size_t) height;
    int fd = memfd_create("singularity-ime-popup", MFD_CLOEXEC);
    if (fd < 0) return;
    if (ftruncate(fd, (off_t) size) < 0) {
        close(fd);
        return;
    }
    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return;
    }
    memcpy(map, pixels, size);
    munmap(map, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t) size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride,
                                                         WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);

    wl_surface_set_buffer_scale(popup_surface, scale > 0 ? scale : 1);
    wl_surface_attach(popup_surface, buffer, 0, 0);
    wl_surface_damage_buffer(popup_surface, 0, 0, width, height);
    wl_surface_commit(popup_surface);
    wl_display_flush(display);
}

void singularity_ime_popup_hide(void) {
    if (popup_surface == NULL) return;
    wl_surface_attach(popup_surface, NULL, 0, 0);
    wl_surface_commit(popup_surface);
    wl_display_flush(display);
}
