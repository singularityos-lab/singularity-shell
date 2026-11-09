using GLib;
using Singularity.Profiles;

namespace Singularity.ProfilesService {

    public class FocusMigration : Object {
        public static void merge(ProfileSet set, string focus_path) {
            string data;
            if (!FileUtils.test(focus_path, FileTest.EXISTS)) return;
            try {
                if (!FileUtils.get_contents(focus_path, out data)) return;
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var obj = root.get_object();
                if (!obj.has_member("modes")) return;
                obj.get_array_member("modes").foreach_element((a, i, n) => {
                    if (n.get_node_type() == Json.NodeType.OBJECT) take(set, n.get_object());
                });
            } catch (Error e) {
                warning("profiles: could not read Focus modes: %s", e.message);
            }
        }

        private static void take(ProfileSet set, Json.Object mode) {
            string id = mode.has_member("id") ? mode.get_string_member("id") : "";
            if (id == "" || id == "do-not-disturb") return;
            Profile? target = null;
            if (id == "work" || id == "sleep") target = set.find(id);
            if (target == null) {
                string name = mode.has_member("name") ? mode.get_string_member("name") : id;
                if (id == "personal") name = _("Personal");
                target = new Profile(set.unique_id(name), name,
                    mode.has_member("icon") ? mode.get_string_member("icon") : "focus-custom-symbolic");
                set.profiles.add(target);
            }
            target.set_value(Areas.NOTIFICATIONS, "rules", rules_from(mode));
            if (mode.has_member("schedules")) {
                bool replaced = false;
                mode.get_array_member("schedules").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var s = n.get_object();
                    if (!replaced) {
                        target.rules.clear();
                        replaced = true;
                    }
                    var c = new Condition(ConditionKind.TIME);
                    if (s.has_member("days")) c.days = (int) s.get_int_member("days") & Condition.ALL_DAYS;
                    if (s.has_member("start")) c.start_minute = Condition.parse_minute(s.get_string_member("start"), c.start_minute);
                    if (s.has_member("end")) c.end_minute = Condition.parse_minute(s.get_string_member("end"), c.end_minute);
                    var r = new Rule();
                    r.enabled = !s.has_member("enabled") || s.get_boolean_member("enabled");
                    r.conditions.add(c);
                    target.rules.add(r);
                });
            }
            if (mode.has_member("while-presenting") && mode.get_boolean_member("while-presenting")) {
                var r = new Rule();
                r.conditions.add(new Condition(ConditionKind.PRESENTING));
                target.rules.add(r);
            }
            if (mode.has_member("while-fullscreen") && mode.get_boolean_member("while-fullscreen")) {
                var r = new Rule();
                r.conditions.add(new Condition(ConditionKind.FULLSCREEN));
                target.rules.add(r);
            }
        }

        private static string rules_from(Json.Object mode) {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("silence"); b.add_boolean_value(true);
            b.set_member_name("allow-time-sensitive");
            b.add_boolean_value(!mode.has_member("allow-time-sensitive") || mode.get_boolean_member("allow-time-sensitive"));
            b.set_member_name("allow-repeated-calls"); b.add_boolean_value(true);
            b.set_member_name("show-badges"); b.add_boolean_value(true);
            b.set_member_name("mute-sounds"); b.add_boolean_value(false);
            b.set_member_name("apps");
            if (mode.has_member("apps")) b.add_value(mode.get_member("apps").copy());
            else { b.begin_array(); b.end_array(); }
            b.set_member_name("people");
            if (mode.has_member("people")) b.add_value(mode.get_member("people").copy());
            else { b.begin_array(); b.end_array(); }
            b.end_object();
            return to_text(b.get_root(), false);
        }
    }
}
