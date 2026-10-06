namespace Singularity {

    public class LidManager : Object {
        private static LidManager? _instance = null;
        private DBusProxy? upower = null;
        private UnixInputStream? inhibitor = null;
        private GLib.Settings settings;
        private Gee.HashSet<string> dimmed = new Gee.HashSet<string>();
        private bool closed = false;
        private uint pending = 0;

        public bool lid_present { get; private set; default = false; }

        public static LidManager get_default() {
            if (_instance == null) _instance = new LidManager();
            return _instance;
        }

        private LidManager() {
            settings = new GLib.Settings("dev.sinty.desktop");
            DBusProxy.create_for_bus.begin(BusType.SYSTEM, DBusProxyFlags.NONE, null,
                "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower", null, (obj, res) => {
                try {
                    upower = DBusProxy.create_for_bus.end(res);
                } catch (Error e) {
                    warning("LidManager: UPower unavailable: %s", e.message);
                    return;
                }
                var present = upower.get_cached_property("LidIsPresent");
                lid_present = present != null && present.get_boolean();
                if (!lid_present) return;
                take_inhibitor.begin();
                upower.g_properties_changed.connect((changed, invalidated) => {
                    var value = changed.lookup_value("LidIsClosed", VariantType.BOOLEAN);
                    if (value != null) set_closed(value.get_boolean());
                });
                var now = upower.get_cached_property("LidIsClosed");
                if (now != null && now.get_boolean()) set_closed(true);
            });
            DisplayManager.get_default().monitors_changed.connect(() => {
                if (closed) schedule();
            });
        }

        private async void take_inhibitor() {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                UnixFDList out_fds;
                var reply = yield bus.call_with_unix_fd_list("org.freedesktop.login1", "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager", "Inhibit",
                    new Variant("(ssss)", "handle-lid-switch", "Singularity", _("The desktop decides what closing the lid does"), "block"),
                    new VariantType("(h)"), DBusCallFlags.NONE, -1, null, null, out out_fds);
                int32 index;
                reply.get("(h)", out index);
                inhibitor = new UnixInputStream(out_fds.get(index), true);
            } catch (Error e) {
                warning("LidManager: could not take over the lid switch: %s", e.message);
            }
        }

        private static bool is_internal(string name) {
            return name.has_prefix("eDP") || name.has_prefix("LVDS") || name.has_prefix("DSI");
        }

        private bool has_external() {
            foreach (var m in DisplayManager.get_default().get_monitors()) {
                if (!is_internal(m.name) && m.enabled) return true;
            }
            return false;
        }

        private void set_closed(bool value) {
            if (closed == value) return;
            closed = value;
            if (!closed) {
                debug("LidManager: lid opened");
                restore_internal();
                return;
            }
            schedule();
        }

        private void schedule() {
            if (pending != 0) Source.remove(pending);
            pending = Timeout.add(800, () => {
                pending = 0;
                act();
                return Source.REMOVE;
            });
        }

        private void act() {
            if (!closed || inhibitor == null) return;
            if (has_external()) {
                debug("LidManager: lid closed with an external display, action %s", settings.get_string("lid-close-docked-action"));
                if (settings.get_string("lid-close-docked-action") == "suspend") {
                    restore_internal();
                    suspend();
                } else {
                    dim_internal();
                }
                return;
            }
            restore_internal();
            debug("LidManager: lid closed, action %s", settings.get_string("lid-close-action"));
            switch (settings.get_string("lid-close-action")) {
                case "lock":
                    SessionManager.get_default().lock_screen();
                    break;
                case "nothing":
                    break;
                default:
                    suspend();
                    break;
            }
        }

        private void dim_internal() {
            var dm = DisplayManager.get_default();
            bool changed = false;
            foreach (var m in dm.get_monitors()) {
                if (is_internal(m.name) && m.enabled) {
                    m.enabled = false;
                    dimmed.add(m.name);
                    changed = true;
                }
            }
            if (changed) dm.apply_configuration();
        }

        private void restore_internal() {
            if (dimmed.size == 0) return;
            var dm = DisplayManager.get_default();
            foreach (var m in dm.get_monitors()) {
                if (dimmed.contains(m.name)) m.enabled = true;
            }
            dimmed.clear();
            dm.apply_configuration();
        }

        private void suspend() {
            SessionManager.get_default().suspend();
        }
    }
}
