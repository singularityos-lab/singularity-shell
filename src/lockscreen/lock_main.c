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
#include <math.h>
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
#include "lock_notifs.h"
#include "lock_fprint.h"
#include "loginui.h"
#include <sinty-system/v1.h>

#define BTN_LEFT 0x110

static cairo_surface_t *bg_surface = NULL;
static cairo_surface_t *bg_sharp_surface = NULL;
static cairo_surface_t *avatar_surface = NULL;

#define MOTION_SMALL_MS 140.0
#define MOTION_LARGE_MS 320.0
#define MOTION_PAGE_MS 380.0
#define LOCK_CLOCK_DROP 8.0
#define SHAKE_VELOCITY 520.0
#define BOUNCY_DAMPING 14.0
#define BOUNCY_STIFFNESS 300.0
#define SHAKE_REST_PX 0.4

enum lock_phase { PHASE_IDLE, PHASE_ENTER, PHASE_LEAVE };

static enum lock_phase anim_phase = PHASE_IDLE;
static int64_t anim_start = -1;
static double anim_ms = 0.0;
static int64_t shake_start = -1;
static bool motion_reduced = false;
static double motion_scale = 1.0;

struct lock_output {
    struct wl_output *wl_output;
    uint32_t name;
    struct wl_surface *surface;
    struct ext_session_lock_surface_v1 *lock_surface;
    uint32_t width, height;
    int32_t scale;
    bool configured;
    struct loginui_buffer *pool[2];
    double mb_cx[3], mb_r[3], mb_cy;
    bool mb_valid;
    struct wl_callback *frame_cb;
    struct lock_output *next;
};

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static struct wl_pointer *pointer;
static struct wl_touch *touch;
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
static char display_name[256] = "";
static bool auth_broker = false;
static bool auth_pin = false;

static LoginUiKeypad keypad;
static LoginUiPattern pattern;
static SintyUnlockState quick = {0};
static bool pattern_mode = false;
static int keypad_page = -1;
static LoginUiGesture gesture;
static bool keypad_shown = false;
static int surface_h = 0;

static void render_output(struct lock_output *o);

static void render_all(void) {
    for (struct lock_output *o = outputs; o; o = o->next)
        if (o->configured) render_output(o);
}

/* ── Rendering ──────────────────────────────────────────────────────────── */

#define PANEL_RADIUS 16

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
    if (uri && uri[0]) {
        bg_surface = loginui_load_wallpaper(uri, 960);
        bg_sharp_surface = loginui_load_image(
            g_str_has_prefix(uri, "file://") ? uri + 7 : uri, 1920, 1920);
    }
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
                                 LoginUiColor color) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *fd = pango_font_description_from_string(desc);
    pango_layout_set_font_description(layout, fd);
    pango_font_description_free(fd);
    pango_layout_set_text(layout, text, -1);
    pango_layout_set_width(layout, (int)(max_w * PANGO_SCALE));
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
    loginui_set_color(cr, color);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

/* kind: 0 prev, 1 play, 2 pause, 3 next */
static void media_button(cairo_t *cr, double cx, double cy, double r, int kind,
                         bool enabled, bool filled) {
    const LoginUiStyle *style = loginui_style();
    if (filled) {
        cairo_arc(cr, cx, cy, r, 0, 2 * 3.14159265);
        loginui_set_color(cr, style->key_pressed);
        cairo_fill(cr);
    }
    LoginUiColor glyph = style->text;
    if (!enabled) glyph.a = 0.35;
    loginui_set_color(cr, glyph);
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
    const LoginUiStyle *style = loginui_style();
    loginui_surface(cr, px, py, pw, ph, PANEL_RADIUS);
    if (m->cover) {
        rounded_rect(cr, px, py, pw, ph, PANEL_RADIUS);
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
        rounded_rect(cr, px, py, pw, ph, PANEL_RADIUS);
        cairo_set_source_rgba(cr, 0, 0, 0, 0.50);
        cairo_fill(cr);
    }
    rounded_rect(cr, px + 0.5, py + 0.5, pw - 1, ph - 1, PANEL_RADIUS);
    loginui_set_color(cr, style->border);
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
        loginui_set_color(cr, style->card);
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
    draw_text_ellipsized(cr, "Sans Bold 13", title, tx, cy - 21, tw, style->text);
    if (m->artist[0])
        draw_text_ellipsized(cr, "Sans 11", m->artist, tx, cy + 1, tw, style->dim);
}

