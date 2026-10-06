namespace Singularity {

    [CCode (cname = "prctl", cheader_filename = "sys/prctl.h")]
    private extern int xsettings_prctl(int option, ulong arg);

    public class XSettingsDaemon : GLib.Object {
        private const int PR_SET_PDEATHSIG = 1;
        private const int MAX_QUICK_EXITS = 5;
        private const int64 QUICK_EXIT_USEC = 10 * GLib.TimeSpan.SECOND;
        private const uint RELOAD_DELAY_MS = 150;
        private const int64 STARTUP_GRACE_USEC = GLib.TimeSpan.SECOND;

        private static XSettingsDaemon? instance = null;

        public string config_path { get; construct; }
        public string program { get; construct; }
        public string state_path { get; construct; }

        private GLib.Subprocess? child = null;
        private int64 started_at = 0;
        private int quick_exits = 0;
        private uint restart_source = 0;
        private uint reload_source = 0;
        private bool missing_reported = false;
        private bool stopping = false;

        public signal void child_started(int pid);
        public signal void child_exited(int pid);

        public static XSettingsDaemon get_default() {
            if (instance == null) {
                instance = new XSettingsDaemon(
                    GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".xsettingsd"),
                    "xsettingsd",
                    GLib.Path.build_filename(GLib.Environment.get_user_runtime_dir(),
                        "singularity", "xsettingsd.pid"));
            }
            return instance;
        }

        public XSettingsDaemon(string config_path, string program, string state_path) {
            Object(config_path: config_path, program: program, state_path: state_path);
        }

        public int pid {
            get {
                string? id = child != null ? child.get_identifier() : null;
                return id != null ? int.parse(id) : 0;
            }
        }

        public bool running {
            get { return pid > 0; }
        }

        public static string merge(string existing, string[] drop_prefixes, string[] lines) {
            var body = new GLib.StringBuilder();
            foreach (string line in existing.split("\n")) {
                string clean = line.strip();
                if (clean == "") continue;
                bool drop = false;
                foreach (string prefix in drop_prefixes) {
                    if (clean.has_prefix(prefix)) {
                        drop = true;
                        break;
                    }
                }
                if (drop) continue;
                body.append(line);
                body.append_c('\n');
            }
            foreach (string line in lines) {
                body.append(line);
                body.append_c('\n');
            }
            return body.str;
        }

        public void update(string[] drop_prefixes, string[] lines) throws GLib.Error {
            string existing = "";
            if (GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS))
                GLib.FileUtils.get_contents(config_path, out existing);
            GLib.FileUtils.set_contents(config_path, merge(existing, drop_prefixes, lines));
            reload();
        }

        public void reload() {
            stopping = false;
            if (child == null) {
                quick_exits = 0;
                start();
                return;
            }
            if (reload_source != 0) return;
            int64 age = GLib.get_monotonic_time() - started_at;
            uint delay = RELOAD_DELAY_MS;
            if (age < STARTUP_GRACE_USEC)
                delay = (uint) ((STARTUP_GRACE_USEC - age) / 1000) + RELOAD_DELAY_MS;
            reload_source = GLib.Timeout.add(delay, () => {
                reload_source = 0;
                if (child != null) child.send_signal(Posix.Signal.HUP);
                else start();
                return GLib.Source.REMOVE;
            });
        }

        public void stop() {
            stopping = true;
            if (restart_source != 0) {
                GLib.Source.remove(restart_source);
                restart_source = 0;
            }
            if (reload_source != 0) {
                GLib.Source.remove(reload_source);
                reload_source = 0;
            }
            if (child != null) child.send_signal(Posix.Signal.TERM);
        }

        private void start() {
            if (child != null || stopping) return;
            string? path = GLib.Environment.find_program_in_path(program);
            if (path == null) {
                if (!missing_reported) {
                    message("xsettingsd: %s not found, X11 apps keep their default settings", program);
                    missing_reported = true;
                }
                return;
            }
            if (GLib.Environment.get_variable("DISPLAY") == null) {
                debug("xsettingsd: no DISPLAY yet, settings saved to %s", config_path);
                return;
            }
            end_stale_instance(path);
            try {
                var launcher = new GLib.SubprocessLauncher(
                    GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE);
                launcher.set_child_setup(() => {
                    xsettings_prctl(PR_SET_PDEATHSIG, Posix.Signal.TERM);
                });
                var proc = launcher.spawnv({ path, "-c", config_path });
                child = proc;
                started_at = GLib.get_monotonic_time();
                write_state(pid);
                child_started(pid);
                proc.wait_async.begin(null, (obj, res) => {
                    try { proc.wait_async.end(res); } catch (GLib.Error e) { }
                    on_child_exit(proc);
                });
            } catch (GLib.Error e) {
                warning("xsettingsd: cannot start %s: %s", path, e.message);
            }
        }

        private void on_child_exit(GLib.Subprocess proc) {
            if (child != proc) return;
            int exited_pid = int.parse(proc.get_identifier() ?? "0");
            child = null;
            if (reload_source != 0) {
                GLib.Source.remove(reload_source);
                reload_source = 0;
            }
            clear_state();
            child_exited(exited_pid);
            if (stopping) return;
            if (GLib.get_monotonic_time() - started_at < QUICK_EXIT_USEC) quick_exits++;
            else quick_exits = 0;
            if (quick_exits >= MAX_QUICK_EXITS) {
                warning("xsettingsd: exited %d times in a row, not restarting until the next settings change", quick_exits);
                return;
            }
            uint delay = 500u << int.min(quick_exits, 5);
            restart_source = GLib.Timeout.add(delay, () => {
                restart_source = 0;
                start();
                return GLib.Source.REMOVE;
            });
        }

        private void write_state(int child_pid) {
            try {
                GLib.DirUtils.create_with_parents(GLib.Path.get_dirname(state_path), 0700);
                GLib.FileUtils.set_contents(state_path, "%d\n".printf(child_pid));
            } catch (GLib.Error e) {
                debug("xsettingsd: cannot record pid: %s", e.message);
            }
        }

        private void clear_state() {
            GLib.FileUtils.remove(state_path);
        }

        public static bool owns_process(int candidate, string program_path, string config,
                string? display) {
            if (candidate <= 1 || candidate == Posix.getpid()) return false;
            string proc_dir = "/proc/%d".printf(candidate);
            Posix.Stat st;
            if (Posix.stat(proc_dir, out st) != 0 || st.st_uid != Posix.getuid()) return false;
            uint8[] raw;
            try {
                GLib.FileUtils.get_data(proc_dir + "/cmdline", out raw);
            } catch (GLib.Error e) {
                return false;
            }
            string[] argv = split_nul(raw);
            if (argv.length != 3 || argv[1] != "-c" || argv[2] != config) return false;
            if (GLib.Path.get_basename(argv[0]) != GLib.Path.get_basename(program_path)) return false;
            try {
                GLib.FileUtils.get_data(proc_dir + "/environ", out raw);
            } catch (GLib.Error e) {
                return false;
            }
            string want = "DISPLAY=" + (display ?? "");
            foreach (string entry in split_nul(raw)) {
                if (entry == want) return true;
            }
            return false;
        }

        private static string[] split_nul(uint8[] raw) {
            string[] parts = {};
            int start = 0;
            for (int i = 0; i < raw.length; i++) {
                if (raw[i] != 0) continue;
                parts += (string) (&raw[start]);
                start = i + 1;
            }
            if (start < raw.length) parts += (string) (&raw[start]);
            return parts;
        }

        private void end_stale_instance(string program_path) {
            string contents;
            try {
                if (!GLib.FileUtils.get_contents(state_path, out contents)) return;
            } catch (GLib.Error e) {
                return;
            }
            int stale = int.parse(contents.strip());
            clear_state();
            if (!owns_process(stale, program_path, config_path,
                    GLib.Environment.get_variable("DISPLAY"))) return;
            message("xsettingsd: ending instance %d left by a previous shell", stale);
            Posix.kill((Posix.pid_t) stale, Posix.Signal.TERM);
            for (int i = 0; i < 20 && Posix.kill((Posix.pid_t) stale, 0) == 0; i++)
                GLib.Thread.usleep(25000);
        }
    }
}
