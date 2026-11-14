namespace Singularity {

    public class AegisAlert : Object {
        public string id = "";
        public string kind = "other";
        public string severity = "minor";
        public string headline = "";
        public string description = "";
        public string instruction = "";
        public string area = "";
        public string source = "";
        public string link = "";
        public int64 sent = 0;
        public int64 raised = 0;
        public int64 dismissable_at = 0;
        public bool test = false;
        public bool danger = false;

        public string icon_name {
            owned get { return "aegis-%s-symbolic".printf(kind); }
        }

        public int64 seconds_held() {
            int64 left = dismissable_at - (GLib.get_real_time() / 1000000);
            return left > 0 ? left : 0;
        }
    }

    [DBus (name = "dev.sinty.Aegis1")]
    private interface AegisBus : Object {
        public abstract async string alerts() throws Error;
        public abstract async void dismiss(string id) throws Error;
        public abstract async string test(string kind) throws Error;
        public abstract async string config() throws Error;
        public abstract async void set_config(string doc) throws Error;
        public abstract async string[] areas() throws Error;
        public abstract async string sos() throws Error;
        public abstract async void call(string number) throws Error;
        public signal void changed();
    }

    public class AegisClient : Object {
        private static AegisClient? instance = null;
        private AegisBus? bus = null;
        private Gee.ArrayList<AegisAlert> list = new Gee.ArrayList<AegisAlert>();
        private Gee.HashSet<string> known = new Gee.HashSet<string>();

        public signal void changed();
        public signal void raised(AegisAlert alert);
        public signal void open_requested();

        public Gee.List<AegisAlert> alerts {
            owned get { return list.read_only_view; }
        }

        public AegisAlert? top {
            owned get { return list.size > 0 ? list[0] : null; }
        }

        public bool available {
            get { return bus != null; }
        }

        public static AegisClient get_default() {
            if (instance == null) instance = new AegisClient();
            return instance;
        }

        private AegisClient() {
            connect_bus.begin();
        }

        private async void connect_bus() {
            try {
                bus = yield Bus.get_proxy<AegisBus>(BusType.SESSION, "dev.sinty.Aegis1", "/dev/sinty/Aegis1");
                bus.changed.connect(() => refresh.begin());
                ((DBusProxy) bus).notify["g-name-owner"].connect(() => refresh.begin());
                yield refresh();
            } catch (Error e) {
                bus = null;
            }
        }

        private static string text(Json.Object o, string key) {
            return o.has_member(key) ? o.get_string_member(key) : "";
        }

        public async void refresh() {
            if (bus == null) return;
            var next = new Gee.ArrayList<AegisAlert>();
            try {
                var parser = new Json.Parser();
                parser.load_from_data(yield bus.alerts());
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                    foreach (var node in root.get_array().get_elements()) {
                        var o = node.get_object();
                        var a = new AegisAlert();
                        a.id = text(o, "id");
                        a.kind = text(o, "kind");
                        a.severity = text(o, "severity");
                        a.headline = text(o, "headline");
                        a.description = text(o, "description");
                        a.instruction = text(o, "instruction");
                        a.area = text(o, "area");
                        a.source = text(o, "source");
                        a.link = text(o, "link");
                        a.sent = o.get_int_member("sent");
                        a.raised = o.get_int_member("raised");
                        a.dismissable_at = o.get_int_member("dismissable_at");
                        a.test = o.get_boolean_member("test");
                        a.danger = o.has_member("danger") && o.get_boolean_member("danger");
                        next.add(a);
                    }
                }
            } catch (Error e) {
                next.clear();
            }
            list = next;
            var seen = new Gee.HashSet<string>();
            AegisAlert? fresh = null;
            foreach (var a in list) {
                seen.add(a.id);
                if (!known.contains(a.id) && fresh == null) fresh = a;
            }
            known = seen;
            changed();
            if (fresh != null) raised(fresh);
        }

        public async bool dismiss(string id) {
            if (bus == null) return false;
            try {
                yield bus.dismiss(id);
                return true;
            } catch (Error e) {
                return false;
            }
        }

        public async void test(string kind) {
            if (bus == null) return;
            try {
                yield bus.test(kind);
            } catch (Error e) {
            }
        }

        public async string config() {
            if (bus == null) return "{}";
            try {
                return yield bus.config();
            } catch (Error e) {
                return "{}";
            }
        }

        public async bool set_config(string doc) {
            if (bus == null) return false;
            try {
                yield bus.set_config(doc);
                return true;
            } catch (Error e) {
                return false;
            }
        }

        public async string[] areas() {
            if (bus == null) return {};
            try {
                return yield bus.areas();
            } catch (Error e) {
                return {};
            }
        }

        public async string sos() {
            if (bus == null) return "{}";
            try {
                return yield bus.sos();
            } catch (Error e) {
                return "{}";
            }
        }

        public async string? call(string number) {
            if (bus == null) return _("Sinty Aegis is not running");
            try {
                yield bus.call(number);
                return null;
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                return e.message;
            }
        }

        public static bool alarm() {
            string[]? player = NotificationSound.player_command("");
            if (player == null) return false;
            var files = new Gee.ArrayList<string>();
            files.add(Path.build_filename(Environment.get_user_data_dir(), "singularity", "sounds", "aegis-alert.wav"));
            foreach (string d in Environment.get_system_data_dirs()) files.add(Path.build_filename(d, "singularity", "sounds", "aegis-alert.wav"));
            foreach (string file in files) {
                if (!FileUtils.test(file, FileTest.IS_REGULAR)) continue;
                string[] argv = player;
                argv += file;
                try {
                    Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL, null, null);
                    return true;
                } catch (SpawnError e) {
                    return false;
                }
            }
            return false;
        }

        public static string kind_label(string kind) {
            switch (kind) {
                case "earthquake": return _("Earthquake");
                case "tsunami": return _("Tsunami");
                case "flood": return _("Flood");
                case "fire": return _("Fire");
                case "storm": return _("Storm");
                case "wind": return _("Wind");
                case "snow": return _("Snow and Ice");
                case "heat": return _("Heat");
                case "cold": return _("Cold");
                case "volcano": return _("Volcano");
                case "landslide": return _("Landslide");
                case "health": return _("Health");
                case "security": return _("Security");
                case "national": return _("National Alert");
                default: return _("Alert");
            }
        }
    }
}
