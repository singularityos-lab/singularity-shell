using Gtk;
using GtkLayerShell;

namespace Singularity {

    public enum CompanionMode {
        TOUCHPAD,
        REMOTE
    }

    public class CompanionPad : Gtk.Window {
        private const uint BTN_LEFT = 0x110;
        private const uint BTN_RIGHT = 0x111;
        private const double POINTER_GAIN = 1.8;
        private const double SCROLL_GAIN = 0.6;
        private const double TAP_SLOP = 6.0;
        private const uint KEY_ESC = 1;
        private const uint KEY_ENTER = 28;
        private const uint KEY_UP = 103;
        private const uint KEY_LEFT = 105;
        private const uint KEY_RIGHT = 106;
        private const uint KEY_DOWN = 108;

        private Stack _stack;
        private Label _title;
        private Button _switch;
        private CompanionMode _mode;
        private double _last_x = 0;
        private double _last_y = 0;
        private double _travel = 0;
        private double _scroll_last = 0;
        private bool _keymap_ready = false;
        private Singularity.Animation.MotionBin _stage;

        public signal void home_requested();
        public signal void done();

        public CompanionPad(Gtk.Application app, Gdk.Monitor monitor, CompanionMode mode) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-companion");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("companion");

            var page = new Box(Orientation.VERTICAL, 16);
            page.add_css_class("osk");
            page.add_css_class("companion-page");
            var head = new Box(Orientation.HORIZONTAL, 8);
            _title = new Label("");
            _title.add_css_class("title-2");
            _title.xalign = 0;
            _title.hexpand = true;
            _switch = new Button();
            _switch.add_css_class("osk-key");
            _switch.add_css_class("osk-key-special");
            _switch.add_css_class("companion-head-key");
            _switch.clicked.connect(() => set_mode(_mode == CompanionMode.TOUCHPAD ? CompanionMode.REMOTE : CompanionMode.TOUCHPAD));
            var close = new Button.with_label(_("Done"));
            close.add_css_class("osk-key");
            close.add_css_class("locked");
            close.add_css_class("companion-head-key");
            close.clicked.connect(() => dismiss());
            head.append(_title);
            head.append(_switch);
            head.append(close);
            page.append(head);

            _stack = new Stack();
            _stack.vexpand = true;
            _stack.transition_type = StackTransitionType.CROSSFADE;
            _stack.transition_duration = Singularity.Motion.Duration.MEDIUM;
            _stack.add_named(build_touchpad(), "touchpad");
            _stack.add_named(build_remote(), "remote");
            page.append(_stack);

            _stage = new Singularity.Animation.MotionBin(page);
            set_child(_stage);
            set_mode(mode);
        }

        public void open() {
            present();
            if (Singularity.Motion.reduced()) return;
            _stage.opacity = 0.0;
            _stage.translate_y = 40.0;
            Singularity.Motion.tween(_stage, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_stage, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        public void dismiss() {
            var fade = Singularity.Motion.tween(_stage, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                close_layer_window(this);
                done();
            });
        }

        public void set_mode(CompanionMode mode) {
            _mode = mode;
            bool pad = mode == CompanionMode.TOUCHPAD;
            _stack.visible_child_name = pad ? "touchpad" : "remote";
            _title.label = pad ? _("Touchpad") : _("Remote");
            _switch.icon_name = pad ? "input-gaming-symbolic" : "input-touchpad-symbolic";
            _switch.tooltip_text = pad ? _("Use as Remote") : _("Use as Touchpad");
        }

        private Widget build_touchpad() {
            var row = new Box(Orientation.HORIZONTAL, 10);
            var surface = new Box(Orientation.VERTICAL, 0);
            surface.add_css_class("companion-touchpad");
            surface.hexpand = true;
            surface.vexpand = true;
            var hint = new Label(_("Move with one finger, tap to click, hold for more options"));
            hint.add_css_class("dim-label");
            hint.wrap = true;
            hint.justify = Justification.CENTER;
            hint.vexpand = true;
            hint.valign = Align.CENTER;
            surface.append(hint);

            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => {
                _last_x = 0;
                _last_y = 0;
                _travel = 0;
            });
            drag.drag_update.connect((dx, dy) => {
                double step_x = dx - _last_x;
                double step_y = dy - _last_y;
                _last_x = dx;
                _last_y = dy;
                _travel += Math.fabs(step_x) + Math.fabs(step_y);
                Singularity.vpointer_move(step_x * POINTER_GAIN, step_y * POINTER_GAIN);
            });
            drag.drag_end.connect((dx, dy) => {
                if (_travel < TAP_SLOP) Singularity.vpointer_click(BTN_LEFT);
            });
            surface.add_controller(drag);
            var hold = new GestureLongPress();
            hold.pressed.connect(() => {
                _travel = TAP_SLOP;
                Singularity.vpointer_click(BTN_RIGHT);
            });
            surface.add_controller(hold);

            var strip = new Box(Orientation.VERTICAL, 0);
            strip.add_css_class("companion-scroll");
            strip.width_request = 44;
            strip.tooltip_text = _("Scroll");
            var scroll_drag = new GestureDrag();
            scroll_drag.drag_begin.connect(() => _scroll_last = 0);
            scroll_drag.drag_update.connect((dx, dy) => {
                double step = dy - _scroll_last;
                _scroll_last = dy;
                Singularity.vpointer_scroll(0, step * SCROLL_GAIN);
            });
            strip.add_controller(scroll_drag);

            row.append(surface);
            row.append(strip);

            var buttons = new Box(Orientation.HORIZONTAL, 10);
            buttons.homogeneous = true;
            buttons.append(pad_button(_("Left Click"), () => Singularity.vpointer_click(BTN_LEFT)));
            buttons.append(pad_button(_("Right Click"), () => Singularity.vpointer_click(BTN_RIGHT)));

            var column = new Box(Orientation.VERTICAL, 10);
            column.append(row);
            column.append(buttons);
            return column;
        }

