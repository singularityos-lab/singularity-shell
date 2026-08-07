/*
 * lock_main.c - Singularity session lock (swaylock-style).
 *
 * A toolkit-less Wayland client that implements a real ext-session-lock-v1
 * locker: it locks the session, creates a lock surface per output (so the
 * compositor shows our UI instead of a blank screen), renders the lock UI with
 * Cairo, reads the keyboard with xkbcommon, and authenticates with PAM. This
 * replaces the previous GTK layer-shell approach, which conflicted with the
 * lock-surface role and left the screen black (#35).
 */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <poll.h>
#include <pwd.h>
#include <sys/mman.h>

#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <cairo/cairo.h>
#include <pango/pangocairo.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>

#include "ext-session-lock-v1-client-protocol.h"
#include "pam_auth.h"
#include "lock_media.h"
#include "loginui.h"

#define BTN_LEFT 0x110

static cairo_surface_t *bg_surface = NULL;
static cairo_surface_t *avatar_surface = NULL;

struct lock_output {
    struct wl_output *wl_output;
    uint32_t name;
    struct wl_surface *surface;
    struct ext_session_lock_surface_v1 *lock_surface;
    uint32_t width, height;
    bool configured;
    double mb_cx[3], mb_r[3], mb_cy;
    bool mb_valid;
    struct lock_output *next;
};

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static struct wl_pointer *pointer;
static struct lock_output *ptr_output;
static double ptr_x, ptr_y;
static struct ext_session_lock_manager_v1 *lock_manager;
static struct ext_session_lock_v1 *lock;
static struct lock_output *outputs;

static struct xkb_context *xkb_context;
static struct xkb_keymap *xkb_keymap;
static struct xkb_state *xkb_state;

static bool running = true;
static bool locked = false;
static char password[1024];
static size_t password_len = 0;
static char status_text[128] = "";
static bool status_error = false;
static char username[256] = "";

static void render_output(struct lock_output *o);

static void render_all(void) {
    for (struct lock_output *o = outputs; o; o = o->next)
        if (o->configured) render_output(o);
}

/* ── Rendering ──────────────────────────────────────────────────────────── */

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r) {
    double deg = 3.14159265 / 180.0;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r,     r, -90 * deg,   0);
    cairo_arc(cr, x + w - r, y + h - r, r,   0,        90 * deg);
    cairo_arc(cr, x + r,     y + h - r, r,  90 * deg,  180 * deg);
    cairo_arc(cr, x + r,     y + r,     r, 180 * deg,  270 * deg);
    cairo_close_path(cr);
}

static void load_assets(void) {
    char *uri = NULL;
    GSettingsSchemaSource *src = g_settings_schema_source_get_default();
    if (src && g_settings_schema_source_lookup(src, "dev.sinty.desktop", TRUE)) {
        GSettings *s = g_settings_new("dev.sinty.desktop");
        uri = g_settings_get_string(s, "background-picture-uri");
        g_object_unref(s);
    }
    if (uri && uri[0]) bg_surface = loginui_load_wallpaper(uri, 960);
    g_free(uri);

    char p[512];
    char *path = NULL;
    snprintf(p, sizeof p, "/var/lib/AccountsService/icons/%s", username);
    if (access(p, R_OK) == 0) path = p;
    if (!path) {
        snprintf(p, sizeof p, "/home/%s/.face", username);
        if (access(p, R_OK) == 0) path = p;
    }
    if (path) avatar_surface = loginui_load_avatar(path, 46);
}

static void draw_text_ellipsized(cairo_t *cr, const char *desc, const char *text,
                                 double x, double y, double max_w,
                                 double r, double g, double b) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *fd = pango_font_description_from_string(desc);
    pango_layout_set_font_description(layout, fd);
    pango_font_description_free(fd);
    pango_layout_set_text(layout, text, -1);
    pango_layout_set_width(layout, (int)(max_w * PANGO_SCALE));
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
    cairo_set_source_rgb(cr, r, g, b);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

