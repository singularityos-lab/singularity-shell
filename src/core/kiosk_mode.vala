namespace Singularity {

    public class KioskMode : Object {
        private const uint MAX_BACKOFF = 30;
        private const int64 STEADY_US = 60 * 1000000;

        private static KioskMode? _instance = null;
        private DesktopAppInfo? _app = null;
        private bool _child_alive = false;
        private int64 _started = 0;
        private uint _backoff = 1;
        private uint _relaunch_id = 0;

        public bool active {
            get { return _app != null; }
        }

        public static KioskMode get_default() {
            if (_instance == null) _instance = new KioskMode();
            return _instance;
        }

        private KioskMode() {
            string? id = ManagedPolicy.get_default().get_string(ManagedPolicy.KIOSK_APP);
            if (id == null || id.strip() == "") return;
            id = id.strip();
            if (!id.has_suffix(".desktop")) id += ".desktop";
            _app = new DesktopAppInfo(id);
            if (_app == null) warning("KioskMode: %s is not installed, the desktop starts as usual", id);
        }

        public string app_name {
            owned get { return _app != null ? _app.get_display_name() : ""; }
        }

        public bool permits(string? app_id) {
            if (_app == null || app_id == null || app_id == "") return true;
            string id = app_id.down();
            if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
            string own = _app.get_id().down();
            if (own.has_suffix(".desktop")) own = own.substring(0, own.length - 8);
            if (id == own) return true;
            string? wm_class = _app.get_startup_wm_class();
            return wm_class != null && id == wm_class.down();
        }

        public void start() {
            if (_app == null) return;
            message("KioskMode: this device runs %s only", _app.get_id());
            var apps = AppSystem.get_default();
            apps.app_opened.connect((handle, app_id) => {
                if (permits(app_id)) wayland_set_maximized(handle, true);
            });
            apps.app_closed.connect(() => schedule());
            launch();
        }

        private bool running() {
            if (_child_alive) return true;
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (permits(win.app_id)) return true;
            }
            return false;
        }

        private void launch() {
            _started = get_monotonic_time();
            try {
                _app.launch_uris_as_manager(new List<string>(), Gdk.Display.get_default().get_app_launch_context(),
                    SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, (info, pid) => {
                        _child_alive = true;
                        ChildWatch.add(pid, (child, status) => {
                            Process.close_pid(child);
                            _child_alive = false;
                            schedule();
                        });
                    });
            } catch (Error e) {
                warning("KioskMode: cannot start %s: %s", _app.get_id(), e.message);
                schedule();
            }
        }

        private void schedule() {
            if (_relaunch_id != 0) return;
            if (get_monotonic_time() - _started > STEADY_US) _backoff = 1;
            _relaunch_id = Timeout.add_seconds(_backoff, () => {
                _relaunch_id = 0;
                if (!running()) launch();
                return Source.REMOVE;
            });
            _backoff = uint.min(_backoff * 2, MAX_BACKOFF);
        }
    }
}
