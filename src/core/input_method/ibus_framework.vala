namespace Singularity.InputMethods {

    public class IBusFramework : Framework {
        private const string BUS_NAME = "org.freedesktop.IBus";
        private const string BUS_PATH = "/org/freedesktop/IBus";
        private const string IC_IFACE = "org.freedesktop.IBus.InputContext";

        public override string id { get { return "ibus"; } }
        public override string display_name { get { return "IBus"; } }

        private Subprocess? daemon = null;

        public static string? daemon_binary() {
            return Environment.find_program_in_path("ibus-daemon");
        }

        public override bool installed() {
            return daemon_binary() != null;
        }

        public static string[] component_dirs() {
            string[] dirs = {};
            string? custom = Environment.get_variable("IBUS_COMPONENT_PATH");
            if (custom != null && custom != "") {
                foreach (string dir in custom.split(":")) dirs += dir;
            }
            foreach (string dir in data_dirs()) dirs += Path.build_filename(dir, "ibus", "component");
            return dirs;
        }

        public override EngineInfo[] engines() {
            EngineInfo[] result = {};
            var seen = new GenericSet<string>(str_hash, str_equal);
            foreach (string dir in component_dirs()) {
                try {
                    var directory = Dir.open(dir);
                    string? name;
                    while ((name = directory.read_name()) != null) {
                        if (!name.has_suffix(".xml")) continue;
                        string contents;
                        FileUtils.get_contents(Path.build_filename(dir, name), out contents);
                        foreach (var info in Serial.parse_ibus_component(contents)) {
                            if (seen.contains(info.name)) continue;
                            seen.add(info.name);
                            result += info;
                        }
                    }
                } catch (Error e) {
                }
            }
            return result;
        }

        public static string? find_address() {
            string? env = Environment.get_variable("IBUS_ADDRESS");
            if (env != null && env != "") return env;
            string dir = Path.build_filename(Environment.get_user_config_dir(), "ibus", "bus");
            string? best = null;
            int64 best_time = 0;
            try {
                var directory = Dir.open(dir);
                string? name;
                while ((name = directory.read_name()) != null) {
                    string path = Path.build_filename(dir, name);
                    string contents;
                    FileUtils.get_contents(path, out contents);
                    string? address = null;
                    int pid = 0;
                    foreach (string line in contents.split("\n")) {
                        if (line.has_prefix("IBUS_ADDRESS=")) address = line.substring(13).strip();
                        else if (line.has_prefix("IBUS_DAEMON_PID=")) pid = int.parse(line.substring(16));
                    }
                    if (address == null || pid <= 0 || !FileUtils.test("/proc/%d".printf(pid), FileTest.EXISTS)) continue;
                    var info = File.new_for_path(path).query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    int64 time = (int64) info.get_attribute_uint64(FileAttribute.TIME_MODIFIED);
                    if (best == null || time > best_time) {
                        best = address;
                        best_time = time;
                    }
                }
            } catch (Error e) {
            }
            return best;
        }

        private void launch() throws Error {
            if (daemon != null) return;
            string? binary = daemon_binary();
            if (binary == null) throw new IOError.NOT_FOUND("ibus-daemon is not installed");
            string[] argv = { binary, "--panel=disable" };
            if (Environment.get_variable("DISPLAY") != null) argv += "--xim";
            daemon = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            daemon.wait_async.begin(null, () => daemon = null);
        }

        public override async InputEngine? connect_engine() throws Error {
            string? address = find_address();
            if (address == null) {
                launch();
                for (int i = 0; i < 50 && address == null; i++) {
                    yield wait_ms(100);
                    address = find_address();
                }
            }
            if (address == null) throw new IOError.TIMED_OUT("IBus did not start");
            DBusConnection? connection = null;
            for (int i = 0; i < 20 && connection == null; i++) {
                try {
                    connection = yield new DBusConnection.for_address(address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION);
                } catch (Error e) {
                    yield wait_ms(100);
                }
            }
            if (connection == null) throw new IOError.FAILED("Cannot reach IBus");
            var reply = yield connection.call(BUS_NAME, BUS_PATH, BUS_NAME, "CreateInputContext",
                new Variant("(s)", "singularity-desktop"), new VariantType("(o)"), DBusCallFlags.NONE, 2000, null);
            string path;
            reply.get("(o)", out path);
            var engine = new IBusEngine(connection, path);
            yield engine.setup();
            return engine;
        }

        public override void shutdown() {
            if (daemon != null) daemon.send_signal(Posix.Signal.TERM);
            daemon = null;
        }
    }

    public class IBusEngine : InputEngine {
        private const string IC_IFACE = "org.freedesktop.IBus.InputContext";
        private const uint CAPS = 1 | 2 | 4 | 8 | 32;

        public override string framework { get { return "ibus"; } }

        private DBusConnection connection;
        private string path;
        private uint subscription = 0;
        private string auxiliary = "";
        private Candidates? table = null;
        private bool table_visible = false;

        public IBusEngine(DBusConnection connection, string path) {
            this.connection = connection;
            this.path = path;
        }

        public async void setup() throws Error {
            subscription = connection.signal_subscribe(null, IC_IFACE, null, path, null,
                DBusSignalFlags.NONE, on_signal);
            connection.notify["closed"].connect(() => lost());
            yield connection.call(null, path, IC_IFACE, "SetCapabilities", new Variant("(u)", CAPS),
                null, DBusCallFlags.NONE, 2000, null);
        }

        private void on_signal(DBusConnection conn, string? sender, string object_path, string iface,
                               string signal_name, Variant parameters) {
            switch (signal_name) {
                case "CommitText":
                    commit(Serial.ibus_text(parameters.get_child_value(0)));
                    break;
                case "UpdatePreeditText":
                case "UpdatePreeditTextWithMode":
                    bool visible = parameters.get_child_value(2).get_boolean();
                    preedit(visible ? Serial.ibus_text(parameters.get_child_value(0)) : "",
                        (int) parameters.get_child_value(1).get_uint32());
                    break;
                case "HidePreeditText":
                    preedit("", 0);
                    break;
                case "UpdateAuxiliaryText":
                    auxiliary = parameters.get_child_value(1).get_boolean()
                        ? Serial.ibus_text(parameters.get_child_value(0)) : "";
                    publish();
                    break;
                case "HideAuxiliaryText":
                    auxiliary = "";
                    publish();
                    break;
                case "UpdateLookupTable":
                    table = Serial.ibus_table(parameters.get_child_value(0));
                    table_visible = parameters.get_child_value(1).get_boolean();
                    publish();
                    break;
                case "ShowLookupTable":
                    table_visible = true;
                    publish();
                    break;
                case "HideLookupTable":
                    table_visible = false;
                    publish();
                    break;
                case "ForwardKeyEvent":
                    uint keysym, keycode, state;
                    parameters.get("(uuu)", out keysym, out keycode, out state);
                    forward_key(keysym, keycode, state);
                    break;
                case "DeleteSurroundingText":
                    int offset;
                    uint count;
                    parameters.get("(iu)", out offset, out count);
                    delete_surrounding(offset, count);
                    break;
            }
        }

        private void publish() {
            if (table_visible && table != null && !table.empty) {
                table.auxiliary = auxiliary;
                candidates(table);
            } else {
                candidates(null);
            }
        }

        private void call(string method, Variant? args) {
            connection.call.begin(null, path, IC_IFACE, method, args, null, DBusCallFlags.NONE, 2000, null);
        }

        public override async bool process_key(uint keysym, uint keycode, uint state, bool release) {
            try {
                var reply = yield connection.call(null, path, IC_IFACE, "ProcessKeyEvent",
                    new Variant("(uuu)", keysym, keycode, state | (release ? IBUS_RELEASE : 0)),
                    new VariantType("(b)"), DBusCallFlags.NONE, 1000, null);
                bool handled;
                reply.get("(b)", out handled);
                return handled;
            } catch (Error e) {
                return false;
            }
        }

        public override async void select_engine(string name) throws Error {
            yield connection.call(null, path, IC_IFACE, "FocusIn", null, null, DBusCallFlags.NONE, 2000, null);
            try {
                yield connection.call("org.freedesktop.IBus", "/org/freedesktop/IBus", "org.freedesktop.IBus",
                    "SetGlobalEngine", new Variant("(s)", name), null, DBusCallFlags.NONE, 5000, null);
            } catch (Error e) {
                yield connection.call(null, path, IC_IFACE, "SetEngine", new Variant("(s)", name),
                    null, DBusCallFlags.NONE, 5000, null);
            }
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
            call("SetSurroundingText", new Variant("(vuu)", Serial.ibus_text_variant(text).get_variant(), cursor, cursor));
        }

        public override void select_candidate(int index) {
            if (index < 0 || index > 9) return;
            uint keysym = '1' + (uint) index;
            if (index == 9) keysym = '0';
            process_key.begin(keysym, 0, 0, false);
            process_key.begin(keysym, 0, 0, true);
        }

        public override void change_page(bool next) {
            uint keysym = next ? 0xff56 : 0xff55;
            process_key.begin(keysym, 0, 0, false);
            process_key.begin(keysym, 0, 0, true);
        }
    }
}
