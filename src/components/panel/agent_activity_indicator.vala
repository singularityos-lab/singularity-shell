using Gtk;

namespace Singularity {

    public class AgentActivityIndicator : Gtk.Button {
        private const string NAME = "dev.sinty.Agent";
        private const string PATH = "/dev/sinty/Agent";
        private const string IFACE = "dev.sinty.Agent1";
        private const uint IDLE_MS = 8000;
        private const uint CURSOR_MS = 2500;

        private Label who_label;
        private AgentOrb orb;
        private DBusConnection? bus = null;
        private uint working_sub = 0;
        private uint pointer_sub = 0;
        private uint idle_timer = 0;
        private Gtk.Window? cursor = null;
        private Label? cursor_label = null;
        private uint cursor_timer = 0;

        public AgentActivityIndicator() {
            Object();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("agent-activity-indicator");

            var box = new Box(Orientation.HORIZONTAL, 6);
            orb = new AgentOrb(14);
            orb.state = AgentOrbState.ACT;
            orb.margin_start = -6;
            orb.margin_end = -6;
            orb.margin_top = -6;
            orb.margin_bottom = -6;
            box.append(orb);
            who_label = new Label(_("Sinty AI"));
            who_label.ellipsize = Pango.EllipsizeMode.END;
            who_label.max_width_chars = 22;
            box.append(who_label);
            set_child(box);

            clicked.connect(() => {
                if (bus != null) bus.call.begin(NAME, PATH, IFACE, "Stop", null, null, DBusCallFlags.NO_AUTO_START, -1, null);
                hide_now();
            });
            if (!AgentConfig.available()) return;
            try {
                bus = Bus.get_sync(BusType.SESSION);
                working_sub = bus.signal_subscribe(NAME, IFACE, "Working", PATH, null, DBusSignalFlags.NONE,
                    (conn, sender, object_path, iface, name, parameters) => {
                        string who, tool;
                        parameters.get("(ss)", out who, out tool);
                        show_working(who, tool);
                    });
                pointer_sub = bus.signal_subscribe(NAME, IFACE, "PointerAt", PATH, null, DBusSignalFlags.NONE,
                    (conn, sender, object_path, iface, name, parameters) => {
                        int x, y;
                        string who;
                        parameters.get("(iis)", out x, out y, out who);
                        show_cursor(x, y, who);
                    });
            } catch (Error e) {
                warning("Cannot watch Sinty AI: %s", e.message);
            }
        }

        public override void dispose() {
            if (bus != null) {
                if (working_sub != 0) bus.signal_unsubscribe(working_sub);
                if (pointer_sub != 0) bus.signal_unsubscribe(pointer_sub);
            }
            working_sub = 0;
            pointer_sub = 0;
            if (idle_timer != 0) Source.remove(idle_timer);
            idle_timer = 0;
            if (cursor_timer != 0) Source.remove(cursor_timer);
            cursor_timer = 0;
            if (cursor != null) cursor.destroy();
            cursor = null;
            base.dispose();
        }

        public static string display_name(string who) {
            if (who == "" || who.has_prefix("/") || who == "unknown") return _("Sinty AI");
            return who;
        }

        private void show_working(string who, string tool) {
            var name = display_name(who);
            who_label.label = name;
            string text = _("%s is working on this computer. Click to stop it.").printf(name);
            tooltip_text = text;
            update_property(Gtk.AccessibleProperty.LABEL, text, -1);
            visible = true;
            orb.state = tool == "" ? AgentOrbState.THINK : AgentOrbState.ACT;
            orb.kick(0.4);
            if (idle_timer != 0) Source.remove(idle_timer);
            idle_timer = Timeout.add(IDLE_MS, () => {
                idle_timer = 0;
                visible = false;
                return Source.REMOVE;
            });
        }

        private void hide_now() {
            if (idle_timer != 0) Source.remove(idle_timer);
            idle_timer = 0;
            visible = false;
            if (cursor != null) cursor.visible = false;
        }

