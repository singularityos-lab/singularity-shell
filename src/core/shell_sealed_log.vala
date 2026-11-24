namespace Singularity {

    public class ShellSealedLog : Object {
        private static SealedLog? writer = null;
        private static bool opened = false;
        private static int64 started = 0;
        private static bool framed = false;

        public static void record (string event, uint64[] args = {}) {
            if (!opened) {
                opened = true;
                writer = SealedLog.open ("shell");
            }
            if (writer != null) {
                writer.log (event, args);
            }
        }

        public static void watch (Gtk.Application app) {
            started = get_monotonic_time ();
            record ("start");
            SessionManager.get_default ().notify["locked"].connect (() => {
                if (SessionManager.get_default ().locked) {
                    record ("lock");
                }
            });
            app.window_added.connect ((window) => {
                if (framed) {
                    return;
                }
                window.map.connect (() => {
                    if (framed) {
                        return;
                    }
                    framed = true;
                    record ("first-frame", { (uint64) ((get_monotonic_time () - started) / 1000) });
                });
            });
        }

        public static void crashed (string app_id, int signal_number) {
            record ("app-crash", { (uint64) str_hash (app_id), (uint64) signal_number });
        }
    }
}