static void render_notifs(cairo_t *cr, struct lock_output *o, double x, double y, double w) {
    const LockNotifsState *ns = lock_notifs_get();
    double row_h = 64, gap = 8, pad = 12;
    const LoginUiStyle *style = loginui_style();
    for (int i = 0; i < ns->count; i++) {
        if (y + row_h > o->height - 16) break;
        const LockNotification *n = &ns->items[i];
        loginui_surface(cr, x, y, w, row_h, PANEL_RADIUS);
        char when[16] = "";
        time_t t = (time_t) n->timestamp;
        struct tm tm;
        localtime_r(&t, &tm);
        strftime(when, sizeof when, "%H:%M", &tm);
        draw_text_ellipsized(cr, "Sans Bold 9", n->app_name, x + pad, y + 7, w - pad * 2 - 44, style->dim);
        draw_text_ellipsized(cr, "Sans 9", when, x + w - pad - 40, y + 7, 40, style->dim);
        draw_text_ellipsized(cr, "Sans Bold 11", n->summary, x + pad, y + 22, w - pad * 2, style->text);
        if (n->body[0])
            draw_text_ellipsized(cr, "Sans 10", n->body, x + pad, y + 39, w - pad * 2, style->dim);
        y += row_h + gap;
    }
}

static void load_motion(void) {
    GSettingsSchemaSource *src = g_settings_schema_source_get_default();
    if (!src) return;
    GSettingsSchema *schema = g_settings_schema_source_lookup(src, "dev.sinty.desktop", TRUE);
    if (schema) {
        GSettings *s = g_settings_new("dev.sinty.desktop");
        if (g_settings_schema_has_key(schema, "reduce-motion"))
            motion_reduced = g_settings_get_boolean(s, "reduce-motion");
        if (g_settings_schema_has_key(schema, "motion-duration-scale")) {
            double scale = g_settings_get_double(s, "motion-duration-scale");
            if (scale > 0.0) motion_scale = scale;
        }
        g_object_unref(s);
        g_settings_schema_unref(schema);
    }
    schema = g_settings_schema_source_lookup(src, "org.gnome.desktop.interface", TRUE);
    if (schema) {
        if (g_settings_schema_has_key(schema, "enable-animations")) {
            GSettings *s = g_settings_new("org.gnome.desktop.interface");
            if (!g_settings_get_boolean(s, "enable-animations")) motion_reduced = true;
            g_object_unref(s);
        }
        g_settings_schema_unref(schema);
    }
}

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static double bezier_axis(double a, double b, double t) {
    double u = 1.0 - t;
    return 3.0 * u * u * t * a + 3.0 * u * t * t * b + t * t * t;
}

static double bezier_ease(double x1, double y1, double x2, double y2, double x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    double lo = 0.0, hi = 1.0, t = x;
    for (int i = 0; i < 32; i++) {
        double value = bezier_axis(x1, x2, t);
        if (fabs(value - x) < 1e-6) break;
        if (value < x) lo = t; else hi = t;
        t = (lo + hi) / 2.0;
    }
    return bezier_axis(y1, y2, t);
}

static double ease_standard(double t) {
    return bezier_ease(0.2, 0.0, 0.0, 1.0, t);
}

static void start_phase(enum lock_phase phase, double ms) {
    anim_phase = phase;
    anim_start = -1;
    anim_ms = motion_reduced ? MOTION_SMALL_MS : ms;
    anim_ms *= motion_scale;
}

static double shake_offset(int64_t now) {
    if (shake_start < 0) return 0.0;
    double t = (now - shake_start) / 1000000.0 / motion_scale;
    double omega = sqrt(BOUNCY_STIFFNESS);
    double zeta = BOUNCY_DAMPING / (2.0 * omega);
    double omega_d = omega * sqrt(1.0 - zeta * zeta);
    double envelope = SHAKE_VELOCITY / omega_d * exp(-zeta * omega * t);
    if (envelope < SHAKE_REST_PX) {
        shake_start = -1;
        return 0.0;
    }
    return -envelope * sin(omega_d * t);
}

static void unlock_session(void);

