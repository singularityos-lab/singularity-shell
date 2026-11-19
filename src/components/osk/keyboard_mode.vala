namespace Singularity {

    public class KeyboardMode : Gtk.Application {
        private OnScreenKeyboard? keyboard = null;

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
            InputMethodService.get_default().start();
            keyboard.follow_input_focus(true);
        }

        public static int launch(string[] args) {
            Environment.set_variable("GDK_BACKEND", "wayland", true);
            InputMethodService.standalone = true;
            string[] rest = { args[0] };
            return new KeyboardMode().run(rest);
        }
    }
}
