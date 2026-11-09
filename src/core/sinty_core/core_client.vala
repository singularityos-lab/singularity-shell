namespace Singularity.SintyCore {

    public class Screen : Object {
        public string id;
        public string name;
        public bool connected;
    }

    public errordomain CoreError {
        NOT_ALLOWED,
        NOT_PAIRING,
        NO_LINK,
        NOT_SUPPORTED,
        WRONG_CODE,
        NOT_A_BACKUP,
        FAILED
    }

    public class Client : Object {
        private const string NAME = "dev.sinty.Core1";
        private const string PATH = "/dev/sinty/Core1";

        private static Client? instance = null;
        private DBusConnection? bus = null;
        private uint[] subscriptions = {};

        public Gee.ArrayList<Screen> screens = new Gee.ArrayList<Screen>();
        public bool pairing { get; private set; }
        public string pairing_screen { get; private set; default = ""; }
        public string route { get; private set; default = ""; }
        public string direct { get; private set; default = ""; }
        public string phone { get; private set; default = ""; }
        public string usb_mode { get; private set; default = "off"; }
        public string form { get; private set; default = ""; }
        public string core_name { get; private set; default = ""; }
        public string identity { get; private set; default = ""; }

        public signal void changed();
        public signal void pairing_request(string screen);
        public signal void pairing_finished(string screen, string result);

        public static Client get_default() {
            if (instance == null) instance = new Client();
            return instance;
        }

        public static bool installed() {
            foreach (unowned string dir in Environment.get_system_data_dirs()) {
                if (FileUtils.test(Path.build_filename(dir, "dbus-1", "system.d", "sinty-cored.conf"), FileTest.EXISTS)) return true;
            }
            return false;
        }

        public static bool has_usb_port() {
            try {
                var dir = Dir.open("/sys/class/udc");
                return dir.read_name() != null;
            } catch (FileError e) {
                return false;
            }
        }

        private static CoreError translate(Error e) {
            string? remote = DBusError.get_remote_error(e);
            DBusError.strip_remote_error(e);
            switch (remote ?? "") {
                case "dev.sinty.Core1.Error.NotAllowed": return new CoreError.NOT_ALLOWED(_("Only the person signed in on this computer can change this."));
                case "dev.sinty.Core1.Error.NotPairing": return new CoreError.NOT_PAIRING(_("No screen is waiting for a code."));
                case "dev.sinty.Core1.Error.NoLink": return new CoreError.NO_LINK(_("There is no network, cable or Wi-Fi Direct connection for a screen."));
                case "dev.sinty.Core1.Error.NotSupported": return new CoreError.NOT_SUPPORTED(_("This computer cannot do this."));
                case "dev.sinty.Core1.Error.WrongCode": return new CoreError.WRONG_CODE(_("The recovery code is not correct."));
                case "dev.sinty.Core1.Error.NotABackup": return new CoreError.NOT_A_BACKUP(_("This file is not a backup of a computer's screens."));
            }
            return new CoreError.FAILED(e.message);
        }

        public async void start() {
            if (bus != null) return;
            try {
                bus = yield Bus.get(BusType.SYSTEM);
            } catch (Error e) {
                warning("sinty-core: %s", e.message);
                return;
            }
            subscriptions += bus.signal_subscribe(NAME, "org.freedesktop.DBus.Properties", "PropertiesChanged", PATH, null, DBusSignalFlags.NONE,
                () => refresh.begin());
            subscriptions += bus.signal_subscribe(NAME, NAME, null, PATH, null, DBusSignalFlags.NONE, on_signal);
            yield refresh();
        }

        private void on_signal(DBusConnection conn, string? sender, string path, string iface, string member, Variant args) {
            switch (member) {
                case "PairingRequest":
                    pairing_request(args.get_child_value(0).get_string());
                    break;
                case "PairingFinished":
                    pairing_finished(args.get_child_value(0).get_string(), args.get_child_value(1).get_string());
                    break;
            }
        }

        public async void refresh() {
            if (bus == null) return;
            Variant reply;
            try {
                reply = yield bus.call(NAME, PATH, "org.freedesktop.DBus.Properties", "GetAll", new Variant("(s)", NAME),
                    new VariantType("(a{sv})"), DBusCallFlags.NONE, -1);
            } catch (Error e) {
                return;
            }
            var props = reply.get_child_value(0);
            pairing = lookup_bool(props, "Pairing");
            pairing_screen = lookup_string(props, "PairingScreen");
            route = lookup_string(props, "Route");
            direct = lookup_string(props, "Direct");
            phone = lookup_string(props, "Phone");
            usb_mode = lookup_string(props, "UsbMode");
            form = lookup_string(props, "Form");
            core_name = lookup_string(props, "Name");
            identity = lookup_string(props, "Identity");
            screens.clear();
            var list = props.lookup_value("Screens", new VariantType("a(ssb)"));
            if (list != null) {
                var iter = list.iterator();
                string id, name;
                bool connected;
                while (iter.next("(ssb)", out id, out name, out connected)) {
                    var s = new Screen();
                    s.id = id;
                    s.name = name;
                    s.connected = connected;
                    screens.add(s);
                }
            }
            changed();
        }

        private static string lookup_string(Variant props, string key) {
            var v = props.lookup_value(key, VariantType.STRING);
            return v != null ? v.get_string() : "";
        }

        private static bool lookup_bool(Variant props, string key) {
            var v = props.lookup_value(key, VariantType.BOOLEAN);
            return v != null && v.get_boolean();
        }

        private async Variant call(string method, Variant? args, string reply) throws CoreError {
            try {
                var conn = yield Bus.get(BusType.SYSTEM);
                return yield conn.call(NAME, PATH, NAME, method, args, new VariantType(reply), DBusCallFlags.NONE, 60000);
            } catch (Error e) {
                throw translate(e);
            }
        }

        private async Variant call_fd(string method, Variant args, string reply, int fd) throws CoreError {
            try {
                var fds = new UnixFDList();
                fds.append(fd);
                var conn = yield Bus.get(BusType.SYSTEM);
                UnixFDList out_fds;
                return yield conn.call_with_unix_fd_list(NAME, PATH, NAME, method, args, new VariantType(reply), DBusCallFlags.NONE, 60000, fds, null, out out_fds);
            } catch (Error e) {
                throw translate(e);
            } finally {
                Posix.close(fd);
            }
        }

        public async string backup(string path) throws CoreError {
            int fd = Posix.open(path, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_TRUNC | Posix.O_CLOEXEC, 0600);
            if (fd < 0) throw new CoreError.FAILED(strerror(errno));
            var v = yield call_fd("Backup", new Variant("(h)", 0), "(s)", fd);
            return v.get_child_value(0).get_string();
        }

        public async void restore(string path, string code) throws CoreError {
            int fd = Posix.open(path, Posix.O_RDONLY | Posix.O_CLOEXEC);
            if (fd < 0) throw new CoreError.FAILED(strerror(errno));
            yield call_fd("Restore", new Variant("(hs)", 0, code), "()", fd);
        }

        public async string start_pairing() throws CoreError {
            var v = yield call("StartPairing", null, "(s)");
            return v.get_child_value(0).get_string();
        }

        public async void confirm_pairing(string code) throws CoreError {
            yield call("ConfirmPairing", new Variant("(s)", code), "()");
        }

        public async void cancel_pairing() throws CoreError {
            yield call("CancelPairing", null, "()");
        }

        public async void revoke_screen(string id) throws CoreError {
            yield call("RevokeScreen", new Variant("(s)", id), "()");
        }

        public async void change_usb_mode(string mode) throws CoreError {
            yield call("SetUsbMode", new Variant("(s)", mode), "()");
        }

        public async void change_form(string form) throws CoreError {
            yield call("SetForm", new Variant("(s)", form), "()");
        }

        public async void direct_network(out string ssid, out string passphrase) throws CoreError {
            var v = yield call("DirectNetwork", null, "(ss)");
            ssid = v.get_child_value(0).get_string();
            passphrase = v.get_child_value(1).get_string();
        }
    }
}
