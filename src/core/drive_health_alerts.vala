namespace Singularity {

    public class DriveHealthAlerts : Object {
        private Gee.HashMap<uint, DriveHealth> shown = new Gee.HashMap<uint, DriveHealth>();

        public signal void open_requested(string page);

        public DriveHealthAlerts() {
            var notifications = SystemMonitor.get_default().notifications;
            notifications.action_invoked.connect((id, action) => {
                var h = shown[id];
                if (h != null) act(h, action);
            });
            notifications.notification_closed.connect((id, reason) => shown.unset(id));
            DriveHealthMonitor.get_default().changed.connect((key, condition, reasons, alert) => {
                if (alert) announce.begin(key);
            });
        }

        private async void announce(string key) {
            DriveHealth? found = null;
            foreach (var h in yield DriveHealth.all()) {
                if (h.key == key) found = h;
            }
            if (found == null || !found.troubled) return;
            var h = found;
            string name = h.name != "" ? h.name : _("A USB drive");
            string summary = h.condition == DriveCondition.FAILING
                ? _("%s Is Failing").printf(name)
                : _("%s Is Wearing Out").printf(name);
            string[] actions = { "default", _("Details") };
            Mount? mount = mount_for(h.device);
            if (mount != null) {
                actions += "copy";
                actions += _("Copy Files");
            }
            if (yield holds_key(h.device)) {
                actions += "key";
                actions += _("Make a New Key");
            }
            if (holds_backups(mount)) {
                actions += "backups";
                actions += _("Move Backups");
            }
            if (mount != null && mount.can_eject()) {
                actions += "eject";
                actions += _("Eject");
            }
            var hints = new HashTable<string, Variant>(str_hash, str_equal);
            hints["urgency"] = new Variant.byte(h.condition == DriveCondition.FAILING ? 2 : 1);
            uint id = SystemMonitor.get_default().notifications.notify(_("Storage"), 0, h.icon_name(),
                summary, h.explain(), actions, hints, -1);
            shown[id] = h;
        }

        public static Mount? mount_for(string device) {
            if (device == "") return null;
            foreach (var m in VolumeMonitor.get().get_mounts()) {
                var v = m.get_volume();
                string? dev = v != null ? v.get_identifier(VolumeIdentifier.UNIX_DEVICE) : null;
                if (dev != null && (dev == device || dev.has_prefix(device) && dev.length > device.length
                        && (dev[device.length].isdigit() || dev[device.length] == 'p'))) return m;
            }
            return null;
        }

        private static async bool holds_key(string device) {
            if (device == "" || !SintyKey.Client.installed()) return false;
            try {
                foreach (var d in yield SintyKey.Client.get_default().drives()) {
                    if (d.device == device && (d.key || d.startup)) return true;
                }
            } catch (SintyKey.KeyError e) {
            }
            return false;
        }

        private static bool holds_backups(Mount? mount) {
            if (mount == null) return false;
            var source = SettingsSchemaSource.get_default();
            if (source == null || source.lookup("dev.sinty.backups", true) == null) return false;
            var s = new GLib.Settings("dev.sinty.backups");
            string kind = s.get_string("destination-kind");
            var v = mount.get_volume();
            if (kind == "disk") {
                string? uuid = v != null ? v.get_identifier(VolumeIdentifier.UUID) : null;
                return uuid != null && uuid == s.get_string("destination-id");
            }
            if (kind == "folder") {
                string? root = mount.get_root().get_path();
                string path = s.get_string("destination-path");
                return root != null && (path == root || path.has_prefix(root + "/"));
            }
            return false;
        }

        private void act(DriveHealth h, string action) {
            switch (action) {
                case "copy":
                    var m = mount_for(h.device);
                    if (m != null) launch_uri(m.get_root().get_uri());
                    break;
                case "key":
                    open_requested("sinty-key");
                    break;
                case "backups":
                    launch_app("dev.sinty.backups.desktop");
                    break;
                case "eject":
                    var m = mount_for(h.device);
                    if (m != null) m.eject_with_operation.begin(MountUnmountFlags.NONE, null, null);
                    break;
                default:
                    open_requested("storage");
                    break;
            }
        }

        private static void launch_uri(string uri) {
            try {
                AppInfo.launch_default_for_uri(uri, null);
            } catch (Error e) {
                warning("open %s: %s", uri, e.message);
            }
        }

        private static void launch_app(string id) {
            var info = new DesktopAppInfo(id);
            if (info == null) return;
            try {
                info.launch(null, null);
            } catch (Error e) {
                warning("launch %s: %s", id, e.message);
            }
        }
    }
}
