using Gtk;

namespace Singularity {

    public enum AgentOrbState {
        OFF,
        IDLE,
        LISTEN,
        THINK,
        ACT,
        SPEAK,
        DONE
    }

    public class AgentOrb : Widget {
        private const double[] SPEED = { 12, 36, 120, 380, 210, 150, 60 };
        private const double[] GLOW = { 0.12, 0.5, 0.72, 1.0, 0.85, 0.8, 0.62 };
        private const double[] PULSE = { 0.01, 0.025, 0.04, 0.07, 0.05, 0.06, 0.03 };
        private const double[] RATE = { 0.15, 0.3, 0.9, 2.2, 1.3, 3.4, 0.4 };
        private const double[] MORPH = { 0, 0, 0.25, 1, 0.5, 0.35, 0 };
        private const double[] COLOR = { 0.35, 1, 1, 1, 1, 1, 1 };

        public int diameter { get; construct; }

        private AgentOrbState _state = AgentOrbState.IDLE;
        public AgentOrbState state {
            get { return _state; }
            set {
                if (_state == value) return;
                _state = value;
                ensure_ticking();
            }
        }

        private uint tick_id = 0;
        private int64 last_frame = 0;
        private double angle = 200;
        private double counter = 0;
        private double speed = 36;
        private double glow = 0.5;
        private double pulse = 0.025;
        private double rate = 0.3;
        private double morph = 0;
        private double color = 1;
        private double phase = 0;
        private double clock = 0;
        private double kick_level = 0;

        public AgentOrb(int diameter = 18) {
            Object(diameter: diameter);
        }

        construct {
            can_target = false;
            accessible_role = AccessibleRole.IMG;
            map.connect(ensure_ticking);
            unmap.connect(stop_ticking);
        }

        public override void dispose() {
            stop_ticking();
            base.dispose();
        }

        public void kick(double amount = 0.2) {
            kick_level = double.min(1.2, kick_level + amount);
            ensure_ticking();
        }

        private bool animations_enabled() {
            var settings = get_settings();
            return settings == null || settings.gtk_enable_animations;
        }

        private void ensure_ticking() {
            if (!get_mapped()) return;
            if (!animations_enabled()) {
                settle();
                queue_draw();
                return;
            }
            if (tick_id != 0) return;
            last_frame = 0;
            tick_id = add_tick_callback(on_tick);
        }

        private void stop_ticking() {
            if (tick_id != 0) remove_tick_callback(tick_id);
            tick_id = 0;
        }

        private void settle() {
            int i = (int) _state;
            speed = SPEED[i];
            glow = GLOW[i];
            pulse = 0;
            rate = RATE[i];
            morph = 0;
            color = COLOR[i];
            kick_level = 0;
        }

        private bool on_tick(Widget widget, Gdk.FrameClock clock_source) {
            int64 now = clock_source.get_frame_time();
            double dt = last_frame == 0 ? 0.016 : double.min(0.05, (now - last_frame) / 1000000.0);
            last_frame = now;
            int i = (int) _state;
            double k = 1 - Math.exp(-dt * 2.6);
            speed += (SPEED[i] - speed) * k;
            glow += (GLOW[i] - glow) * k;
            pulse += (PULSE[i] - pulse) * k;
            rate += (RATE[i] - rate) * k;
            morph += (MORPH[i] - morph) * k;
            color += (COLOR[i] - color) * k;
            kick_level *= Math.exp(-dt * 4);
            angle = Math.fmod(angle + speed * dt, 360);
            counter = Math.fmod(counter - speed * 0.55 * dt, 360);
            phase += rate * Math.PI * 2 * dt;
            clock += dt;
            queue_draw();
            return Source.CONTINUE;
        }

        private int padding() {
            return (int) Math.ceil(diameter * 0.45);
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = natural = diameter + padding() * 2;
            minimum_baseline = natural_baseline = -1;
        }

        private static Gdk.RGBA rgba(double r, double g, double b, double a) {
            var c = Gdk.RGBA();
            c.red = (float) r;
            c.green = (float) g;
            c.blue = (float) b;
            c.alpha = (float) a;
            return c;
        }

        private Gdk.RGBA tone(double r, double g, double b, double a) {
            double grey = 0.3 * r + 0.59 * g + 0.11 * b;
            return rgba(grey + (r - grey) * color, grey + (g - grey) * color, grey + (b - grey) * color, a);
        }

        private static Gsk.ColorStop stop(float offset, Gdk.RGBA c) {
            var s = Gsk.ColorStop();
            s.offset = offset;
            s.color = c;
            return s;
        }

