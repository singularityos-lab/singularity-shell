namespace Singularity {

    public class WindowCard : Object {
        private void* _card = null;

        public signal void landed();

        public WindowCard(void* handle) {
            _card = WindowCardBridge.create(handle, () => landed());
        }

        public bool valid {
            get { return _card != null; }
        }

        public void place(Graphene.Rect rect, double radius) {
            if (_card == null) return;
            WindowCardBridge.set_rect(_card, (int) Math.round(rect.origin.x), (int) Math.round(rect.origin.y),
                (int) Math.round(rect.size.width), (int) Math.round(rect.size.height), (int) Math.round(radius));
        }

        public void release(bool minimize, Graphene.Rect? target, double radius, double vx, double vy) {
            if (_card == null) return;
            if (target == null) {
                WindowCardBridge.release(_card, minimize, 0, 0, 0, 0, 0, (int) vx, (int) vy);
                return;
            }
            WindowCardBridge.release(_card, minimize, (int) Math.round(target.origin.x), (int) Math.round(target.origin.y),
                (int) Math.round(target.size.width), (int) Math.round(target.size.height), (int) Math.round(radius),
                (int) vx, (int) vy);
        }

        public void close() {
            if (_card == null) return;
            var card = _card;
            _card = null;
            WindowCardBridge.free(card);
        }
    }

    public class HomeGesture : Object {
        private const double DECIDE = 10.0;
        private const double HOME_TRAVEL = 0.42;
        private const double MIN_SCALE = 0.32;
        private const double MAX_RADIUS = 38.0;
        private const double COMMIT_PROGRESS = 0.3;
        private const double FLING_UP = 450.0;
        private const double HOLD_RADIUS = 8.0;
        private const uint HOLD_MS = 220;
        private const double SWITCH_GAP = 24.0;
        private const double SWITCH_COMMIT = 0.32;
        private const double FLING_SIDE = 500.0;

        private enum Mode {
            IDLE,
            UNDECIDED,
            HOME,
            SWITCH,
            NONE
        }

        private Gdk.Monitor _monitor;
        private Mode _mode = Mode.IDLE;
        private AppSystem.Window? _active = null;
        private Graphene.Rect _rect;
        private WindowCard? _card = null;
        private WindowCard? _neighbor = null;
        private int _side = 0;
        private Singularity.Animation.VelocityTracker _vx = new Singularity.Animation.VelocityTracker();
        private Singularity.Animation.VelocityTracker _vy = new Singularity.Animation.VelocityTracker();
        private uint _hold_source = 0;
        private double _hold_x = 0.0;
        private double _hold_y = 0.0;
        private bool _armed = false;
        private double _last_dx = 0.0;
        private double _last_dy = 0.0;
        private Gee.ArrayList<WindowCard> _landing = new Gee.ArrayList<WindowCard>();

        public signal void home_reached();
        public signal void recents_requested();

        public HomeGesture(Gdk.Monitor monitor) {
            _monitor = monitor;
        }

        public bool tracking {
            get { return _mode == Mode.HOME || _mode == Mode.SWITCH; }
        }

        public bool begin() {
            reset();
            if (!WindowCardBridge.available()) return false;
            _active = top_window();
            if (_active == null) return false;
            if (!window_rect(_active, out _rect)) {
                var geo = _monitor.geometry;
                _rect = Graphene.Rect().init(geo.x, geo.y, geo.width, geo.height);
            }
            _mode = Mode.UNDECIDED;
            return true;
        }

        public bool update(double dx, double dy) {
            int64 now = GLib.get_monotonic_time();
            _vx.add(now, dx);
            _vy.add(now, dy);
            _last_dx = dx;
            _last_dy = dy;
            if (_mode == Mode.UNDECIDED) {
                if (Math.fabs(dx) < DECIDE && Math.fabs(dy) < DECIDE) return false;
                if (dy < 0 && Math.fabs(dy) >= Math.fabs(dx)) start_home();
                else if (Math.fabs(dx) > Math.fabs(dy)) start_switch(dx);
                else _mode = Mode.NONE;
            }
            if (_mode == Mode.HOME) track_home(dx, dy);
            else if (_mode == Mode.SWITCH) track_switch(dx);
            return tracking;
        }

        public void end() {
            stop_hold();
            int64 now = GLib.get_monotonic_time();
            _vx.add(now, _last_dx);
            _vy.add(now, _last_dy);
            double vx = _vx.velocity;
            double vy = _vy.velocity;
            if (_mode == Mode.HOME) finish_home(vx, vy);
            else if (_mode == Mode.SWITCH) finish_switch(vx);
            _mode = Mode.IDLE;
        }

        public void cancel() {
            stop_hold();
            if (_mode == Mode.HOME && _card != null) {
                land(_card, false, null, 0.0, 0.0, 0.0);
                _card = null;
                OnScreenKeyboard.suspend_current(false);
            } else if (_mode == Mode.SWITCH) {
                if (_card != null) land(_card, false, null, 0.0, 0.0, 0.0);
                if (_neighbor != null) land(_neighbor, true, side_rect(-_side), 0.0, 0.0, 0.0);
                _card = null;
                _neighbor = null;
            }
            _mode = Mode.IDLE;
        }

        private void reset() {
            OnScreenKeyboard.suspend_current(false);
            if (_card != null) _card.close();
            if (_neighbor != null) _neighbor.close();
            _card = null;
            _neighbor = null;
            _active = null;
            _side = 0;
            _armed = false;
            stop_hold();
            _vx.reset();
            _vy.reset();
            _mode = Mode.IDLE;
        }

        private bool window_rect(AppSystem.Window win, out Graphene.Rect rect) {
            int x, y, w, h, maximized, fullscreen;
            string? connector;
            rect = Graphene.Rect();
            if (!Singularity.wayland_get_window_geometry(win.handle, out x, out y, out w, out h,
                    out maximized, out fullscreen, out connector) || w <= 0 || h <= 0) {
                return false;
            }
            rect = Graphene.Rect().init(x, y, w, h);
            return true;
        }

        private AppSystem.Window? top_window() {
            foreach (var win in AppSystem.get_default().get_mru_windows()) {
                if (win.is_minimized) continue;
                if (Singularity.wayland_get_window_monitor(win.handle) != _monitor) continue;
                return win;
            }
            return null;
        }

        private Gee.ArrayList<AppSystem.Window> monitor_windows() {
            var list = new Gee.ArrayList<AppSystem.Window>();
            foreach (var win in AppSystem.get_default().get_mru_windows()) {
                if (Singularity.wayland_get_window_monitor(win.handle) != _monitor) continue;
                list.add(win);
            }
            return list;
        }

        private void start_home() {
            _card = new WindowCard(_active.handle);
            if (!_card.valid) {
                _card = null;
                _mode = Mode.NONE;
                return;
            }
            _mode = Mode.HOME;
            OnScreenKeyboard.suspend_current(true);
            foreach (var win in monitor_windows()) {
                if (win == _active || win.is_minimized) continue;
                Graphene.Rect place;
                if (!window_rect(win, out place)) continue;
                var hide = new WindowCard(win.handle);
                if (!hide.valid) continue;
                land(hide, true, place, 0.0, 0.0, 0.0);
            }
        }

        private double home_progress(double dy) {
            double travel = _monitor.geometry.height * HOME_TRAVEL;
            return (-dy / double.max(travel, 1.0)).clamp(0.0, 1.0);
        }

        private Graphene.Rect home_rect(double dx, double dy) {
            double p = home_progress(dy);
            double eased = 1.0 - Math.pow(1.0 - p, 2.0);
            double scale = 1.0 - (1.0 - MIN_SCALE) * eased;
            double w = _rect.size.width * scale;
            double h = _rect.size.height * scale;
            double finger_bottom = _rect.origin.y + _rect.size.height + double.min(0.0, dy) * 0.9;
            double cx = _rect.origin.x + _rect.size.width / 2.0 + dx * 0.9;
            double top = finger_bottom - h - _rect.size.height * 0.04 * eased;
            if (dy > 0) top += dy * 0.15;
            return Graphene.Rect().init((float) (cx - w / 2.0), (float) top, (float) w, (float) h);
        }

        private void track_home(double dx, double dy) {
            if (_card == null) return;
            double p = home_progress(dy);
            _card.place(home_rect(dx, dy), MAX_RADIUS * double.min(1.0, p * 3.0));
            bool moved = Math.hypot(dx - _hold_x, dy - _hold_y) > HOLD_RADIUS;
            if (moved || _hold_source == 0) {
                if (moved && _armed && Math.hypot(dx - _hold_x, dy - _hold_y) > HOLD_RADIUS * 6) _armed = false;
                _hold_x = dx;
                _hold_y = dy;
                stop_hold();
                if (p > 0.12 && !_armed) _hold_source = Timeout.add(HOLD_MS, () => {
                    _hold_source = 0;
                    if (_mode != Mode.HOME) return Source.REMOVE;
                    _armed = true;
                    Singularity.Haptics.get_default().pulse(12, 0x4000);
                    return Source.REMOVE;
                });
            }
        }

        private void stop_hold() {
            if (_hold_source == 0) return;
            Source.remove(_hold_source);
            _hold_source = 0;
        }

        private void finish_home(double vx, double vy) {
            var card = _card;
            _card = null;
            if (card == null) return;
            double p = home_progress(_last_dy);
            if (_armed && vy > -FLING_UP) {
                var geo = _monitor.geometry;
                double w = geo.width * 0.62;
                double h = w * _rect.size.height / double.max(_rect.size.width, 1.0);
                var target = Graphene.Rect().init((float) (geo.x + (geo.width - w) / 2.0),
                    (float) (geo.y + (geo.height - h) / 2.0), (float) w, (float) h);
                resume_keyboard_after(card);
                land(card, true, target, MAX_RADIUS * 0.6, vx, vy);
                recents_requested();
                return;
            }
            if (vy < -FLING_UP || (p > COMMIT_PROGRESS && vy < FLING_UP)) {
                resume_keyboard_after(card);
                land(card, true, null, 0.0, vx, vy);
                home_reached();
                return;
            }
            land(card, false, null, 0.0, vx, vy);
            OnScreenKeyboard.suspend_current(false);
        }

        private void resume_keyboard_after(WindowCard card) {
            ulong id = 0;
            id = card.landed.connect(() => {
                card.disconnect(id);
                if (_mode != Mode.HOME) OnScreenKeyboard.suspend_current(false);
            });
        }

        private Graphene.Rect side_rect(int side) {
            float offset = (float) ((_rect.size.width + SWITCH_GAP) * side);
            return Graphene.Rect().init(_rect.origin.x + offset, _rect.origin.y, _rect.size.width, _rect.size.height);
        }

        private AppSystem.Window? neighbor_for(int side) {
            var list = monitor_windows();
            list.remove(_active);
            if (list.size == 0) return null;
            return side < 0 ? list[0] : list[list.size - 1];
        }

        private void start_switch(double dx) {
            _side = dx > 0 ? -1 : 1;
            var neighbor = neighbor_for(_side);
            _card = new WindowCard(_active.handle);
            if (!_card.valid) {
                _card = null;
                _mode = Mode.NONE;
                return;
            }
            if (neighbor != null) {
                _neighbor = new WindowCard(neighbor.handle);
                if (!_neighbor.valid) _neighbor = null;
            }
            _mode = Mode.SWITCH;
        }

        private void track_switch(double dx) {
            if (_card == null) return;
            double offset = dx;
            if (_neighbor == null) {
                double limit = _rect.size.width * 0.18;
                offset = limit * Math.tanh(dx / double.max(limit, 1.0));
            } else if ((dx > 0 ? -1 : 1) != _side) {
                offset = dx * 0.25;
            }
            var current = _rect;
            current.origin.x += (float) offset;
            _card.place(current, 0.0);
            if (_neighbor != null) {
                var next = side_rect(_side);
                next.origin.x += (float) offset;
                _neighbor.place(next, 0.0);
            }
        }

        private void finish_switch(double vx) {
            var card = _card;
            var neighbor = _neighbor;
            _card = null;
            _neighbor = null;
            if (card == null) return;
            bool toward = (_side < 0 && _last_dx > 0) || (_side > 0 && _last_dx < 0);
            bool flung = (_side < 0 && vx > FLING_SIDE) || (_side > 0 && vx < -FLING_SIDE);
            bool far = Math.fabs(_last_dx) > _rect.size.width * SWITCH_COMMIT;
            if (neighbor != null && toward && (flung || far)) {
                land(card, true, side_rect(-_side), 0.0, vx, 0.0);
                land(neighbor, false, null, 0.0, vx, 0.0);
                return;
            }
            land(card, false, null, 0.0, vx, 0.0);
            if (neighbor != null) land(neighbor, true, side_rect(_side), 0.0, vx, 0.0);
        }

        private void land(WindowCard card, bool minimize, Graphene.Rect? target, double radius,
                          double vx, double vy) {
            _landing.add(card);
            ulong id = 0;
            id = card.landed.connect(() => {
                card.disconnect(id);
                _landing.remove(card);
                card.close();
            });
            card.release(minimize, target, radius, vx, vy);
        }
    }
}
