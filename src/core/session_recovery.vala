using GLib;
using Gee;

namespace Singularity {

    /** One saved window from the previous session. */
    public class SessionEntry : Object {
        public string app_id;
        public string name;
        public string title;         // live window title, shown when the app name is unhelpful
        public string icon_name;     // fallback icon name
        public GLib.Icon? gicon;     // preferred icon
        public int x;
        public int y;
        public int w;
        public int h;
        public bool maximized;
        public bool fullscreen;
        public string monitor;       // connector
        public bool selected = true; // chosen in the restore dialog
    }

    /**
     * Session recovery. On logout/shutdown/reboot it snapshots
     * the open windows (app + exact geometry + monitor) to
     * ~/.local/state/singularity/session.json. On the next login the shell
     * asks (via a dialog) whether to reopen them, then relaunches the apps
     * and places each window back where it was.
     *
     * Window geometry comes from labwc via the singularity-tiling
     * `get_geometry` request; placement back uses `set_geometry`.
     */
    public class SessionRecovery : Object {
        private AppSystem app_system;
        private string state_path;

        // Pending placements during a restore: app_id -> queue of entries.
        private HashTable<string, Gee.ArrayList<SessionEntry>> _pending;
        private ulong _opened_handler = 0;
        private uint _stop_timer = 0;

        public SessionRecovery() {
            app_system = AppSystem.get_default();
            string dir = Path.build_filename(Environment.get_user_state_dir(),
                                              "singularity");
            try { File.new_for_path(dir).make_directory_with_parents(); }
            catch (Error e) { /* exists */ }
            state_path = Path.build_filename(dir, "session.json");
        }

        public bool has_session() {
            return FileUtils.test(state_path, FileTest.EXISTS) && load().size > 0;
        }

        // Capture
        public void capture() {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("captured_at");
            builder.add_string_value(new DateTime.now_local().to_string());
            builder.set_member_name("entries");
            builder.begin_array();

            foreach (var win in app_system.get_windows()) {
                if (win.app_id == null || win.app_id == "") continue;
                // Only relaunchable apps (must resolve to a .desktop).
                var info = app_system.get_app_info(win.app_id) as DesktopAppInfo;
                if (info == null) continue;
                // Skip our own shell surfaces / non-app windows defensively.
                if (win.app_id.has_prefix("dev.sinty.desktop")) continue;

                int x, y, w, h, mx, fs;
                string? conn;
                bool got = Singularity.wayland_get_window_geometry(
                    win.handle, out x, out y, out w, out h, out mx, out fs, out conn);
                if (!got) { x = 0; y = 0; w = 0; h = 0; mx = 0; fs = 0; conn = ""; }

                builder.begin_object();
                builder.set_member_name("app_id");   builder.add_string_value(win.app_id);
                builder.set_member_name("name");     builder.add_string_value(info.get_display_name());
                builder.set_member_name("title");    builder.add_string_value(win.title ?? "");
                builder.set_member_name("x");        builder.add_int_value(x);
                builder.set_member_name("y");        builder.add_int_value(y);
                builder.set_member_name("w");        builder.add_int_value(w);
                builder.set_member_name("h");        builder.add_int_value(h);
                builder.set_member_name("maximized");builder.add_boolean_value(mx != 0);
                builder.set_member_name("fullscreen");builder.add_boolean_value(fs != 0);
                builder.set_member_name("monitor");  builder.add_string_value(conn ?? "");
                builder.end_object();
            }
            builder.end_array();
            builder.end_object();

            var gen = new Json.Generator();
            gen.set_root(builder.get_root());
            gen.pretty = true;
            try { gen.to_file(state_path); }
            catch (Error e) { warning("session capture: %s", e.message); }
        }

        // Load
        public Gee.ArrayList<SessionEntry> load() {
            var list = new Gee.ArrayList<SessionEntry>();
            if (!FileUtils.test(state_path, FileTest.EXISTS)) return list;
            var parser = new Json.Parser();
            try {
                parser.load_from_file(state_path);
                var root = parser.get_root();
                if (root == null) return list;
                var obj = root.get_object();
                if (obj == null || !obj.has_member("entries")) return list;
                var arr = obj.get_array_member("entries");
                foreach (var node in arr.get_elements()) {
                    var e = node.get_object();
                    if (e == null) continue;
                    var se = new SessionEntry();
                    se.app_id    = e.get_string_member_with_default("app_id", "");
                    se.name      = e.get_string_member_with_default("name", se.app_id);
                    se.title     = e.get_string_member_with_default("title", "");
                    se.x = (int) e.get_int_member_with_default("x", 0);
                    se.y = (int) e.get_int_member_with_default("y", 0);
                    se.w = (int) e.get_int_member_with_default("w", 0);
                    se.h = (int) e.get_int_member_with_default("h", 0);
                    se.maximized  = e.get_boolean_member_with_default("maximized", false);
                    se.fullscreen = e.get_boolean_member_with_default("fullscreen", false);
                    se.monitor    = e.get_string_member_with_default("monitor", "");
                    if (se.app_id == "") continue;
                    var info = app_system.get_app_info(se.app_id) as DesktopAppInfo;
                    if (info != null) { se.gicon = info.get_icon(); se.icon_name = se.app_id; }
                    else se.icon_name = "application-x-executable";
                    list.add(se);
                }
            } catch (Error err) {
                warning("session load: %s", err.message);
            }
            return list;
        }

        public void clear() {
            FileUtils.unlink(state_path);
        }

        // Restore
        public void restore(Gee.ArrayList<SessionEntry> entries) {
            _pending = new HashTable<string, Gee.ArrayList<SessionEntry>>(str_hash, str_equal);
            foreach (var e in entries) {
                if (!e.selected) continue;
                if (!_pending.contains(e.app_id))
                    _pending.insert(e.app_id, new Gee.ArrayList<SessionEntry>());
                _pending.get(e.app_id).add(e);
                launch(e.app_id);
            }
            if (_pending.size() == 0) { clear(); return; }

            // Place windows as they map.
            _opened_handler = app_system.app_opened.connect(on_app_opened);
            // Stop listening after a grace period; restore is best-effort.
            _stop_timer = GLib.Timeout.add_seconds(20, () => {
                stop_listening();
                return GLib.Source.REMOVE;
            });
            // The snapshot has served its purpose.
            clear();
        }

        private void launch(string app_id) {
            var info = app_system.get_app_info(app_id) as DesktopAppInfo;
            if (info == null) return;
            try {
                var ctx = Gdk.Display.get_default().get_app_launch_context();
                info.launch(null, ctx);
            } catch (Error e) {
                warning("session restore launch %s: %s", app_id, e.message);
            }
        }

        private void on_app_opened(void* handle, string app_id) {
            if (_pending == null) return;
            var q = _pending.get(app_id);
            if (q == null || q.size == 0) return;
            var e = q.remove_at(0);
            if (q.size == 0) _pending.remove(app_id);

            // Place after a couple of frames so the window has its surface.
            void* h = handle;
            GLib.Timeout.add(120, () => {
                if (e.w > 0 && e.h > 0)
                    Singularity.wayland_set_geometry(h, e.x, e.y, e.w, e.h);
                return GLib.Source.REMOVE;
            });

            if (_pending.size() == 0) stop_listening();
        }

        private void stop_listening() {
            if (_opened_handler != 0) {
                app_system.disconnect(_opened_handler);
                _opened_handler = 0;
            }
            if (_stop_timer != 0) { GLib.Source.remove(_stop_timer); _stop_timer = 0; }
            _pending = null;
        }
    }
}
