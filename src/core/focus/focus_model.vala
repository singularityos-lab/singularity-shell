using GLib;

namespace Singularity {

    public class FocusSchedule : Object {
        public const int ALL_DAYS = 0x7f;
        public const int WEEKDAYS = 0x1f;

        public int days { get; set; default = ALL_DAYS; }
        public int start_minute { get; set; default = 22 * 60; }
        public int end_minute { get; set; default = 7 * 60; }
        public bool enabled { get; set; default = true; }

        public FocusSchedule(int days, int start_minute, int end_minute, bool enabled = true) {
            this.days = days;
            this.start_minute = start_minute.clamp(0, 24 * 60 - 1);
            this.end_minute = end_minute.clamp(0, 24 * 60 - 1);
            this.enabled = enabled;
        }

        public bool has_day(int day_of_week) {
            return (days & (1 << (day_of_week - 1))) != 0;
        }

        public bool covers(DateTime time) {
            if (!enabled || days == 0) return false;
            int minute = time.get_hour() * 60 + time.get_minute();
            int today = time.get_day_of_week();
            if (start_minute == end_minute) return has_day(today);
            if (start_minute < end_minute) {
                return has_day(today) && minute >= start_minute && minute < end_minute;
            }
            if (minute >= start_minute) return has_day(today);
            int yesterday = today == 1 ? 7 : today - 1;
            return minute < end_minute && has_day(yesterday);
        }

        public static string format_minute(int minute) {
            return "%02d:%02d".printf(minute / 60, minute % 60);
        }

        public static int parse_minute(string text, int fallback) {
            string[] parts = text.strip().split(":");
            if (parts.length != 2) return fallback;
            int h = int.parse(parts[0]);
            int m = int.parse(parts[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return fallback;
            return h * 60 + m;
        }

        public Json.Node to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("days"); b.add_int_value(days);
            b.set_member_name("start"); b.add_string_value(format_minute(start_minute));
            b.set_member_name("end"); b.add_string_value(format_minute(end_minute));
            b.set_member_name("enabled"); b.add_boolean_value(enabled);
            b.end_object();
            return b.get_root();
        }

        public static FocusSchedule from_json(Json.Object o) {
            int days = o.has_member("days") ? (int) o.get_int_member("days") : ALL_DAYS;
            int start = parse_minute(o.has_member("start") ? o.get_string_member("start") : "", 22 * 60);
            int end = parse_minute(o.has_member("end") ? o.get_string_member("end") : "", 7 * 60);
            bool enabled = o.has_member("enabled") ? o.get_boolean_member("enabled") : true;
            return new FocusSchedule(days & ALL_DAYS, start, end, enabled);
        }
    }

    public class FocusPerson : Object {
        public string name { get; set; default = ""; }
        public string[] handles { get; set; default = {}; }

        public FocusPerson(string name, string[] handles = {}) {
            this.name = name;
            this.handles = handles;
        }

        public bool matches(string summary, string body) {
            string haystack = (summary + "\n" + body).down();
            string n = name.strip().down();
            if (n.length >= 2 && haystack.contains(n)) return true;
            foreach (string h in handles) {
                string handle = h.strip().down();
                if (handle.length >= 3 && haystack.contains(handle)) return true;
            }
            return false;
        }
    }

    public class FocusMode : Object {
        public const string DO_NOT_DISTURB = "do-not-disturb";

        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string icon_name { get; set; default = "notifications-disabled-symbolic"; }
        public bool builtin { get; set; default = false; }
        public bool allow_time_sensitive { get; set; default = true; }
        public bool while_presenting { get; set; default = false; }
        public bool while_fullscreen { get; set; default = false; }
        public Gee.ArrayList<string> allowed_apps { get; private set; default = new Gee.ArrayList<string>(); }
        public Gee.ArrayList<FocusPerson> allowed_people { get; private set; default = new Gee.ArrayList<FocusPerson>(); }
        public Gee.ArrayList<FocusSchedule> schedules { get; private set; default = new Gee.ArrayList<FocusSchedule>(); }

