using Gtk;
using GtkLayerShell;

namespace Singularity {

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
            public SplitDivider? split = null;
            public PhoneHome? home = null;

            public void destroy_surfaces() {
                if (home != null) { home.destroy(); home = null; }
                if (split != null) { split.destroy(); split = null; }
                if (nav != null) { nav.destroy(); nav = null; }
                if (tv != null) { tv.destroy(); tv = null; }
                if (watch != null) { watch.destroy(); watch = null; }
            }
        }

        private unowned Gtk.Application _app;
        private Gee.ArrayList<Screen> _screens = new Gee.ArrayList<Screen>();
        private HashTable<void*, bool> _form_maximized = new HashTable<void*, bool>(direct_hash, direct_equal);
        private Gee.HashSet<string> _known_outputs = new Gee.HashSet<string>();
        private Gee.HashMap<string, uint> _paced = new Gee.HashMap<string, uint>();
        private bool _pacing_ready = false;
        private RecentsSwitcher? _switcher = null;
        private CompanionPad? _pad = null;
        private ScreenChooser? _chooser = null;
        private bool _keymap_ready = false;

        public signal void home_requested(Gdk.Monitor? monitor);
        public signal bool launcher_pull_begin(Gdk.Monitor? monitor);
        public signal void wallpaper_requested();
        public signal void launcher_pull_update(Gdk.Monitor? monitor, double dy);
        public signal void launcher_pull_end(Gdk.Monitor? monitor, double dy);
        public signal bool shade_pull_begin(Gdk.Monitor? monitor);
        public signal void shade_pull_update(Gdk.Monitor? monitor, double dy);
        public signal void shade_pull_end(Gdk.Monitor? monitor, double dy);
        public signal void next_requested();
        public signal void previous_requested();

        public FormShell(Gtk.Application app) {
            _app = app;
            var app_system = AppSystem.get_default();
            app_system.app_opened.connect((handle, app_id) => {
                on_app_opened(handle);
                sync_pacing();
            });
            app_system.window_output_changed.connect((handle) => apply_window(handle));
            app_system.app_closed.connect((handle) => {
                _form_maximized.remove(handle);
                sync_pacing();
                Idle.add(() => {
                    fill_after_close(handle);
                    return Source.REMOVE;
                });
            });
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
            app_system.window_state_changed.connect((handle) => queue_layout_check());
            app_system.window_geometry_changed.connect((handle) => queue_layout_check());
            app_system.window_output_changed.connect((handle) => queue_layout_check());
            app_system.app_opened.connect((handle, app_id) => queue_layout_check());
            app_system.app_closed.connect((handle) => queue_layout_check());
            app_system.workspaces_changed.connect(queue_layout_check);
            watch_geometry();
        }

        private bool watches_layout() {
            foreach (var screen in _screens) {
                if (screen.kind == Singularity.FormFactorKind.TABLET || screen.tv != null) return true;
            }
            return false;
        }

        private void watch_geometry() {
            bool want = watches_layout();
            if (want == _watching_geometry) return;
            _watching_geometry = want;
            bool pushed = Singularity.wayland_set_geometry_updates(want);
            if (_layout_poll != 0) {
                Source.remove(_layout_poll);
                _layout_poll = 0;
            }
            if (want && !pushed) {
                _layout_poll = Timeout.add(LAYOUT_POLL_MS, () => {
                    queue_layout_check();
                    return Source.CONTINUE;
                });
            }
            if (want) queue_layout_check();
        }

        private void queue_layout_check() {
            if (_layout_check != 0 || !_watching_geometry) return;
            _layout_check = Idle.add(() => {
                _layout_check = 0;
                update_splits();
                sync_tv_keyboard();
                return Source.REMOVE;
            });
        }

        private const uint LAYOUT_POLL_MS = 400;
        private bool _watching_geometry = false;
        private uint _layout_poll = 0;
        private uint _layout_check = 0;
        private uint _keyboard_recheck = 0;
        private const uint TV_INTERFACE_RATE = 30;
        private const int SPLIT_MAX_GAP = 40;
        private const double SPLIT_MIN_HEIGHT = 0.6;

        private struct PaneGeometry {
            void* handle;
            int x;
            int y;
            int width;
            int height;
        }

        private void update_splits() {
            foreach (var screen in _screens) {
                if (screen.kind != Singularity.FormFactorKind.TABLET) continue;
                if (screen.split != null && screen.split.dragging) continue;
                PaneGeometry left, right;
                if (!find_split(screen.monitor, out left, out right)) {
                    if (screen.split != null) {
                        screen.split.destroy();
                        screen.split = null;
                    }
                    continue;
                }
                if (screen.split == null) {
                    screen.split = new SplitDivider(_app, screen.monitor, TABLET_TOP_RESERVE, TABLET_BOTTOM_RESERVE);
                    screen.split.dismissed_side.connect((gone, kept) => {
                        Singularity.minimize_window(gone);
                        Singularity.wayland_set_maximized(kept, true);
                        _form_maximized.insert(kept, true);
                    });
                    screen.split.present();
                }
                int gap = right.x - (left.x + left.width);
                screen.split.track(left.handle, right.handle, left.x + left.width + gap / 2, gap);
            }
        }

        private bool find_split(Gdk.Monitor monitor, out PaneGeometry left, out PaneGeometry right) {
            left = PaneGeometry();
            right = PaneGeometry();
            PaneGeometry[] panes = {};
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (win.is_minimized || win.is_fullscreen || !on_monitor(win.handle, monitor)) continue;
                int x, y, w, h, maximized, fullscreen;
                string? connector;
                if (!Singularity.wayland_get_window_geometry(win.handle, out x, out y, out w, out h,
                        out maximized, out fullscreen, out connector)) continue;
                if (maximized != 0 || fullscreen != 0) return false;
                panes += PaneGeometry() { handle = win.handle, x = x, y = y, width = w, height = h };
                if (panes.length > 2) return false;
            }
            if (panes.length != 2) return false;
            var a = panes[0].x <= panes[1].x ? panes[0] : panes[1];
            var b = panes[0].x <= panes[1].x ? panes[1] : panes[0];
            int gap = b.x - (a.x + a.width);
            int min_height = (int) ((monitor.geometry.height - TABLET_TOP_RESERVE - TABLET_BOTTOM_RESERVE) * SPLIT_MIN_HEIGHT);
            if (gap < 0 || gap > SPLIT_MAX_GAP || a.height < min_height || b.height < min_height) return false;
            left = a;
            right = b;
            return true;
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
            if (KioskMode.get_default().active) return false;
            var kind = kind_on(monitor);
            return kind != Singularity.FormFactorKind.TV && kind != Singularity.FormFactorKind.WATCH;
        }

        public static bool wants_desktop_icons(Gdk.Monitor? monitor = null) {
            if (KioskMode.get_default().active) return false;
            return kind_on(monitor) != Singularity.FormFactorKind.PHONE;
        }

        public static bool wants_dock(Gdk.Monitor? monitor = null) {
            if (KioskMode.get_default().active) return false;
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

        private HomeGesture home_gesture_for(Screen screen) {
            var monitor = screen.monitor;
            var gesture = new HomeGesture(monitor);
            gesture.home_reached.connect(() => {
                if (_switcher != null) _switcher.dismiss();
                SnapController.get_default().dismiss_assist();
                var current = screen_for(monitor);
                if (current != null && current.home != null) {
                    current.home.leave_edit();
                    current.home.leave_hub();
                }
            });
            gesture.recents_requested.connect(() => show_recents(monitor));
            return gesture;
        }

        public bool go_home(Gdk.Monitor? monitor = null) {
            var target = monitor ?? active_monitor();
            var kind = kind_on(target);
            if (kind != Singularity.FormFactorKind.TV && kind != Singularity.FormFactorKind.WATCH
                    && kind != Singularity.FormFactorKind.PHONE && kind != Singularity.FormFactorKind.TABLET) return false;
            if (_switcher != null) _switcher.dismiss();
            SnapController.get_default().dismiss_assist();
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (on_monitor(win.handle, target)) Singularity.minimize_window(win.handle);
            }
            var screen = screen_for(target);
            if (screen != null && screen.tv != null) {
                screen.tv.own_keyboard(true);
                screen.tv.play_enter();
                screen.tv.focus_first();
            }
            if (screen != null && screen.watch != null) screen.watch.show_face();
            if (screen != null && screen.home != null) {
                screen.home.leave_edit();
                screen.home.leave_hub();
                screen.home.go_to_page(0);
            }
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
            sync_pacing();
            watch_geometry();
        }

        private void build_surfaces(Screen screen) {
            if (KioskMode.get_default().active) return;
            var monitor = screen.monitor;
            switch (screen.kind) {
                case Singularity.FormFactorKind.PHONE:
                    screen.nav = new PhoneNavBar(_app, monitor);
                    screen.nav.gesture = home_gesture_for(screen);
                    screen.nav.back_requested.connect(() => go_back());
                    screen.nav.home_requested.connect(() => {
                        if (!go_home(monitor)) home_requested(monitor);
                    });
                    screen.nav.pull_update.connect((dy) => launcher_pull_update(monitor, dy));
                    screen.nav.pull_end.connect((dy) => launcher_pull_end(monitor, dy));
                    screen.nav.recents_requested.connect(() => show_recents(monitor));
                    screen.nav.next_requested.connect(() => next_requested());
                    screen.nav.previous_requested.connect(() => previous_requested());
                    screen.nav.companion_requested.connect(() => open_companion(monitor));
                    screen.nav.present();
                    screen.home = new PhoneHome(_app, monitor);
                    screen.home.wallpaper_requested.connect(() => wallpaper_requested());
                    screen.home.present();
                    break;
                case Singularity.FormFactorKind.TABLET:
                    screen.nav = new PhoneNavBar(_app, monitor, true);
                    screen.nav.gesture = home_gesture_for(screen);
                    screen.nav.home_requested.connect(() => {
                        if (!go_home(monitor)) home_requested(monitor);
                    });
                    screen.nav.recents_requested.connect(() => show_recents(monitor));
                    screen.nav.next_requested.connect(() => next_requested());
                    screen.nav.previous_requested.connect(() => previous_requested());
                    screen.nav.present();
                    screen.home = new PhoneHome(_app, monitor, true);
                    screen.home.wallpaper_requested.connect(() => wallpaper_requested());
                    screen.home.present();
                    break;
                case Singularity.FormFactorKind.TV:
                    screen.tv = new TvHome(_app, monitor);
                    foreach (var win in AppSystem.get_default().get_windows()) {
                        if (on_monitor(win.handle, monitor)) Singularity.minimize_window(win.handle);
                    }
                    screen.tv.present();
                    screen.tv.play_enter();
                    screen.tv.focus_first();
                    sync_tv_keyboard();
                    break;
                case Singularity.FormFactorKind.WATCH:
                    screen.watch = new WatchFace(_app, monitor);
                    screen.watch.pull_begin.connect(() => shade_pull_begin(monitor));
                    screen.watch.pull_update.connect((dy) => shade_pull_update(monitor, dy));
                    screen.watch.pull_end.connect((dy) => shade_pull_end(monitor, dy));
                    screen.watch.present();
                    break;
                default:
                    break;
            }
        }

        private static bool covered_by_app(Gdk.Monitor? monitor) {
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (!win.is_minimized && on_monitor(win.handle, monitor)) return true;
            }
            return false;
        }

        private void sync_tv_keyboard() {
            foreach (var screen in _screens) {
                if (screen.tv == null) continue;
                bool covered = covered_by_app(screen.monitor);
                if (!covered && screen.tv.recently_released()) {
                    recheck_keyboard_later();
                    continue;
                }
                screen.tv.own_keyboard(!covered);
            }
            sync_pacing();
        }

        private void recheck_keyboard_later() {
            if (_keyboard_recheck != 0) return;
            _keyboard_recheck = Timeout.add_seconds(TvHome.RELEASE_HOLD_SECONDS, () => {
                _keyboard_recheck = 0;
                sync_tv_keyboard();
                return Source.REMOVE;
            });
        }

        private void sync_pacing() {
            if (!_pacing_ready) {
                if (!Singularity.FramePacingBridge.init()) return;
                _pacing_ready = true;
            }
            foreach (var monitor in monitors()) {
                uint rate = 0;
                if (kind_on(monitor) == Singularity.FormFactorKind.TV && !covered_by_app(monitor)) rate = TV_INTERFACE_RATE;
                string connector = connector_of(monitor);
                if (_paced.has_key(connector) && _paced[connector] == rate) continue;
                _paced[connector] = rate;
                Singularity.FramePacingBridge.set(connector, rate);
            }
        }

        private AppSystem.Window? window_for(void* handle) {
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (win.handle == handle) return win;
            }
            return null;
        }

        private bool is_secondary(AppSystem.Window win) {
            if (win.app_id == null || win.app_id == "") return false;
            foreach (var other in AppSystem.get_default().get_windows()) {
                if (other.handle != win.handle && other.app_id == win.app_id && !other.is_minimized) return true;
            }
            return false;
        }

        private void apply_window(void* handle) {
            var win = window_for(handle);
            if (win == null || win.is_fullscreen) return;
            if (!_form_maximized.contains(handle) && is_secondary(win)) return;
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

        private void fill_after_close(void* closed) {
            foreach (var monitor in monitors()) {
                var kind = kind_on(monitor);
                if (kind != Singularity.FormFactorKind.TABLET && kind != Singularity.FormFactorKind.TV) continue;
                AppSystem.Window? last = null;
                int count = 0;
                foreach (var win in AppSystem.get_default().get_windows()) {
                    if (win.handle == closed || win.is_minimized || !on_monitor(win.handle, monitor)) continue;
                    last = win;
                    count++;
                }
                if (count != 1 || last.is_maximized || last.is_fullscreen) continue;
                Singularity.wayland_set_maximized(last.handle, true);
                _form_maximized.insert(last.handle, true);
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
            var opened = window_for(handle);
            if (opened != null && is_secondary(opened)) return;
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
            foreach (var screen in _screens) {
                if (screen.home != null && screen.home.leave_edit()) return;
                if (screen.home != null && screen.home.hub_back()) return;
                if (screen.home != null && screen.home.leave_hub()) return;
            }
            if (!_keymap_ready) _keymap_ready = ScreenKeymap.get_default().ensure();
            Singularity.osk_press(ESCAPE_KEYCODE, 0);
        }
    }
}
