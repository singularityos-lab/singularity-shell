using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class TvSettings : Gtk.Window {
        private const int HERO_ICON = 128;
        private const uint GLOW_MS = 5200;
        private const double GLOW_LOW = 0.35;
        private const double GLOW_HIGH = 0.9;
        private const string HOME_ICON = "video-television";

        private SettingsView _view;
        private Image _hero_icon;
        private Label _hero_title;
        private Label _hero_subtitle;
        private Singularity.Animation.MotionBin _hero;
        private Singularity.Animation.MotionBin _glow;
        private Singularity.Animation.MotionBin _stage;
        private string _page = "home";
        private bool _closing = false;
        private bool _glow_up = true;

        public signal void dismissed();

        public TvSettings(SingularityApp app, Gdk.Monitor monitor) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-tv-settings");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("tv-settings");

            var glow = new Box(Orientation.VERTICAL, 0);
            glow.add_css_class("tv-settings-glow");
            glow.hexpand = true;
            glow.vexpand = true;
            _glow = new Singularity.Animation.MotionBin(glow);
            _glow.opacity = GLOW_LOW;
            _glow.can_target = false;

            _view = new SettingsView(app, false);
            _view.hexpand = true;
            _view.vexpand = true;
            _view.back_to_system.connect(() => dismiss());
            _view.page_shown.connect(show_hero);

            var card = new Box(Orientation.VERTICAL, 0);
            card.add_css_class("sidebar");
            card.add_css_class("tv-settings-card");
            card.hexpand = true;
            card.append(_view);

            var row = new Box(Orientation.HORIZONTAL, 64);
            row.add_css_class("tv-settings-page");
            row.append(build_hero());
            row.append(card);

            var overlay = new Overlay();
            overlay.child = _glow;
            overlay.add_overlay(row);
            _stage = new Singularity.Animation.MotionBin(overlay);
            set_child(_stage);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                if (_page != "home") _view.go_home();
                else dismiss();
                return true;
            });
            ((Widget) this).add_controller(keys);
        }

        private Widget build_hero() {
            var side = new Box(Orientation.VERTICAL, 20);
            side.add_css_class("tv-settings-hero");
            side.width_request = 380;
            _hero_icon = new Image.from_icon_name(HOME_ICON);
            _hero_icon.pixel_size = HERO_ICON;
            _hero_title = new Label(_("Settings"));
            _hero_title.add_css_class("tv-home-title");
            _hero_title.wrap = true;
            _hero_title.justify = Justification.CENTER;
            _hero_subtitle = new Label(_("This TV"));
            _hero_subtitle.add_css_class("tv-settings-hero-subtitle");
            side.append(_hero_icon);
            side.append(_hero_title);
            side.append(_hero_subtitle);
            _hero = new Singularity.Animation.MotionBin(side);
            _hero.valign = Align.CENTER;
            return _hero;
        }

        private static string colored_icon(string symbolic) {
            var theme = IconTheme.get_for_display(Gdk.Display.get_default());
            string base_name = symbolic.has_suffix("-symbolic") ? symbolic.substring(0, symbolic.length - 9) : symbolic;
            if (theme.has_icon(base_name)) return base_name;
            switch (base_name) {
                case "audio-volume-high": return "audio-headphones";
                case "folder-remote": return "preferences-desktop-remote-desktop";
                case "avatar-default": case "system-users": return "computer";
            }
            return HOME_ICON;
        }

        private void show_hero(string name) {
            _page = name;
            bool home = name == "home";
            string icon = home ? HOME_ICON : colored_icon(_view.page_icon(name));
            string title = home ? _("Settings") : _view.page_title(name);
            if (_hero_icon.icon_name == icon && _hero_title.label == title) return;
            _hero_icon.icon_name = icon;
            _hero_title.label = title;
            _hero_subtitle.label = home ? _("This TV") : _("Settings");
            if (Singularity.Motion.reduced() || !get_mapped()) return;
            _hero.opacity = 0.0;
            _hero.translate_y = 16.0;
            Singularity.Motion.tween(_hero, "opacity", 1.0, Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_hero, "translate-y", 0.0, Singularity.Motion.Spring.GENTLE);
        }

        private void breathe() {
            if (_closing || Singularity.Motion.reduced()) return;
            _glow_up = !_glow_up;
            var anim = Singularity.Motion.tween(_glow, "opacity", _glow_up ? GLOW_LOW : GLOW_HIGH,
                GLOW_MS, Singularity.Motion.Curve.STANDARD);
            anim.done.connect(() => breathe());
        }

        public void open() {
            _closing = false;
            present();
            _view.go_home();
            show_hero("home");
            if (Singularity.Motion.reduced()) return;
            _stage.opacity = 0.0;
            _stage.scale = 1.04;
            Singularity.Motion.tween(_stage, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_stage, "scale", 1.0, Singularity.Motion.Spring.GENTLE);
            breathe();
        }

        public void dismiss() {
            if (_closing) return;
            _closing = true;
            var fade = Singularity.Motion.tween(_stage, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                close_layer_window(this);
                dismissed();
            });
        }
    }
}
