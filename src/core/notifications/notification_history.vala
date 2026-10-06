using GLib;

namespace Singularity {

    public class Notification : Object {
        public uint id { get; construct; }
        public string app_name { get; construct; }
        public string summary { get; construct; }
        public string body { get; construct; }
        public string icon { get; construct; }
        public string[] actions { get; construct; }
        public int64 timestamp { get; construct; }
        public string app_key { get; set; default = ""; }
        public string desktop_entry { get; set; default = ""; }
        public bool silenced { get; set; default = false; }
        public bool time_sensitive { get; set; default = false; }
        public bool restored { get; set; default = false; }
        public string lock_screen { get; set; default = AppNotificationPolicy.LOCK_HIDE_CONTENT; }
        public string grouping { get; set; default = AppNotificationPolicy.GROUP_BY_APP; }
        public string reply_placeholder { get; set; default = ""; }
        public string reply_submit { get; set; default = ""; }

        public Notification(uint id, string app_name, string summary, string body, string icon, string[] actions) {
            Object(
                id: id,
                app_name: app_name,
                summary: summary,
                body: body,
                icon: icon,
                actions: actions,
                timestamp: GLib.get_real_time()
            );
        }

        public Notification.with_time(uint id, string app_name, string summary, string body, string icon,
                                      string[] actions, int64 timestamp) {
            Object(
                id: id,
                app_name: app_name,
                summary: summary,
                body: body,
                icon: icon,
                actions: actions,
                timestamp: timestamp
            );
        }

        public bool has_inline_reply {
            get {
                if (restored) return false;
                for (int i = 0; i + 1 < actions.length; i += 2) {
                    if (actions[i] == "inline-reply") return true;
                }
                return false;
            }
        }

        public string group_key {
            owned get {
                if (grouping == AppNotificationPolicy.GROUP_OFF) return "single:%u".printf(id);
                return app_key != "" ? app_key : app_name;
            }
        }
    }

    public class NotificationHistoryFile : Object {
        public const int DEFAULT_LIMIT = 200;

        public string path { get; construct; }

        public NotificationHistoryFile(string path) {
            Object(path: path);
        }

        public static string default_path() {
            return Path.build_filename(Environment.get_user_state_dir(), "singularity", "notifications", "history.json");
        }

        public string icon_dir() {
            return Path.build_filename(Path.get_dirname(path), "icons");
        }

        public static Gee.ArrayList<Notification> prune(Gee.List<Notification> items, int retention_days,
                                                        int64 now_us, int limit) {
            var kept = new Gee.ArrayList<Notification>();
            int64 cutoff = retention_days > 0 ? now_us - (int64) retention_days * 86400 * 1000000 : int64.MIN;
            foreach (var n in items) {
                if (n.timestamp < cutoff) continue;
                if (limit > 0 && kept.size >= limit) break;
                kept.add(n);
            }
            return kept;
        }

        public static string serialize(Gee.List<Notification> items, uint next_id = 0) {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version"); b.add_int_value(1);
            b.set_member_name("next-id"); b.add_int_value(next_id);
            b.set_member_name("notifications");
            b.begin_array();
            foreach (var n in items) {
                b.begin_object();
                b.set_member_name("id"); b.add_int_value(n.id);
                b.set_member_name("app-name"); b.add_string_value(n.app_name);
                b.set_member_name("app-key"); b.add_string_value(n.app_key);
                b.set_member_name("desktop-entry"); b.add_string_value(n.desktop_entry);
                b.set_member_name("summary"); b.add_string_value(n.summary);
                b.set_member_name("body"); b.add_string_value(n.body);
                b.set_member_name("icon"); b.add_string_value(n.icon);
                b.set_member_name("timestamp"); b.add_int_value(n.timestamp);
                b.set_member_name("silenced"); b.add_boolean_value(n.silenced);
                b.set_member_name("time-sensitive"); b.add_boolean_value(n.time_sensitive);
                b.set_member_name("lock-screen"); b.add_string_value(n.lock_screen);
                b.set_member_name("grouping"); b.add_string_value(n.grouping);
                b.end_object();
            }
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        private static string str_member(Json.Object o, string name, string fallback = "") {
            if (!o.has_member(name)) return fallback;
            var node = o.get_member(name);
            if (node.get_value_type() != typeof(string)) return fallback;
            return node.get_string();
        }

        public static Gee.ArrayList<Notification> deserialize(string data) {
            var list = new Gee.ArrayList<Notification>();
            try {
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return list;
                var obj = root.get_object();
                if (!obj.has_member("notifications")) return list;
                obj.get_array_member("notifications").foreach_element((a, i, node) => {
                    if (node.get_node_type() != Json.NodeType.OBJECT) return;
                    var o = node.get_object();
                    if (!o.has_member("id") || !o.has_member("timestamp")) return;
                    var n = new Notification.with_time((uint) o.get_int_member("id"),
                        str_member(o, "app-name"), str_member(o, "summary"), str_member(o, "body"),
                        str_member(o, "icon"), new string[0], o.get_int_member("timestamp"));
                    n.app_key = str_member(o, "app-key");
                    n.desktop_entry = str_member(o, "desktop-entry");
                    n.silenced = o.has_member("silenced") && o.get_boolean_member("silenced");
                    n.time_sensitive = o.has_member("time-sensitive") && o.get_boolean_member("time-sensitive");
                    n.lock_screen = str_member(o, "lock-screen", AppNotificationPolicy.LOCK_HIDE_CONTENT);
                    n.grouping = str_member(o, "grouping", AppNotificationPolicy.GROUP_BY_APP);
                    n.restored = true;
                    list.add(n);
                });
            } catch (Error e) {
                warning("notification history: unreadable file: %s", e.message);
            }
            return list;
        }

        public static uint read_next_id(string data) {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return 0;
                var obj = root.get_object();
                return obj.has_member("next-id") ? (uint) obj.get_int_member("next-id") : 0;
            } catch (Error e) {
                return 0;
            }
        }

        public uint load_next_id() {
            string data;
            try {
                if (!FileUtils.get_contents(path, out data)) return 0;
            } catch (Error e) {
                return 0;
            }
            return read_next_id(data);
        }

        public Gee.ArrayList<Notification> load() {
            string data;
            try {
                if (!FileUtils.get_contents(path, out data)) return new Gee.ArrayList<Notification>();
            } catch (Error e) {
                return new Gee.ArrayList<Notification>();
            }
            return deserialize(data);
        }

        public void save(Gee.List<Notification> items, uint next_id = 0) {
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            try {
                FileUtils.set_contents_full(path, serialize(items, next_id), -1,
                    FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("notification history: could not save: %s", e.message);
            }
        }

        public void clear_icons(Gee.List<Notification> keep) {
            var used = new Gee.HashSet<string>();
            foreach (var n in keep) used.add(n.icon);
            try {
                var dir = Dir.open(icon_dir());
                string? name;
                while ((name = dir.read_name()) != null) {
                    string full = Path.build_filename(icon_dir(), name);
                    if (!used.contains(full)) FileUtils.remove(full);
                }
            } catch (FileError e) {
            }
        }
    }
}
