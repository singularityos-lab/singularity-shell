using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class TvHome : Gtk.Window {
        private const double FOCUS_SCALE = 1.08;

        private FlowBox _apps;
        private FlowBox _resume;
        private Label _resume_title;
        private Label _clock;
        private unowned Gdk.Monitor _monitor;
        private TvSettings? _settings_screen = null;
        private ulong _sig_clock = 0;
        private ulong _sig_running = 0;
        private ulong _sig_apps = 0;

        public TvHome(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            _monitor = monitor;
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
            var gear_icon = new Image.from_icon_name(TvSettings.SETTINGS_ICON);
            gear_icon.pixel_size = TvSettings.GEAR_SIZE;
            var gear = new Button();
            gear.child = gear_icon;
            gear.add_css_class("tv-home-gear");
            gear.tooltip_text = _("Settings");
            gear.update_property(Gtk.AccessibleProperty.LABEL, _("Settings"), -1);
            gear.valign = Align.CENTER;
            gear.clicked.connect(() => open_settings());
            head.append(title);
            head.append(_clock);
            head.append(gear);
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
            if (_settings_screen != null) { _settings_screen.destroy(); _settings_screen = null; }
            base.dispose();
        }

        public void open_settings() {
            var shell = application as SingularityApp;
            if (shell == null) return;
            if (_settings_screen == null) {
                _settings_screen = new TvSettings(shell, _monitor);
                _settings_screen.dismissed.connect(() => focus_first());
            }
            _settings_screen.open();
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

        public WatchFace(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
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

        private class Screen : Object {
            public unowned Gdk.Monitor monitor;
            public Singularity.FormFactorKind kind;
            public PhoneNavBar? nav = null;
            public TvHome? tv = null;
            public WatchFace? watch = null;

            public void destroy_surfaces() {
                if (nav != null) { nav.destroy(); nav = null; }
                if (tv != null) { tv.destroy(); tv = null; }
                if (watch != null) { watch.destroy(); watch = null; }
            }
        }

        private unowned Gtk.Application _app;
        private Gee.ArrayList<Screen> _screens = new Gee.ArrayList<Screen>();
        private HashTable<void*, bool> _form_maximized = new HashTable<void*, bool>(direct_hash, direct_equal);
        private Gee.HashSet<string> _known_outputs = new Gee.HashSet<string>();
        private RecentsSwitcher? _switcher = null;
        private CompanionPad? _pad = null;
        private ScreenChooser? _chooser = null;
        private bool _keymap_ready = false;

        public signal void home_requested(Gdk.Monitor? monitor);
        public signal void next_requested();
        public signal void previous_requested();

        public FormShell(Gtk.Application app) {
            _app = app;
            var app_system = AppSystem.get_default();
            app_system.app_opened.connect((handle, app_id) => on_app_opened(handle));
            app_system.window_output_changed.connect((handle) => apply_window(handle));
            app_system.app_closed.connect((handle) => _form_maximized.remove(handle));
            var ff = Singularity.FormFactor.get_default();
            ff.changed.connect(() => sync());
            ff.outputs_changed.connect(() => sync());
            var display = Gdk.Display.get_default();
            if (display != null) {
                var monitors = display.get_monitors();
                for (uint i = 0; i < monitors.get_n_items(); i++) {
                    _known_outputs.add(connector_of((Gdk.Monitor) monitors.get_item(i)));
                }
                monitors.items_changed.connect(() => Idle.add(() => {
                    sync();
                    offer_new_outputs();
                    return Source.REMOVE;
                }));
            }
            sync();
        }

        private static string connector_of(Gdk.Monitor monitor) {
            return monitor.get_connector() ?? "";
        }

        public static Gee.List<Singularity.FormFactorKind> offered_kinds() {
            var kinds = new Gee.ArrayList<Singularity.FormFactorKind>();
            bool developer = false;
            var schema = SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true);
            if (schema != null && schema.has_key("developer-mode")) {
                developer = new GLib.Settings("dev.sinty.desktop").get_boolean("developer-mode");
            }
            foreach (var kind in Singularity.FormFactorKind.all()) {
                if (kind == Singularity.FormFactorKind.WATCH && !developer) continue;
                kinds.add(kind);
            }
            return kinds;
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

        public static string kind_icon(Singularity.FormFactorKind kind) {
            switch (kind) {
                case Singularity.FormFactorKind.TABLET: return "tablet";
                case Singularity.FormFactorKind.PHONE: return "phone";
                case Singularity.FormFactorKind.TV: return "video-television";
                case Singularity.FormFactorKind.WATCH: return "watch";
                default: return "computer";
            }
        }

        public static string kind_label(Singularity.FormFactorKind kind) {
            switch (kind) {
                case Singularity.FormFactorKind.TABLET: return _("Tablet");
                case Singularity.FormFactorKind.PHONE: return _("Phone");
                case Singularity.FormFactorKind.TV: return _("TV");
                case Singularity.FormFactorKind.WATCH: return _("Watch");
                default: return _("Desktop");
            }
        }

        private static Singularity.FormFactorKind kind_on(Gdk.Monitor? monitor) {
            return Singularity.FormFactor.at(monitor ?? Singularity.FormFactor.main_monitor());
        }

        public static bool wants_panel(Gdk.Monitor? monitor = null) {
            var kind = kind_on(monitor);
            return kind != Singularity.FormFactorKind.TV && kind != Singularity.FormFactorKind.WATCH;
        }

        public static bool wants_dock(Gdk.Monitor? monitor = null) {
            var kind = kind_on(monitor);
            return kind == Singularity.FormFactorKind.DESKTOP || kind == Singularity.FormFactorKind.TABLET;
        }

        public static bool wants_workspaces(Gdk.Monitor? monitor = null) {
            return wants_dock(monitor);
        }

        public static int dock_icon_size(GLib.Settings settings, Gdk.Monitor? monitor = null) {
            int size = settings.get_int("dock-icon-size");
            if (kind_on(monitor) == Singularity.FormFactorKind.TABLET) return int.max(size, TABLET_DOCK_ICON_SIZE);
            return size;
        }

        public static bool dock_magnifies(GLib.Settings settings, Gdk.Monitor? monitor = null) {
            return settings.get_boolean("dock-magnification") && !kind_on(monitor).is_touch_first();
        }

        private static Gee.ArrayList<Gdk.Monitor> monitors() {
            var list = new Gee.ArrayList<Gdk.Monitor>();
            var display = Gdk.Display.get_default();
            if (display == null) return list;
            var model = display.get_monitors();
            for (uint i = 0; i < model.get_n_items(); i++) list.add((Gdk.Monitor) model.get_item(i));
            return list;
        }

        private Screen? screen_for(Gdk.Monitor? monitor) {
            foreach (var screen in _screens) {
                if (screen.monitor == monitor) return screen;
            }
            return null;
        }

        private static bool on_monitor(void* handle, Gdk.Monitor? monitor) {
            if (monitor == null || monitors().size < 2) return true;
            var wm = Singularity.wayland_get_window_monitor(handle);
            return wm == null ? Singularity.FormFactor.is_main(monitor) : wm == monitor;
        }

        private static Gdk.Monitor? active_monitor() {
            return AppSystem.get_default().get_active_monitor() ?? Singularity.FormFactor.main_monitor();
        }

        public bool go_home(Gdk.Monitor? monitor = null) {
            var target = monitor ?? active_monitor();
            var kind = kind_on(target);
            if (kind != Singularity.FormFactorKind.TV && kind != Singularity.FormFactorKind.WATCH) return false;
            if (_switcher != null) _switcher.dismiss();
            SnapController.get_default().dismiss_assist();
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (on_monitor(win.handle, target)) Singularity.minimize_window(win.handle);
            }
            var screen = screen_for(target);
            if (screen != null && screen.tv != null) {
                screen.tv.play_enter();
                screen.tv.focus_first();
            }
            if (screen != null && screen.watch != null) screen.watch.show_face();
            return true;
        }

        public void hide_recents() {
            if (_switcher != null) _switcher.dismiss();
        }

        public void show_recents(Gdk.Monitor? monitor = null) {
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
            _switcher.open(monitor ?? active_monitor());
        }

        public void sync() {
            if (_switcher != null) _switcher.dismiss();
            var current = monitors();
            var stale = new Gee.ArrayList<Screen>();
            foreach (var screen in _screens) {
                if (!current.contains(screen.monitor) || kind_on(screen.monitor) != screen.kind) stale.add(screen);
            }
            foreach (var screen in stale) {
                screen.destroy_surfaces();
                _screens.remove(screen);
            }
            foreach (var monitor in current) {
                if (screen_for(monitor) != null) continue;
                var screen = new Screen();
                screen.monitor = monitor;
                screen.kind = kind_on(monitor);
                build_surfaces(screen);
                _screens.add(screen);
            }
            if (current.size == 1) resize_nested(kind_on(current[0]));
            foreach (var win in AppSystem.get_default().get_windows()) apply_window(win.handle);
            update_companion();
        }

        private void build_surfaces(Screen screen) {
            var monitor = screen.monitor;
            switch (screen.kind) {
                case Singularity.FormFactorKind.PHONE:
                    screen.nav = new PhoneNavBar(_app, monitor);
                    screen.nav.back_requested.connect(() => go_back());
                    screen.nav.home_requested.connect(() => home_requested(monitor));
                    screen.nav.recents_requested.connect(() => show_recents(monitor));
                    screen.nav.next_requested.connect(() => next_requested());
                    screen.nav.previous_requested.connect(() => previous_requested());
                    screen.nav.companion_requested.connect(() => open_companion(monitor));
                    screen.nav.present();
                    break;
                case Singularity.FormFactorKind.TV:
                    screen.tv = new TvHome(_app, monitor);
                    foreach (var win in AppSystem.get_default().get_windows()) {
                        if (on_monitor(win.handle, monitor)) Singularity.minimize_window(win.handle);
                    }
                    screen.tv.present();
                    screen.tv.play_enter();
                    screen.tv.focus_first();
                    break;
                case Singularity.FormFactorKind.WATCH:
                    screen.watch = new WatchFace(_app, monitor);
                    screen.watch.present();
                    break;
                default:
                    break;
            }
        }

        private AppSystem.Window? window_for(void* handle) {
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (win.handle == handle) return win;
            }
            return null;
        }

        private void apply_window(void* handle) {
            var win = window_for(handle);
            if (win == null || win.is_fullscreen) return;
            var monitor = Singularity.wayland_get_window_monitor(handle) ?? Singularity.FormFactor.main_monitor();
            bool full = kind_on(monitor).is_full_screen();
            if (full) {
                if (!win.is_maximized) {
                    Singularity.wayland_set_maximized(handle, true);
                    _form_maximized.insert(handle, true);
                }
            } else if (_form_maximized.contains(handle)) {
                _form_maximized.remove(handle);
                if (win.is_maximized) Singularity.wayland_set_maximized(handle, false);
            }
        }

        private void on_app_opened(void* handle) {
            Idle.add(() => {
                apply_window(handle);
                return Source.REMOVE;
            });
            var monitor = Singularity.wayland_get_window_monitor(handle) ?? Singularity.FormFactor.main_monitor();
            var kind = kind_on(monitor);
            if (kind != Singularity.FormFactorKind.TABLET && kind != Singularity.FormFactorKind.TV) return;
            int others = 0;
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (win.handle != handle && !win.is_minimized && on_monitor(win.handle, monitor)) others++;
            }
            if (others == 0) return;
            Timeout.add(Singularity.Motion.Duration.LARGE, () => {
                offer_split(handle, monitor, kind);
                return Source.REMOVE;
            });
        }

        private void offer_split(void* handle, Gdk.Monitor? monitor, Singularity.FormFactorKind kind) {
            if (monitor == null) return;
            var geo = monitor.geometry;
            int top = kind == Singularity.FormFactorKind.TABLET ? TABLET_TOP_RESERVE : 0;
            int bottom = kind == Singularity.FormFactorKind.TABLET ? TABLET_BOTTOM_RESERVE : 0;
            var area = SnapRect(geo.x, geo.y + top, geo.width, geo.height - top - bottom);
            SnapController.get_default().assist_split(handle, area);
        }

        private Gdk.Monitor? companion_target(Gdk.Monitor phone, out CompanionMode mode) {
            mode = CompanionMode.TOUCHPAD;
            foreach (var monitor in monitors()) {
                if (monitor == phone) continue;
                var kind = kind_on(monitor);
                if (kind == Singularity.FormFactorKind.TV) {
                    mode = CompanionMode.REMOTE;
                    return monitor;
                }
                if (kind == Singularity.FormFactorKind.DESKTOP || kind == Singularity.FormFactorKind.TABLET) return monitor;
            }
            return null;
        }

        private void update_companion() {
            foreach (var screen in _screens) {
                if (screen.nav == null) continue;
                CompanionMode mode;
                var target = companion_target(screen.monitor, out mode);
                screen.nav.set_companion(target != null, mode == CompanionMode.REMOTE);
            }
            if (_pad != null) {
                bool keep = false;
                foreach (var screen in _screens) {
                    CompanionMode mode;
                    if (screen.nav != null && companion_target(screen.monitor, out mode) != null) keep = true;
                }
                if (!keep) _pad.dismiss();
            }
        }

        private void open_companion(Gdk.Monitor phone) {
            CompanionMode mode;
            var target = companion_target(phone, out mode);
            if (target == null) return;
            if (_pad != null) return;
            _pad = new CompanionPad(_app, phone, mode);
            _pad.home_requested.connect(() => {
                if (!go_home(target)) home_requested(target);
            });
            _pad.done.connect(() => {
                var old = _pad;
                _pad = null;
                Idle.add(() => {
                    old.destroy();
                    return Source.REMOVE;
                });
            });
            _pad.open();
        }

        private void offer_new_outputs() {
            var current = monitors();
            var seen = new Gee.HashSet<string>();
            Gdk.Monitor? fresh = null;
            foreach (var monitor in current) {
                string connector = connector_of(monitor);
                seen.add(connector);
                if (!_known_outputs.contains(connector) && !Singularity.FormFactor.is_main(monitor)) fresh = monitor;
            }
            _known_outputs.clear();
            _known_outputs.add_all(seen);
            if (fresh == null || !Singularity.FormFactor.get_default().outputs_configurable) return;
            if (_chooser != null) _chooser.destroy();
            _chooser = new ScreenChooser(_app, Singularity.FormFactor.main_monitor(), fresh);
            _chooser.finished.connect(() => {
                var old = _chooser;
                _chooser = null;
                Idle.add(() => {
                    if (old != null) old.destroy();
                    return Source.REMOVE;
                });
            });
            _chooser.open();
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
