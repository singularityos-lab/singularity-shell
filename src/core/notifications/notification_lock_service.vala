using GLib;

namespace Singularity {

    public struct LockScreenNotification {
        public string app_name;
        public string icon;
        public string summary;
        public string body;
        public int64 timestamp;
    }

    [DBus (name = "dev.sinty.Notifications1")]
    public class NotificationLockService : Object {
        public const int MAX_ITEMS = 4;
        private NotificationManager _manager;

        public signal void changed();

        public NotificationLockService(NotificationManager manager) {
            _manager = manager;
            _manager.history_changed.connect(() => changed());
        }

        public LockScreenNotification[] get_lock_screen_notifications() throws GLib.Error {
            LockScreenNotification[] items = {};
            var ns = AppNotificationSettings.get_default();
            if (ns.available && !ns.settings.get_boolean("lock-screen-enabled")) return items;
            foreach (var n in _manager.get_history()) {
                if (items.length >= MAX_ITEMS) break;
                if (n.silenced) continue;
                if (n.lock_screen == AppNotificationPolicy.LOCK_HIDE) continue;
                var item = LockScreenNotification();
                item.app_name = n.app_name;
                item.icon = n.icon.has_prefix("/") ? "" : n.icon;
                item.timestamp = n.timestamp / 1000000;
                if (n.lock_screen == AppNotificationPolicy.LOCK_SHOW) {
                    item.summary = n.summary;
                    item.body = n.body;
                } else {
                    item.summary = _("Notification");
                    item.body = "";
                }
                items += item;
            }
            return items;
        }

        public static void export(NotificationManager manager) {
            var service = new NotificationLockService(manager);
            Bus.own_name(BusType.SESSION, "dev.sinty.Notifications", BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        conn.register_object("/dev/sinty/Notifications", service);
                    } catch (IOError e) {
                        warning("notifications: could not export dev.sinty.Notifications1: %s", e.message);
                    }
                },
                () => {},
                () => { warning("notifications: lost name dev.sinty.Notifications"); });
        }
    }
}
