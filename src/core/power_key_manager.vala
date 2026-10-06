namespace Singularity {

    public class PowerKeyManager : Object {
        private static PowerKeyManager? _instance = null;
        private GLib.Settings settings;
        private UnixInputStream? inhibitor = null;

        public static PowerKeyManager get_default() {
            if (_instance == null) _instance = new PowerKeyManager();
            return _instance;
        }

        private PowerKeyManager() {
            settings = new GLib.Settings("dev.sinty.desktop");
            take_inhibitor.begin();
        }

        private async void take_inhibitor() {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                UnixFDList out_fds;
                var reply = yield bus.call_with_unix_fd_list("org.freedesktop.login1", "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager", "Inhibit",
                    new Variant("(ssss)", "handle-power-key:handle-suspend-key", "Singularity",
                        _("The desktop decides what the power button does"), "block"),
                    new VariantType("(h)"), DBusCallFlags.NONE, 3000, null, null, out out_fds);
                int32 index;
                reply.get("(h)", out index);
                inhibitor = new UnixInputStream(out_fds.get(index), true);
            } catch (Error e) {
                debug("PowerKeyManager: no logind key inhibitor: %s", e.message);
            }
        }

        public void power_pressed() {
            string action = settings.get_string("power-button-action");
            message("PowerKeyManager: power button, action %s", action);
            switch (action) {
                case "suspend":
                    SessionManager.get_default().suspend();
                    break;
                case "power-off":
                    SessionManager.get_default().shutdown();
                    break;
                case "lock":
                    PowerActions.get_default().lock_screen();
                    break;
                case "nothing":
                    break;
                default:
                    ask();
                    break;
            }
        }

        public void sleep_pressed() {
            SessionManager.get_default().suspend();
        }

        private void ask() {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return;
            new PowerConfirmDialog(app, _("Power Off"), "system-shutdown-symbolic",
                _("Your computer will turn off. Unsaved work in open apps may be lost."),
                _("Power Off"), () => SessionManager.get_default().shutdown()).open_dialog();
        }
    }
}
