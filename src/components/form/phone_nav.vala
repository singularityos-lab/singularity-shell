using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class PhoneNavBar : Gtk.Window {
        private const double HOME_SWIPE = 40.0;
        private const double PULL_SLOP = 12.0;
        private const double SWITCH_SWIPE = 70.0;
        private const double PILL_TRAVEL = 36.0;

        public signal void back_requested();
        public signal void home_requested();
        public signal void recents_requested();
        public signal void next_requested();
        public signal void previous_requested();
        public signal void companion_requested();
        public signal bool pull_begin();
        public signal void pull_update(double dy);
        public signal void pull_end(double dy);

        private Singularity.Animation.MotionBin _pill_motion;
        private Singularity.Animation.MotionBin _bar_motion;
        private bool _gesture_fired = false;
        private bool _pulling = false;
        private bool _tracking = false;
        private Button _companion;

        public HomeGesture? gesture { get; set; default = null; }

        public PhoneNavBar(Gtk.Application app, Gdk.Monitor monitor, bool handle_only = false) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-phone-nav");
            set_layer(this, handle_only ? GtkLayerShell.Layer.OVERLAY : GtkLayerShell.Layer.TOP);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, !handle_only);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, !handle_only);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            if (!handle_only) auto_exclusive_zone_enable(this);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("phone-nav");
            if (handle_only) add_css_class("handle-only");

            var bar = new CenterBox();
            bar.add_css_class("phone-nav-bar");
            var back = nav_button("go-previous-symbolic", _("Back"));
            back.clicked.connect(() => back_requested());
            var home = new Button();
            home.add_css_class("phone-nav-home");
            home.tooltip_text = _("Home");
            home.update_property(Gtk.AccessibleProperty.LABEL, _("Home"), -1);
            var pill = new Box(Orientation.HORIZONTAL, 0);
            pill.add_css_class("phone-nav-pill");
            _pill_motion = new Singularity.Animation.MotionBin(pill);
            _pill_motion.halign = Align.CENTER;
            _pill_motion.valign = Align.CENTER;
            home.child = _pill_motion;
            home.activate.connect(() => home_requested());
            var recents = nav_button("view-grid-symbolic", _("Recent Apps"));
            recents.clicked.connect(() => recents_requested());
            _companion = nav_button("input-touchpad-symbolic", _("Control Other Screen"));
            _companion.visible = false;
            _companion.clicked.connect(() => companion_requested());
            var end = new Box(Orientation.HORIZONTAL, 4);
            end.append(_companion);
            end.append(recents);
            bar.center_widget = home;
            if (!handle_only) {
                bar.start_widget = back;
                bar.end_widget = end;
            }

            var drag = new GestureDrag();
            drag.propagation_phase = PropagationPhase.CAPTURE;
            drag.drag_begin.connect(() => {
                _gesture_fired = false;
                _pulling = false;
                _tracking = gesture != null && gesture.begin();
            });
            drag.drag_update.connect((dx, dy) => follow_finger(drag, dx, dy));
            drag.drag_end.connect((dx, dy) => {
                if (_tracking) gesture.end();
                if (_pulling) pull_end(dy);
                _pulling = false;
                _tracking = false;
                settle();
            });
            drag.cancel.connect(() => {
                if (_tracking) gesture.cancel();
                _tracking = false;
                settle();
            });
            bar.add_controller(drag);

            var shade = new Singularity.Widgets.ShadeBin(bar);
            var cover = HomeCover.get_default();
            shade.shade = cover.amount(monitor);
            cover.amount_changed.connect((m, amount) => {
                if (m == monitor) shade.shade = amount;
            });
            cover.changed.connect((m) => {
                if (m != monitor) return;
                if (cover.covered(m)) add_css_class("hub-covered");
                else remove_css_class("hub-covered");
            });
            _bar_motion = new Singularity.Animation.MotionBin(shade);
            set_child(_bar_motion);
            map.connect(() => play_enter());
        }

        public void set_companion(bool available, bool remote) {
            _companion.icon_name = remote ? "input-gaming-symbolic" : "input-touchpad-symbolic";
            if (_companion.visible == available) return;
            _companion.visible = available;
            if (!available || Singularity.Motion.reduced()) return;
            _companion.opacity = 0.0;
            Singularity.Motion.tween(_companion, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
        }

        private void follow_finger(GestureDrag drag, double dx, double dy) {
            if (_tracking) {
                _pill_motion.translate_y = double.max(-PILL_TRAVEL * 0.5, double.min(0.0, dy * 0.15));
                _pill_motion.translate_x = double.max(-PILL_TRAVEL, double.min(PILL_TRAVEL, dx * 0.4));
                if (gesture.update(dx, dy) && !_gesture_fired) {
                    _gesture_fired = true;
                    drag.set_state(EventSequenceState.CLAIMED);
                }
                return;
            }
            if (_pulling) {
                pull_update(dy);
                return;
            }
            if (_gesture_fired) return;
            _pill_motion.translate_y = double.max(-PILL_TRAVEL, double.min(0.0, dy * 0.5));
            _pill_motion.translate_x = double.max(-PILL_TRAVEL, double.min(PILL_TRAVEL, dx * 0.4));
            if (dy < -PULL_SLOP && Math.fabs(dx) < Math.fabs(dy) && pull_begin()) {
                fire(drag);
                _pulling = true;
                pull_update(dy);
            } else if (dy < -HOME_SWIPE && Math.fabs(dx) < Math.fabs(dy)) {
                fire(drag);
                home_requested();
            } else if (Math.fabs(dx) > SWITCH_SWIPE && Math.fabs(dx) > Math.fabs(dy)) {
                fire(drag);
                if (dx < 0) next_requested();
                else previous_requested();
            }
        }

        private void fire(GestureDrag drag) {
            _gesture_fired = true;
            drag.set_state(EventSequenceState.CLAIMED);
            settle();
        }

        private void settle() {
            Singularity.Motion.spring_to(_pill_motion, "translate-y", 0.0, Singularity.Motion.Spring.BOUNCY);
            Singularity.Motion.spring_to(_pill_motion, "translate-x", 0.0, Singularity.Motion.Spring.BOUNCY);
        }

        private void play_enter() {
            if (Singularity.Motion.reduced()) return;
            _bar_motion.translate_y = 44.0;
            Singularity.Motion.spring_to(_bar_motion, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        private Button nav_button(string icon, string label) {
            var b = new Button.from_icon_name(icon);
            b.add_css_class("phone-nav-button");
            b.tooltip_text = label;
            b.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            return b;
        }
    }
}
