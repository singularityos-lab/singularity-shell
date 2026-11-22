namespace Singularity {

    public class DockRipple : Gtk.Widget {
        private double _progress = 0.0;
        private double _fade = 1.0;

        public double progress {
            get { return _progress; }
            set { _progress = value; queue_draw(); }
        }

        public double fade {
            get { return _fade; }
            set { _fade = value; queue_draw(); }
        }

        construct {
            can_target = false;
            can_focus = false;
            overflow = Gtk.Overflow.VISIBLE;
            add_css_class("dock-launch-ripple");
        }

        public Singularity.Animation.MotionBin? icon { get; set; }

        public override void snapshot(Gtk.Snapshot snapshot) {
            double width = get_width();
            double height = get_height();
            if (width < 1 || height < 1 || _fade <= 0.0) return;
            double cx = width / 2.0;
            double cy = height / 2.0;
            double scale = 1.0;
            if (icon != null && icon.get_parent() != null) {
                Graphene.Rect bounds;
                if (icon.compute_bounds(this, out bounds)) {
                    double ox = bounds.origin.x + bounds.size.width * icon.origin_x;
                    double oy = bounds.origin.y + bounds.size.height * icon.origin_y;
                    scale = icon.scale_x;
                    cx = ox + (bounds.origin.x + bounds.size.width / 2.0 - ox) * scale + icon.translate_x;
                    cy = oy + (bounds.origin.y + bounds.size.height / 2.0 - oy) * scale + icon.translate_y;
                }
            }
            double size = double.min(width, height);
            double radius = size * (0.42 * scale + 0.26 * _progress);
            double ring = double.max(1.5, 3.0 * (1.0 - _progress) + 1.0);
            var color = get_color();
            color.alpha = (float) (0.7 * _fade);
            var rect = Graphene.Rect() {
                origin = { (float) (cx - radius), (float) (cy - radius) },
                size = { (float) (radius * 2.0), (float) (radius * 2.0) }
            };
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(rect, (float) radius);
            float[] widths = { (float) ring, (float) ring, (float) ring, (float) ring };
            Gdk.RGBA[] colors = { color, color, color, color };
            snapshot.append_border(rounded, widths, colors);
        }
    }

    public class DockIconMotion : Object {
        private const uint DWELL = 80;

        private uint pending = 0;
        private bool played = false;
        private bool hovered = false;
        private bool launching = false;
        private double detail = 1.0;

        private static DockIconMotion of(Gtk.Widget wrapper) {
            var state = wrapper.get_data<DockIconMotion>("icon_motion");
            if (state != null) return state;
            state = new DockIconMotion();
            wrapper.set_data<DockIconMotion>("icon_motion", state);
            return state;
        }

        public static void entered(Gtk.Widget wrapper, bool magnified) {
            var state = of(wrapper);
            if (state.hovered) return;
            state.hovered = true;
            state.detail = magnified ? DockMagnifier.MAX_SCALE : 1.0;
            var item = WeakRef(wrapper);
            state.pending = Timeout.add(DWELL, () => {
                var alive = item.get() as Gtk.Widget;
                if (alive == null) return Source.REMOVE;
                var current = of(alive);
                current.pending = 0;
                current.played = current.animate(alive);
                return Source.REMOVE;
            });
        }

        public static void left(Gtk.Widget wrapper) {
            var state = of(wrapper);
            state.cancel();
            state.hovered = false;
            state.played = false;
            state.detail = 1.0;
        }

        public static void activated(Gtk.Widget wrapper) {
            var state = of(wrapper);
            if (state.played) return;
            state.cancel();
            bool running = state.animate(wrapper);
            if (state.hovered) state.played = running;
        }

        public static void launched(Gtk.Widget wrapper) {
            of(wrapper).launching = true;
            activated(wrapper);
        }

        public static void opened(Gtk.Widget wrapper) {
            var state = of(wrapper);
            if (state.launching) {
                state.launching = false;
                return;
            }
            if (wrapper.get_mapped()) {
                activated(wrapper);
                return;
            }
            wrapper.add_tick_callback((item, clock) => {
                activated(item);
                return Source.REMOVE;
            });
        }

        private void cancel() {
            if (pending == 0) return;
            Source.remove(pending);
            pending = 0;
        }

        private bool animate(Gtk.Widget wrapper) {
            var button = wrapper.get_data<Gtk.Button>("dock_button");
            if (button == null) return false;
            var bin = button.get_child() as Singularity.Animation.MotionBin;
            var content = bin != null ? bin.child : button.get_child();
            var sharp = content as DockSharpIcon;
            var image = sharp != null ? sharp.image : content as Gtk.Image;
            if (image == null) return false;
            return Singularity.Animation.IconMotion.play(image, Singularity.Animation.IconMotion.DOCK_LIMIT, detail);
        }

        public override void dispose() {
            cancel();
            base.dispose();
        }
    }

    public class DockLaunchFeedback : Object {
        public const double BOUNCE = 0.28;
        public const double STRETCH = 3.0;
        public const uint GIVE_UP_SECONDS = 10;

        public static void play(Gtk.Widget wrapper, string position) {
            DockIconMotion.launched(wrapper);
            ripple(wrapper);
            bounce(wrapper, position);
            stretch_dot(wrapper);
        }

        private static void ripple(Gtk.Widget wrapper) {
            var overlay = wrapper.get_data<Gtk.Overlay>("item_overlay");
            if (overlay == null) return;
            var previous = wrapper.get_data<DockRipple>("launch_ripple");
            if (previous != null && previous.get_parent() == overlay) overlay.remove_overlay(previous);
            var ripple = new DockRipple();
            var button = wrapper.get_data<Gtk.Button>("dock_button");
            if (button != null) ripple.icon = button.get_child() as Singularity.Animation.MotionBin;
            overlay.add_overlay(ripple);
            wrapper.set_data("launch_ripple", ripple);
            unowned Gtk.Overlay overlay_weak = overlay;
            unowned DockRipple ripple_weak = ripple;
            Singularity.Animation.Animation animation;
            if (Singularity.Motion.reduced()) {
                ripple.progress = 1.0;
                var fade = new Singularity.Animation.TimedAnimation.with_curve(ripple, 1.0, 0.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.LINEAR);
                fade.reduced_mode = Singularity.Animation.ReducedMode.FULL;
                fade.set_sink((value) => ripple_weak.fade = value);
                animation = fade;
            } else {
                var grow = new Singularity.Animation.TimedAnimation.with_curve(ripple, 0.0, 1.0,
                    Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.ENTER);
                grow.set_sink((value) => {
                    ripple_weak.progress = value;
                    ripple_weak.fade = 1.0 - value;
                });
                animation = grow;
            }
            animation.done.connect(() => {
                if (ripple_weak.get_parent() == overlay_weak) overlay_weak.remove_overlay(ripple_weak);
            });
            animation.play();
        }

        private static void bounce(Gtk.Widget wrapper, string position) {
            if (Singularity.Motion.reduced()) return;
            var button = wrapper.get_data<Gtk.Button>("dock_button");
            if (button == null) return;
            var bin = button.get_child() as Singularity.Animation.MotionBin;
            if (bin == null) return;
            double size = double.max(1.0, button.get_height());
            double velocity = BOUNCE * size / peak_ratio(Singularity.Motion.Spring.BOUNCY);
            string property = "translate-y";
            if (position == "left") {
                property = "translate-x";
            } else if (position == "right") {
                property = "translate-x";
                velocity = -velocity;
            } else {
                velocity = -velocity;
            }
            Singularity.Motion.spring_to(bin, property, 0.0, Singularity.Motion.Spring.BOUNCY, velocity);
        }

        public static double peak_ratio(Singularity.Motion.Spring spring) {
            double omega = Math.sqrt(spring.stiffness() / spring.mass());
            double zeta = spring.damping_ratio();
            if (zeta >= 1.0) return 1.0 / (omega * Math.E);
            double damped = omega * Math.sqrt(1.0 - zeta * zeta);
            double time = Math.atan2(damped, zeta * omega) / damped;
            return Math.exp(-zeta * omega * time) * Math.sin(damped * time) / damped;
        }

        private static void stretch_dot(Gtk.Widget wrapper) {
            var row = wrapper.get_data<Gtk.Box>("indicator_row");
            if (row == null || row.get_first_child() != null) return;
            var dot = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            dot.add_css_class("dock-indicator-dot");
            var bin = new Singularity.Animation.MotionBin(dot);
            bin.valign = Gtk.Align.CENTER;
            bin.add_css_class("dock-launch-dot");
            row.append(bin);
            wrapper.set_data("launch_dot", bin);
            if (Singularity.Motion.reduced()) {
                bin.scale_x = STRETCH;
            } else {
                bin.scale_x = 1.0;
                Singularity.Motion.spring_to(bin, "scale-x", STRETCH, Singularity.Motion.Spring.SNAPPY);
            }
            Gtk.Widget wrapper_ref = wrapper;
            Singularity.Animation.MotionBin bin_ref = bin;
            GLib.Timeout.add_seconds(GIVE_UP_SECONDS, () => {
                if (wrapper_ref.get_data<Singularity.Animation.MotionBin>("launch_dot") == bin_ref) {
                    wrapper_ref.set_data<Singularity.Animation.MotionBin?>("launch_dot", null);
                    var parent = bin_ref.get_parent() as Gtk.Box;
                    if (parent != null) parent.remove(bin_ref);
                }
                return GLib.Source.REMOVE;
            });
        }

        public static Gtk.Widget? take_dot(Gtk.Widget wrapper) {
            var bin = wrapper.get_data<Singularity.Animation.MotionBin>("launch_dot");
            if (bin == null) return null;
            wrapper.set_data<Singularity.Animation.MotionBin?>("launch_dot", null);
            if (Singularity.Motion.reduced()) {
                Singularity.Motion.cancel(bin, "scale-x");
                bin.scale_x = 1.0;
            } else {
                Singularity.Motion.spring_to(bin, "scale-x", 1.0, Singularity.Motion.Spring.SNAPPY);
            }
            return bin;
        }

        public static bool launching(Gtk.Widget wrapper) {
            return wrapper.get_data<Singularity.Animation.MotionBin>("launch_dot") != null;
        }
    }
}
