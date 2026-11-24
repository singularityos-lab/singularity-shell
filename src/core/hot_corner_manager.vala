using Gtk;
using GtkLayerShell;
using GLib;
using Gee;

namespace Singularity {

    public class HotCornerManager : Object {
        private const int CORNER_SIZE = 24;
        private const int CORNER_HYSTERESIS = 48;
        private const int TRIGGER_DELAY_MS = 150;
        // The action only arms once the pointer is pushed right against the
        // screen edge (within EDGE_TRIGGER px) while still moving into it, so
        // brushing past a corner no longer fires it (issue #111). The wider
        // CORNER_SIZE band only lights the hint.
        private const int EDGE_TRIGGER = 4;
        private double _last_x = -1;

        private Gtk.Application _app;
        private GLib.Settings settings;
        private string[] _actions = { "none", "none", "none", "none" };
        private uint _timer_id = 0;
        private string? _pending_action = null;
        private int _pending_corner = -1;
        private HotCornerHintWindow?[] _hints = new HotCornerHintWindow?[4];

        public signal void overview_triggered();
        public signal void workspaces_triggered();
        public signal void settings_triggered();

        public HotCornerManager(Gtk.Application app) {
            _app = app;
            settings = new GLib.Settings("dev.sinty.desktop");
            reload_actions();
            settings.changed.connect((key) => {
                if (key.has_prefix("hot-corner-")) reload_actions();
            });
        }

        private void reload_actions() {
            _actions[0] = settings.get_string("hot-corner-top-left");
            _actions[1] = settings.get_string("hot-corner-top-right");
            _actions[2] = settings.get_string("hot-corner-bottom-left");
            _actions[3] = settings.get_string("hot-corner-bottom-right");
        }

        public void attach_to_panel(Gtk.Widget panel) {
            var motion = new Gtk.EventControllerMotion();
            motion.motion.connect((x, y) => {
                handle_edge_motion(panel.get_width(), x, 0, 1);
            });
            motion.leave.connect(() => {
                _last_x = -1;
                on_leave();
            });
            panel.add_controller(motion);
        }

        public void attach_to_dock(Gtk.Widget dock) {
            var motion = new Gtk.EventControllerMotion();
            motion.motion.connect((x, y) => {
                handle_edge_motion(dock.get_width(), x, 2, 3);
            });
            motion.leave.connect(() => {
                _last_x = -1;
                on_leave();
            });
            dock.add_controller(motion);
        }

        private void handle_edge_motion(int w, double x, int left_corner, int right_corner) {
            var hit = HotCornerLogic.evaluate(w, x, _last_x, CORNER_SIZE, EDGE_TRIGGER,
                _actions[left_corner] != "none", _actions[right_corner] != "none",
                left_corner, right_corner);
            _last_x = x;

            int hint_corner = hit.hint_corner;
            string? hint_action = hint_corner >= 0 ? _actions[hint_corner] : null;
            int arm_corner = hit.arm ? hit.hint_corner : -1;
            string? arm_action = hit.arm ? hint_action : null;

            // Keep an armed trigger alive while the pointer lingers near the
            // corner, so a tiny inward drift before the delay elapses doesn't
            // cancel it.
            if (arm_action == null && _pending_corner >= 0 && _timer_id != 0) {
                if (_pending_corner == left_corner && x < CORNER_HYSTERESIS) {
                    show_hint(hint_corner, hint_action);
                    return;
                }
                if (_pending_corner == right_corner && w > 0 && x > w - CORNER_HYSTERESIS) {
                    show_hint(hint_corner, hint_action);
                    return;
                }
            }

            show_hint(hint_corner, hint_action);
            handle_hover(arm_action, arm_corner);
        }

        private void on_leave() {
            if (_timer_id != 0) {
                GLib.Source.remove(_timer_id);
                _timer_id = 0;
            }
            _pending_action = null;
            _pending_corner = -1;
            hide_hints();
        }

