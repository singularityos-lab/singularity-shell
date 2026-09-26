using Gtk;
using Gdk;
using GLib;

namespace Singularity {

    public class WallpaperManager : Object {
        private static WallpaperManager? _instance = null;
        private GLib.Settings settings;
        public string? wallpaper_path { get; private set; }
        public Texture? display_texture { get; private set; }
        private Pixbuf? _display_pixbuf;
        public Texture? preview_texture { get; private set; }
        public Texture? medium_texture { get; private set; }
        private string? _cached_path = null;
        private int _load_serial = 0;
        private Mutex _mutex = Mutex ();
        private WallpaperRotator? rotator = null;

        // Attribution metadata for the current wallpaper. Mirrors the
        // dev.sinty.desktop gschema keys background-attribution-title
        // and background-attribution-author. Updated by reload() from
        // the schema; both empty means the Background overlay widget
        // should hide itself. WallpaperManager fires wallpaper_changed
        // whenever these change, so a wallpaper-set call that clears
        // the keys (local pack pick, drag-drop, reset) re-paints the
        // overlay to hide it, and a future call site that sets them
        // alongside the URI (the OCS apply-this-image flow) re-paints
        // to show them.
        public string attribution_title { get; private set; default = ""; }
        public string attribution_author { get; private set; default = ""; }

        public signal void wallpaper_changed();
        // Emitted only after a different image becomes the displayed wallpaper.
        public signal void wallpaper_path_changed(string new_path);

        public static WallpaperManager get_default() {
            if (_instance == null) {
                _instance = new WallpaperManager();
            }
            return _instance;
        }

        // Clicking through several pack thumbnails quickly (confirmed live,
        // O6N, 2026-09-10: three "Wallpaper loaded" reloads inside ~2s)
        // fires one full decode-at-display-resolution + GPU texture upload
        // per click, each on its own background thread. reload()'s
        // _load_serial/_mutex guard only discards a STALE thread's finished
        // RESULT -- it does nothing to stop several of those decode+upload
        // operations from actually running concurrently before being
        // discarded. On this hardware that is a real hazard, not a
        // theoretical one: the Sky1/Mali GPU driver stack already has
        // documented fragility under concurrent GPU work (Panthor crashes,
        // labwc races). The live reproduction of this exact bug ended in
        // "Gdk-Message: Lost connection to Wayland compositor." with no
        // coredump -- a clean Wayland protocol-level disconnect, not a
        // catchable Vala exception, consistent with the compositor itself
        // rejecting the client under GPU/surface contention.
        //
        // Debounce the SIGNAL-driven reload path so a burst of rapid clicks
        // coalesces into a single decode+upload after the clicking settles,
        // rather than racing several. 200ms is imperceptible for the
        // common single-click case (satisfies "it should refresh
        // immediately") while eliminating the overlap for a rapid burst.
        // The constructor's initial reload() stays IMMEDIATE and
        // undebounced -- startup should show the current wallpaper without
        // an artificial delay, and there is no burst to coalesce yet.
        private uint reload_debounce_source = 0;

        private void schedule_reload() {
            if (reload_debounce_source != 0) Source.remove(reload_debounce_source);
            reload_debounce_source = Timeout.add(200, () => {
                reload_debounce_source = 0;
                reload();
                return false;
            });
        }

        private WallpaperManager() {
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["background-picture-uri"].connect(() => {
                schedule_reload();
            });
            // Attribution keys are subscribed independently so they can
            // move without the URI changing (the future apply-OCS-item
            // flow will set attribution without re-pointing the wallpaper
            // file if the URI is already current). Guarded with
            // schema.has_key() so a binary running against an older
            // schema (no attribution keys defined yet) does not critical
            // on missing-key connect.
            SettingsSchema? schema = settings.settings_schema;
            if (schema != null) {
                if (schema.has_key("background-attribution-title"))
                    settings.changed["background-attribution-title"].connect(() => schedule_reload());
                if (schema.has_key("background-attribution-author"))
                    settings.changed["background-attribution-author"].connect(() => schedule_reload());
            }
            reload();
        }