        private void blob(Snapshot snapshot, float cx, float cy, float radius, Gdk.RGBA c) {
            var clear = c;
            clear.alpha = 0;
            var core = c;
            var bounds = Graphene.Rect().init(cx - radius, cy - radius, radius * 2, radius * 2);
            Gsk.ColorStop[] stops = { stop(0, core), stop(0.3f, core), stop(1, clear) };
            snapshot.append_radial_gradient(bounds, Graphene.Point().init(cx, cy), radius, radius, 0, 1, stops);
        }

        public override void snapshot(Snapshot snapshot) {
            float w = get_width();
            float h = get_height();
            float cx = w / 2;
            float cy = h / 2;
            double scale = 1 + pulse * Math.sin(phase) + kick_level * 0.12;
            float r = (float) (diameter / 2.0 * scale);
            double g = glow + kick_level * 0.5;

            float halo = (float) (r * (1.55 + 0.35 * g));
            var halo_bounds = Graphene.Rect().init(cx - halo, cy - halo, halo * 2, halo * 2);
            Gsk.ColorStop[] halo_stops = {
                stop(0, tone(0.47, 0.59, 1, 0.55 * g)),
                stop(0.55f, tone(1, 0.48, 0.72, 0.22 * g)),
                stop(1, rgba(1, 0.48, 0.72, 0))
            };
            snapshot.append_radial_gradient(halo_bounds, Graphene.Point().init(cx, cy), halo, halo, 0, 1, halo_stops);

            var orb = Graphene.Rect().init(cx - r, cy - r, r * 2, r * 2);
            double m = morph * 0.07;
            double t = clock * 2.3;
            float[] corner = new float[8];
            for (int i = 0; i < 8; i++) corner[i] = (float) (r * 2 * (0.5 + m * Math.sin(t + i * 1.7)));
            var clip = Gsk.RoundedRect();
            clip.init(orb,
                Graphene.Size() { width = corner[0], height = corner[4] },
                Graphene.Size() { width = corner[1], height = corner[5] },
                Graphene.Size() { width = corner[2], height = corner[6] },
                Graphene.Size() { width = corner[3], height = corner[7] });
            snapshot.push_rounded_clip(clip);

            snapshot.append_color(tone(0.48, 0.53, 1, 1), orb);
            snapshot.push_blur(r * 0.32);
            float big = r * 1.7f;
            var wide = Graphene.Rect().init(cx - big, cy - big, big * 2, big * 2);
            Gsk.ColorStop[] ring = {
                stop(0, tone(0.31, 0.61, 1, 1)),
                stop(0.14f, tone(0.49, 0.55, 1, 1)),
                stop(0.28f, tone(0.63, 0.49, 1, 1)),
                stop(0.43f, tone(0.88, 0.49, 0.94, 1)),
                stop(0.57f, tone(1, 0.48, 0.72, 1)),
                stop(0.71f, tone(1, 0.62, 0.69, 1)),
                stop(0.86f, tone(0.56, 0.78, 1, 1)),
                stop(1, tone(0.31, 0.61, 1, 1))
            };
            snapshot.append_conic_gradient(wide, Graphene.Point().init(cx, cy), (float) angle, ring);
            snapshot.save();
            snapshot.translate(Graphene.Point().init(cx, cy));
            snapshot.rotate((float) counter);
            snapshot.translate(Graphene.Point().init(-cx, -cy));
            blob(snapshot, cx - r * 0.42f, cy - r * 0.38f, r * 0.8f, tone(0.59, 0.9, 1, 0.95));
            blob(snapshot, cx + r * 0.45f, cy + r * 0.3f, r * 0.75f, tone(1, 0.59, 0.82, 0.95));
            blob(snapshot, cx - r * 0.15f, cy + r * 0.6f, r * 0.65f, tone(0.75, 0.55, 1, 0.9));
            snapshot.restore();
            snapshot.pop();

            float shine = r * 0.95f;
            float sx = cx - r * 0.32f;
            float sy = cy - r * 0.48f;
            Gsk.ColorStop[] light = { stop(0, rgba(1, 1, 1, 0.78)), stop(1, rgba(1, 1, 1, 0)) };
            snapshot.append_radial_gradient(Graphene.Rect().init(sx - shine, sy - shine, shine * 2, shine * 2),
                Graphene.Point().init(sx, sy), shine, shine, 0, 1, light);
            snapshot.pop();
        }
    }
}
