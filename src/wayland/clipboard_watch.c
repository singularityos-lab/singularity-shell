#define _GNU_SOURCE
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <linux/input-event-codes.h>

#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <gio/gio.h>
#include <gio/gunixinputstream.h>
#include <gio/gunixoutputstream.h>
#include <gdk/gdk.h>
#include <gdk/wayland/gdkwayland.h>

#include "ext-data-control-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "clipboard_watch.h"

#define MAX_TEXT (4 * 1024 * 1024)
#define MAX_IMAGE (24 * 1024 * 1024)

static struct wl_display *display = NULL;
static struct ext_data_control_manager_v1 *manager = NULL;
static struct ext_data_control_device_v1 *device = NULL;
static struct zwp_virtual_keyboard_manager_v1 *vk_manager = NULL;
static struct zwp_virtual_keyboard_v1 *vkbd = NULL;
static SingularityClipboardFunc callback = NULL;
static gpointer callback_data = NULL;
static struct ext_data_control_source_v1 *own_source = NULL;
static GBytes *own_data = NULL;
static char *own_mime = NULL;
static uint32_t vk_time = 0;

typedef struct {
    GPtrArray *mimes;
} OfferInfo;

typedef struct {
    char *mime;
    GByteArray *buf;
    gsize limit;
    GInputStream *stream;
} ReadJob;

static void offer_mime(void *data, struct ext_data_control_offer_v1 *offer, const char *mime) {
    (void) offer;
    OfferInfo *info = data;
    g_ptr_array_add(info->mimes, g_strdup(mime));
}

static const struct ext_data_control_offer_v1_listener offer_listener = { offer_mime };

static void free_offer(struct ext_data_control_offer_v1 *offer) {
    OfferInfo *info = ext_data_control_offer_v1_get_user_data(offer);
    if (info != NULL) {
        g_ptr_array_unref(info->mimes);
        g_free(info);
    }
    ext_data_control_offer_v1_destroy(offer);
}

static void device_data_offer(void *data, struct ext_data_control_device_v1 *dev,
                              struct ext_data_control_offer_v1 *offer) {
    (void) data; (void) dev;
    OfferInfo *info = g_new0(OfferInfo, 1);
    info->mimes = g_ptr_array_new_with_free_func(g_free);
    ext_data_control_offer_v1_add_listener(offer, &offer_listener, info);
}

static gboolean has_mime(OfferInfo *info, const char *mime) {
    for (guint i = 0; i < info->mimes->len; i++) {
        if (g_strcmp0(g_ptr_array_index(info->mimes, i), mime) == 0) return TRUE;
    }
    return FALSE;
}

static const char *pick_mime(OfferInfo *info) {
    static const char *images[] = { "image/png", "image/jpeg", "image/bmp", NULL };
    static const char *texts[] = { "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT", NULL };
    for (int i = 0; texts[i] != NULL; i++) {
        if (has_mime(info, texts[i])) {
            for (int j = 0; images[j] != NULL; j++) {
                if (has_mime(info, images[j]) && !has_mime(info, "text/uri-list")) return images[j];
            }
            return texts[i];
        }
    }
    for (int j = 0; images[j] != NULL; j++) {
        if (has_mime(info, images[j])) return images[j];
    }
    return NULL;
}

static void read_job_free(ReadJob *job) {
    g_free(job->mime);
    if (job->buf) g_byte_array_unref(job->buf);
    g_clear_object(&job->stream);
    g_free(job);
}

static void on_read(GObject *src, GAsyncResult *res, gpointer user_data) {
    ReadJob *job = user_data;
    GError *error = NULL;
    GBytes *chunk = g_input_stream_read_bytes_finish(G_INPUT_STREAM(src), res, &error);
    if (chunk == NULL) {
        g_debug("clipboard: read failed: %s", error ? error->message : "unknown");
        g_clear_error(&error);
        read_job_free(job);
        return;
    }
    gsize size = g_bytes_get_size(chunk);
    if (size > 0) {
        if (job->buf->len + size > job->limit) {
            g_debug("clipboard: %s is larger than the limit, skipped", job->mime);
            g_bytes_unref(chunk);
            read_job_free(job);
            return;
        }
        g_byte_array_append(job->buf, g_bytes_get_data(chunk, NULL), size);
        g_bytes_unref(chunk);
        g_input_stream_read_bytes_async(job->stream, 65536, G_PRIORITY_DEFAULT, NULL, on_read, job);
        return;
    }
    g_bytes_unref(chunk);
    if (job->buf->len > 0 && callback != NULL) {
        GBytes *bytes = g_byte_array_free_to_bytes(job->buf);
        job->buf = NULL;
        callback(job->mime, bytes, FALSE, callback_data);
        g_bytes_unref(bytes);
    }
    read_job_free(job);
}

