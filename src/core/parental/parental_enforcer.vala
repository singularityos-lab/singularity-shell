namespace Singularity {

    public class ParentalEnforcer : Object {
        private const uint CHECK_SECONDS = 20;
        private const int64 RELOCK_SECONDS = 60;

        private static ParentalEnforcer? _instance = null;
        private Parental.FilePolicyStore store;
        private Parental.Policy _policy;
        private string policy_data = "";
        private uint check_id = 0;
        private string warned_key = "";
        private string stopped_key = "";
        private int64 last_lock = 0;

        public signal void policy_changed();

        public static ParentalEnforcer get_default() {
            if (_instance == null) _instance = new ParentalEnforcer();
            return _instance;
        }

        private ParentalEnforcer() {
            var config = Parental.Config.get_default();
            store = new Parental.FilePolicyStore(config.policy_directory, config.write_command);
            _policy = store.load(Environment.get_user_name());
            policy_data = _policy.to_data();
        }

        public Parental.Policy policy {
            get { return _policy; }
        }

        public bool hides(string? app_id) {
            return _policy.blocks_app(app_id);
        }

        public bool allows(AppInfo? info) {
            if (info == null) return true;
            if (!_policy.blocks_app(info.get_id())) return true;
            notify_denied(info.get_display_name());
            return false;
        }

        public bool allows_command(string command) {
            if (_policy.blocked_apps.length == 0) return true;
            string[] argv;
            try {
                GLib.Shell.parse_argv(command, out argv);
            } catch (Error e) {
                return true;
            }
            if (argv.length == 0) return true;
            string name = Path.get_basename(argv[0]);
            foreach (string id in _policy.blocked_apps) {
                var info = new DesktopAppInfo(id + ".desktop");
                if (info == null) continue;
                string? exe = info.get_executable();
                if (exe != null && Path.get_basename(exe) == name) {
                    notify_denied(info.get_display_name());
                    return false;
                }
            }
            return true;
        }

        private void notify_denied(string app_name) {
            message("ParentalEnforcer: launch of %s denied by parental controls", app_name);
            send(_("App Not Allowed"), _("%s is blocked by parental controls on this account.").printf(app_name));
        }

        private void send(string summary, string body) {
            var hints = new HashTable<string, Variant>(str_hash, str_equal);
            hints.insert("urgency", new Variant.byte(1));
            SystemMonitor.get_default().notifications.notify(_("Parental Controls"), 0,
                "preferences-system-time-symbolic", summary, body, {}, hints, -1);
        }

        public void start() {
            if (check_id != 0) return;
            AppSystem.get_default().app_opened.connect((handle, app_id) => {
                var info = AppSystem.get_default().resolve_app_for_id(app_id);
                string id = info != null && info.get_id() != null ? info.get_id() : app_id;
                if (!_policy.blocks_app(id) && !_policy.blocks_app(app_id)) return;
                message("ParentalEnforcer: closing a window of blocked app %s", app_id);
                Singularity.close_window(handle);
                notify_denied(info != null ? info.get_display_name() : app_id);
            });
            check_id = Timeout.add_seconds(CHECK_SECONDS, () => {
                check();
                return Source.CONTINUE;
            });
            Idle.add(() => {
                check();
                return Source.REMOVE;
            });
            message("ParentalEnforcer: policy for %s is %s", Environment.get_user_name(),
                _policy.is_active ? "active" : "not set");
        }

        public void reload() {
            var fresh = store.load(Environment.get_user_name());
            string data = fresh.to_data();
            if (data == policy_data) return;
            policy_data = data;
            _policy = fresh;
            message("ParentalEnforcer: policy reloaded, %d blocked apps", _policy.blocked_apps.length);
            policy_changed();
        }

        private void check() {
            reload();
            if (_policy.daily_limit_minutes <= 0 && !_policy.bedtime_enabled) return;
            var now = new DateTime.now_local();
            int minute = now.get_hour() * 60 + now.get_minute();
            int64 used = ScreenTimeTracker.get_default().today_seconds();
            var verdict = _policy.evaluate(minute, used);
            string day = Parental.UsageReport.day_key(now);
            switch (verdict) {
                case Parental.Verdict.WARNING:
                    string key = day + (_policy.in_bedtime(minute + _policy.warning_minutes) ? "-bed" : "-limit");
                    if (warned_key == key) break;
                    warned_key = key;
                    int64 left = _policy.seconds_left(used);
                    int bed = _policy.minutes_until_bedtime(minute);
                    int minutes = left >= 0 ? (int) ((left + 59) / 60) : bed;
                    if (bed > 0 && (minutes < 0 || bed < minutes)) minutes = bed;
                    message("ParentalEnforcer: %d minutes of screen time left", minutes);
                    send(_("Screen Time Almost Up"),
                        ngettext("%d minute left. Save your work.", "%d minutes left. Save your work.", minutes).printf(minutes));
                    break;
                case Parental.Verdict.LIMIT_REACHED:
                case Parental.Verdict.BEDTIME:
                    string reason = verdict == Parental.Verdict.BEDTIME ? "bedtime" : "limit";
                    if (stopped_key != day + reason) {
                        stopped_key = day + reason;
                        send(verdict == Parental.Verdict.BEDTIME ? _("It's Bedtime") : _("Screen Time Is Up"),
                            _("The screen locks now. An administrator can change the limits in Settings."));
                    }
                    int64 mono = get_monotonic_time() / 1000000;
                    if (last_lock != 0 && mono - last_lock < RELOCK_SECONDS) break;
                    if (ScreenTimeTracker.session_locked()) break;
                    last_lock = mono;
                    message("ParentalEnforcer: locking the session (%s)", reason);
                    SessionManager.get_default().lock_screen();
                    break;
                default:
                    break;
            }
        }
    }
}
