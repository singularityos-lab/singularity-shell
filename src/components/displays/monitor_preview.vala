using Gtk;
using Gdk;
using Cairo;

namespace Singularity.Shell {

    public class RemoteTile : Object {
        public string id;
        public string name;
        public string output;
        public string side;
        public int start;
        public int end;
        public string state;
    }

    public class MonitorPreview : DrawingArea {
        private const double TILE_SHARE = 0.62;
        private GenericArray<RemoteTile> remotes = new GenericArray<RemoteTile>();
        private RemoteTile? dragging_remote = null;
        private double remote_drag_x;
        private double remote_drag_y;
        public signal void remote_moved(string id, string output, string side, int start, int end);
        private DisplayManager display_manager;
        private DisplayManager.Monitor? dragging_monitor = null;
        private double drag_start_x;
        private double drag_start_y;
        private int monitor_start_x;
        private int monitor_start_y;
        private double view_scale = 0.1;
        private int offset_x = 0;
        private int offset_y = 0;
        private bool _is_dragging = false;
        public string shell_monitor_name { get; set; default = ""; }
        public signal void layout_changed();
        public signal void shell_monitor_changed(string connector_name);

        public MonitorPreview() {
            display_manager = DisplayManager.get_default();
            display_manager.monitors_changed.connect(queue_draw);
            set_draw_func(draw_func);
            var gesture_drag = new Gtk.GestureDrag();
            gesture_drag.drag_begin.connect(on_drag_begin);
            gesture_drag.drag_update.connect(on_drag_update);
            gesture_drag.drag_end.connect(on_drag_end);
            add_controller(gesture_drag);
            var gesture_click = new Gtk.GestureClick();
            gesture_click.button = 1;
            gesture_click.pressed.connect(on_click_pressed);
            add_controller(gesture_click);
            set_size_request(-1, 200);
            add_css_class("monitor-preview");
        }

        public void set_remotes(GenericArray<RemoteTile> tiles) {
            if (dragging_remote != null) return;
            remotes = tiles;
            queue_draw();
        }

        private static void monitor_size(DisplayManager.Monitor m, out int w, out int h) {
            w = m.current_mode != null ? m.current_mode.width : 1920;
            h = m.current_mode != null ? m.current_mode.height : 1080;
            if (m.transform % 2 != 0) {
                int t = w;
                w = h;
                h = t;
            }
        }

        private static int logical(DisplayManager.Monitor m, int pixels) {
            double scale = m.scale > 0 ? m.scale : 1.0;
            return (int) Math.round(pixels / scale);
        }

        private DisplayManager.Monitor? monitor_named(string name) {
            foreach (var m in display_manager.get_monitors()) {
                if (m.enabled && m.name == name) return m;
            }
            return null;
        }

        private bool remote_rect(RemoteTile r, out double x, out double y, out double w, out double h) {
            x = y = w = h = 0;
            var m = monitor_named(r.output);
            if (m == null) return false;
            int mw, mh;
            monitor_size(m, out mw, out mh);
            double th = mh * TILE_SHARE;
            double tw = th * 1.6;
            bool vertical = r.side == "left" || r.side == "right";
            double length = vertical ? logical(m, mh) : logical(m, mw);
            double centre = length > 0 ? ((r.start + r.end) / 2.0) / length : 0.5;
            switch (r.side) {
                case "left":
                    x = m.x - tw; y = m.y + centre.clamp(0, 1) * mh - th / 2; break;
                case "right":
                    x = m.x + mw; y = m.y + centre.clamp(0, 1) * mh - th / 2; break;
                case "top":
                    x = m.x + centre.clamp(0, 1) * mw - tw / 2; y = m.y - th; break;
                default:
                    x = m.x + centre.clamp(0, 1) * mw - tw / 2; y = m.y + mh; break;
            }
            w = tw;
            h = th;
            return true;
        }

