namespace Singularity.InputMethods {

    public class FcitxFramework : Framework {
        private const string BUS_NAME = "org.fcitx.Fcitx5";

        public override string id { get { return "fcitx5"; } }
        public override string display_name { get { return "Fcitx 5"; } }

        private Subprocess? daemon = null;

        public static string? daemon_binary() {
            return Environment.find_program_in_path("fcitx5");
        }

        public override bool installed() {
            return daemon_binary() != null;
        }

        public override EngineInfo[] engines() {
            EngineInfo[] result = {};
            var seen = new GenericSet<string>(str_hash, str_equal);
            foreach (string dir in data_dirs()) {
                string im_dir = Path.build_filename(dir, "fcitx5", "inputmethod");
                try {
                    var directory = Dir.open(im_dir);
                    string? name;
                    while ((name = directory.read_name()) != null) {
                        if (!name.has_suffix(".conf")) continue;
                        string id = name.substring(0, name.length - 5);
                        if (seen.contains(id) || id.has_prefix("keyboard-")) continue;
                        string contents;
                        FileUtils.get_contents(Path.build_filename(im_dir, name), out contents);
                        var info = Serial.parse_fcitx_conf(id, contents);
                        if (info == null) continue;
                        seen.add(id);
                        result += info;
                    }
                } catch (Error e) {
                }
            }
            return result;
        }

        private async bool running(DBusConnection bus) {
            try {
                var reply = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new Variant("(s)", BUS_NAME), new VariantType("(b)"), DBusCallFlags.NONE, 1000, null);
                bool owned;
                reply.get("(b)", out owned);
                return owned;
            } catch (Error e) {
                return false;
            }
        }

        private void launch() throws Error {
            if (daemon != null) return;
            string? binary = daemon_binary();
            if (binary == null) throw new IOError.NOT_FOUND("fcitx5 is not installed");
            daemon = new Subprocess.newv({ binary, "--disable=wayland,waylandim" },
                SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            daemon.wait_async.begin(null, () => daemon = null);
        }

        public override async InputEngine? connect_engine() throws Error {
            var bus = yield Bus.get(BusType.SESSION);
            if (!(yield running(bus))) {
                launch();
                bool up = false;
                for (int i = 0; i < 80 && !up; i++) {
                    yield wait_ms(100);
                    up = yield running(bus);
                }
                if (!up) throw new IOError.TIMED_OUT("Fcitx did not start");
            }
            var args = new VariantBuilder(new VariantType("a(ss)"));
            args.add("(ss)", "program", "singularity-desktop");
            args.add("(ss)", "display", "wayland:");
            var reply = yield bus.call(BUS_NAME, "/org/freedesktop/portal/inputmethod", "org.fcitx.Fcitx.InputMethod1",
                "CreateInputContext", new Variant("(a(ss))", args), new VariantType("(oay)"), DBusCallFlags.NONE, 3000, null);
            string path = reply.get_child_value(0).get_string();
            var engine = new FcitxEngine(bus, path);
            yield engine.setup();
            return engine;
        }

        public override void shutdown() {
            if (daemon != null) daemon.send_signal(Posix.Signal.TERM);
            daemon = null;
        }
    }

    public class FcitxEngine : InputEngine {
        private const string BUS_NAME = "org.fcitx.Fcitx5";
        private const string IC_IFACE = "org.fcitx.Fcitx.InputContext1";
        private const uint64 CAPS = (1 << 1) | (1 << 4) | (1 << 6) | ((uint64) 1 << 39);

        public override string framework { get { return "fcitx5"; } }

        private DBusConnection bus;
        private string path;
        private uint subscription = 0;

        public FcitxEngine(DBusConnection bus, string path) {
            this.bus = bus;
            this.path = path;
        }

        public async void setup() throws Error {
            subscription = bus.signal_subscribe(BUS_NAME, IC_IFACE, null, path, null, DBusSignalFlags.NONE, on_signal);
            bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                "/org/freedesktop/DBus", BUS_NAME, DBusSignalFlags.NONE, (c, s, p, i, n, parameters) => {
                    string owner;
                    parameters.get_child(2, "s", out owner);
                    if (owner == "") lost();
                });
            yield bus.call(BUS_NAME, path, IC_IFACE, "SetCapability", new Variant("(t)", CAPS),
                null, DBusCallFlags.NONE, 2000, null);
        }

