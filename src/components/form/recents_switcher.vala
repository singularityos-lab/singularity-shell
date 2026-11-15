using Gtk;
using GtkLayerShell;

namespace Singularity {

    private class RecentsShot : Widget {
        private const float RADIUS = 16.0f;

        private int _width;
        private int _height;
        private Gdk.Paintable? _paintable = null;

        public Gdk.Paintable? paintable {
            get { return _paintable; }
            set { _paintable = value; queue_draw(); }
        }

        public RecentsShot(int width, int height) {
            _width = width;
            _height = height;
            overflow = Overflow.HIDDEN;
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = natural = orientation == Orientation.HORIZONTAL ? _width : _height;
            minimum_baseline = natural_baseline = -1;
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (_paintable == null) return;
            double iw = _paintable.get_intrinsic_width();
            double ih = _paintable.get_intrinsic_height();
            if (iw <= 0 || ih <= 0) return;
            int w = get_width();
            int h = get_height();
            double scale = double.max(w / iw, h / ih);
            double dw = iw * scale;
            double dh = ih * scale;
            var bounds = Graphene.Rect().init(0, 0, w, h);
            var clip = Gsk.RoundedRect().init_from_rect(bounds, RADIUS);
            snapshot.push_rounded_clip(clip);
            snapshot.save();
            snapshot.translate(Graphene.Point().init((float) ((w - dw) / 2.0), 0));
            _paintable.snapshot(snapshot, dw, dh);
            snapshot.restore();
            snapshot.pop();
        }
    }

    public class RecentsSwitcher : Gtk.Window {
        private const double CLOSE_SWIPE = 120.0;
        private const double CARD_RATIO = 0.62;
        private const int CARD_MAX_WIDTH = 420;
        private const int TV_CARD_WIDTH = 440;

        private Box _cards;
        private ScrolledWindow _scroll;
        private Label _empty;
        private Button _close_all;
        private Singularity.Animation.MotionBin _stage;
        private int _card_width = 260;
        private int _card_height = 460;
        private bool _closing = false;
        private Gdk.Monitor? _monitor = null;

        public signal void dismissed();