static bool apply_motion(LoginUiState *st) {
    int64_t now = now_us();
    bool animating = false;
    st->background_sharp = bg_sharp_surface;
    if (anim_phase != PHASE_IDLE) {
        if (anim_start < 0) anim_start = now;
        double t = anim_ms > 0.0 ? (now - anim_start) / 1000.0 / anim_ms : 1.0;
        if (t > 1.0) t = 1.0;
        double p = motion_reduced ? t : ease_standard(t);
        if (anim_phase == PHASE_ENTER) {
            st->sharpness = 1.0 - p;
            st->content_fade = 1.0 - p;
            st->clock_dy = motion_reduced ? 0.0 : -LOCK_CLOCK_DROP * (1.0 - p);
        } else {
            st->sharpness = p;
            st->content_fade = p;
        }
        if (t >= 1.0) {
            if (anim_phase == PHASE_LEAVE) st->content_fade = 1.0;
            else anim_phase = PHASE_IDLE;
        } else {
            animating = true;
        }
    }
    st->card_dx = shake_offset(now);
    if (shake_start >= 0) animating = true;
    return animating;
}

static void frame_done(void *data, struct wl_callback *cb, uint32_t time) {
    struct lock_output *o = data;
    wl_callback_destroy(cb);
    o->frame_cb = NULL;
    if (anim_phase == PHASE_LEAVE && anim_start >= 0
            && (now_us() - anim_start) / 1000.0 >= anim_ms) {
        anim_phase = PHASE_IDLE;
        unlock_session();
        return;
    }
    render_output(o);
}
static const struct wl_callback_listener frame_listener = { .done = frame_done };

static bool secret_is_pin(void) {
    char tier[32] = {0};
    FILE *f = fopen("/run/sinty-key/tier", "re");
    if (f) {
        bool tpm = fgets(tier, sizeof tier, f) && strncmp(tier, "tpm", 3) == 0;
        fclose(f);
        return tpm;
    }
    return access("/dev/tpmrm0", F_OK) == 0 || access("/dev/tpm0", F_OK) == 0;
}

static double now_s(void) {
    return now_us() / 1000000.0;
}

static void render_output(struct lock_output *o) {
    if (o->frame_cb) return;
    int s = o->scale > 0 ? o->scale : 1;
    cairo_t *cr;
    struct loginui_buffer *b = loginui_pool_buffer(shm, o->pool, 2, o->width * s, o->height * s, &cr);
    if (!b) return;
    cairo_scale(cr, s, s);

    time_t now = time(NULL);
    struct tm tm; localtime_r(&now, &tm);
    char tbuf[32], dbuf[64];
    strftime(tbuf, sizeof tbuf, "%H:%M", &tm);
    strftime(dbuf, sizeof dbuf, "%A, %B %e", &tm);

    LoginUiState st = {0};
    st.width = (int)o->width;
    st.height = (int)o->height;
    st.username = display_name[0] ? display_name : (username[0] ? username : NULL);
    st.time_str = tbuf;
    st.date_str = dbuf;
    st.avatar = avatar_surface;
    st.background = bg_surface;
    st.password_dots = loginui_password_chars(password, password_len);
    st.status_text = status_text[0] ? status_text : NULL;
    st.status_error = status_error;
    /* On Sinty OS the unlock field takes a PIN, not a password (the recoverd
     * broker socket is the tell that we authenticate via the PIN daemon). */
    st.auth_label = auth_broker ? (pattern_mode ? "Pattern" : auth_pin ? "PIN" : "Passphrase") : NULL;
    if (pattern_mode) {
        st.pattern = &pattern;
        st.pattern_fallback = auth_pin ? "Use PIN" : "Use passphrase";
        st.auth_hint = "Draw your pattern";
        keypad.n_keys = 0;
    }
    bool animating = apply_motion(&st);

    surface_h = (int)o->height;
    keypad_shown = loginui_compact(st.width, st.height) && (touch || !keyboard || pattern_mode);
    if (keypad_shown) {
        LoginUiKeypadPage page = auth_broker && auth_pin ? LOGINUI_KEYPAD_DIGITS : LOGINUI_KEYPAD_LETTERS;
        if ((int)page != keypad_page) {
            keypad_page = (int)page;
            loginui_keypad_set_page(&keypad, page);
        }
    }
    st.cover = keypad_shown ? gesture.cover : 0.0;
    st.keypad = keypad_shown && !pattern_mode ? &keypad : NULL;

    double card_x, card_y, card_w, card_h;
    loginui_render(cr, &st, &card_x, &card_y, &card_w, &card_h);

    double extras = keypad_shown ? gesture.cover : 1.0;
    o->mb_valid = false;
    if (st.content_fade < 1.0 && extras > 0.0) {
        double alpha = (1.0 - st.content_fade) * extras;
        if (keypad_shown) {
            card_y = st.height * 0.30 - 14 + (1.0 - extras) * 48;
            card_h = 0;
        }
        bool faded = alpha < 1.0;
        if (faded) cairo_push_group(cr);
        cairo_save(cr);
        cairo_translate(cr, st.card_dx, 0);
        render_media(cr, o, card_x, card_y, card_w, card_h);
        render_notifs(cr, o, card_x, card_y + card_h + 14 + (o->mb_valid ? 102 : 0), card_w);
        cairo_restore(cr);
        if (faded) {
            cairo_pop_group_to_source(cr);
            cairo_paint_with_alpha(cr, alpha);
        }
        if (keypad_shown && extras < 0.5) o->mb_valid = false;
    }

    cairo_destroy(cr);

    if (animating || anim_phase == PHASE_LEAVE) {
        o->frame_cb = wl_surface_frame(o->surface);
        wl_callback_add_listener(o->frame_cb, &frame_listener, o);
    }
    wl_surface_set_buffer_scale(o->surface, s);
    wl_surface_attach(o->surface, b->wl_buffer, 0, 0);
    wl_surface_damage_buffer(o->surface, 0, 0, (int)o->width * s, (int)o->height * s);
    wl_surface_commit(o->surface);
}