/* kind: 0 prev, 1 play, 2 pause, 3 next */
static void media_button(cairo_t *cr, double cx, double cy, double r, int kind,
                         bool enabled, bool filled) {
    if (filled) {
        cairo_arc(cr, cx, cy, r, 0, 2 * 3.14159265);
        cairo_set_source_rgba(cr, 1, 1, 1, 0.14);
        cairo_fill(cr);
    }
    cairo_set_source_rgba(cr, 0.96, 0.96, 0.98, enabled ? 0.96 : 0.35);
    double s = r * (filled ? 0.42 : 0.5);
    switch (kind) {
    case 1:
        cairo_move_to(cr, cx - s * 0.7, cy - s);
        cairo_line_to(cr, cx - s * 0.7, cy + s);
        cairo_line_to(cr, cx + s, cy);
        cairo_close_path(cr);
        cairo_fill(cr);
        break;
    case 2:
        cairo_rectangle(cr, cx - s * 0.7, cy - s, s * 0.55, 2 * s);
        cairo_rectangle(cr, cx + s * 0.15, cy - s, s * 0.55, 2 * s);
        cairo_fill(cr);
        break;
    case 0:
        cairo_rectangle(cr, cx - s, cy - s, s * 0.35, 2 * s);
        cairo_fill(cr);
        cairo_move_to(cr, cx + s, cy - s);
        cairo_line_to(cr, cx + s, cy + s);
        cairo_line_to(cr, cx - s * 0.4, cy);
        cairo_close_path(cr);
        cairo_fill(cr);
        break;
    case 3:
        cairo_move_to(cr, cx - s, cy - s);
        cairo_line_to(cr, cx - s, cy + s);
        cairo_line_to(cr, cx + s * 0.4, cy);
        cairo_close_path(cr);
        cairo_fill(cr);
        cairo_rectangle(cr, cx + s * 0.65, cy - s, s * 0.35, 2 * s);
        cairo_fill(cr);
        break;
    }
}

