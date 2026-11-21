namespace Singularity {

    public class ScreenKeymap : Object {
        private static ScreenKeymap? instance = null;

        public signal void changed();

        private GLib.Settings settings;
        private bool ready = false;

        public static ScreenKeymap get_default() {
            if (instance == null) instance = new ScreenKeymap();
            return instance;
        }

        private ScreenKeymap() {
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["xkb-layout"].connect(() => apply());
            settings.changed["xkb-variant"].connect(() => apply());
            SystemMonitor.get_default().locale.state_changed.connect(() => {
                if (!explicit_layout()) apply();
            });
        }

        private bool explicit_layout() {
            return settings.get_user_value("xkb-layout") != null;
        }

        public bool ensure() {
            return ready || apply();
        }

        public bool apply() {
            string variant;
            string layout = LocaleManager.effective_keyboard_layout(settings, out variant);
            bool applied = Singularity.osk_set_layout(layout, variant);
            if (!applied && !explicit_layout()) {
                string lang = SystemMonitor.get_default().locale.get_lang_value();
                if (lang == "") lang = Environment.get_variable("LANG") ?? "";
                foreach (string candidate in LocaleManager.keyboard_layouts_for(lang)) {
                    if (Singularity.osk_set_layout(candidate, null)) {
                        applied = true;
                        break;
                    }
                }
            }
            ready = applied;
            if (applied) changed();
            return applied;
        }
    }
}