        public void start_rotation() {
            if (rotator != null) return;
            rotator = WallpaperRotator.get_default();
            rotator.current_uri = settings.get_string("background-picture-uri");
            rotator.wallpaper_selected.connect((uri) => {
                settings.set_string("background-picture-uri", uri);
            });
            // Track external changes so rotation does not reselect the current image.
            settings.changed["background-picture-uri"].connect(() => {
                rotator.current_uri = settings.get_string("background-picture-uri");
            });
            rotator.start();
        }

        public void reload() {
            // Read attribution keys defensively: a schema that doesn't
            // have them yet (older deploy, ad-hoc bisect, dev mode) must
            // not abort here -- "" is the right empty value, and the
            // overlay widget treats both-empty as "hide".
            SettingsSchema? schema = settings.settings_schema;
            string new_title = "";
            string new_author = "";
            if (schema != null) {
                if (schema.has_key("background-attribution-title"))
                    new_title = settings.get_string("background-attribution-title");
                if (schema.has_key("background-attribution-author"))
                    new_author = settings.get_string("background-attribution-author");
            }
            // Prefer the current image's normalized sidecar. In particular,
            // Openverse's legally valid plain-text credit must not be parsed
            // as HTML again by the overlay.
            string metadata_uri = settings.get_string("background-picture-uri");
            string? metadata_path = metadata_uri != "" ? File.new_for_uri(metadata_uri).get_path() : null;
            var metadata = WallpaperSidecar.read(metadata_path ?? "");
            if (metadata.valid) {
                new_title = metadata.title;
                new_author = metadata.author;
            } else {
                new_title = WallpaperSidecar.plain_text(new_title);
                new_author = WallpaperSidecar.plain_text(new_author);
            }
            bool attribution_changed =
                new_title != attribution_title ||
                new_author != attribution_author;
            attribution_title = new_title;
            attribution_author = new_author;

            string custom_uri = settings.get_string("background-picture-uri");
            string? path = resolve_path(custom_uri);
            if (path == null) {
                string[] fallbacks = {};
                foreach (unowned string d in GLib.Environment.get_system_data_dirs()) {
                    fallbacks += GLib.Path.build_filename(d, "backgrounds", "singularity", "singularity-cosmos.svg");
                    fallbacks += GLib.Path.build_filename(d, "backgrounds", "singularity", "default.png");
                }
                fallbacks += "../default.png";
                foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                    fallbacks += GLib.Path.build_filename(d, "backgrounds", "default.png");
                fallbacks += "/usr/share/backgrounds/gnome/adwaita-l.jpg";
                foreach (var p in fallbacks) {
                    if (FileUtils.test(p, FileTest.EXISTS)) {
                        path = p;
                        break;
                    } else {
                        if (!p.has_prefix("/")) {
                            try {
                                string exe_path = FileUtils.read_link("/proc/self/exe");
                                var exe_dir = File.new_for_path(exe_path).get_parent();
                                var f = exe_dir.get_child(p);
                                if (f.query_exists()) {
                                    path = f.get_path();
                                    break;
                                }
                            } catch (Error e) {}
                        }
                    }
                }
            }
            if (path != null) {
                if (path == _cached_path) {
                    // Wallpaper file unchanged; if only the attribution
                    // metadata moved (URI stays the same but the keys
                    // were updated), the overlay widget still needs to
                    // repaint, so fire wallpaper_changed(). Otherwise
                    // return -- the texture reload below is what fires
                    // the signal for a true wallpaper change.
                    if (attribution_changed) wallpaper_changed();
                    return;
                }
                _cached_path = path;
                wallpaper_path = path;

                int serial;
                _mutex.lock();
                _load_serial++;
                serial = _load_serial;
                _mutex.unlock();

                string load_path = path;
                int target_w = 0;
                int target_h = 0;
                get_display_target_size(out target_w, out target_h);

                new Thread<void>("wallpaper-load", () => {
                    _mutex.lock();
                    if (serial != _load_serial) {
                        _mutex.unlock();
                        return;
                    }
                    _mutex.unlock();

                    Pixbuf? pb_display = null;
                    try {
                        pb_display = load_display_pixbuf(load_path, target_w, target_h);
                    } catch (Error e) {
                        warning("Failed to load wallpaper: %s", e.message);
                    }

                    Pixbuf? pb_medium = null;
                    Pixbuf? pb_small = null;
                    try {
                        pb_medium = new Pixbuf.from_file_at_scale(load_path, 320, 180, true);
                    } catch (Error e) {}
                    try {
                        pb_small = new Pixbuf.from_file_at_scale(load_path, 120, 67, false);
                    } catch (Error e) {}

                    pb_display = ensure_alpha(pb_display);
                    pb_medium = ensure_alpha(pb_medium);
                    pb_small = ensure_alpha(pb_small);

                    _mutex.lock();
                    bool stale = (serial != _load_serial);
                    _mutex.unlock();
                    if (stale) return;

                    Idle.add(() => {
                        _mutex.lock();
                        bool still_valid = (serial == _load_serial);
                        _mutex.unlock();
                        if (!still_valid) return false;

                        if (pb_display != null) display_texture = Texture.for_pixbuf(pb_display);
                        if (pb_medium != null) { medium_texture = Texture.for_pixbuf(pb_medium); _display_pixbuf = pb_medium.copy(); }
                        if (pb_small != null) preview_texture = Texture.for_pixbuf(pb_small);
                        message("Wallpaper loaded: %s", load_path);
                        wallpaper_changed();
                        wallpaper_path_changed(load_path);
                        return false;
                    });
                });
            }
        }

