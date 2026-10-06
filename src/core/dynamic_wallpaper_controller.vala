using GLib;

namespace Singularity {

    public class DynamicWallpaperController : Object {
        public const string PICTURE_KEY = "background-picture-uri";
        public const string DYNAMIC_KEY = "background-dynamic-uri";
        public const string COORDINATES_KEY = "dynamic-wallpaper-coordinates";
        public const int BLEND_STEPS = 12;
        private const uint TICK_SECONDS = 60;

        private static DynamicWallpaperController? _instance = null;

        private GLib.Settings? settings = null;
        private DynamicWallpaper? current = null;
        private string last_written = "";
        private string loaded_uri = "";
        private int render_serial = 0;
        private string pending_target = "";
        private uint tick_source = 0;

        public bool available { get; private set; default = false; }
        public string location_source { get; private set; default = ""; }
        public DynamicWallpaper? wallpaper { get { return current; } }

        public signal void state_changed();

        public static DynamicWallpaperController get_default() {
            if (_instance == null) _instance = new DynamicWallpaperController();
            return _instance;
        }

        private DynamicWallpaperController() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema == null || !schema.has_key(DYNAMIC_KEY)) return;
            available = true;
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed[PICTURE_KEY].connect(() => defer(on_picture_changed));
            settings.changed[DYNAMIC_KEY].connect(() => defer(load_active));
            if (schema.has_key(COORDINATES_KEY)) settings.changed[COORDINATES_KEY].connect(() => refresh());
            Singularity.Style.ThemeMode.get_default().changed.connect(() => refresh());
            load_active();
            on_picture_changed();
            uint tick = TICK_SECONDS;
            string? env_tick = Environment.get_variable("SINGULARITY_DYNAMIC_WALLPAPER_TICK");
            if (env_tick != null && int.parse(env_tick) > 0) tick = (uint) int.parse(env_tick);
            tick_source = Timeout.add_seconds(tick, () => {
                refresh();
                return Source.CONTINUE;
            });
        }

        private delegate void Step();

        private void defer(owned Step step) {
            Idle.add(() => {
                step();
                return Source.REMOVE;
            });
        }

        public static string cache_dir() {
            return Path.build_filename(Environment.get_user_cache_dir(), "singularity", "dynamic-wallpaper");
        }

        public bool is_dynamic_uri(string uri) {
            if (uri == "") return false;
            string? path = File.new_for_uri(uri).get_path();
            return path != null && DynamicWallpaper.is_dynamic_path(path);
        }

        public string selected_uri() {
            if (settings == null) return "";
            string dyn = settings.get_string(DYNAMIC_KEY);
            return dyn != "" ? dyn : settings.get_string(PICTURE_KEY);
        }

        private bool is_our_output(string uri) {
            if (uri == last_written) return true;
            string? path = File.new_for_uri(uri).get_path();
            if (path == null) return false;
            if (path.has_prefix(cache_dir() + "/")) return true;
            if (current != null) {
                foreach (string img in current.images()) if (img == path) return true;
            }
            return false;
        }

        private void on_picture_changed() {
            string uri = settings.get_string(PICTURE_KEY);
            if (uri == last_written) return;
            if (is_dynamic_uri(uri)) {
                if (settings.get_string(DYNAMIC_KEY) != uri) settings.set_string(DYNAMIC_KEY, uri);
                else load_active();
                return;
            }
            if (settings.get_string(DYNAMIC_KEY) != "" && !is_our_output(uri)) {
                settings.set_string(DYNAMIC_KEY, "");
            }
        }

        private void load_active() {
            string uri = settings.get_string(DYNAMIC_KEY);
            if (uri == "") {
                current = null;
                loaded_uri = "";
                render_serial++;
                state_changed();
                return;
            }
            if (uri != loaded_uri || current == null) {
                string? path = File.new_for_uri(uri).get_path();
                try {
                    current = DynamicWallpaper.load(path ?? "");
                    loaded_uri = uri;
                    message("Dynamic wallpaper: %s (%s)", current.display_name(), current.kind.to_token());
                } catch (Error e) {
                    warning("Dynamic wallpaper %s could not be loaded: %s", uri, e.message);
                    current = null;
                    loaded_uri = "";
                    state_changed();
                    return;
                }
            }
            refresh();
            state_changed();
        }

        public DateTime now() {
            string? clock_file = Environment.get_variable("SINGULARITY_DYNAMIC_WALLPAPER_CLOCK");
            if (clock_file != null) {
                try {
                    string text;
                    FileUtils.get_contents(clock_file, out text);
                    var parsed = new DateTime.from_iso8601(text.strip(), new TimeZone.local());
                    if (parsed != null) return parsed.to_local();
                } catch (Error e) {
                }
            }
            return new DateTime.now_local();
        }

        public static bool parse_coordinates(string text, out double latitude, out double longitude) {
            latitude = 0;
            longitude = 0;
            var parts = text.strip().split(",");
            if (parts.length != 2) return false;
            double lat = 0, lon = 0;
            if (!double.try_parse(parts[0].strip(), out lat) || !double.try_parse(parts[1].strip(), out lon)) return false;
            if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return false;
            latitude = lat;
            longitude = lon;
            return true;
        }

        public void resolve_location(out double latitude, out double longitude) {
            if (settings != null && settings.settings_schema.has_key(COORDINATES_KEY)
                    && parse_coordinates(settings.get_string(COORDINATES_KEY), out latitude, out longitude)) {
                location_source = "manual";
                return;
            }
            string? tz = SunTimes.local_timezone_id();
            if (tz != null && SunTimes.timezone_coordinates(tz, out latitude, out longitude)) {
                location_source = "timezone";
                return;
            }
            double offset_hours = new DateTime.now_local().get_utc_offset() / (double) TimeSpan.HOUR;
            latitude = 40.0;
            longitude = (offset_hours * 15.0).clamp(-180.0, 180.0);
            location_source = "approximate";
        }

        public DynamicWallpaperState? current_state() {
            if (current == null) return null;
            double lat, lon;
            resolve_location(out lat, out lon);
            bool dark = Singularity.Style.ThemeMode.get_default().shell_dark();
            return current.evaluate(now(), dark, true, lat, lon);
        }

        public void refresh() {
            if (current == null || settings == null) return;
            var raw = current_state();
            if (raw == null) return;
            var state = raw.quantized(BLEND_STEPS);
            if (state.from == "") {
                string img = current.preview_image(Singularity.Style.ThemeMode.get_default().shell_dark());
                state = new DynamicWallpaperState(img, img, 0.0);
            }
            if (!state.is_blend) {
                render_serial++;
                pending_target = "";
                write_uri(File.new_for_path(state.single_image).get_uri());
                return;
            }
            string target = Path.build_filename(cache_dir(), "blend-%s.png".printf(
                Checksum.compute_for_string(ChecksumType.SHA1, state.key()).substring(0, 16)));
            if (FileUtils.test(target, FileTest.EXISTS)) {
                render_serial++;
                pending_target = "";
                write_uri(File.new_for_path(target).get_uri());
                return;
            }
            if (target == pending_target) return;
            pending_target = target;
            int serial = ++render_serial;
            int w, h;
            target_size(out w, out h);
            string from = state.from;
            string to = state.to;
            double progress = state.progress;
            new Thread<void>("dynamic-wallpaper-blend", () => {
                bool ok = render_blend(from, to, progress, w, h, target);
                Idle.add(() => {
                    if (pending_target == target) pending_target = "";
                    if (serial != render_serial) return Source.REMOVE;
                    if (ok) {
                        write_uri(File.new_for_path(target).get_uri());
                    } else {
                        write_uri(File.new_for_path(progress >= 0.5 ? to : from).get_uri());
                    }
                    return Source.REMOVE;
                });
            });
        }

        private void write_uri(string uri) {
            if (settings.get_string(PICTURE_KEY) == uri) {
                last_written = uri;
                return;
            }
            last_written = uri;
            settings.set_string(PICTURE_KEY, uri);
            prune_cache(uri);
        }

        private void prune_cache(string keep_uri) {
            string? keep = File.new_for_uri(keep_uri).get_path();
            try {
                var dir = Dir.open(cache_dir());
                string? name;
                var victims = new GenericArray<string>();
                while ((name = dir.read_name()) != null) {
                    if (!name.has_prefix("blend-") || !name.has_suffix(".png")) continue;
                    string full = Path.build_filename(cache_dir(), name);
                    if (full != keep) victims.add(full);
                }
                if (victims.length > 2) {
                    foreach (string v in victims.data) FileUtils.unlink(v);
                }
            } catch (Error e) {
            }
        }

        private static void target_size(out int w, out int h) {
            w = 0;
            h = 0;
            var display = Gdk.Display.get_default();
            if (display != null) {
                var monitors = display.get_monitors();
                for (uint i = 0; i < monitors.get_n_items(); i++) {
                    var monitor = monitors.get_item(i) as Gdk.Monitor;
                    if (monitor == null) continue;
                    w = int.max(w, monitor.geometry.width * monitor.scale_factor);
                    h = int.max(h, monitor.geometry.height * monitor.scale_factor);
                }
            }
            if (w <= 0 || h <= 0) {
                w = 1920;
                h = 1080;
            }
        }

        public static bool render_blend(string from, string to, double progress, int w, int h, string target) {
            try {
                DirUtils.create_with_parents(Path.get_dirname(target), 0700);
                var a = cover(new Gdk.Pixbuf.from_file_at_scale(from, w, h, true), w, h);
                var b = cover(new Gdk.Pixbuf.from_file_at_scale(to, w, h, true), w, h);
                var out_pb = a.copy();
                b.composite(out_pb, 0, 0, w, h, 0, 0, 1.0, 1.0, Gdk.InterpType.BILINEAR,
                    (int) Math.round(progress.clamp(0.0, 1.0) * 255));
                string tmp = target + ".part";
                out_pb.save(tmp, "png", "compression", "1");
                FileUtils.rename(tmp, target);
                return true;
            } catch (Error e) {
                warning("Dynamic wallpaper blend failed: %s", e.message);
                return false;
            }
        }

        private static Gdk.Pixbuf cover(Gdk.Pixbuf src, int w, int h) {
            if (src.width == w && src.height == h) return src.has_alpha ? src : src.add_alpha(false, 0, 0, 0);
            double scale = double.max((double) w / src.width, (double) h / src.height);
            int sw = int.max(w, (int) Math.ceil(src.width * scale));
            int sh = int.max(h, (int) Math.ceil(src.height * scale));
            var scaled = src.scale_simple(sw, sh, Gdk.InterpType.BILINEAR);
            if (!scaled.has_alpha) scaled = scaled.add_alpha(false, 0, 0, 0);
            var cropped = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, w, h);
            scaled.copy_area((sw - w) / 2, (sh - h) / 2, w, h, cropped, 0, 0);
            return cropped;
        }
    }
}
