namespace Singularity.SintyKey {

    public class Alerts : Object {
        private DBusProxy? proxy = null;
        private Gee.HashMap<string, string> states = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, string> owners = new Gee.HashMap<string, string>();
        private Gee.HashSet<uint> shown = new Gee.HashSet<uint>();

        public signal void open_requested(string page);

        public Alerts() {
            var notifications = SystemMonitor.get_default().notifications;
            notifications.action_invoked.connect((id, action) => {
                if (shown.contains(id) && action == "default") open_requested("sinty-key");
            });
            notifications.notification_closed.connect((id, reason) => shown.remove(id));
            if (FileUtils.test("/run/sinty-key/guest", FileTest.EXISTS)) {
                post(_("Guest Mode"),
                    _("This computer does not know your Sinty Key. Your files stay on the Key and nothing is kept on this computer."), "sinty-key-guest");
            }
            if (!Client.installed()) return;
            connect_bus.begin();
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
            proxy.notify["g-name-owner"].connect(() => take(false));
        }

        private void take(bool announce) {
            var value = proxy.get_cached_property("Present");
            if (value == null || !value.is_of_type(new VariantType("a(ssss)"))) return;
            var now_states = new Gee.HashMap<string, string>();
            var now_owners = new Gee.HashMap<string, string>();
            var me = Environment.get_user_name();
            var iter = value.iterator();
            string device, id, owner, state;
            while (iter.next("(ssss)", out device, out id, out owner, out state)) {
                now_states[device] = state;
                now_owners[device] = owner;
                if (!announce || states[device] == state) continue;
                if (state == "locked" && !states.has_key(device)) {
                    post(_("Sinty Key Connected"), _("Unlock it with its PIN to use the data on it."), "sinty-key-locked");
                } else if (state == "copy" && !states.has_key(device)) {
                    post(_("Older Sinty Key"),
                        _("This Key is an older copy of one this computer knows. Open it with its recovery code."), "sinty-key-copy");
                }
            }
            if (announce) {
                foreach (var entry in states.entries) {
                    if (now_states.has_key(entry.key) || entry.value == "locked" || entry.value == "copy") continue;
                    post(_("Sinty Key Locked"), _("The Sinty Key was removed, so its data is locked again."), "sinty-key-locked");
                    if (owners[entry.key] == me) SessionManager.get_default().lock_screen();
                }
            }
            states = now_states;
            owners = now_owners;
        }

        private void post(string summary, string body, string icon = "sinty-key") {
            string[] actions = { "default", _("Open Settings") };
            uint id = SystemMonitor.get_default().notifications.notify(_("Sinty Key"), 0, icon,
                summary, body, actions, new HashTable<string, Variant>(str_hash, str_equal), -1);
            shown.add(id);
        }
    }
}
