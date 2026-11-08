namespace Singularity {

    [CCode (cname = "syscall", cheader_filename = "unistd.h,sys/syscall.h")]
    private extern long app_lifecycle_syscall(long number, int which, int who, int ioprio);
    [CCode (cname = "SYS_ioprio_set", cheader_filename = "sys/syscall.h")]
    private extern const long SYS_IOPRIO_SET;

    public enum AppState {
        FOREGROUND,
        BACKGROUND_ACTIVE,
        BACKGROUND_IDLE,
        SUSPENDED
    }

    public class AppLifecycle : Object {
        private const uint SAMPLE_SECONDS = 30;
        private const int64 RECLAIM_AFTER_US = 60 * 1000000LL;
        private const int64 FREEZE_AFTER_US = 10 * 60 * 1000000LL;
        private const int QUIET_SAMPLES = 3;
        private const double ACTIVE_CORE_SHARE = 0.02;
        private const uint64 ACTIVE_IO_BYTES_PER_SECOND = 64 * 1024;
        private const int IOPRIO_WHO_PROCESS = 1;
        private const int IOPRIO_IDLE_CLASS = 3 << 13;

        private class Entry {
            public string app_id;
            public int64 hidden_since;
            public bool reclaimed;
            public AppState cls = AppState.FOREGROUND;
            public uint64 cpu_usec;
            public uint64 io_bytes;
            public int64 sampled_at;
            public int quiet;
            public bool measured;
            public bool frozen_by_us;
        }

        public signal void changed();

        private static AppLifecycle? instance = null;
        private string cgroup_root;
        private string proc_root;
        private string flag;
        private string list;
        private GLib.Settings settings;
        private FileMonitor? monitor = null;
        private uint sample_source = 0;
        private HashTable<string, Entry> entries = new HashTable<string, Entry>(str_hash, str_equal);
        private bool active = false;

        public static AppLifecycle get_default() {
            if (instance == null) instance = new AppLifecycle();
            return instance;
        }

        public AppLifecycle(string cgroup_root = "/sys/fs/cgroup", string proc_root = "/proc") {
            this.cgroup_root = cgroup_root;
            this.proc_root = proc_root;
            string dir = Path.build_filename(Environment.get_user_runtime_dir(), "singularity");
            flag = Path.build_filename(dir, "background-apps");
            list = Path.build_filename(dir, "background-apps.list");
        }

        public bool saving {
            get {
                return IdleManager.get_default().on_battery
                    || SystemMonitor.get_default().power_profiles.active_profile == "power-saver";
            }
        }

        public bool is_lowered(string path) {
            Entry? entry = entries.lookup(path);
            return entry != null && entry.cls == AppState.BACKGROUND_IDLE;
        }

        public AppState class_of(string path) {
            Entry? entry = entries.lookup(path);
            return entry != null ? entry.cls : AppState.FOREGROUND;
        }

        public string? continuous_work() {
            var pause = AppPause.get_default();
            foreach (var group in pause.groups()) {
                if (group.paused) continue;
                if (pause.uses_media(group.path)) return "%s is playing media".printf(group.app_id);
                Entry? entry = entries.lookup(group.path);
                if (entry != null && entry.cls == AppState.BACKGROUND_ACTIVE) return "%s is working in the background".printf(group.app_id);
            }
            string load;
            try {
                if (FileUtils.get_contents(proc_root + "/loadavg", out load) && double.parse(load.split(" ")[0]) >= 1.5)
                    return "the processor is busy";
            } catch (FileError e) {}
            return null;
        }

        public void start() {
            if (!AppPause.get_default().available) return;
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["background-apps"].connect(update);
            IdleManager.get_default().notify["on-battery"].connect(update);
            SystemMonitor.get_default().power_profiles.profile_changed.connect(update);
            AppPause.get_default().changed.connect((app_id, paused) => {
                if (!paused) {
                    foreach (var entry in entries.get_values()) {
                        if (entry.app_id == app_id) entry.frozen_by_us = false;
                    }
                }
            });
            DirUtils.create_with_parents(Path.get_dirname(list), 0700);
            try {
                monitor = File.new_for_path(list).monitor_file(FileMonitorFlags.WATCH_MOVES, null);
                monitor.changed.connect((file, other, event) => {
                    if (active) apply();
                });
            } catch (Error e) {
                warning("app-lifecycle: cannot watch %s: %s", list, e.message);
            }
            update();
        }

        private void update() {
            bool want = settings.get_boolean("background-apps") || saving;
            if (want) {
                try {
                    FileUtils.set_contents(flag, "");
                } catch (FileError e) {
                    warning("app-lifecycle: %s", e.message);
                }
                active = true;
                apply();
            } else {
                FileUtils.unlink(flag);
                active = false;
                foreach (string path in entries.get_keys()) release(path, entries.lookup(path));
                entries.remove_all();
                if (sample_source != 0) {
                    Source.remove(sample_source);
                    sample_source = 0;
                }
                changed();
            }
            message("app-lifecycle: %s (%s)", active ? "on" : "off", saving ? "saving power" : "on mains");
        }

        private GenericSet<string> hidden_groups() {
            var hidden = new GenericSet<string>(str_hash, str_equal);
            string contents;
            try {
                if (FileUtils.get_contents(list, out contents)) {
                    foreach (string line in contents.split("\n")) {
                        if (line.strip() != "") hidden.add(line.strip());
                    }
                }
            } catch (FileError e) {}
            return hidden;
        }

        private void apply() {
            var hidden = hidden_groups();
            var pause = AppPause.get_default();
            var current = new GenericSet<string>(str_hash, str_equal);
            int64 now = get_monotonic_time();
            bool any_change = false;
            foreach (var group in pause.groups()) {
                current.add(group.path);
                Entry? entry = entries.lookup(group.path);
                if (!hidden.contains(group.path)) {
                    if (entry != null) {
                        release(group.path, entry);
                        entries.remove(group.path);
                        message("app-lifecycle: %s back in the foreground", group.app_id);
                        any_change = true;
                    }
                    continue;
                }
                if (entry == null) {
                    entry = new Entry();
                    entry.app_id = group.app_id;
                    entry.hidden_since = now;
                    entry.cpu_usec = group.cpu_usec;
                    entry.io_bytes = io_bytes(group.path);
                    entry.sampled_at = now;
                    entries.insert(group.path, entry);
                    any_change = true;
                }
                if (group.paused) continue;
                AppState next = pause.uses_media(group.path) || (entry.measured && entry.quiet == 0)
                    ? AppState.BACKGROUND_ACTIVE : AppState.BACKGROUND_IDLE;
                if (next != entry.cls) {
                    set_class(group.path, entry, next);
                    any_change = true;
                }
                if (entry.cls == AppState.BACKGROUND_IDLE && !entry.reclaimed && now - entry.hidden_since >= RECLAIM_AFTER_US) {
                    entry.reclaimed = true;
                    reclaim(group.path, group.memory / 4);
                }
            }
            foreach (string path in entries.get_keys()) {
                if (!current.contains(path)) {
                    entries.remove(path);
                    any_change = true;
                }
            }
            if (entries.size() > 0 && sample_source == 0) {
                sample_source = Timeout.add_seconds(SAMPLE_SECONDS, () => {
                    sample();
                    return Source.CONTINUE;
                });
            } else if (entries.size() == 0 && sample_source != 0) {
                Source.remove(sample_source);
                sample_source = 0;
            }
            if (any_change) changed();
        }

        private void sample() {
            var pause = AppPause.get_default();
            int64 now = get_monotonic_time();
            foreach (var group in pause.groups()) {
                Entry? entry = entries.lookup(group.path);
                if (entry == null || group.paused) continue;
                double secs = (now - entry.sampled_at) / 1000000.0;
                uint64 io = io_bytes(group.path);
                bool busy = false;
                if (secs > 0) {
                    double share = group.cpu_usec >= entry.cpu_usec ? (group.cpu_usec - entry.cpu_usec) / (secs * 1000000.0) : 0;
                    double rate = io >= entry.io_bytes ? (io - entry.io_bytes) / secs : 0;
                    busy = share >= ACTIVE_CORE_SHARE || rate >= ACTIVE_IO_BYTES_PER_SECOND;
                }
                entry.cpu_usec = group.cpu_usec;
                entry.io_bytes = io;
                entry.sampled_at = now;
                entry.measured = true;
                entry.quiet = busy ? 0 : entry.quiet + 1;
            }
            apply();
            consider_freezing.begin();
        }

        private async void consider_freezing() {
            if (!saving) return;
            int64 now = get_monotonic_time();
            var pause = AppPause.get_default();
            foreach (string path in entries.get_keys()) {
                Entry? entry = entries.lookup(path);
                if (entry == null || entry.cls != AppState.BACKGROUND_IDLE) continue;
                if (now - entry.hidden_since < FREEZE_AFTER_US || entry.quiet < QUIET_SAMPLES) continue;
                if (pause.uses_media(path) || holds_connections(path) || yield holds_inhibitor(path)) continue;
                if (pause.pause(entry.app_id)) {
                    entry.frozen_by_us = true;
                    entry.cls = AppState.SUSPENDED;
                    message("app-lifecycle: %s suspended after %d minutes in the background",
                        entry.app_id, (int) ((now - entry.hidden_since) / 60000000));
                    changed();
                }
            }
        }

        private void set_class(string path, Entry entry, AppState cls) {
            entry.cls = cls;
            switch (cls) {
                case AppState.BACKGROUND_IDLE:
                    write(path + "/cpu.weight", "10");
                    write(path + "/cpu.uclamp.max", "25");
                    write(path + "/io.weight", "default 10");
                    set_ioprio(path, IOPRIO_IDLE_CLASS);
                    message("app-lifecycle: %s idle in the background", entry.app_id);
                    break;
                case AppState.BACKGROUND_ACTIVE:
                    write(path + "/cpu.weight", "50");
                    write(path + "/cpu.uclamp.max", "max");
                    write(path + "/io.weight", "default 50");
                    set_ioprio(path, 0);
                    message("app-lifecycle: %s working in the background", entry.app_id);
                    break;
                default:
                    break;
            }
        }

        private void release(string path, Entry? entry) {
            write(path + "/cpu.weight", "100");
            write(path + "/cpu.uclamp.max", "max");
            write(path + "/io.weight", "default 100");
            set_ioprio(path, 0);
            if (entry != null && entry.frozen_by_us) {
                AppPause.get_default().resume(entry.app_id);
                entry.frozen_by_us = false;
            }
        }

        private int[] members(string path) {
            int[] pids = {};
            string contents;
            try {
                if (!FileUtils.get_contents(cgroup_root + path + "/cgroup.procs", out contents)) return pids;
            } catch (FileError e) {
                return pids;
            }
            foreach (string line in contents.split("\n")) {
                int pid = int.parse(line.strip());
                if (pid > 0) pids += pid;
            }
            return pids;
        }

        private bool holds_connections(string path) {
            var sockets = new GenericSet<string>(str_hash, str_equal);
            foreach (int pid in members(path)) {
                try {
                    var fds = Dir.open("%s/%d/fd".printf(proc_root, pid));
                    string? fd;
                    while ((fd = fds.read_name()) != null) {
                        string target = FileUtils.read_link("%s/%d/fd/%s".printf(proc_root, pid, fd));
                        if (target.has_prefix("socket:[")) sockets.add(target.substring(8, target.length - 9));
                    }
                } catch (FileError e) {}
            }
            if (sockets.length == 0) return false;
            foreach (string table in new string[] { "tcp", "tcp6" }) {
                string contents;
                try {
                    if (!FileUtils.get_contents("%s/net/%s".printf(proc_root, table), out contents)) continue;
                } catch (FileError e) {
                    continue;
                }
                foreach (string line in contents.split("\n")) {
                    string[] f = line.strip().split_set(" \t");
                    string[] cols = {};
                    foreach (string c in f) if (c != "") cols += c;
                    if (cols.length < 10 || cols[3] != "01") continue;
                    if (loopback(cols[2])) continue;
                    if (sockets.contains(cols[9])) return true;
                }
            }
            return false;
        }

        private static bool loopback(string remote) {
            string addr = remote.split(":")[0];
            if (addr.length == 8) return addr.has_suffix("7F");
            return addr == "00000000000000000000000001000000"
                || (addr.has_prefix("0000000000000000FFFF0000") && addr.has_suffix("7F"));
        }

        private async bool holds_inhibitor(string path) {
            var pids = new GenericSet<uint>(direct_hash, direct_equal);
            foreach (int pid in members(path)) pids.add((uint) pid);
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var reply = yield bus.call("org.freedesktop.login1", "/org/freedesktop/login1",
                    "org.freedesktop.login1.Manager", "ListInhibitors", null,
                    new VariantType("(a(ssssuu))"), DBusCallFlags.NONE, 2000);
                var iter = reply.get_child_value(0).iterator();
                string what, who, why, mode;
                uint uid, pid;
                while (iter.next("(ssssuu)", out what, out who, out why, out mode, out uid, out pid)) {
                    if (pids.contains(pid)) return true;
                }
            } catch (Error e) {
                return true;
            }
            return false;
        }

        private uint64 io_bytes(string path) {
            string contents;
            uint64 total = 0;
            try {
                if (!FileUtils.get_contents(cgroup_root + path + "/io.stat", out contents)) return 0;
            } catch (FileError e) {
                return 0;
            }
            foreach (string line in contents.split("\n")) {
                foreach (string part in line.split(" ")) {
                    if (part.has_prefix("rbytes=")) total += uint64.parse(part.substring(7));
                    else if (part.has_prefix("wbytes=")) total += uint64.parse(part.substring(7));
                }
            }
            return total;
        }

        private void set_ioprio(string path, int ioprio) {
            string threads;
            try {
                if (!FileUtils.get_contents(cgroup_root + path + "/cgroup.threads", out threads)) return;
            } catch (FileError e) {
                return;
            }
            foreach (string line in threads.split("\n")) {
                int tid = int.parse(line.strip());
                if (tid > 0) app_lifecycle_syscall(SYS_IOPRIO_SET, IOPRIO_WHO_PROCESS, tid, ioprio);
            }
        }

        private void reclaim(string path, uint64 amount) {
            if (amount < 16 * 1024 * 1024) return;
            string target = cgroup_root + path + "/memory.reclaim";
            if (!FileUtils.test(target, FileTest.EXISTS)) return;
            new Thread<bool>("background-reclaim", () => {
                int fd = Posix.open(target, Posix.O_WRONLY | Posix.O_CLOEXEC);
                if (fd < 0) return false;
                string value = amount.to_string();
                Posix.write(fd, value, value.length);
                Posix.close(fd);
                return true;
            });
        }

        private bool write(string relative, string value) {
            int fd = Posix.open(cgroup_root + relative, Posix.O_WRONLY | Posix.O_CLOEXEC);
            if (fd < 0) return false;
            bool ok = Posix.write(fd, value, value.length) == value.length;
            Posix.close(fd);
            return ok;
        }
    }
}
