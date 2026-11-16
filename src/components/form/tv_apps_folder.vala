using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class TvAppsFolder : Gtk.Window {
        public const string ICON = "dev.sinty.apps";
        private const int HEAD_ICON = 88;

        private FlowBox _grid;
        private Singularity.Animation.MotionBin _stage;
        private bool _closing = false;
        private ulong _sig_apps = 0;

        public signal void dismissed();

        public TvAppsFolder(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-tv-apps");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("tv-settings");

            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("tv-home-page");
            var head = new Box(Orientation.HORIZONTAL, 24);
            head.add_css_class("tv-home-head");
            var icon = new Image.from_icon_name(ICON);
            icon.pixel_size = HEAD_ICON;
            var title = new Label(_("Apps"));
            title.add_css_class("tv-home-title");
            title.xalign = 0;
            title.valign = Align.CENTER;
            head.append(icon);
            head.append(title);
            page.append(head);

            _grid = TvHome.new_row();
            _grid.valign = Align.START;
            _grid.child_activated.connect((child) => {
                var id = child.get_data<string>("tv-action");
                if (id == null) return;
                var info = new GLib.DesktopAppInfo(id);
                if (info != null) AppSystem.launch_app(info);
                dismiss();
            });
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = _grid;
            page.append(scroll);

            _stage = new Singularity.Animation.MotionBin(page);
            set_child(_stage);

            var keys = new EventControllerKey();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape && keyval != Gdk.Key.BackSpace) return false;
                dismiss();
                return true;
            });
            ((Widget) this).add_controller(keys);

            _sig_apps = AppSystem.get_default().apps_changed.connect(() => fill());
            fill();
        }

        public override void dispose() {
            if (_sig_apps != 0) { AppSystem.get_default().disconnect(_sig_apps); _sig_apps = 0; }
            base.dispose();
        }

        private void fill() {
            Widget? w;
            while ((w = _grid.get_first_child()) != null) _grid.remove(w);
            var apps = new GLib.List<GLib.AppInfo>();
            foreach (var info in GLib.AppInfo.get_all()) {
                if (info.should_show() && info.get_id() != null) apps.append(info);
            }
            apps.sort((a, b) => a.get_display_name().collate(b.get_display_name()));
            foreach (var info in apps) {
                var child = TvHome.tile(info.get_icon(), "application-x-executable", info.get_display_name());
                child.set_data<string>("tv-action", info.get_id());
                _grid.append(child);
            }
        }

        public void open() {
            _closing = false;
            present();
            var first = _grid.get_child_at_index(0);
            if (first != null) first.grab_focus();
            if (Singularity.Motion.reduced()) return;
            _stage.opacity = 0.0;
            _stage.scale = 1.04;
            Singularity.Motion.tween(_stage, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_stage, "scale", 1.0, Singularity.Motion.Spring.GENTLE);
            Widget[] tiles = {};
            for (var c = _grid.get_first_child(); c != null; c = c.get_next_sibling()) {
                var fc = c as FlowBoxChild;
                if (fc != null && fc.child != null) tiles += fc.child;
            }
            Singularity.Motion.cascade(tiles, Singularity.Motion.Preset.SCALE_FADE);
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