        public FocusMode(string id, string name, string icon_name, bool builtin = false) {
            this.id = id;
            this.name = name;
            this.icon_name = icon_name;
            this.builtin = builtin;
        }

        public bool allows_app(string app_key) {
            foreach (string a in allowed_apps) {
                if (a == app_key) return true;
            }
            return false;
        }

        public bool allows_sender(string summary, string body) {
            foreach (var p in allowed_people) {
                if (p.matches(summary, body)) return true;
            }
            return false;
        }

        public bool scheduled_at(DateTime time) {
            foreach (var s in schedules) {
                if (s.covers(time)) return true;
            }
            return false;
        }

        public Json.Node to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("id"); b.add_string_value(id);
            b.set_member_name("name"); b.add_string_value(name);
            b.set_member_name("icon"); b.add_string_value(icon_name);
            b.set_member_name("builtin"); b.add_boolean_value(builtin);
            b.set_member_name("allow-time-sensitive"); b.add_boolean_value(allow_time_sensitive);
            b.set_member_name("while-presenting"); b.add_boolean_value(while_presenting);
            b.set_member_name("while-fullscreen"); b.add_boolean_value(while_fullscreen);
            b.set_member_name("apps");
            b.begin_array();
            foreach (string a in allowed_apps) b.add_string_value(a);
            b.end_array();
            b.set_member_name("people");
            b.begin_array();
            foreach (var p in allowed_people) {
                b.begin_object();
                b.set_member_name("name"); b.add_string_value(p.name);
                b.set_member_name("handles");
                b.begin_array();
                foreach (string h in p.handles) b.add_string_value(h);
                b.end_array();
                b.end_object();
            }
            b.end_array();
            b.set_member_name("schedules");
            b.begin_array();
            foreach (var s in schedules) b.add_value(s.to_json());
            b.end_array();
            b.end_object();
            return b.get_root();
        }