        private void calculate_view_transform(int width, int height) {
            int min_x = int.MAX;
            int min_y = int.MAX;
            int max_x = int.MIN;
            int max_y = int.MIN;
            foreach (var m in display_manager.get_monitors()) {
                if (!m.enabled) continue;
                if (m.x < min_x) min_x = m.x;
                if (m.y < min_y) min_y = m.y;
                int w = m.current_mode != null ? m.current_mode.width : 1920;
                int h = m.current_mode != null ? m.current_mode.height : 1080;
                if (m.transform == 1 || m.transform == 3 || m.transform == 5 || m.transform == 7) {
                    int temp = w; w = h; h = temp;
                }
                if (m.x + w > max_x) max_x = m.x + w;
                if (m.y + h > max_y) max_y = m.y + h;
            }
            if (min_x == int.MAX) {
                return;
            }
            foreach (var r in remotes.data) {
                double rx = 0, ry = 0, rw = 0, rh = 0;
                if (r == dragging_remote || !remote_rect(r, out rx, out ry, out rw, out rh)) continue;
                min_x = int.min(min_x, (int) rx);
                min_y = int.min(min_y, (int) ry);
                max_x = int.max(max_x, (int) (rx + rw));
                max_y = int.max(max_y, (int) (ry + rh));
            }
            int total_w = max_x - min_x;
            int total_h = max_y - min_y;
            total_w += 1000;
            total_h += 1000;
            double scale_x = (double)width / total_w;
            double scale_y = (double)height / total_h;
            view_scale = double.min(scale_x, scale_y);
            offset_x = (int)((width - (total_w - 1000) * view_scale) / 2) - (int)(min_x * view_scale);
            offset_y = (int)((height - (total_h - 1000) * view_scale) / 2) - (int)(min_y * view_scale);
        }

        private void draw_func(DrawingArea area, Context cr, int width, int height) {
            calculate_view_transform(width, height);
            calculate_view_transform(width, height);
            int index = 1;
            foreach (var m in display_manager.get_monitors()) {
                if (!m.enabled) continue;
                int w = m.current_mode != null ? m.current_mode.width : 1920;
                int h = m.current_mode != null ? m.current_mode.height : 1080;
                if (m.transform == 1 || m.transform == 3 || m.transform == 5 || m.transform == 7) {
                    int temp = w; w = h; h = temp;
                }
                double x = m.x * view_scale + offset_x;
                double y = m.y * view_scale + offset_y;
                double dw = w * view_scale;
                double dh = h * view_scale;
                // Monitor body
                rounded_rect(cr, x, y, dw, dh, 4.0);
                cr.set_source_rgba(0.18, 0.18, 0.18, 1.0);
                cr.fill_preserve();
                if (m == dragging_monitor) {
                    cr.set_source_rgba(0.3, 0.6, 1.0, 1.0);
                    cr.set_line_width(2.0);
                } else {
                    cr.set_source_rgba(0.38, 0.38, 0.38, 1.0);
                    cr.set_line_width(1.0);
                }
                cr.stroke();

                bool is_shell = (m.name == shell_monitor_name && shell_monitor_name != "");
                double bar_alpha = is_shell ? 0.70 : 0.38;

                // Topbar skeleton
                double topbar_h = double.max(4.0, dh * 0.06);
                rounded_rect(cr, x + 2, y + 2, dw - 4, topbar_h, 2.0);
                cr.set_source_rgba(0.55, 0.55, 0.55, bar_alpha);
                cr.fill();

                // Tiny dots in topbar (clock / icons hint)
                double dot_y = y + 2 + topbar_h / 2;
                double dot_r = double.max(1.0, topbar_h * 0.18);
                for (int d = 0; d < 3; d++) {
                    cr.arc(x + dw - 6 - d * (dot_r * 2 + 2), dot_y, dot_r, 0, 2 * Math.PI);
                    cr.set_source_rgba(0.75, 0.75, 0.75, bar_alpha);
                    cr.fill();
                }

                // Dock skeleton
                double dock_h = double.max(6.0, dh * 0.10);
                double dock_w = dw * 0.55;
                double dock_x = x + (dw - dock_w) / 2;
                double dock_y = y + dh - dock_h - 3;
                rounded_rect(cr, dock_x, dock_y, dock_w, dock_h, 3.0);
                cr.set_source_rgba(0.50, 0.50, 0.50, bar_alpha);
                cr.fill();

                // Tiny icon dots in dock
                int n_icons = (int)(dock_w / (dock_h * 1.4));
                if (n_icons > 8) n_icons = 8;
                double icon_r = double.max(1.5, dock_h * 0.22);
                double icon_spacing = dock_w / (n_icons + 1);
                for (int d = 0; d < n_icons; d++) {
                    cr.arc(dock_x + icon_spacing * (d + 1), dock_y + dock_h / 2, icon_r, 0, 2 * Math.PI);
                    cr.set_source_rgba(0.80, 0.80, 0.80, bar_alpha);
                    cr.fill();
                }

                // Monitor number badge
                cr.select_font_face("Inter", FontSlant.NORMAL, FontWeight.BOLD);
                cr.set_font_size(20.0);
                string num = index.to_string();
                TextExtents extents;
                cr.text_extents(num, out extents);
                double badge_cx = x + dw / 2;
                double badge_cy = y + dh / 2;
                cr.arc(badge_cx, badge_cy, 16, 0, 2 * Math.PI);
                cr.set_source_rgba(is_shell ? 0.2 : 0.85, is_shell ? 0.55 : 0.85, is_shell ? 1.0 : 0.85, 1.0);
                cr.fill();
                cr.set_source_rgba(is_shell ? 1.0 : 0.1, is_shell ? 1.0 : 0.1, is_shell ? 1.0 : 0.1, 1.0);
                cr.move_to(badge_cx - extents.width / 2 - extents.x_bearing,
                           badge_cy - extents.height / 2 - extents.y_bearing);
                cr.show_text(num);

                index++;
            }
            foreach (var r in remotes.data) draw_remote(cr, r);
        }

