using GLib;
using Singularity.Profiles;

namespace Singularity.ProfilesService {

    public class Engine : Object {
        public ProfileSet set { get; private set; }
        public string active_id { get; private set; default = ""; }
        public string reason { get; private set; default = ""; }
        public string detail { get; private set; default = ""; }
        public Facts facts { get; private set; default = new Facts(); }
        public string[] known_wifi { get; private set; default = {}; }

        public signal void status_changed();
        public signal void profiles_changed();
        public signal void announce(Profile profile, string text);

        private string _path;
        private string _session_path;
        private Gee.HashMap<string, AreaHandle> _areas = new Gee.HashMap<string, AreaHandle>();
        private Gee.HashMap<string, Gee.ArrayList<AreaHandle>> _candidates = new Gee.HashMap<string, Gee.ArrayList<AreaHandle>>();
        private Gee.HashMap<string, Gee.HashMap<string, string>> _before = new Gee.HashMap<string, Gee.HashMap<string, string>>();
        private Gee.HashMap<string, Gee.HashMap<string, string>> _applied = new Gee.HashMap<string, Gee.HashMap<string, string>>();
        private string _manual = "";
        private string _suppressed = "";
        private bool _busy = false;
        private bool _again = false;
        private uint _tick = 0;
        private Gee.HashSet<string> _pending_areas = new Gee.HashSet<string>();

        public Engine(string config_dir, string state_dir) {
            _path = Path.build_filename(config_dir, "profiles.json");
            _session_path = Path.build_filename(state_dir, "profiles-session.json");
            load();
            load_session();
            schedule_tick();
        }

        public Gee.Collection<AreaHandle> areas {
            owned get { return _areas.values; }
        }

        public AreaHandle? area(string id) {
            return _areas[id];
        }

        private void load() {
            string data;
            try {
                if (FileUtils.get_contents(_path, out data)) {
                    var parsed = ProfileSet.from_data(data);
                    if (parsed != null) {
                        set = parsed;
                        return;
                    }
                    FileUtils.set_contents(_path + ".unreadable", data);
                }
            } catch (Error e) {
            }
            set = ProfileSet.defaults();
            FocusMigration.merge(set, Path.build_filename(Path.get_dirname(_path), "focus-modes.json"));
            save();
        }

