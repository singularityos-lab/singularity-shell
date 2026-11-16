using Gtk;

namespace Singularity {

    public class TvBanner : Widget {
        public const int WIDTH = 248;
        public const int HEIGHT = 156;
        private const int ICON_SIZE = 88;
        private const float RADIUS = 22f;

        private Gdk.Paintable? _icon = null;
        private Gdk.RGBA _top;
        private Gdk.RGBA _bottom;
        private Gdk.RGBA _glow;
        private double _tilt_x = 0;
        private double _tilt_y = 0;
        private double _lift = 0;
        private double _vivid = 0;

        public double lift {
            get { return _lift; }
            set { _lift = value.clamp(0, 1.2); queue_draw(); }
        }

        public TvBanner(GLib.Icon? gicon, string fallback) {
            add_css_class("tv-banner");
            set_size_request(WIDTH, HEIGHT);
            halign = Align.CENTER;
            var theme = IconTheme.get_for_display(Gdk.Display.get_default());
            IconPaintable paintable = gicon != null
                ? theme.lookup_by_gicon(gicon, ICON_SIZE, 2, TextDirection.NONE, 0)
                : theme.lookup_icon(fallback, null, ICON_SIZE, 2, TextDirection.NONE, 0);
            _icon = paintable;
            double hue, sat, val;
            tone_of(paintable, out hue, out sat, out val);
            double vivid = double.min(sat / 0.45, 1.0);
            _vivid = vivid;
            _top = from_hsv(hue, sat * 0.8, 0.3 + 0.3 * vivid);
            _bottom = from_hsv(hue, double.min(sat * 1.05, 0.85), 0.12 + 0.08 * vivid);
            _glow = from_hsv(hue, double.min(sat * 1.2, 0.9), 0.95);

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                _tilt_x = (x / double.max(get_width(), 1)) * 2 - 1;
                _tilt_y = (y / double.max(get_height(), 1)) * 2 - 1;
                queue_draw();
            });
            motion.leave.connect(() => {
                _tilt_x = 0;
                _tilt_y = 0;
                queue_draw();
            });
            add_controller(motion);
        }

        private static void tone_of(IconPaintable paintable, out double hue, out double sat, out double val) {
            hue = 0.6;
            sat = 0.12;
            val = 0.5;
            const int SAMPLE = 24;
            var snap = new Gtk.Snapshot();
            paintable.snapshot(snap, SAMPLE, SAMPLE);
            var node = snap.to_node();
            if (node == null) return;
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, SAMPLE, SAMPLE);
            var cr = new Cairo.Context(surface);
            node.draw(cr);
            surface.flush();
            unowned uint8[] px = surface.get_data();
            int stride = surface.get_stride();
            double r = 0, g = 0, b = 0, total = 0;
            for (int y = 0; y < SAMPLE; y++) {
                for (int x = 0; x < SAMPLE; x++) {
                    int i = y * stride + x * 4;
                    int a = px[i + 3];
                    if (a < 160) continue;
                    double pr = px[i + 2] / (double) a, pg = px[i + 1] / (double) a, pb = px[i] / (double) a;
                    double mx = double.max(pr, double.max(pg, pb));
                    double mn = double.min(pr, double.min(pg, pb));
                    double s = mx > 0 ? (mx - mn) / mx : 0;
                    double w = s * s * mx + 0.02;
                    r += pr * w;
                    g += pg * w;
                    b += pb * w;
                    total += w;
                }
            }
            if (total <= 0) return;
            float h, s, v;
            Gtk.rgb_to_hsv((float) (r / total), (float) (g / total), (float) (b / total), out h, out s, out v);
            hue = h;
            sat = double.min(s, 0.8);
            val = v;
        }

        private static Gdk.RGBA from_hsv(double h, double s, double v) {
            float r, g, b;
            Gtk.hsv_to_rgb((float) h, (float) s, (float) v, out r, out g, out b);
            return Gdk.RGBA() { red = r, green = g, blue = b, alpha = 1 };
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            float w = get_width();
            float h = get_height();
            var rect = Graphene.Rect().init(0, 0, w, h);
            var outline = Gsk.RoundedRect();
            outline.init_from_rect(rect, RADIUS);
            float tx = (float) _tilt_x;
            float ty = (float) _tilt_y;

            float lift = (float) double.min(_lift, 1.0);
            if (lift > 0.01f) {
                var halo = _glow;
                halo.alpha = 0.55f * lift;
                snapshot.append_outset_shadow(outline, halo, 0, 6 * lift, 2 * lift, 38);
                var core = _glow;
                core.alpha = 0.32f * lift;
                snapshot.append_outset_shadow(outline, core, 0, 2 * lift, 0, 12);
            }

            snapshot.push_rounded_clip(outline);
            Gsk.ColorStop[] base_stops = { { 0f, _top }, { 1f, _bottom } };
            snapshot.append_linear_gradient(rect, Graphene.Point() { x = 0, y = 0 }, Graphene.Point() { x = w * 0.4f, y = h }, base_stops);

            var glow_clear = _glow;
            glow_clear.alpha = 0;
            var glow_core = _glow;
            glow_core.alpha = 0.32f;
            Gsk.ColorStop[] glow_stops = { { 0f, glow_core }, { 1f, glow_clear } };
            snapshot.append_radial_gradient(rect, Graphene.Point() { x = w / 2 - tx * 8, y = h * 0.42f - ty * 6 },
                w * 0.42f, h * 0.55f, 0f, 1f, glow_stops);

            if (_icon != null) {
                float big = h * 1.6f;
                snapshot.save();
                snapshot.push_opacity(0.1 + 0.25 * _vivid);
                snapshot.push_blur(26);
                snapshot.translate(Graphene.Point() { x = (w - big) / 2 - tx * 12, y = (h - big) / 2 + h * 0.18f - ty * 8 });
                _icon.snapshot(snapshot, big, big);
                snapshot.pop();
                snapshot.pop();
                snapshot.restore();
            }

            var sheen_on = Gdk.RGBA() { red = 1, green = 1, blue = 1, alpha = 0.14f + 0.12f * lift };
            var sheen_off = Gdk.RGBA() { red = 1, green = 1, blue = 1, alpha = 0 };
            Gsk.ColorStop[] sheen_stops = { { 0f, sheen_on }, { 0.5f, sheen_off }, { 1f, sheen_off } };
            snapshot.append_linear_gradient(rect, Graphene.Point() { x = w * (0.2f + 0.25f * tx), y = 0 },
                Graphene.Point() { x = w * (0.45f + 0.25f * tx), y = h }, sheen_stops);

            if (_icon != null) {
                snapshot.save();
                Gsk.Shadow[] shadow = { { Gdk.RGBA() { red = 0, green = 0, blue = 0, alpha = 0.38f }, 0, 6, 14 } };
                snapshot.push_shadow(shadow);
                snapshot.translate(Graphene.Point() { x = (w - ICON_SIZE) / 2 + tx * 5, y = (h - ICON_SIZE) / 2 + ty * 4 });
                _icon.snapshot(snapshot, ICON_SIZE, ICON_SIZE);
                snapshot.pop();
                snapshot.restore();
            }
            snapshot.pop();
        }
    }
}
