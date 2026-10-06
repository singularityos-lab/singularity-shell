namespace Singularity {

    public class SwipeDismiss : Object {
        private const double START_DISTANCE = 12.0;
        private const double DISMISS_FRACTION = 0.4;
        private const double FLING_VELOCITY = 700.0;

        public Singularity.Animation.MotionBin bin { get; construct; }
        public bool dragging { get; private set; default = false; }
        public bool leaving { get; private set; default = false; }

        public signal void started();
        public signal void cancelled();
        public signal void dismissed();

        private Gtk.GestureDrag drag;
        private Singularity.Animation.SpringAnimation? spring = null;

        public SwipeDismiss(Singularity.Animation.MotionBin bin) {
            Object(bin: bin);
            drag = new Gtk.GestureDrag();
            drag.button = 1;
            drag.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            drag.drag_update.connect(on_update);
            drag.drag_end.connect(on_end);
            drag.cancel.connect(() => {
                if (dragging) settle(0.0, double.NAN);
            });
            bin.add_controller(drag);
        }

        private void on_update(double offset_x, double offset_y) {
            if (leaving) return;
            if (!dragging) {
                if (Math.fabs(offset_x) < START_DISTANCE || Math.fabs(offset_x) < Math.fabs(offset_y)) return;
                dragging = true;
                drag.set_state(Gtk.EventSequenceState.CLAIMED);
                Singularity.Motion.cancel(bin, "translate-x");
                spring = new Singularity.Animation.SpringAnimation(bin, bin.translate_x, 0.0,
                    Singularity.Motion.Spring.SNAPPY);
                spring.reduced_mode = Singularity.Animation.ReducedMode.FULL;
                started();
            }
            bin.translate_x = offset_x;
            bin.opacity = 1.0 - (Math.fabs(offset_x) / double.max(1.0, bin.get_width())).clamp(0.0, 0.6);
            spring.track(offset_x);
        }

        private void on_end(double offset_x, double offset_y) {
            if (!dragging) return;
            double velocity = spring.velocity;
            double width = double.max(1.0, bin.get_width());
            bool fling = Math.fabs(velocity) >= FLING_VELOCITY && (velocity > 0) == (offset_x > 0);
            if (fling || Math.fabs(offset_x) >= width * DISMISS_FRACTION) {
                settle(offset_x > 0 ? width + 40.0 : -(width + 40.0), velocity);
            } else {
                settle(0.0, velocity);
            }
        }

        private void settle(double target, double velocity) {
            dragging = false;
            var animation = spring;
            spring = null;
            if (animation == null) return;
            if (target == 0.0) {
                Singularity.Motion.tween(bin, "opacity", 1.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.STANDARD);
                Singularity.Motion.spring_to(bin, "translate-x", 0.0, Singularity.Motion.Spring.SNAPPY,
                    velocity.is_nan() ? 0.0 : velocity);
                cancelled();
                return;
            }
            leaving = true;
            animation.reduced_mode = Singularity.Animation.ReducedMode.SHORTEN;
            animation.clamp = true;
            animation.set_sink((value) => bin.translate_x = value);
            animation.done.connect(() => dismissed());
            Singularity.Motion.tween(bin, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            animation.release(target, velocity.is_nan() ? 0.0 : velocity);
        }
    }
}
