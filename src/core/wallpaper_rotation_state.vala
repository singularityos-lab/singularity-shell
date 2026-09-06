using GLib;

namespace Singularity {

    // Reads and writes the plain-text state files
    // cix-installer/post-install/45-wallpaper-rotator.sh's ncz-wallpaper-rotate
    // and ncz-wallpaper-daemon shell scripts already poll every rotation cycle
    // -- this class is the UI's side of that same shared state, not a new
    // mechanism. config_dir is injected (rather than read from
    // GLib.Environment here) so it's testable against a temp directory.
    public class WallpaperRotationState : Object {
        private const int DEFAULT_INTERVAL_SECONDS = 600;
        private const int MIN_INTERVAL_SECONDS = 30;

        private string config_dir;

        public WallpaperRotationState(string config_dir) {
            this.config_dir = config_dir;
        }

        private string path_for(string filename) {
            return GLib.Path.build_filename(config_dir, filename);
        }

        private string? read_trimmed(string filename) {
            string path = path_for(filename);
            if (!FileUtils.test(path, FileTest.EXISTS)) return null;
            string contents;
            try {
                FileUtils.get_contents(path, out contents);
            } catch (Error e) {
                return null;
            }
            return contents.strip();
        }

        private void write(string filename, string contents) {
            GLib.DirUtils.create_with_parents(config_dir, 0700);
            string dest = path_for(filename);
            string tmp = dest + ".tmp";
            try {
                // Write-then-rename: the rotator daemon polls these files on
                // its own timer, so a partial write it reads mid-flush would
                // be picked up as-is. rename(2) within the same directory is
                // atomic, so the daemon only ever sees a complete write.
                FileUtils.set_contents(tmp, contents);
                if (FileUtils.rename(tmp, dest) != 0) {
                    warning("wallpaper rotation state: could not rename %s into place", filename);
                }
            } catch (Error e) {
                warning("wallpaper rotation state: could not write %s: %s", filename, e.message);
            }
        }

        public string get_selected_collection(string default_id) {
            string? value = read_trimmed("collection");
            return (value == null || value == "") ? default_id : value;
        }

        public void set_selected_collection(string id) {
            write("collection", id);
        }

        public bool get_rotate_enabled() {
            string? value = read_trimmed("rotate-enabled");
            if (value == null) return true;
            string lowered = value.down();
            return lowered != "0" && lowered != "false" && lowered != "off";
        }

        public void set_rotate_enabled(bool enabled) {
            write("rotate-enabled", enabled ? "1" : "0");
        }

        public int get_rotate_interval_seconds() {
            string? value = read_trimmed("rotate-interval");
            if (value == null) return DEFAULT_INTERVAL_SECONDS;
            int64 parsed;
            if (!int64.try_parse(value, out parsed)) return DEFAULT_INTERVAL_SECONDS;
            int seconds = (int) parsed;
            return seconds < MIN_INTERVAL_SECONDS ? MIN_INTERVAL_SECONDS : seconds;
        }

        public void set_rotate_interval_seconds(int seconds) {
            int clamped = seconds < MIN_INTERVAL_SECONDS ? MIN_INTERVAL_SECONDS : seconds;
            write("rotate-interval", clamped.to_string());
        }
    }
}