static void render_media(cairo_t *cr, struct lock_output *o,
                         double card_x, double card_y, double card_w, double card_h) {
    const LockMediaState *m = lock_media_get();
    if (!m->has_player) { o->mb_valid = false; return; }

    double pad = 12, cover = 64;
    double px = card_x, pw = card_w;
    double ph = pad * 2 + cover;
    double py = card_y + card_h + 14;
    double cy = py + ph / 2.0;

    /* Card body: solid base, then the cover art as a dim, scaled background
     * with a dark veil (mirrors the sidebar media widget). */
    rounded_rect(cr, px, py, pw, ph, 18);
    cairo_set_source_rgba(cr, 0.176, 0.176, 0.176, 0.97);
    cairo_fill(cr);
    if (m->cover) {
        rounded_rect(cr, px, py, pw, ph, 18);
        cairo_save(cr);
        cairo_clip(cr);
        int cw = cairo_image_surface_get_width(m->cover);
        int chh = cairo_image_surface_get_height(m->cover);
        double sc = pw / (double)cw;
        if (ph / (double)chh > sc) sc = ph / (double)chh;
        cairo_translate(cr, px + (pw - cw * sc) / 2.0, py + (ph - chh * sc) / 2.0);
        cairo_scale(cr, sc, sc);
        cairo_set_source_surface(cr, m->cover, 0, 0);
        cairo_paint_with_alpha(cr, 0.20);
        cairo_restore(cr);
        rounded_rect(cr, px, py, pw, ph, 18);
        cairo_set_source_rgba(cr, 0, 0, 0, 0.50);
        cairo_fill(cr);
    }
    rounded_rect(cr, px + 0.5, py + 0.5, pw - 1, ph - 1, 18);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);

    /* Sharp cover thumbnail on the left. */
    double cx0 = px + pad, cy0 = py + pad;
    rounded_rect(cr, cx0, cy0, cover, cover, 10);
    cairo_save(cr);
    cairo_clip(cr);
    if (m->cover) {
        int cw = cairo_image_surface_get_width(m->cover);
        int chh = cairo_image_surface_get_height(m->cover);
        double sc = cover / (double)(cw < chh ? cw : chh);
        cairo_translate(cr, cx0 + (cover - cw * sc) / 2.0, cy0 + (cover - chh * sc) / 2.0);
        cairo_scale(cr, sc, sc);
        cairo_set_source_surface(cr, m->cover, 0, 0);
        cairo_paint(cr);
    } else {
        cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
        cairo_paint(cr);
    }
    cairo_restore(cr);

    /* Controls on the right, vertically centred (prev / play-pause / next). */
    double big = 17, small = 15;
    o->mb_r[2] = small; o->mb_cx[2] = px + pw - pad - small;
    o->mb_r[1] = big;   o->mb_cx[1] = o->mb_cx[2] - small - 6 - big;
    o->mb_r[0] = small; o->mb_cx[0] = o->mb_cx[1] - big - 6 - small;
    o->mb_cy = cy;
    o->mb_valid = true;
    media_button(cr, o->mb_cx[0], cy, small, 0, m->can_prev, false);
    media_button(cr, o->mb_cx[1], cy, big, m->playing ? 2 : 1, true, true);
    media_button(cr, o->mb_cx[2], cy, small, 3, m->can_next, false);

    /* Title + artist between the thumbnail and the controls, ellipsized. */
    double tx = cx0 + cover + 12;
    double tw = (o->mb_cx[0] - small - 8) - tx;
    if (tw < 20) tw = 20;
    const char *title = m->title[0] ? m->title : "Unknown";
    draw_text_ellipsized(cr, "Sans Bold 13", title, tx, cy - 21, tw, 0.96, 0.96, 0.98);
    if (m->artist[0])
        draw_text_ellipsized(cr, "Sans 11", m->artist, tx, cy + 1, tw, 0.78, 0.78, 0.82);
}

static void render_output(struct lock_output *o) {
    cairo_t *cr;
    struct loginui_buffer *b = loginui_create_buffer(shm, o->width, o->height, &cr);
    if (!b) return;

    time_t now = time(NULL);
    struct tm tm; localtime_r(&now, &tm);
    char tbuf[32], dbuf[64];
    strftime(tbuf, sizeof tbuf, "%H:%M", &tm);
    strftime(dbuf, sizeof dbuf, "%A, %B %e", &tm);

    LoginUiState st = {0};
    st.width = (int)o->width;
    st.height = (int)o->height;
    st.username = username[0] ? username : NULL;
    st.time_str = tbuf;
    st.date_str = dbuf;
    st.avatar = avatar_surface;
    st.background = bg_surface;
    st.password_dots = (int)password_len;
    st.status_text = status_text[0] ? status_text : NULL;
    st.status_error = status_error;
    /* On Sinty OS the unlock field takes a PIN, not a password (the recoverd
     * broker socket is the tell that we authenticate via the PIN daemon). */
    st.auth_label = (access("/run/sinty-recoverd.sock", F_OK) == 0) ? "PIN" : NULL;

    double card_x, card_y, card_w, card_h;
    loginui_render(cr, &st, &card_x, &card_y, &card_w, &card_h);

    render_media(cr, o, card_x, card_y, card_w, card_h);

    cairo_destroy(cr);

    wl_surface_attach(o->surface, b->wl_buffer, 0, 0);
    wl_surface_damage_buffer(o->surface, 0, 0, (int)o->width, (int)o->height);
    wl_surface_commit(o->surface);
}

/* ── ext-session-lock ───────────────────────────────────────────────────── */

