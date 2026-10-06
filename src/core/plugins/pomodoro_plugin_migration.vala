using GLib;

namespace Singularity {

    public class PomodoroPluginMigration : Object {
        public const string LEGACY_MODULE = "pomodoro";
        public const string REPLACEMENT_MODULE = "clock-timer-tile";
        public const string MARKER = "pomodoro-plugin-migrated";

        public static string state_dir() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "migrations");
        }

        public static string[] without(string[] list, string module, out bool found) {
            found = false;
            string[] kept = {};
            foreach (unowned string name in list) {
                if (name == module) {
                    found = true;
                    continue;
                }
                kept += name;
            }
            return kept;
        }

        public static bool needed(string state_dir) {
            return !FileUtils.test(Path.build_filename(state_dir, MARKER), FileTest.EXISTS);
        }

        public static bool run(GLib.Settings desktop, string state_dir) {
            if (!needed(state_dir)) return false;
            bool found;
            string[] kept = without(desktop.get_strv("enabled-plugins"), LEGACY_MODULE, out found);
            if (found) {
                desktop.set_strv("enabled-plugins", kept);
                if (desktop.settings_schema.has_key("disabled-plugins")) {
                    bool was_off;
                    string[] off = without(desktop.get_strv("disabled-plugins"), REPLACEMENT_MODULE, out was_off);
                    if (was_off) desktop.set_strv("disabled-plugins", off);
                }
            }
            DirUtils.create_with_parents(state_dir, 0700);
            try {
                FileUtils.set_contents(Path.build_filename(state_dir, MARKER), found ? "retired\n" : "absent\n");
            } catch (FileError e) {
                warning("plugins: could not record the Pomodoro migration: %s", e.message);
            }
            return found;
        }
    }
}
