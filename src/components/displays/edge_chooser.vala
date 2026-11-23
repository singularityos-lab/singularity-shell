using Gtk;

namespace Singularity.Shell {

    public class EdgeChooser : Gtk.Window {
        private const int SHADOW_SPACE = 32;
        private const int GAP = 12;
        private const uint LINGER_MS = 6000;

        private static EdgeChooser? current = null;

        private NearbyClient client;
        private string output;
        private string side;
        private int length;
        private Box card;
        private Singularity.Animation.MotionBin card_motion;
        private uint linger_id = 0;
        private bool inside = false;
        private bool closing = false;

        public static void start(Gtk.Application app) {
            var client = NearbyClient.get_default();
            client.edge_pushed.connect((output, side, position, length) => {
                if (!(side in InputSides.ALL)) return;
                var candidates = new Gee.ArrayList<NearbyDevice>();
                foreach (var d in client.devices) {
                    if (d.can_share_input && !d.placed && d.reachable) candidates.add(d);
                }
                if (candidates.size == 0) return;
                if (current != null) current.dismiss();
                current = new EdgeChooser(app, output, side, position, length, candidates);
                current.present();
            });
        }

        private EdgeChooser(Gtk.Application app, string output, string side, double position, double length,
                            Gee.List<NearbyDevice> candidates) {
            Object(application: app);
            client = NearbyClient.get_default();
            this.output = output;
            this.side = side;
            this.length = (int) Math.round(length);

            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_namespace(this, "singularity-edge-chooser");
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_exclusive_zone(this, -1);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            var monitor = monitor_named(output);
            if (monitor != null) GtkLayerShell.set_monitor(this, monitor);
            bool vertical = side == "left" || side == "right";
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, side == "left" || !vertical);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, side == "right");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, side == "top" || vertical);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, side == "bottom");

            add_css_class("singularity");
            add_css_class("edge-chooser-window");

            card = new Box(Orientation.VERTICAL, 4);
            card.add_css_class("edge-chooser");
            card.width_request = 260;
            Singularity.Style.BackgroundEffect.track(this, () => { return new Gtk.Widget[] { card }; });

            var title = new Label(candidates.size == 1 ? _("Put a Sinty Here?") : _("Which Sinty Is Here?"));
            title.add_css_class("heading");
            title.xalign = 0;
            title.margin_start = 8;
            title.margin_top = 4;
            card.append(title);
            var hint = new Label(_("Its pointer and keyboard will come from this computer when you cross this edge."));
            hint.add_css_class("dim-label");
            hint.add_css_class("caption");
            hint.wrap = true;
            hint.max_width_chars = 30;
            hint.xalign = 0;
            hint.margin_start = 8;
            hint.margin_end = 8;
            hint.margin_bottom = 6;
            card.append(hint);
            foreach (var d in candidates) card.append(device_button(d));

            card_motion = new Singularity.Animation.MotionBin(card);
            card_motion.margin_top = SHADOW_SPACE;
            card_motion.margin_bottom = SHADOW_SPACE;
            card_motion.margin_start = SHADOW_SPACE;
            card_motion.margin_end = SHADOW_SPACE;
            set_child(card_motion);
            place(position);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval) => {
                if (keyval != Gdk.Key.Escape) return false;
                dismiss();
                return true;
            });
            ((Gtk.Widget) this).add_controller(keys);
            var motion = new EventControllerMotion();
            motion.enter.connect(() => {
                inside = true;
                stop_linger();
            });
            motion.leave.connect(() => {
                inside = false;
                linger(1200);
            });
            card.add_controller(motion);
            map.connect(() => {
                card_motion.opacity = 0.0;
                if (!Singularity.Motion.reduced()) card_motion.scale = 0.88;
                Singularity.Motion.tween(card_motion, "opacity", 1.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
                Singularity.Motion.tween(card_motion, "scale", 1.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
            });
            linger(LINGER_MS);
        }

        private Widget device_button(NearbyDevice d) {
            var row = new Box(Orientation.HORIZONTAL, 10);
            var icon = new Image.from_icon_name(d.full_icon_name);
            icon.pixel_size = 32;
            row.append(icon);
            var name = new Label(d.name);
            name.xalign = 0;
            name.hexpand = true;
            name.ellipsize = Pango.EllipsizeMode.END;
            row.append(name);
            var button = new Button();
            button.add_css_class("flat");
            button.add_css_class("edge-chooser-device");
            button.child = row;
            button.clicked.connect(() => {
                client.place_input.begin(d.id, output, side, 0, length, (o, r) => {
                    try {
                        client.place_input.end(r);
                    } catch (Error e) {
                        warning("edge chooser: %s", e.message);
                    }
                });
                dismiss();
            });
            return button;
        }

        private void place(double position) {
            int along = (int) Math.round(position) - SHADOW_SPACE - 40;
            if (side == "left" || side == "right") {
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, int.max(0, along));
                GtkLayerShell.set_margin(this, side == "left" ? GtkLayerShell.Edge.LEFT : GtkLayerShell.Edge.RIGHT, GAP);
            } else {
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.LEFT, int.max(0, along - 90));
                GtkLayerShell.set_margin(this, side == "top" ? GtkLayerShell.Edge.TOP : GtkLayerShell.Edge.BOTTOM, GAP);
            }
        }

        private void linger(uint ms) {
            stop_linger();
            linger_id = Timeout.add(ms, () => {
                linger_id = 0;
                if (!inside) dismiss();
                return Source.REMOVE;
            });
        }

        private void stop_linger() {
            if (linger_id == 0) return;
            Source.remove(linger_id);
            linger_id = 0;
        }

        public void dismiss() {
            if (closing) return;
            closing = true;
            stop_linger();
            if (current == this) current = null;
            if (!Singularity.Motion.reduced()) {
                Singularity.Motion.tween(card_motion, "scale", 0.92,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT);
            }
            Singularity.Motion.tween(card_motion, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT).done.connect(() => {
                close_layer_window(this);
                destroy();
            });
        }

        private static Gdk.Monitor? monitor_named(string name) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var list = display.get_monitors();
            for (uint i = 0; i < list.get_n_items(); i++) {
                var m = (Gdk.Monitor) list.get_item(i);
                if (m.connector == name) return m;
            }
            return null;
        }
    }
}
