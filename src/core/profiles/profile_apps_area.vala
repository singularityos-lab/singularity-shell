using GLib;
using Singularity.Profiles;

namespace Singularity {

    public class ProfileAppEntry : Object {
        public string app { get; set; default = ""; }
        public int workspace { get; set; default = -1; }
        public string output { get; set; default = ""; }

        public ProfileAppEntry(string app, int workspace = -1, string output = "") {
            this.app = app;
            this.workspace = workspace;
            this.output = output;
        }

        public void build(Json.Builder b) {
            b.begin_object();
            b.set_member_name("app"); b.add_string_value(app);
            b.set_member_name("workspace"); b.add_int_value(workspace);
            b.set_member_name("output"); b.add_string_value(output);
            b.end_object();
        }

        public static ProfileAppEntry? from_node(Json.Node n) {
            if (n.get_value_type() == typeof(string)) {
                string id = n.get_string().strip();
                return id != "" ? new ProfileAppEntry(id) : null;
            }
            if (n.get_node_type() != Json.NodeType.OBJECT) return null;
            var o = n.get_object();
            string id = o.has_member("app") ? o.get_string_member("app").strip() : "";
            if (id == "") return null;
            return new ProfileAppEntry(id,
                o.has_member("workspace") ? (int) o.get_int_member("workspace") : -1,
                o.has_member("output") ? o.get_string_member("output") : "");
        }

        public static Gee.ArrayList<ProfileAppEntry> list_from(string json) {
            var list = new Gee.ArrayList<ProfileAppEntry>();
            var root = parse_value(json);
            if (root.get_node_type() != Json.NodeType.ARRAY) return list;
            root.get_array().foreach_element((a, i, n) => {
                var e = from_node(n);
                if (e != null && find(list, e.app) == null) list.add(e);
            });
            return list;
        }

        public static string list_to(Gee.List<ProfileAppEntry> list) {
            var b = new Json.Builder();
            b.begin_array();
            foreach (var e in list) e.build(b);
            b.end_array();
            return to_text(b.get_root(), false);
        }

        public static ProfileAppEntry? find(Gee.List<ProfileAppEntry> list, string app) {
            foreach (var e in list) {
                if (e.app == app) return e;
            }
            return null;
        }
    }

    public class ProfileApps : Object {
        private const int PLACE_TIMEOUT = 60;

        private Gee.ArrayList<ProfileAppEntry> _opened = new Gee.ArrayList<ProfileAppEntry>();
        private Gee.ArrayList<ProfileAppEntry> _closed = new Gee.ArrayList<ProfileAppEntry>();
        private Gee.HashMap<string, ProfileAppEntry> _pending = new Gee.HashMap<string, ProfileAppEntry>();
        private Area? _area = null;

        public Area build() {
            var a = new Area(Areas.APPS, area_label(Areas.APPS), "view-app-grid-symbolic");
            a.add(new Option("open", _("Open Apps"), OptionKind.STRUCTURED)
                .with_subtitle(_("Opened when the profile starts and closed when it ends")));
            a.add(new Option("close", _("Close Apps"), OptionKind.STRUCTURED)
                .with_subtitle(_("Apps with unsaved work stay open")));
            var running = new Option("running", _("Open Now"), OptionKind.STRUCTURED);
            running.read_only = true;
            a.add(running);
            a.handlers((key) => {
                switch (key) {
                    case "open": return ProfileAppEntry.list_to(_opened);
                    case "close": return ProfileAppEntry.list_to(_closed);
                    case "running": return ProfileAppEntry.list_to(running_entries());
                }
                return null;
            }, (key, json) => {
                if (key == "open") apply_open(ProfileAppEntry.list_from(json));
                else if (key == "close") apply_close(ProfileAppEntry.list_from(json));
            });
            var apps = AppSystem.get_default();
            apps.running_apps_changed.connect(() => a.notify_changed({ "running" }));
            apps.app_opened.connect(on_app_opened);
            _area = a;
            return a;
        }

        private static string app_id_for(string window_app_id) {
            var info = AppSystem.get_default().resolve_app_for_id(window_app_id);
            string id = info != null && info.get_id() != null ? info.get_id() : window_app_id;
            if (id.has_suffix(".desktop")) id = id.substring(0, id.length - ".desktop".length);
            return id;
        }

        private static bool same_app(string window_app_id, string app) {
            if (window_app_id.down() == app.down()) return true;
            return app_id_for(window_app_id).down() == app.down();
        }

        private static bool is_running(string app) {
            return AppSystem.get_default().is_app_running(app + ".desktop") || windows_of(app).size > 0;
        }