        public static FocusMode? from_json(Json.Object o) {
            if (!o.has_member("id")) return null;
            string id = o.get_string_member("id");
            if (id == "") return null;
            var mode = new FocusMode(id,
                o.has_member("name") ? o.get_string_member("name") : id,
                o.has_member("icon") ? o.get_string_member("icon") : "notifications-disabled-symbolic",
                o.has_member("builtin") && o.get_boolean_member("builtin"));
            if (o.has_member("allow-time-sensitive")) mode.allow_time_sensitive = o.get_boolean_member("allow-time-sensitive");
            if (o.has_member("while-presenting")) mode.while_presenting = o.get_boolean_member("while-presenting");
            if (o.has_member("while-fullscreen")) mode.while_fullscreen = o.get_boolean_member("while-fullscreen");
            if (o.has_member("apps")) {
                o.get_array_member("apps").foreach_element((a, i, n) => {
                    if (n.get_value_type() == typeof(string)) mode.allowed_apps.add(n.get_string());
                });
            }
            if (o.has_member("people")) {
                o.get_array_member("people").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var po = n.get_object();
                    string[] handles = {};
                    if (po.has_member("handles")) {
                        po.get_array_member("handles").foreach_element((ha, hi, hn) => {
                            handles += hn.get_string();
                        });
                    }
                    mode.allowed_people.add(new FocusPerson(po.has_member("name") ? po.get_string_member("name") : "", handles));
                });
            }
            if (o.has_member("schedules")) {
                o.get_array_member("schedules").foreach_element((a, i, n) => {
                    if (n.get_node_type() == Json.NodeType.OBJECT) mode.schedules.add(FocusSchedule.from_json(n.get_object()));
                });
            }
            return mode;
        }
    }

    public enum FocusReason {
        NONE,
        MANUAL,
        SCHEDULE,
        PRESENTING,
        FULLSCREEN;

        public string to_id() {
            switch (this) {
                case MANUAL: return "manual";
                case SCHEDULE: return "schedule";
                case PRESENTING: return "presenting";
                case FULLSCREEN: return "fullscreen";
                default: return "";
            }
        }
    }

    public class FocusState : Object {
        public FocusMode? mode { get; construct; }
        public FocusReason reason { get; construct; }

        public FocusState(FocusMode? mode, FocusReason reason) {
            Object(mode: mode, reason: mode == null ? FocusReason.NONE : reason);
        }

        public bool active { get { return mode != null; } }
    }

    public class FocusModeSet : Object {
        public Gee.ArrayList<FocusMode> modes { get; private set; default = new Gee.ArrayList<FocusMode>(); }

        public static FocusModeSet defaults() {
            var set = new FocusModeSet();
            var dnd = new FocusMode(FocusMode.DO_NOT_DISTURB, "Do Not Disturb", "notifications-disabled-symbolic", true);
            dnd.allow_time_sensitive = false;
            set.modes.add(dnd);
            var work = new FocusMode("work", "Work", "focus-work-symbolic", true);
            work.while_presenting = true;
            set.modes.add(work);
            var sleep = new FocusMode("sleep", "Sleep", "focus-sleep-symbolic", true);
            sleep.schedules.add(new FocusSchedule(FocusSchedule.ALL_DAYS, 23 * 60, 7 * 60, false));
            set.modes.add(sleep);
            set.modes.add(new FocusMode("personal", "Personal", "focus-personal-symbolic", true));
            return set;
        }

        public FocusMode? find(string id) {
            foreach (var m in modes) {
                if (m.id == id) return m;
            }
            return null;
        }

        public string unique_id(string name) {
            string base_id = "custom";
            var sb = new StringBuilder();
            foreach (char c in name.down().to_utf8()) {
                if (c.isalnum()) sb.append_c(c);
                else if (sb.len > 0 && sb.str[sb.len - 1] != '-') sb.append_c('-');
            }
            string slug = sb.str.strip();
            while (slug.has_suffix("-")) slug = slug.substring(0, slug.length - 1);
            if (slug != "") base_id = "custom-" + slug;
            string candidate = base_id;
            int n = 2;
            while (find(candidate) != null) candidate = "%s-%d".printf(base_id, n++);
            return candidate;
        }

        public FocusState evaluate(string manual_id, DateTime now, bool presenting, bool fullscreen) {
            if (manual_id != "") {
                var manual = find(manual_id);
                if (manual != null) return new FocusState(manual, FocusReason.MANUAL);
            }
            foreach (var m in modes) {
                if (m.scheduled_at(now)) return new FocusState(m, FocusReason.SCHEDULE);
            }
            if (presenting) {
                foreach (var m in modes) {
                    if (m.while_presenting) return new FocusState(m, FocusReason.PRESENTING);
                }
            }
            if (fullscreen) {
                foreach (var m in modes) {
                    if (m.while_fullscreen) return new FocusState(m, FocusReason.FULLSCREEN);
                }
            }
            return new FocusState(null, FocusReason.NONE);
        }

        public string to_data() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version"); b.add_int_value(1);
            b.set_member_name("modes");
            b.begin_array();
            foreach (var m in modes) b.add_value(m.to_json());
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        public static FocusModeSet from_data(string data) {
            var set = new FocusModeSet();
            try {
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return defaults();
                var obj = root.get_object();
                if (!obj.has_member("modes")) return defaults();
                obj.get_array_member("modes").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var m = FocusMode.from_json(n.get_object());
                    if (m != null && set.find(m.id) == null) set.modes.add(m);
                });
            } catch (Error e) {
                return defaults();
            }
            if (set.find(FocusMode.DO_NOT_DISTURB) == null) {
                set.modes.insert(0, defaults().find(FocusMode.DO_NOT_DISTURB));
            }
            return set;
        }
    }
}
