using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class SplitDivider : Gtk.Window {
        private const int HANDLE = 36;
        private const double MIN_SHARE = 0.25;
        private const double DISMISS_SHARE = 0.14;
        private const double[] STOPS = { 1.0 / 3.0, 0.5, 2.0 / 3.0 };

        private unowned Gdk.Monitor _monitor;
        private Gdk.Rectangle _area;
        private void* _left = null;
        private void* _right = null;
        private int _gap = 0;
        private int _split = 0;
        private double _drag_origin = 0;
        private bool _dragging = false;
        private Fixed _canvas;
        private Singularity.Animation.MotionBin _handle;
        private Box[] _guides = {};
        private int _active_stop = -1;

        public bool dragging { get { return _dragging; } }

        public signal void dismissed_side(void* gone, void* kept);

        public SplitDivider(Gtk.Application app, Gdk.Monitor monitor, int top, int bottom) {
            Object(application: app);
            _monitor = monitor;
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-split-divider");
            set_layer(this, GtkLayerShell.Layer.TOP);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_margin(this, GtkLayerShell.Edge.TOP, top);
            set_margin(this, GtkLayerShell.Edge.BOTTOM, bottom);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("split-divider");
            var geo = monitor.geometry;
            _area = { geo.x, geo.y + top, geo.width, geo.height - top - bottom };

            _canvas = new Fixed();
            _canvas.can_target = true;
            foreach (var stop in STOPS) {
                var guide = new Box(Orientation.VERTICAL, 0);
                guide.add_css_class("split-guide");
                guide.set_size_request(2, _area.height);
                guide.opacity = 0.0;
                guide.can_target = false;
                _canvas.put(guide, (int) (_area.width * stop) - 1, 0);
                _guides += guide;
            }

            var strip = new Box(Orientation.VERTICAL, 0);
            strip.set_size_request(HANDLE, _area.height);
            var pill = new Box(Orientation.VERTICAL, 0);
            pill.add_css_class("phone-nav-pill");
            pill.add_css_class("split-pill");
            pill.halign = Align.CENTER;
            pill.valign = Align.CENTER;
            pill.vexpand = true;
            strip.append(pill);
            _handle = new Singularity.Animation.MotionBin(strip);
            _canvas.put(_handle, 0, 0);

            var drag = new GestureDrag();
            drag.drag_begin.connect(() => begin_drag());
            drag.drag_update.connect((dx, dy) => follow(dx));
            drag.drag_end.connect((dx, dy) => release(dx));
            _handle.add_controller(drag);

            set_child(_canvas);
            map.connect_after(() => update_input_region());
        }

        public Gdk.Monitor monitor { get { return _monitor; } }

        public void track(void* left, void* right, int split, int gap) {
            if (_dragging) return;
            _left = left;
            _right = right;
            _gap = gap;
            _split = split;
            place_handle(split - _area.x);
        }

        private void place_handle(double local) {
            _canvas.move(_handle, (int) Math.round(local) - HANDLE / 2, 0);
            update_input_region();
        }

        private void update_input_region() {
            var surface = get_surface();
            if (surface == null) return;
            int local = _split - _area.x;
            var rect = Cairo.RectangleInt() { x = local - HANDLE / 2, y = 0, width = HANDLE, height = _area.height };
            if (_dragging) rect = Cairo.RectangleInt() { x = 0, y = 0, width = _area.width, height = _area.height };
            surface.set_input_region(new Cairo.Region.rectangle(rect));
        }

        private void begin_drag() {
            _dragging = true;
            _drag_origin = _split - _area.x;
            _active_stop = -1;
            update_input_region();
            foreach (var guide in _guides) Singularity.Motion.tween(guide, "opacity", 0.35, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_handle, "scale", 1.15, Singularity.Motion.Spring.SNAPPY);
        }

        private int nearest_stop(double local) {
            int best = 0;
            double distance = double.MAX;
            for (int i = 0; i < STOPS.length; i++) {
                double d = Math.fabs(local - _area.width * STOPS[i]);
                if (d < distance) {
                    distance = d;
                    best = i;
                }
            }
            return best;
        }

        private void follow(double dx) {
            if (!_dragging) return;
            double local = (_drag_origin + dx).clamp(_area.width * DISMISS_SHARE * 0.5, _area.width * (1.0 - DISMISS_SHARE * 0.5));
            _split = _area.x + (int) Math.round(local);
            place_handle(local);
            double share = local / _area.width;
            if (share >= MIN_SHARE && share <= 1.0 - MIN_SHARE) apply_split(_split, false);
            int stop = nearest_stop(local);
            if (stop == _active_stop) return;
            _active_stop = stop;
            for (int i = 0; i < _guides.length; i++) {
                if (i == stop) _guides[i].add_css_class("active");
                else _guides[i].remove_css_class("active");
            }
        }

        private void release(double dx) {
            if (!_dragging) return;
            follow(dx);
            _dragging = false;
            foreach (var guide in _guides) {
                guide.remove_css_class("active");
                Singularity.Motion.tween(guide, "opacity", 0.0, Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            }
            Singularity.Motion.spring_to(_handle, "scale", 1.0, Singularity.Motion.Spring.BOUNCY);
            double local = _split - _area.x;
            double share = local / _area.width;
            if (share < DISMISS_SHARE * 1.5) {
                dismissed_side(_left, _right);
                return;
            }
            if (share > 1.0 - DISMISS_SHARE * 1.5) {
                dismissed_side(_right, _left);
                return;
            }
            int target = _area.x + (int) Math.round(_area.width * STOPS[nearest_stop(local)]);
            settle(target);
        }

        public double handle_x {
            get { return _handle_x; }
            set {
                _handle_x = value;
                place_handle(value);
            }
        }
        private double _handle_x = 0;

        private void settle(int target) {
            _handle_x = _split - _area.x;
            _split = target;
            apply_split(target, true);
            Singularity.Motion.spring_to(this, "handle-x", target - _area.x, Singularity.Motion.Spring.SNAPPY);
        }

        private void apply_split(int split, bool animated) {
            if (_left == null || _right == null) return;
            int half = _gap / 2;
            int left_w = split - half - _area.x;
            int right_x = split + (_gap - half);
            int right_w = _area.x + _area.width - right_x;
            if (left_w <= 0 || right_w <= 0) return;
            if (animated && Singularity.wayland_can_animate_geometry()) {
                Singularity.wayland_set_geometry_animated(_left, _area.x, _area.y, left_w, _area.height);
                Singularity.wayland_set_geometry_animated(_right, right_x, _area.y, right_w, _area.height);
            } else {
                Singularity.wayland_set_geometry(_left, _area.x, _area.y, left_w, _area.height);
                Singularity.wayland_set_geometry(_right, right_x, _area.y, right_w, _area.height);
            }
        }
    }
}