static void set_cover(double target) {
    if (loginui_gesture_set_cover(&gesture, target, now_s())) render_all();
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

static void unlock_session(void) {
    lock_fprint_stop();
    ext_session_lock_v1_unlock_and_destroy(lock);
    wl_display_roundtrip(display);
    running = false;
}

static void begin_leave(void) {
    if (anim_phase == PHASE_LEAVE) return;
    bool any = false;
    for (struct lock_output *o = outputs; o; o = o->next)
        if (o->configured) any = true;
    if (!any) {
        unlock_session();
        return;
    }
    shake_start = -1;
    start_phase(PHASE_LEAVE, MOTION_LARGE_MS);
    render_all();
}

static void on_fprint_match(void) {
    snprintf(status_text, sizeof status_text, "%s", "Unlocking…");
    status_error = false;
    render_all();
    wl_display_flush(display);
    begin_leave();
}

static void on_fprint_status(const char *text, bool error) {
    if (password_len > 0) return;
    snprintf(status_text, sizeof status_text, "%s", text);
    status_error = error;
    render_all();
}

static bool retry_wait_text(char *out, size_t n) {
    char path[64];
    snprintf(path, sizeof path, "/run/sinty-key/wait-%u", (unsigned)getuid());
    FILE *f = fopen(path, "re");
    if (!f) return false;
    long long until = 0;
    int ok = fscanf(f, "%lld", &until);
    fclose(f);
    if (ok != 1) return false;
    long long left = until - (long long)time(NULL);
    if (left <= 0) return false;
    if (left < 120) snprintf(out, n, "Too many attempts. Try again in %lld seconds.", left);
    else snprintf(out, n, "Too many attempts. Try again in %lld minutes.", (left + 59) / 60);
    return true;
}

#define BADGE_UID 61000

static int badge_resume(const char *pin, char *why, size_t n) {
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);
    if (!bus) {
        g_clear_error(&err);
        snprintf(why, n, "%s", "The Sinty Key service is not running");
        return -1;
    }
    GVariant *r = g_dbus_connection_call_sync(bus, "dev.sinty.Key1", "/dev/sinty/Key1", "dev.sinty.Key1",
        "ResumeBadge", g_variant_new("(s)", pin), NULL, G_DBUS_CALL_FLAGS_NONE, 60000, NULL, &err);
    g_object_unref(bus);
    if (r) {
        g_variant_unref(r);
        return 0;
    }
    char *name = g_dbus_error_get_remote_error(err);
    if (name && g_str_has_suffix(name, ".WrongPin")) snprintf(why, n, "%s", "Incorrect PIN");
    else if (name && g_str_has_suffix(name, ".SecurityKeyRequired")) snprintf(why, n, "%s", "Plug in the security key of the Sinty Key and touch it");
    else snprintf(why, n, "%s", "Plug the Sinty Key back in, then enter its PIN");
    g_free(name);
    g_clear_error(&err);
    return -1;
}

static void quick_refresh(void) {
    memset(&quick, 0, sizeof quick);
    if (!auth_broker || getuid() == BADGE_UID || sinty_unlock_state(&quick) != 0) quick.armed = false;
    pattern_mode = quick.armed && quick.kind == SINTY_UNLOCK_PATTERN;
    loginui_pattern_reset(&pattern);
}

