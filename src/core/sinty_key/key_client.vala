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
        FAILED
    }

    public class Client : Object {
        private const string NAME = "dev.sinty.Key1";
        private const string PATH = "/dev/sinty/Key1";

        private static Client? instance = null;

        public static Client get_default() {
            if (instance == null) instance = new Client();
            return instance;
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
                case "dev.sinty.Key1.Error.NoTpm": return new KeyError.NO_TPM(_("This computer has no security chip to remember the Key."));
            }
            return new KeyError.FAILED(e.message);
        }

        private async Variant call(string method, Variant args, string reply) throws KeyError {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                return yield bus.call(NAME, PATH, NAME, method, args, new VariantType(reply), DBusCallFlags.NONE, 120000);
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