        private static Gee.ArrayList<AppSystem.Window> windows_of(string app) {
            var list = new Gee.ArrayList<AppSystem.Window>();
            foreach (var w in AppSystem.get_default().get_windows()) {
                if (w.app_id != null && w.app_id != "" && same_app(w.app_id, app)) list.add(w);
            }
            return list;
        }

        private static bool holds_unsaved_work(string app) {
            foreach (var inhibitor in IdleInhibitors.get_default().inhibitors) {
                if ((inhibitor.flags & IdleInhibitors.LOGOUT) == 0) continue;
                string id = inhibitor.app_id;
                if (id.has_suffix(".desktop")) id = id.substring(0, id.length - ".desktop".length);
                if (id.down() == app.down() || same_app(id, app)) return true;
            }
            return false;
        }

        private Gee.ArrayList<ProfileAppEntry> running_entries() {
            var list = new Gee.ArrayList<ProfileAppEntry>();
            var apps = AppSystem.get_default();
            foreach (var w in apps.get_windows()) {
                if (w.app_id == null || w.app_id == "" || w.app_id.has_prefix("dev.sinty.desktop")) continue;
                string id = app_id_for(w.app_id);
                if (ProfileAppEntry.find(list, id) != null) continue;
                if (apps.resolve_app_for_id(w.app_id) == null) continue;
                list.add(new ProfileAppEntry(id, apps.workspace_index_of(w), apps.output_of(w) ?? ""));
            }
            return list;
        }

        private static void launch(string app) {
            var info = AppSystem.get_default().resolve_app_for_id(app);
            if (info == null) info = new DesktopAppInfo(app + ".desktop");
            if (info == null) {
                warning("profiles: no app named %s", app);
                return;
            }
            AppSystem.launch_app(info);
        }

        private static void close_politely(string app) {
            foreach (var w in windows_of(app)) Singularity.close_window(w.handle);
        }

        private void apply_open(Gee.ArrayList<ProfileAppEntry> wanted) {
            foreach (var e in wanted) {
                if (ProfileAppEntry.find(_opened, e.app) != null || is_running(e.app)) continue;
                _opened.add(e);
                if (e.workspace >= 0 || e.output != "") watch_placement(e);
                launch(e.app);
            }
            var leaving = new Gee.ArrayList<ProfileAppEntry>();
            foreach (var e in _opened) {
                if (ProfileAppEntry.find(wanted, e.app) == null) leaving.add(e);
            }
            foreach (var e in leaving) {
                _opened.remove(e);
                _pending.unset(e.app);
                if (holds_unsaved_work(e.app)) continue;
                close_politely(e.app);
            }
            _area.notify_changed({ "open" });
        }

        private void apply_close(Gee.ArrayList<ProfileAppEntry> wanted) {
            var apps = AppSystem.get_default();
            foreach (var e in wanted) {
                if (ProfileAppEntry.find(_closed, e.app) != null) continue;
                var windows = windows_of(e.app);
                if (windows.size == 0 || holds_unsaved_work(e.app)) continue;
                var w = windows[0];
                _closed.add(new ProfileAppEntry(e.app, apps.workspace_index_of(w), apps.output_of(w) ?? ""));
                close_politely(e.app);
            }
            var back = new Gee.ArrayList<ProfileAppEntry>();
            foreach (var e in _closed) {
                if (ProfileAppEntry.find(wanted, e.app) == null) back.add(e);
            }
            foreach (var e in back) {
                _closed.remove(e);
                if (is_running(e.app)) continue;
                if (e.workspace >= 0 || e.output != "") watch_placement(e);
                launch(e.app);
            }
            _area.notify_changed({ "close" });
        }

        private void watch_placement(ProfileAppEntry e) {
            _pending[e.app] = e;
            Timeout.add_seconds(PLACE_TIMEOUT, () => {
                if (_pending.has_key(e.app) && _pending[e.app] == e) _pending.unset(e.app);
                return Source.REMOVE;
            });
        }

        private void on_app_opened(void* handle, string window_app_id) {
            if (_pending.size == 0) return;
            ProfileAppEntry? match = null;
            foreach (var e in _pending.values) {
                if (same_app(window_app_id, e.app)) {
                    match = e;
                    break;
                }
            }
            if (match == null) return;
            _pending.unset(match.app);
            var entry = match;
            Timeout.add(300, () => {
                var win = AppSystem.get_default().get_window_by_handle(handle);
                if (win != null) AppSystem.get_default().place_window_on(win, entry.output, entry.workspace);
                return Source.REMOVE;
            });
        }
    }
}