        private void draw_remote(Context cr, RemoteTile r) {
            double x, y, w, h;
            if (r == dragging_remote) {
                double rx, ry;
                if (!remote_rect(r, out rx, out ry, out w, out h)) return;
                x = remote_drag_x - w * view_scale / 2;
                y = remote_drag_y - h * view_scale / 2;
            } else {
                if (!remote_rect(r, out x, out y, out w, out h)) return;
                x = x * view_scale + offset_x;
                y = y * view_scale + offset_y;
            }
            double dw = w * view_scale, dh = h * view_scale;
            bool live = r.state == "connected" || r.state == "active";
            var accent = get_color();
            rounded_rect(cr, x + 3, y + 3, dw - 6, dh - 6, 6.0);
            cr.set_source_rgba(0.14, 0.14, 0.16, live ? 0.95 : 0.6);
            cr.fill_preserve();
            cr.set_line_width(r == dragging_remote || r.state == "active" ? 2.0 : 1.0);
            if (live) cr.set_source_rgba(accent.red, accent.green, accent.blue, 0.9);
            else cr.set_source_rgba(0.5, 0.5, 0.5, 0.7);
            cr.set_dash(live ? new double[0] : new double[] { 4.0, 3.0 }, 0);
            cr.stroke();
            cr.set_dash(new double[0], 0);
            var layout = create_pango_layout(r.name);
            layout.set_width((int) ((dw - 16) * Pango.SCALE));
            layout.set_ellipsize(Pango.EllipsizeMode.END);
            layout.set_alignment(Pango.Alignment.CENTER);
            int tw, th;
            layout.get_pixel_size(out tw, out th);
            cr.set_source_rgba(1, 1, 1, live ? 0.92 : 0.55);
            cr.move_to(x + 8, y + (dh - th) / 2);
            Pango.cairo_show_layout(cr, layout);
        }

