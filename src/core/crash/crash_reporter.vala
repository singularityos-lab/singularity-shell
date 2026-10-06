namespace Singularity.Crash {

    public class Symbolizer : Object {
        public static async void fill(Report report, Config config) {
            if (report.backtrace != "") return;
            if (report.source == SourceKind.COREDUMPCTL) {
                yield fill_from_coredumpctl(report, config);
                return;
            }
            if (report.core_path == "" || !FileUtils.test(report.core_path, FileTest.IS_REGULAR)) return;
            string tool = config.backtrace_tool;
            bool want_gdb = tool == "auto" || tool == "gdb";
            bool want_eu = tool == "auto" || tool == "eu-stack";
            string? output = null;
            if (want_gdb && Environment.find_program_in_path("gdb") != null) {
                output = yield Tools.run({ "gdb", "-batch", "-nx", "-iex", "set debuginfod enabled off",
                                           "-ex", "set pagination off", "-ex", "thread apply all bt",
                                           report.executable, report.core_path }, config.backtrace_timeout);
                if (output != null && output.contains("#0")) {
                    report.backtrace = Report.trim_backtrace(output);
                    report.backtrace_tool = "gdb";
                }
            }
            if (report.backtrace == "" && want_eu && Environment.find_program_in_path("eu-stack") != null) {
                output = yield Tools.run({ "eu-stack", "-m", "-s", "--core=" + report.core_path,
                                           "--executable=" + report.executable }, config.backtrace_timeout);
                if (output != null && output.contains("#0")) {
                    report.backtrace = Report.trim_backtrace(output);
                    report.backtrace_tool = "eu-stack";
                }
            }
            if (report.backtrace != "" && config.delete_core_after_backtrace) {
                FileUtils.remove(report.core_path);
                report.core_path = "";
            }
            report.mark_seen();
        }

        private static async void fill_from_coredumpctl(Report report, Config config) {
            string? info = yield Tools.run({ "coredumpctl", "--no-pager", "info", report.pid.to_string() },
                                           config.backtrace_timeout);
            if (info != null) {
                string stack = Report.extract_coredumpctl_stack(info);
                if (stack != "") {
                    report.backtrace = Report.trim_backtrace(stack);
                    report.backtrace_tool = "coredumpctl";
                }
            }
        }
    }

    public class Metadata : Object {
        public static void resolve(Report report) {
            DesktopAppInfo? app = find_app(report);
            if (app != null) {
                string id = app.get_id() ?? "";
                if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
                if (id != "") report.app_id = id;
                report.app_name = app.get_display_name() ?? report.app_name;
                string desktop_bug = AppMetadata.sanitize_url(app.get_string("X-Singularity-Bug-Tracker"));
                if (desktop_bug == "") desktop_bug = AppMetadata.sanitize_url(app.get_string("X-Bug-Tracker"));
                report.bug_url = desktop_bug;
                string? desktop_version = app.get_string("X-AppVersion");
                if (desktop_version != null && desktop_version.strip() != "") report.app_version = desktop_version.strip();
            }
            if (report.app_id != "") {
                string? xml = read_metainfo(report.app_id);
                if (xml != null) {
                    string version = AppMetadata.metainfo_version(xml);
                    if (version != "") report.app_version = version;
                    string bug = AppMetadata.metainfo_bug_url(xml);
                    if (bug != "") report.bug_url = bug;
                }
            }
            report.os_name = OsIdentity.load().menu_label();
            var uts = Posix.utsname();
            report.kernel = "%s %s %s".printf(uts.sysname, uts.release, uts.machine);
        }

        public static DesktopAppInfo? find_app(Report report) {
            if (report.app_id != "") {
                var app = new DesktopAppInfo(report.app_id + ".desktop");
                if (app != null) return app;
            }
            if (report.desktop_file != "" && FileUtils.test(report.desktop_file, FileTest.IS_REGULAR)) {
                var app = new DesktopAppInfo.from_filename(report.desktop_file);
                if (app != null) return app;
            }
            if (report.executable == "") return null;
            string exe = report.executable;
            string base_name = Path.get_basename(exe);
            foreach (var info in AppInfo.get_all()) {
                var app = info as DesktopAppInfo;
                if (app == null || app.get_nodisplay()) continue;
                string? program = app.get_executable();
                if (program == null) continue;
                string? resolved = Path.is_absolute(program) ? program : Environment.find_program_in_path(program);
                if (resolved == exe || program == exe) return app;
                if (Path.get_basename(program) == base_name && base_name.length > 2) return app;
            }
            return null;
        }

        private static string? read_metainfo(string app_id) {
            var dirs = new GenericArray<string>();
            dirs.add(Environment.get_user_data_dir());
            foreach (string dir in Environment.get_system_data_dirs()) dirs.add(dir);
            string[] names = {
                "metainfo/%s.metainfo.xml".printf(app_id),
                "metainfo/%s.appdata.xml".printf(app_id),
                "appdata/%s.appdata.xml".printf(app_id),
                "appdata/%s.metainfo.xml".printf(app_id)
            };
            foreach (string dir in dirs) {
                foreach (string name in names) {
                    string path = Path.build_filename(dir, name);
                    string data;
                    try {
                        if (FileUtils.get_contents(path, out data)) return data;
                    } catch (Error e) {
                    }
                }
            }
            return null;
        }

        public static async void fill_package_version(Report report) {
            if (report.app_version != "" || report.executable == "") return;
            string exe = report.executable;
            if (Environment.find_program_in_path("rpm") != null) {
                string? out_text = yield Tools.run({ "rpm", "-qf", "--qf", "%{VERSION}-%{RELEASE}", exe }, 5);
                if (out_text != null && out_text.strip() != "" && !out_text.contains("not owned")) {
                    report.app_version = out_text.strip();
                    return;
                }
            }
            if (Environment.find_program_in_path("dpkg-query") != null) {
                string? owner = yield Tools.run({ "dpkg-query", "-S", exe }, 5);
                if (owner != null && owner.contains(":")) {
                    string pkg = owner.split(":")[0].strip();
                    string? version = yield Tools.run({ "dpkg-query", "-W", "-f", "${Version}", pkg }, 5);
                    if (version != null && version.strip() != "") {
                        report.app_version = version.strip();
                        return;
                    }
                }
            }
            if (Environment.find_program_in_path("pacman") != null) {
                string? owned = yield Tools.run({ "pacman", "-Qo", exe }, 5);
                if (owned != null && owned.contains(" is owned by ")) {
                    var parts = owned.strip().split(" ");
                    if (parts.length >= 2) report.app_version = parts[parts.length - 1];
                }
            }
        }
    }

    public class Reporter : Object {
        private const uint MERGE_DELAY_MS = 2500;
        private const string SCHEMA = "dev.sinty.desktop.crash";

        private static Reporter? instance = null;

        public Config config { get; private set; }
        public SourceKind[] active_kinds { get; private set; }

        private GLib.Settings? settings = null;
        private GenericArray<CrashSource> sources = new GenericArray<CrashSource>();
        private RateLimiter limiter = new RateLimiter();
        private HashTable<int, Report> pending_launcher = new HashTable<int, Report>(direct_hash, direct_equal);
        private HashTable<int, uint> pending_timers = new HashTable<int, uint>(direct_hash, direct_equal);
        private HashTable<string, bool> handled = new HashTable<string, bool>(str_hash, str_equal);
        private HashTable<uint, Report> notified = new HashTable<uint, Report>(direct_hash, direct_equal);
        private bool running = false;
        private bool started_once = false;

        public signal void reported(Report report);

        public static Reporter get_default() {
            if (instance == null) instance = new Reporter();
            return instance;
        }

        private Reporter() {
            config = Config.load();
            active_kinds = {};
            var schema_source = SettingsSchemaSource.get_default();
            if (schema_source != null && schema_source.lookup(SCHEMA, true) != null) {
                settings = new GLib.Settings(SCHEMA);
                settings.changed["enabled"].connect(() => sync());
            }
        }

        public bool watches_launches() {
            if (!running) return false;
            foreach (var kind in active_kinds) if (kind == SourceKind.LAUNCHER) return true;
            return false;
        }

        public bool enabled {
            get { return settings == null || settings.get_boolean("enabled"); }
        }

        public void start() {
            var notifications = SystemMonitor.get_default().notifications;
            notifications.action_invoked.connect((id, action) => {
                var report = notified.lookup(id);
                if (report == null) return;
                if (action == "reopen") reopen(report);
                else if (action == "details" || action == "default") show_details(report);
                else return;
                notified.remove(id);
                SystemMonitor.get_default().notifications.close_notification(id);
            });
            notifications.notification_closed.connect((id, reason) => {
                Timeout.add_seconds(600, () => {
                    notified.remove(id);
                    return Source.REMOVE;
                });
            });
            sync();
        }

        public static SourceKind[] detect(Config config) {
            string pattern = Config.read_core_pattern();
            bool handler = SourceSelection.pattern_uses_handler(pattern)
                || FileUtils.test(config.user_spool_dir((int) Posix.getuid()), FileTest.IS_DIR);
            bool coredump = SourceSelection.pattern_uses_coredump(pattern) && CoredumpctlSource.available();
            return SourceSelection.select(config.sources, handler, coredump);
        }

        private void sync() {
            if (enabled && !running) {
                running = true;
                active_kinds = detect(config);
                foreach (var kind in active_kinds) {
                    CrashSource source;
                    switch (kind) {
                        case SourceKind.HANDLER:
                            source = new SpoolSource(config, started_once ? get_real_time() / 1000000 : 0);
                            break;
                        case SourceKind.COREDUMPCTL: source = new CoredumpctlSource(); break;
                        default: source = new LauncherSource(); break;
                    }
                    source.crashed.connect(on_crashed);
                    sources.add(source);
                    source.start();
                }
                started_once = true;
                string[] names = {};
                foreach (var kind in active_kinds) names += kind.id();
                message("Crash reporter: sources %s", string.joinv(",", names));
            } else if (!enabled && running) {
                running = false;
                foreach (var source in sources) source.stop();
                sources = new GenericArray<CrashSource>();
                active_kinds = {};
                message("Crash reporter: off");
            }
        }

        private void on_crashed(Report report) {
            if (!enabled) return;
            if (handled.contains(report.key())) return;
            if (report.source == SourceKind.LAUNCHER) {
                pending_launcher.insert(report.pid, report);
                uint timer = Timeout.add(MERGE_DELAY_MS, () => {
                    pending_timers.remove(report.pid);
                    var held = pending_launcher.lookup(report.pid);
                    if (held == null) return Source.REMOVE;
                    pending_launcher.remove(report.pid);
                    process.begin(held);
                    return Source.REMOVE;
                });
                pending_timers.insert(report.pid, timer);
                return;
            }
            var launcher = pending_launcher.lookup(report.pid);
            if (launcher != null) {
                if (report.app_id == "") report.app_id = launcher.app_id;
                pending_launcher.remove(report.pid);
                uint timer = pending_timers.lookup(report.pid);
                if (timer != 0) Source.remove(timer);
                pending_timers.remove(report.pid);
            }
            process.begin(report);
        }

        private async void process(Report report) {
            if (handled.contains(report.key())) return;
            handled.insert(report.key(), true);
            Metadata.resolve(report);
            bool known = report.app_name != "";
            message("Crash reporter: %s pid %d signal %d from %s", report.display_name(), report.pid,
                    report.signal_number, report.source.id());
            if (!known && !config.notify_unknown) {
                report.mark_seen();
                return;
            }
            yield Metadata.fill_package_version(report);
            var verdict = limiter.check(report.app_id != "" ? report.app_id : report.executable, get_real_time() / 1000000);
            report.mark_seen();
            reported(report);
            if (verdict == RateLimiter.Verdict.SUPPRESS) {
                message("Crash reporter: notification for %s rate limited", report.display_name());
                return;
            }
            string name = report.display_name();
            string summary;
            string body;
            string[] actions;
            if (verdict == RateLimiter.Verdict.REPEATED) {
                summary = _("%s keeps quitting unexpectedly").printf(name);
                body = _("It quit several times in the last few minutes. Details show what went wrong.");
                actions = { "default", _("Details"), "details", _("Details") };
            } else {
                summary = _("%s quit unexpectedly").printf(name);
                body = _("Nothing was sent anywhere. Details show what went wrong.");
                actions = { "default", _("Details"), "reopen", _("Reopen"), "details", _("Details") };
            }
            var hints = new HashTable<string, Variant>(str_hash, str_equal);
            hints.insert("urgency", new Variant.byte(1));
            hints.insert("category", new Variant.string("x-singularity.crash"));
            string icon = "dialog-warning";
            var app = Metadata.find_app(report);
            if (app != null && app.get_icon() != null) icon = app.get_icon().to_string();
            uint id = SystemMonitor.get_default().notifications.notify(_("Crash Reports"), 0, icon,
                summary, body, actions, hints, -1);
            notified.insert(id, report);
        }

        public void reopen(Report report) {
            var app = Metadata.find_app(report);
            if (app != null) AppSystem.launch_app(app);
        }

        public void show_details(Report report) {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app != null) {
                foreach (unowned Gtk.Window window in app.get_windows()) {
                    var sidebar = window as Singularity.Sidebar;
                    if (sidebar != null) sidebar.dismiss();
                }
            }
            var window = new Singularity.Shell.CrashDetailsWindow(report, config);
            window.open_dialog();
        }

        public string describe_sources() {
            var kinds = running ? active_kinds : detect(config);
            foreach (var kind in kinds) {
                if (kind == SourceKind.HANDLER) return _("Collected by the Singularity crash handler, with backtraces.");
                if (kind == SourceKind.COREDUMPCTL) return _("Collected by systemd-coredump, with backtraces.");
            }
            foreach (var kind in kinds) {
                if (kind == SourceKind.LAUNCHER) return _("Only apps opened from the desktop are noticed, without backtraces.");
            }
            return _("No crash data is collected on this system.");
        }

        public int clear_user_reports() {
            string dir = config.user_spool_dir((int) Posix.getuid());
            int removed = 0;
            Dir handle;
            try {
                handle = Dir.open(dir);
            } catch (FileError e) {
                return 0;
            }
            string? name;
            var names = new GenericArray<string>();
            while ((name = handle.read_name()) != null) {
                if (name.has_suffix(".crash") || name.has_suffix(".core")) names.add(name);
            }
            foreach (string entry in names) {
                if (FileUtils.remove(Path.build_filename(dir, entry)) == 0) removed++;
            }
            return removed;
        }
    }
}
