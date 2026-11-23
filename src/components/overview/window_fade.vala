namespace Singularity {

    internal class WindowFade : Object {
        private unowned Gtk.Window window;
        private GLib.Settings settings;

        public bool faded { get; private set; default = false; }
        public bool by_compositor { get; private set; default = false; }

        public signal void changed();

        public WindowFade(Gtk.Window window, GLib.Settings settings) {
            this.window = window;
            this.settings = settings;
            settings.changed["background-effect"].connect(() => {
                if (faded && !plain()) apply(false, 0);
                changed();
            });
        }

        public bool plain() {
            return Style.BackgroundEffect.read(settings) == Style.BackgroundEffectMode.DISABLED;
        }

        public bool shows_desktop() {
            return plain() && by_compositor;
        }

        public void apply(bool fade, uint ms) {
            if (fade && !plain()) fade = false;
            if (fade == faded) return;
            if (MotionHints.fade_windows(window, fade, Motion.get_default().scale(ms))) {
                faded = fade;
                by_compositor = true;
            }
            changed();
        }
    }
}