static void quick_locked(void) {
    quick.armed = false;
    pattern_mode = false;
    snprintf(status_text, sizeof status_text, "%s",
             secret_is_pin() ? "Too many attempts. Enter your PIN." : "Too many attempts. Enter your passphrase.");
    status_error = true;
}

static bool quick_pin_matches(void) {
    if (!quick.armed || quick.kind != SINTY_UNLOCK_PIN || (int)password_len != quick.length) return false;
    for (size_t i = 0; i < password_len; i++)
        if (password[i] < '0' || password[i] > '9') return false;
    return true;
}

static void submit_pattern(const char *sequence) {
    snprintf(status_text, sizeof status_text, "%s", "Checking…");
    status_error = false;
    render_all();
    wl_display_flush(display);
    int rc = sinty_unlock_verify(sequence);
    if (rc == SINTY_UNLOCK_OK) {
        loginui_pattern_reset(&pattern);
        status_text[0] = '\0';
        begin_leave();
        return;
    }
    if (!motion_reduced) shake_start = now_us();
    if (rc == SINTY_UNLOCK_LOCKED) quick_locked();
    else {
        pattern.error = true;
        snprintf(status_text, sizeof status_text, "%s", "Incorrect pattern");
        status_error = true;
    }
    render_all();
}

static void submit_password(void) {
    if (password_len == 0) return;
    if (quick_pin_matches()) {
        password[password_len] = '\0';
        int rc = sinty_unlock_verify(password);
        if (rc == SINTY_UNLOCK_OK) {
            memset(password, 0, sizeof password);
            password_len = 0;
            status_text[0] = '\0';
            begin_leave();
            return;
        }
        if (rc == SINTY_UNLOCK_LOCKED) quick.armed = false;
    }
    if (getuid() == BADGE_UID) {
        password[password_len] = '\0';
        snprintf(status_text, sizeof status_text, "%s", "Opening the Sinty Key…");
        status_error = false;
        render_all();
        wl_display_flush(display);
        char why[128];
        int rc = badge_resume(password, why, sizeof why);
        memset(password, 0, sizeof password);
        password_len = 0;
        if (rc == 0) {
            begin_leave();
            return;
        }
        if (!motion_reduced) shake_start = now_us();
        snprintf(status_text, sizeof status_text, "%s", why);
        status_error = true;
        render_all();
        return;
    }
    password[password_len] = '\0';
    snprintf(status_text, sizeof status_text, "%s",
             singularity_pam_needs_touch() ? "Touch your security key…" : "Authenticating…");
    status_error = false;
    render_all();
    wl_display_flush(display);

    int rc = singularity_pam_authenticate(username, password);

    /* Wipe the password from memory regardless of outcome. */
    memset(password, 0, sizeof password);
    password_len = 0;

    if (rc == 0) {
        begin_leave();
    } else {
        if (!motion_reduced) shake_start = now_us();
        if (!retry_wait_text(status_text, sizeof status_text))
            snprintf(status_text, sizeof status_text, "%s",
                     (access("/run/sinty-recoverd.sock", F_OK) != 0) ? "Incorrect password"
                     : singularity_pam_needs_touch() ? (secret_is_pin() ? "Incorrect PIN, or the security key was not touched"
                                                                        : "Incorrect passphrase, or the security key was not touched")
                     : secret_is_pin() ? "Incorrect PIN" : "Incorrect passphrase");
        status_error = true;
        render_all();
    }
}

static void leave_pattern(void) {
    if (!pattern_mode) return;
    pattern_mode = false;
    loginui_pattern_reset(&pattern);
    keypad_page = -1;
}

static void type_text(const char *text, size_t n) {
    if ((unsigned char)text[0] < 0x20 || password_len + n >= sizeof password - 1) return;
    leave_pattern();
    memcpy(password + password_len, text, n);
    password_len += n;
    status_text[0] = '\0';
    render_all();
}

static void erase_last(void) {
    while (password_len > 0 && ((unsigned char)password[password_len - 1] & 0xC0) == 0x80)
        password[--password_len] = '\0';
    if (password_len > 0) password[--password_len] = '\0';
    status_text[0] = '\0';
    render_all();
}

static void keypad_activate(int i) {
    char text[8];
    switch (loginui_keypad_activate(&keypad, i, text, sizeof text)) {
    case LOGINUI_KEYPAD_TEXT: type_text(text, strlen(text)); break;
    case LOGINUI_KEYPAD_BACKSPACE: erase_last(); break;
    case LOGINUI_KEYPAD_ENTER: submit_password(); break;
    default: render_all(); break;
    }
}