static void lock_surface_configure(void *data, struct ext_session_lock_surface_v1 *s,
                                   uint32_t serial, uint32_t w, uint32_t h) {
    struct lock_output *o = data;
    o->width = w; o->height = h; o->configured = true;
    ext_session_lock_surface_v1_ack_configure(s, serial);
    render_output(o);
}
static const struct ext_session_lock_surface_v1_listener lock_surface_listener = {
    .configure = lock_surface_configure,
};

static void create_lock_surface(struct lock_output *o) {
    if (o->lock_surface || !lock) return;
    o->surface = wl_compositor_create_surface(compositor);
    o->lock_surface = ext_session_lock_v1_get_lock_surface(lock, o->surface, o->wl_output);
    ext_session_lock_surface_v1_add_listener(o->lock_surface, &lock_surface_listener, o);
}

static void lock_locked(void *data, struct ext_session_lock_v1 *l) {
    locked = true;
    for (struct lock_output *o = outputs; o; o = o->next) create_lock_surface(o);
}
static void lock_finished(void *data, struct ext_session_lock_v1 *l) {
    /* Compositor denied or ended the lock; nothing more we can do. */
    running = false;
}
static const struct ext_session_lock_v1_listener lock_listener = {
    .locked = lock_locked,
    .finished = lock_finished,
};

/* ── Auth ───────────────────────────────────────────────────────────────── */

static void submit_password(void) {
    if (password_len == 0) return;
    password[password_len] = '\0';
    snprintf(status_text, sizeof status_text, "%s", "Authenticating…");
    status_error = false;
    render_all();
    wl_display_flush(display);

    int rc = singularity_pam_authenticate(username, password);

    /* Wipe the password from memory regardless of outcome. */
    memset(password, 0, sizeof password);
    password_len = 0;

    if (rc == 0) {
        ext_session_lock_v1_unlock_and_destroy(lock);
        wl_display_roundtrip(display);
        running = false;
    } else {
        snprintf(status_text, sizeof status_text, "%s",
                 (access("/run/sinty-recoverd.sock", F_OK) == 0) ? "Incorrect PIN" : "Incorrect password");
        status_error = true;
        render_all();
    }
}

/* ── Keyboard ───────────────────────────────────────────────────────────── */

static void kb_keymap(void *data, struct wl_keyboard *kb, uint32_t format, int fd, uint32_t size) {
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) { close(fd); return; }
    char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return;
    if (xkb_keymap) xkb_keymap_unref(xkb_keymap);
    if (xkb_state) xkb_state_unref(xkb_state);
    xkb_keymap = xkb_keymap_new_from_string(xkb_context, map,
        XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    if (xkb_keymap) xkb_state = xkb_state_new(xkb_keymap);
}
static void kb_enter(void *d, struct wl_keyboard *kb, uint32_t s, struct wl_surface *sf, struct wl_array *keys) {}
static void kb_leave(void *d, struct wl_keyboard *kb, uint32_t s, struct wl_surface *sf) {}
static void kb_modifiers(void *d, struct wl_keyboard *kb, uint32_t s,
                         uint32_t dep, uint32_t lat, uint32_t lck, uint32_t grp) {
    if (xkb_state) xkb_state_update_mask(xkb_state, dep, lat, lck, 0, 0, grp);
}
static void kb_repeat(void *d, struct wl_keyboard *kb, int32_t rate, int32_t delay) {}

