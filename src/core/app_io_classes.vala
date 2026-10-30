namespace Singularity {

    public class AppIoClasses : Object {
        private const string NAME = "dev.sinty.Scheduler";
        private const string PATH = "/dev/sinty/Scheduler";
        private const string IFACE = "dev.sinty.Scheduler1";
        private const uint POLL_SECONDS = 2;
        private const int64 LAUNCH_US = 8 * 1000000LL;

        private static AppIoClasses? instance = null;
        private DBusConnection? bus = null;
        private HashTable<string, string> sent = new HashTable<string, string>(str_hash, str_equal);
        private string? focused = null;
        private uint poll = 0;
        private HashTable<string, int64?> launching = new HashTable<string, int64?>(str_hash, str_equal);

        public bool installed { get; private set; default = false; }
        public bool enabled { get; private set; default = false; }
        public bool switched_on { get; private set; default = false; }

        public static AppIoClasses get_default() {
            if (instance == null) instance = new AppIoClasses();
            return instance;
        }

        public void start() {
            if (!AppPause.get_default().available) return;
            AppSystem.get_default().app_focused.connect((app_id) => {
                focused = app_id;
                if (enabled) push();
            });
            refresh.begin();
        }

        public void app_launching(string app_id) {
            if (!enabled) return;
            launching.insert(AppPause.scope_name(app_id), get_monotonic_time() + LAUNCH_US);
            push();
        }

        public async void refresh() {
            if (bus == null) {
                try {
                    bus = yield Bus.get(BusType.SYSTEM);
                } catch (Error e) {
                    return;
                }
            }
            bool now_installed = false, now_enabled = false;
            try {
                var reply = yield bus.call(NAME, PATH, "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", IFACE), new VariantType("(a{sv})"), DBusCallFlags.NONE, -1);
                var props = new VariantDict(reply.get_child_value(0));
                props.lookup("Installed", "b", out now_installed);
                props.lookup("Enabled", "b", out now_enabled);
            } catch (Error e) {
            }
            installed = now_installed;
            switched_on = now_enabled;
            enabled = now_enabled && AppPause.get_default().available;
            update_poll();
        }

        public async string? switch_scheduler(bool active) {
            if (bus == null) return _("The system service is not available.");
            try {
                yield bus.call(NAME, PATH, IFACE, "SetEnabled", new Variant("(b)", active), null,
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1);
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                return e.message;
            }
            yield refresh();
            return null;
        }

        public async HashTable<string, int64?> stats() {
            var result = new HashTable<string, int64?>(str_hash, str_equal);
            if (bus == null) return result;
            try {
                var reply = yield bus.call(NAME, PATH, IFACE, "GetStats", null,
                    new VariantType("(a{sx})"), DBusCallFlags.NONE, -1);
                var iter = reply.get_child_value(0).iterator();
                string key;
                int64 value;
                while (iter.next("{sx}", out key, out value)) result.insert(key, value);
            } catch (Error e) {
            }
            return result;
        }

        private void update_poll() {
            if (enabled && poll == 0) {
                sent.remove_all();
                poll = Timeout.add_seconds(POLL_SECONDS, () => {
                    push();
                    return Source.CONTINUE;
                });
                push();
            } else if (!enabled && poll != 0) {
                Source.remove(poll);
                poll = 0;
            }
        }

        private void push() {
            var pause = AppPause.get_default();
            var background = AppBackground.get_default();
            var wanted = new HashTable<string, string>(str_hash, str_equal);
            wanted.insert(pause.session_path, "interactive");
            string? scope = focused != null ? AppPause.scope_name(focused) : null;
            int64 now = get_monotonic_time();
            launching.foreach_remove((name, until) => until <= now);
            foreach (var group in pause.groups()) {
                string cls = "normal";
                string name = Path.get_basename(group.path);
                if (background.is_lowered(group.path)) cls = "background";
                else if ((scope != null && name == scope) || launching.contains(name)) cls = "interactive";
                wanted.insert(group.path, cls);
            }
            var builder = new VariantBuilder(new VariantType("a{ss}"));
            bool changed = false;
            wanted.foreach((path, cls) => {
                if (sent.lookup(path) == cls) return;
                builder.add("{ss}", path, cls);
                changed = true;
            });
            if (!changed) return;
            sent = (owned) wanted;
            bus.call.begin(NAME, PATH, IFACE, "SetClasses", new Variant("(a{ss})", builder), null,
                DBusCallFlags.NONE, -1, null, (obj, res) => {
                    try {
                        bus.call.end(res);
                    } catch (Error e) {
                        sent.remove_all();
                    }
                });
        }
    }
}
