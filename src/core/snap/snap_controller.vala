namespace Singularity {

    public class SnapController : Object {
        private const string ENABLED_KEY = "snap-layouts";
        private const string ASSIST_KEY = "snap-assist";

        private static SnapController? _instance = null;

        private Gtk.Application? _app = null;
        private GLib.Settings? _settings = null;
        private SnapPicker? _picker = null;
        private SnapAssist? _assist = null;
        private void* _toplevel = null;
        private SnapRect _area;
        private bool _started = false;

        public static SnapController get_default() {
            if (_instance == null) _instance = new SnapController();
            return _instance;
        }

        public void start(Gtk.Application app) {
            if (_started) return;
            _started = true;
            _app = app;
            AppSystem.get_default();
            var source = GLib.SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema != null && schema.has_key(ENABLED_KEY)) {
                _settings = new GLib.Settings("dev.sinty.desktop");
                _settings.changed[ENABLED_KEY].connect(apply_enabled);
                _settings.changed["tiling-enabled"].connect(apply_enabled);
            }
            if (!SnapBridge.start(on_event)) {
                message("Snap layouts: compositor has no snap protocol, picker unavailable");
                return;
            }
            apply_enabled();
        }

        private bool assist_enabled() {
            if (_settings == null) return true;
            return !_settings.settings_schema.has_key(ASSIST_KEY) || _settings.get_boolean(ASSIST_KEY);
        }

        private void apply_enabled() {
            bool enabled = _settings == null
                || (_settings.get_boolean(ENABLED_KEY) && !_settings.get_boolean("tiling-enabled"));
            SnapBridge.set_enabled(enabled);
            message("Snap layouts: picker %s", enabled ? "enabled" : "disabled");
            if (!enabled && _picker != null) _picker.dismiss();
        }

        private SnapPicker ensure_picker() {
            if (_picker == null) {
                _picker = new SnapPicker(_app);
                _picker.zone_chosen.connect(on_zone_chosen);
                _picker.closed.connect(on_picker_closed);
            }
            return _picker;
        }

        private void on_zone_chosen(SnapPicker picker, SnapLayout layout, SnapZone zone) {
            var area = picker.area;
            picker.dismiss();
            snap(_toplevel, area, layout, zone);
        }

        private void on_picker_closed(SnapPicker picker) {
            if (_picker != picker) return;
            _picker = null;
            Idle.add(() => {
                picker.destroy();
                return Source.REMOVE;
            });
        }

        private SnapAssist ensure_assist() {
            if (_assist == null) {
                _assist = new SnapAssist(_app);
                _assist.window_chosen.connect((handle, zone) => {
                    send_zone(handle, _area, zone);
                    Singularity.wayland_activate_window(handle);
                });
            }
            return _assist;
        }

        private void on_event(SnapBridge.EventKind kind, void* toplevel, uint source,
                              int x, int y, int width, int height,
                              int area_x, int area_y, int area_width, int area_height) {
            switch (kind) {
                case SnapBridge.EventKind.SHOW:
                    if (_assist != null && _assist.is_open) return;
                    _toplevel = toplevel;
                    _area = SnapRect(area_x, area_y, area_width, area_height);
                    ensure_picker().open(source, SnapRect(x, y, width, height), _area);
                    if (source == 1) {
                        var s = _picker.surface;
                        SnapBridge.set_picker_area(s.x, s.y, s.width, s.height);
                    }
                    break;
                case SnapBridge.EventKind.MOTION:
                    if (_picker == null || !_picker.is_open) return;
                    SnapLayout? layout;
                    var zone = _picker.hover_layout_point(x, y, out layout);
                    if (zone != null) {
                        var r = zone.rect_in(_area);
                        SnapBridge.set_zone_preview(r.x, r.y, r.width, r.height, true);
                    } else {
                        SnapBridge.set_zone_preview(0, 0, 0, 0, false);
                    }
                    break;
                case SnapBridge.EventKind.HIDE:
                    if (_picker == null) return;
                    if (source == 0) {
                        _picker.button_left();
                    } else {
                        SnapBridge.set_picker_area(0, 0, 0, 0);
                        _picker.dismiss();
                    }
                    break;
                case SnapBridge.EventKind.DROP:
                    SnapBridge.set_picker_area(0, 0, 0, 0);
                    SnapBridge.set_zone_preview(0, 0, 0, 0, false);
                    if (_picker == null) return;
                    SnapLayout? layout;
                    var zone = _picker.hover_layout_point(x, y, out layout);
                    var area = _picker.area;
                    _picker.dismiss();
                    if (zone != null && layout != null) snap(toplevel, area, layout, zone);
                    break;
            }
        }

        private void send_zone(void* handle, SnapRect area, SnapZone zone) {
            SnapBridge.snap_to_zone(handle, area.x + area.width / 2, area.y + area.height / 2,
                zone.x, zone.y, zone.width, zone.height);
        }

        private void snap(void* toplevel, SnapRect area, SnapLayout layout, SnapZone zone) {
            if (toplevel == null) return;
            _area = area;
            send_zone(toplevel, area, zone);
            message("Snap layouts: snapped to %s zone %d,%d %dx%d", layout.id, zone.x, zone.y, zone.width, zone.height);
            if (!assist_enabled()) return;
            var rest = layout.remaining(zone);
            if (rest.length == 0) return;
            var monitor = monitor_for(area);
            if (!ensure_assist().open(monitor, area, rest, toplevel)) {
                message("Snap layouts: no other windows to suggest");
            }
        }

        private static Gdk.Monitor? monitor_for(SnapRect area) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            int cx = area.x + area.width / 2;
            int cy = area.y + area.height / 2;
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = (Gdk.Monitor) monitors.get_item(i);
                var g = monitor.geometry;
                if (cx >= g.x && cx < g.x + g.width && cy >= g.y && cy < g.y + g.height) return monitor;
            }
            return null;
        }
    }
}