/* ── Keyboard ───────────────────────────────────────────────────────────── */

static void kb_keymap(void *data, struct wl_keyboard *kb, uint32_t format, int fd, uint32_t size) {
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        fprintf(stderr, "lock: unsupported keymap format %u\n", format);
        close(fd);
        return;
    }
    char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        fprintf(stderr, "lock: cannot map the keymap\n");
        return;
    }
    if (xkb_keymap) xkb_keymap_unref(xkb_keymap);
    if (xkb_state) xkb_state_unref(xkb_state);
    xkb_state = NULL;
    xkb_keymap = xkb_keymap_new_from_string(xkb_context, map,
        XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    if (!xkb_keymap) {
        fprintf(stderr, "lock: cannot compile the keymap\n");
        return;
    }
    xkb_state = xkb_state_new(xkb_keymap);
    if (!xkb_state) fprintf(stderr, "lock: cannot create the keyboard state\n");
    loginui_keypad_set_keymap(&keypad, xkb_keymap);
    render_all();
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
    if (state != WL_KEYBOARD_KEY_STATE_PRESSED) return;
    if (anim_phase == PHASE_LEAVE) return;
    if (!xkb_state) {
        snprintf(status_text, sizeof status_text, "%s", "Keyboard unavailable");
        status_error = true;
        render_all();
        return;
    }
    xkb_keycode_t kc = key + 8;
    xkb_keysym_t sym = xkb_state_key_get_one_sym(xkb_state, kc);
    gesture.last_input = now_s();
    if (loginui_gesture_covered(&gesture, keypad_shown) && sym != XKB_KEY_XF86AudioPlay && sym != XKB_KEY_XF86AudioPause
            && sym != XKB_KEY_XF86AudioNext && sym != XKB_KEY_XF86AudioPrev)
        set_cover(0.0);

    switch (sym) {
    case XKB_KEY_Return:
    case XKB_KEY_KP_Enter:
        submit_password();
        return;
    case XKB_KEY_BackSpace:
        erase_last();
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
    if (n > 0) type_text(buf, (size_t)n);
}
static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = kb_keymap, .enter = kb_enter, .leave = kb_leave,
    .key = kb_key, .modifiers = kb_modifiers, .repeat_info = kb_repeat,
};

/* ── Pointer and touch ───────────────────────────────────────────────────── */

static struct lock_output *output_for(struct wl_surface *sf) {
    for (struct lock_output *o = outputs; o; o = o->next)
        if (o->surface == sf) return o;
    return NULL;
}

static bool media_click(struct lock_output *o, double x, double y) {
    if (!o || !o->mb_valid) return false;
    for (int i = 0; i < 3; i++) {
        double r = o->mb_r[i] + 6;
        double dx = x - o->mb_cx[i];
        double dy = y - o->mb_cy;
        if (dx * dx + dy * dy <= r * r) {
            if (i == 0) lock_media_prev();
            else if (i == 1) lock_media_play_pause();
            else lock_media_next();
            return true;
        }
    }
    return false;
}

static bool haptic_keys(void) {
    static int enabled = -1;
    if (enabled < 0) {
        enabled = 1;
        GSettingsSchemaSource *src = g_settings_schema_source_get_default();
        GSettingsSchema *schema = src ? g_settings_schema_source_lookup(src, "dev.sinty.desktop", TRUE) : NULL;
        if (schema) {
            if (g_settings_schema_has_key(schema, "keyboard-haptic-feedback")) {
                GSettings *s = g_settings_new("dev.sinty.desktop");
                enabled = g_settings_get_boolean(s, "keyboard-haptic-feedback");
                g_object_unref(s);
            }
            g_settings_schema_unref(schema);
        }
    }
    return enabled == 1;
}

static bool pattern_reachable(void) {
    return pattern_mode && (!keypad_shown || gesture.cover <= 0.0);
}

