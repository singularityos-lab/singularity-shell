using Gtk;

namespace Singularity {

    public class IdleManager : Object {
        public const string DIM_OPACITY = "0.55";
        public const double DIM_BACKLIGHT_PERCENT = 30.0;

        private const int DIM = 1;
        private const int BLANK = 2;
        private const int LOCK = 3;
        private const int SUSPEND = 4;
        private const int PROBE = 5;

        private static IdleManager? _instance = null;
        private GLib.Settings settings;
        private GLib.Settings? lock_settings = null;
        private UPower.Client? upower = null;
        private Gee.ArrayList<DimWindow> dim_windows = new Gee.ArrayList<DimWindow>();
        private Gee.HashSet<int> fired = new Gee.HashSet<int>();
        private int probe_target = 0;
        private uint probe_check = 0;
        private int64 idle_since = 0;
        private int64 blanked_since = 0;
        private double saved_backlight = -1.0;
        private bool dbus_inhibited = false;

        public bool available { get; private set; default = false; }
        public bool on_battery { get; private set; default = false; }
        public bool dimmed { get; private set; default = false; }
        public bool blanked { get; private set; default = false; }
        public signal void action_taken(string action);

        public static IdleManager get_default() {
            if (_instance == null) _instance = new IdleManager();
            return _instance;
        }

        private IdleManager() {
            settings = new GLib.Settings("dev.sinty.desktop");
            var source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup("dev.sinty.lockscreen", true) != null) {
                lock_settings = new GLib.Settings("dev.sinty.lockscreen");
                lock_settings.changed.connect(() => rearm());
            }
            settings.changed.connect((key) => {
                if (key.has_prefix("idle-") || key.has_prefix("screen-blank-") || key.has_prefix("suspend-idle-")) rearm();
            });
            try {
                upower = UPower.Client.new_full(null);
            } catch (Error e) {
                debug("IdleManager: UPower unavailable: %s", e.message);
            }
            if (upower != null) {
                on_battery = upower.get_on_battery();
                upower.notify["on-battery"].connect(() => {
                    on_battery = upower.get_on_battery();
                    rearm();
                });
            }
            IdleInhibitors.get_default().changed.connect(on_inhibitors_changed);
        }

        public void start() {
            available = IdleNotify.init();
            if (!available) {
                warning("IdleManager: the compositor does not offer ext-idle-notify-v1");
                return;
            }
            rearm();
        }

        public int blank_seconds {
            get { return settings.get_int(on_battery ? "screen-blank-battery" : "screen-blank-ac"); }
        }

        public int suspend_seconds {
            get { return settings.get_int(on_battery ? "suspend-idle-battery" : "suspend-idle-ac"); }
        }

        public int lock_seconds {
            get {
                if (lock_settings == null || !lock_settings.get_boolean("lock-enabled")) return 0;
                return lock_settings.get_int("idle-delay");
            }
        }

        public int dim_seconds {
            get {
                int blank = blank_seconds;
                if (!settings.get_boolean("idle-dim-screen") || blank <= 0) return 0;
                return int.max(blank - int.min(30, blank / 2), 1);
            }
        }

        public void rearm() {
            if (!available) return;
            int[] all = { DIM, BLANK, LOCK, SUSPEND, PROBE };
            foreach (int id in all) IdleNotify.unwatch(id);
            fired.clear();
            probe_target = 0;
            int[] ids = { DIM, BLANK, LOCK, SUSPEND };
            int[] delays = { dim_seconds, blank_seconds, lock_seconds, suspend_seconds };
            int shortest = 0;
            for (int i = 0; i < ids.length; i++) {
                if (delays[i] <= 0) continue;
                IdleNotify.watch(ids[i], (uint32) delays[i] * 1000, false, on_idle_event, this);
                if (shortest == 0 || delays[i] < shortest) {
                    shortest = delays[i];
                    probe_target = ids[i];
                }
            }
            if (shortest > 0 && IdleNotify.input_only_supported()) {
                IdleNotify.watch(PROBE, (uint32) shortest * 1000, true, on_idle_event, this);
            }
            message("IdleManager: armed dim %d blank %d lock %d suspend %d (%s)",
                delays[0], delays[1], delays[2], delays[3], on_battery ? "battery" : "ac");
        }

        private static void on_idle_event(int id, bool idle, void* data) {
            var self = (IdleManager) data;
            if (idle) self.handle_idle(id);
            else self.handle_resume(id);
        }

