namespace Singularity {

    [CCode (cname = "syscall", cheader_filename = "unistd.h,sys/syscall.h")]
    private extern long app_background_syscall(long number, int which, int who, int ioprio);
    [CCode (cname = "SYS_ioprio_set", cheader_filename = "sys/syscall.h")]
    private extern const long SYS_IOPRIO_SET;

    public class AppBackground : Object {
        private const uint POLL_SECONDS = 2;
        private const int64 RECLAIM_AFTER_US = 60 * 1000000LL;
        private const int IOPRIO_WHO_PROCESS = 1;
        private const int IOPRIO_IDLE_CLASS = 3 << 13;

        private class Entry {
            public int64 since;
            public bool reclaimed;
        }

        private static AppBackground? instance = null;
        private string cgroup_root;
        private string proc_root;
        private string flag;
        private string list;
        private GLib.Settings settings;
        private uint poll = 0;
        private HashTable<string, Entry> lowered = new HashTable<string, Entry>(str_hash, str_equal);

        public static AppBackground get_default() {
            if (instance == null) instance = new AppBackground();
            return instance;
        }

        public AppBackground(string cgroup_root = "/sys/fs/cgroup", string proc_root = "/proc") {
            this.cgroup_root = cgroup_root;
            this.proc_root = proc_root;
            string dir = Path.build_filename(Environment.get_user_runtime_dir(), "singularity");
            flag = Path.build_filename(dir, "background-apps");
            list = Path.build_filename(dir, "background-apps.list");
        }

        public bool is_lowered(string path) {
            return lowered.contains(path);
        }

        public void start() {
            if (!AppPause.get_default().available) return;
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["background-apps"].connect(update);
            update();
        }

        private void update() {
            bool enabled = settings.get_boolean("background-apps");
            if (enabled) {
                DirUtils.create_with_parents(Path.get_dirname(flag), 0700);
                try {
                    FileUtils.set_contents(flag, "");
                } catch (FileError e) {
                    warning("background-apps: %s", e.message);
                }
                if (poll == 0) poll = Timeout.add_seconds(POLL_SECONDS, () => {
                    apply();
                    return Source.CONTINUE;
                });
                apply();
            } else {
                FileUtils.unlink(flag);
                if (poll != 0) {
                    Source.remove(poll);
                    poll = 0;
                }
                foreach (string path in lowered.get_keys()) restore(path);
                lowered.remove_all();
            }
        }

        private void apply() {
            var hidden = new GenericSet<string>(str_hash, str_equal);
            string contents;
            try {
                if (FileUtils.get_contents(list, out contents)) {
                    foreach (string line in contents.split("\n")) {
                        if (line.strip() != "") hidden.add(line.strip());
                    }
                }
            } catch (FileError e) {}

            var pause = AppPause.get_default();
            var current = new GenericSet<string>(str_hash, str_equal);
            int64 now = get_monotonic_time();
            foreach (var group in pause.groups()) {
                current.add(group.path);
                bool wanted = hidden.contains(group.path) && !group.paused && !pause.uses_media(group.path);
                Entry? entry = lowered.lookup(group.path);
                if (wanted && entry == null) {
                    lower(group.path);
                    entry = new Entry();
                    entry.since = now;
                    lowered.insert(group.path, entry);
                    message("background-apps: %s moved to the background", group.app_id);
                } else if (!wanted && entry != null) {
                    restore(group.path);
                    lowered.remove(group.path);
                    message("background-apps: %s back in the foreground", group.app_id);
                    continue;
                }
                if (entry != null && !entry.reclaimed && now - entry.since >= RECLAIM_AFTER_US) {
                    entry.reclaimed = true;
                    reclaim(group.path, group.memory / 4);
                }
            }
            foreach (string path in lowered.get_keys()) {
                if (!current.contains(path)) lowered.remove(path);
            }
        }

        private void lower(string path) {
            write(path + "/cpu.weight", "10");
            write(path + "/cpu.uclamp.max", "25");
            write(path + "/io.weight", "default 10");
            set_ioprio(path, IOPRIO_IDLE_CLASS);
        }

        private void restore(string path) {
            write(path + "/cpu.weight", "100");
            write(path + "/cpu.uclamp.max", "max");
            write(path + "/io.weight", "default 100");
            set_ioprio(path, 0);
        }

        private void set_ioprio(string path, int ioprio) {
            string members;
            try {
                if (!FileUtils.get_contents(cgroup_root + path + "/cgroup.threads", out members)) return;
            } catch (FileError e) {
                return;
            }
            foreach (string line in members.split("\n")) {
                int tid = int.parse(line.strip());
                if (tid > 0) app_background_syscall(SYS_IOPRIO_SET, IOPRIO_WHO_PROCESS, tid, ioprio);
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
