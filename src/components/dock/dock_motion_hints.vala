namespace Singularity {

    public delegate string[] DockAliasFunc(string app_id);

    public class DockMotionHints : Object {

        private unowned Gtk.Window window;
        private unowned Gtk.Widget container;
        private DockAliasFunc aliases;
        private HashTable<string, string> sent = new HashTable<string, string>(str_hash, str_equal);
        private bool hidden = false;
        private bool cleared = true;
        private ulong layout_id = 0;
        private unowned Gdk.FrameClock? clock = null;

        public DockMotionHints(Gtk.Window window, Gtk.Widget container, owned DockAliasFunc aliases) {
            this.window = window;
            this.container = container;
            this.aliases = (owned) aliases;
            unowned Gtk.Widget widget = window;
            widget.realize.connect(attach_clock);
            widget.unrealize.connect(detach_clock);
            window.map.connect(() => {
                sent.remove_all();
                cleared = true;
                sync();
            });
            window.unmap.connect(() => {
                sent.remove_all();
                cleared = true;
            });
            if (window.get_realized()) attach_clock();
        }

        public void set_hidden(bool value) {
            if (hidden == value) return;
            hidden = value;
            sync();
        }

        public void launch(string app_id) {
            sync();
            MotionHints.launch(window, app_id);
        }

        private void attach_clock() {
            detach_clock();
            clock = window.get_frame_clock();
            if (clock == null) return;
            layout_id = clock.layout.connect_after(() => sync());
        }

        private void detach_clock() {
            if (clock != null && layout_id != 0) clock.disconnect(layout_id);
            layout_id = 0;
            clock = null;
        }

        public void sync() {
            if (!window.get_mapped()) return;
            if (hidden) {
                if (!cleared) {
                    MotionHints.clear(window);
                    sent.remove_all();
                    cleared = true;
                }
                return;
            }
            double surface_x, surface_y;
            window.get_surface_transform(out surface_x, out surface_y);
            int window_width = window.get_width();
            int window_height = window.get_height();
            var seen = new GenericSet<string>(str_hash, str_equal);
            for (var child = container.get_first_child(); child != null; child = child.get_next_sibling()) {
                string? app_id = child.get_data<string>("app_id");
                if (app_id == null || app_id == "" || !child.get_mapped()) continue;
                Graphene.Rect bounds;
                if (!child.compute_bounds(window, out bounds)) continue;
                int x = (int) Math.round(bounds.origin.x + surface_x);
                int y = (int) Math.round(bounds.origin.y + surface_y);
                int width = (int) Math.round(bounds.size.width);
                int height = (int) Math.round(bounds.size.height);
                if (width <= 0 || height <= 0 || x + width <= 0 || y + height <= 0
                        || x >= window_width + surface_x || y >= window_height + surface_y) {
                    continue;
                }
                string value = "%d,%d,%d,%d".printf(x, y, width, height);
                string[] ids = { app_id };
                foreach (var alias in aliases(app_id)) {
                    if (alias != null && alias != "" && !(alias in ids)) ids += alias;
                }
                foreach (var id in ids) {
                    if (seen.contains(id)) continue;
                    seen.add(id);
                    if (sent.get(id) == value) continue;
                    MotionHints.set_icon_rect(window, id, x, y, width, height);
                    sent.insert(id, value);
                    cleared = false;
                }
            }
            string[] stale = {};
            foreach (var id in sent.get_keys()) {
                if (!seen.contains(id)) stale += id;
            }
            foreach (var id in stale) {
                MotionHints.set_icon_rect(window, id, 0, 0, 0, 0);
                sent.remove(id);
            }
        }
    }
}