static void input_press(struct lock_output *o, double x, double y) {
    if (anim_phase == PHASE_LEAVE) return;
    if (pattern_reachable()) {
        if (loginui_pattern_link_at(&pattern, x, y)) {
            leave_pattern();
            status_text[0] = '\0';
            render_all();
            return;
        }
        if (loginui_pattern_press(&pattern, x, y)) {
            status_text[0] = '\0';
            gesture.last_input = now_s();
            if (haptic_keys()) sinty_haptic_key();
            render_all();
            return;
        }
    }
    if (loginui_gesture_covered(&gesture, keypad_shown) && media_click(o, x, y)) return;
    int before = keypad.pressed;
    LoginUiGestureEvent ev = loginui_gesture_press(&gesture, &keypad, keypad_shown, x, y, now_s());
    if (keypad_shown && keypad.pressed >= 0 && keypad.pressed != before && haptic_keys()) sinty_haptic_key();
    switch (ev) {
    case LOGINUI_GESTURE_REDRAW: render_all(); break;
    case LOGINUI_GESTURE_TAP: media_click(o, x, y); break;
    default: break;
    }
}

static void input_motion(double x, double y) {
    if (pattern.tracking) {
        int before = pattern.n;
        loginui_pattern_motion(&pattern, x, y);
        if (pattern.n != before && haptic_keys()) sinty_haptic_key();
        gesture.last_input = now_s();
        render_all();
        return;
    }
    if (loginui_gesture_motion(&gesture, &keypad, keypad_shown, x, y, surface_h, now_s()) == LOGINUI_GESTURE_REDRAW)
        render_all();
}

static void input_release(double x, double y) {
    if (pattern.tracking) {
        char sequence[LOGINUI_PATTERN_MAX + 1];
        size_t n = loginui_pattern_release(&pattern, sequence, sizeof sequence);
        if (n >= 4) {
            submit_pattern(sequence);
        } else if (n > 0) {
            pattern.error = true;
            snprintf(status_text, sizeof status_text, "%s", "Connect at least 4 dots");
            status_error = true;
            render_all();
        }
        explicit_bzero(sequence, sizeof sequence);
        return;
    }
    int key = -1;
    switch (loginui_gesture_release(&gesture, &keypad, keypad_shown, x, y, now_s(), &key)) {
    case LOGINUI_GESTURE_REDRAW: render_all(); break;
    case LOGINUI_GESTURE_KEY: if (anim_phase != PHASE_LEAVE) keypad_activate(key); break;
    default: break;
    }
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t serial,
                     struct wl_surface *sf, wl_fixed_t sx, wl_fixed_t sy) {
    ptr_output = output_for(sf);
    ptr_x = wl_fixed_to_double(sx);
    ptr_y = wl_fixed_to_double(sy);
}
static void pt_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *sf) {
    ptr_output = NULL;
}
static void pt_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t sx, wl_fixed_t sy) {
    ptr_x = wl_fixed_to_double(sx);
    ptr_y = wl_fixed_to_double(sy);
    input_motion(ptr_x, ptr_y);
}
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time,
                      uint32_t button, uint32_t btn_state) {
    if (button != BTN_LEFT) return;
    if (btn_state == WL_POINTER_BUTTON_STATE_PRESSED) input_press(ptr_output, ptr_x, ptr_y);
    else input_release(ptr_x, ptr_y);
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

static void tc_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time,
                    struct wl_surface *sf, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    if (gesture.touch_id >= 0) return;
    gesture.touch_id = id;
    gesture.touch_x = wl_fixed_to_double(x);
    gesture.touch_y = wl_fixed_to_double(y);
    input_press(output_for(sf), gesture.touch_x, gesture.touch_y);
}
static void tc_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id) {
    if (id != gesture.touch_id) return;
    gesture.touch_id = -1;
    input_release(gesture.touch_x, gesture.touch_y);
}
static void tc_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    if (id != gesture.touch_id) return;
    gesture.touch_x = wl_fixed_to_double(x);
    gesture.touch_y = wl_fixed_to_double(y);
    input_motion(gesture.touch_x, gesture.touch_y);
}
static void tc_frame(void *d, struct wl_touch *t) {}
static void tc_cancel(void *d, struct wl_touch *t) {
    if (loginui_gesture_cancel(&gesture, &keypad)) render_all();
}
static void tc_shape(void *d, struct wl_touch *t, int32_t id, wl_fixed_t major, wl_fixed_t minor) {}
static void tc_orientation(void *d, struct wl_touch *t, int32_t id, wl_fixed_t orientation) {}
static const struct wl_touch_listener touch_listener = {
    .down = tc_down, .up = tc_up, .motion = tc_motion, .frame = tc_frame,
    .cancel = tc_cancel, .shape = tc_shape, .orientation = tc_orientation,
};

/* ── Outputs ────────────────────────────────────────────────────────────── */

