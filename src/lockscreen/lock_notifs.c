#include "lock_notifs.h"

#include <stdio.h>
#include <string.h>
#include <gio/gio.h>

static GDBusConnection *bus = NULL;
static LockNotifsState state;
static void (*change_cb)(void) = NULL;

static void on_reply(GObject *src, GAsyncResult *res, gpointer data) {
    (void) data;
    GError *error = NULL;
    GVariant *ret = g_dbus_connection_call_finish(G_DBUS_CONNECTION(src), res, &error);
    memset(&state, 0, sizeof state);
    if (ret == NULL) {
        g_clear_error(&error);
        if (change_cb) change_cb();
        return;
    }
    GVariantIter *iter = NULL;
    g_variant_get(ret, "(a(ssssx))", &iter);
    const char *app, *icon, *summary, *body;
    gint64 ts;
    while (state.count < LOCK_NOTIFS_MAX && g_variant_iter_next(iter, "(&s&s&s&sx)", &app, &icon, &summary, &body, &ts)) {
        LockNotification *n = &state.items[state.count++];
        snprintf(n->app_name, sizeof n->app_name, "%s", app);
        snprintf(n->summary, sizeof n->summary, "%s", summary);
        snprintf(n->body, sizeof n->body, "%s", body);
        for (char *p = n->body; *p; p++) if (*p == '\n') *p = ' ';
        n->timestamp = ts;
    }
    g_variant_iter_free(iter);
    g_variant_unref(ret);
    if (change_cb) change_cb();
}

static void refresh(void) {
    if (bus == NULL) return;
    g_dbus_connection_call(bus, "dev.sinty.Notifications", "/dev/sinty/Notifications",
        "dev.sinty.Notifications1", "GetLockScreenNotifications", NULL,
        G_VARIANT_TYPE("(a(ssssx))"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, NULL, on_reply, NULL);
}

static void on_signal(GDBusConnection *c, const char *sender, const char *path, const char *iface,
                      const char *name, GVariant *params, gpointer data) {
    (void) c; (void) sender; (void) path; (void) iface; (void) name; (void) params; (void) data;
    refresh();
}

void lock_notifs_init(void (*on_change)(void)) {
    change_cb = on_change;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (bus == NULL) return;
    g_dbus_connection_signal_subscribe(bus, "dev.sinty.Notifications", "dev.sinty.Notifications1", "Changed",
        "/dev/sinty/Notifications", NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_signal, NULL, NULL);
    refresh();
}

const LockNotifsState *lock_notifs_get(void) {
    return &state;
}