        private delegate void PadAction();

        private Button pad_button(string label, owned PadAction action) {
            var b = new Button.with_label(label);
            b.add_css_class("osk-key");
            b.add_css_class("osk-key-special");
            b.add_css_class("companion-wide-key");
            b.clicked.connect(() => action());
            return b;
        }

        private Button key_button(string icon, string label, uint code) {
            var b = new Button.from_icon_name(icon);
            b.add_css_class("osk-key");
            b.add_css_class("companion-dpad-key");
            b.tooltip_text = label;
            b.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            b.clicked.connect(() => press(code));
            return b;
        }

        private Widget build_remote() {
            var pad = new Grid();
            pad.add_css_class("companion-dpad");
            pad.row_spacing = 8;
            pad.column_spacing = 8;
            pad.halign = Align.CENTER;
            pad.valign = Align.CENTER;
            pad.vexpand = true;
            pad.attach(key_button("go-up-symbolic", _("Up"), KEY_UP), 1, 0);
            pad.attach(key_button("go-previous-symbolic", _("Left"), KEY_LEFT), 0, 1);
            var ok = new Button.with_label(_("OK"));
            ok.add_css_class("osk-key");
            ok.add_css_class("locked");
            ok.add_css_class("companion-dpad-key");
            ok.clicked.connect(() => press(KEY_ENTER));
            pad.attach(ok, 1, 1);
            pad.attach(key_button("go-next-symbolic", _("Right"), KEY_RIGHT), 2, 1);
            pad.attach(key_button("go-down-symbolic", _("Down"), KEY_DOWN), 1, 2);

            var actions = new Box(Orientation.HORIZONTAL, 10);
            actions.homogeneous = true;
            var back = new Button.from_icon_name("go-previous-symbolic");
            back.add_css_class("osk-key");
            back.add_css_class("osk-key-special");
            back.add_css_class("companion-wide-key");
            back.tooltip_text = _("Back");
            back.clicked.connect(() => press(KEY_ESC));
            var home = new Button.from_icon_name("go-home-symbolic");
            home.add_css_class("osk-key");
            home.add_css_class("osk-key-special");
            home.add_css_class("companion-wide-key");
            home.tooltip_text = _("Home");
            home.clicked.connect(() => home_requested());
            actions.append(back);
            actions.append(home);

            var column = new Box(Orientation.VERTICAL, 16);
            column.append(pad);
            column.append(actions);
            return column;
        }

        private void press(uint code) {
            if (!_keymap_ready) {
                var settings = new GLib.Settings("dev.sinty.desktop");
                _keymap_ready = Singularity.osk_set_layout(settings.get_string("xkb-layout"), settings.get_string("xkb-variant"));
            }
            Singularity.osk_press(code, 0);
        }
    }
}
