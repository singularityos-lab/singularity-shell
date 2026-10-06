/*
 * vkbd.c - Type text into the focused window via a Wayland virtual keyboard.
 *
 * Binds zwp_virtual_keyboard_manager_v1 on the GDK display and creates a
 * virtual keyboard for the seat. Characters found in the user's layout are
 * typed with that layout's keys and modifiers, which Xwayland apps also
 * understand. Other characters get one generated xkb keymap whose keys map to
 * their Unicode codepoints, uploaded shortly before the keys are pressed. The
 * emoji picker and dictation use it to insert text into the focused app.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <xkbcommon/xkbcommon.h>

#include <wayland-client.h>
#include <glib.h>
#include <gdk/gdk.h>
#include <gdk/wayland/gdkwayland.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "vkbd.h"

static struct zwp_virtual_keyboard_manager_v1 *vk_manager = NULL;
static struct zwp_virtual_keyboard_v1 *vkbd = NULL;
static struct wl_display *wl_disp = NULL;
static uint32_t key_time = 0;

static void reg_global(void *data, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t ver) {
    (void) data; (void) ver;
    if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        vk_manager = wl_registry_bind(
            r, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}
static void reg_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void) data; (void) r; (void) name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

#define BATCH_KEYS 240

typedef struct {
    gunichar *chars;
    glong len;
    glong pos;
} TypeJob;

typedef struct {
    guint code;
    uint32_t mask;
} LayoutKey;

enum { UPLOADED_NONE, UPLOADED_LAYOUT, UPLOADED_CUSTOM };

static GQueue jobs = G_QUEUE_INIT;
static guint job_timer = 0;
static gunichar batch_keys[BATCH_KEYS];
static int batch_count = 0;
static glong run_end = 0;
static gboolean run_pending = FALSE;
static gboolean run_in_layout = FALSE;
static int uploaded = UPLOADED_NONE;
static struct xkb_context *xkb_ctx = NULL;
static char *layout_text = NULL;
static GHashTable *layout_keys = NULL;

static void keysym_name(gunichar cp, char *sym, size_t len) {
    if (cp == '\n' || cp == '\r') g_strlcpy(sym, "Return", len);
    else if (cp == '\t') g_strlcpy(sym, "Tab", len);
    else g_snprintf(sym, len, "U%04X", cp);
}

static int memfd_with(const char *text, size_t *size_out) {
    size_t size = strlen(text) + 1;
    int fd = memfd_create("singularity-vkbd-keymap", MFD_CLOEXEC);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t) size) < 0) { close(fd); return -1; }
    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { close(fd); return -1; }
    memcpy(map, text, size);
    munmap(map, size);
    *size_out = size;
    return fd;
}

static int make_keymap_fd(const gunichar *keys, int count, size_t *size_out) {
    GString *str = g_string_new("xkb_keymap {\nxkb_keycodes \"(unnamed)\" { minimum = 8; maximum = 255;\n");
    for (int i = 0; i < count; i++) g_string_append_printf(str, "<K%d> = %d;\n", i, i + 9);
    g_string_append(str, "};\nxkb_types \"(unnamed)\" { type \"ONE_LEVEL\" { modifiers = none; level_name[Level1] = \"Any\"; }; };\n"
                         "xkb_compatibility \"(unnamed)\" { };\nxkb_symbols \"(unnamed)\" {\n");
    for (int i = 0; i < count; i++) {
        char sym[16];
        keysym_name(keys[i], sym, sizeof sym);
        g_string_append_printf(str, "key <K%d> { [ %s ] };\n", i, sym);
    }
    g_string_append(str, "};\n};\n");
    int fd = memfd_with(str->str, size_out);
    g_string_free(str, TRUE);
    return fd;
}

void singularity_type_text_set_layout(const char *layout, const char *variant) {
    if (xkb_ctx == NULL) xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names names = {
        .layout = (layout != NULL && *layout != '\0') ? layout : "us",
        .variant = (variant != NULL && *variant != '\0') ? variant : NULL,
    };
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(xkb_ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == NULL) return;
    if (layout_keys != NULL) g_hash_table_unref(layout_keys);
    layout_keys = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_free);
    xkb_keycode_t min = xkb_keymap_min_keycode(keymap);
    xkb_keycode_t max = MIN(xkb_keymap_max_keycode(keymap), 255);
    for (xkb_keycode_t code = min; code <= max; code++) {
        xkb_level_index_t levels = xkb_keymap_num_levels_for_key(keymap, code, 0);
        for (xkb_level_index_t level = 0; level < levels; level++) {
            const xkb_keysym_t *syms = NULL;
            if (xkb_keymap_key_get_syms_by_level(keymap, code, 0, level, &syms) != 1) continue;
            gunichar cp = syms[0] == XKB_KEY_Return ? '\n' : syms[0] == XKB_KEY_Tab ? '\t' : xkb_keysym_to_utf32(syms[0]);
            if (cp == 0 || g_hash_table_contains(layout_keys, GUINT_TO_POINTER(cp))) continue;
            xkb_mod_mask_t masks[4];
            size_t count = xkb_keymap_key_get_mods_for_level(keymap, code, 0, level, masks, 4);
            if (count == 0) continue;
            LayoutKey *key = g_new0(LayoutKey, 1);
            key->code = code - 8;
            key->mask = masks[0];
            g_hash_table_insert(layout_keys, GUINT_TO_POINTER(cp), key);
        }
    }
    g_free(layout_text);
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    layout_text = g_strdup(text);
    free(text);
    xkb_keymap_unref(keymap);
    if (uploaded == UPLOADED_LAYOUT) uploaded = UPLOADED_NONE;
}

static LayoutKey *layout_key(gunichar cp) {
    if (layout_keys == NULL) return NULL;
    return g_hash_table_lookup(layout_keys, GUINT_TO_POINTER(cp == '\r' ? '\n' : cp));
}

static gboolean ensure_vkbd(void) {
    if (vkbd != NULL) return TRUE;
    GdkDisplay *gdk = gdk_display_get_default();
    if (gdk == NULL || !GDK_IS_WAYLAND_DISPLAY(gdk)) return FALSE;
    wl_disp = gdk_wayland_display_get_wl_display(gdk);
    if (wl_disp == NULL) return FALSE;
    if (vk_manager == NULL) {
        struct wl_registry *reg = wl_display_get_registry(wl_disp);
        wl_registry_add_listener(reg, &reg_listener, NULL);
        wl_display_roundtrip(wl_disp);
    }
    if (vk_manager == NULL) {
        g_warning("vkbd: compositor has no virtual keyboard manager");
        return FALSE;
    }
    GdkSeat *gseat = gdk_display_get_default_seat(gdk);
    if (gseat == NULL) return FALSE;
    struct wl_seat *seat = gdk_wayland_seat_get_wl_seat(gseat);
    if (seat == NULL) return FALSE;
    vkbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vk_manager, seat);
    return vkbd != NULL;
}

static int batch_index(gunichar cp) {
    for (int i = 0; i < batch_count; i++) {
        if (batch_keys[i] == cp) return i;
    }
    return -1;
}

static gboolean run_job(gpointer data);

static void schedule(guint ms) {
    job_timer = g_timeout_add(ms, run_job, NULL);
}

static gboolean upload_layout(void) {
    size_t size = 0;
    int fd = memfd_with(layout_text, &size);
    if (fd < 0) return FALSE;
    zwp_virtual_keyboard_v1_keymap(vkbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t) size);
    close(fd);
    zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
    wl_display_flush(wl_disp);
    uploaded = UPLOADED_LAYOUT;
    return TRUE;
}

static gboolean upload_custom(TypeJob *job) {
    batch_count = 0;
    glong end = job->pos;
    while (end < job->len && layout_key(job->chars[end]) == NULL) {
        if (batch_index(job->chars[end]) < 0) {
            if (batch_count == BATCH_KEYS) break;
            batch_keys[batch_count++] = job->chars[end];
        }
        end++;
    }
    run_end = end;
    size_t size = 0;
    int fd = make_keymap_fd(batch_keys, batch_count, &size);
    if (fd < 0) return FALSE;
    zwp_virtual_keyboard_v1_keymap(vkbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t) size);
    close(fd);
    zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
    wl_display_flush(wl_disp);
    uploaded = UPLOADED_CUSTOM;
    return TRUE;
}

static void press(guint code, uint32_t mask) {
    zwp_virtual_keyboard_v1_modifiers(vkbd, mask, 0, 0, 0);
    zwp_virtual_keyboard_v1_key(vkbd, key_time++, code, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_key(vkbd, key_time++, code, WL_KEYBOARD_KEY_STATE_RELEASED);
    if (mask != 0) zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
}

static void press_run(TypeJob *job) {
    for (glong i = job->pos; i < run_end; i++) {
        if (run_in_layout) {
            LayoutKey *key = layout_key(job->chars[i]);
            if (key != NULL) press(key->code, key->mask);
        } else {
            int index = batch_index(job->chars[i]);
            if (index >= 0) press((guint) index + 1, 0);
        }
    }
    job->pos = run_end;
    wl_display_flush(wl_disp);
}

static gboolean run_job(gpointer data) {
    (void) data;
    job_timer = 0;
    TypeJob *job = g_queue_peek_head(&jobs);
    if (job == NULL) return G_SOURCE_REMOVE;
    if (run_pending) {
        run_pending = FALSE;
        press_run(job);
    } else if (job->pos < job->len) {
        if (layout_key(job->chars[job->pos]) != NULL && layout_text != NULL) {
            glong end = job->pos;
            while (end < job->len && layout_key(job->chars[end]) != NULL) end++;
            run_end = end;
            run_in_layout = TRUE;
            if (uploaded != UPLOADED_LAYOUT && upload_layout()) {
                run_pending = TRUE;
                schedule(40);
                return G_SOURCE_REMOVE;
            }
            press_run(job);
        } else {
            run_in_layout = FALSE;
            if (!upload_custom(job)) {
                job->pos = job->len;
            } else {
                run_pending = TRUE;
                schedule(40);
                return G_SOURCE_REMOVE;
            }
        }
    }
    if (job->pos >= job->len) {
        g_queue_pop_head(&jobs);
        g_free(job->chars);
        g_free(job);
    }
    if (!g_queue_is_empty(&jobs)) schedule(10);
    return G_SOURCE_REMOVE;
}

void singularity_type_text(const char *utf8) {
    if (utf8 == NULL || *utf8 == '\0') return;
    if (!ensure_vkbd()) return;
    TypeJob *job = g_new0(TypeJob, 1);
    job->chars = g_utf8_to_ucs4_fast(utf8, -1, &job->len);
    g_queue_push_tail(&jobs, job);
    if (job_timer == 0 && g_queue_get_length(&jobs) == 1) run_job(NULL);
}
