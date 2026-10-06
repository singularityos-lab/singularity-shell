using GLib;

namespace Singularity {

    public class FocusManager : Object {
        private static FocusManager? _instance = null;

        public FocusModeSet modes { get; private set; }
        public FocusState state { get; private set; default = new FocusState(null, FocusReason.NONE); }
        public bool presenting { get { return _presenters.size > 0; } }
        public bool fullscreen { get; private set; default = false; }
        public int64 until { get; private set; default = 0; }

        public signal void changed();
        public signal void modes_changed();

        private GLib.Settings _desktop;
        private GLib.Settings? _notif;
        private string _path;
        private Gee.HashMap<uint, string> _presenters = new Gee.HashMap<uint, string>();
        private Gee.HashMap<string, uint> _watches = new Gee.HashMap<string, uint>();
        private uint _next_cookie = 1;
        private uint _tick_id = 0;
        private string _suppressed = "";
        private FileMonitor? _monitor = null;
        private bool _saving = false;

        public static FocusManager get_default() {
            if (_instance == null) _instance = new FocusManager();
            return _instance;
        }

        public static string default_path() {
            return Path.build_filename(Environment.get_user_config_dir(), "singularity", "focus-modes.json");
        }

        private FocusManager() {
            _path = default_path();
            _desktop = new GLib.Settings("dev.sinty.desktop");
            var notif = AppNotificationSettings.get_default();
            _notif = notif.available ? notif.settings : null;
            load_modes();
            _desktop.changed["do-not-disturb"].connect(() => evaluate());
            if (_notif != null) {
                _notif.changed["focus-mode"].connect(() => evaluate());
                _notif.changed["focus-until"].connect(() => evaluate());
            }
            AppSystem.get_default().any_fullscreen_changed.connect(update_fullscreen);
            GameModeManager.get_default().state_changed.connect(update_fullscreen);
            update_fullscreen();
            try {
                _monitor = File.new_for_path(_path).monitor_file(FileMonitorFlags.NONE);
                _monitor.changed.connect((f, o, ev) => {
                    if (_saving) return;
                    if (ev == FileMonitorEvent.CHANGES_DONE_HINT || ev == FileMonitorEvent.CREATED) {
                        load_modes();
                        evaluate();
                        modes_changed();
                    }
                });
            } catch (Error e) {
            }
            schedule_tick();
            evaluate();
        }

        private void load_modes() {
            string data;
            try {
                if (FileUtils.get_contents(_path, out data)) {
                    modes = FocusModeSet.from_data(data);
                    return;
                }
            } catch (Error e) {
            }
            modes = FocusModeSet.defaults();
        }