        private RemoteTile? remote_at(double px, double py) {
            for (int i = (int) remotes.length - 1; i >= 0; i--) {
                double x, y, w, h;
                if (!remote_rect(remotes[i], out x, out y, out w, out h)) continue;
                x = x * view_scale + offset_x;
                y = y * view_scale + offset_y;
                if (px >= x && px <= x + w * view_scale && py >= y && py <= y + h * view_scale) return remotes[i];
            }
            return null;
        }

        private bool side_free(DisplayManager.Monitor m, string side) {
            int mw, mh;
            monitor_size(m, out mw, out mh);
            foreach (var o in display_manager.get_monitors()) {
                if (o == m || !o.enabled) continue;
                int ow, oh;
                monitor_size(o, out ow, out oh);
                bool overlap_y = o.y < m.y + mh && m.y < o.y + oh;
                bool overlap_x = o.x < m.x + mw && m.x < o.x + ow;
                switch (side) {
                    case "left": if (overlap_y && o.x + ow == m.x) return false; break;
                    case "right": if (overlap_y && o.x == m.x + mw) return false; break;
                    case "top": if (overlap_x && o.y + oh == m.y) return false; break;
                    default: if (overlap_x && o.y == m.y + mh) return false; break;
                }
            }
            return true;
        }

        private void drop_remote(RemoteTile r, double px, double py) {
            double lx = (px - offset_x) / view_scale, ly = (py - offset_y) / view_scale;
            DisplayManager.Monitor? best = null;
            string best_side = "";
            double best_distance = double.MAX;
            foreach (var m in display_manager.get_monitors()) {
                if (!m.enabled) continue;
                int mw, mh;
                monitor_size(m, out mw, out mh);
                double cx = lx.clamp(m.x, m.x + mw), cy = ly.clamp(m.y, m.y + mh);
                string[] sides = { "left", "right", "top", "bottom" };
                double[] gaps = { Math.fabs(lx - m.x) + Math.fabs(ly - cy), Math.fabs(lx - (m.x + mw)) + Math.fabs(ly - cy),
                                  Math.fabs(ly - m.y) + Math.fabs(lx - cx), Math.fabs(ly - (m.y + mh)) + Math.fabs(lx - cx) };
                for (int i = 0; i < 4; i++) {
                    if (gaps[i] < best_distance && side_free(m, sides[i])) {
                        best = m;
                        best_side = sides[i];
                        best_distance = gaps[i];
                    }
                }
            }
            if (best == null) return;
            int bw, bh;
            monitor_size(best, out bw, out bh);
            int length = best_side == "left" || best_side == "right" ? logical(best, bh) : logical(best, bw);
            r.output = best.name;
            r.side = best_side;
            r.start = 0;
            r.end = length;
            remote_moved(r.id, r.output, r.side, r.start, r.end);
        }

        private void on_drag_begin(Gtk.GestureDrag gesture, double start_x, double start_y) {
            _is_dragging = false;
            dragging_monitor = null;
            dragging_remote = remote_at(start_x, start_y);
            if (dragging_remote != null) {
                drag_start_x = start_x;
                drag_start_y = start_y;
                remote_drag_x = start_x;
                remote_drag_y = start_y;
                queue_draw();
                return;
            }
            unowned var monitors = display_manager.get_monitors();
            for (int i = (int)monitors.length() - 1; i >= 0; i--) {
                var m = monitors.nth_data(i);
                if (!m.enabled) continue;
                int w = m.current_mode != null ? m.current_mode.width : 1920;
                int h = m.current_mode != null ? m.current_mode.height : 1080;
                if (m.transform % 2 != 0) { int t = w; w = h; h = t; }
                double mx = m.x * view_scale + offset_x;
                double my = m.y * view_scale + offset_y;
                double mw = w * view_scale;
                double mh = h * view_scale;
                if (start_x >= mx && start_x <= mx + mw && start_y >= my && start_y <= my + mh) {
                    dragging_monitor = m;
                    drag_start_x = start_x;
                    drag_start_y = start_y;
                    monitor_start_x = m.x;
                    monitor_start_y = m.y;
                    queue_draw();
                    break;
                }
            }
        }

