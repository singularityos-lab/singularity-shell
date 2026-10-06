using Singularity.Updates;

namespace Singularity {

    public class UpdatesScheduler : Object {
        private const uint FIRST_RUN_DELAY = 120;
        private const uint TICK_INTERVAL = 1800;
        private const int64 DAY = 86400;

        private static UpdatesScheduler? _instance = null;
        private GLib.Settings settings;
        private bool running = false;
        private bool started = false;
        private Gee.HashMap<uint, string> shown = new Gee.HashMap<uint, string>();

        public signal void open_requested(string page);

        public static UpdatesScheduler get_default() {
            if (_instance == null) _instance = new UpdatesScheduler();
            return _instance;
        }

        private UpdatesScheduler() {
            settings = new GLib.Settings("dev.sinty.desktop");
        }

        public void start() {
            if (started) return;
            started = true;
            var notifications = SystemMonitor.get_default().notifications;
            notifications.action_invoked.connect((id, action) => {
                if (shown.has_key(id) && action == "default") open_requested("updates");
            });
            notifications.notification_closed.connect((id, reason) => shown.unset(id));
            Timeout.add_seconds(FIRST_RUN_DELAY, () => {
                tick();
                return Source.REMOVE;
            });
            Timeout.add_seconds(TICK_INTERVAL, () => {
                tick();
                return Source.CONTINUE;
            });
        }

        public int64 interval() {
            return settings.get_string("updates-check-frequency") == "weekly" ? 7 * DAY : DAY;
        }

        public bool due(int64 now) {
            if (!settings.get_boolean("updates-automatic-check")) return false;
            int64 last = settings.get_int64("updates-last-check");
            return last <= 0 || now - last >= interval() || now < last;
        }

        private void tick() {
            int64 now = get_real_time() / 1000000;
            if (!due(now)) return;
            run_automatic.begin();
        }

        public async void run_automatic() {
            if (running) return;
            running = true;
            try {
                var provider = yield Backend.get_default();
                if (provider.kind == "none" || provider.state.is_busy() || provider.state == State.SCHEDULED) return;
                yield provider.check();
                settings.set_int64("updates-last-check", get_real_time() / 1000000);
                if (provider.state == State.AVAILABLE && provider.can_download
                        && settings.get_boolean("updates-automatic-download")
                        && !NetworkMonitor.get_default().network_metered) {
                    yield provider.download();
                }
                announce(provider);
            } catch (Error e) {
                debug("Updates: automatic check failed: %s", e.message);
            } finally {
                running = false;
            }
        }

        public static string signature(Provider provider) {
            if (provider.available_version != "") return provider.available_version;
            var names = new Gee.ArrayList<string>();
            foreach (var pkg in provider.packages) names.add(pkg.name + "=" + pkg.version);
            names.sort();
            return Checksum.compute_for_string(ChecksumType.SHA1, string.joinv(",", names.to_array()));
        }

        private void announce(Provider provider) {
            if (provider.state != State.AVAILABLE && provider.state != State.READY) return;
            string key = "%s:%s".printf(provider.state == State.READY ? "ready" : "available", signature(provider));
            if (settings.get_string("updates-notified") == key) return;
            settings.set_string("updates-notified", key);
            string title;
            string body;
            if (provider.state == State.READY) {
                title = _("Updates Ready to Install");
                body = _("They are installed the next time you restart. Choose when in Settings.");
            } else if (provider.available_version != "") {
                title = _("%s Is Available").printf(provider.available_version);
                body = _("Download it from Settings when it suits you.");
            } else {
                int count = provider.packages.size;
                title = ngettext("%d Update Available", "%d Updates Available", count).printf(count);
                body = _("Download them from Settings when it suits you.");
            }
            string[] actions = { "default", _("Open Settings") };
            uint id = SystemMonitor.get_default().notifications.notify(_("Updates"), 0, "singularity-updates",
                title, body, actions, new HashTable<string, Variant>(str_hash, str_equal), -1);
            shown[id] = key;
        }
    }
}