        private void handle_idle(int id) {
            if (id == PROBE) {
                if (idle_since == 0) idle_since = get_monotonic_time();
                if (probe_check != 0) Source.remove(probe_check);
                probe_check = Timeout.add(1000, () => {
                    probe_check = 0;
                    if (!fired.contains(probe_target)) {
                        debug("IdleManager: a window keeps the session awake");
                        IdleInhibitors.get_default().mark_window_inhibit(true);
                    }
                    return Source.REMOVE;
                });
                return;
            }
            fired.add(id);
            if (idle_since == 0) idle_since = get_monotonic_time();
            var inhibitors = IdleInhibitors.get_default();
            inhibitors.mark_window_inhibit(false);
            bool blocked = id == SUSPEND
                ? inhibitors.inhibits(IdleInhibitors.IDLE | IdleInhibitors.SUSPEND)
                : inhibitors.inhibits(IdleInhibitors.IDLE);
            if (blocked) {
                message("IdleManager: idle action %d held back by an inhibitor", id);
                return;
            }
            switch (id) {
                case DIM:
                    dim();
                    break;
                case BLANK:
                    blank_screens(true);
                    break;
                case LOCK:
                    message("IdleManager: locking the session");
                    action_taken("lock");
                    PowerActions.get_default().lock_screen();
                    break;
                case SUSPEND:
                    message("IdleManager: suspending");
                    action_taken("suspend");
                    PowerActions.get_default().suspend.begin((obj, res) => {
                        try {
                            PowerActions.get_default().suspend.end(res);
                        } catch (Error e) {
                            warning("IdleManager: suspend failed: %s", e.message);
                        }
                    });
                    break;
            }
        }

        private void handle_resume(int id) {
            fired.remove(id);
            if (id == PROBE) {
                if (probe_check != 0) {
                    Source.remove(probe_check);
                    probe_check = 0;
                }
                IdleInhibitors.get_default().mark_window_inhibit(false);
            }
            idle_since = 0;
            undim();
            if (blanked) blank_screens(false);
        }

        private void on_inhibitors_changed() {
            bool now = IdleInhibitors.get_default().inhibits(IdleInhibitors.IDLE, false);
            bool was = dbus_inhibited;
            dbus_inhibited = now;
            if (!was && now) {
                undim();
                if (blanked) blank_screens(false);
            }
            if (was && !now && fired.size > 0) rearm();
        }

        public void wake() {
            undim();
            if (blanked) blank_screens(false);
            rearm();
        }

        public uint32 idle_seconds() {
            if (idle_since == 0) return 0;
            return (uint32) ((get_monotonic_time() - idle_since) / 1000000);
        }

        public uint32 blanked_seconds() {
            if (!blanked) return 0;
            return (uint32) ((get_monotonic_time() - blanked_since) / 1000000);
        }

        public void blank_screens(bool value) {
            if (blanked == value) return;
            if (value) {
                message("IdleManager: turning the screens off");
                action_taken("blank");
                blanked_since = get_monotonic_time();
                IdleNotify.output_power_set(false);
            } else {
                message("IdleManager: turning the screens on");
                IdleNotify.output_power_set(true);
                undim();
            }
            blanked = value;
        }

        private string? backlight_connector() {
            foreach (var display in BrightnessManager.get_default().displays) {
                if (display.internal_panel) return display.connector;
            }
            return null;
        }

        private void dim() {
            if (dimmed) return;
            dimmed = true;
            message("IdleManager: dimming the screens");
            action_taken("dim");
            string? panel = backlight_connector();
            if (panel != null) {
                var brightness = BrightnessManager.get_default();
                saved_backlight = brightness.brightness;
                if (saved_backlight > DIM_BACKLIGHT_PERCENT) brightness.set_level(DIM_BACKLIGHT_PERCENT);
            }
            var app = GLib.Application.get_default() as Gtk.Application;
            var monitors = Gdk.Display.get_default().get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = (Gdk.Monitor) monitors.get_item(i);
                if (panel != null && monitor.connector == panel) continue;
                var window = new DimWindow(app, monitor);
                dim_windows.add(window);
                window.fade_in();
            }
        }

        private void undim() {
            if (!dimmed) return;
            dimmed = false;
            if (saved_backlight > 0) {
                BrightnessManager.get_default().set_level(saved_backlight);
                saved_backlight = -1.0;
            }
            foreach (var window in dim_windows) window.fade_out();
            dim_windows.clear();
        }
    }

    internal class DimWindow : Gtk.Window {
        private static Gtk.CssProvider? provider = null;

        public DimWindow(Gtk.Application? app, Gdk.Monitor monitor) {
            Object(application: app);
            if (provider == null) {
                provider = new Gtk.CssProvider();
                provider.load_from_string(
                    "window.idle-dim { background: black; opacity: 0; transition: opacity %ums %s; }\n".printf(fade_ms(), Motion.Curve.ENTER.to_css())
                    + "window.idle-dim.dimmed { opacity: %s; }".printf(IdleManager.DIM_OPACITY));
                Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 10);
            }
            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_namespace(this, "singularity-idle-dim");
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_exclusive_zone(this, -1);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            GtkLayerShell.set_monitor(this, monitor);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            add_css_class("idle-dim");
            can_target = false;
            map.connect_after(() => Singularity.surface_set_input_passthrough(this));
        }

        private static uint fade_ms() {
            if (Motion.reduced()) return 0;
            return Motion.get_default().scale((uint) Motion.Duration.SCENE);
        }

        public void fade_in() {
            present();
            Timeout.add(30, () => {
                add_css_class("dimmed");
                return Source.REMOVE;
            });
        }

        public void fade_out() {
            remove_css_class("dimmed");
            Timeout.add(fade_ms(), () => {
                close_layer_window(this);
                destroy();
                return Source.REMOVE;
            });
        }
    }
}
