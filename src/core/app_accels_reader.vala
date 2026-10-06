namespace Singularity {

    public class AppAccelsReader : Object {
        public const string INTERFACE = "dev.sinty.ActionAccels1";
        private const int TIMEOUT_MS = 500;

        public static string object_path_for(string bus_name) {
            return "/" + bus_name.replace(".", "/").replace("-", "_");
        }

        public static GenericArray<AppAccel> parse(Variant list, HashTable<string, bool>? enabled,
                                                   bool filter_app, bool filter_win) {
            var result = new GenericArray<AppAccel>();
            for (size_t i = 0; i < list.n_children(); i++) {
                var dict = new VariantDict(list.get_child_value(i));
                string? action = null;
                if (!dict.lookup("action", "s", out action) || action == null || action == "") continue;
                Variant? accels = dict.lookup_value("accels", VariantType.STRING_ARRAY);
                if (accels == null || accels.n_children() == 0) continue;
                if (enabled != null) {
                    string name;
                    Variant? target;
                    try {
                        GLib.Action.parse_detailed_name(action, out name, out target);
                    } catch (Error e) {
                        continue;
                    }
                    bool check = (filter_app && name.has_prefix("app.")) || (filter_win && name.has_prefix("win."));
                    if (check && !enabled.contains(name)) continue;
                }
                var entry = new AppAccel();
                entry.action = action;
                entry.accels = accels.get_strv();
                string? label = null;
                if (dict.lookup("label", "s", out label) && label != null) entry.label = label;
                string? group = null;
                if (dict.lookup("group", "s", out group) && group != null) entry.group = group;
                result.add(entry);
            }
            return result;
        }

        public static string signature(GenericArray<AppAccel>? list) {
            if (list == null) return "";
            var sb = new StringBuilder();
            foreach (var a in list.data) {
                sb.append(a.action).append_c('\t').append(a.label).append_c('\t').append(a.group)
                    .append_c('\t').append(string.joinv(",", a.accels)).append_c('\n');
            }
            return sb.str;
        }

        public static async GenericArray<AppAccel>? fetch(DBusConnection conn, string bus_name) {
            string app_path = object_path_for(bus_name);
            Variant reply;
            try {
                reply = yield conn.call(bus_name, app_path, INTERFACE, "ListAccels", null,
                    new VariantType("(aa{sv})"), DBusCallFlags.NO_AUTO_START, TIMEOUT_MS, null);
            } catch (Error e) {
                return null;
            }
            var enabled = new HashTable<string, bool>(str_hash, str_equal);
            bool have_app = yield describe_all(conn, bus_name, app_path, "app", enabled);
            bool have_win = false;
            string? win_path = yield active_window_path(conn, bus_name, app_path);
            if (win_path != null) have_win = yield describe_all(conn, bus_name, win_path, "win", enabled);
            return parse(reply.get_child_value(0), enabled, have_app, have_win);
        }

        private static async bool describe_all(DBusConnection conn, string bus_name, string path,
                                               string prefix, HashTable<string, bool> enabled) {
            try {
                var reply = yield conn.call(bus_name, path, "org.gtk.Actions", "DescribeAll", null,
                    new VariantType("(a{s(bgav)})"), DBusCallFlags.NO_AUTO_START, TIMEOUT_MS, null);
                var dict = reply.get_child_value(0);
                for (size_t i = 0; i < dict.n_children(); i++) {
                    var entry = dict.get_child_value(i);
                    string name = entry.get_child_value(0).get_string();
                    bool on = entry.get_child_value(1).get_child_value(0).get_boolean();
                    if (on) enabled.insert(prefix + "." + name, true);
                }
                return true;
            } catch (Error e) {
                return false;
            }
        }

        private static async string? active_window_path(DBusConnection conn, string bus_name, string app_path) {
            try {
                var reply = yield conn.call(bus_name, app_path, "org.gtk.Actions", "Describe",
                    new Variant("(s)", "active-window-path"), new VariantType("((bgav))"),
                    DBusCallFlags.NO_AUTO_START, TIMEOUT_MS, null);
                var states = reply.get_child_value(0).get_child_value(2);
                if (states.n_children() > 0) {
                    var state = states.get_child_value(0).get_variant();
                    if (state.is_of_type(VariantType.STRING)) {
                        string path = state.get_string();
                        if (path != "" && Variant.is_object_path(path)) return path;
                    }
                }
            } catch (Error e) {
            }
            return null;
        }
    }
}
