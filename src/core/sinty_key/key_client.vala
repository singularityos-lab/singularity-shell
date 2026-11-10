namespace Singularity.SintyKey {

    public class KeySlot : Object {
        public string fingerprint;
        public string name;
        public string firmware;
        public int64 last_used;
        public bool here;
    }

    public class KeyInfo : Object {
        public string root;
        public string id;
        public string level;
        public string mode;
        public Gee.ArrayList<KeySlot> slots = new Gee.ArrayList<KeySlot>();

        public bool unlocked {
            get {
                return mode != "";
            }
        }
    }

    public class KeyDrive : Object {
        public string device;
        public string name;
        public uint64 size;
        public string root;
        public bool key;
        public bool startup;
    }

    public class SecurityKey : Object {
        public string id;
        public string name;
        public int64 added;
    }

    public class TrustedDevice : Object {
        public string kind;
        public string id;
        public string name;
        public int64 added;
        public int64 last_used;
    }

    public errordomain KeyError {
        WRONG_PIN,
        WRONG_CODE,
        COPY,
        SHORT_PIN,
        EXISTS,
        NOT_A_KEY,
        NOT_REMEMBERED,
        TAMPERED,
        NOT_ALLOWED,
        NO_TPM,
        NOT_A_BACKUP,
        DAMAGED,
        FAKE_DRIVE,
        SECURITY_KEY_REQUIRED,
        UNKNOWN_SECURITY_KEY,
        SECURITY_KEY_EXISTS,
        TOO_MANY_SECURITY_KEYS,
        NOT_TOUCHED,
        SECURITY_KEY_PIN_REQUIRED,
        WRONG_SECURITY_KEY_PIN,
        SECURITY_KEY_PIN_BLOCKED,
        SECURITY_KEY_UNSUPPORTED,
        FAILED
    }

    public class Client : Object {
        private const string NAME = "dev.sinty.Key1";
        private const string PATH = "/dev/sinty/Key1";
        public const uint BADGE_UID = 61000;

        private static Client? instance = null;

        public signal void progress(string device, uint percent);

        public static Client get_default() {
            if (instance == null) {
                instance = new Client();
                instance.follow_progress.begin();
            }
            return instance;
        }

        private async void follow_progress() {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                bus.signal_subscribe(NAME, NAME, "Progress", PATH, null, DBusSignalFlags.NONE, (conn, sender, path, iface, name, args) => {
                    if (!args.is_of_type(new VariantType("(su)"))) return;
                    progress(args.get_child_value(0).get_string(), args.get_child_value(1).get_uint32());
                });
            } catch (Error e) {
            }
        }

        public static bool installed() {
            foreach (unowned string dir in Environment.get_system_data_dirs()) {
                if (FileUtils.test(Path.build_filename(dir, "dbus-1", "system-services", NAME + ".service"), FileTest.EXISTS)) return true;
            }
            return false;
        }

        private static KeyError translate(Error e) {
            string? remote = DBusError.get_remote_error(e);
            DBusError.strip_remote_error(e);
            switch (remote ?? "") {
                case "dev.sinty.Key1.Error.WrongPin": return new KeyError.WRONG_PIN(_("The PIN is not correct."));
                case "dev.sinty.Key1.Error.WrongCode": return new KeyError.WRONG_CODE(_("The recovery code is not correct."));
                case "dev.sinty.Key1.Error.Copy": return new KeyError.COPY(_("This is an older copy of the Key. Unlock it with the recovery code."));
                case "dev.sinty.Key1.Error.ShortPin": return new KeyError.SHORT_PIN(_("The PIN needs at least 4 characters."));
                case "dev.sinty.Key1.Error.Exists": return new KeyError.EXISTS(_("This drive is already a Sinty Key."));
                case "dev.sinty.Key1.Error.NotAKey": return new KeyError.NOT_A_KEY(_("This drive is not a Sinty Key."));
                case "dev.sinty.Key1.Error.NotRemembered": return new KeyError.NOT_REMEMBERED(_("The Key does not remember that computer."));
                case "dev.sinty.Key1.Error.Tampered": return new KeyError.TAMPERED(_("The Key was changed outside Sinty OS and cannot be trusted."));
                case "dev.sinty.Key1.Error.NotAllowed": return new KeyError.NOT_ALLOWED(_("Only removable drives can be a Sinty Key."));
                case "dev.sinty.Key1.Error.NotABackup": return new KeyError.NOT_A_BACKUP(_("This file is not a Sinty Key backup."));
                case "dev.sinty.Key1.Error.Damaged": return new KeyError.DAMAGED(_("The backup is damaged or was changed."));
                case "dev.sinty.Key1.Error.FakeDrive": return new KeyError.FAKE_DRIVE(_("This drive reports more space than it really has and would lose your files. Use another drive."));
                case "dev.sinty.Key1.Error.SecurityKeyRequired": return new KeyError.SECURITY_KEY_REQUIRED(_("Plug in one of the security keys of this Key."));
                case "dev.sinty.Key1.Error.UnknownSecurityKey": return new KeyError.UNKNOWN_SECURITY_KEY(_("This security key does not belong to the Key."));
                case "dev.sinty.Key1.Error.SecurityKeyExists": return new KeyError.SECURITY_KEY_EXISTS(_("This security key already belongs to the Key."));
                case "dev.sinty.Key1.Error.TooManySecurityKeys": return new KeyError.TOO_MANY_SECURITY_KEYS(_("The Key already has as many security keys as it can hold."));
                case "dev.sinty.Key1.Error.NoSecurityKey": return new KeyError.FAILED(_("That security key is no longer on the Key."));
                case "dev.sinty.Key1.Error.NotTouched": return new KeyError.NOT_TOUCHED(_("The security key was not touched in time."));
                case "dev.sinty.Key1.Error.SecurityKeyPinRequired": return new KeyError.SECURITY_KEY_PIN_REQUIRED(_("This security key has its own PIN. Enter it too."));
                case "dev.sinty.Key1.Error.WrongSecurityKeyPin": return new KeyError.WRONG_SECURITY_KEY_PIN(_("The security key PIN is not correct."));
                case "dev.sinty.Key1.Error.SecurityKeyPinBlocked": return new KeyError.SECURITY_KEY_PIN_BLOCKED(_("The security key PIN is blocked. Reset the security key with its maker's tool."));
                case "dev.sinty.Key1.Error.SecurityKeyUnsupported": return new KeyError.SECURITY_KEY_UNSUPPORTED(_("This security key cannot protect a Sinty Key. It needs FIDO2 with hmac-secret."));
                case "dev.sinty.Key1.Error.Disabled": return new KeyError.NOT_ALLOWED(_("This computer does not open sessions from a Sinty Key."));
                case "dev.sinty.Key1.Error.Unverified": return new KeyError.NOT_ALLOWED(_("This computer is not running a verified system."));
                case "dev.sinty.Key1.Error.NoTpm": return new KeyError.NO_TPM(_("This computer has no security chip to remember the Key."));
            }
            return new KeyError.FAILED(e.message);
        }

        private async Variant call(string method, Variant? args, string reply, int timeout = 120000) throws KeyError {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                return yield bus.call(NAME, PATH, NAME, method, args, new VariantType(reply), DBusCallFlags.NONE, timeout);
            } catch (Error e) {
                throw translate(e);
            }
        }

        private async Variant call_fd(string method, Variant args, string reply, int fd) throws KeyError {
            try {
                var fds = new UnixFDList();
                fds.append(fd);
                var bus = yield Bus.get(BusType.SYSTEM);
                UnixFDList out_fds;
                return yield bus.call_with_unix_fd_list(NAME, PATH, NAME, method, args, new VariantType(reply), DBusCallFlags.NONE, -1, fds, null, out out_fds);
            } catch (Error e) {
                throw translate(e);
            } finally {
                Posix.close(fd);
            }
        }

        public async void backup(string root, string pin, string path) throws KeyError {
            int fd = Posix.open(path, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_TRUNC | Posix.O_CLOEXEC, 0600);
            if (fd < 0) throw new KeyError.FAILED(strerror(errno));
            yield call_fd("Backup", new Variant("(ssh)", root, pin, 0), "()", fd);
        }

        public async string restore(string path, string code, string root, string pin) throws KeyError {
            int fd = Posix.open(path, Posix.O_RDONLY | Posix.O_CLOEXEC);
            if (fd < 0) throw new KeyError.FAILED(strerror(errno));
            var v = yield call_fd("Restore", new Variant("(hsss)", 0, code, root, pin), "(s)", fd);
            return v.get_child_value(0).get_string();
        }

        public async Gee.ArrayList<TrustedDevice> devices() throws KeyError {
            var v = yield call("Devices", null, "(a(sssxx))");
            var list = new Gee.ArrayList<TrustedDevice>();
            var iter = v.get_child_value(0).iterator();
            string kind, id, name;
            int64 added, last;
            while (iter.next("(sssxx)", out kind, out id, out name, out added, out last)) {
                var d = new TrustedDevice();
                d.kind = kind;
                d.id = id;
                d.name = name;
                d.added = added;
                d.last_used = last;
                list.add(d);
            }
            return list;
        }

        public async string[] startup_sync(string device) throws KeyError {
            var v = yield call("StartupSync", new Variant("(s)", device), "(sss)");
            return { v.get_child_value(0).get_string(), v.get_child_value(1).get_string(), v.get_child_value(2).get_string() };
        }

        public async void update_startup_key(string device) throws KeyError {
            yield call("UpdateStartupKey", new Variant("(s)", device), "()", 7200000);
        }

        public async void update_from_startup_key(string device) throws KeyError {
            yield call("UpdateFromStartupKey", new Variant("(s)", device), "()", 7200000);
        }

        public async bool badge_allowed() throws KeyError {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var v = yield bus.call(NAME, PATH, "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", NAME, "BadgeAllowed"), new VariantType("(v)"), DBusCallFlags.NONE, 5000);
                var inner = v.get_child_value(0).get_variant();
                return inner.is_of_type(VariantType.BOOLEAN) && inner.get_boolean();
            } catch (Error e) {
                throw translate(e);
            }
        }

        public async void set_badge_allowed(bool on) throws KeyError {
            yield call("SetBadgeAllowed", new Variant("(b)", on), "()");
        }

        public async void revoke(string kind, string id) throws KeyError {
            yield call("Revoke", new Variant("(ss)", kind, id), "()");
        }

        public async KeyInfo inspect(string root) throws KeyError {
            var v = yield call("Inspect", new Variant("(s)", root), "(sssa(sssxb))");
            var info = new KeyInfo();
            info.root = root;
            info.id = v.get_child_value(0).get_string();
            info.level = v.get_child_value(1).get_string();
            info.mode = v.get_child_value(2).get_string();
            var iter = v.get_child_value(3).iterator();
            string fp, name, fw;
            int64 last;
            bool here;
            while (iter.next("(sssxb)", out fp, out name, out fw, out last, out here)) {
                var s = new KeySlot();
                s.fingerprint = fp;
                s.name = name;
                s.firmware = fw;
                s.last_used = last;
                s.here = here;
                info.slots.add(s);
            }
            return info;
        }

        public async string create(string root, string pin) throws KeyError {
            var v = yield call("Create", new Variant("(ss)", root, pin), "(s)");
            return v.get_child_value(0).get_string();
        }

        public async string unlock(string root, string pin) throws KeyError {
            var v = yield call("Unlock", new Variant("(ss)", root, pin), "(s)");
            return v.get_child_value(0).get_string();
        }

        public async void lock(string root) throws KeyError {
            yield call("Lock", new Variant("(s)", root), "()");
        }

        public async void remember(string root, string pin, string name) throws KeyError {
            yield call("Remember", new Variant("(sss)", root, pin, name), "()");
        }

        public async void forget(string root, string pin, string fingerprint) throws KeyError {
            yield call("Forget", new Variant("(sss)", root, pin, fingerprint), "()");
        }

        public async void change_pin(string root, string old_pin, string pin) throws KeyError {
            yield call("ChangePin", new Variant("(sss)", root, old_pin, pin), "()");
        }

        public async void recover(string root, string code, string pin) throws KeyError {
            yield call("Recover", new Variant("(sss)", root, code, pin), "()");
        }

        public async Gee.ArrayList<SecurityKey> security_keys(string root) throws KeyError {
            var v = yield call("SecurityKeys", new Variant("(s)", root), "(a(ssx))");
            var list = new Gee.ArrayList<SecurityKey>();
            var iter = v.get_child_value(0).iterator();
            string id, name;
            int64 added;
            while (iter.next("(ssx)", out id, out name, out added)) {
                var k = new SecurityKey();
                k.id = id;
                k.name = name;
                k.added = added;
                list.add(k);
            }
            return list;
        }

        public async string add_security_key(string root, string pin, string name, string key_pin) throws KeyError {
            var v = yield call("AddSecurityKey", new Variant("(ssss)", root, pin, name, key_pin), "(s)");
            return v.get_child_value(0).get_string();
        }

        public async void remove_security_key(string root, string pin, string id) throws KeyError {
            yield call("RemoveSecurityKey", new Variant("(sss)", root, pin, id), "()");
        }

        public async void recover_without_security_keys(string root, string code, string pin) throws KeyError {
            yield call("RecoverWithoutSecurityKeys", new Variant("(sss)", root, code, pin), "()");
        }

        public async Gee.ArrayList<KeyDrive> drives() throws KeyError {
            var v = yield call("Drives", null, "(a(sstsbb))");
            var list = new Gee.ArrayList<KeyDrive>();
            var iter = v.get_child_value(0).iterator();
            string device, name, root;
            uint64 size;
            bool key, startup;
            while (iter.next("(sstsbb)", out device, out name, out size, out root, out key, out startup)) {
                var d = new KeyDrive();
                d.device = device;
                d.name = name;
                d.size = size;
                d.root = root;
                d.key = key;
                d.startup = startup;
                list.add(d);
            }
            return list;
        }

        public async void move_home(string root, string direction) throws KeyError {
            yield call("MoveHome", new Variant("(sss)", root, "", direction), "()", int.MAX);
        }

        public async string move_home_state(string root, string direction) throws KeyError {
            var v = yield call("MoveHomeState", new Variant("(sss)", root, "", direction), "(s)");
            return v.get_child_value(0).get_string();
        }

        public async void finish_move(string root, string direction, bool remove) throws KeyError {
            yield call("FinishMove", new Variant("(sssb)", root, "", direction, remove), "()", int.MAX);
        }

        public async Gee.ArrayList<KeyDrive> rescue_targets() throws KeyError {
            var v = yield call("RescueTargets", null, "(a(sstsbb))");
            var list = new Gee.ArrayList<KeyDrive>();
            var iter = v.get_child_value(0).iterator();
            string device, name, root;
            uint64 size;
            bool key, startup;
            while (iter.next("(sstsbb)", out device, out name, out size, out root, out key, out startup)) {
                var d = new KeyDrive();
                d.device = device;
                d.name = name;
                d.size = size;
                d.root = root;
                d.key = key;
                d.startup = startup;
                list.add(d);
            }
            return list;
        }

        public async string rescue(string device) throws KeyError {
            var v = yield call("Rescue", new Variant("(s)", device), "(s)", 600000);
            return v.get_child_value(0).get_string();
        }

        public async void end_rescue() throws KeyError {
            yield call("EndRescue", null, "()");
        }

        public async string prepare(string device) throws KeyError {
            var v = yield call("Prepare", new Variant("(s)", device), "(s)", 600000);
            return v.get_child_value(0).get_string();
        }

        public async void make_bootable(string device) throws KeyError {
            yield call("MakeBootable", new Variant("(s)", device), "()", int.MAX);
        }

        public async string[] architectures() throws KeyError {
            var v = yield call("Architectures", null, "(as)");
            return v.get_child_value(0).get_strv();
        }

        public async void make_bootable_for(string device, string arch) throws KeyError {
            yield call("MakeBootableFor", new Variant("(ss)", device, arch), "()", int.MAX);
        }

        public async string open(string device, string pin) throws KeyError {
            var v = yield call("Open", new Variant("(ss)", device, pin), "(ss)");
            return v.get_child_value(0).get_string();
        }

        public static Gee.ArrayList<string> removable_drives() {
            var list = new Gee.ArrayList<string>();
            string base_dir = Path.build_filename("/run/media", Environment.get_user_name());
            try {
                var dir = Dir.open(base_dir);
                string? name;
                while ((name = dir.read_name()) != null) {
                    string path = Path.build_filename(base_dir, name);
                    if (FileUtils.test(path, FileTest.IS_DIR)) list.add(path);
                }
            } catch (FileError e) {
            }
            list.sort((a, b) => strcmp(a, b));
            return list;
        }
    }
}
