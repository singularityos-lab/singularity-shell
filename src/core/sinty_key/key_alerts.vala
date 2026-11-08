namespace Singularity.SintyKey {

    public class Alerts : Object {
        private DBusProxy? proxy = null;
        private Gee.HashSet<string> open = new Gee.HashSet<string>();
        private Gee.HashSet<uint> shown = new Gee.HashSet<uint>();
        private VolumeMonitor? monitor = null;

        public signal void open_requested(string page);

        public Alerts() {
            var notifications = SystemMonitor.get_default().notifications;
            notifications.action_invoked.connect((id, action) => {
                if (shown.contains(id) && action == "default") open_requested("sinty-key");
            });
            notifications.notification_closed.connect((id, reason) => shown.remove(id));
            if (FileUtils.test("/run/sinty-key/guest", FileTest.EXISTS)) {
                post(_("Guest Mode"),
                    _("This computer does not know your Sinty Key. Your files stay on the Key and nothing is kept on this computer."));
            }
            if (!Client.installed()) return;
            connect_bus.begin();
            monitor = VolumeMonitor.get();
            monitor.mount_added.connect((mount) => {
                var root = mount.get_root().get_path();
                if (root != null) check_drive.begin(root);
            });
        }

        private async void connect_bus() {
            try {
                proxy = yield new DBusProxy.for_bus(BusType.SYSTEM, DBusProxyFlags.DO_NOT_AUTO_START, null,
                    "dev.sinty.Key1", "/dev/sinty/Key1", "dev.sinty.Key1");
            } catch (Error e) {
                return;
            }
            take(false);
            proxy.g_properties_changed.connect((changed, invalidated) => take(true));
        }

        private void take(bool announce) {
            var value = proxy.get_cached_property("Unlocked");
            var now = new Gee.HashSet<string>();
            if (value != null) {
                foreach (var s in value.get_strv()) now.add(s);
            }
            if (announce) {
                foreach (var root in open) {
                    if (!now.contains(root) && !FileUtils.test(root, FileTest.IS_DIR)) removed(root);
                }
            }
            open = now;
        }

        private void post(string summary, string body) {
            string[] actions = { "default", _("Open Settings") };
            uint id = SystemMonitor.get_default().notifications.notify(_("Sinty Key"), 0, "drive-removable-media",
                summary, body, actions, new HashTable<string, Variant>(str_hash, str_equal), -1);
            shown.add(id);
        }

        private void removed(string root) {
            post(_("Sinty Key Locked"),
                _("\"%s\" was removed, so its data is locked again.").printf(Path.get_basename(root)));
        }

        private async void check_drive(string root) {
            if (!FileUtils.test(Path.build_filename(root, "Data"), FileTest.IS_DIR)) return;
            try {
                var info = yield Client.get_default().inspect(root);
                if (info.unlocked) return;
                post(_("Sinty Key Connected"),
                    _("Unlock \"%s\" with its PIN to use the data on it.").printf(Path.get_basename(root)));
            } catch (KeyError e) {
            }
        }
    }
}
