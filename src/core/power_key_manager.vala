namespace Singularity {

    public class PowerKeyManager : Object {
        private static PowerKeyManager? _instance = null;
        private const int CHORD_MS = 400;

        private GLib.Settings settings;
        private UnixInputStream? inhibitor = null;
        private int64 volume_down_at = 0;
        private double volume_before = -1;
        private uint pending_power = 0;

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

        public bool volume_down_pressed(double volume) {
            if (!Singularity.FormFactor.current().is_handheld()) return false;
            if (pending_power != 0) {
                Source.remove(pending_power);
                pending_power = 0;
                capture();
                return true;
            }
            volume_down_at = GLib.get_monotonic_time();
            volume_before = volume;
            return false;
        }

        public void power_pressed() {
            var idle = IdleManager.get_default();
            if (idle.blanked) {
                message("PowerKeyManager: power button, turning the screen back on");
                idle.wake();
                return;
            }
            if (!Singularity.FormFactor.current().is_handheld()) {
                run_power_action();
                return;
            }
            if (GLib.get_monotonic_time() - volume_down_at < CHORD_MS * 1000) {
                volume_down_at = 0;
                if (volume_before >= 0) SystemMonitor.get_default().audio.update_volume(volume_before);
                capture();
                return;
            }
            if (pending_power != 0) Source.remove(pending_power);
            pending_power = Timeout.add(CHORD_MS, () => {
                pending_power = 0;
                run_power_action();
                return Source.REMOVE;
            });
        }

        private void capture() {
            message("PowerKeyManager: power and volume down, taking a screenshot");
            SystemMonitor.get_default().shortcuts.capture_fullscreen();
        }

        private void run_power_action() {
            var idle = IdleManager.get_default();
            string action = settings.get_string("power-button-action");
            if (action == "auto") action = Singularity.FormFactor.current().is_handheld() ? "screen-off" : "ask";
            message("PowerKeyManager: power button, action %s", action);
            switch (action) {
                case "screen-off":
                    PowerActions.get_default().lock_screen();
                    idle.hold_screens_off();
                    break;
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
