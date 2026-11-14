namespace Singularity {

    public interface SessionLocker : Object {
        public abstract void lock_session();
        public abstract bool is_locked();
    }

    public delegate bool LockOnSuspendFunc();

    public class LockClientProbe : Object {
        public static bool running(Posix.uid_t uid, Posix.pid_t self_pid) {
            Dir dir;
            try {
                dir = Dir.open("/proc");
            } catch (FileError e) {
                return false;
            }
            string? name;
            while ((name = dir.read_name()) != null) {
                if (name[0] < '0' || name[0] > '9') continue;
                if ((Posix.pid_t) int.parse(name) == self_pid) continue;
                string base_path = "/proc/" + name;
                Posix.Stat st;
                if (Posix.stat(base_path, out st) != 0 || st.st_uid != uid) continue;
                string argv0;
                try {
                    if (!FileUtils.get_contents(base_path + "/cmdline", out argv0) || argv0 == "") continue;
                } catch (FileError e) {
                    continue;
                }
                if (Path.get_basename(argv0).has_prefix("singularity-lockscreen")) return true;
            }
            return false;
        }
    }

    public class LogindLockListener : Object {
        public const string BUS_NAME = "org.freedesktop.login1";
        public const string MANAGER_PATH = "/org/freedesktop/login1";
        public const string MANAGER_IFACE = "org.freedesktop.login1.Manager";
        public const string SESSION_IFACE = "org.freedesktop.login1.Session";

        public int64 repeat_guard_us = 2 * 1000000;
        public uint poll_ms = 100;
        public uint settle_ms = 500;
        public uint sleep_wait_max_ms = 3000;

        private DBusConnection bus;
        private SessionLocker locker;
        private LockOnSuspendFunc lock_on_suspend;
        private uint session_sub = 0;
        private uint manager_sub = 0;
        private int inhibit_fd = -1;
        private bool sleeping = false;
        private uint sleep_wait = 0;
        private int64 last_request = 0;
        private bool stopped = false;

        public string? session_path { get; private set; default = null; }
        public bool inhibitor_held { get { return inhibit_fd >= 0; } }

        public uint lock_requests { get; private set; default = 0; }
        public uint locks_skipped { get; private set; default = 0; }

        public signal void inhibitor_released();
        public signal void inhibitor_taken();

        public LogindLockListener(DBusConnection bus, SessionLocker locker, owned LockOnSuspendFunc lock_on_suspend) {
            this.bus = bus;
            this.locker = locker;
            this.lock_on_suspend = (owned) lock_on_suspend;
        }

        ~LogindLockListener() {
            stop();
        }

        public async bool start() {
            stopped = false;
            session_path = yield resolve_session();
            if (stopped) return false;
            if (session_path == null) {
                warning("LogindLock: no logind session for this shell; loginctl lock-session will not lock");
            } else {
                session_sub = bus.signal_subscribe(BUS_NAME, SESSION_IFACE, null, session_path, null,
                    DBusSignalFlags.NONE, on_session_signal);
                message("LogindLock: following %s", session_path);
            }
            manager_sub = bus.signal_subscribe(BUS_NAME, MANAGER_IFACE, "PrepareForSleep", MANAGER_PATH, null,
                DBusSignalFlags.NONE, on_manager_signal);
            yield take_inhibitor();
            return session_path != null;
        }

        public void stop() {
            stopped = true;
            if (session_sub != 0) {
                bus.signal_unsubscribe(session_sub);
                session_sub = 0;
            }
            if (manager_sub != 0) {
                bus.signal_unsubscribe(manager_sub);
                manager_sub = 0;
            }
            if (sleep_wait != 0) {
                Source.remove(sleep_wait);
                sleep_wait = 0;
            }
            close_inhibitor();
        }

        private async ObjectPath? call_path(string method, Variant args) {
            try {
                var reply = yield bus.call(BUS_NAME, MANAGER_PATH, MANAGER_IFACE, method, args,
                    new VariantType("(o)"), DBusCallFlags.NONE, 5000, null);
                ObjectPath path;
                reply.get("(o)", out path);
                return path;
            } catch (Error e) {
                debug("LogindLock: %s failed: %s", method, e.message);
                return null;
            }
        }

        private async string? resolve_session() {
            string? id = Environment.get_variable("XDG_SESSION_ID");
            if (id != null && id != "") {
                var path = yield call_path("GetSession", new Variant("(s)", id));
                if (path != null) return path;
            }
            var by_pid = yield call_path("GetSessionByPID", new Variant("(u)", (uint32) Posix.getpid()));
            if (by_pid != null) return by_pid;
            var user = yield call_path("GetUser", new Variant("(u)", (uint32) Posix.getuid()));
            if (user == null) return null;
            try {
                var reply = yield bus.call(BUS_NAME, user, "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", "org.freedesktop.login1.User", "Display"),
                    new VariantType("(v)"), DBusCallFlags.NONE, 5000, null);
                Variant boxed;
                reply.get("(v)", out boxed);
                string sid;
                ObjectPath spath;
                boxed.get("(so)", out sid, out spath);
                if (sid != "" && spath != "/") return spath;
            } catch (Error e) {
                debug("LogindLock: user display session unavailable: %s", e.message);
            }
            return null;
        }

        private void on_session_signal(DBusConnection conn, string? sender, string path, string iface,
                                       string name, Variant parameters) {
            switch (name) {
                case "Lock":
                    request_lock("logind Lock");
                    break;
                case "Unlock":
                    message("LogindLock: logind asked to unlock; the lock screen stays until the user authenticates");
                    break;
            }
        }

        private void on_manager_signal(DBusConnection conn, string? sender, string path, string iface,
                                       string name, Variant parameters) {
            if (!parameters.is_of_type(new VariantType("(b)"))) return;
            bool start;
            parameters.get("(b)", out start);
            if (start) before_sleep();
            else after_sleep();
        }

        public bool request_lock(string reason) {
            if (locker.is_locked()) {
                locks_skipped++;
                message("LogindLock: %s: already locked", reason);
                return false;
            }
            int64 now = get_monotonic_time();
            if (last_request != 0 && now - last_request < repeat_guard_us) {
                locks_skipped++;
                message("LogindLock: %s: a lock was requested %d ms ago", reason,
                    (int) ((now - last_request) / 1000));
                return false;
            }
            last_request = now;
            lock_requests++;
            message("LogindLock: %s: locking the session", reason);
            locker.lock_session();
            return true;
        }

        private void before_sleep() {
            sleeping = true;
            if (!lock_on_suspend()) {
                message("LogindLock: system is going to sleep; lock-on-suspend is off");
                release_inhibitor();
                return;
            }
            if (locker.is_locked()) {
                locks_skipped++;
                message("LogindLock: system is going to sleep; already locked");
                release_inhibitor();
                return;
            }
            request_lock("system is going to sleep");
            if (sleep_wait != 0) Source.remove(sleep_wait);
            int64 deadline = get_monotonic_time() + (int64) sleep_wait_max_ms * 1000;
            int64 locked_at = 0;
            sleep_wait = Timeout.add(poll_ms, () => {
                int64 now = get_monotonic_time();
                if (locked_at == 0 && locker.is_locked()) locked_at = now;
                bool settled = locked_at != 0 && now - locked_at >= (int64) settle_ms * 1000;
                if (!settled && now < deadline) return Source.CONTINUE;
                if (!settled) warning("LogindLock: lock screen not up after %u ms; letting the system sleep", sleep_wait_max_ms);
                sleep_wait = 0;
                release_inhibitor();
                return Source.REMOVE;
            });
        }

        private void after_sleep() {
            sleeping = false;
            if (stopped) return;
            if (sleep_wait != 0) {
                Source.remove(sleep_wait);
                sleep_wait = 0;
            }
            take_inhibitor.begin();
        }

        private async void take_inhibitor() {
            if (inhibit_fd >= 0 || sleeping || stopped) return;
            try {
                UnixFDList out_fds;
                var reply = yield bus.call_with_unix_fd_list(BUS_NAME, MANAGER_PATH, MANAGER_IFACE, "Inhibit",
                    new Variant("(ssss)", "sleep", "Singularity", "Lock the screen before the system sleeps", "delay"),
                    new VariantType("(h)"), DBusCallFlags.NONE, 5000, null, null, out out_fds);
                int32 index;
                reply.get("(h)", out index);
                int fd = out_fds.get(index);
                if (inhibit_fd >= 0 || sleeping || stopped) {
                    Posix.close(fd);
                    return;
                }
                inhibit_fd = fd;
                inhibitor_taken();
            } catch (Error e) {
                warning("LogindLock: no sleep delay inhibitor: %s", e.message);
            }
        }

        private void close_inhibitor() {
            if (inhibit_fd < 0) return;
            Posix.close(inhibit_fd);
            inhibit_fd = -1;
        }

        private void release_inhibitor() {
            if (inhibit_fd < 0) return;
            close_inhibitor();
            inhibitor_released();
        }
    }
}
