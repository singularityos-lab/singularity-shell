using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class HubPeek : Object {
        private const int EDGE = 18;
        private const double COMMIT = 0.3;
        private const double FLING = 900.0;
        private const double SLOP = 8.0;
        private const int64 EXPECT_US = 8 * TimeSpan.SECOND;

        private static HubPeek? instance = null;

        private string _expected = "";
        private string _expected_class = "";
        private int64 _expected_until = 0;
        private void* _handle = null;
        private Gtk.Window? _strip = null;
        private unowned Gdk.Monitor? _strip_monitor = null;
        private WindowCard? _card = null;
        private Graphene.Rect _rect;
        private bool _dragging = false;
        private GestureSwipe? _velocity = null;
        private uint _monitor_retry = 0;

        public static HubPeek get_default() {
            if (instance == null) instance = new HubPeek();
            return instance;
        }

        private HubPeek() {
            var apps = AppSystem.get_default();
            apps.window_focused.connect(on_focused);
            apps.app_opened.connect((handle, app_id) => {
                if (handle == AppSystem.get_default().get_focused_window_handle()) on_focused(handle);
            });
            apps.app_closed.connect((handle) => {
                if (handle == _handle) untrack();
            });
            apps.window_state_changed.connect((handle) => {
                if (handle == _handle) update_strip();
            });
            apps.window_output_changed.connect((handle) => {
                if (handle == _handle) update_strip();
            });
        }

        private static string normalize(string id) {
            string s = id.down();
            if (s.has_suffix(".desktop")) s = s.substring(0, s.length - 8);
            return s;
        }

        public void expect(string app_id) {
            _expected = normalize(app_id);
            _expected_class = "";
            var info = new DesktopAppInfo(_expected + ".desktop");
            if (info != null) {
                string? wm = info.get_startup_wm_class();
                if (wm != null) _expected_class = normalize(wm);
            }
            _expected_until = get_monotonic_time() + EXPECT_US;
        }

        private bool matches(AppSystem.Window win) {
            if (_expected == "" || get_monotonic_time() > _expected_until) return false;
            string id = normalize(win.app_id);
            if (id == _expected || id == _expected_class) return true;
            int dot = _expected.last_index_of_char('.');
            return dot > 0 && id == _expected.substring(dot + 1);
        }

        private AppSystem.Window? window_for(void* handle) {
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (win.handle == handle) return win;
            }
            return null;
        }

        private void on_focused(void* handle) {
            if (handle == null) {
                hide_strip();
                return;
            }
            if (handle == _handle) {
                update_strip();
                return;
            }
            var win = window_for(handle);
            if (win != null && matches(win)) {
                _expected = "";
                _handle = handle;
                update_strip();
                return;
            }
            hide_strip();
        }

        private void untrack() {
            _handle = null;
            if (_monitor_retry != 0) {
                Source.remove(_monitor_retry);
                _monitor_retry = 0;
            }
            if (_card != null) {
                _card.close();
                _card = null;
            }
            _dragging = false;
            hide_strip();
        }

        private void update_strip() {
            var win = _handle != null ? window_for(_handle) : null;
            if (win == null || win.is_minimized || win.is_fullscreen) {
                hide_strip();
                return;
            }
            var monitor = Singularity.wayland_get_window_monitor(_handle);
            if (monitor == null) {
                hide_strip();
                if (_monitor_retry == 0) _monitor_retry = Timeout.add(150, () => {
                    _monitor_retry = 0;
                    update_strip();
                    return Source.REMOVE;
                });
                return;
            }
            if (_strip != null && _strip_monitor != monitor) {
                _strip.destroy();
                _strip = null;
            }
            if (_strip == null) build_strip(monitor);
            _strip.present();
        }

        private void hide_strip() {
            if (_strip != null && !_dragging) _strip.visible = false;
        }

        private void build_strip(Gdk.Monitor monitor) {
            var strip = new Gtk.Window();
            strip.application = (Gtk.Application) GLib.Application.get_default();
            init_for_window(strip);
            set_monitor(strip, monitor);
            set_namespace(strip, "singularity-hub-peek");
            set_layer(strip, GtkLayerShell.Layer.OVERLAY);
            set_anchor(strip, GtkLayerShell.Edge.LEFT, true);
            set_anchor(strip, GtkLayerShell.Edge.TOP, true);
            set_anchor(strip, GtkLayerShell.Edge.BOTTOM, true);
            set_exclusive_zone(strip, -1);
            set_keyboard_mode(strip, GtkLayerShell.KeyboardMode.NONE);
            strip.add_css_class("hub-peek-edge");
            strip.set_default_size(EDGE, -1);
            var area = new Box(Orientation.VERTICAL, 0);
            area.width_request = EDGE;
            area.vexpand = true;
            strip.child = area;

            var drag = new GestureDrag();
            drag.drag_begin.connect(() => _dragging = false);
            drag.drag_update.connect((dx, dy) => {
                if (!_dragging) {
                    if (dx < SLOP || Math.fabs(dx) < Math.fabs(dy)) return;
                    if (!begin()) return;
                    drag.set_state(EventSequenceState.CLAIMED);
                }
                follow(dx);
            });
            drag.drag_end.connect((dx, dy) => {
                if (!_dragging) return;
                double vx = 0, vy = 0;
                if (_velocity == null || !_velocity.get_velocity(out vx, out vy)) vx = 0;
                finish(dx, vx);
            });
            drag.cancel.connect(() => {
                if (_dragging) finish(0, 0);
            });
            area.add_controller(drag);
            _velocity = new GestureSwipe();
            area.add_controller(_velocity);
            _strip = strip;
            _strip_monitor = monitor;
        }

        private bool begin() {
            if (_handle == null || !WindowCardBridge.available()) return false;
            int x, y, w, h, maximized, fullscreen;
            string? connector;
            if (!Singularity.wayland_get_window_geometry(_handle, out x, out y, out w, out h,
                    out maximized, out fullscreen, out connector) || w <= 0 || h <= 0) return false;
            _rect = Graphene.Rect().init(x, y, w, h);
            _card = new WindowCard(_handle);
            if (!_card.valid) {
                _card = null;
                return false;
            }
            _dragging = true;
            return true;
        }

        private Graphene.Rect shifted(double dx) {
            return Graphene.Rect().init(_rect.origin.x + (float) dx, _rect.origin.y, _rect.size.width, _rect.size.height);
        }

        private void follow(double dx) {
            if (_card == null) return;
            _card.place(shifted(double.max(0.0, dx)), 0.0);
        }

        private void finish(double dx, double vx) {
            var card = _card;
            _card = null;
            _dragging = false;
            if (card == null) return;
            bool leave = dx > _rect.size.width * COMMIT;
            if (vx > FLING) leave = true;
            else if (vx < -FLING) leave = false;
            ulong id = 0;
            id = card.landed.connect(() => {
                card.disconnect(id);
                card.close();
            });
            if (leave) {
                card.release(true, shifted(_rect.size.width), 0.0, vx, 0.0);
                _handle = null;
                hide_strip();
            } else {
                card.release(false, _rect, 0.0, vx, 0.0);
            }
        }
    }
}
