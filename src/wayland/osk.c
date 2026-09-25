#define _GNU_SOURCE
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

#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "osk.h"

static struct zwp_virtual_keyboard_manager_v1 *manager = NULL;
static struct zwp_virtual_keyboard_v1 *keyboard = NULL;
static struct wl_display *display = NULL;
static struct xkb_context *context = NULL;
static struct xkb_keymap *keymap = NULL;
static struct xkb_state *label_state = NULL;
static uint32_t key_time = 0;

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *iface, uint32_t version) {
    (void) data; (void) version;
    if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void) data; (void) registry; (void) name;
}

static const struct wl_registry_listener registry_listener = { registry_global, registry_remove };

static gboolean ensure_keyboard(void) {
    if (keyboard != NULL) return TRUE;
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
    if (seat == NULL) return FALSE;
    keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    return keyboard != NULL;
}

gboolean singularity_osk_set_layout(const char *layout, const char *variant) {
    if (!ensure_keyboard()) return FALSE;
    if (context == NULL) context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names names = {
        .layout = (layout != NULL && *layout != '\0') ? layout : "us",
        .variant = (variant != NULL && *variant != '\0') ? variant : NULL,
    };
    struct xkb_keymap *next = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (next == NULL) return FALSE;
    char *text = xkb_keymap_get_as_string(next, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("singularity-osk-keymap", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t) size) < 0) {
        if (fd >= 0) close(fd);
        free(text);
        xkb_keymap_unref(next);
        return FALSE;
    }
    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        free(text);
        xkb_keymap_unref(next);
        return FALSE;
    }
    memcpy(map, text, size);
    munmap(map, size);
    free(text);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t) size);
    close(fd);
    wl_display_flush(display);

    if (label_state != NULL) xkb_state_unref(label_state);
    if (keymap != NULL) xkb_keymap_unref(keymap);
    keymap = next;
    label_state = xkb_state_new(keymap);
    return TRUE;
}

static uint32_t modifier_bit(const char *name) {
    if (keymap == NULL) return 0;
    xkb_mod_index_t index = xkb_keymap_mod_get_index(keymap, name);
    return index == XKB_MOD_INVALID ? 0 : (1u << index);
}

static uint32_t modifier_mask(guint modifiers) {
    uint32_t mask = 0;
    if (modifiers & SINGULARITY_OSK_SHIFT) mask |= modifier_bit(XKB_MOD_NAME_SHIFT);
    if (modifiers & SINGULARITY_OSK_CTRL) mask |= modifier_bit(XKB_MOD_NAME_CTRL);
    if (modifiers & SINGULARITY_OSK_ALT) mask |= modifier_bit(XKB_MOD_NAME_ALT);
    if (modifiers & SINGULARITY_OSK_SUPER) mask |= modifier_bit(XKB_MOD_NAME_LOGO);
    return mask;
}

void singularity_osk_press(guint evdev_code, guint modifiers) {
    if (keyboard == NULL || keymap == NULL) return;
    uint32_t mask = modifier_mask(modifiers);
    zwp_virtual_keyboard_v1_modifiers(keyboard, mask, 0, 0, 0);
    zwp_virtual_keyboard_v1_key(keyboard, key_time++, evdev_code, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_key(keyboard, key_time++, evdev_code, WL_KEYBOARD_KEY_STATE_RELEASED);
    zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
    wl_display_flush(display);
}

char *singularity_osk_label(guint evdev_code, gboolean shifted) {
    if (keymap == NULL || label_state == NULL) return NULL;
    xkb_state_update_mask(label_state, shifted ? modifier_bit(XKB_MOD_NAME_SHIFT) : 0, 0, 0, 0, 0, 0);
    xkb_keysym_t sym = xkb_state_key_get_one_sym(label_state, evdev_code + 8);
    uint32_t cp = xkb_keysym_to_utf32(sym);
    if (cp == 0 || cp < 0x20) return NULL;
    char buffer[8] = { 0 };
    g_unichar_to_utf8(cp, buffer);
    return g_strdup(buffer);
}
