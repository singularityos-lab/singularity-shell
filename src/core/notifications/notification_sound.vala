using GLib;

namespace Singularity {

    public class NotificationSound : Object {
        private const string[] PLAYERS = { "pw-play", "paplay", "canberra-gtk-play" };
        private const string[] EXTENSIONS = { ".oga", ".ogg", ".wav" };
        private int64 _last_play = 0;

        public static string[]? player_command(string configured) {
            if (configured.strip() != "") {
                try {
                    string[] argv;
                    GLib.Shell.parse_argv(configured, out argv);
                    if (argv.length > 0 && Environment.find_program_in_path(argv[0]) != null) return argv;
                } catch (ShellError e) {
                    warning("notification sound: bad sound-command: %s", e.message);
                }
                return null;
            }
            foreach (string p in PLAYERS) {
                string? path = Environment.find_program_in_path(p);
                if (path == null) continue;
                if (p == "canberra-gtk-play") return { path, "-f" };
                return { path };
            }
            return null;
        }

        public static string? find_theme_sound(string name) {
            string[] themes = { "freedesktop" };
            var gtk = Gtk.Settings.get_default();
            if (gtk != null && gtk.gtk_sound_theme_name != null && gtk.gtk_sound_theme_name != "") {
                themes = { gtk.gtk_sound_theme_name, "freedesktop" };
            }
            var dirs = new Gee.ArrayList<string>();
            dirs.add(Environment.get_user_data_dir());
            foreach (string d in Environment.get_system_data_dirs()) dirs.add(d);
            foreach (string theme in themes) {
                foreach (string d in dirs) {
                    foreach (string ext in EXTENSIONS) {
                        string path = Path.build_filename(d, "sounds", theme, "stereo", name + ext);
                        if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
                    }
                }
            }
            return null;
        }

        public void play(HashTable<string, Variant>? hints) {
            var s = AppNotificationSettings.get_default();
            if (!s.available || !s.settings.get_boolean("sounds-enabled")) return;
            int64 now = get_monotonic_time();
            if (now - _last_play < 400000) return;
            string? file = null;
            if (hints != null) {
                var f = hints.lookup("sound-file");
                if (f != null && f.is_of_type(VariantType.STRING)) {
                    string p = f.get_string();
                    if (p.has_prefix("file://")) {
                        try {
                            p = Filename.from_uri(p);
                        } catch (ConvertError e) {
                            p = "";
                        }
                    }
                    if (p != "" && FileUtils.test(p, FileTest.IS_REGULAR)) file = p;
                }
                var n = hints.lookup("sound-name");
                if (file == null && n != null && n.is_of_type(VariantType.STRING)) file = find_theme_sound(n.get_string());
            }
            if (file == null) file = find_theme_sound(s.settings.get_string("sound-name"));
            if (file == null) {
                debug("notification sound: no sound file found");
                return;
            }
            string[]? argv = player_command(s.settings.get_string("sound-command"));
            if (argv == null) {
                debug("notification sound: no player available");
                return;
            }
            argv += file;
            _last_play = now;
            try {
                new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                debug("notification sound: %s", file);
            } catch (Error e) {
                warning("notification sound: %s", e.message);
            }
        }
    }
}
