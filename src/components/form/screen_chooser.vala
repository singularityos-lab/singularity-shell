using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class ScreenChooser : Gtk.Window {
        private const uint LIFETIME_MS = 15000;
        private const uint TICK_MS = 50;
        private const int TILE_ICON = 64;
        private const int COMPACT_TILE_ICON = 40;
        private const int COMPACT_WIDTH = 600;
        private const int EDGE = 8;

        private unowned Gdk.Monitor _screen;
        private ProgressBar _countdown;
        private Singularity.Animation.MotionBin _card;
        private uint _tick = 0;
        private int64 _started = 0;
        private bool _closing = false;
        private bool _compact = false;
        private ulong _outputs_id = 0;

        public signal void finished();

        public ScreenChooser(Gtk.Application app, Gdk.Monitor? host, Gdk.Monitor screen) {
            Object(application: app);
            _screen = screen;
            init_for_window(this);
            if (host != null) set_monitor(this, host);
            set_namespace(this, "singularity-screen-chooser");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_margin(this, GtkLayerShell.Edge.TOP, 56);
            _compact = host != null && host.geometry.width < COMPACT_WIDTH;
            if (_compact) {
                set_anchor(this, GtkLayerShell.Edge.LEFT, true);
                set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
                set_margin(this, GtkLayerShell.Edge.LEFT, EDGE);
                set_margin(this, GtkLayerShell.Edge.RIGHT, EDGE);
            }
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("screen-chooser");

            var card = new Box(Orientation.VERTICAL, 14);
            card.add_css_class("screen-chooser-card");
            if (_compact) card.add_css_class("compact");

            var head = new Box(Orientation.HORIZONTAL, 12);
            var text = new Box(Orientation.VERTICAL, 2);
            text.hexpand = true;
            var title = new Label(_("%s Connected").printf(screen_name(screen)));
            title.add_css_class("title-3");
            title.xalign = 0;
            var subtitle = new Label(_("Choose how this screen behaves. You can change it later in Displays."));
            subtitle.add_css_class("dim-label");
            subtitle.wrap = true;
            subtitle.xalign = 0;
            subtitle.max_width_chars = _compact ? 20 : 44;
            text.append(title);
            text.append(subtitle);
            var close = new Button.from_icon_name("window-close-symbolic");
            close.add_css_class("circular");
            close.valign = Align.START;
            close.tooltip_text = _("Keep Suggested");
            close.clicked.connect(() => dismiss());
            head.append(text);
            head.append(close);
            card.append(head);

            var suggested = Singularity.FormFactor.detect(screen);
            var current = Singularity.FormFactor.at(screen);
            var tiles = new Box(Orientation.HORIZONTAL, _compact ? 4 : 10);
            tiles.homogeneous = true;
            foreach (var kind in FormShell.offered_kinds()) {
                tiles.append(tile(kind, kind == current, kind == suggested));
            }
            card.append(tiles);

            _countdown = new ProgressBar();
            _countdown.add_css_class("screen-chooser-countdown");
            _countdown.fraction = 1.0;
            card.append(_countdown);

            _card = new Singularity.Animation.MotionBin(card);
            set_child(_card);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                dismiss();
                return true;
            });
            ((Widget) this).add_controller(keys);

            var ff = Singularity.FormFactor.get_default();
            string connector = screen.get_connector() ?? "";
            string initial = ff.output_preference(connector);
            _outputs_id = ff.outputs_changed.connect(() => {
                if (ff.output_preference(connector) != initial) dismiss();
            });
        }

        private static string screen_name(Gdk.Monitor monitor) {
            string? model = monitor.get_model();
            if (model != null && model.strip() != "" && model.strip() != "Unknown") return model.strip();
            return monitor.get_connector() ?? _("Screen");
        }

        private Button tile(Singularity.FormFactorKind kind, bool active, bool suggested) {
            var box = new Box(Orientation.VERTICAL, 6);
            var icon = new Image.from_icon_name(FormShell.kind_icon(kind));
            icon.pixel_size = _compact ? COMPACT_TILE_ICON : TILE_ICON;
            var label = new Label(FormShell.kind_label(kind));
            label.add_css_class("screen-chooser-label");
            var hint = new Label(suggested ? _("Suggested") : "");
            hint.add_css_class("caption");
            hint.add_css_class("dim-label");
            box.append(icon);
            box.append(label);
            box.append(hint);
            var b = new Button();
            b.add_css_class("screen-chooser-tile");
            if (active) b.add_css_class("active");
            b.child = box;
            b.clicked.connect(() => {
                var ff = Singularity.FormFactor.get_default();
                string connector = _screen.get_connector() ?? "";
                ff.choose_for_output(connector, kind == Singularity.FormFactor.detect(_screen) ? Singularity.FormFactor.AUTO : kind.to_id());
                dismiss();
            });
            return b;
        }

        public void open() {
            present();
            _started = GLib.get_monotonic_time();
            _tick = Timeout.add(TICK_MS, () => {
                double elapsed = (GLib.get_monotonic_time() - _started) / 1000.0;
                _countdown.fraction = double.max(0.0, 1.0 - elapsed / LIFETIME_MS);
                if (elapsed < LIFETIME_MS) return Source.CONTINUE;
                _tick = 0;
                dismiss();
                return Source.REMOVE;
            });
            if (Singularity.Motion.reduced()) return;
            _card.opacity = 0.0;
            _card.translate_y = -32.0;
            Singularity.Motion.tween(_card, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_card, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        public void dismiss() {
            if (_closing) return;
            _closing = true;
            if (_tick != 0) {
                Source.remove(_tick);
                _tick = 0;
            }
            var fade = Singularity.Motion.tween(_card, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                close_layer_window(this);
                finished();
            });
        }

        public override void dispose() {
            if (_outputs_id != 0) {
                Singularity.FormFactor.get_default().disconnect(_outputs_id);
                _outputs_id = 0;
            }
            if (_tick != 0) {
                Source.remove(_tick);
                _tick = 0;
            }
            base.dispose();
        }
    }
}
