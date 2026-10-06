#include <gio/gio.h>
#include <string.h>

#include "lock_fprint.h"

#define FPRINT_BUS "net.reactivated.Fprint"
#define FPRINT_MANAGER_PATH "/net/reactivated/Fprint/Manager"
#define FPRINT_MANAGER "net.reactivated.Fprint.Manager"
#define FPRINT_DEVICE "net.reactivated.Fprint.Device"

static GDBusProxy *device = NULL;
static GCancellable *cancellable = NULL;
static char *user_name = NULL;
static bool claimed = false;
static bool verifying = false;
static LockFprintMatch match_cb = NULL;
static LockFprintStatus status_cb = NULL;

bool lock_fprint_active(void) {
    return verifying;
}

static void report(const char *text, bool error) {
    if (status_cb) status_cb(text, error);
}

static void start_verify(void);

static void on_verify_started(GObject *source, GAsyncResult *res, gpointer data) {
    (void)data;
    GError *error = NULL;
    GVariant *reply = g_dbus_proxy_call_finish(G_DBUS_PROXY(source), res, &error);
    if (!reply) {
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            g_warning("lock: fingerprint verification unavailable: %s", error->message);
        g_error_free(error);
        verifying = false;
        return;
    }
    g_variant_unref(reply);
    verifying = true;
    report("Touch the fingerprint sensor or type your password", false);
}

static void restart_verify(void) {
    if (!device || !claimed) return;
    GVariant *stopped = g_dbus_proxy_call_sync(device, "VerifyStop", NULL, G_DBUS_CALL_FLAGS_NONE,
                                               -1, NULL, NULL);
    if (stopped) g_variant_unref(stopped);
    start_verify();
}

static void on_signal(GDBusProxy *proxy, const char *sender, const char *signal, GVariant *params,
                      gpointer data) {
    (void)proxy; (void)sender; (void)data;
    if (strcmp(signal, "VerifyStatus") != 0) return;
    const char *result = NULL;
    gboolean done = FALSE;
    g_variant_get(params, "(&sb)", &result, &done);
    if (strcmp(result, "verify-match") == 0) {
        verifying = false;
        if (match_cb) match_cb();
        return;
    }
    if (strcmp(result, "verify-no-match") == 0) {
        report("Fingerprint not recognized, try again", true);
    } else if (strcmp(result, "verify-swipe-too-short") == 0) {
        report("Swipe was too short, try again", true);
    } else if (strcmp(result, "verify-finger-not-centered") == 0) {
        report("Center your finger on the sensor", true);
    } else if (strcmp(result, "verify-remove-and-retry") == 0) {
        report("Lift your finger and try again", true);
    } else if (strcmp(result, "verify-retry-scan") == 0) {
        report("Touch the sensor again", true);
    } else if (strcmp(result, "verify-disconnected") == 0) {
        verifying = false;
        report("The fingerprint sensor was disconnected", true);
        return;
    }
    if (done) restart_verify();
}

static void start_verify(void) {
    g_dbus_proxy_call(device, "VerifyStart", g_variant_new("(s)", "any"), G_DBUS_CALL_FLAGS_NONE, -1,
                      cancellable, on_verify_started, NULL);
}

static void on_claimed(GObject *source, GAsyncResult *res, gpointer data) {
    (void)data;
    GError *error = NULL;
    GVariant *reply = g_dbus_proxy_call_finish(G_DBUS_PROXY(source), res, &error);
    if (!reply) {
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            g_warning("lock: cannot claim the fingerprint sensor: %s", error->message);
        g_error_free(error);
        return;
    }
    g_variant_unref(reply);
    claimed = true;
    start_verify();
}

static void on_fingers(GObject *source, GAsyncResult *res, gpointer data) {
    (void)data;
    GError *error = NULL;
    GVariant *reply = g_dbus_proxy_call_finish(G_DBUS_PROXY(source), res, &error);
    if (!reply) {
        g_error_free(error);
        return;
    }
    GVariant *fingers = g_variant_get_child_value(reply, 0);
    gsize count = g_variant_n_children(fingers);
    g_variant_unref(fingers);
    g_variant_unref(reply);
    if (count == 0) return;
    g_dbus_proxy_call(device, "Claim", g_variant_new("(s)", user_name), G_DBUS_CALL_FLAGS_NONE, -1,
                      cancellable, on_claimed, NULL);
}

static void on_device(GObject *source, GAsyncResult *res, gpointer data) {
    (void)source; (void)data;
    GError *error = NULL;
    device = g_dbus_proxy_new_for_bus_finish(res, &error);
    if (!device) {
        g_error_free(error);
        return;
    }
    g_signal_connect(device, "g-signal", G_CALLBACK(on_signal), NULL);
    g_dbus_proxy_call(device, "ListEnrolledFingers", g_variant_new("(s)", user_name),
                      G_DBUS_CALL_FLAGS_NONE, -1, cancellable, on_fingers, NULL);
}

static void on_default_device(GObject *source, GAsyncResult *res, gpointer data) {
    (void)data;
    GError *error = NULL;
    GVariant *reply = g_dbus_proxy_call_finish(G_DBUS_PROXY(source), res, &error);
    g_object_unref(source);
    if (!reply) {
        g_error_free(error);
        return;
    }
    const char *path = NULL;
    g_variant_get(reply, "(&o)", &path);
    g_dbus_proxy_new_for_bus(G_BUS_TYPE_SYSTEM, G_DBUS_PROXY_FLAGS_DO_NOT_LOAD_PROPERTIES, NULL,
                             FPRINT_BUS, path, FPRINT_DEVICE, cancellable, on_device, NULL);
    g_variant_unref(reply);
}

static void on_manager(GObject *source, GAsyncResult *res, gpointer data) {
    (void)source; (void)data;
    GError *error = NULL;
    GDBusProxy *manager = g_dbus_proxy_new_for_bus_finish(res, &error);
    if (!manager) {
        g_error_free(error);
        return;
    }
    g_dbus_proxy_call(manager, "GetDefaultDevice", NULL, G_DBUS_CALL_FLAGS_NONE, -1, cancellable,
                      on_default_device, NULL);
}

void lock_fprint_start(const char *user, LockFprintMatch on_match, LockFprintStatus on_status) {
    if (!user || !user[0] || cancellable) return;
    user_name = g_strdup(user);
    match_cb = on_match;
    status_cb = on_status;
    cancellable = g_cancellable_new();
    g_dbus_proxy_new_for_bus(G_BUS_TYPE_SYSTEM,
                             G_DBUS_PROXY_FLAGS_DO_NOT_LOAD_PROPERTIES | G_DBUS_PROXY_FLAGS_DO_NOT_AUTO_START,
                             NULL, FPRINT_BUS, FPRINT_MANAGER_PATH, FPRINT_MANAGER, cancellable, on_manager,
                             NULL);
}

void lock_fprint_stop(void) {
    if (cancellable) g_cancellable_cancel(cancellable);
    if (device && claimed) {
        if (verifying) {
            GVariant *r = g_dbus_proxy_call_sync(device, "VerifyStop", NULL, G_DBUS_CALL_FLAGS_NONE, 2000,
                                                 NULL, NULL);
            if (r) g_variant_unref(r);
        }
        GVariant *r = g_dbus_proxy_call_sync(device, "Release", NULL, G_DBUS_CALL_FLAGS_NONE, 2000, NULL,
                                             NULL);
        if (r) g_variant_unref(r);
    }
    verifying = false;
    claimed = false;
    g_clear_object(&device);
    g_clear_object(&cancellable);
    g_clear_pointer(&user_name, g_free);
}