        public void save_modes() {
            _saving = true;
            DirUtils.create_with_parents(Path.get_dirname(_path), 0700);
            try {
                FileUtils.set_contents_full(_path, modes.to_data(), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("focus: could not save modes: %s", e.message);
            }
            Timeout.add(500, () => {
                _saving = false;
                return Source.REMOVE;
            });
            evaluate();
            modes_changed();
        }

        public FocusMode add_mode(string name, string icon_name) {
            var mode = new FocusMode(modes.unique_id(name), name, icon_name);
            modes.modes.add(mode);
            save_modes();
            return mode;
        }

        public void remove_mode(string id) {
            var mode = modes.find(id);
            if (mode == null || mode.builtin) return;
            modes.modes.remove(mode);
            if (_notif != null && _notif.get_string("focus-mode") == id) {
                _notif.set_string("focus-mode", FocusMode.DO_NOT_DISTURB);
            }
            save_modes();
        }

        public static string display_name(FocusMode mode) {
            if (!mode.builtin) return mode.name;
            switch (mode.id) {
                case FocusMode.DO_NOT_DISTURB: return _("Do Not Disturb");
                case "work": return _("Work");
                case "sleep": return _("Sleep");
                case "personal": return _("Personal");
            }
            return mode.name;
        }

        public static string reason_label(FocusReason reason) {
            switch (reason) {
                case FocusReason.SCHEDULE: return _("On a schedule");
                case FocusReason.PRESENTING: return _("While presenting or sharing the screen");
                case FocusReason.FULLSCREEN: return _("While a full-screen app or game runs");
                case FocusReason.MANUAL: return _("On");
                default: return _("Off");
            }
        }

        public string manual_mode_id {
            owned get { return _notif != null ? _notif.get_string("focus-mode") : FocusMode.DO_NOT_DISTURB; }
        }

        public void activate(string id, uint minutes = 0) {
            if (modes.find(id) == null) return;
            _suppressed = "";
            if (_notif != null) {
                _notif.set_string("focus-mode", id);
                _notif.set_int64("focus-until", minutes > 0 ? get_real_time() / 1000000 + minutes * 60 : 0);
            }
            _desktop.set_boolean("do-not-disturb", true);
            evaluate();
        }

        public void deactivate() {
            if (state.active && state.reason != FocusReason.MANUAL) _suppressed = state.mode.id;
            _desktop.set_boolean("do-not-disturb", false);
            if (_notif != null) _notif.set_int64("focus-until", 0);
            evaluate();
        }

        public void toggle() {
            if (state.active) deactivate();
            else activate(manual_mode_id);
        }

        public uint begin_presenting(string sender, string reason) {
            uint cookie = _next_cookie++;
            _presenters[cookie] = sender;
            if (sender != "" && !_watches.has_key(sender)) {
                _watches[sender] = Bus.watch_name(BusType.SESSION, sender, BusNameWatcherFlags.NONE, null, (c, name) => {
                    drop_sender(name);
                });
            }
            debug("focus: presenting started by %s (%s)", sender, reason);
            evaluate();
            return cookie;
        }

        public void end_presenting(uint cookie) {
            if (!_presenters.has_key(cookie)) return;
            _presenters.unset(cookie);
            evaluate();
        }

        private void drop_sender(string sender) {
            var gone = new Gee.ArrayList<uint>();
            foreach (var e in _presenters.entries) {
                if (e.value == sender) gone.add(e.key);
            }
            foreach (uint c in gone) _presenters.unset(c);
            if (_watches.has_key(sender)) {
                Bus.unwatch_name(_watches[sender]);
                _watches.unset(sender);
            }
            evaluate();
        }

        private void update_fullscreen() {
            bool fs = AppSystem.get_default().has_any_fullscreen_window() || GameModeManager.get_default().active;
            if (fs == fullscreen) return;
            fullscreen = fs;
            evaluate();
        }

        private void schedule_tick() {
            if (_tick_id != 0) Source.remove(_tick_id);
            var now = new DateTime.now_local();
            uint wait = 60 - (uint) now.get_second();
            _tick_id = Timeout.add_seconds(wait == 0 ? 60 : wait, () => {
                _tick_id = 0;
                evaluate();
                schedule_tick();
                return Source.REMOVE;
            });
        }

        public void evaluate() {
            string manual = "";
            int64 end = _notif != null ? _notif.get_int64("focus-until") : 0;
            if (_desktop.get_boolean("do-not-disturb")) {
                if (end > 0 && get_real_time() / 1000000 >= end) {
                    _notif.set_int64("focus-until", 0);
                    _desktop.set_boolean("do-not-disturb", false);
                    return;
                }
                manual = manual_mode_id;
                if (modes.find(manual) == null) manual = FocusMode.DO_NOT_DISTURB;
            }
            var raw = modes.evaluate(manual, new DateTime.now_local(), presenting, fullscreen);
            FocusState next = raw;
            if (_suppressed != "") {
                if (raw.active && raw.reason != FocusReason.MANUAL && raw.mode.id == _suppressed) {
                    next = new FocusState(null, FocusReason.NONE);
                } else if (!raw.active || raw.mode.id != _suppressed) {
                    _suppressed = "";
                }
            }
            int64 new_until = next.reason == FocusReason.MANUAL ? end : 0;
            string old_id = state.active ? state.mode.id : "";
            string new_id = next.active ? next.mode.id : "";
            bool differs = old_id != new_id || state.reason != next.reason || until != new_until;
            if (next.active && state.active && next.mode != state.mode) differs = true;
            state = next;
            until = new_until;
            if (differs) {
                debug("focus: %s (%s)", new_id == "" ? "off" : new_id, next.reason.to_id());
                changed();
            }
        }
    }

