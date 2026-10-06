namespace Singularity {

    public class AccessibilityFeedback : Object {
        private static AccessibilityFeedback? _instance;
        private string? player;

        public static AccessibilityFeedback get_default() {
            if (_instance == null) _instance = new AccessibilityFeedback();
            return _instance;
        }

        private AccessibilityFeedback() {
            player = Environment.find_program_in_path("pw-play") ?? Environment.find_program_in_path("paplay");
            SystemMonitor.get_default().shortcuts.accessibility_feedback.connect(on_feedback);
        }

        private void on_feedback(string feature, bool enabled) {
            string icon;
            string text;
            switch (feature) {
                case "caps-lock":
                    icon = "caps-lock-symbolic";
                    text = enabled ? _("Caps Lock On") : _("Caps Lock Off");
                    break;
                case "num-lock":
                    icon = "input-num-lock-symbolic";
                    text = enabled ? _("Num Lock On") : _("Num Lock Off");
                    break;
                case "sticky-keys":
                    icon = "preferences-desktop-accessibility-symbolic";
                    text = enabled ? _("Sticky Keys On") : _("Sticky Keys Off");
                    break;
                case "slow-keys":
                    icon = "preferences-desktop-accessibility-symbolic";
                    text = enabled ? _("Slow Keys On") : _("Slow Keys Off");
                    break;
                case "sticky-modifier":
                    if (modifier_beep()) play("bell");
                    return;
                default:
                    return;
            }
            play(enabled ? "device-added" : "device-removed");
            Singularity.Shell.OsdOverlay.get_default().show_osd(icon, -1, text);
        }

        private static bool modifier_beep() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("org.gnome.desktop.a11y.keyboard", true) : null;
            if (schema == null || !schema.has_key("stickykeys-modifier-beep")) return false;
            return new GLib.Settings("org.gnome.desktop.a11y.keyboard").get_boolean("stickykeys-modifier-beep");
        }

        private void play(string sound) {
            if (player == null) return;
            string? file = find_sound(sound);
            if (file == null) return;
            try {
                Process.spawn_async(null, { player, file }, null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (SpawnError e) {
                warning("AccessibilityFeedback: %s", e.message);
            }
        }

        private static string? find_sound(string name) {
            var dirs = new GenericArray<string>();
            dirs.add(Environment.get_user_data_dir());
            foreach (var dir in Environment.get_system_data_dirs()) dirs.add(dir);
            foreach (var dir in dirs) {
                foreach (var ext in new string[] { "oga", "ogg", "wav" }) {
                    var path = Path.build_filename(dir, "sounds", "freedesktop", "stereo", name + "." + ext);
                    if (FileUtils.test(path, FileTest.EXISTS)) return path;
                }
            }
            return null;
        }
    }
}
