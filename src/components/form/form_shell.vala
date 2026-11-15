using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class TvHome : Gtk.Window {
        private const double FOCUS_SCALE = 1.08;

        private FlowBox _apps;
        private FlowBox _resume;
        private Label _resume_title;
        private Label _clock;
        private ulong _sig_clock = 0;
        private ulong _sig_running = 0;
        private ulong _sig_apps = 0;

        public TvHome(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-tv-home");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("tv-home");

            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("tv-home-page");
            var head = new Box(Orientation.HORIZONTAL, 0);
            head.add_css_class("tv-home-head");
            var title = new Label(greeting());
            title.add_css_class("tv-home-title");
            title.hexpand = true;
            title.xalign = 0;
            _clock = new Label("");
            _clock.add_css_class("tv-home-clock");
            head.append(title);
            head.append(_clock);
            page.append(head);

            _resume_title = section_label(_("Resume"));
            page.append(_resume_title);
            _resume = new_row();
            page.append(_resume);
            page.append(section_label(_("Apps")));
            _apps = new_row();
            page.append(_apps);
            set_child(page);

            var app_system = AppSystem.get_default();
            _sig_running = app_system.running_apps_changed.connect(() => fill_resume());
            _sig_apps = app_system.apps_changed.connect(() => fill_apps());
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            update_clock();
            fill_apps();
            fill_resume();
        }

        public override void dispose() {
            var app_system = AppSystem.get_default();
            if (_sig_running != 0) { app_system.disconnect(_sig_running); _sig_running = 0; }
            if (_sig_apps != 0) { app_system.disconnect(_sig_apps); _sig_apps = 0; }
            if (_sig_clock != 0) { SharedClock.get_default().disconnect(_sig_clock); _sig_clock = 0; }
            base.dispose();
        }

        public void play_enter() {
            Widget[] tiles = {};
            foreach (var row in new FlowBox[] { _resume, _apps }) {
                for (var c = row.get_first_child(); c != null; c = c.get_next_sibling()) {
                    var bin = tile_motion(c);
                    if (bin != null) tiles += bin;
                }
            }
            Singularity.Motion.cascade(tiles, Singularity.Motion.Preset.SCALE_FADE);
        }

        private static string greeting() {
            int h = new DateTime.now_local().get_hour();
            if (h < 12) return _("Good morning");
            if (h < 18) return _("Good afternoon");
            return _("Good evening");
        }

        private Label section_label(string text) {
            var l = new Label(text);
            l.add_css_class("tv-home-section");
            l.xalign = 0;
            return l;
        }

        private FlowBox new_row() {
            var row = new FlowBox();
            row.add_css_class("tv-home-row");
            row.selection_mode = SelectionMode.NONE;
            row.homogeneous = true;
            row.min_children_per_line = 3;
            row.max_children_per_line = 6;
            row.column_spacing = 28;
            row.row_spacing = 28;
            row.activate_on_single_click = true;
            row.child_activated.connect((child) => {
                var action = child.get_data<string>("tv-action");
                var handle = child.get_data<void*>("tv-window");
                if (handle != null) {
                    Singularity.wayland_activate_window(handle);
                    return;
                }
                if (action != null) {
                    var info = new GLib.DesktopAppInfo(action);
                    if (info != null) AppSystem.launch_app(info);
                }
            });
            return row;
        }

        private static Singularity.Animation.MotionBin? tile_motion(Widget child) {
            var flow_child = child as FlowBoxChild;
            return flow_child != null ? flow_child.child as Singularity.Animation.MotionBin : null;
        }

        private FlowBoxChild tile(GLib.Icon? icon, string icon_name, string label) {
            var box = new Box(Orientation.VERTICAL, 14);
            box.add_css_class("tv-tile");
            var img = icon != null ? new Image.from_gicon(icon) : new Image.from_icon_name(icon_name);
            img.pixel_size = 112;
            img.add_css_class("tv-tile-icon");
            var name = new Label(label);
            name.add_css_class("tv-tile-label");
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 14;
            box.append(img);
            box.append(name);
            var motion = new Singularity.Animation.MotionBin(box);
            var child = new FlowBoxChild();
            child.child = motion;
            child.focusable = true;
            child.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            var focus = new EventControllerFocus();
            focus.enter.connect(() => Singularity.Motion.spring_to(motion, "scale", FOCUS_SCALE, Singularity.Motion.Spring.BOUNCY));
            focus.leave.connect(() => Singularity.Motion.spring_to(motion, "scale", 1.0, Singularity.Motion.Spring.SNAPPY));
            child.add_controller(focus);
            return child;
        }

        private void fill_apps() {
            Widget? w;
            while ((w = _apps.get_first_child()) != null) _apps.remove(w);
            var settings = new GLib.Settings("dev.sinty.desktop");
            foreach (string id in settings.get_strv("pinned-apps")) {
                var info = new GLib.DesktopAppInfo(id);
                if (info == null || info.get_nodisplay()) continue;
                var child = tile(info.get_icon(), "application-x-executable", info.get_display_name());
                child.set_data<string>("tv-action", id);
                _apps.append(child);
            }
        }

        private void fill_resume() {
            Widget? w;
            while ((w = _resume.get_first_child()) != null) _resume.remove(w);
            int n = 0;
            foreach (var win in AppSystem.get_default().get_mru_windows()) {
                if (n++ >= 6) break;
                var child = tile(win.gicon, win.icon_name, win.title);
                child.set_data<void*>("tv-window", win.handle);
                _resume.append(child);
            }
            _resume.visible = n > 0;
            _resume_title.visible = n > 0;
        }

        private void update_clock() {
            _clock.label = new DateTime.now_local().format("%H:%M");
        }

        public void focus_first() {
            var first = (_resume.visible ? _resume : _apps).get_child_at_index(0);
            if (first != null) first.grab_focus();
        }
    }

    public class WatchFace : Gtk.Window {
        private const int WATCH_ICON = 56;
        private const uint WATCH_APPS_PER_ROW = 3;

        private Stack _stack;
        private Label _time;
        private Label _date;
        private Label _notice;
        private FlowBox _apps;
        private Singularity.Animation.MotionBin _face_motion;
        private Singularity.Animation.MotionBin _apps_motion;
        private ulong _sig_clock = 0;
        private ulong _sig_history = 0;

        public WatchFace(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-watch-face");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("watch-face");

            _stack = new Stack();
            _stack.transition_type = StackTransitionType.CROSSFADE;
            _stack.transition_duration = Singularity.Motion.Duration.MEDIUM;
            _stack.add_named(build_face(), "face");
            _stack.add_named(build_apps(), "apps");
            set_child(_stack);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape && _stack.visible_child_name == "apps") {
                    show_face();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller(keys);

            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            var notifications = SystemMonitor.get_default().notifications;
            _sig_history = notifications.history_changed.connect(() => update_notice());
            update_clock();
            update_notice();
        }

        public override void dispose() {
            if (_sig_clock != 0) { SharedClock.get_default().disconnect(_sig_clock); _sig_clock = 0; }
            if (_sig_history != 0) { SystemMonitor.get_default().notifications.disconnect(_sig_history); _sig_history = 0; }
            base.dispose();
        }

        private Widget build_face() {
            var face = new Box(Orientation.VERTICAL, 0);
            face.add_css_class("watch-face-dial");
            face.halign = Align.CENTER;
            face.valign = Align.CENTER;
            _date = new Label("");
            _date.add_css_class("watch-face-date");
            _time = new Label("");
            _time.add_css_class("watch-face-time");
            _notice = new Label("");
            _notice.add_css_class("watch-face-notice");
            _notice.ellipsize = Pango.EllipsizeMode.END;
            _notice.max_width_chars = 22;
            var hint = new Image.from_icon_name("view-app-grid-symbolic");
            hint.add_css_class("watch-face-hint");
            hint.margin_top = 14;
            face.append(_date);
            face.append(_time);
            face.append(_notice);
            face.append(hint);
            _face_motion = new Singularity.Animation.MotionBin(face);
            var tap = new GestureClick();
            tap.released.connect(() => show_apps());
            _face_motion.add_controller(tap);
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
            var back = new Button.from_icon_name("go-previous-symbolic");
            back.add_css_class("watch-back");
            back.halign = Align.CENTER;
            back.tooltip_text = _("Watch Face");
            back.clicked.connect(() => show_face());
            var column = new Box(Orientation.VERTICAL, 8);
            column.valign = Align.CENTER;
            column.append(back);
            column.append(_apps);
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = column;
            _apps_motion = new Singularity.Animation.MotionBin(scroll);
            return _apps_motion;
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

        public void show_face() {
            _stack.visible_child_name = "face";
            if (Singularity.Motion.reduced()) return;
            _face_motion.scale = 0.9;
            Singularity.Motion.spring_to(_face_motion, "scale", 1.0, Singularity.Motion.Spring.BOUNCY);
        }

        private void update_clock() {
            var now = new DateTime.now_local();
            _time.label = now.format("%H:%M");
            _date.label = now.format("%a %e").up();
        }

        private void update_notice() {
            unowned List<Notification> history = SystemMonitor.get_default().notifications.get_history();
            uint count = history.length();
            if (count == 0) {
                _notice.label = _("No notifications");
                return;
            }
            var last = history.last().data;
            _notice.label = count == 1 ? last.summary : ngettext("%s and %u more", "%s and %u more", count - 1).printf(last.summary, count - 1);
        }
    }

    public class FormShell : Object {
        private const uint ESCAPE_KEYCODE = 1;
        private const int TABLET_DOCK_ICON_SIZE = 64;
        private const int TABLET_TOP_RESERVE = 36;
        private const int TABLET_BOTTOM_RESERVE = 104;

        private unowned Gtk.Application _app;
        private PhoneNavBar? _nav = null;
        private TvHome? _tv = null;
        private WatchFace? _watch = null;
        private RecentsSwitcher? _switcher = null;
        private bool _keymap_ready = false;
        private Singularity.FormFactorKind _last_kind;

        public signal void home_requested();
        public signal void next_requested();
        public signal void previous_requested();

        public FormShell(Gtk.Application app) {
            _app = app;
            _last_kind = Singularity.FormFactor.current();
            AppSystem.get_default().app_opened.connect((handle, app_id) => on_app_opened(handle));
            Singularity.FormFactor.get_default().changed.connect(() => sync());
            sync();
        }

        public static string device_size(Singularity.FormFactorKind kind) {
            switch (kind) {
                case Singularity.FormFactorKind.TABLET: return "1180x820";
                case Singularity.FormFactorKind.PHONE: return "412x915";
                case Singularity.FormFactorKind.TV: return "1600x900";
                case Singularity.FormFactorKind.WATCH: return "396x396";
                default: return "1280x800";
            }
        }

        public static bool wants_panel() {
            var kind = Singularity.FormFactor.current();
            return kind != Singularity.FormFactorKind.TV && kind != Singularity.FormFactorKind.WATCH;
        }

        public static bool wants_dock() {
            var kind = Singularity.FormFactor.current();
            return kind == Singularity.FormFactorKind.DESKTOP || kind == Singularity.FormFactorKind.TABLET;
        }

        public static bool wants_workspaces() {
            return wants_dock();
        }

        public static int dock_icon_size(GLib.Settings settings) {
            int size = settings.get_int("dock-icon-size");
            if (Singularity.FormFactor.current() == Singularity.FormFactorKind.TABLET) return int.max(size, TABLET_DOCK_ICON_SIZE);
            return size;
        }

        public static bool dock_magnifies(GLib.Settings settings) {
            return settings.get_boolean("dock-magnification") && !Singularity.FormFactor.current().is_touch_first();
        }

        public bool go_home() {
            var kind = Singularity.FormFactor.current();
            if (kind != Singularity.FormFactorKind.TV && kind != Singularity.FormFactorKind.WATCH) return false;
            if (_switcher != null) _switcher.dismiss();
            SnapController.get_default().dismiss_assist();
            minimize_all();
            if (_tv != null) {
                _tv.play_enter();
                _tv.focus_first();
            }
            if (_watch != null) _watch.show_face();
            return true;
        }

        public void show_recents() {
            SnapController.get_default().dismiss_assist();
            if (_switcher == null) {
                _switcher = new RecentsSwitcher(_app);
                _switcher.dismissed.connect(() => {
                    var old = _switcher;
                    _switcher = null;
                    Idle.add(() => {
                        old.destroy();
                        return Source.REMOVE;
                    });
                });
            }
            _switcher.open();
        }

        public void sync() {
            var kind = Singularity.FormFactor.current();
            bool changed = kind != _last_kind;
            _last_kind = kind;
            resize_nested(kind);
            if (_switcher != null) _switcher.dismiss();
            if (kind == Singularity.FormFactorKind.PHONE) {
                if (_nav == null) {
                    _nav = new PhoneNavBar(_app);
                    _nav.back_requested.connect(() => go_back());
                    _nav.home_requested.connect(() => home_requested());
                    _nav.recents_requested.connect(() => show_recents());
                    _nav.next_requested.connect(() => next_requested());
                    _nav.previous_requested.connect(() => previous_requested());
                }
                _nav.present();
            } else if (_nav != null) {
                _nav.destroy();
                _nav = null;
            }
            if (kind == Singularity.FormFactorKind.TV) {
                if (_tv == null) _tv = new TvHome(_app);
                if (changed) minimize_all();
                _tv.present();
                _tv.play_enter();
                _tv.focus_first();
            } else if (_tv != null) {
                _tv.destroy();
                _tv = null;
            }
            if (kind == Singularity.FormFactorKind.WATCH) {
                if (_watch == null) _watch = new WatchFace(_app);
                _watch.present();
            } else if (_watch != null) {
                _watch.destroy();
                _watch = null;
            }
            bool maximize = kind.is_full_screen();
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (maximize != win.is_maximized) Singularity.wayland_set_maximized(win.handle, maximize);
            }
        }

        private void on_app_opened(void* handle) {
            var kind = Singularity.FormFactor.current();
            if (!kind.is_full_screen()) return;
            Idle.add(() => {
                Singularity.wayland_set_maximized(handle, true);
                return Source.REMOVE;
            });
            if (kind != Singularity.FormFactorKind.TABLET && kind != Singularity.FormFactorKind.TV) return;
            if (AppSystem.get_default().get_windows().length() < 2) return;
            Timeout.add(Singularity.Motion.Duration.LARGE, () => {
                offer_split(handle, kind);
                return Source.REMOVE;
            });
        }

        private void offer_split(void* handle, Singularity.FormFactorKind kind) {
            var display = Gdk.Display.get_default();
            if (display == null || display.get_monitors().get_n_items() == 0) return;
            var geo = ((Gdk.Monitor) display.get_monitors().get_item(0)).geometry;
            int top = kind == Singularity.FormFactorKind.TABLET ? TABLET_TOP_RESERVE : 0;
            int bottom = kind == Singularity.FormFactorKind.TABLET ? TABLET_BOTTOM_RESERVE : 0;
            var area = SnapRect(geo.x, geo.y + top, geo.width, geo.height - top - bottom);
            SnapController.get_default().assist_split(handle, area);
        }

        private void minimize_all() {
            foreach (var win in AppSystem.get_default().get_windows()) Singularity.minimize_window(win.handle);
        }

        private void resize_nested(Singularity.FormFactorKind kind) {
            if (Environment.get_variable("LABWC_NESTED_MODE") == null) return;
            if (Singularity.FormFactor.get_default().forced) return;
            string[] parts = device_size(kind).split("x");
            DisplayManager.get_default().resize_nested_output(int.parse(parts[0]), int.parse(parts[1]));
        }

        private void go_back() {
            if (_switcher != null) {
                _switcher.dismiss();
                return;
            }
            if (!_keymap_ready) {
                var settings = new GLib.Settings("dev.sinty.desktop");
                _keymap_ready = Singularity.osk_set_layout(settings.get_string("xkb-layout"), settings.get_string("xkb-variant"));
            }
            Singularity.osk_press(ESCAPE_KEYCODE, 0);
        }
    }
}
