using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class PhoneNavBar : Gtk.Window {
        private const double HOME_SWIPE = 40.0;
        private const double SWITCH_SWIPE = 70.0;
        private const double PILL_TRAVEL = 36.0;

        public signal void back_requested();
        public signal void home_requested();
        public signal void recents_requested();
        public signal void next_requested();
        public signal void previous_requested();

        private Singularity.Animation.MotionBin _pill_motion;
        private Singularity.Animation.MotionBin _bar_motion;
        private bool _gesture_fired = false;

        public PhoneNavBar(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-phone-nav");
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            auto_exclusive_zone_enable(this);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("phone-nav");

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
            home.clicked.connect(() => home_requested());
            var recents = nav_button("view-grid-symbolic", _("Recent Apps"));
            recents.clicked.connect(() => recents_requested());
            bar.start_widget = back;
            bar.center_widget = home;
            bar.end_widget = recents;

            var drag = new GestureDrag();
            drag.propagation_phase = PropagationPhase.CAPTURE;
            drag.drag_begin.connect(() => _gesture_fired = false);
            drag.drag_update.connect((dx, dy) => follow_finger(drag, dx, dy));
            drag.drag_end.connect((dx, dy) => settle());
            bar.add_controller(drag);

            _bar_motion = new Singularity.Animation.MotionBin(bar);
            set_child(_bar_motion);
            map.connect(() => play_enter());
        }

        private void follow_finger(GestureDrag drag, double dx, double dy) {
            if (_gesture_fired) return;
            _pill_motion.translate_y = double.max(-PILL_TRAVEL, double.min(0.0, dy * 0.5));
            _pill_motion.translate_x = double.max(-PILL_TRAVEL, double.min(PILL_TRAVEL, dx * 0.4));
            if (dy < -HOME_SWIPE && Math.fabs(dx) < Math.fabs(dy)) {
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