static void kb_key(void *data, struct wl_keyboard *kb, uint32_t serial,
                   uint32_t time, uint32_t key, uint32_t state) {
    if (!xkb_state || state != WL_KEYBOARD_KEY_STATE_PRESSED) return;
    xkb_keycode_t kc = key + 8;
    xkb_keysym_t sym = xkb_state_key_get_one_sym(xkb_state, kc);

    switch (sym) {
    case XKB_KEY_Return:
    case XKB_KEY_KP_Enter:
        submit_password();
        return;
    case XKB_KEY_BackSpace:
        if (password_len > 0) password[--password_len] = '\0';
        status_text[0] = '\0';
        render_all();
        return;
    case XKB_KEY_Escape:
        password_len = 0; password[0] = '\0'; status_text[0] = '\0';
        render_all();
        return;
    case XKB_KEY_XF86AudioPlay:
    case XKB_KEY_XF86AudioPause:
        lock_media_play_pause();
        return;
    case XKB_KEY_XF86AudioNext:
        lock_media_next();
        return;
    case XKB_KEY_XF86AudioPrev:
        lock_media_prev();
        return;
    default: break;
    }

    char buf[8];
    int n = xkb_state_key_get_utf8(xkb_state, kc, buf, sizeof buf);
    if (n > 0 && (unsigned char)buf[0] >= 0x20 && password_len + n < sizeof password - 1) {
        memcpy(password + password_len, buf, n);
        password_len += n;
        status_text[0] = '\0';
        render_all();
    }
}
static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = kb_keymap, .enter = kb_enter, .leave = kb_leave,
    .key = kb_key, .modifiers = kb_modifiers, .repeat_info = kb_repeat,
};

/* ── Pointer (media buttons) ─────────────────────────────────────────────── */

static void pt_enter(void *d, struct wl_pointer *p, uint32_t serial,
                     struct wl_surface *sf, wl_fixed_t sx, wl_fixed_t sy) {
    ptr_output = NULL;
    for (struct lock_output *o = outputs; o; o = o->next)
        if (o->surface == sf) { ptr_output = o; break; }
    ptr_x = wl_fixed_to_double(sx);
    ptr_y = wl_fixed_to_double(sy);
}
static void pt_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *sf) {
    ptr_output = NULL;
}
static void pt_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t sx, wl_fixed_t sy) {
    ptr_x = wl_fixed_to_double(sx);
    ptr_y = wl_fixed_to_double(sy);
}
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time,
                      uint32_t button, uint32_t btn_state) {
    if (button != BTN_LEFT || btn_state != WL_POINTER_BUTTON_STATE_PRESSED) return;
    if (!ptr_output || !ptr_output->mb_valid) return;
    for (int i = 0; i < 3; i++) {
        double r = ptr_output->mb_r[i] + 6;
        double dx = ptr_x - ptr_output->mb_cx[i];
        double dy = ptr_y - ptr_output->mb_cy;
        if (dx * dx + dy * dy <= r * r) {
            if (i == 0) lock_media_prev();
            else if (i == 1) lock_media_play_pause();
            else lock_media_next();
            break;
        }
    }
}
static void pt_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t axis, wl_fixed_t value) {}
static void pt_frame(void *d, struct wl_pointer *p) {}
static void pt_axis_source(void *d, struct wl_pointer *p, uint32_t src) {}
static void pt_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t axis) {}
static void pt_axis_discrete(void *d, struct wl_pointer *p, uint32_t axis, int32_t discrete) {}
static const struct wl_pointer_listener pointer_listener = {
    .enter = pt_enter, .leave = pt_leave, .motion = pt_motion, .button = pt_button,
    .axis = pt_axis, .frame = pt_frame, .axis_source = pt_axis_source,
    .axis_stop = pt_axis_stop, .axis_discrete = pt_axis_discrete,
};

/* ── Registry ───────────────────────────────────────────────────────────── */

static struct wl_registry *registry_global_obj;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    } else if (strcmp(iface, wl_shm_interface.name) == 0) {
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, ext_session_lock_manager_v1_interface.name) == 0) {
        lock_manager = wl_registry_bind(reg, name, &ext_session_lock_manager_v1_interface, 1);
    } else if (strcmp(iface, wl_seat_interface.name) == 0) {
        seat = wl_registry_bind(reg, name, &wl_seat_interface, version < 5 ? version : 5);
    } else if (strcmp(iface, wl_output_interface.name) == 0) {
        struct lock_output *o = calloc(1, sizeof(*o));
        o->name = name;
        o->wl_output = wl_registry_bind(reg, name, &wl_output_interface,
                                        version < 3 ? version : 3);
        o->next = outputs;
        outputs = o;
        if (locked) create_lock_surface(o);
    }
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    struct lock_output **pp = &outputs;
    while (*pp) {
        if ((*pp)->name == name) {
            struct lock_output *dead = *pp;
            *pp = dead->next;
            if (dead->lock_surface) ext_session_lock_surface_v1_destroy(dead->lock_surface);
            if (dead->surface) wl_surface_destroy(dead->surface);
            if (dead->wl_output) wl_output_destroy(dead->wl_output);
            free(dead);
            return;
        }
        pp = &(*pp)->next;
    }
}
static const struct wl_registry_listener registry_listener = { reg_global, reg_remove };

