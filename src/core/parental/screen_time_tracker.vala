namespace Singularity {

    public class ScreenTimeTracker : Object {
        private const uint TICK_SECONDS = 15;
        private const int64 MAX_STEP_SECONDS = 60;

        private static ScreenTimeTracker? _instance = null;
        private Parental.UsageStore? _store = null;
        private GLib.Settings settings;
        private string? current_app = null;
        private int64 last_tick = 0;
        private uint tick_id = 0;
        private uint ticks = 0;
        private const int BREAK_IDLE = 6;
        private BreakReminder breaks = new BreakReminder();
        private bool break_idle = false;
        private uint32 reminder_id = 0;

        public signal void changed();

        public static ScreenTimeTracker get_default() {
            if (_instance == null) _instance = new ScreenTimeTracker();
            return _instance;
        }

        private ScreenTimeTracker() {
            settings = new GLib.Settings("dev.sinty.desktop");
        }

        public Parental.UsageStore store {
            get {
                if (_store == null) {
                    _store = Parental.Stores.usage_store_for(Environment.get_user_name(), Environment.get_home_dir());
                }
                return _store;
            }
        }

        public bool recording {
            get { return settings.get_boolean("screen-time-enabled"); }
        }

        public void start() {
            if (tick_id != 0) return;
            var apps = AppSystem.get_default();
            current_app = resolve(apps.get_focused_app_id());
            last_tick = get_monotonic_time();
            settings.changed.connect((key) => {
                if (key.has_prefix("break-reminder-")) configure_breaks();
            });
            configure_breaks();
            apps.app_focused.connect((app_id) => {
                account();
                current_app = resolve(app_id);
            });
            SessionManager.get_default().session_ending.connect(() => {
                account();
                save();
            });
            tick_id = Timeout.add_seconds(TICK_SECONDS, () => {
                account();
                ticks++;
                if (ticks % 4 == 0) save();
                changed();
                return Source.CONTINUE;
            });
            message("ScreenTimeTracker: recording focused app time into %s", Parental.Config.get_default().usage_directory_for(
                Environment.get_user_name(), Environment.get_home_dir()));
        }

        private string? resolve(string? app_id) {
            if (app_id == null || app_id == "") return null;
            var info = AppSystem.get_default().resolve_app_for_id(app_id);
            string id = info != null && info.get_id() != null ? info.get_id() : app_id;
            return Parental.Policy.normalize_app_id(id);
        }

        public static bool session_locked() {
            string uid = "%u".printf((uint) Posix.getuid());
            try {
                var dir = Dir.open("/proc");
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (!name[0].isdigit()) continue;
                    string comm;
                    try {
                        FileUtils.get_contents("/proc/%s/comm".printf(name), out comm);
                    } catch (Error e) {
                        continue;
                    }
                    if (!comm.strip().has_prefix("singularity-loc")) continue;
                    string status;
                    FileUtils.get_contents("/proc/%s/status".printf(name), out status);
                    foreach (string line in status.split("\n")) {
                        if (line.has_prefix("Uid:")) {
                            var parts = line.substring(4).strip().split("\t");
                            if (parts.length > 0 && parts[0] == uid) return true;
                        }
                    }
                }
            } catch (Error e) {
            }
            return false;
        }

        private void account() {
            int64 now = get_monotonic_time();
            int64 elapsed = (now - last_tick) / 1000000;
            if (elapsed <= 0) return;
            last_tick = now;
            bool remind = settings.settings_schema.has_key("break-reminder-enabled")
                && settings.get_boolean("break-reminder-enabled");
            if (!remind && (!recording || current_app == null)) return;
            bool locked = session_locked();
            if (remind) {
                int interval = settings.get_int("break-reminder-minutes") * 60;
                if (breaks.advance(now, !break_idle && !locked, interval)) {
                    var hints = new HashTable<string, Variant>(str_hash, str_equal);
                    reminder_id = SystemMonitor.get_default().notifications.notify(_("Wellbeing"), reminder_id,
                        "singularity-screen-time", _("Time for a Break"),
                        _("You have been using the computer for %d minutes. Step away for a few minutes.").printf(interval / 60),
                        {}, hints, -1);
                }
            }
            if (!recording || current_app == null) return;
            if (IdleManager.get_default().idle_seconds() > 0 || locked) return;
            store.add(Parental.UsageReport.day_key(new DateTime.now_local()), current_app,
                int64.min(elapsed, MAX_STEP_SECONDS));
        }

        private void configure_breaks() {
            breaks.reset();
            break_idle = false;
            IdleNotify.unwatch(BREAK_IDLE);
            if (settings.settings_schema.has_key("break-reminder-enabled")
                    && settings.get_boolean("break-reminder-enabled")) {
                IdleNotify.watch(BREAK_IDLE, 300000, true, on_break_idle, this);
            }
        }

        private static void on_break_idle(int id, bool idle, void* data) {
            var self = (ScreenTimeTracker) data;
            self.break_idle = idle;
            self.breaks.reset();
        }

        public void save() {
            try {
                store.flush();
            } catch (Error e) {
                warning("ScreenTimeTracker: cannot save usage: %s", e.message);
            }
        }

        public int64 today_seconds() {
            account();
            return Parental.UsageReport.total(store.day(Parental.UsageReport.day_key(new DateTime.now_local())));
        }

        public void clear_history() {
            try {
                store.clear();
            } catch (Error e) {
                warning("ScreenTimeTracker: cannot clear usage: %s", e.message);
            }
            changed();
        }
    }
}
