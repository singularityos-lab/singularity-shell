using Gtk;

namespace Singularity.Shell {

    private class EdgeGlow : Gtk.Widget {
        private const double REACH = 150.0;
        private const double SPAN_MIN = 70.0;
        private const double SPAN_MAX = 240.0;

        public string side { get; set; default = "left"; }
        public double position { get; set; default = 0.5; }
        public double progress { get; set; default = 0.0; }
        public double burst { get; set; default = 0.0; }
        public string label { get; set; default = ""; }

        construct {
            add_css_class("edge-approach");
            can_target = false;
            notify.connect(() => queue_draw());
        }

        private bool vertical_edge() {
            return side == "left" || side == "right";
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            double w = get_width(), h = get_height();
            double length = vertical_edge() ? h : w;
            double level = double.max(progress, burst);
            if (level <= 0 || length <= 0) return;

            var accent = get_color();
            double along = position.clamp(0, 1) * length;
            double span = SPAN_MIN + (SPAN_MAX - SPAN_MIN) * level + burst * length * 0.35;
            double depth = 10 + (REACH - 10) * level;
            double fade = burst > 0 ? 1.0 - burst * 0.85 : 1.0;

            var cr = snapshot.append_cairo(Graphene.Rect().init(0, 0, (float) w, (float) h));
            double ex = 0, ey = 0, nx = 0, ny = 0, ax = 0, ay = 0;
            switch (side) {
                case "right": ex = w; ey = along; nx = -1; ny = 0; ax = 0; ay = 1; break;
                case "top": ex = along; ey = 0; nx = 0; ny = 1; ax = 1; ay = 0; break;
                case "bottom": ex = along; ey = h; nx = 0; ny = -1; ax = 1; ay = 0; break;
                default: ex = 0; ey = along; nx = 1; ny = 0; ax = 0; ay = 1; break;
            }

            cr.save();
            cr.translate(ex, ey);
            double angle = Math.atan2(ny, nx);
            cr.rotate(angle);
            cr.scale(depth, span / 2);
            var glow = new Cairo.Pattern.radial(0, 0, 0, 0, 0, 1);
            glow.add_color_stop_rgba(0, accent.red, accent.green, accent.blue, 0.85 * fade);
            glow.add_color_stop_rgba(0.45, accent.red, accent.green, accent.blue, 0.38 * fade);
            glow.add_color_stop_rgba(1, accent.red, accent.green, accent.blue, 0);
            cr.set_source(glow);
            cr.arc(0, 0, 1, -Math.PI / 2, Math.PI / 2);
            cr.close_path();
            cr.fill();
            cr.restore();

            double line = span * 0.5;
            var rim = new Cairo.Pattern.linear(ex - ax * line, ey - ay * line, ex + ax * line, ey + ay * line);
            rim.add_color_stop_rgba(0, 1, 1, 1, 0);
            rim.add_color_stop_rgba(0.5, 1, 1, 1, 0.9 * fade);
            rim.add_color_stop_rgba(1, 1, 1, 1, 0);
            cr.set_source(rim);
            cr.set_line_width(3);
            cr.move_to(ex - ax * line, ey - ay * line);
            cr.line_to(ex + ax * line, ey + ay * line);
            cr.stroke();

            if (label == "" || progress < 0.25 || burst > 0) return;
            var layout = create_pango_layout(label);
            int tw, th;
            layout.get_pixel_size(out tw, out th);
            double pad_x = 12, pad_y = 6;
            double pw = tw + pad_x * 2, ph = th + pad_y * 2;
            double offset = depth * 0.55 + 18 + (vertical_edge() ? pw / 2 : ph / 2);
            double cx = (ex + nx * offset).clamp(pw / 2 + 8, w - pw / 2 - 8);
            double cy = (ey + ny * offset).clamp(ph / 2 + 8, h - ph / 2 - 8);
            double alpha = ((progress - 0.25) / 0.25).clamp(0, 1);
            rounded(cr, cx - pw / 2, cy - ph / 2, pw, ph, ph / 2);
            cr.set_source_rgba(0, 0, 0, 0.72 * alpha);
            cr.fill();
            cr.set_source_rgba(1, 1, 1, alpha);
            cr.move_to(cx - tw / 2.0, cy - th / 2.0);
            Pango.cairo_show_layout(cr, layout);
        }

