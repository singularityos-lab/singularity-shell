namespace Singularity {

    public struct InhibitorInfo {
        public uint32 cookie;
        public string app_id;
        public string reason;
        public uint32 flags;
    }

    public class IdleInhibitor : Object {
        public uint32 cookie { get; construct; }
        public string app_id { get; construct; }
        public string reason { get; construct; }
        public uint flags { get; construct; }
        public string sender { get; construct; }

        public IdleInhibitor(uint32 cookie, string app_id, string reason, uint flags, string sender) {
            Object(cookie: cookie, app_id: app_id, reason: reason, flags: flags, sender: sender);
        }

        public string display_name {
            owned get {
                string id = app_id.strip();
                if (id == "") return _("An app");
                string desktop_id = id.has_suffix(".desktop") ? id : id + ".desktop";
                var info = new DesktopAppInfo(desktop_id);
                if (info == null) info = new DesktopAppInfo(desktop_id.down());
                return info != null ? info.get_display_name() : id;
            }
        }

        public Icon? icon {
            owned get {
                string id = app_id.strip();
                if (id == "") return null;
                var info = new DesktopAppInfo(id.has_suffix(".desktop") ? id : id + ".desktop");
                return info != null ? info.get_icon() : null;
            }
        }
    }

    public class IdleInhibitors : Object {
        public const uint LOGOUT = 1;
        public const uint USER_SWITCH = 2;
        public const uint SUSPEND = 4;
        public const uint IDLE = 8;

        private static IdleInhibitors? _instance = null;
        private Gee.ArrayList<IdleInhibitor> _list = new Gee.ArrayList<IdleInhibitor>();
        private Gee.HashMap<string, uint> watches = new Gee.HashMap<string, uint>();
        private uint32 next_cookie = 1;
        private DBusConnection? connection = null;
        private ScreenSaverService? screensaver = null;
        private InhibitorService? service = null;

        public bool window_inhibit { get; private set; default = false; }
        public signal void changed();

        public static IdleInhibitors get_default() {
            if (_instance == null) _instance = new IdleInhibitors();
            return _instance;
        }

        public Gee.List<IdleInhibitor> inhibitors {
            owned get { return _list.read_only_view; }
        }

        public bool inhibits(uint flags, bool include_windows = true) {
            if (include_windows && (flags & IDLE) != 0 && window_inhibit) return true;
            foreach (var inhibitor in _list) {
                if ((inhibitor.flags & flags) != 0) return true;
            }
            return false;
        }

        public void mark_window_inhibit(bool value) {
            if (window_inhibit == value) return;
            window_inhibit = value;
            changed();
        }

        public void start() {
            if (screensaver != null) return;
            screensaver = new ScreenSaverService(this);
            service = new InhibitorService(this);
            Bus.own_name(BusType.SESSION, "org.freedesktop.ScreenSaver",
                BusNameOwnerFlags.ALLOW_REPLACEMENT | BusNameOwnerFlags.REPLACE,
                (conn) => {
                    connection = conn;
                    try {
                        conn.register_object("/org/freedesktop/ScreenSaver", screensaver);
                        conn.register_object("/ScreenSaver", screensaver);
                        conn.register_object("/org/freedesktop/ScreenSaver", service);
                    } catch (IOError e) {
                        warning("IdleInhibitors: cannot export: %s", e.message);
                    }
                },
                null,
                () => warning("IdleInhibitors: lost org.freedesktop.ScreenSaver"));
        }

        public uint32 add(string sender, string app_id, string reason, uint flags) {
            uint32 cookie = next_cookie++;
            _list.add(new IdleInhibitor(cookie, app_id, reason, flags, sender));
            watch_sender(sender);
            debug("IdleInhibitors: %s inhibits %u (%s), cookie %u", app_id, flags, reason, cookie);
            changed();
            if (service != null) service.changed();
            return cookie;
        }

        public void remove(uint32 cookie, string sender) {
            foreach (var inhibitor in _list) {
                if (inhibitor.cookie != cookie) continue;
                if (inhibitor.sender != sender) return;
                _list.remove(inhibitor);
                debug("IdleInhibitors: released cookie %u", cookie);
                drop_watch_if_unused(sender);
                changed();
                if (service != null) service.changed();
                return;
            }
        }

        private void watch_sender(string sender) {
            if (connection == null || sender == "" || watches.has_key(sender)) return;
            watches[sender] = Bus.watch_name_on_connection(connection, sender, BusNameWatcherFlags.NONE,
                null, (conn, name) => release_sender(name));
        }

        private void drop_watch_if_unused(string sender) {
            foreach (var inhibitor in _list) {
                if (inhibitor.sender == sender) return;
            }
            uint id;
            if (watches.unset(sender, out id)) Bus.unwatch_name(id);
        }

        private void release_sender(string sender) {
            var gone = new Gee.ArrayList<IdleInhibitor>();
            foreach (var inhibitor in _list) {
                if (inhibitor.sender == sender) gone.add(inhibitor);
            }
            uint id;
            if (watches.unset(sender, out id)) Bus.unwatch_name(id);
            if (gone.size == 0) return;
            _list.remove_all(gone);
            changed();
            if (service != null) service.changed();
        }

        public InhibitorInfo[] snapshot() {
            InhibitorInfo[] result = {};
            foreach (var inhibitor in _list) {
                result += InhibitorInfo() {
                    cookie = inhibitor.cookie,
                    app_id = inhibitor.app_id,
                    reason = inhibitor.reason,
                    flags = (uint32) inhibitor.flags
                };
            }
            return result;
        }
    }

    [DBus (name = "org.freedesktop.ScreenSaver")]
    public class ScreenSaverService : Object {
        private unowned IdleInhibitors registry;

        public signal void active_changed(bool active);

        public ScreenSaverService(IdleInhibitors registry) {
            this.registry = registry;
            IdleManager.get_default().notify["blanked"].connect(() => {
                active_changed(IdleManager.get_default().blanked);
            });
        }

        public uint32 inhibit(string application_name, string reason_for_inhibit, BusName sender) throws Error {
            return registry.add(sender, application_name, reason_for_inhibit, IdleInhibitors.IDLE | IdleInhibitors.SUSPEND);
        }

        public void un_inhibit(uint32 cookie, BusName sender) throws Error {
            registry.remove(cookie, sender);
        }

        public void @lock() throws Error {
            PowerActions.get_default().lock_screen();
        }

        public bool get_active() throws Error {
            return IdleManager.get_default().blanked;
        }

        public bool set_active(bool active) throws Error {
            IdleManager.get_default().blank_screens(active);
            return true;
        }

        public uint32 get_active_time() throws Error {
            return IdleManager.get_default().blanked_seconds();
        }

        public uint32 get_session_idle_time() throws Error {
            return IdleManager.get_default().idle_seconds();
        }

        public void simulate_user_activity() throws Error {
            IdleManager.get_default().wake();
        }
    }

    [DBus (name = "dev.sinty.desktop.Inhibitors")]
    public class InhibitorService : Object {
        private unowned IdleInhibitors registry;

        public signal void changed();

        public InhibitorService(IdleInhibitors registry) {
            this.registry = registry;
        }

        public uint32 inhibit(string app_id, string reason, uint32 flags, BusName sender) throws Error {
            return registry.add(sender, app_id, reason, flags);
        }

        public void un_inhibit(uint32 cookie, BusName sender) throws Error {
            registry.remove(cookie, sender);
        }

        public InhibitorInfo[] list() throws Error {
            return registry.snapshot();
        }

        public bool window_inhibit() throws Error {
            return registry.window_inhibit;
        }
    }
}