static void device_selection(void *data, struct ext_data_control_device_v1 *dev,
                             struct ext_data_control_offer_v1 *offer) {
    (void) data; (void) dev;
    if (offer == NULL) return;
    OfferInfo *info = ext_data_control_offer_v1_get_user_data(offer);
    if (info == NULL) {
        ext_data_control_offer_v1_destroy(offer);
        return;
    }
    if (has_mime(info, "x-kde-passwordManagerHint")) {
        if (callback != NULL) callback("x-kde-passwordManagerHint", NULL, TRUE, callback_data);
        free_offer(offer);
        return;
    }
    const char *mime = pick_mime(info);
    if (mime == NULL) {
        free_offer(offer);
        return;
    }
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) != 0) {
        free_offer(offer);
        return;
    }
    ReadJob *job = g_new0(ReadJob, 1);
    job->mime = g_strdup(mime);
    job->limit = g_str_has_prefix(mime, "image/") ? MAX_IMAGE : MAX_TEXT;
    job->buf = g_byte_array_new();
    ext_data_control_offer_v1_receive(offer, mime, fds[1]);
    close(fds[1]);
    wl_display_flush(display);
    job->stream = g_unix_input_stream_new(fds[0], TRUE);
    g_input_stream_read_bytes_async(job->stream, 65536, G_PRIORITY_DEFAULT, NULL, on_read, job);
    free_offer(offer);
}

static void device_finished(void *data, struct ext_data_control_device_v1 *dev) {
    (void) data;
    ext_data_control_device_v1_destroy(dev);
    if (dev == device) device = NULL;
}

static void device_primary(void *data, struct ext_data_control_device_v1 *dev,
                           struct ext_data_control_offer_v1 *offer) {
    (void) data; (void) dev;
    if (offer != NULL) free_offer(offer);
}

static const struct ext_data_control_device_v1_listener device_listener = {
    device_data_offer, device_selection, device_finished, device_primary,
};

static void reg_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    (void) data; (void) ver;
    if (strcmp(iface, ext_data_control_manager_v1_interface.name) == 0) {
        manager = wl_registry_bind(r, name, &ext_data_control_manager_v1_interface, 1);
    } else if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        vk_manager = wl_registry_bind(r, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}

static void reg_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void) data; (void) r; (void) name;
}

static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static struct wl_seat *gdk_seat(void) {
    GdkDisplay *gdk = gdk_display_get_default();
    if (gdk == NULL) return NULL;
    GdkSeat *seat = gdk_display_get_default_seat(gdk);
    return seat != NULL ? gdk_wayland_seat_get_wl_seat(seat) : NULL;
}

static gboolean ensure_globals(void) {
    if (display != NULL) return manager != NULL;
    GdkDisplay *gdk = gdk_display_get_default();
    if (gdk == NULL || !GDK_IS_WAYLAND_DISPLAY(gdk)) return FALSE;
    display = gdk_wayland_display_get_wl_display(gdk);
    if (display == NULL) return FALSE;
    struct wl_registry *reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(display);
    return manager != NULL;
}

gboolean singularity_clipboard_watch_available(void) {
    return ensure_globals();
}

gboolean singularity_clipboard_watch_start(SingularityClipboardFunc func, gpointer user_data) {
    callback = func;
    callback_data = user_data;
    if (!ensure_globals()) {
        g_message("clipboard: the compositor has no ext-data-control-v1, clipboard history is limited");
        return FALSE;
    }
    if (device != NULL) return TRUE;
    struct wl_seat *seat = gdk_seat();
    if (seat == NULL) return FALSE;
    device = ext_data_control_manager_v1_get_data_device(manager, seat);
    ext_data_control_device_v1_add_listener(device, &device_listener, NULL);
    wl_display_flush(display);
    return TRUE;
}

