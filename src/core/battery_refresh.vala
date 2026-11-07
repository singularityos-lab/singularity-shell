namespace Singularity {

    public class BatteryRefresh : Object {
        private const int LOW_REFRESH = 60000;

        private static BatteryRefresh? instance = null;
        private GLib.Settings? settings = null;
        private uint pending = 0;

        public static BatteryRefresh get_default() {
            if (instance == null) instance = new BatteryRefresh();
            return instance;
        }

        public void start() {
            var schema = SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true);
            if (schema == null || !schema.has_key("battery-refresh-rate")) return;
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["battery-refresh-rate"].connect(schedule);
            IdleManager.get_default().notify["on-battery"].connect(schedule);
            DisplayManager.get_default().monitors_changed.connect(schedule);
            schedule();
        }

        private void schedule() {
            if (pending != 0) Source.remove(pending);
            pending = Timeout.add(500, () => {
                pending = 0;
                update();
                return Source.REMOVE;
            });
        }

        public static bool internal_panel(string? name) {
            if (name == null) return false;
            return name.has_prefix("eDP") || name.has_prefix("LVDS") || name.has_prefix("DSI");
        }

        public static DisplayManager.Mode? lower_mode(List<DisplayManager.Mode?> modes, DisplayManager.Mode current) {
            DisplayManager.Mode? best = null;
            foreach (var m in modes) {
                if (m.width != current.width || m.height != current.height) continue;
                if (m.refresh >= current.refresh || m.refresh < LOW_REFRESH - 1500) continue;
                if (best == null || m.refresh < best.refresh) best = m;
            }
            return best;
        }

        public static DisplayManager.Mode? mode_with(List<DisplayManager.Mode?> modes, DisplayManager.Mode current, int refresh) {
            foreach (var m in modes) {
                if (m.width == current.width && m.height == current.height && m.refresh == refresh) return m;
            }
            return null;
        }

        public bool update() {
            bool lower = settings != null && settings.get_boolean("battery-refresh-rate") && IdleManager.get_default().on_battery;
            bool changed = false;
            foreach (var m in DisplayManager.get_default().get_monitors()) {
                if (!internal_panel(m.name) || !m.enabled || m.current_mode == null) continue;
                if (lower && m.restore_refresh == 0) {
                    var mode = lower_mode(m.modes, m.current_mode);
                    if (mode == null) continue;
                    m.restore_refresh = m.current_mode.refresh;
                    m.current_mode = mode;
                    changed = true;
                } else if (!lower && m.restore_refresh > 0) {
                    var mode = mode_with(m.modes, m.current_mode, m.restore_refresh);
                    m.restore_refresh = 0;
                    if (mode == null) continue;
                    m.current_mode = mode;
                    changed = true;
                }
            }
            if (changed) DisplayManager.get_default().apply_configuration();
            return changed;
        }
    }
}
