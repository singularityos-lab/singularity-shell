namespace Singularity {

    [DBus (name = "dev.sinty.Shell.AppPause")]
    public class AppPauseService : Object {
        public signal void changed(string app_id, bool paused);

        public bool available { get { return AppPause.get_default().available; } }

        public HashTable<string, Variant>[] list_apps() throws Error {
            HashTable<string, Variant>[] apps = {};
            foreach (var group in AppPause.get_default().groups()) {
                var row = new HashTable<string, Variant>(str_hash, str_equal);
                row.insert("app-id", new Variant.string(group.app_id));
                row.insert("paused", new Variant.boolean(group.paused));
                row.insert("cpu-usec", new Variant.uint64(group.cpu_usec));
                row.insert("memory", new Variant.uint64(group.memory));
                row.insert("swapped", new Variant.uint64(group.swapped));
                apps += row;
            }
            return apps;
        }

        public bool pause(string app_id) throws Error {
            return AppPause.get_default().pause(app_id);
        }

        public bool resume(string app_id) throws Error {
            return AppPause.get_default().resume(app_id);
        }
    }

    public class AppPause : Object {
        private const uint SAMPLE_SECONDS = 5;
        private const int SUSTAINED_SAMPLES = 3;
        private const double CPU_PRESSURE = 50.0;
        private const double MEMORY_PRESSURE = 15.0;
        private const int HOT_MILLIDEGREES = 90000;
        private const double BUSY_CORE_SHARE = 0.15;
        private const uint64 BUSY_MEMORY = 300 * 1024 * 1024;
        private const int64 COOLDOWN_US = 10 * 60 * 1000000LL;
        private const int MAX_SUGGESTED = 3;

        public class Group {
            public string app_id;
            public string path;
            public bool paused;
            public uint64 cpu_usec;
            public uint64 memory;
            public uint64 swapped;
            public double core_share;
        }

        public signal void changed(string app_id, bool paused);

        public bool available { get; private set; default = false; }

        private static AppPause? instance = null;
        private string cgroup_root;
        private string session = "";
        private string slice = "";
        private HashTable<string, uint64?> last_cpu = new HashTable<string, uint64?>(str_hash, str_equal);
        private int64 last_sample = 0;
        private int strained = 0;
        private int64 quiet_until = 0;
        private uint suggestion = 0;
        private int64 suggested_at = 0;
        private string[] suggested = {};
        private ProcessTerminator procs;

        public static AppPause get_default() {
            if (instance == null) instance = new AppPause();
            return instance;
        }

        public AppPause(string cgroup_root = "/sys/fs/cgroup", string proc_root = "/proc") {
            this.cgroup_root = cgroup_root;
            procs = new ProcessTerminator(3000, proc_root, cgroup_root);
            string? own = procs.cgroup_of(Posix.getpid());
            if (own == null || own == "/") return;
            string parent = Path.get_dirname(own);
            if (Path.get_basename(parent) != "user-%u.slice".printf((uint) Posix.getuid())) return;
            Posix.Stat st;
            if (Posix.stat(cgroup_root + parent, out st) != 0 || st.st_uid != Posix.getuid()) return;
            if (Posix.access(cgroup_root + parent + "/cgroup.procs", Posix.W_OK) != 0) return;
            session = own;
            slice = parent;
            available = true;
        }

        public string session_path { get { return session; } }

        public void start() {
            if (!available) return;
            var css = new Gtk.CssProvider();
            css.load_from_string(".dock-item.paused image { filter: grayscale(1); opacity: 0.55; }");
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            var apps = AppSystem.get_default();
            apps.app_opened.connect((handle, app_id) => {
                Timeout.add(300, () => {
                    place_window(handle, app_id);
                    return Source.REMOVE;
                });
            });
            apps.app_closed.connect(() => Timeout.add_seconds(2, () => {
                prune();
                return Source.REMOVE;
            }));
            prune();
            foreach (var win in apps.get_windows()) place_window(win.handle, win.app_id);
            ProcessInfo.watch_resume(on_resume_requested);

            var notifications = SystemMonitor.get_default().notifications;
            notifications.action_invoked.connect((id, action) => {
                if (id != suggestion) return;
                suggestion = 0;
                if (action == "pause") {
                    foreach (string app in suggested) pause(app);
                } else {
                    quiet_until = get_monotonic_time() + COOLDOWN_US;
                }
                notifications.close_notification(id);
            });
            notifications.notification_closed.connect((id, reason) => {
                if (id != suggestion) return;
                suggestion = 0;
                quiet_until = int64.max(quiet_until, get_monotonic_time() + COOLDOWN_US);
            });
            Timeout.add_seconds(SAMPLE_SECONDS, () => {
                sample();
                return Source.CONTINUE;
            });
        }

        private void on_resume_requested(void* toplevel) {
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (win.handle == toplevel) {
                    resume(win.app_id);
                    return;
                }
            }
            int pid;
            uint source;
            if (ProcessInfo.get_pid(toplevel, out pid, out source)) {
                string? path = procs.app_scope_of(pid);
                if (path != null) write(path + "/cgroup.freeze", "0");
            }
        }

        public string? prepare_launch(string app_id) {
            if (!available || app_id == "") return null;
            string path = scope_path(app_id);
            if (DirUtils.create(cgroup_root + path, 0755) != 0 && errno != Posix.EEXIST) return null;
            return cgroup_root + path + "/cgroup.procs";
        }

        public static void join(string procs_file) {
            int fd = Posix.open(procs_file, Posix.O_WRONLY | Posix.O_CLOEXEC);
            if (fd < 0) return;
            Posix.write(fd, "0", 1);
            Posix.close(fd);
        }

        public static string scope_name(string desktop_id) {
            string app_id = desktop_id.has_suffix(".desktop")
                ? desktop_id.substring(0, desktop_id.length - 8) : desktop_id;
            var name = new StringBuilder();
            unichar c;
            for (int i = 0; app_id.get_next_char(ref i, out c);) {
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                        || c == '.' || c == '-' || c == '_')
                    name.append_unichar(c);
                else
                    name.append_c('_');
            }
            if (name.len == 0) name.append("unknown");
            return "app-%s.scope".printf(name.str);
        }

        private string scope_path(string app_id) {
            return slice + "/" + scope_name(app_id);
        }

        public void place_window(void* handle, string app_id) {
            if (!available || app_id == "") return;
            int pid;
            uint source;
            if (!ProcessInfo.get_pid(handle, out pid, out source) || !procs.may_signal(pid)) return;
            if (procs.cgroup_of(pid) != session) return;
            string path = scope_path(app_id);
            if (DirUtils.create(cgroup_root + path, 0755) != 0 && errno != Posix.EEXIST) {
                warning("app-pause: cannot create %s: %s", path, Posix.strerror(errno));
                return;
            }
            int moved = 0;
            foreach (int member in tree_of(pid)) {
                if (write(path + "/cgroup.procs", member.to_string())) moved++;
            }
            message("app-pause: %s placed in %s (%d processes)", app_id, path, moved);
        }

        private int[] tree_of(int root) {
            var children = new HashTable<int, GenericArray<int>>(direct_hash, direct_equal);
            Dir dir;
            try {
                dir = Dir.open(procs.proc_root);
            } catch (FileError e) {
                return { root };
            }
            string? name;
            while ((name = dir.read_name()) != null) {
                int pid = int.parse(name);
                if (pid <= 1 || pid == root || !procs.may_signal(pid)) continue;
                if (procs.cgroup_of(pid) != session) continue;
                int parent = parent_of(pid);
                var list = children.lookup(parent);
                if (list == null) {
                    list = new GenericArray<int>();
                    children.insert(parent, list);
                }
                list.add(pid);
            }
            int[] tree = { root };
            for (int i = 0; i < tree.length; i++) {
                var list = children.lookup(tree[i]);
                if (list == null) continue;
                foreach (int child in list.data) tree += child;
            }
            return tree;
        }

        private int parent_of(int pid) {
            string stat;
            try {
                if (!FileUtils.get_contents("%s/%d/stat".printf(procs.proc_root, pid), out stat)) return 0;
            } catch (FileError e) {
                return 0;
            }
            int close = stat.last_index_of_char(')');
            if (close < 0) return 0;
            string[] fields = stat.substring(close + 2).split(" ");
            return fields.length > 1 ? int.parse(fields[1]) : 0;
        }

        private bool write(string relative, string value) {
            int fd = Posix.open(cgroup_root + relative, Posix.O_WRONLY | Posix.O_CLOEXEC);
            if (fd < 0) return false;
            bool ok = Posix.write(fd, value, value.length) == value.length;
            Posix.close(fd);
            return ok;
        }

        private string? read(string relative) {
            string contents;
            try {
                if (FileUtils.get_contents(cgroup_root + relative, out contents)) return contents;
            } catch (FileError e) {}
            return null;
        }

        private uint64 read_key(string relative, string key) {
            string? contents = read(relative);
            if (contents == null) return 0;
            foreach (string line in contents.split("\n")) {
                if (line.has_prefix(key + " ")) return uint64.parse(line.substring(key.length + 1));
            }
            return 0;
        }

        private uint64 read_number(string relative) {
            string? contents = read(relative);
            return contents == null ? 0 : uint64.parse(contents.strip());
        }

        public Group[] groups() {
            Group[] list = {};
            if (!available) return list;
            Dir dir;
            try {
                dir = Dir.open(cgroup_root + slice);
            } catch (FileError e) {
                return list;
            }
            var ids = new HashTable<string, string>(str_hash, str_equal);
            foreach (var win in AppSystem.get_default().get_windows()) ids.insert(scope_name(win.app_id), win.app_id);
            string? name;
            while ((name = dir.read_name()) != null) {
                if (!name.has_prefix("app-") || !name.has_suffix(".scope")) continue;
                var group = new Group();
                group.path = slice + "/" + name;
                group.app_id = ids.lookup(name) ?? name.substring(4, name.length - 10);
                group.paused = read_key(group.path + "/cgroup.events", "frozen") == 1;
                group.cpu_usec = read_key(group.path + "/cpu.stat", "usage_usec");
                group.memory = read_number(group.path + "/memory.current");
                group.swapped = read_number(group.path + "/memory.swap.current");
                list += group;
            }
            return list;
        }

        public bool is_paused(string app_id) {
            return available && read_key(scope_path(app_id) + "/cgroup.events", "frozen") == 1;
        }

        public bool can_pause(string app_id) {
            return available && read_key(scope_path(app_id) + "/cgroup.events", "populated") == 1;
        }

        public bool pause(string app_id) {
            if (!can_pause(app_id) || is_paused(app_id)) return false;
            string path = scope_path(app_id);
            if (!write(path + "/cgroup.freeze", "1")) return false;
            message("app-pause: paused %s", app_id);
            changed(app_id, true);
            uint64 memory = read_number(path + "/memory.current");
            if (memory > 0 && FileUtils.test(cgroup_root + path + "/memory.reclaim", FileTest.EXISTS)) {
                string target = cgroup_root + path + "/memory.reclaim";
                new Thread<bool>("app-pause-reclaim", () => {
                    int fd = Posix.open(target, Posix.O_WRONLY | Posix.O_CLOEXEC);
                    if (fd < 0) return false;
                    string amount = memory.to_string();
                    Posix.write(fd, amount, amount.length);
                    Posix.close(fd);
                    return true;
                });
            }
            return true;
        }

        public bool resume(string app_id) {
            if (!is_paused(app_id)) return false;
            if (!write(scope_path(app_id) + "/cgroup.freeze", "0")) return false;
            message("app-pause: resumed %s", app_id);
            changed(app_id, false);
            return true;
        }

        private void prune() {
            foreach (var group in groups()) {
                if (read_key(group.path + "/cgroup.events", "populated") == 0) {
                    DirUtils.remove(cgroup_root + group.path);
                    last_cpu.remove(group.path);
                }
            }
        }

        private double pressure(string resource) {
            string contents;
            try {
                if (!FileUtils.get_contents("/proc/pressure/" + resource, out contents)) return 0;
            } catch (FileError e) {
                return 0;
            }
            foreach (string part in contents.split("\n")[0].split(" ")) {
                if (part.has_prefix("avg10=")) return double.parse(part.substring(6));
            }
            return 0;
        }

        private int hottest() {
            int max = 0;
            for (int i = 0; i < 64; i++) {
                string contents;
                try {
                    if (!FileUtils.get_contents("/sys/class/thermal/thermal_zone%d/temp".printf(i), out contents)) break;
                } catch (FileError e) {
                    break;
                }
                max = int.max(max, int.parse(contents.strip()));
            }
            return max;
        }

        public bool uses_media(string path) {
            return plays_media(path);
        }

        private bool plays_media(string path) {
            string? members = read(path + "/cgroup.procs");
            if (members == null) return false;
            var audio = SystemMonitor.get_default().audio;
            foreach (string line in members.split("\n")) {
                int pid = int.parse(line.strip());
                if (pid <= 0) continue;
                bool muted;
                if (audio != null && audio.find_streams(pid, {}, out muted)) return true;
                try {
                    var fds = Dir.open("%s/%d/fd".printf(procs.proc_root, pid));
                    string? fd;
                    while ((fd = fds.read_name()) != null) {
                        string target = FileUtils.read_link("%s/%d/fd/%s".printf(procs.proc_root, pid, fd));
                        if (target.has_prefix("/dev/video") || target.has_prefix("/dev/snd/")) return true;
                    }
                } catch (FileError e) {}
            }
            return false;
        }

        private void sample() {
            int64 now = get_monotonic_time();
            double elapsed = last_sample == 0 ? 0 : (now - last_sample) / 1000000.0;
            last_sample = now;
            var list = groups();
            foreach (var group in list) {
                uint64? before = last_cpu.lookup(group.path);
                if (before != null && elapsed > 0 && group.cpu_usec >= before)
                    group.core_share = (group.cpu_usec - before) / (elapsed * 1000000.0);
                last_cpu.insert(group.path, group.cpu_usec);
            }

            bool memory_strain = pressure("memory") >= MEMORY_PRESSURE;
            bool cpu_strain = pressure("cpu") >= CPU_PRESSURE || hottest() >= HOT_MILLIDEGREES;
            strained = memory_strain || cpu_strain ? strained + 1 : 0;
            if (strained < SUSTAINED_SAMPLES || now < quiet_until) return;
            if (suggestion != 0 && now < suggested_at + COOLDOWN_US) return;

            string focused = AppSystem.get_default().get_focused_app_id() ?? "";
            Group[] busy = {};
            foreach (var group in list) {
                if (group.paused || scope_name(focused) == scope_name(group.app_id)) continue;
                bool heavy = (cpu_strain && group.core_share >= BUSY_CORE_SHARE)
                    || (memory_strain && group.memory >= BUSY_MEMORY);
                if (heavy && !plays_media(group.path)) busy += group;
            }
            if (busy.length == 0) return;
            for (int i = 0; i < busy.length; i++) {
                for (int j = i + 1; j < busy.length; j++) {
                    bool swap = memory_strain && !cpu_strain
                        ? busy[j].memory > busy[i].memory
                        : busy[j].core_share > busy[i].core_share;
                    if (swap) {
                        var tmp = busy[i];
                        busy[i] = busy[j];
                        busy[j] = tmp;
                    }
                }
            }
            string[] names = {};
            suggested = {};
            for (int i = 0; i < busy.length && i < MAX_SUGGESTED; i++) {
                suggested += busy[i].app_id;
                var info = AppSystem.get_default().resolve_app_for_id(busy[i].app_id);
                names += info != null && info.get_display_name() != null ? info.get_display_name() : busy[i].app_id;
            }
            string title = cpu_strain && !memory_strain
                ? _("The Computer Is Working Hard")
                : _("Memory Is Running Low");
            string body = ngettext("%s is using a lot of resources. Pause it until you need it again?",
                "%s are using a lot of resources. Pause them until you need them again?",
                names.length).printf(string.joinv(", ", names));
            string[] actions = { "pause", ngettext("Pause App", "Pause Apps", names.length), "later", _("Not Now") };
            suggestion = SystemMonitor.get_default().notifications.notify(_("System"), suggestion,
                "media-playback-pause-symbolic", title, body, actions,
                new HashTable<string, Variant>(str_hash, str_equal), -1);
            suggested_at = now;
            strained = 0;
        }
    }
}