        public RecentsSwitcher(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-recents");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("recents");

            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("recents-page");
            _cards = new Box(Orientation.HORIZONTAL, 18);
            _cards.add_css_class("recents-cards");
            _cards.valign = Align.CENTER;
            _cards.halign = Align.CENTER;
            _scroll = new ScrolledWindow();
            _scroll.vscrollbar_policy = PolicyType.NEVER;
            _scroll.hscrollbar_policy = PolicyType.EXTERNAL;
            _scroll.vexpand = true;
            _scroll.child = _cards;
            _empty = new Label(_("No Recent Apps"));
            _empty.add_css_class("recents-empty");
            _empty.vexpand = true;
            _close_all = new Button.with_label(_("Close All"));
            _close_all.add_css_class("recents-close-all");
            _close_all.halign = Align.CENTER;
            _close_all.clicked.connect(() => close_all());
            page.append(_scroll);
            page.append(_empty);
            page.append(_close_all);
            _stage = new Singularity.Animation.MotionBin(page);
            set_child(_stage);

            var tap = new GestureClick();
            tap.released.connect((n, x, y) => {
                var picked = page.pick(x, y, PickFlags.DEFAULT);
                if (picked == page || picked == _scroll || picked == _cards || picked == _empty) dismiss();
            });
            page.add_controller(tap);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape || keyval == Gdk.Key.BackSpace) {
                    dismiss();
                    return true;
                }
                if (keyval == Gdk.Key.Up) {
                    var focus = get_focus();
                    var card = focus != null ? find_card(focus) : null;
                    if (card != null) {
                        fling(card);
                        return true;
                    }
                }
                return false;
            });
            ((Widget) this).add_controller(keys);
        }

        public void open(Gdk.Monitor? monitor) {
            _monitor = monitor;
            if (monitor != null) set_monitor(this, monitor);
            measure_cards();
            fill();
            _closing = false;
            present();
            _stage.opacity = 0.0;
            Singularity.Motion.tween(_stage, "opacity", 1.0, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
            Widget[] cards = {};
            for (var c = _cards.get_first_child(); c != null; c = c.get_next_sibling()) cards += c;
            Singularity.Motion.cascade(cards, Singularity.Motion.Preset.SCALE_FADE);
            var first = _cards.get_first_child();
            if (first != null) first.grab_focus();
        }

        public void dismiss() {
            if (_closing || !visible) return;
            _closing = true;
            var fade = Singularity.Motion.tween(_stage, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                if (!_closing) return;
                close_layer_window(this);
                _stage.opacity = 1.0;
                dismissed();
            });
        }

        private void measure_cards() {
            var display = Gdk.Display.get_default();
            if (display == null || display.get_monitors().get_n_items() == 0) return;
            var monitor = _monitor ?? display.get_monitors().get_item(0) as Gdk.Monitor;
            var geo = monitor.geometry;
            bool tv = Singularity.FormFactor.at(monitor) == Singularity.FormFactorKind.TV;
            _card_width = tv ? TV_CARD_WIDTH : int.min(CARD_MAX_WIDTH, (int) (geo.width * CARD_RATIO));
            _card_height = (int) (_card_width * (double) geo.height / geo.width);
        }

        private void fill() {
            Widget? w;
            while ((w = _cards.get_first_child()) != null) _cards.remove(w);
            int n = 0;
            var display = Gdk.Display.get_default();
            bool filter = _monitor != null && display != null && display.get_monitors().get_n_items() > 1;
            foreach (var win in AppSystem.get_default().get_mru_windows()) {
                if (filter && Singularity.wayland_get_window_monitor(win.handle) != _monitor) continue;
                _cards.append(card_for(win));
                n++;
            }
            _scroll.visible = n > 0;
            _close_all.visible = n > 0;
            _empty.visible = n == 0;
        }

        private Widget card_for(AppSystem.Window win) {
            var box = new Box(Orientation.VERTICAL, 10);
            box.add_css_class("recents-card");
            var head = new Box(Orientation.HORIZONTAL, 8);
            var icon = win.gicon != null ? new Image.from_gicon(win.gicon) : new Image.from_icon_name(win.icon_name);
            icon.pixel_size = 24;
            var title = new Label(win.title);
            title.ellipsize = Pango.EllipsizeMode.END;
            title.xalign = 0;
            title.hexpand = true;
            title.add_css_class("recents-title");
            head.append(icon);
            head.append(title);
            var shot = new RecentsShot(_card_width, _card_height);
            shot.add_css_class("recents-shot");
            PreviewCache.get_default().request(win.handle, _card_width, _card_height, (texture) => {
                if (texture != null) shot.paintable = texture;
            });
            box.append(head);
            box.append(shot);
            var motion = new Singularity.Animation.MotionBin(box);
            motion.focusable = true;
            motion.set_data<void*>("switcher-window", win.handle);
            motion.update_property(Gtk.AccessibleProperty.LABEL, win.title, -1);

            var click = new GestureClick();
            click.released.connect(() => open_window(motion));
            motion.add_controller(click);
            var drag = new GestureDrag();
            drag.drag_update.connect((dx, dy) => {
                if (Math.fabs(dy) < Math.fabs(dx)) return;
                drag.set_state(EventSequenceState.CLAIMED);
                motion.translate_y = double.min(0.0, dy);
                motion.opacity = 1.0 - double.min(0.6, -motion.translate_y / (_card_height * 1.5));
            });
            drag.drag_end.connect((dx, dy) => {
                if (dy < -CLOSE_SWIPE) fling(motion);
                else {
                    Singularity.Motion.spring_to(motion, "translate-y", 0.0, Singularity.Motion.Spring.BOUNCY);
                    Singularity.Motion.tween(motion, "opacity", 1.0, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
                }
            });
            motion.add_controller(drag);
            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter || keyval == Gdk.Key.space) {
                    open_window(motion);
                    return true;
                }
                return false;
            });
            motion.add_controller(keys);
            return motion;
        }

        private Singularity.Animation.MotionBin? find_card(Widget widget) {
            for (Widget? w = widget; w != null; w = w.get_parent()) {
                if (w.get_parent() == _cards) return w as Singularity.Animation.MotionBin;
            }
            return null;
        }

        private void open_window(Singularity.Animation.MotionBin card) {
            var handle = card.get_data<void*>("switcher-window");
            if (handle != null) Singularity.wayland_activate_window(handle);
            dismiss();
        }

        private void fling(Singularity.Animation.MotionBin card) {
            var handle = card.get_data<void*>("switcher-window");
            var out = Singularity.Motion.tween(card, "translate-y", -(_card_height + 200.0),
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.EXIT);
            Singularity.Motion.tween(card, "opacity", 0.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.EXIT);
            out.done.connect(() => {
                if (handle != null) Singularity.close_window(handle);
                var next = card.get_next_sibling() ?? card.get_prev_sibling();
                _cards.remove(card);
                if (next != null) next.grab_focus();
                if (_cards.get_first_child() == null) dismiss();
            });
        }

        private void close_all() {
            uint i = 0;
            for (var c = _cards.get_first_child(); c != null; c = c.get_next_sibling()) {
                var card = c as Singularity.Animation.MotionBin;
                if (card == null) continue;
                uint delay = Singularity.Motion.stagger_delay(i++);
                Timeout.add(delay + 1, () => {
                    if (card.get_parent() == _cards) fling(card);
                    return Source.REMOVE;
                });
            }
        }
    }
}
