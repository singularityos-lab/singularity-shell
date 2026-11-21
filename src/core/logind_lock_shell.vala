namespace Singularity {

    public class ShellSessionLocker : Object, SessionLocker {
        public void lock_session() {
            PowerActions.get_default().lock_screen();
        }

        public bool is_locked() {
            return LockClientProbe.running(Posix.getuid(), Posix.getpid());
        }
    }

    public class LogindLock : Object {
        private static LogindLockListener? listener = null;

        private static bool lock_on_suspend() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.lockscreen", true) : null;
            if (schema == null || !schema.has_key("lock-on-suspend")) return true;
            return new GLib.Settings("dev.sinty.lockscreen").get_boolean("lock-on-suspend");
        }

        public static void start() {
            if (listener != null) return;
            Bus.get.begin(BusType.SYSTEM, null, (obj, res) => {
                try {
                    var bus = Bus.get.end(res);
                    listener = new LogindLockListener(bus, new ShellSessionLocker(), lock_on_suspend);
                    listener.start.begin();
                } catch (Error e) {
                    warning("LogindLock: system bus unavailable: %s", e.message);
                }
            });
        }
    }
}
