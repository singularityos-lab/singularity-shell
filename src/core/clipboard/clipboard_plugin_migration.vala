using GLib;

namespace Singularity {

    public class ClipboardPluginMigration : Object {
        public const string LEGACY_MODULE = "clipboard-history";
        public const string MARKER = "legacy-plugin-migrated";

        public static string[] without_legacy(string[] enabled, out bool found) {
            found = false;
            string[] kept = {};
            foreach (unowned string name in enabled) {
                if (name == LEGACY_MODULE) {
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

        public static bool run(GLib.Settings desktop, GLib.Settings? clipboard, string state_dir) {
            if (!needed(state_dir)) return false;
            bool found;
            string[] kept = without_legacy(desktop.get_strv("enabled-plugins"), out found);
            if (found) {
                desktop.set_strv("enabled-plugins", kept);
                if (clipboard != null) clipboard.set_boolean("history-enabled", true);
            }
            DirUtils.create_with_parents(state_dir, 0700);
            try {
                FileUtils.set_contents(Path.build_filename(state_dir, MARKER), found ? "retired\n" : "absent\n");
            } catch (FileError e) {
                warning("clipboard: could not record the plugin migration: %s", e.message);
            }
            return found;
        }
    }
}
