namespace Singularity {

    public class ShellSessionLocker : Object, SessionLocker {
        public void lock_session() {
            SessionManager.get_default().lock_screen();
        }

        public bool is_locked() {
            return SessionManager.get_default().locked;
        }
    }

    public class LogindLock : Object {
        private static LogindLockListener? listener = null;

        public static void start() {
            if (listener != null) return;
            Bus.get.begin(BusType.SYSTEM, null, (obj, res) => {
                try {
                    var bus = Bus.get.end(res);
                    listener = new LogindLockListener(bus, new ShellSessionLocker(), PowerActions.lock_on_suspend);
                    listener.start.begin();
                } catch (Error e) {
                    warning("LogindLock: system bus unavailable: %s", e.message);
                }
            });
        }
    }
}