        private void show_hint(int corner, string? action) {
            if (corner < 0 || action == null) {
                hide_hints();
                return;
            }
            for (int i = 0; i < 4; i++) {
                if (i != corner && _hints[i] != null) _hints[i].hide_hint();
            }
            if (_hints[corner] == null) {
                _hints[corner] = new HotCornerHintWindow(_app, corner);
            }
            _hints[corner].show_hint(action);
        }

        private void hide_hints() {
            for (int i = 0; i < 4; i++) {
                if (_hints[i] != null) _hints[i].hide_hint();
            }
        }

        private void handle_hover(string? action, int corner) {
            if (action == _pending_action) return;

            if (_timer_id != 0) {
                GLib.Source.remove(_timer_id);
                _timer_id = 0;
            }

            _pending_action = action;
            _pending_corner = corner;

            if (action != null) {
                _timer_id = GLib.Timeout.add(TRIGGER_DELAY_MS, fire_pending_action);
            }
        }

        private bool fire_pending_action() {
            _timer_id = 0;
            if (_pending_action != null) fire_action(_pending_action);
            return GLib.Source.REMOVE;
        }

        private void fire_action(string action) {
            hide_hints();
            if (action == "workspaces") workspaces_triggered();
            else if (action == "overview") overview_triggered();
            else if (action == "settings") settings_triggered();
        }

        public void simulate_corner(int corner_idx) {
            if (corner_idx < 0 || corner_idx >= 4) return;
            if (_actions[corner_idx] != "none")
                fire_action(_actions[corner_idx]);
        }

    }

    internal class HotCornerHintWindow : Gtk.Window {
        private Overlay hint;
        private Image icon;

        public HotCornerHintWindow(Gtk.Application app, int corner) {
            Object(application: app);

            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            set_anchor(this, GtkLayerShell.Edge.TOP, corner == 0 || corner == 1);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, corner == 2 || corner == 3);
            set_anchor(this, GtkLayerShell.Edge.LEFT, corner == 0 || corner == 2);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, corner == 1 || corner == 3);

            var mon = Singularity.Panel.find_primary_monitor();
            if (mon != null) GtkLayerShell.set_monitor(this, mon);

            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("hot-corner-window");
            can_target = false;
            map.connect_after(() => {
                Singularity.surface_set_input_passthrough(this);
            });

            hint = new Overlay();
            hint.add_css_class("corner-hint");
            switch (corner) {
                case 0: hint.add_css_class("corner-hint-tl"); break;
                case 1: hint.add_css_class("corner-hint-tr"); break;
                case 2: hint.add_css_class("corner-hint-bl"); break;
                case 3: hint.add_css_class("corner-hint-br"); break;
            }
            hint.can_target = false;
            hint.set_size_request(112, 112);

            var glow = new Box(Orientation.HORIZONTAL, 0);
            glow.add_css_class("corner-hint-glow");
            hint.set_child(glow);

            var badge = new Box(Orientation.HORIZONTAL, 0);
            badge.add_css_class("corner-hint-badge");
            badge.halign = (corner == 1 || corner == 3) ? Align.END : Align.START;
            badge.valign = (corner == 2 || corner == 3) ? Align.END : Align.START;
            if (badge.halign == Align.START) badge.margin_start = 12;
            else badge.margin_end = 12;
            if (badge.valign == Align.START) badge.margin_top = 12;
            else badge.margin_bottom = 12;

            icon = new Image.from_icon_name("view-app-grid-symbolic");
            icon.pixel_size = 18;
            icon.width_request = 24;
            icon.height_request = 24;
            icon.halign = Align.CENTER;
            icon.valign = Align.CENTER;
            badge.append(icon);
            hint.add_overlay(badge);

            set_child(hint);
            close_layer_window (this);
        }

        public void show_hint(string action) {
            icon.icon_name = icon_for_action(action);
            hint.add_css_class("visible");
            present();
        }

        public void hide_hint() {
            hint.remove_css_class("visible");
            close_layer_window (this);
        }

        private static string icon_for_action(string? action) {
            switch (action) {
                case "workspaces": return "dev.sinty.workspaces";
                case "overview":   return "view-app-grid-symbolic";
                case "settings":   return "emblem-system-symbolic";
                default:           return "go-next-symbolic";
            }
        }
    }
}