        private void on_signal(DBusConnection conn, string? sender, string object_path, string iface,
                               string signal_name, Variant parameters) {
            switch (signal_name) {
                case "CommitString":
                    commit(parameters.get_child_value(0).get_string());
                    break;
                case "UpdateFormattedPreedit":
                    preedit(Serial.fcitx_formatted(parameters.get_child_value(0)),
                        parameters.get_child_value(1).get_int32());
                    break;
                case "UpdateClientSideUI":
                    string aux = Serial.fcitx_formatted(parameters.get_child_value(2))
                        + Serial.fcitx_formatted(parameters.get_child_value(0))
                        + Serial.fcitx_formatted(parameters.get_child_value(3));
                    var list = Serial.fcitx_candidates(parameters.get_child_value(4),
                        parameters.get_child_value(5).get_int32(),
                        parameters.get_child_value(7).get_boolean(),
                        parameters.get_child_value(8).get_boolean(),
                        parameters.get_child_value(6).get_int32(), aux);
                    candidates(list.empty ? null : list);
                    break;
                case "ForwardKey":
                    uint keysym, state;
                    bool release;
                    parameters.get("(uub)", out keysym, out state, out release);
                    if (!release) forward_key(keysym, 0, state);
                    break;
                case "DeleteSurroundingText":
                    int offset;
                    uint count;
                    parameters.get("(iu)", out offset, out count);
                    delete_surrounding(offset, count);
                    break;
            }
        }

        private void call(string method, Variant? args) {
            bus.call.begin(BUS_NAME, path, IC_IFACE, method, args, null, DBusCallFlags.NONE, 2000, null);
        }

        public override async bool process_key(uint keysym, uint keycode, uint state, bool release) {
            try {
                var reply = yield bus.call(BUS_NAME, path, IC_IFACE, "ProcessKeyEvent",
                    new Variant("(uuubu)", keysym, keycode, state, release, (uint) (get_monotonic_time() / 1000)),
                    new VariantType("(b)"), DBusCallFlags.NONE, 1000, null);
                bool handled;
                reply.get("(b)", out handled);
                return handled;
            } catch (Error e) {
                return false;
            }
        }

        public override async void select_engine(string name) throws Error {
            yield bus.call(BUS_NAME, path, IC_IFACE, "FocusIn", null, null, DBusCallFlags.NONE, 2000, null);
            var group = yield bus.call(BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1", "CurrentInputMethodGroup",
                null, new VariantType("(s)"), DBusCallFlags.NONE, 2000, null);
            string group_name;
            group.get("(s)", out group_name);
            var info = yield bus.call(BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1", "InputMethodGroupInfo",
                new Variant("(s)", group_name), null, DBusCallFlags.NONE, 2000, null);
            string layout = info.get_child_value(0).get_string();
            var items = info.get_child_value(1);
            bool present = false;
            var builder = new VariantBuilder(new VariantType("a(ss)"));
            for (size_t i = 0; i < items.n_children(); i++) {
                var item = items.get_child_value(i);
                string im = item.get_child_value(0).get_string();
                if (im == name) present = true;
                builder.add("(ss)", im, item.get_child_value(1).get_string());
            }
            if (!present) {
                builder.add("(ss)", name, "");
                yield bus.call(BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1", "SetInputMethodGroupInfo",
                    new Variant("(ssa(ss))", group_name, layout, builder), null, DBusCallFlags.NONE, 2000, null);
            }
            yield bus.call(BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1", "SetCurrentIM",
                new Variant("(s)", name), null, DBusCallFlags.NONE, 2000, null);
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
            call("SetSurroundingText", new Variant("(suu)", text, cursor, cursor));
        }

        public override void select_candidate(int index) {
            call("SelectCandidate", new Variant("(i)", index));
        }

        public override void change_page(bool next) {
            call(next ? "NextPage" : "PrevPage", null);
        }
    }
}