static void source_send(void *data, struct ext_data_control_source_v1 *src, const char *mime, int32_t fd) {
    (void) data; (void) mime;
    if (src != own_source || own_data == NULL) {
        close(fd);
        return;
    }
    GOutputStream *out = g_unix_output_stream_new(fd, TRUE);
    gsize len = 0;
    const guint8 *bytes = g_bytes_get_data(own_data, &len);
    g_output_stream_write_all_async(out, bytes, len, G_PRIORITY_DEFAULT, NULL, NULL, NULL);
    g_object_set_data_full(G_OBJECT(out), "payload", g_bytes_ref(own_data), (GDestroyNotify) g_bytes_unref);
    g_output_stream_close_async(out, G_PRIORITY_DEFAULT, NULL, NULL, NULL);
    g_object_unref(out);
}

static void source_cancelled(void *data, struct ext_data_control_source_v1 *src) {
    (void) data;
    if (src == own_source) {
        own_source = NULL;
        g_clear_pointer(&own_data, g_bytes_unref);
        g_clear_pointer(&own_mime, g_free);
    }
    ext_data_control_source_v1_destroy(src);
}

static const struct ext_data_control_source_v1_listener source_listener = { source_send, source_cancelled };

gboolean singularity_clipboard_set(const char *mime, GBytes *data) {
    if (!ensure_globals() || device == NULL || mime == NULL || data == NULL) return FALSE;
    struct ext_data_control_source_v1 *src = ext_data_control_manager_v1_create_data_source(manager);
    ext_data_control_source_v1_add_listener(src, &source_listener, NULL);
    if (g_str_has_prefix(mime, "image/")) {
        ext_data_control_source_v1_offer(src, mime);
    } else {
        ext_data_control_source_v1_offer(src, "text/plain;charset=utf-8");
        ext_data_control_source_v1_offer(src, "text/plain");
        ext_data_control_source_v1_offer(src, "UTF8_STRING");
        ext_data_control_source_v1_offer(src, "STRING");
        ext_data_control_source_v1_offer(src, "TEXT");
    }
    if (own_source != NULL) ext_data_control_source_v1_destroy(own_source);
    g_clear_pointer(&own_data, g_bytes_unref);
    g_free(own_mime);
    own_source = src;
    own_data = g_bytes_ref(data);
    own_mime = g_strdup(mime);
    ext_data_control_device_v1_set_selection(device, src);
    wl_display_flush(display);
    return TRUE;
}

static int keymap_fd(size_t *size_out) {
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (ctx == NULL) return -1;
    struct xkb_rule_names names = { "evdev", "pc105", "us", "", "" };
    struct xkb_keymap *km = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (km == NULL) {
        xkb_context_unref(ctx);
        return -1;
    }
    char *str = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
    xkb_keymap_unref(km);
    xkb_context_unref(ctx);
    if (str == NULL) return -1;
    size_t size = strlen(str) + 1;
    int fd = memfd_create("singularity-paste-keymap", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t) size) < 0) {
        if (fd >= 0) close(fd);
        free(str);
        return -1;
    }
    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        free(str);
        return -1;
    }
    memcpy(map, str, size);
    munmap(map, size);
    free(str);
    *size_out = size;
    return fd;
}

gboolean singularity_clipboard_send_paste(void) {
    ensure_globals();
    if (display == NULL || vk_manager == NULL) return FALSE;
    if (vkbd == NULL) {
        struct wl_seat *seat = gdk_seat();
        if (seat == NULL) return FALSE;
        vkbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vk_manager, seat);
    }
    size_t size = 0;
    int fd = keymap_fd(&size);
    if (fd < 0) return FALSE;
    zwp_virtual_keyboard_v1_keymap(vkbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t) size);
    close(fd);
    const uint32_t ctrl_mask = 1u << 2;
    zwp_virtual_keyboard_v1_key(vkbd, vk_time++, KEY_LEFTCTRL, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_modifiers(vkbd, ctrl_mask, 0, 0, 0);
    zwp_virtual_keyboard_v1_key(vkbd, vk_time++, KEY_V, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_key(vkbd, vk_time++, KEY_V, WL_KEYBOARD_KEY_STATE_RELEASED);
    zwp_virtual_keyboard_v1_key(vkbd, vk_time++, KEY_LEFTCTRL, WL_KEYBOARD_KEY_STATE_RELEASED);
    zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
    wl_display_flush(display);
    return TRUE;
}
