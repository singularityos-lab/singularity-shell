#include <glib.h>
#include "input-method-unstable-v2-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static gboolean keys[1024];
static guint presses;
static guint depressed_mods;
static guint releases;

static void record_key(struct zwp_virtual_keyboard_v1 *keyboard, uint32_t time,
                       uint32_t key, uint32_t state) {
    (void) keyboard; (void) time;
    keys[key] = state == WL_KEYBOARD_KEY_STATE_PRESSED;
    if (keys[key]) presses++;
}

static void record_modifiers(struct zwp_virtual_keyboard_v1 *keyboard,
                            uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    (void) keyboard; (void) latched; (void) locked; (void) group;
    depressed_mods = depressed;
}

static void record_release(struct zwp_input_method_keyboard_grab_v2 *grab) {
    (void) grab;
    releases++;
}

static int record_flush(struct wl_display *connection) {
    (void) connection;
    return 0;
}

#define zwp_virtual_keyboard_v1_key record_key
#define zwp_virtual_keyboard_v1_modifiers record_modifiers
#define zwp_input_method_keyboard_grab_v2_release record_release
#define wl_display_flush record_flush
#include "../src/wayland/ime.c"

static void setup(void) {
    memset(keys, 0, sizeof keys);
    memset(forwarded, 0, sizeof forwarded);
    presses = 0;
    releases = 0;
    depressed_mods = 0;
    display = (void *) 1;
    input_method = (void *) 2;
    keyboard_grab = (void *) 3;
    forward_keyboard = (void *) 4;
    forward_keymap_set = TRUE;
    current.active = TRUE;
    want_grab = TRUE;
    key_func = NULL;
}

static void release_keys_and_modifiers(void) {
    setup();
    singularity_ime_forward_key(30, TRUE);
    grab_modifiers(NULL, keyboard_grab, 0, 12, 0, 0, 0);
    singularity_ime_set_grab(FALSE);
    g_assert_false(keys[30]);
    g_assert_false(singularity_ime_key_forwarded(30));
    g_assert_cmpuint(depressed_mods, ==, 0);
    g_assert_cmpuint(releases, ==, 1);
}

static gboolean disable_grab(guint key, guint sym, const char *text,
                            gboolean pressed, guint modifiers, gpointer data) {
    (void) key; (void) sym; (void) text; (void) pressed; (void) modifiers; (void) data;
    singularity_ime_set_grab(FALSE);
    return FALSE;
}

static void disable_during_key(void) {
    setup();
    key_func = disable_grab;
    grab_key(NULL, keyboard_grab, 0, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
    g_assert_cmpuint(presses, ==, 1);
    g_assert_false(keys[30]);
    g_assert_false(singularity_ime_key_forwarded(30));
    g_assert_null(keyboard_grab);
}

static void stale_grab(void) {
    setup();
    struct zwp_input_method_keyboard_grab_v2 *previous = keyboard_grab;
    singularity_ime_set_grab(FALSE);
    grab_key(NULL, previous, 0, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
    grab_modifiers(NULL, previous, 0, 12, 0, 0, 0);
    g_assert_cmpuint(presses, ==, 0);
    g_assert_cmpuint(depressed_mods, ==, 0);
}

static gboolean consume_key(guint key, guint sym, const char *text,
                           gboolean pressed, guint modifiers, gpointer data) {
    disable_grab(key, sym, text, pressed, modifiers, data);
    return TRUE;
}

static void consumed_key(void) {
    setup();
    key_func = consume_key;
    grab_key(NULL, keyboard_grab, 0, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
    g_assert_cmpuint(presses, ==, 0);
    g_assert_false(keys[30]);
}

static void key_pair(void) {
    setup();
    grab_key(NULL, keyboard_grab, 0, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
    g_assert_true(keys[30]);
    grab_key(NULL, keyboard_grab, 0, 0, 30, WL_KEYBOARD_KEY_STATE_RELEASED);
    g_assert_false(keys[30]);
    g_assert_cmpuint(presses, ==, 1);
    g_assert_cmpuint(releases, ==, 0);
}

int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/ime/release-keys-modifiers", release_keys_and_modifiers);
    g_test_add_func("/ime/disable-during-key", disable_during_key);
    g_test_add_func("/ime/key-pair", key_pair);
    g_test_add_func("/ime/stale-grab", stale_grab);
    g_test_add_func("/ime/consumed-key", consumed_key);
    return g_test_run();
}