    [DBus (name = "dev.sinty.Focus1")]
    public class FocusService : Object {
        private FocusManager _manager;

        public bool active { get { return _manager.state.active; } }
        public string mode_id { owned get { return _manager.state.active ? _manager.state.mode.id : ""; } }
        public string mode_name { owned get { return _manager.state.active ? FocusManager.display_name(_manager.state.mode) : ""; } }
        public string icon_name { owned get { return _manager.state.active ? _manager.state.mode.icon_name : ""; } }
        public string reason { owned get { return _manager.state.reason.to_id(); } }
        public int64 until { get { return _manager.until; } }

        public signal void status_changed(HashTable<string, Variant> status);

        public FocusService(FocusManager manager) {
            _manager = manager;
            _manager.changed.connect(() => {
                HashTable<string, Variant> status;
                try {
                    status = get_status();
                } catch (GLib.Error e) {
                    return;
                }
                emit_properties_changed();
                status_changed(status);
            });
        }

        [DBus (visible = false)]
        public DBusConnection? connection { get; set; default = null; }

        private void emit_properties_changed() {
            if (connection == null) return;
            var changed = new VariantBuilder(new VariantType("a{sv}"));
            changed.add("{sv}", "Active", new Variant.boolean(active));
            changed.add("{sv}", "ModeId", new Variant.string(mode_id));
            changed.add("{sv}", "ModeName", new Variant.string(mode_name));
            changed.add("{sv}", "IconName", new Variant.string(icon_name));
            changed.add("{sv}", "Reason", new Variant.string(reason));
            changed.add("{sv}", "Until", new Variant.int64(until));
            try {
                connection.emit_signal(null, "/dev/sinty/Focus", "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    new Variant("(sa{sv}as)", "dev.sinty.Focus1", changed, new VariantBuilder(new VariantType("as"))));
            } catch (GLib.Error e) {
                warning("focus: could not emit PropertiesChanged: %s", e.message);
            }
        }

        public HashTable<string, Variant> get_status() throws GLib.Error {
            var t = new HashTable<string, Variant>(str_hash, str_equal);
            t["active"] = new Variant.boolean(active);
            t["mode-id"] = new Variant.string(mode_id);
            t["mode-name"] = new Variant.string(mode_name);
            t["icon-name"] = new Variant.string(icon_name);
            t["reason"] = new Variant.string(reason);
            t["until"] = new Variant.int64(until);
            return t;
        }

        public void list_modes(out string[] ids, out string[] names, out string[] icons) throws GLib.Error {
            string[] i = {};
            string[] n = {};
            string[] c = {};
            foreach (var m in _manager.modes.modes) {
                i += m.id;
                n += FocusManager.display_name(m);
                c += m.icon_name;
            }
            ids = i;
            names = n;
            icons = c;
        }

        public void activate(string mode_id, uint minutes) throws GLib.Error {
            if (_manager.modes.find(mode_id) == null) {
                throw new DBusError.INVALID_ARGS("No Focus mode named %s", mode_id);
            }
            _manager.activate(mode_id, minutes);
        }

        public void deactivate() throws GLib.Error {
            _manager.deactivate();
        }

        public uint begin_presenting(string reason, GLib.BusName sender) throws GLib.Error {
            return _manager.begin_presenting(sender, reason);
        }

        public void end_presenting(uint cookie) throws GLib.Error {
            _manager.end_presenting(cookie);
        }

        public static void export() {
            var service = new FocusService(FocusManager.get_default());
            Bus.own_name(BusType.SESSION, "dev.sinty.Focus", BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        conn.register_object("/dev/sinty/Focus", service);
                        service.connection = conn;
                    } catch (IOError e) {
                        warning("focus: could not export dev.sinty.Focus1: %s", e.message);
                    }
                },
                () => {},
                () => { warning("focus: lost name dev.sinty.Focus"); });
        }
    }
}
