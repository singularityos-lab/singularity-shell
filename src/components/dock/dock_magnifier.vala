namespace Singularity {

    public class DockMagnifier : Object {
        public const double MAX_SCALE = 1.5;
        private const double RANGE = 2.5;

        public Gtk.Box box { get; construct; }
        public GLib.Settings settings { get; construct; }
        public bool enabled { get; private set; default = false; }

        public signal void changed();

        public DockMagnifier(Gtk.Box box, GLib.Settings settings) {
            Object(box: box, settings: settings);
        }

        construct {
            enabled = settings.get_boolean("dock-magnification");
            settings.changed["dock-magnification"].connect(() => {
                enabled = settings.get_boolean("dock-magnification");
                rest(true);
                changed();
            });
            var motion = new Gtk.EventControllerMotion();
            motion.enter.connect((x, y) => track(x, y));
            motion.motion.connect((x, y) => track(x, y));
            motion.leave.connect(() => rest(false));
            box.add_controller(motion);
        }

        public int headroom(bool allowed) {
            if (!enabled || !allowed) return 0;
            int size = settings.get_int("dock-icon-size");
            return (int) Math.ceil(size * (MAX_SCALE - 1.0)) + 4;
        }

        public Singularity.Animation.MotionBin wrap(Gtk.Widget icon) {
            var image = icon as Gtk.Image;
            Gtk.Widget child = icon;
            if (image != null) {
                var sharp = new DockSharpIcon(image, MAX_SCALE);
                child = sharp;
            }
            var bin = new Singularity.Animation.MotionBin(child);
            bin.halign = Gtk.Align.CENTER;
            bin.valign = Gtk.Align.CENTER;
            if (child is DockSharpIcon) {
                unowned Singularity.Animation.MotionBin bin_weak = bin;
                bin.notify["scale"].connect(() => sync_sharp(bin_weak));
                bin.notify["scale-x"].connect(() => sync_sharp(bin_weak));
            }
            return bin;
        }

        private static void sync_sharp(Singularity.Animation.MotionBin bin) {
            var sharp = bin.child as DockSharpIcon;
            if (sharp != null) sharp.set_scale(double.max(bin.scale_x, bin.scale_y));
        }

        private Singularity.Animation.MotionBin? bin_of(Gtk.Widget item) {
            var button = item.get_data<Gtk.Button>("dock_button") ?? find_button(item);
            if (button == null) return null;
            Gtk.Widget? child = button.get_child();
            if (child == null) return null;
            var bin = child as Singularity.Animation.MotionBin;
            if (bin != null) return bin;
            button.set_child(null);
            bin = wrap(child);
            button.set_child(bin);
            return bin;
        }

        private static Gtk.Button? find_button(Gtk.Widget widget) {
            var button = widget as Gtk.Button;
            if (button != null) return button;
            for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                var found = find_button(child);
                if (found != null) return found;
            }
            return null;
        }

        private void place_origin(Singularity.Animation.MotionBin bin) {
            string position = settings.get_string("dock-position");
            if (position == "left") {
                bin.origin_x = 0.0;
                bin.origin_y = 0.5;
            } else if (position == "right") {
                bin.origin_x = 1.0;
                bin.origin_y = 0.5;
            } else {
                bin.origin_x = 0.5;
                bin.origin_y = 1.0;
            }
        }

        private void track(double x, double y) {
            if (!enabled || settings.get_boolean("bar-layout-edit-mode")) return;
            bool vertical = box.orientation == Gtk.Orientation.VERTICAL;
            double cursor = vertical ? y : x;
            double size = double.max(1.0, settings.get_int("dock-icon-size"));
            double range = size * RANGE;

            Singularity.Animation.MotionBin[] bins = {};
            double[] extras = {};
            double[] centers = {};
            int anchor = -1;
            double nearest = double.MAX;
            for (var item = box.get_first_child(); item != null; item = item.get_next_sibling()) {
                var bin = bin_of(item);
                if (bin == null || !bin.get_mapped()) continue;
                var button = bin.get_parent();
                Graphene.Point center;
                Graphene.Point local = { button.get_width() / 2.0f, button.get_height() / 2.0f };
                if (!button.compute_point(box, local, out center)) continue;
                double position = vertical ? center.y : center.x;
                double distance = Math.fabs(position - cursor);
                double falloff = distance < range ? (Math.cos(Math.PI * distance / range) + 1.0) / 2.0 : 0.0;
                bins += bin;
                centers += position;
                extras += (MAX_SCALE - 1.0) * falloff * size;
                if (distance < nearest) {
                    nearest = distance;
                    anchor = bins.length - 1;
                }
            }
            if (anchor < 0) return;

            for (int i = 0; i < bins.length; i++) {
                double offset = 0.0;
                if (i < anchor) {
                    offset -= extras[anchor] / 2.0 + extras[i] / 2.0;
                    for (int j = i + 1; j < anchor; j++) offset -= extras[j];
                } else if (i > anchor) {
                    offset += extras[anchor] / 2.0 + extras[i] / 2.0;
                    for (int j = anchor + 1; j < i; j++) offset += extras[j];
                }
                double scale = 1.0 + extras[i] / size;
                place_origin(bins[i]);
                apply(bins[i], scale, offset, vertical, false);
            }
        }

        private void rest(bool instant) {
            bool vertical = box.orientation == Gtk.Orientation.VERTICAL;
            for (var item = box.get_first_child(); item != null; item = item.get_next_sibling()) {
                var bin = bin_of(item);
                if (bin == null) continue;
                apply(bin, 1.0, 0.0, vertical, instant);
            }
        }

        private void apply(Singularity.Animation.MotionBin bin, double scale, double offset,
                                  bool vertical, bool instant) {
            string axis = vertical ? "translate-y" : "translate-x";
            string other = vertical ? "translate-x" : "translate-y";
            if (instant || Singularity.Motion.reduced()) {
                Singularity.Motion.cancel(bin, "scale");
                Singularity.Motion.cancel(bin, axis);
                Singularity.Motion.cancel(bin, other);
                bin.reset_transform();
                bin.scale = scale;
                if (vertical) bin.translate_y = offset;
                else bin.translate_x = offset;
                sync_sharp(bin);
                return;
            }
            spring(bin, "scale", bin.scale, scale);
            spring(bin, axis, vertical ? bin.translate_y : bin.translate_x, offset);
        }

        private void spring(Singularity.Animation.MotionBin bin, string property, double current, double target) {
            var running = bin.get_data<Singularity.Animation.Animation>("singularity-motion-" + property);
            bool playing = running != null && running.state == Singularity.Animation.AnimationState.PLAYING;
            if (!playing && Math.fabs(current - target) < 0.001) return;
            Singularity.Motion.spring_to(bin, property, target, Singularity.Motion.Spring.SNAPPY);
        }
    }
}