        private string? resolve_path(string uri) {
            if (uri == "") return null;
            try {
                var file = File.new_for_uri(uri);
                var path = file.get_path();
                if (path != null && FileUtils.test(path, FileTest.EXISTS)) {
                    return path;
                }
            } catch (Error e) {
            }
            return null;
        }

        public bool top_band_rect(double frac, out int x, out int y, out int w, out int h) {
            x = 0; y = 0; w = 0; h = 0;
            var pb = _display_pixbuf;
            if (pb == null) return false;
            if (frac <= 0.0) frac = 0.05;
            if (frac > 1.0) frac = 1.0;
            int dw = pb.get_width();
            int dh = pb.get_height();
            int tw = 0, th = 0;
            get_display_target_size(out tw, out th);
            if (tw <= 0 || tw > dw) tw = dw;
            if (th <= 0 || th > dh) th = dh;
            x = (dw - tw) / 2;
            y = (dh - th) / 2;
            w = tw;
            h = int.min(int.max(1, (int) Math.ceil(frac * th)), dh - y);
            return true;
        }

        public double top_band_luminance(double frac) {
            int x, y, w, h;
            if (!top_band_rect(frac, out x, out y, out w, out h)) return -1.0;
            var pb = _display_pixbuf;
            if (pb.get_bits_per_sample() != 8) return -1.0;
            int channels = pb.get_n_channels();
            if (channels < 3) return -1.0;
            int rowstride = pb.get_rowstride();
            uint8[] data = pb.get_pixels_with_length();
            int n = data.length;
            double total = 0.0;
            int count = 0;
            for (int yy = y; yy < y + h; yy++) {
                for (int xx = x; xx < x + w; xx++) {
                    int idx = yy * rowstride + xx * channels;
                    if (idx + 2 >= n) continue;
                    double r = data[idx]     / 255.0;
                    double g = data[idx + 1] / 255.0;
                    double b = data[idx + 2] / 255.0;
                    total += 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    count++;
                }
            }
            return count > 0 ? total / count : -1.0;
        }

        public Pixbuf? top_band_pixbuf(double frac) {
            int x, y, w, h;
            if (!top_band_rect(frac, out x, out y, out w, out h)) return null;
            return new Pixbuf.subpixbuf(_display_pixbuf, x, y, w, h);
        }

        public bool get_display_dimensions(out int w, out int h) {
            w = 0; h = 0;
            if (_display_pixbuf == null) return false;
            w = _display_pixbuf.get_width();
            h = _display_pixbuf.get_height();
            return true;
        }

        private void get_display_target_size(out int target_w, out int target_h) {
            target_w = 0;
            target_h = 0;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = monitors.get_item(i) as Gdk.Monitor;
                if (monitor == null) continue;
                var geom = monitor.geometry;
                int scale = monitor.scale_factor;
                target_w = int.max(target_w, geom.width * scale);
                target_h = int.max(target_h, geom.height * scale);
            }
        }

