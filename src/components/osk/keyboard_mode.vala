namespace Singularity {

    public class KeyboardMode : Gtk.Application {
        private const uint HIDE_DELAY_MS = 150;

        private OnScreenKeyboard? keyboard = null;
        private uint hide_timeout = 0;
        private bool was_active = false;

        public KeyboardMode() {
            Object(application_id: "dev.sinty.Keyboard", flags: ApplicationFlags.NON_UNIQUE);
        }

        protected override void startup() {
            base.startup();
            Singularity.Style.StyleManager.pin_brand_themes();
            InputMethodService.keep_local_input();
        }

        protected override void activate() {
            hold();
            Singularity.Style.StyleManager.get_default().load_theme();
            keyboard = new OnScreenKeyboard(this);
            keyboard.follows_focus = true;
            var ime = InputMethodService.get_default();
            ime.notify["active"].connect(follow_focus);
            ime.start();
            follow_focus();
        }

        private void follow_focus() {
            if (hide_timeout != 0) {
                Source.remove(hide_timeout);
                hide_timeout = 0;
            }
            bool active = InputMethodService.get_default().active;
            bool focused = active && !was_active;
            was_active = active;
            if (active) {
                if (focused) keyboard.present();
                return;
            }
            hide_timeout = Timeout.add(HIDE_DELAY_MS, () => {
                hide_timeout = 0;
                if (!InputMethodService.get_default().active) keyboard.set_visible(false);
                return Source.REMOVE;
            });
        }

        public static int launch(string[] args) {
            Environment.set_variable("GDK_BACKEND", "wayland", true);
            InputMethodService.standalone = true;
            string[] rest = { args[0] };
            return new KeyboardMode().run(rest);
        }
    }
}