        private void on_drag_update(Gtk.GestureDrag gesture, double offset_x, double offset_y) {
            if (dragging_remote != null) {
                if ((offset_x * offset_x + offset_y * offset_y) > 25.0) _is_dragging = true;
                remote_drag_x = drag_start_x + offset_x;
                remote_drag_y = drag_start_y + offset_y;
                queue_draw();
                return;
            }
            if (dragging_monitor != null) {
                if ((offset_x * offset_x + offset_y * offset_y) > 25.0) {
                    _is_dragging = true;
                }
                int dx = (int)(offset_x / view_scale);
                int dy = (int)(offset_y / view_scale);
                dragging_monitor.x = monitor_start_x + dx;
                dragging_monitor.y = monitor_start_y + dy;
                queue_draw();
            }
        }

        private void on_drag_end(Gtk.GestureDrag gesture, double offset_x, double offset_y) {
            if (dragging_remote != null) {
                var r = dragging_remote;
                dragging_remote = null;
                if (_is_dragging) drop_remote(r, drag_start_x + offset_x, drag_start_y + offset_y);
                _is_dragging = false;
                queue_draw();
                return;
            }
            if (dragging_monitor != null && _is_dragging) {
                snap_to_grid();
                layout_changed();
            }
            dragging_monitor = null;
            _is_dragging = false;
            queue_draw();
        }

        private void on_click_pressed(Gtk.GestureClick gesture, int n_press, double click_x, double click_y) {
            if (_is_dragging || remote_at(click_x, click_y) != null) return;
            unowned var monitors = display_manager.get_monitors();
            for (int i = (int)monitors.length() - 1; i >= 0; i--) {
                var m = monitors.nth_data(i);
                if (!m.enabled) continue;
                int w = m.current_mode != null ? m.current_mode.width : 1920;
                int h = m.current_mode != null ? m.current_mode.height : 1080;
                if (m.transform % 2 != 0) { int t = w; w = h; h = t; }
                double mx = m.x * view_scale + offset_x;
                double my = m.y * view_scale + offset_y;
                double mw = w * view_scale;
                double mh = h * view_scale;
                if (click_x >= mx && click_x <= mx + mw && click_y >= my && click_y <= my + mh) {
                    shell_monitor_name = m.name;
                    shell_monitor_changed(m.name);
                    queue_draw();
                    break;
                }
            }
        }

        private void snap_to_grid() {
            // Collect enabled monitors into array
            DisplayManager.Monitor[] enabled = {};
            foreach (var m in display_manager.get_monitors()) {
                if (m.enabled) enabled += m;
            }
            if (enabled.length == 0) return;
            // Sort array by current dragged x position (bubble sort - small array)
            for (int i = 0; i < enabled.length - 1; i++) {
                for (int j = 0; j < enabled.length - 1 - i; j++) {
                    if (enabled[j].x > enabled[j + 1].x) {
                        var tmp = enabled[j];
                        enabled[j] = enabled[j + 1];
                        enabled[j + 1] = tmp;
                    }
                }
            }
            // Pack monitors left-to-right with no gaps, using each monitor's own width
            int cursor = 0;
            foreach (var m in enabled) {
                int w = m.current_mode != null ? m.current_mode.width : 1920;
                m.x = cursor;
                m.y = 0;
                cursor += w;
            }
        }

        private void rounded_rect(Cairo.Context cr, double x, double y, double w, double h, double r) {
            cr.new_sub_path();
            cr.arc(x + r,     y + r,     r, Math.PI,       1.5 * Math.PI);
            cr.arc(x + w - r, y + r,     r, 1.5 * Math.PI, 2.0 * Math.PI);
            cr.arc(x + w - r, y + h - r, r, 0,             0.5 * Math.PI);
            cr.arc(x + r,     y + h - r, r, 0.5 * Math.PI, Math.PI);
            cr.close_path();
        }

    }
}
