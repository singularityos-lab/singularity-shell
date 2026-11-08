namespace Singularity.InputMethods {

    public class SintyFramework : Framework {
        private const string BUS_NAME = "dev.sinty.Input1";
        private const string OBJECT_PATH = "/dev/sinty/Input1";

        public override string id { get { return "sinty"; } }
        public override string display_name { get { return "Sinty"; } }

        private EngineInfo[]? cached = null;

        public override bool installed() {
            foreach (string dir in data_dirs()) {
                if (FileUtils.test(Path.build_filename(dir, "dbus-1", "services", BUS_NAME + ".service"), FileTest.EXISTS)) {
                    return true;
                }
            }
            return false;
        }

        public override EngineInfo[] engines() {
            if (cached != null) return cached;
            EngineInfo[] result = {};
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                var reply = bus.call_sync(BUS_NAME, OBJECT_PATH, BUS_NAME, "ListEngines", null,
                    new VariantType("(aas)"), DBusCallFlags.NONE, 3000, null);
                var list = reply.get_child_value(0);
                for (size_t i = 0; i < list.n_children(); i++) {
                    string[] fields = list.get_child_value(i).get_strv();
                    if (fields.length < 4) continue;
                    result += new EngineInfo() {
                        framework = id, name = fields[0], label = fields[1], symbol = fields[2], language = fields[3]
                    };
                }
                cached = result;
            } catch (Error e) {
                warning("Input method: cannot list the Sinty engines: %s", e.message);
            }
            return result;
        }

        public override async InputEngine? connect_engine() throws Error {
            var bus = yield Bus.get(BusType.SESSION);
            var engine = new SintyEngine(bus);
            engine.setup();
            return engine;
        }

        public override void shutdown() {
        }
    }

    public class SintyEngine : InputEngine {
        private const string BUS_NAME = "dev.sinty.Input1";
        private const string OBJECT_PATH = "/dev/sinty/Input1";

        public override string framework { get { return "sinty"; } }

        private DBusConnection bus;

        public SintyEngine(DBusConnection bus) {
            this.bus = bus;
        }

        public void setup() {
            bus.signal_subscribe(BUS_NAME, BUS_NAME, null, OBJECT_PATH, null, DBusSignalFlags.NONE, on_signal);
            bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                "/org/freedesktop/DBus", BUS_NAME, DBusSignalFlags.NONE, (c, s, p, i, n, parameters) => {
                    string owner;
                    parameters.get_child(2, "s", out owner);
                    if (owner == "") lost();
                });
        }

        private void on_signal(DBusConnection conn, string? sender, string object_path, string iface,
                               string signal_name, Variant parameters) {
            switch (signal_name) {
                case "Commit":
                    commit(parameters.get_child_value(0).get_string());
                    break;
                case "Preedit":
                    preedit(parameters.get_child_value(0).get_string(), parameters.get_child_value(1).get_int32());
                    break;
                case "Candidates":
                    var list = new Candidates();
                    list.items = parameters.get_child_value(0).get_strv();
                    list.labels = parameters.get_child_value(1).get_strv();
                    list.selected = parameters.get_child_value(2).get_int32();
                    list.has_previous = parameters.get_child_value(3).get_boolean();
                    list.has_next = parameters.get_child_value(4).get_boolean();
                    list.auxiliary = parameters.get_child_value(5).get_string();
                    candidates(list.empty ? null : list);
                    break;
            }
        }

        private void call(string method, Variant? args) {
            bus.call.begin(BUS_NAME, OBJECT_PATH, BUS_NAME, method, args, null, DBusCallFlags.NONE, 2000, null);
        }

        public override async bool process_key(uint keysym, uint keycode, uint state, bool release) {
            try {
                var reply = yield bus.call(BUS_NAME, OBJECT_PATH, BUS_NAME, "ProcessKey",
                    new Variant("(uuub)", keysym, keycode, state, release),
                    new VariantType("(b)"), DBusCallFlags.NONE, 1000, null);
                bool handled;
                reply.get("(b)", out handled);
                return handled;
            } catch (Error e) {
                return false;
            }
        }

        public override async void select_engine(string name) throws Error {
            yield bus.call(BUS_NAME, OBJECT_PATH, BUS_NAME, "SelectEngine", new Variant("(s)", name),
                null, DBusCallFlags.NONE, 3000, null);
        }

        public override void focus_in() {
            call("FocusIn", null);
        }

        public override void focus_out() {
            call("FocusOut", null);
        }

        public override void reset() {
            call("Reset", null);
        }

        public override void set_surrounding(string text, uint cursor) {
            call("SetSurrounding", new Variant("(su)", text, cursor));
        }

        public override void select_candidate(int index) {
            call("SelectCandidate", new Variant("(i)", index));
        }

        public override void change_page(bool next) {
            call("ChangePage", new Variant("(b)", next));
        }
    }
}