/* ── Main ───────────────────────────────────────────────────────────────── */

static void on_media_change(void) {
    render_all();
    if (display) wl_display_flush(display);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_name) snprintf(username, sizeof username, "%s", pw->pw_name);
    else { const char *u = getenv("USER"); if (u) snprintf(username, sizeof username, "%s", u); }

    load_assets();

    display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "lock: cannot connect to Wayland display\n"); return 1; }

    registry_global_obj = wl_display_get_registry(display);
    wl_registry_add_listener(registry_global_obj, &registry_listener, NULL);
    wl_display_roundtrip(display);

    if (!compositor || !shm || !lock_manager || !seat) {
        fprintf(stderr, "lock: compositor missing required globals (session-lock unsupported)\n");
        return 1;
    }

    xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    keyboard = wl_seat_get_keyboard(seat);
    if (keyboard) wl_keyboard_add_listener(keyboard, &keyboard_listener, NULL);
    pointer = wl_seat_get_pointer(seat);
    if (pointer) wl_pointer_add_listener(pointer, &pointer_listener, NULL);

    lock = ext_session_lock_manager_v1_lock(lock_manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    wl_display_roundtrip(display);

    /* MPRIS now-playing controls run on the GLib main context, which is
     * folded into the Wayland poll below so D-Bus signals are dispatched
     * without a second thread. */
    lock_media_init(on_media_change);

    GMainContext *ctx = g_main_context_default();
    int fd = wl_display_get_fd(display);
    int last_min = -1;
    GPollFD gfds[64];
    while (running) {
        while (wl_display_prepare_read(display) != 0)
            wl_display_dispatch_pending(display);
        wl_display_flush(display);

        gboolean acq = g_main_context_acquire(ctx);
        gint max_pri = 0, gl_timeout = -1;
        int nf = 0;
        if (acq) {
            g_main_context_prepare(ctx, &max_pri);
            nf = g_main_context_query(ctx, max_pri, &gl_timeout, gfds, 64);
        }

        struct pollfd pfds[65];
        pfds[0].fd = fd; pfds[0].events = POLLIN; pfds[0].revents = 0;
        for (int i = 0; i < nf; i++) {
            pfds[i + 1].fd = gfds[i].fd;
            pfds[i + 1].events = gfds[i].events;
            pfds[i + 1].revents = 0;
        }

        int timeout = 1000;
        if (gl_timeout >= 0 && gl_timeout < timeout) timeout = gl_timeout;

        int pr = poll(pfds, nf + 1, timeout);

        if (pr > 0 && (pfds[0].revents & POLLIN)) {
            wl_display_read_events(display);
        } else {
            wl_display_cancel_read(display);
        }
        wl_display_dispatch_pending(display);

        if (acq) {
            for (int i = 0; i < nf; i++) gfds[i].revents = pfds[i + 1].revents;
            g_main_context_check(ctx, max_pri, gfds, nf);
            g_main_context_dispatch(ctx);
            g_main_context_release(ctx);
        }

        /* Repaint clock once a minute. */
        time_t now = time(NULL);
        struct tm tm; localtime_r(&now, &tm);
        if (tm.tm_min != last_min) { last_min = tm.tm_min; render_all(); }
    }

    wl_display_roundtrip(display);
    return 0;
}