        private static void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }
    }

    private class EdgeApproachWindow : Gtk.Window {
        private const int THICKNESS = 220;
        public EdgeGlow glow;
        public string side { get; private set; }

        public EdgeApproachWindow(Gtk.Application app, Gdk.Monitor monitor, string side) {
            Object(application: app);
            this.side = side;
            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_namespace(this, "singularity-edge-approach");
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_exclusive_zone(this, -1);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            GtkLayerShell.set_monitor(this, monitor);
            bool vertical = side == "left" || side == "right";
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, side != "right");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, side != "left");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, side != "bottom");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, side != "top");
            if (vertical) set_default_size(THICKNESS, -1);
            else set_default_size(-1, THICKNESS);
            add_css_class("singularity");
            add_css_class("edge-approach-window");
            glow = new EdgeGlow();
            glow.side = side;
            if (vertical) glow.width_request = THICKNESS;
            else glow.height_request = THICKNESS;
            set_child(glow);
            map.connect(() => {
                var surface = get_surface();
                if (surface != null) surface.set_input_region(new Cairo.Region());
            });
        }
    }

    public class EdgeApproach : Object {
        private const string CORE = "dev.sinty.Core1";
        private const string CORE_PATH = "/dev/sinty/Core1";

        private static EdgeApproach? instance = null;
        private Gtk.Application app;
        private EdgeApproachWindow? window = null;
        private Singularity.Animation.TimedAnimation? animation = null;
        private uint idle_id = 0;

        public static EdgeApproach get_default(Gtk.Application app) {
            if (instance == null) instance = new EdgeApproach(app);
            return instance;
        }

        private EdgeApproach(Gtk.Application app) {
            this.app = app;
            Bus.get.begin(BusType.SYSTEM, null, (o, r) => {
                try {
                    var bus = Bus.get.end(r);
                    bus.signal_subscribe(CORE, CORE, "Approach", CORE_PATH, null, DBusSignalFlags.NONE,
                        (c, sender, path, iface, name, args) => {
                            if (!args.is_of_type(new VariantType("(ssdd)"))) return;
                            string screen, side;
                            double position, progress;
                            args.get("(ssdd)", out screen, out side, out position, out progress);
                            approach(screen, side, position, progress);
                        });
                } catch (Error e) {
                    debug("edge approach: %s", e.message);
                }
            });
        }

        public void approach(string screen, string side, double position, double progress) {
            if (!(side in InputSides.ALL)) return;
            if (progress <= 0) {
                fade_out(false);
                return;
            }
            var win = ensure(side);
            if (win == null) return;
            animation?.reset();
            animation = null;
            win.glow.label = screen;
            win.glow.position = position;
            win.glow.burst = 0;
            if (progress >= 1) {
                win.glow.progress = 1;
                fade_out(true);
                return;
            }
            win.glow.progress = progress;
            watch_idle();
        }

        private void watch_idle() {
            if (idle_id != 0) Source.remove(idle_id);
            idle_id = Timeout.add(700, () => {
                idle_id = 0;
                fade_out(false);
                return Source.REMOVE;
            });
        }

        private EdgeApproachWindow? ensure(string side) {
            if (window != null && window.side == side) return window;
            close_window();
            var monitor = InputSides.monitor_at(side);
            if (monitor == null) return null;
            window = new EdgeApproachWindow(app, monitor, side);
            window.present();
            return window;
        }

        private void fade_out(bool burst) {
            if (idle_id != 0) {
                Source.remove(idle_id);
                idle_id = 0;
            }
            var win = window;
            if (win == null) return;
            animation?.reset();
            uint ms = burst ? Singularity.Motion.Duration.SCENE.exit_ms() : Singularity.Motion.Duration.SMALL.exit_ms();
            double from = burst ? 0 : win.glow.progress;
            var anim = new Singularity.Animation.TimedAnimation.with_curve(win.glow, from, burst ? 1 : 0, ms,
                burst ? Singularity.Motion.Curve.ENTER : Singularity.Motion.Curve.STANDARD);
            animation = anim;
            anim.tick.connect(() => {
                if (burst) win.glow.burst = anim.value;
                else win.glow.progress = anim.value;
            });
            anim.done.connect(() => {
                if (animation == anim) animation = null;
                if (window == win) close_window();
            });
            anim.play();
        }

        private void close_window() {
            if (window == null) return;
            var win = window;
            window = null;
            close_layer_window(win);
            win.destroy();
        }
    }

    public class InputSides {
        public const string[] ALL = { "left", "right", "top", "bottom" };

        public static Gdk.Monitor? monitor_at(string side) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var list = display.get_monitors();
            Gdk.Monitor? best = null;
            int best_value = 0;
            for (uint i = 0; i < list.get_n_items(); i++) {
                var m = (Gdk.Monitor) list.get_item(i);
                var g = m.get_geometry();
                int value;
                switch (side) {
                    case "left": value = -g.x; break;
                    case "right": value = g.x + g.width; break;
                    case "top": value = -g.y; break;
                    default: value = g.y + g.height; break;
                }
                if (best == null || value > best_value) {
                    best = m;
                    best_value = value;
                }
            }
            return best;
        }
    }
}