        private static Gdk.Monitor? monitor_at(int x, int y, out Gdk.Rectangle area) {
            area = Gdk.Rectangle();
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var mons = display.get_monitors();
            Gdk.Monitor? first = null;
            for (uint i = 0; i < mons.get_n_items(); i++) {
                var mon = (Gdk.Monitor) mons.get_item(i);
                var g = mon.get_geometry();
                if (first == null) {
                    first = mon;
                    area = g;
                }
                if (x >= g.x && x < g.x + g.width && y >= g.y && y < g.y + g.height) {
                    area = g;
                    return mon;
                }
            }
            return first;
        }

        private void show_cursor(int x, int y, string who) {
            Gdk.Rectangle area;
            var mon = monitor_at(x, y, out area);
            if (mon == null) return;
            if (cursor == null) {
                cursor = new Gtk.Window();
                var app = GLib.Application.get_default() as Gtk.Application;
                if (app != null) cursor.set_application(app);
                GtkLayerShell.init_for_window(cursor);
                GtkLayerShell.set_namespace(cursor, "sinty-agent-cursor");
                GtkLayerShell.set_layer(cursor, GtkLayerShell.Layer.OVERLAY);
                GtkLayerShell.set_keyboard_mode(cursor, GtkLayerShell.KeyboardMode.NONE);
                GtkLayerShell.set_exclusive_zone(cursor, -1);
                GtkLayerShell.set_anchor(cursor, GtkLayerShell.Edge.TOP, true);
                GtkLayerShell.set_anchor(cursor, GtkLayerShell.Edge.LEFT, true);
                cursor.add_css_class("singularity");
                cursor.add_css_class("agent-cursor");
                cursor.can_target = false;
                var box = new Box(Orientation.HORIZONTAL, 2);
                var arrow = new DrawingArea();
                arrow.set_content_width(16);
                arrow.set_content_height(22);
                arrow.valign = Align.START;
                arrow.add_css_class("agent-cursor-arrow");
                arrow.set_draw_func((area, cr, w, h) => {
                    var fill = area.get_color();
                    cr.move_to(1.5, 1.5);
                    cr.line_to(1.5, 18.0);
                    cr.line_to(5.5, 14.0);
                    cr.line_to(8.5, 20.5);
                    cr.line_to(11.0, 19.5);
                    cr.line_to(8.0, 13.0);
                    cr.line_to(13.5, 13.0);
                    cr.close_path();
                    cr.set_source_rgba(fill.red, fill.green, fill.blue, fill.alpha);
                    cr.fill_preserve();
                    cr.set_source_rgb(1, 1, 1);
                    cr.set_line_width(1.5);
                    cr.set_line_join(Cairo.LineJoin.ROUND);
                    cr.stroke();
                });
                box.append(arrow);
                cursor_label = new Label("");
                cursor_label.add_css_class("agent-cursor-label");
                cursor_label.valign = Align.START;
                cursor_label.margin_top = 14;
                box.append(cursor_label);
                cursor.set_child(box);
                cursor.map.connect(() => {
                    var surface = cursor.get_surface();
                    if (surface != null) surface.set_input_region(new Cairo.Region());
                });
            }
            cursor_label.label = display_name(who);
            GtkLayerShell.set_monitor(cursor, mon);
            GtkLayerShell.set_margin(cursor, GtkLayerShell.Edge.LEFT, int.max(0, x - area.x));
            GtkLayerShell.set_margin(cursor, GtkLayerShell.Edge.TOP, int.max(0, y - area.y));
            cursor.present();
            if (cursor_timer != 0) Source.remove(cursor_timer);
            cursor_timer = Timeout.add(CURSOR_MS, () => {
                cursor_timer = 0;
                if (cursor != null) cursor.visible = false;
                return Source.REMOVE;
            });
        }
    }
}
