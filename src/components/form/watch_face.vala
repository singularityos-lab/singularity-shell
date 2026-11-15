using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class WatchFace : Gtk.Window {
        private const int WATCH_ICON = 56;
        private const uint WATCH_APPS_PER_ROW = 3;
        private const double CARD_SHARE = 0.62;
        private const int CARD_GAP = 18;
        private const double CARD_SHRINK = 0.14;
        private const double SWIPE_SLOP = 10.0;
        private const double PAGE_COMMIT = 0.2;
        private const double PULL_SLOP = 10.0;
        private const int PREVIEW_SIZE = 132;
        private const int SWATCH_SIZE = 30;

        private unowned Gdk.Monitor _monitor;
        private Stack _stack;
        private WatchFaceView _face;
        private FlowBox _apps;
        private Singularity.Animation.MotionBin _face_motion;
        private Singularity.Animation.MotionBin _apps_motion;
        private Singularity.Animation.MotionBin _picker_motion;
        private ScrolledWindow _pager;
        private Box _cards;
        private Label _picker_title;
        private Button _customize;
        private Box _options;
        private Label _custom_title;
        private WatchFaceView _preview;
        private Gee.ArrayList<Singularity.Animation.MotionBin> _card_bins = new Gee.ArrayList<Singularity.Animation.MotionBin>();
        private string[] _card_ids = {};
        private int _side = 396;
        private int _card = 240;
        private int _index = 0;
        private double _picker_x = 0;
        private double _swipe_origin = 0;
        private bool _swiping = false;
        private bool _pulling = false;
        private bool _suppress_tap = false;
        private ulong _sig_wallpaper = 0;
        private ulong _sig_power = 0;
        private ulong _sig_history = 0;

        public signal bool pull_begin();
        public signal void pull_update(double dy);
        public signal void pull_end(double dy);

        public WatchFace(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            _monitor = monitor;
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-watch-face");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("watch-face");
            _side = int.min(monitor.geometry.width, monitor.geometry.height);
            _card = (int) (_side * CARD_SHARE);

            WatchFaceRegistry.get_default().load_manifests();

            _stack = new Stack();
            _stack.transition_type = StackTransitionType.CROSSFADE;
            _stack.transition_duration = Singularity.Motion.Duration.MEDIUM;
            _stack.add_named(build_face(), "face");
            _stack.add_named(build_apps(), "apps");
            _stack.add_named(build_picker(), "picker");
            _stack.add_named(build_customize(), "customize");
            set_child(_stack);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                if (_stack.visible_child_name == "customize") show_picker();
                else if (_stack.visible_child_name != "face") show_face();
                else return false;
                return true;
            });
            ((Widget) this).add_controller(keys);

            var wallpaper = WallpaperManager.get_default();
            _sig_wallpaper = wallpaper.wallpaper_changed.connect(() => sync_wallpaper());
            var power = SystemMonitor.get_default().power;
            _sig_power = power.state_changed.connect(() => sync_power());
            _sig_history = SystemMonitor.get_default().notifications.history_changed.connect(() => sync_notifications());
            sync_wallpaper();
            sync_power();
            sync_notifications();
        }

        public override void dispose() {
            if (_sig_wallpaper != 0) { WallpaperManager.get_default().disconnect(_sig_wallpaper); _sig_wallpaper = 0; }
            if (_sig_power != 0) { SystemMonitor.get_default().power.disconnect(_sig_power); _sig_power = 0; }
            if (_sig_history != 0) { SystemMonitor.get_default().notifications.disconnect(_sig_history); _sig_history = 0; }
            base.dispose();
        }

        public Gdk.Monitor monitor { get { return _monitor; } }

        private void sync_wallpaper() {
            var texture = WallpaperManager.get_default().display_texture;
            _face.wallpaper = texture;
            _preview.wallpaper = texture;
            foreach (var bin in _card_bins) {
                var view = bin.get_data<WatchFaceView>("watch-view");
                if (view != null) view.wallpaper = texture;
            }
        }

        private void sync_power() {
            var power = SystemMonitor.get_default().power;
            _face.battery = power.is_present ? power.percentage : -1.0;
            _face.charging = power.is_charging;
        }

        private void sync_notifications() {
            _face.notifications = SystemMonitor.get_default().notifications.get_history().length();
        }

        private Widget build_face() {
            _face = new WatchFaceView();
            _face.hexpand = true;
            _face.vexpand = true;
            _face_motion = new Singularity.Animation.MotionBin(_face);
            _face_motion.update_property(Gtk.AccessibleProperty.LABEL, _("Watch Face"), -1);

            var tap = new GestureClick();
            tap.pressed.connect(() => _suppress_tap = false);
            tap.released.connect(() => {
                if (_suppress_tap) return;
                show_apps();
            });
            _face_motion.add_controller(tap);

            var hold = new GestureLongPress();
            hold.pressed.connect(() => {
                _suppress_tap = true;
                show_picker();
            });
            _face_motion.add_controller(hold);

            var context = new GestureClick();
            context.button = Gdk.BUTTON_SECONDARY;
            context.pressed.connect(() => {
                _suppress_tap = true;
                show_picker();
            });
            _face_motion.add_controller(context);

            var pull = new GestureDrag();
            pull.drag_begin.connect(() => _pulling = false);
            pull.drag_update.connect((dx, dy) => {
                if (!_pulling) {
                    if (dy < PULL_SLOP || Math.fabs(dx) > dy) return;
                    if (!pull_begin()) return;
                    _pulling = true;
                    _suppress_tap = true;
                    hold.reset();
                    pull.set_state(EventSequenceState.CLAIMED);
                }
                pull_update(dy);
            });
            pull.drag_end.connect((dx, dy) => {
                if (_pulling) pull_end(dy);
                _pulling = false;
            });
            _face_motion.add_controller(pull);
            return _face_motion;
        }

        private Widget build_apps() {
            _apps = new FlowBox();
            _apps.add_css_class("watch-apps");
            _apps.selection_mode = SelectionMode.NONE;
            _apps.homogeneous = true;
            _apps.min_children_per_line = WATCH_APPS_PER_ROW;
            _apps.max_children_per_line = WATCH_APPS_PER_ROW;
            _apps.column_spacing = 10;
            _apps.row_spacing = 10;
            _apps.halign = Align.CENTER;
            _apps.valign = Align.CENTER;
            _apps.activate_on_single_click = true;
            _apps.child_activated.connect((child) => {
                var id = child.get_data<string>("watch-app");
                var info = id != null ? new GLib.DesktopAppInfo(id) : null;
                if (info != null) AppSystem.launch_app(info);
                show_face();
            });
            var column = new Box(Orientation.VERTICAL, 8);
            column.valign = Align.CENTER;
            column.append(back_button(_("Watch Face"), () => show_face()));
            column.append(_apps);
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = column;
            _apps_motion = new Singularity.Animation.MotionBin(scroll);
            return _apps_motion;
        }

        private delegate void BackAction();

        private Button back_button(string tooltip, owned BackAction action) {
            var back = new Button.from_icon_name("go-previous-symbolic");
            back.add_css_class("watch-back");
            back.halign = Align.CENTER;
            back.tooltip_text = tooltip;
            back.clicked.connect(() => action());
            return back;
        }

        private Widget build_picker() {
            _picker_title = new Label("");
            _picker_title.add_css_class("watch-picker-title");
            _picker_title.margin_top = (int) (_side * 0.06);

            _cards = new Box(Orientation.HORIZONTAL, CARD_GAP);
            _cards.margin_start = (_side - _card) / 2;
            _cards.margin_end = (_side - _card) / 2;
            _cards.valign = Align.CENTER;

            _pager = new ScrolledWindow();
            _pager.hscrollbar_policy = PolicyType.EXTERNAL;
            _pager.vscrollbar_policy = PolicyType.NEVER;
            _pager.kinetic_scrolling = false;
            _pager.vexpand = true;
            _pager.child = _cards;
            _pager.hadjustment.value_changed.connect(() => update_cards());

            _customize = new Button.with_label(_("Customize"));
            _customize.add_css_class("pill");
            _customize.halign = Align.CENTER;
            _customize.margin_bottom = (int) (_side * 0.07);
            _customize.clicked.connect(() => show_customize());

            var column = new Box(Orientation.VERTICAL, 6);
            column.append(_picker_title);
            column.append(_pager);
            column.append(_customize);

            var swipe = new GestureDrag();
            swipe.propagation_phase = PropagationPhase.CAPTURE;
            swipe.drag_begin.connect(() => _swiping = false);
            swipe.drag_update.connect((dx, dy) => {
                if (!_swiping) {
                    if (Math.fabs(dx) < SWIPE_SLOP || Math.fabs(dx) < Math.fabs(dy)) return;
                    _swiping = true;
                    swipe.set_state(EventSequenceState.CLAIMED);
                    Singularity.Motion.cancel(this, "picker-x");
                    _swipe_origin = _pager.hadjustment.value;
                }
                picker_x = (_swipe_origin - dx).clamp(0, (_card_ids.length - 1) * (double) (_card + CARD_GAP));
            });
            swipe.drag_end.connect((dx, dy) => {
                if (!_swiping) return;
                _swiping = false;
                int target = _index;
                if (dx < -_card * PAGE_COMMIT) target++;
                else if (dx > _card * PAGE_COMMIT) target--;
                go_to_card(target);
            });
            _pager.add_controller(swipe);

            _picker_motion = new Singularity.Animation.MotionBin(column);
            return _picker_motion;
        }

        public double picker_x {
            get { return _picker_x; }
            set {
                _picker_x = value;
                _pager.hadjustment.value = value;
            }
        }

        private void fill_cards() {
            Widget? w;
            while ((w = _cards.get_first_child()) != null) _cards.remove(w);
            _card_bins.clear();
            _card_ids = {};
            var texture = WallpaperManager.get_default().display_texture;
            foreach (var face in WatchFaceRegistry.get_default().list()) {
                var view = new WatchFaceView(face.id);
                view.set_size_request(_card, _card);
                view.wallpaper = texture;
                view.add_css_class("watch-picker-card");
                var bin = new Singularity.Animation.MotionBin(view);
                bin.set_data<WatchFaceView>("watch-view", view);
                bin.update_property(Gtk.AccessibleProperty.LABEL, face.name, -1);
                int index = _card_ids.length;
                var pick = new GestureClick();
                pick.released.connect(() => {
                    if (index == _index) choose(face.id);
                    else go_to_card(index);
                });
                bin.add_controller(pick);
                _cards.append(bin);
                _card_bins.add(bin);
                _card_ids += face.id;
            }
        }

        private void update_cards() {
            double step = _card + CARD_GAP;
            double pos = _pager.hadjustment.value / step;
            for (int i = 0; i < _card_bins.size; i++) {
                double d = double.min(1.0, Math.fabs(pos - i));
                _card_bins[i].scale = 1.0 - CARD_SHRINK * d;
                _card_bins[i].opacity = 1.0 - 0.45 * d;
            }
            int nearest = ((int) Math.round(pos)).clamp(0, int.max(0, _card_ids.length - 1));
            if (_card_ids.length == 0) return;
            var face = WatchFaceRegistry.get_default().find(_card_ids[nearest]);
            if (face == null) return;
            _picker_title.label = face.name;
            _customize.visible = face.get_options().length > 0;
        }

        private void go_to_card(int index) {
            _index = index.clamp(0, int.max(0, _card_ids.length - 1));
            _picker_x = _pager.hadjustment.value;
            Singularity.Motion.spring_to(this, "picker-x", _index * (double) (_card + CARD_GAP), Singularity.Motion.Spring.SNAPPY);
        }

        private void choose(string id) {
            WatchFaceStore.get_default().current = id;
            show_face();
        }

        private Widget build_customize() {
            _custom_title = new Label("");
            _custom_title.add_css_class("watch-picker-title");
            _custom_title.hexpand = true;
            _custom_title.xalign = 0;

            var head = new Box(Orientation.HORIZONTAL, 10);
            head.append(back_button(_("Watch Faces"), () => show_picker()));
            head.append(_custom_title);

            _preview = new WatchFaceView(WatchFaceStore.DEFAULT_FACE);
            _preview.set_size_request(PREVIEW_SIZE, PREVIEW_SIZE);
            _preview.halign = Align.CENTER;
            _preview.add_css_class("watch-picker-card");

            _options = new Box(Orientation.VERTICAL, 14);

            var done = new Button.with_label(_("Done"));
            done.add_css_class("pill");
            done.add_css_class("suggested-action");
            done.halign = Align.CENTER;
            done.clicked.connect(() => choose(_preview.face_id));

            var column = new Box(Orientation.VERTICAL, 14);
            column.add_css_class("watch-customize");
            column.append(head);
            column.append(_preview);
            column.append(_options);
            column.append(done);

            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = column;
            return scroll;
        }

        private void fill_options(WatchFaceProvider face) {
            Widget? w;
            while ((w = _options.get_first_child()) != null) _options.remove(w);
            var store = WatchFaceStore.get_default();
            foreach (var option in face.get_options()) {
                string value = store.get_value(face, option);
                if (option.kind == WatchFaceOptionKind.TOGGLE) {
                    var row = new Box(Orientation.HORIZONTAL, 10);
                    row.add_css_class("watch-option-row");
                    var label = new Label(option.label);
                    label.hexpand = true;
                    label.xalign = 0;
                    var toggle = new Switch();
                    toggle.active = value == "true";
                    toggle.valign = Align.CENTER;
                    toggle.update_property(Gtk.AccessibleProperty.LABEL, option.label, -1);
                    toggle.notify["active"].connect(() => store.set_value(face, option.key, toggle.active ? "true" : "false"));
                    row.append(label);
                    row.append(toggle);
                    _options.append(row);
                    continue;
                }
                var group = new Box(Orientation.VERTICAL, 8);
                var caption = new Label(option.label);
                caption.add_css_class("watch-option-caption");
                caption.xalign = 0;
                group.append(caption);
                if (option.kind == WatchFaceOptionKind.COLOR) group.append(swatches(face, option, value));
                else group.append(choices(face, option, value));
                _options.append(group);
            }
        }

        private Widget choices(WatchFaceProvider face, WatchFaceOption option, string value) {
            var bubbles = new Singularity.Widgets.BubbleSwitcher();
            var values = option.get_values();
            var labels = option.get_labels();
            for (int i = 0; i < values.length; i++) bubbles.add_option(values[i], i < labels.length ? labels[i] : values[i]);
            bubbles.set_active(value);
            bubbles.halign = Align.START;
            bubbles.selected.connect((name) => WatchFaceStore.get_default().set_value(face, option.key, name));
            return bubbles;
        }

        private Widget swatches(WatchFaceProvider face, WatchFaceOption option, string value) {
            var row = new Box(Orientation.HORIZONTAL, 10);
            var values = option.get_values();
            var labels = option.get_labels();
            var buttons = new Gee.ArrayList<Button>();
            for (int i = 0; i < values.length; i++) {
                string spec = values[i];
                var area = new DrawingArea();
                area.set_size_request(SWATCH_SIZE, SWATCH_SIZE);
                area.set_draw_func((d, cr, width, height) => {
                    var c = WatchPaint.rgba(spec);
                    bool active = d.get_parent() != null && d.get_parent().has_css_class("active");
                    double radius = double.min(width, height) / 2.0;
                    if (active) {
                        WatchPaint.color(cr, c);
                        cr.set_line_width(2.0);
                        cr.arc(width / 2.0, height / 2.0, radius - 1.0, 0, 2 * Math.PI);
                        cr.stroke();
                    }
                    WatchPaint.color(cr, c);
                    cr.arc(width / 2.0, height / 2.0, radius - (active ? 5.0 : 2.0), 0, 2 * Math.PI);
                    cr.fill_preserve();
                    cr.set_source_rgba(1, 1, 1, 0.25);
                    cr.set_line_width(1.0);
                    cr.stroke();
                });
                var b = new Button();
                b.add_css_class("flat");
                b.add_css_class("circular");
                b.add_css_class("watch-swatch");
                b.child = area;
                b.tooltip_text = i < labels.length ? labels[i] : spec;
                b.update_property(Gtk.AccessibleProperty.LABEL, b.tooltip_text, -1);
                if (spec == value) b.add_css_class("active");
                b.clicked.connect(() => {
                    foreach (var other in buttons) {
                        other.remove_css_class("active");
                        other.child.queue_draw();
                    }
                    b.add_css_class("active");
                    area.queue_draw();
                    WatchFaceStore.get_default().set_value(face, option.key, spec);
                });
                buttons.add(b);
                row.append(b);
            }
            return row;
        }

        private void fill_apps() {
            Widget? w;
            while ((w = _apps.get_first_child()) != null) _apps.remove(w);
            var settings = new GLib.Settings("dev.sinty.desktop");
            foreach (string id in settings.get_strv("pinned-apps")) {
                var info = new GLib.DesktopAppInfo(id);
                if (info == null || info.get_nodisplay()) continue;
                var img = new Image.from_gicon(info.get_icon() ?? new ThemedIcon("application-x-executable"));
                img.pixel_size = WATCH_ICON;
                img.add_css_class("watch-app-icon");
                var motion = new Singularity.Animation.MotionBin(img);
                var child = new FlowBoxChild();
                child.child = motion;
                child.focusable = true;
                child.update_property(Gtk.AccessibleProperty.LABEL, info.get_display_name(), -1);
                child.tooltip_text = info.get_display_name();
                child.set_data<string>("watch-app", id);
                _apps.append(child);
            }
        }

        private void show_apps() {
            fill_apps();
            _stack.visible_child_name = "apps";
            if (Singularity.Motion.reduced()) return;
            _apps_motion.scale = 1.12;
            Singularity.Motion.spring_to(_apps_motion, "scale", 1.0, Singularity.Motion.Spring.SNAPPY);
            Widget[] icons = {};
            for (var c = _apps.get_first_child(); c != null; c = c.get_next_sibling()) {
                var flow_child = c as FlowBoxChild;
                if (flow_child != null && flow_child.child != null) icons += flow_child.child;
            }
            Singularity.Motion.cascade(icons, Singularity.Motion.Preset.SCALE_FADE);
            foreach (var icon in icons) {
                var bin = icon as Singularity.Animation.MotionBin;
                if (bin == null) continue;
                bin.scale = 0.6;
                Singularity.Motion.spring_to(bin, "scale", 1.0, Singularity.Motion.Spring.BOUNCY);
            }
        }

        public void show_picker() {
            bool entering = _stack.visible_child_name == "face";
            if (_card_ids.length == 0) fill_cards();
            _index = int.max(0, WatchFaceRegistry.get_default().index_of(WatchFaceStore.get_default().current));
            if (_stack.visible_child_name != "customize") {
                Singularity.Motion.cancel(this, "picker-x");
                Idle.add(() => {
                    picker_x = _index * (double) (_card + CARD_GAP);
                    update_cards();
                    return Source.REMOVE;
                });
            }
            _stack.visible_child_name = "picker";
            update_cards();
            if (!entering || Singularity.Motion.reduced()) return;
            _picker_motion.scale = (double) _side / _card;
            Singularity.Motion.spring_to(_picker_motion, "scale", 1.0, Singularity.Motion.Spring.SNAPPY);
        }

        private void show_customize() {
            if (_card_ids.length == 0) return;
            var face = WatchFaceRegistry.get_default().find(_card_ids[_index]);
            if (face == null) return;
            _custom_title.label = face.name;
            _preview.face_id = face.id;
            fill_options(face);
            _stack.visible_child_name = "customize";
        }

        public void show_face() {
            bool from_picker = _stack.visible_child_name == "picker" || _stack.visible_child_name == "customize";
            _stack.visible_child_name = "face";
            if (Singularity.Motion.reduced()) return;
            _face_motion.scale = from_picker ? (double) _card / _side : 0.9;
            Singularity.Motion.spring_to(_face_motion, "scale", 1.0, from_picker ? Singularity.Motion.Spring.SNAPPY : Singularity.Motion.Spring.BOUNCY);
        }
    }
}
