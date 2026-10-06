namespace Singularity {

    public class DockSharpIcon : Gtk.Widget {
        public Gtk.Image image { get; construct; }
        public double factor { get; construct; }

        private Gtk.Image large;
        private bool magnified = false;

        public DockSharpIcon(Gtk.Image image, double factor) {
            Object(image: image, factor: double.max(1.0, factor));
        }

        construct {
            halign = image.halign;
            valign = image.valign;
            large = new Gtk.Image();
            large.can_target = false;
            foreach (var css_class in image.get_css_classes()) large.add_css_class(css_class);
            image.set_parent(this);
            large.set_parent(this);
            image.notify["storage-type"].connect(sync_source);
            image.notify["gicon"].connect(sync_source);
            image.notify["icon-name"].connect(sync_source);
            image.notify["paintable"].connect(sync_source);
            image.notify["pixel-size"].connect(sync_source);
            sync_source();
        }

        private void sync_source() {
            large.pixel_size = (int) Math.ceil(image.pixel_size * factor);
            switch (image.storage_type) {
                case Gtk.ImageType.GICON:
                    large.set_from_gicon(image.gicon);
                    break;
                case Gtk.ImageType.ICON_NAME:
                    large.set_from_icon_name(image.icon_name);
                    break;
                case Gtk.ImageType.PAINTABLE:
                    large.set_from_paintable(image.paintable);
                    break;
                default:
                    large.clear();
                    break;
            }
            queue_resize();
        }

        public void set_scale(double scale) {
            bool value = scale > 1.001;
            if (value == magnified) return;
            magnified = value;
            queue_draw();
        }

        public override void dispose() {
            if (image != null && image.get_parent() == this) image.unparent();
            if (large != null) {
                large.unparent();
                large = null;
            }
            base.dispose();
        }

        public override Gtk.SizeRequestMode get_request_mode() {
            return Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Gtk.Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            image.measure(orientation, for_size, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
        }

        public override void size_allocate(int width, int height, int baseline) {
            image.allocate(width, height, baseline, null);
            int minimum, large_width, large_height, minimum_baseline, natural_baseline;
            large.measure(Gtk.Orientation.HORIZONTAL, -1, out minimum, out large_width,
                out minimum_baseline, out natural_baseline);
            large.measure(Gtk.Orientation.VERTICAL, -1, out minimum, out large_height,
                out minimum_baseline, out natural_baseline);
            float shrink = (float) (1.0 / factor);
            var transform = new Gsk.Transform()
                .translate({ width / 2.0f, height / 2.0f })
                .scale(shrink, shrink)
                .translate({ -large_width / 2.0f, -large_height / 2.0f });
            large.allocate(large_width, large_height, -1, transform);
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            snapshot_child(magnified ? large : image, snapshot);
        }
    }
}
