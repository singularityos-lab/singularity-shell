namespace Singularity {

    public class LedMatrixService : Object {
        private const string SCHEMA = "dev.sinty.desktop";
        public const string CUSTOM_PREFIX = "custom:";

        private static LedMatrixService? _instance = null;

        public bool available { get; private set; default = false; }
        public int width { get; private set; default = 13; }
        public int height { get; private set; default = 8; }
        public int levels { get; private set; default = 8; }
        public uint firmware { get; private set; default = 0; }
        public bool enabled { get; private set; default = true; }
        public string scene_id { get; private set; default = "clock"; }
        public LedContext context { get; private set; }
        public LedScene scene { get; private set; }

        public signal void frame_rendered(uint8[] pixels);
        public signal void scenes_changed();

        private LedDevice? device = null;
        private GLib.Settings? settings = null;
        private uint tick_id = 0;
        private uint tick_ms = 0;
        private uint retry_id = 0;
        private uint8[]? last_sent = null;
        private int64 started = 0;
        private int brightness = 7;
        private UtilizationMonitor? utilization = null;
        private PowerManager? power = null;
        private LedMedia? media = null;
        private FileMonitor? scenes_monitor = null;

        public static LedMatrixService get_default() {
            if (_instance == null) _instance = new LedMatrixService();
            return _instance;
        }

        private LedMatrixService() {
            context = new LedContext();
            scene = LedScene.builtin("clock", width, height);
            started = get_monotonic_time();
            if (settings_available()) {
                settings = new GLib.Settings(SCHEMA);
                settings.changed.connect(on_setting);
            }
            read_settings();
            watch_scenes();
            connect_device();
        }

        private void read_settings() {
            if (settings == null) return;
            enabled = settings.get_boolean("led-matrix-enabled");
            brightness = settings.get_int("led-matrix-brightness").clamp(0, 7);
            scene_id = settings.get_string("led-matrix-scene");
        }

        private void on_setting(string key) {
            if (!key.has_prefix("led-matrix-")) return;
            bool was_enabled = enabled;
            int was_brightness = brightness;
            read_settings();
            if (device != null && brightness != was_brightness) device.brightness(brightness);
            if (was_enabled && !enabled) {
                stop_sources();
                if (device != null) device.clear();
                last_sent = null;
            }
            load_scene();
            refresh();
        }

        private void watch_scenes() {
            var dir = File.new_for_path(LedScene.user_dir());
            try {
                DirUtils.create_with_parents(dir.get_path(), 0755);
                scenes_monitor = dir.monitor_directory(FileMonitorFlags.NONE);
                scenes_monitor.changed.connect(() => {
                    scenes_changed();
                    if (scene_id.has_prefix(CUSTOM_PREFIX)) {
                        load_scene();
                        refresh();
                    }
                });
            } catch (Error e) {
                debug("LedMatrix: cannot watch scenes: %s", e.message);
            }
        }

        public static string custom_path(string id) {
            return Path.build_filename(LedScene.user_dir(), id.substring(CUSTOM_PREFIX.length) + ".json");
        }

        public string[] custom_ids() {
            string[] ids = {};
            try {
                var dir = Dir.open(LedScene.user_dir());
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_suffix(".json")) ids += CUSTOM_PREFIX + name.substring(0, name.length - 5);
                }
            } catch (Error e) {
            }
            return ids;
        }

        public string import_scene(string path) throws Error {
            var s = LedScene.load(path);
            string base_name = Path.get_basename(path);
            if (base_name.has_suffix(".json")) base_name = base_name.substring(0, base_name.length - 5);
            string stem = base_name.replace("/", "-").strip();
            if (stem == "") stem = "scene";
            string target = Path.build_filename(LedScene.user_dir(), stem + ".json");
            int n = 2;
            while (FileUtils.test(target, FileTest.EXISTS)) {
                target = Path.build_filename(LedScene.user_dir(), "%s-%d.json".printf(stem, n++));
            }
            if (s.name == "") s.name = stem;
            s.save(target);
            string id = Path.get_basename(target);
            return CUSTOM_PREFIX + id.substring(0, id.length - 5);
        }

        public void remove_scene(string id) {
            if (!id.has_prefix(CUSTOM_PREFIX)) return;
            FileUtils.unlink(custom_path(id));
            if (settings != null && scene_id == id) settings.set_string("led-matrix-scene", "clock");
        }

        public string scene_title(string id) {
            switch (id) {
                case "clock": return _("Clock");
                case "now-playing": return _("Now Playing");
                case "notifications": return _("Notifications");
                case "system": return _("System Load");
                case "battery": return _("Battery");
            }
            if (id.has_prefix(CUSTOM_PREFIX)) {
                try {
                    var s = LedScene.load(custom_path(id));
                    if (s.name != "") return s.name;
                } catch (Error e) {
                }
                return id.substring(CUSTOM_PREFIX.length);
            }
            return id;
        }

        private void load_scene() {
            if (scene_id.has_prefix(CUSTOM_PREFIX)) {
                try {
                    scene = LedScene.load(custom_path(scene_id));
                    return;
                } catch (Error e) {
                    warning("LedMatrix: cannot load %s: %s", scene_id, e.message);
                }
            }
            scene = LedScene.builtin(scene_id, width, height);
        }

        public void watch(NotificationManager notifications) {
            notifications.new_notification.connect((id, app_name, summary, body, icon, actions) => {
                context.set_value("notifications", summary != "" ? summary : app_name);
                update_count(notifications);
            });
            notifications.history_changed.connect(() => update_count(notifications));
            update_count(notifications);
        }

        private void update_count(NotificationManager notifications) {
            uint n = notifications.get_history().length();
            context.set_value("notification_count", n > 0 ? "%u".printf(n) : "");
            if (n == 0) context.set_value("notifications", "");
            refresh();
        }

        public static bool settings_available() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup(SCHEMA, true) : null;
            return schema != null && schema.has_key("led-matrix-enabled")
                && schema.has_key("led-matrix-scene") && schema.has_key("led-matrix-brightness");
        }

        public static bool board_has_matrix() {
            uint8[] data;
            try {
                FileUtils.get_data("/proc/device-tree/compatible", out data);
            } catch (Error e) {
                return false;
            }
            var names = new StringBuilder();
            foreach (uint8 b in data) names.append_c(b == 0 ? '\n' : (char) b);
            foreach (unowned string name in names.str.split("\n")) {
                if (name != "" && FileUtils.test("/usr/share/sinty-matrix/devices/%s.conf".printf(name), FileTest.EXISTS)) return true;
            }
            return false;
        }

        private void connect_device() {
            device = LedDevice.open();
            if (device != null) {
                width = device.width;
                height = device.height;
                levels = device.levels;
                firmware = device.firmware;
                available = true;
                last_sent = null;
                device.lost.connect(lost);
                device.brightness(brightness);
                load_scene();
                refresh();
                return;
            }
            if (retry_id == 0 && board_has_matrix()) {
                retry_id = Timeout.add_seconds(5, () => {
                    retry_id = 0;
                    connect_device();
                    return Source.REMOVE;
                });
            }
        }

        private void lost() {
            device = null;
            available = false;
            stop_sources();
            stop_tick();
            Idle.add(() => {
                connect_device();
                return Source.REMOVE;
            });
        }

        private bool uses(string key) {
            foreach (var l in scene.layers) {
                if (l.text.contains("{" + key) || l.source.contains("{" + key) || l.when.contains("{" + key)) return true;
            }
            return false;
        }

        private void start_sources() {
            if ((uses("cpu") || uses("memory")) && utilization == null) {
                utilization = new UtilizationMonitor();
                utilization.updated.connect(() => {
                    if (utilization.cpu_fraction >= 0) context.set_value("cpu", "%d".printf((int) Math.round(utilization.cpu_fraction * 100)));
                    if (utilization.memory_fraction >= 0) context.set_value("memory", "%d".printf((int) Math.round(utilization.memory_fraction * 100)));
                    refresh();
                });
                utilization.start();
            }
            if ((uses("battery") || uses("charging")) && power == null) {
                power = new PowerManager();
                power.state_changed.connect(() => {
                    context.set_value("battery", "%d".printf((int) Math.round(power.percentage)));
                    context.set_value("charging", power.is_charging ? "1" : "");
                    refresh();
                });
                context.set_value("battery", "%d".printf((int) Math.round(power.percentage)));
                context.set_value("charging", power.is_charging ? "1" : "");
            }
            if (uses("media") || uses("playing")) {
                if (media == null) {
                    media = new LedMedia(context);
                    media.changed.connect(refresh);
                }
            }
        }

        private void stop_sources() {
            if (utilization != null) {
                utilization.stop();
                utilization = null;
            }
            power = null;
            media = null;
        }

        private void update_clock() {
            var now = new DateTime.now_local();
            context.set_value("time", now.format("%H:%M"));
            context.set_value("date", now.format("%d/%m"));
            context.set_value("weekday", now.format("%a"));
        }

        public uint8[] render_now() {
            update_clock();
            if (media != null) media.update_progress();
            int64 ms = (get_monotonic_time() - started) / 1000;
            return LedRenderer.render(scene, context, ms);
        }

        public void refresh() {
            if (!enabled || !available) {
                stop_tick();
                return;
            }
            start_sources();
            var pixels = render_now();
            frame_rendered(pixels);
            if (last_sent == null || Memory.cmp(last_sent, pixels, pixels.length) != 0) {
                if (device == null || !device.frame(pixels)) return;
                last_sent = pixels;
            }
            uint want = LedRenderer.animated(scene, context) ? 40 : 1000;
            if (want != tick_ms) {
                stop_tick();
                tick_ms = want;
                tick_id = Timeout.add(want, () => {
                    refresh();
                    return Source.CONTINUE;
                });
            }
        }

        private void stop_tick() {
            if (tick_id != 0) Source.remove(tick_id);
            tick_id = 0;
            tick_ms = 0;
        }
    }

    private class LedMedia : Object {
        private unowned LedContext context;
        private NowPlayingCache player;

        public signal void changed();

        public LedMedia(LedContext context) {
            this.context = context;
            player = NowPlayingCache.get_default();
            player.changed.connect(sync);
            sync();
        }

        ~LedMedia() {
            player.changed.disconnect(sync);
        }

        private void sync() {
            string title = player.title, artist = player.artist;
            context.set_value("media", artist != "" && title != "" ? "%s - %s".printf(artist, title) : title);
            context.set_value("playing", player.playing ? "1" : "");
            update_progress();
            changed();
        }

        public void update_progress() {
            int64 length = player.length_us;
            context.set_value("media_progress", length > 0 ? "%d".printf((int) (player.position_us() * 100 / length)) : "0");
        }
    }

}