        public void save() {
            DirUtils.create_with_parents(Path.get_dirname(_path), 0700);
            try {
                FileUtils.set_contents_full(_path, set.to_data(), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("profiles: could not save: %s", e.message);
            }
        }

        private void load_session() {
            string data;
            try {
                if (!FileUtils.get_contents(_session_path, out data)) return;
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var o = root.get_object();
                if (o.has_member("active")) active_id = o.get_string_member("active");
                if (o.has_member("reason")) reason = o.get_string_member("reason");
                if (o.has_member("detail")) detail = o.get_string_member("detail");
                if (o.has_member("manual")) _manual = o.get_string_member("manual");
                if (o.has_member("manual-source")) _manual_source = o.get_string_member("manual-source");
                if (o.has_member("suppressed")) _suppressed = o.get_string_member("suppressed");
                read_table(o, "before", _before);
                read_table(o, "applied", _applied);
                if (set.find(active_id) == null) active_id = "";
            } catch (Error e) {
            }
        }

        private static void read_table(Json.Object o, string name, Gee.HashMap<string, Gee.HashMap<string, string>> table) {
            if (!o.has_member(name)) return;
            o.get_object_member(name).foreach_member((t, area, node) => {
                if (node.get_node_type() != Json.NodeType.OBJECT) return;
                var m = new Gee.HashMap<string, string>();
                node.get_object().foreach_member((ao, key, v) => m[key] = value_text(v));
                table[area] = m;
            });
        }

        private static void write_table(Json.Builder b, string name, Gee.HashMap<string, Gee.HashMap<string, string>> table) {
            b.set_member_name(name);
            b.begin_object();
            foreach (var area in table.entries) {
                b.set_member_name(area.key);
                b.begin_object();
                foreach (var kv in area.value.entries) {
                    b.set_member_name(kv.key);
                    b.add_value(parse_value(kv.value));
                }
                b.end_object();
            }
            b.end_object();
        }

        private void save_session() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("active"); b.add_string_value(active_id);
            b.set_member_name("reason"); b.add_string_value(reason);
            b.set_member_name("detail"); b.add_string_value(detail);
            b.set_member_name("manual"); b.add_string_value(_manual);
            b.set_member_name("manual-source"); b.add_string_value(_manual_source);
            b.set_member_name("suppressed"); b.add_string_value(_suppressed);
            write_table(b, "before", _before);
            write_table(b, "applied", _applied);
            b.end_object();
            DirUtils.create_with_parents(Path.get_dirname(_session_path), 0700);
            try {
                FileUtils.set_contents_full(_session_path, to_text(b.get_root(), false), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("profiles: could not save the session: %s", e.message);
            }
        }

        public void add_area(AreaHandle handle) {
            var list = _candidates[handle.id];
            if (list == null) {
                list = new Gee.ArrayList<AreaHandle>();
                _candidates[handle.id] = list;
            }
            for (int i = list.size - 1; i >= 0; i--) {
                if (list[i].owner == handle.owner && list[i].system_bus == handle.system_bus) list.remove_at(i);
            }
            list.add(handle);
            handle.changed.connect((keys) => {
                if (handle.id == Areas.STATE && _areas[Areas.STATE] == handle) refresh_facts.begin();
            });
            elect(handle.id);
        }

        private void elect(string id) {
            var list = _candidates[id];
            AreaHandle? best = null;
            if (list != null) {
                foreach (var h in list) {
                    if (best == null || h.rank > best.rank) best = h;
                }
            }
            if (best == _areas[id]) return;
            if (best == null) _areas.unset(id);
            else _areas[id] = best;
            if (id == Areas.STATE) refresh_facts.begin();
            _pending_areas.add(id);
            evaluate();
        }

        public void remove_area(string id, string owner, bool system_bus = false) {
            var list = _candidates[id];
            if (list == null) return;
            for (int i = list.size - 1; i >= 0; i--) {
                if (list[i].owner == owner && list[i].system_bus == system_bus) list.remove_at(i);
            }
            elect(id);
        }

        public void remove_owner(string owner, bool system_bus = false) {
            foreach (string id in _candidates.keys.to_array()) remove_area(id, owner, system_bus);
        }

        private async void refresh_facts() {
            var state = _areas[Areas.STATE];
            if (state == null) return;
            var s = yield state.snapshot({});
            var f = new Facts();
            f.wifi_ssid = text_of(s["wifi"]);
            f.screens = list_of(s["screens"]);
            f.devices = list_of(s["devices"]);
            f.fullscreen = bool_of(s["fullscreen"]);
            f.game = bool_of(s["game"]);
            f.presenting = bool_of(s["presenting"]);
            f.key_present = bool_of(s["key"]);
            f.key_owner = text_of(s["key-owner"]);
            f.on_battery = bool_of(s["on-battery"]);
            f.battery_percent = s["battery"] != null ? int.parse(s["battery"]) : 100;
            known_wifi = list_of(s["known-wifi"]);
            facts = f;
            evaluate();
        }

        private static string text_of(string? json) {
            if (json == null) return "";
            var n = parse_value(json);
            return n.get_value_type() == typeof(string) ? n.get_string() : "";
        }

        private static bool bool_of(string? json) {
            return json != null && json.strip() == "true";
        }

        private static string[] list_of(string? json) {
            string[] out_list = {};
            if (json == null) return out_list;
            var n = parse_value(json);
            if (n.get_node_type() != Json.NodeType.ARRAY) return out_list;
            n.get_array().foreach_element((a, i, e) => {
                if (e.get_value_type() == typeof(string)) out_list += e.get_string();
            });
            return out_list;
        }

        private void schedule_tick() {
            var now = new DateTime.now_local();
            uint wait = 60 - (uint) now.get_second();
            _tick = Timeout.add_seconds(wait == 0 ? 60 : wait, () => {
                _tick = 0;
                var f = facts;
                f.now = new DateTime.now_local();
                evaluate();
                schedule_tick();
                return Source.REMOVE;
            });
        }

        private string _manual_source = "";

        public static string source_text(string source) {
            switch (source) {
                case "menu": return _("Turned on from the system menu");
                case "shortcut": return _("Turned on with its keyboard shortcut");
                case "settings": return _("Turned on in Settings");
                case "agent": return _("Turned on by Sinty Agent");
            }
            return _("Turned on by hand");
        }

        public void activate(string id, string source = "") {
            if (set.find(id) == null) return;
            _manual = id;
            _manual_source = source;
            _suppressed = "";
            evaluate();
        }

        public void deactivate() {
            if (active_id != "" && reason != "manual") _suppressed = active_id;
            _manual = "";
            evaluate();
        }

        public void evaluate() {
            if (_busy) {
                _again = true;
                return;
            }
            run.begin();
        }

        private async void run() {
            _busy = true;
            do {
                _again = false;
                facts.now = new DateTime.now_local();
                if (_suppressed != "") {
                    var p = set.find(_suppressed);
                    if (p == null || p.matching_rule(facts) == null) _suppressed = "";
                }
                var sel = set.choose(_manual, _suppressed, facts);
                string next = sel.profile != null ? sel.profile.id : "";
                string next_reason = sel.profile == null ? "" : (sel.manual ? "manual" : "rule");
                string next_detail = sel.manual ? source_text(_manual_source) : (sel.rule != null ? describe_rule(sel.rule) : "");
                bool areas_arrived = _pending_areas.size > 0;
                _pending_areas.clear();
                if (next != active_id || areas_arrived) {
                    string previous = active_id;
                    yield transition(active_id != "" ? set.find(active_id) : null, sel.profile);
                    active_id = next;
                    reason = next_reason;
                    detail = next_detail;
                    save_session();
                    status_changed();
                    if (next != previous && sel.profile != null && sel.profile.announce) {
                        announce(sel.profile, next_detail);
                    }
                } else if (next_reason != reason || next_detail != detail) {
                    reason = next_reason;
                    detail = next_detail;
                    save_session();
                    status_changed();
                }
            } while (_again);
            _busy = false;
        }

        public async void reapply() {
            if (_busy) {
                _again = true;
                return;
            }
            _busy = true;
            var p = active_id != "" ? set.find(active_id) : null;
            yield transition(p, p);
            save_session();
            _busy = false;
            if (_again) evaluate();
        }

        private async void transition(Profile? old_profile, Profile? new_profile) {
            var touched = new Gee.TreeSet<string>();
            foreach (var a in _applied.keys) touched.add(a);
            if (new_profile != null) {
                foreach (string a in new_profile.areas()) touched.add(a);
            }
            foreach (string area_id in touched) {
                var handle = _areas[area_id];
                if (handle == null) continue;
                var wanted = new_profile != null ? new_profile.values_for(area_id) : new Gee.TreeMap<string, string>().read_only_view;
                var applied = _applied[area_id] ?? new Gee.HashMap<string, string>();
                var before = _before[area_id] ?? new Gee.HashMap<string, string>();

                string[] missing = {};
                foreach (var key in wanted.keys) {
                    var opt = handle.info.find(key);
                    if (opt == null || opt.read_only) continue;
                    if (!before.has_key(key)) missing += key;
                }
                if (missing.length > 0) {
                    var current = yield handle.snapshot(missing);
                    foreach (string key in missing) {
                        string? v = current[key];
                        if (v != null) before[key] = v;
                    }
                }

                string[] leaving = {};
                foreach (var key in applied.keys) {
                    if (!wanted.has_key(key)) leaving += key;
                }
                var restore = new HashTable<string, string>(str_hash, str_equal);
                if (leaving.length > 0) {
                    var current = yield handle.snapshot(leaving);
                    foreach (string key in leaving) {
                        string? original = before[key];
                        bool untouched = area_id == Areas.APPS || same_value(current[key], applied[key]);
                        if (original != null && untouched) restore[key] = original;
                        before.unset(key);
                        applied.unset(key);
                    }
                }
                yield handle.apply(restore);

                var values = new HashTable<string, string>(str_hash, str_equal);
                foreach (var e in wanted.entries) {
                    var opt = handle.info.find(e.key);
                    if (opt == null || opt.read_only || !before.has_key(e.key)) continue;
                    if (applied.has_key(e.key) && same_value(applied[e.key], e.value)) continue;
                    values[e.key] = e.value;
                    applied[e.key] = e.value;
                }
                yield handle.apply(values);

                if (applied.size > 0) _applied[area_id] = applied;
                else _applied.unset(area_id);
                if (before.size > 0) _before[area_id] = before;
                else _before.unset(area_id);
            }
        }

        public async Profile capture(string id) {
            var base_profile = set.find(id);
            Profile p = base_profile != null ? Profile.from_data(base_profile.to_data()) : new Profile(id, id, "focus-custom-symbolic");
            foreach (var handle in _areas.values) {
                if (handle.id == Areas.STATE) continue;
                if (handle.id == Areas.APPS) {
                    var running = yield handle.snapshot({ "running" });
                    if (running["running"] != null) p.set_value(Areas.APPS, "open", running["running"]);
                    continue;
                }
                string[] keys = {};
                foreach (var opt in handle.info.options) {
                    if (!opt.read_only) keys += opt.key;
                }
                if (keys.length == 0) continue;
                var snap = yield handle.snapshot(keys);
                foreach (string key in keys) {
                    string? v = snap[key];
                    if (v != null) p.set_value(handle.id, key, v);
                }
            }
            return p;
        }

        public string save_profile(Profile incoming) throws Error {
            if (incoming.name.strip() == "") throw new DBusError.INVALID_ARGS("A profile needs a name");
            if (incoming.id == "" || (set.find(incoming.id) == null && !incoming.id.has_prefix("custom"))) {
                incoming.id = set.unique_id(incoming.name);
            }
            var existing = set.find(incoming.id);
            if (existing != null) {
                incoming.builtin = existing.builtin;
                int index = set.profiles.index_of(existing);
                set.profiles[index] = incoming;
            } else {
                incoming.builtin = false;
                set.profiles.add(incoming);
            }
            save();
            profiles_changed();
            if (incoming.id == active_id) reapply.begin();
            else evaluate();
            return incoming.id;
        }

        public void delete_profile(string id) throws Error {
            var p = set.find(id);
            if (p == null) throw new DBusError.INVALID_ARGS("No profile named %s", id);
            if (p.builtin) throw new DBusError.ACCESS_DENIED("Built-in profiles can be changed but not removed");
            if (_manual == id) _manual = "";
            if (_suppressed == id) _suppressed = "";
            set.profiles.remove(p);
            save();
            profiles_changed();
            evaluate();
        }
    }
}
