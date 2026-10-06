namespace Singularity.Crash {

    public abstract class CrashSource : Object {
        public signal void crashed(Report report);

        public abstract SourceKind kind { get; }

        public abstract void start();

        public virtual void stop() {
        }

        protected static int current_uid() {
            return (int) Posix.getuid();
        }
    }

    public class SpoolSource : CrashSource {
        private const int REPLAY_SECONDS = 600;

        private Config config;
        private string dir;
        private FileMonitor? monitor = null;
        private FileMonitor? parent_monitor = null;
        private uint scan_id = 0;
        private uint poll_id = 0;
        private HashTable<string, bool> emitted = new HashTable<string, bool>(str_hash, str_equal);

        public override SourceKind kind { get { return SourceKind.HANDLER; } }

        private int64 not_before;

        public SpoolSource(Config config, int64 not_before) {
            this.config = config;
            this.not_before = not_before;
            this.dir = config.user_spool_dir(current_uid());
        }

        public override void start() {
            watch();
            schedule_scan(0);
        }

        public override void stop() {
            if (monitor != null) monitor.cancel();
            if (parent_monitor != null) parent_monitor.cancel();
            if (scan_id != 0) Source.remove(scan_id);
            if (poll_id != 0) Source.remove(poll_id);
            monitor = null;
            parent_monitor = null;
            scan_id = 0;
            poll_id = 0;
        }

        private void watch() {
            if (monitor != null) return;
            var file = File.new_for_path(dir);
            if (FileUtils.test(dir, FileTest.IS_DIR)) {
                try {
                    monitor = file.monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
                    monitor.changed.connect(() => schedule_scan(250));
                    return;
                } catch (Error e) {
                    debug("Crash: cannot watch %s: %s", dir, e.message);
                }
            }
            if (parent_monitor == null && FileUtils.test(config.spool_dir, FileTest.IS_DIR)) {
                try {
                    parent_monitor = File.new_for_path(config.spool_dir).monitor_directory(FileMonitorFlags.NONE, null);
                    parent_monitor.changed.connect(() => {
                        if (FileUtils.test(dir, FileTest.IS_DIR)) {
                            watch();
                            schedule_scan(250);
                        }
                    });
                } catch (Error e) {
                    debug("Crash: cannot watch %s: %s", config.spool_dir, e.message);
                }
            }
            if (poll_id == 0) {
                poll_id = Timeout.add_seconds(10, () => {
                    if (monitor == null) watch();
                    schedule_scan(0);
                    return Source.CONTINUE;
                });
            }
        }

        private void schedule_scan(uint delay) {
            if (scan_id != 0) Source.remove(scan_id);
            scan_id = Timeout.add(delay, () => {
                scan_id = 0;
                scan();
                return Source.REMOVE;
            });
        }

        private void scan() {
            Dir handle;
            try {
                handle = Dir.open(dir);
            } catch (FileError e) {
                return;
            }
            int64 now = get_real_time() / 1000000;
            string? name;
            var found = new GenericArray<Report>();
            while ((name = handle.read_name()) != null) {
                if (!name.has_suffix(".crash")) continue;
                if (emitted.contains(name)) continue;
                var report = Report.from_file(Path.build_filename(dir, name));
                if (report == null) continue;
                emitted.insert(name, true);
                if (report.seen) continue;
                if (report.uid >= 0 && report.uid != current_uid()) continue;
                if (now - report.timestamp > REPLAY_SECONDS || report.timestamp < not_before) continue;
                report.source = SourceKind.HANDLER;
                found.add(report);
            }
            found.sort((a, b) => a.timestamp < b.timestamp ? -1 : (a.timestamp > b.timestamp ? 1 : 0));
            foreach (var report in found) crashed(report);
        }
    }

    public class CoredumpctlSource : CrashSource {
        private const string DEFAULT_DIR = "/var/lib/systemd/coredump";

        private FileMonitor? monitor = null;
        private uint poll_id = 0;
        private uint query_id = 0;
        private int64 since_usec;
        private bool querying = false;

        public override SourceKind kind { get { return SourceKind.COREDUMPCTL; } }

        public CoredumpctlSource() {
            since_usec = get_real_time();
        }

        public static bool available() {
            return Environment.find_program_in_path("coredumpctl") != null;
        }

        private static string storage_dir() {
            string? env = Environment.get_variable("SINGULARITY_COREDUMP_DIR");
            return env != null && env != "" ? env : DEFAULT_DIR;
        }

        public override void start() {
            string path = storage_dir();
            if (FileUtils.test(path, FileTest.IS_DIR)) {
                try {
                    monitor = File.new_for_path(path).monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
                    monitor.changed.connect(() => schedule_query(1500));
                } catch (Error e) {
                    debug("Crash: cannot watch %s: %s", path, e.message);
                }
            }
            poll_id = Timeout.add_seconds(monitor != null ? 60 : 15, () => {
                schedule_query(0);
                return Source.CONTINUE;
            });
        }

        public override void stop() {
            if (monitor != null) monitor.cancel();
            if (poll_id != 0) Source.remove(poll_id);
            if (query_id != 0) Source.remove(query_id);
            monitor = null;
            poll_id = 0;
            query_id = 0;
        }

        private void schedule_query(uint delay) {
            if (query_id != 0) Source.remove(query_id);
            query_id = Timeout.add(delay, () => {
                query_id = 0;
                query.begin();
                return Source.REMOVE;
            });
        }

        private async void query() {
            if (querying) return;
            querying = true;
            string since = "@%lld".printf(since_usec / 1000000);
            string? output = yield Tools.run({ "coredumpctl", "--json=short", "--no-pager", "--no-legend",
                                               "list", "--since=" + since }, 15);
            querying = false;
            if (output == null || output.strip() == "") return;
            var reports = SourceSelection.parse_coredumpctl_json(output, current_uid(), since_usec);
            foreach (var report in reports) {
                if (report.timestamp * 1000000 > since_usec) since_usec = report.timestamp * 1000000;
                crashed(report);
            }
        }
    }

    public class LaunchWatcher : Object {
        private static LaunchWatcher? instance = null;

        public signal void exited(int pid, string app_id, string executable, int signal_number, int64 when);

        public static LaunchWatcher get_default() {
            if (instance == null) instance = new LaunchWatcher();
            return instance;
        }

        public void watch(Pid pid, string app_id, string executable) {
            ChildWatch.add(pid, (child, status) => {
                Process.close_pid(child);
                int sig = 0;
                if (Process.if_signaled(status)) sig = Process.term_sig(status);
                if (sig != 0 && Report.is_crash_signal(sig)) {
                    exited((int) child, app_id, executable, sig, get_real_time() / 1000000);
                }
            });
        }
    }

    public class LauncherSource : CrashSource {
        private ulong handler = 0;

        public override SourceKind kind { get { return SourceKind.LAUNCHER; } }

        public override void start() {
            handler = LaunchWatcher.get_default().exited.connect((pid, app_id, executable, sig, when) => {
                var report = new Report();
                report.source = SourceKind.LAUNCHER;
                report.pid = pid;
                report.uid = current_uid();
                report.app_id = app_id;
                report.executable = executable;
                report.signal_number = sig;
                report.timestamp = when;
                crashed(report);
            });
        }

        public override void stop() {
            if (handler != 0) LaunchWatcher.get_default().disconnect(handler);
            handler = 0;
        }
    }

    public class Tools : Object {
        public static async string? run(string[] argv, int timeout_seconds) {
            Subprocess process;
            try {
                var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE
                                                      | SubprocessFlags.STDIN_INHERIT);
                launcher.unsetenv("DEBUGINFOD_URLS");
                launcher.setenv("LC_ALL", "C", true);
                process = launcher.spawnv(argv);
            } catch (Error e) {
                return null;
            }
            bool expired = false;
            uint timer = Timeout.add_seconds(timeout_seconds, () => {
                expired = true;
                process.force_exit();
                return Source.REMOVE;
            });
            string? stdout_text = null;
            try {
                yield process.communicate_utf8_async(null, null, out stdout_text, null);
            } catch (Error e) {
                stdout_text = null;
            }
            if (!expired) Source.remove(timer);
            return expired && (stdout_text == null || stdout_text == "") ? null : stdout_text;
        }
    }
}
