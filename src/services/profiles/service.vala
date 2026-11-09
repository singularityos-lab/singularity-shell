using GLib;
using Singularity.Profiles;

namespace Singularity.ProfilesService {

    [DBus (name = "dev.sinty.Profiles1")]
    public class Service : Object {
        private Engine _engine;
        private DBusConnection? _conn = null;
        private Gee.HashMap<string, uint> _watches = new Gee.HashMap<string, uint>();
        private uint32 _last_notice = 0;

        public string active_profile { owned get { return _engine.active_id; } }
        public string reason { owned get { return _engine.reason; } }

        public signal void status_changed(HashTable<string, Variant> status);
        public signal void profiles_changed();

        public Service(Engine engine) {
            _engine = engine;
            _engine.status_changed.connect(() => {
                emit_properties();
                status_changed(build_status());
            });
            _engine.profiles_changed.connect(() => profiles_changed());
            _engine.announce.connect((p, text) => notify_activation.begin(p, text));
        }

        [DBus (visible = false)]
        public void attach(DBusConnection conn) {
            _conn = conn;
            conn.signal_subscribe("org.freedesktop.Notifications", "org.freedesktop.Notifications", "ActionInvoked",
                "/org/freedesktop/Notifications", null, DBusSignalFlags.NONE, (c, sender, path, iface, name, args) => {
                    uint32 id;
                    string action;
                    args.get("(us)", out id, out action);
                    if (id == _last_notice && action == "turn-off") _engine.deactivate();
                });
        }

        private HashTable<string, Variant> build_status() {
            var t = new HashTable<string, Variant>(str_hash, str_equal);
            t["active"] = new Variant.string(_engine.active_id);
            t["reason"] = new Variant.string(_engine.reason);
            t["detail"] = new Variant.string(_engine.detail);
            return t;
        }

        private void emit_properties() {
            if (_conn == null) return;
            var changed = new VariantBuilder(new VariantType("a{sv}"));
            changed.add("{sv}", "ActiveProfile", new Variant.string(_engine.active_id));
            changed.add("{sv}", "Reason", new Variant.string(_engine.reason));
            try {
                _conn.emit_signal(null, SERVICE_PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    new Variant.tuple({ new Variant.string("dev.sinty.Profiles1"), changed.end(), new Variant.array(VariantType.STRING, {}) }));
            } catch (Error e) {
                warning("profiles: PropertiesChanged failed: %s", e.message);
            }
        }

        private async void notify_activation(Profile p, string text) {
            if (_conn == null) return;
            var hints = new VariantBuilder(new VariantType("a{sv}"));
            hints.add("{sv}", "urgency", new Variant.byte(0));
            hints.add("{sv}", "transient", new Variant.boolean(true));
            hints.add("{sv}", "category", new Variant.string("x-sinty.profile"));
            hints.add("{sv}", "desktop-entry", new Variant.string("dev.sinty.settings"));
            string[] actions = { "turn-off", _("Turn Off") };
            try {
                var reply = yield _conn.call("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications", "Notify",
                    new Variant.tuple({ new Variant.string(_("Profiles")), new Variant.uint32(_last_notice),
                        new Variant.string(p.icon_name), new Variant.string(_("%s is on").printf(display_name(p))),
                        new Variant.string(text), new Variant.strv(actions), hints.end(), new Variant.int32(6000) }),
                    new VariantType("(u)"), DBusCallFlags.NONE, -1, null);
                reply.get("(u)", out _last_notice);
            } catch (Error e) {
                debug("profiles: could not notify: %s", e.message);
            }
        }

        public async string list_profiles() throws GLib.Error {
            return _engine.set.to_data();
        }

        public async string list_areas() throws GLib.Error {
            var b = new Json.Builder();
            b.begin_array();
            var ids = new Gee.TreeSet<string>();
            foreach (var h in _engine.areas) ids.add(h.id);
            foreach (string id in ids) {
                if (id == Areas.STATE) continue;
                var elected = _engine.area(id);
                var info = AreaInfo.from_data(elected.info.to_data()) ?? elected.info;
                foreach (var other in _engine.areas) {
                    if (other == elected || other.id != id || other.system_bus) continue;
                    info.label = other.info.label;
                    info.icon_name = other.info.icon_name;
                    foreach (var opt in info.options) {
                        var local = other.info.find(opt.key);
                        if (local == null) continue;
                        opt.label = local.label;
                        opt.subtitle = local.subtitle;
                        foreach (var c in opt.choices) {
                            string? l = local.label_for(string_value(c.value));
                            if (l != null && l != "") c.label = l;
                        }
                    }
                }
                info.build(b);
            }
            b.end_array();
            return to_text(b.get_root(), false);
        }

        public async string current_facts() throws GLib.Error {
            var f = _engine.facts;
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("wifi"); b.add_string_value(f.wifi_ssid);
            b.set_member_name("known-wifi"); b.begin_array();
            foreach (string s in _engine.known_wifi) b.add_string_value(s);
            b.end_array();
            b.set_member_name("screens"); b.begin_array();
            foreach (string s in f.screens) b.add_string_value(s);
            b.end_array();
            b.set_member_name("devices"); b.begin_array();
            foreach (string s in f.devices) b.add_string_value(s);
            b.end_array();
            b.set_member_name("key-owner"); b.add_string_value(f.key_owner);
            b.end_object();
            return to_text(b.get_root(), false);
        }

        public async string save_profile(string data) throws GLib.Error {
            var p = Profile.from_data(data);
            if (p == null) throw new DBusError.INVALID_ARGS("Unreadable profile");
            return _engine.save_profile(p);
        }

        public async void delete_profile(string id) throws GLib.Error {
            _engine.delete_profile(id);
        }

        public async string capture_current(string id) throws GLib.Error {
            var p = yield _engine.capture(id);
            return p.to_data();
        }

        public async void activate(string id) throws GLib.Error {
            if (_engine.set.find(id) == null) throw new DBusError.INVALID_ARGS("No profile named %s", id);
            _engine.activate(id);
        }

        public async void activate_from(string id, string source) throws GLib.Error {
            if (_engine.set.find(id) == null) throw new DBusError.INVALID_ARGS("No profile named %s", id);
            _engine.activate(id, source);
        }

        public async void deactivate() throws GLib.Error {
            _engine.deactivate();
        }

        public async HashTable<string, Variant> status() throws GLib.Error {
            return build_status();
        }

        public async void register_area(string id, ObjectPath path, BusName sender) throws GLib.Error {
            if (id.strip() == "") throw new DBusError.INVALID_ARGS("An area needs an id");
            var handle = yield AreaHandle.connect_remote(id, BusType.SESSION, sender, path, sender, 1);
            if (handle == null) throw new DBusError.FAILED("The area %s does not answer", id);
            _engine.add_area(handle);
            if (!_watches.has_key(sender)) {
                string owner = sender;
                _watches[owner] = Bus.watch_name(BusType.SESSION, owner, BusNameWatcherFlags.NONE, null, () => {
                    _engine.remove_owner(owner);
                    Bus.unwatch_name(_watches[owner]);
                    _watches.unset(owner);
                });
            }
        }

        public async void unregister_area(string id, BusName sender) throws GLib.Error {
            _engine.remove_area(id, sender);
        }
    }
}