        // Sample the average luminance of an arbitrary rectangular
        // sub-region of the cached display pixbuf. Used by the
        // attribution overlay (Background.vala) to pick light or dark
        // text the same way panel.vala does for the top band, but
        // sampling the corner rect the overlay occupies instead of the
        // top strip the panel covers.
        //
        // Returns -1.0 if the display pixbuf is not yet loaded or the
        // rect is fully out of range. Callers compare against
        // topbar_lum_threshold (0.72, panel.vala) and pick light text
        // when luminance > threshold, matching the .light-bg CSS class
        // the panel uses for the same decision.
        //
        // Coordinates are in DISPLAY pixbuf pixels (the medium-resolution
        // texture the panel already samples), not the on-screen output
        // size. The pixbuf aspect ratio matches the screen aspect, so
        // a corner in screen-pixel units maps to a corner in pixbuf
        // pixels at the same proportional position -- callers pass
        // (x, y, w, h) directly. The rect is clamped into the pixbuf
        // bounds so a corner that's partially off-screen at the time
        // the overlay measures still gets a meaningful sample.
        // Fractional-coordinate variant of corner_luminance. The pixbuf
        // aspect ratio matches the screen aspect ratio (medium_texture
        // is built from_file_at_scale preserving aspect), so a
        // fractional rect (0..1, 0..1) samples the same proportional
        // position of the screen. Callers don't need to know the
        // cached pixbuf's pixel size, only where on the screen they
        // want to sample.
        public double corner_luminance_frac(double fx, double fy, double fw, double fh) {
            var pb = _display_pixbuf;
            if (pb == null) return -1.0;
            int pw = pb.get_width();
            int ph = pb.get_height();
            int x = (int) Math.round(fx * pw);
            int y = (int) Math.round(fy * ph);
            int w = (int) Math.round(fw * pw);
            int h = (int) Math.round(fh * ph);
            return corner_luminance(x, y, w, h);
        }

        public double corner_luminance(int x, int y, int w, int h) {
            var pb = _display_pixbuf;
            if (pb == null) return -1.0;
            if (pb.get_bits_per_sample() != 8) return -1.0;
            int channels = pb.get_n_channels();
            if (channels < 3) return -1.0;
            int pw = pb.get_width();
            int ph = pb.get_height();
            x = int.max(0, int.min(x, pw - 1));
            y = int.max(0, int.min(y, ph - 1));
            w = int.max(1, int.min(w, pw - x));
            h = int.max(1, int.min(h, ph - y));
            int rowstride = pb.get_rowstride();
            uint8[] data = pb.get_pixels_with_length();
            int n = data.length;
            double total = 0.0;
            int count = 0;
            for (int yy = y; yy < y + h; yy++) {
                for (int xx = x; xx < x + w; xx++) {
                    int idx = yy * rowstride + xx * channels;
                    if (idx + 2 >= n) continue;
                    double r = data[idx]     / 255.0;
                    double g = data[idx + 1] / 255.0;
                    double b = data[idx + 2] / 255.0;
                    total += 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    count++;
                }
            }
            return count > 0 ? total / count : -1.0;
        }

        private static Pixbuf? ensure_alpha(Pixbuf? pb) {
            if (pb == null) return null;
            if (pb.get_has_alpha()) return pb;
            return pb.add_alpha(false, 0, 0, 0);
        }

        private Pixbuf load_display_pixbuf(string path, int target_w, int target_h) throws Error {
            if (target_w <= 0 || target_h <= 0) {
                target_w = 1920;
                target_h = 1080;
            }

            int src_w = 0;
            int src_h = 0;
            Gdk.Pixbuf.get_file_info(path, out src_w, out src_h);
            if (src_w <= 0 || src_h <= 0) {
                return new Pixbuf.from_file_at_scale(path, target_w, target_h, true);
            }

            double scale = double.max((double)target_w / (double)src_w,
                                      (double)target_h / (double)src_h);
            if (scale > 1.0) scale = 1.0;
            int decode_w = int.max(1, (int)Math.ceil(src_w * scale));
            int decode_h = int.max(1, (int)Math.ceil(src_h * scale));
            int max_dim = 4096;
            if (decode_w > max_dim || decode_h > max_dim) {
                double clamp = double.min((double)max_dim / decode_w, (double)max_dim / decode_h);
                decode_w = int.max(1, (int)(decode_w * clamp));
                decode_h = int.max(1, (int)(decode_h * clamp));
            }
            return new Pixbuf.from_file_at_scale(path, decode_w, decode_h, true);
        }
    }
}
