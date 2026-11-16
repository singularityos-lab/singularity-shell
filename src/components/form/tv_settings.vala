using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class TvSettings : Gtk.Window {
        public const string SETTINGS_ICON = "singularity-settings";
        public const int GEAR_SIZE = 56;
        private const string MORE = "__more__";
        private const int TILE_ICON = 112;
        private const int HEAD_ICON = 88;
        private const int HERO_ICON = 200;
        private const double FOCUS_SCALE = 1.12;
        private const double CARD_TRAVEL = 160.0;
        private const string[] TV_PAGES = {
            "network", "displays", "sound", "bluetooth", "connected-devices", "apps",
            "accessibility", "desktop", "datetime", "wellbeing", "updates"
        };

        private SettingsView _view;
        private Stack _grids;
        private FlowBox _main_grid;
        private FlowBox _more_grid;
        private Box _grid_layer;
        private Box _page_layer;
        private Image _hero_icon;
        private Label _hero_title;
        private Singularity.Animation.MotionBin _hero_motion;
        private Singularity.Animation.MotionBin _hero_text;
        private Singularity.Animation.MotionBin _card;
        private Singularity.Animation.MotionBin _stage;
        private FlowBoxChild? _active_tile = null;
        private string? _root_page = null;
        private string _current = "";
        private bool _closing = false;

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

            _view = new SettingsView(app, false);
            _view.hide_back_buttons = true;
            _view.hexpand = true;
            _view.vexpand = true;
            _view.page_shown.connect((name) => _current = name);

            var overlay = new Overlay();
            overlay.child = build_grid_layer();
            overlay.add_overlay(build_page_layer());
            _stage = new Singularity.Animation.MotionBin(overlay);
            set_child(_stage);

            var keys = new EventControllerKey();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                go_back();
                return true;
            });
            ((Widget) this).add_controller(keys);
        }

        private Widget build_grid_layer() {
            _grid_layer = new Box(Orientation.VERTICAL, 0);
            _grid_layer.add_css_class("tv-home-page");

            var head = new Box(Orientation.HORIZONTAL, 24);
            head.add_css_class("tv-home-head");
            var icon = new Image.from_icon_name(SETTINGS_ICON);
            icon.pixel_size = HEAD_ICON;
            var title = new Label(_("Settings"));
            title.add_css_class("tv-home-title");
            title.xalign = 0;
            title.valign = Align.CENTER;
            head.append(icon);
            head.append(title);
            _grid_layer.append(head);

            _main_grid = make_grid();
            foreach (string name in TV_PAGES) _main_grid.append(tile(name, _view.page_title(name), tv_icon(name)));
            _main_grid.append(tile(MORE, _("All Settings"), SETTINGS_ICON));

            _more_grid = make_grid();
            foreach (string name in _view.all_pages()) {
                if (name in TV_PAGES) continue;
                _more_grid.append(tile(name, _view.page_title(name), tv_icon(name)));
            }

            _grids = new Stack();
            _grids.transition_type = StackTransitionType.CROSSFADE;
            _grids.transition_duration = Singularity.Motion.Duration.LARGE;
            _grids.vexpand = true;
            _grids.add_named(scroller(_main_grid), "main");
            _grids.add_named(scroller(_more_grid), "more");
            _grid_layer.append(_grids);
            return _grid_layer;
        }

        private static Widget scroller(Widget child) {
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = child;
            return scroll;
        }

        private FlowBox make_grid() {
            var grid = new FlowBox();
            grid.add_css_class("tv-settings-grid");
            grid.selection_mode = SelectionMode.NONE;
            grid.homogeneous = true;
            grid.min_children_per_line = 4;
            grid.max_children_per_line = 6;
            grid.column_spacing = 16;
            grid.row_spacing = 24;
            grid.valign = Align.START;
            grid.activate_on_single_click = true;
            grid.child_activated.connect((child) => activate_tile(child));
            return grid;
        }

        private FlowBoxChild tile(string name, string label, string icon_name) {
            var box = new Box(Orientation.VERTICAL, 14);
            box.add_css_class("tv-settings-tile");
            var icon = new Image.from_icon_name(icon_name);
            icon.pixel_size = TILE_ICON;
            var motion = new Singularity.Animation.MotionBin(icon);
            var text = new Label(label);
            text.add_css_class("tv-tile-label");
            text.ellipsize = Pango.EllipsizeMode.END;
            box.append(motion);
            box.append(text);
            var child = new FlowBoxChild();
            child.child = box;
            child.focusable = true;
            child.set_data<string>("tv-page", name);
            child.set_data<string>("tv-icon", icon_name);
            child.set_data<Widget>("tv-motion", motion);
            child.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            var focus = new EventControllerFocus();
            focus.enter.connect(() => Singularity.Motion.spring_to(motion, "scale", FOCUS_SCALE, Singularity.Motion.Spring.BOUNCY));
            focus.leave.connect(() => Singularity.Motion.spring_to(motion, "scale", 1.0, Singularity.Motion.Spring.SNAPPY));
            child.add_controller(focus);
            return child;
        }

        private Widget build_page_layer() {
            _page_layer = new Box(Orientation.HORIZONTAL, 48);
            _page_layer.add_css_class("tv-settings-page");
            _page_layer.opacity = 0.0;
            _page_layer.can_target = false;
            _page_layer.can_focus = false;

            var side = new Box(Orientation.VERTICAL, 24);
            side.add_css_class("tv-settings-hero");
            side.width_request = 440;
            side.valign = Align.CENTER;
            _hero_icon = new Image.from_icon_name(SETTINGS_ICON);
            _hero_icon.pixel_size = HERO_ICON;
            _hero_motion = new Singularity.Animation.MotionBin(_hero_icon);
            _hero_motion.halign = Align.CENTER;

            var text = new Box(Orientation.VERTICAL, 18);
            _hero_title = new Label("");
            _hero_title.add_css_class("tv-home-title");
            _hero_title.wrap = true;
            _hero_title.justify = Justification.CENTER;
            var hint = new Box(Orientation.HORIZONTAL, 10);
            hint.add_css_class("tv-settings-back-hint");
            hint.halign = Align.CENTER;
            var remote = new Image.from_icon_name("input-remote-symbolic");
            remote.pixel_size = 28;
            var back = new Image.from_icon_name("go-previous-symbolic");
            back.pixel_size = 20;
            var hint_label = new Label(_("Back"));
            hint.append(remote);
            hint.append(back);
            hint.append(hint_label);
            text.append(_hero_title);
            text.append(hint);
            _hero_text = new Singularity.Animation.MotionBin(text);

            side.append(_hero_motion);
            side.append(_hero_text);

            var card = new Box(Orientation.VERTICAL, 0);
            card.add_css_class("sidebar");
            card.add_css_class("tv-settings-card");
            card.append(_view);
            _card = new Singularity.Animation.MotionBin(card);
            _card.hexpand = true;

            _page_layer.append(side);
            _page_layer.append(_card);
            return _page_layer;
        }

        private static string tv_icon(string name) {
            switch (name) {
                case "network": return "network-wireless";
                case "displays": return "video-television";
                case "sound": return "audio-headphones";
                case "bluetooth": return "singularity-bluetooth";
                case "connected-devices": return "phone";
                case "apps": return "dev.sinty.apps";
                case "accessibility": return "singularity-screen-reader";
                case "desktop": return "singularity-dynamic-wallpaper";
                case "datetime": return "dev.sinty.clock";
                case "wellbeing": return "singularity-screen-time";
                case "updates": return "singularity-updates";
                case "autostart": return "singularity-autostart";
                case "safety": return "singularity-parental-controls";
                case "privacy": return "preferences-system-privacy";
                case "notifications": return "preferences-system-notifications";
                case "sharing": return "preferences-desktop-remote-desktop";
                case "accounts": return "singularity-account-generic";
                case "keyboard": return "input-keyboard";
                case "tablet": return "input-tablet";
                case "printers": return "printer";
                case "storage": return "drive-harddisk";
                case "system": case "users": return "computer";
                case "sinty-key": return "sinty-key";
                case "developer": return "applications-engineering";
                case "region": return "singularity-input-methods";
                case "power": return "computer-laptop";
                case "performance": return "singularity-equalizer";
            }
            return SETTINGS_ICON;
        }

        private void activate_tile(FlowBoxChild child) {
            string? name = child.get_data<string>("tv-page");
            if (name == null) return;
            if (name == MORE) {
                _grids.visible_child_name = "more";
                focus_first(_more_grid);
                return;
            }
            open_page(child, name);
        }

        private static void focus_first(FlowBox grid) {
            var first = grid.get_child_at_index(0);
            if (first != null) first.grab_focus();
        }

        private void open_page(FlowBoxChild child, string name) {
            _active_tile = child;
            _root_page = name;
            _view.forget_history();
            _view.navigate_to(name);
            _hero_icon.icon_name = child.get_data<string>("tv-icon");
            _hero_title.label = _view.page_title(name);
            _page_layer.can_target = true;
            _page_layer.can_focus = true;
            _grid_layer.can_focus = false;
            Singularity.Motion.tween(_page_layer, "opacity", 1.0, Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.tween(_grid_layer, "opacity", 0.0, Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.EXIT);
            fly_hero(child, true);
            _card.translate_x = CARD_TRAVEL;
            _card.opacity = 0.0;
            Singularity.Motion.spring_to(_card, "translate-x", 0.0, Singularity.Motion.Spring.GENTLE);
            Singularity.Motion.tween(_card, "opacity", 1.0, Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.ENTER);
            _hero_text.opacity = 0.0;
            _hero_text.translate_y = 24.0;
            Singularity.Motion.tween(_hero_text, "opacity", 1.0, Singularity.Motion.Duration.SCENE, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_hero_text, "translate-y", 0.0, Singularity.Motion.Spring.GENTLE);
            Idle.add(() => {
                _view.child_focus(DirectionType.TAB_FORWARD);
                return Source.REMOVE;
            });
        }

        private void fly_hero(FlowBoxChild child, bool opening) {
            var tile_motion = child.get_data<Widget>("tv-motion");
            Graphene.Rect from = Graphene.Rect.zero();
            Graphene.Rect to = Graphene.Rect.zero();
            if (tile_motion == null || !tile_motion.compute_bounds(this, out from) || !_hero_icon.compute_bounds(this, out to)
                    || to.size.width <= 0) {
                _hero_motion.translate_x = 0.0;
                _hero_motion.translate_y = 0.0;
                _hero_motion.scale = 1.0;
                return;
            }
            double dx = (from.origin.x + from.size.width / 2.0) - (to.origin.x + to.size.width / 2.0) + _hero_motion.translate_x;
            double dy = (from.origin.y + from.size.height / 2.0) - (to.origin.y + to.size.height / 2.0) + _hero_motion.translate_y;
            double ratio = (double) TILE_ICON / HERO_ICON;
            if (opening) {
                _hero_motion.translate_x = dx;
                _hero_motion.translate_y = dy;
                _hero_motion.scale = ratio;
                Singularity.Motion.spring_to(_hero_motion, "translate-x", 0.0, Singularity.Motion.Spring.GENTLE);
                Singularity.Motion.spring_to(_hero_motion, "translate-y", 0.0, Singularity.Motion.Spring.GENTLE);
                Singularity.Motion.spring_to(_hero_motion, "scale", 1.0, Singularity.Motion.Spring.GENTLE);
            } else {
                Singularity.Motion.spring_to(_hero_motion, "translate-x", dx, Singularity.Motion.Spring.SNAPPY);
                Singularity.Motion.spring_to(_hero_motion, "translate-y", dy, Singularity.Motion.Spring.SNAPPY);
                Singularity.Motion.spring_to(_hero_motion, "scale", ratio, Singularity.Motion.Spring.SNAPPY);
            }
        }

        private void close_page() {
            var tile = _active_tile;
            _root_page = null;
            _page_layer.can_target = false;
            _page_layer.can_focus = false;
            _grid_layer.can_focus = true;
            if (tile != null) fly_hero(tile, false);
            Singularity.Motion.tween(_page_layer, "opacity", 0.0, Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.EXIT);
            Singularity.Motion.tween(_grid_layer, "opacity", 1.0, Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_card, "translate-x", CARD_TRAVEL, Singularity.Motion.Spring.SNAPPY);
            if (tile != null) tile.grab_focus();
        }

        private void go_back() {
            if (_root_page != null) {
                if (_current != _root_page && _view.history_back()) return;
                close_page();
                return;
            }
            if (_grids.visible_child_name == "more") {
                _grids.visible_child_name = "main";
                var more = _main_grid.get_child_at_index((int) TV_PAGES.length);
                if (more != null) more.grab_focus();
                return;
            }
            dismiss();
        }

        public void open() {
            _closing = false;
            present();
            _grids.visible_child_name = "main";
            focus_first(_main_grid);
            if (Singularity.Motion.reduced()) return;
            _stage.opacity = 0.0;
            _stage.scale = 1.04;
            Singularity.Motion.tween(_stage, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_stage, "scale", 1.0, Singularity.Motion.Spring.GENTLE);
            Widget[] tiles = {};
            for (var c = _main_grid.get_first_child(); c != null; c = c.get_next_sibling()) {
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