static void out_geometry(void *d, struct wl_output *wo, int32_t x, int32_t y, int32_t pw, int32_t ph,
                         int32_t subpixel, const char *make, const char *model, int32_t transform) {}
static void out_mode(void *d, struct wl_output *wo, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {}
static void out_done(void *d, struct wl_output *wo) {
    struct lock_output *o = d;
    if (o->configured) render_output(o);
}
static void out_scale(void *d, struct wl_output *wo, int32_t factor) {
    struct lock_output *o = d;
    o->scale = factor;
}
static const struct wl_output_listener output_listener = {
    .geometry = out_geometry, .mode = out_mode, .done = out_done, .scale = out_scale,
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
        o->scale = 1;
        o->wl_output = wl_registry_bind(reg, name, &wl_output_interface,
                                        version < 3 ? version : 3);
        wl_output_add_listener(o->wl_output, &output_listener, o);
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
            if (dead->frame_cb) wl_callback_destroy(dead->frame_cb);
            if (dead->lock_surface) ext_session_lock_surface_v1_destroy(dead->lock_surface);
            if (dead->surface) wl_surface_destroy(dead->surface);
            loginui_pool_release(dead->pool, 2);
            if (ptr_output == dead) ptr_output = NULL;
            if (dead->wl_output) wl_output_destroy(dead->wl_output);
            free(dead);
            if (anim_phase == PHASE_LEAVE) {
                bool any = false;
                for (struct lock_output *o = outputs; o; o = o->next)
                    if (o->configured) any = true;
                if (!any) unlock_session();
            }
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

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) {
        keyboard = wl_seat_get_keyboard(s);
        wl_keyboard_add_listener(keyboard, &keyboard_listener, NULL);
    } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && keyboard) {
        wl_keyboard_release(keyboard);
        keyboard = NULL;
    }
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && pointer) {
        wl_pointer_release(pointer);
        pointer = NULL;
    }
    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !touch) {
        touch = wl_seat_get_touch(s);
        wl_touch_add_listener(touch, &touch_listener, NULL);
    } else if (!(caps & WL_SEAT_CAPABILITY_TOUCH) && touch) {
        wl_touch_release(touch);
        touch = NULL;
        gesture.touch_id = -1;
    }
    render_all();
}

static void seat_name(void *data, struct wl_seat *s, const char *name) {
    (void)data; (void)s; (void)name;
}

static const struct wl_seat_listener seat_listener = { seat_capabilities, seat_name };

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_name) snprintf(username, sizeof username, "%s", pw->pw_name);
    else { const char *u = getenv("USER"); if (u) snprintf(username, sizeof username, "%s", u); }
    if (pw && pw->pw_gecos && pw->pw_gecos[0] && pw->pw_gecos[0] != ',')
        snprintf(display_name, sizeof display_name, "%.*s", (int)strcspn(pw->pw_gecos, ","), pw->pw_gecos);

    loginui_gesture_init(&gesture);
    loginui_keypad_init(&keypad, NULL, LOGINUI_KEYPAD_LETTERS);
    auth_broker = access("/run/sinty-recoverd.sock", F_OK) == 0;
    auth_pin = secret_is_pin();
    quick_refresh();
    load_assets();
    load_motion();
    start_phase(PHASE_ENTER, MOTION_PAGE_MS);

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
    wl_seat_add_listener(seat, &seat_listener, NULL);
    wl_display_roundtrip(display);

    lock = ext_session_lock_manager_v1_lock(lock_manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    wl_display_roundtrip(display);

    /* MPRIS now-playing controls run on the GLib main context, which is
     * folded into the Wayland poll below so D-Bus signals are dispatched
     * without a second thread. */
    lock_media_init(on_media_change);
    lock_notifs_init(on_media_change);
    lock_fprint_start(username, on_fprint_match, on_fprint_status);

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

        int timeout = loginui_next_wakeup(&gesture, keypad_shown, password_len == 0, now_s(), 30.0);
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

        if (loginui_gesture_tick(&gesture, now_s()) || loginui_caret_tick()) render_all();
        if (password_len == 0 && loginui_gesture_idle(&gesture, keypad_shown, now_s(), 30.0)) set_cover(1.0);

        /* Repaint clock once a minute. */
        time_t now = time(NULL);
        struct tm tm; localtime_r(&now, &tm);
        if (tm.tm_min != last_min) { last_min = tm.tm_min; render_all(); }
    }

    wl_display_roundtrip(display);
    return 0;
}
