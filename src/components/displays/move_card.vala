using Gtk;

namespace Singularity.Shell {

    public class MoveCard : Gtk.Window {
        private const int SHADOW_SPACE = 32;
        private const int GAP = 12;
        private const int PICTURE_WIDTH = 240;
        private const int PICTURE_HEIGHT = 150;

        private static MoveCard? current = null;

        private string device_id;
        private string app_id;
        private string side;
        private Box card;
        private Singularity.Animation.MotionBin card_motion;
        private Cancellable cancellable = new Cancellable();
        private bool closing = false;

        public static void start(Gtk.Application app) {
            var client = NearbyClient.get_default();
            client.app_dragged.connect((device_id, app_id, state, movable, output, side, position) => {
                if (state == "entered") {
                    if (!(side in InputSides.ALL)) return;
                    if (current != null) current.dismiss(false);
                    current = new MoveCard(app, device_id, app_id, movable, output, side, position);
                    current.present();
                    return;
                }
                if (current == null || current.device_id != device_id || current.app_id != app_id) return;
                current.dismiss(state == "dropped" && movable);
            });
        }

        private MoveCard(Gtk.Application app, string device_id, string app_id, bool movable, string output, string side, double position) {
            Object(application: app);
            this.device_id = device_id;
            this.app_id = app_id;
            this.side = side;

            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_namespace(this, "singularity-move-card");
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_exclusive_zone(this, -1);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            var monitor = monitor_named(output);
            if (monitor != null) GtkLayerShell.set_monitor(this, monitor);
            bool vertical = side == "left" || side == "right";
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, side == "left" || !vertical);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, side == "right");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, side == "top" || vertical);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, side == "bottom");
            can_target = false;

            add_css_class("singularity");
            add_css_class("edge-chooser-window");

            card = new Box(Orientation.VERTICAL, 8);
            card.add_css_class("edge-chooser");
            card.width_request = PICTURE_WIDTH + 20;
            Singularity.Style.BackgroundEffect.track(this, () => { return new Gtk.Widget[] { card }; });

            var picture = new Picture();
            picture.add_css_class("edge-window");
            picture.content_fit = ContentFit.CONTAIN;
            picture.can_shrink = true;
            picture.height_request = PICTURE_HEIGHT;
            var icon = new Image.from_gicon(icon_of(app_id));
            icon.pixel_size = 96;
            icon.height_request = PICTURE_HEIGHT;
            var preview = new Stack();
            preview.add_named(new Singularity.Widgets.Clamp(picture, PICTURE_WIDTH), "picture");
            preview.add_named(icon, "icon");
            preview.visible_child_name = "icon";
            card.append(preview);

            var d = NearbyClient.get_default().find(device_id);
            string device = d != null ? d.name : _("the other device");
            string app_name = label_of(app_id);
            var title = new Label(movable ? _("Let Go to Move %s to %s").printf(app_name, device)
                                          : _("%s Cannot Move to %s").printf(app_name, device));
            title.add_css_class("heading");
            title.wrap = true;
            title.max_width_chars = 26;
            title.xalign = 0;
            title.margin_start = 6;
            title.margin_end = 6;
            card.append(title);
            var hint = new Label(movable ? _("It continues there exactly as it is now, and closes here.")
                                         : _("This app cannot continue on another device."));
            hint.add_css_class("dim-label");
            hint.add_css_class("caption");
            hint.wrap = true;
            hint.max_width_chars = 30;
            hint.xalign = 0;
            hint.margin_start = 6;
            hint.margin_end = 6;
            hint.margin_bottom = 4;
            card.append(hint);

            card_motion = new Singularity.Animation.MotionBin(card);
            card_motion.margin_top = SHADOW_SPACE;
            card_motion.margin_bottom = SHADOW_SPACE;
            card_motion.margin_start = SHADOW_SPACE;
            card_motion.margin_end = SHADOW_SPACE;
            set_child(card_motion);
            place(position);

            Singularity.Migration.Preview.fetch.begin(app_id, cancellable, (o, r) => {
                try {
                    var previews = Singularity.Migration.Preview.fetch.end(r);
                    if (previews.size > 0) {
                        picture.paintable = previews[0].texture;
                        preview.visible_child_name = "picture";
                    }
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED)) debug("move card: %s", e.message);
                }
            });

            map.connect(() => {
                card_motion.opacity = 0.0;
                if (!Singularity.Motion.reduced()) card_motion.scale = 0.88;
                Singularity.Motion.tween(card_motion, "opacity", 1.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
                Singularity.Motion.tween(card_motion, "scale", 1.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
            });
        }

        private void place(double position) {
            int along = (int) Math.round(position) - SHADOW_SPACE - PICTURE_HEIGHT / 2;
            if (side == "left" || side == "right") {
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, int.max(0, along));
                GtkLayerShell.set_margin(this, side == "left" ? GtkLayerShell.Edge.LEFT : GtkLayerShell.Edge.RIGHT, GAP);
            } else {
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.LEFT, int.max(0, (int) Math.round(position) - SHADOW_SPACE - PICTURE_WIDTH / 2));
                GtkLayerShell.set_margin(this, side == "top" ? GtkLayerShell.Edge.TOP : GtkLayerShell.Edge.BOTTOM, GAP);
            }
        }

        public void dismiss(bool thrown) {
            if (closing) return;
            closing = true;
            cancellable.cancel();
            if (current == this) current = null;
            if (thrown && !Singularity.Motion.reduced()) {
                double distance = PICTURE_WIDTH + SHADOW_SPACE * 2 + GAP;
                string property = side == "left" || side == "right" ? "translate-x" : "translate-y";
                double sign = side == "left" || side == "top" ? -1 : 1;
                Singularity.Motion.tween(card_motion, property, sign * distance,
                    Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.EXIT);
            } else if (!Singularity.Motion.reduced()) {
                Singularity.Motion.tween(card_motion, "scale", 0.92,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT);
            }
            Singularity.Motion.tween(card_motion, "opacity", 0.0,
                thrown ? Singularity.Motion.Duration.MEDIUM : Singularity.Motion.Duration.SMALL,
                Singularity.Motion.Curve.EXIT).done.connect(() => {
                close_layer_window(this);
                destroy();
            });
        }

        private static string label_of(string app_id) {
            var info = new GLib.DesktopAppInfo(app_id + ".desktop");
            return info != null ? info.get_display_name() : app_id;
        }

        private static GLib.Icon icon_of(string app_id) {
            var info = new GLib.DesktopAppInfo(app_id + ".desktop");
            var icon = info != null ? info.get_icon() : null;
            return icon ?? new ThemedIcon.from_names({ app_id, "application-x-executable" });
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
