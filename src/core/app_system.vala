using Gtk;
using GLib;
using Gdk;

namespace Singularity {

    public class AppSystem : Object {
        private static AppSystem? _instance = null;
        private GLib.Settings settings;
        private HashTable<string, AppInfo> installed_apps_map;
        private HashTable<string, AppInfo> steam_app_map;
        private List<AppInfo> installed_apps_list;
        // Keeps the GLib.AppInfo objects alive - AppInfo is a Vala interface so
        // neither HashTable nor List generates g_object_ref/unref for it automatically.
        // Without this, the GList returned by AppInfo.get_all() is freed at the end of
        // scan_apps(), leaving dangling pointers in installed_apps_map, g_object_ref crash.
        private List<AppInfo> _app_info_owner;
        private List<string> running_apps_list;
        public string[] pinned_apps { get; private set; }
        public string dock_position { get; private set; }
        public bool dynamic_workspaces { get; private set; }
        public int workspace_count { get; private set; }
        public bool is_container { get; private set; default = false; }
        public signal void config_changed(string key);
        public signal void apps_changed();
        public signal void running_apps_changed();
        public signal void window_output_changed(void* handle);
        public signal void app_focused(string? app_id);
        public signal void window_focused(void* handle);
        public signal void app_opened(void* handle, string app_id);
        public signal void app_closed(void* handle);
        public signal void menu_model_changed(MenuModel? model);
        public signal void desktop_action_requested(string action);
        public signal void pulse_app_requested(string app_id);
        public MenuModel? current_menu_model { get; private set; }
        public ActionGroup? current_action_group { get; private set; }
        public ActionGroup? current_app_action_group { get; private set; }
        public ActionGroup? current_win_action_group { get; private set; }
        private int menu_generation = 0;
        private bool _menu_promoted = false;
        private bool _setting_grid_order = false;
        private string current_menu_app_id = "";
        private Dbusmenu.Client? dbusmenu_client;
        private HashTable<string, string> bus_menu_map;
        private AppMenuRegistrar registrar;
        private GLib.DBusConnection? _session_bus = null;
        private void* current_focused_window_handle = null;
        private string? current_focused_app_id = null;
        private GLib.AppInfoMonitor _app_info_monitor;
        private uint _app_rescan_timer = 0;

        public static bool activate_next_created_workspace = false;
        public static Window? window_to_move_to_new_workspace = null;
        // Updated by Panel/Dock on allocation so screenshot geometry is accurate
        public int shell_panel_height = 32;
        public int shell_dock_height = 56;

        public List<string> get_running_apps() {
            var list = new List<string>();
            foreach (var app in running_apps_list) {
                list.append(app);
            }
            return list;
        }

        public List<Window> get_windows() {
            var list = new List<Window>();
            foreach (var win in windows) {
                list.append(win);
            }
            return list;
        }

        public List<Window> get_active_workspace_windows() {
            var list = new List<Window>();
            foreach (var ws in workspaces) {
                if (ws.active) {
                    foreach (var win in ws.windows) {
                        list.append(win);
                    }
                    break;
                }
            }
            return list;
        }

        public string? get_focused_app_id() {
            return current_focused_app_id;
        }

        public void* get_focused_window_handle() {
            return current_focused_window_handle;
        }

        public class Workspace : Object {
            public void* handle;
            public string name;
            public bool active;
            public List<Window> windows;

            public Workspace(void* handle, string name) {
                this.handle = handle;
                this.name = name;
                this.active = false;
                this.windows = new List<Window>();
            }
        }

        public class Window : Object {
            public void* handle;
            public string app_id;
            public string title;
            public string icon_name;
            public Icon? gicon;
            public bool is_maximized;
            public bool is_fullscreen;
            public bool is_minimized;
            public uint snap_type = 0; // last snap type applied by TilingManager (SNAP_* constants)

            public Window(void* handle, string app_id) {
                this.handle = handle;
                this.app_id = app_id.dup();
                this.title = app_id.dup();
                this.icon_name = app_id.dup();
                this.gicon = null;
                this.is_maximized = false;
                this.is_fullscreen = false;
                this.is_minimized = false;
            }
        }

        private List<Workspace> workspaces;
        private List<Window> windows;
        private List<Window> mru_windows; // Most Recently Used order
        private bool _ws_changed_pending = false;
        private bool _running_changed_pending = false;
        public signal void workspaces_changed();
        public signal void app_title_changed(Window win);
        public signal void any_maximized_changed();
        public signal void any_fullscreen_changed();

        public static AppSystem get_default() {
            if (_instance == null) {
                _instance = new AppSystem();
            }
            return _instance;
        }

        private AppSystem() {
            installed_apps_map = new HashTable<string, AppInfo>(str_hash, str_equal);
            steam_app_map = new HashTable<string, AppInfo>(str_hash, str_equal);
            installed_apps_list = new List<AppInfo>();
            running_apps_list = new List<string>();
            workspaces = new List<Workspace>();
            windows = new List<Window>();
            mru_windows = new List<Window>();
            bus_menu_map = new HashTable<string, string>(str_hash, str_equal);
            settings = new GLib.Settings("dev.sinty.desktop");
            load_settings();
            load_folders();
            if (FileUtils.test("/run/.containerenv", FileTest.EXISTS) || FileUtils.test("/.dockerenv", FileTest.EXISTS)) {
                is_container = true;
            }
            Idle.add(() => {
                scan_apps();
                enable_atspi_if_needed();
                return Source.REMOVE;
            });
            // Re-scan installed apps when software is added or removed, so the
            // overview, spotlight and settings stay current. AppInfoMonitor is
            // the standard GIO signal and covers every XDG_DATA_DIRS location.
            _app_info_monitor = GLib.AppInfoMonitor.@get();
            _app_info_monitor.changed.connect(() => {
                if (_app_rescan_timer != 0) GLib.Source.remove(_app_rescan_timer);
                _app_rescan_timer = GLib.Timeout.add(700, () => {
                    _app_rescan_timer = 0;
                    scan_apps();
                    return GLib.Source.REMOVE;
                });
            });
            settings.changed.connect((key) => {
                load_settings();
                config_changed(key);
                if (key == "app-folders") load_folders();
                if (key == "dynamic-workspaces" || key == "workspace-count") {
                    update_workspaces_config();
                }
            });
            Singularity.wayland_init(
                on_app_opened,
                on_app_closed,
                on_app_focused,
                on_app_title_changed,
                on_app_state_changed,
                on_workspace_created,
                on_workspace_destroyed,
                on_workspace_state,
                this
            );
            Singularity.wayland_set_window_output_changed_callback(on_window_output_changed, this);
            update_workspaces_config();
        }

        private void schedule_workspaces_changed() {
            if (_ws_changed_pending) return;
            _ws_changed_pending = true;
            Idle.add(() => {
                _ws_changed_pending = false;
                workspaces_changed();
                return Source.REMOVE;
            });
        }

        private void schedule_running_apps_changed() {
            if (_running_changed_pending) return;
            _running_changed_pending = true;
            Idle.add(() => {
                _running_changed_pending = false;
                running_apps_changed();
                return Source.REMOVE;
            });
        }

        public void set_registrar(AppMenuRegistrar registrar) {
            this.registrar = registrar;
            registrar.menu_registered.connect((id, bus, path) => {
                bus_menu_map.insert(bus, path);
            });
        }

        private static void on_app_title_changed(void* handle, string title, void* data) {
            var self = (AppSystem)data;
            string safe_title = title.dup();
            foreach (var win in self.windows) {
                if (win.handle == handle) {
                    win.title = safe_title;
                    self.app_title_changed(win);
                    break;
                }
            }
        }

        private static void on_app_state_changed(void* handle, int is_maximized, int is_fullscreen, int is_minimized, void* data) {
            var self = (AppSystem)data;
            foreach (var win in self.windows) {
                if (win.handle == handle) {
                    bool was_maximized = win.is_maximized;
                    bool was_fullscreen = win.is_fullscreen;
                    bool was_minimized = win.is_minimized;
                    win.is_maximized = (is_maximized != 0);
                    win.is_fullscreen = (is_fullscreen != 0);
                    win.is_minimized = (is_minimized != 0);
                    // Minimizing the focused window unfocuses it, so clear the
                    // global menu and the app name instead of leaving them on
                    // the panel (#179).
                    if (!was_minimized && win.is_minimized
                            && handle == self.current_focused_window_handle) {
                        self.notify_desktop_focused();
                    }
                    if (was_maximized != win.is_maximized || was_fullscreen != win.is_fullscreen) {
                        PreviewCache.get_default().invalidate(handle);
                    }
                    // A maximized window that gets minimized stops covering the
                    // panel/dock, so re-evaluate maximize-driven state too.
                    if (was_maximized != win.is_maximized || was_minimized != win.is_minimized) {
                        self.any_maximized_changed();
                    }
                    if (was_fullscreen != win.is_fullscreen) {
                        self.any_fullscreen_changed();
                        var gm = GameModeManager.get_default();
                        gm.on_fullscreen_app(win.app_id, win.is_fullscreen);
                    }
                    break;
                }
            }
        }

        public bool has_any_maximized_window() {
            foreach (var win in windows) {
                if (win.is_maximized && !win.is_minimized) return true;
            }
            return false;
        }

        // Per-monitor variant: true only if a maximized window lives on the
        // given monitor. Used so each panel flattens independently - a
        // maximized window on monitor B shouldn't flatten the panel on A.
        public bool has_maximized_window_on_monitor(Gdk.Monitor monitor) {
            var display = Gdk.Display.get_default();
            // Single monitor: any maximized window is necessarily on it.
            if (display != null && display.get_monitors().get_n_items() <= 1)
                return has_any_maximized_window();

            string? target_conn = monitor.get_connector();
            // The "primary" monitor (first in the list) is where windows whose
            // output we cannot resolve are assumed to live - better to flatten
            // the primary than to flatten nothing.
            Gdk.Monitor? primary = (display != null)
                ? display.get_monitors().get_item(0) as Gdk.Monitor : null;
            bool target_is_primary = (primary != null) && (
                primary == monitor ||
                (target_conn != null && primary.get_connector() == target_conn));

            foreach (var win in windows) {
                if (!win.is_maximized || win.is_minimized) continue;
                var wmon = Singularity.wayland_get_window_monitor(win.handle);
                if (wmon == null) {
                    // Unresolvable -> assume primary monitor.
                    if (target_is_primary) return true;
                    continue;
                }
                if (wmon == monitor) return true;
                // Compare by connector too - instances should match but this
                // is immune to any ref/identity quirks.
                if (target_conn != null && wmon.get_connector() == target_conn)
                    return true;
            }
            return false;
        }

        public bool has_any_fullscreen_window() {
            foreach (var win in windows) {
                if (win.is_fullscreen) return true;
            }
            return false;
        }

        public bool is_focused_window_fullscreen() {
            if (current_focused_window_handle == null) return false;
            foreach (var win in windows) {
                if (win.handle == current_focused_window_handle)
                    return win.is_fullscreen;
            }
            return false;
        }

        public static bool add_app_to_desktop(AppInfo app) {
            var entry = app as DesktopAppInfo;
            string? src = (entry != null) ? entry.get_filename() : null;
            if (src == null) return false;
            string desktop_dir = Environment.get_user_special_dir(UserDirectory.DESKTOP)
                ?? Path.build_filename(Environment.get_home_dir(), "Desktop");
            try {
                var dir = File.new_for_path(desktop_dir);
                if (!dir.query_exists()) dir.make_directory_with_parents();
                var dest = dir.get_child(Path.get_basename(src));
                File.new_for_path(src).copy(dest, FileCopyFlags.OVERWRITE);
                string? dpath = dest.get_path();
                if (dpath != null) FileUtils.chmod(dpath, 0755);
                return true;
            } catch (Error e) {
                warning("Failed to add app to desktop: %s", e.message);
                return false;
            }
        }

        private static void on_workspace_created(void* handle, string name, void* data) {
            var self = (AppSystem)data;
            foreach (var ws in self.workspaces) {
                if (ws.handle == handle) return;
            }
            string display_name = name;
            if (name == "Workspace" || name == "") {
                display_name = "%d".printf((int)self.workspaces.length() + 1);
            }
            var new_ws = new Workspace(handle, display_name);
            self.workspaces.append(new_ws);
            self.schedule_workspaces_changed();

            if (window_to_move_to_new_workspace != null) {
                var win = window_to_move_to_new_workspace;
                window_to_move_to_new_workspace = null;
                self.move_window_to_workspace(win, new_ws);
            }

            if (activate_next_created_workspace) {
                activate_next_created_workspace = false;
                GLib.Idle.add(() => {
                    self.activate_workspace(new_ws);
                    return GLib.Source.REMOVE;
                });
            }
        }

        private static void on_workspace_destroyed(void* handle, void* data) {
            var self = (AppSystem)data;
            Workspace? found = null;
            foreach (var ws in self.workspaces) {
                if (ws.handle == handle) {
                    found = ws;
                    break;
                }
            }
            if (found != null) {
                self.workspaces.remove(found);
                self.schedule_workspaces_changed();
            }
        }

        private static void on_workspace_state(void* handle, uint32 state, void* data) {
            var self = (AppSystem)data;
            bool is_active = (state & 1) != 0;
            foreach (var ws in self.workspaces) {
                if (ws.handle == handle) {
                    ws.active = is_active;
                } else if (is_active) {
                    ws.active = false;
                }
            }
            self.schedule_workspaces_changed();
        }

        public unowned List<Workspace> get_workspaces() {
            return workspaces;
        }

        public void activate_workspace(Workspace ws) {
            Singularity.wayland_activate_workspace(ws.handle);
        }

        public void move_window_to_workspace_by_index(Window? win, int workspace_index) {
            if (win == null) return;
            Workspace? target_ws = null;
            int current_idx = 0;
            foreach (var ws in workspaces) {
                if (current_idx == workspace_index) {
                    target_ws = ws;
                    break;
                }
                current_idx++;
            }
            if (target_ws != null) {
                Singularity.wayland_move_to_workspace(win.handle, (uint32)workspace_index);
                foreach (var ws in workspaces) {
                    if (ws.windows.find(win) != null) {
                        ws.windows.remove(win);
                        break;
                    }
                }
                target_ws.windows.append(win);
                schedule_workspaces_changed();
            }
        }

        private static void on_app_opened(void* handle, string app_id, void* data) {
            var self = (AppSystem)data;
            self.add_running_app(handle, app_id);
        }

        private static void on_app_closed(void* handle, void* data) {
            var self = (AppSystem)data;
            self.remove_running_app(handle);
        }

        private static void on_window_output_changed(void* handle, void* data) {
            var self = (AppSystem)data;
            Idle.add(() => {
                self.window_output_changed(handle);
                self.running_apps_changed();
                return Source.REMOVE;
            });
        }

        private static void on_app_focused(void* handle, void* data) {
            var self = (AppSystem)data;
            self.handle_app_focused(handle);
        }

        public void move_window_to_workspace(Window? win, Workspace ws) {
            if (win == null) return;
            int target_index = -1;
            int idx = 0;
            foreach (var w in workspaces) {
                if (w == ws) {
                    target_index = idx;
                    break;
                }
                idx++;
            }
            if (target_index < 0) return;
            Singularity.wayland_move_to_workspace(win.handle, (uint32)target_index);
            foreach (var w in workspaces) {
                if (w.windows.find(win) != null) {
                    w.windows.remove(win);
                    break;
                }
            }
            ws.windows.append(win);
            schedule_workspaces_changed();
        }

        public Window? get_window_by_handle(void* handle) {
            foreach (var win in windows) {
                if (win.handle == handle) return win;
            }
            return null;
        }

        // Called directly by the Background component when the wallpaper is clicked.
        // Layer-shell surfaces don't participate in foreign-toplevel focus events,
        // so the background explicitly pokes us here.

        public void notify_desktop_focused() {
            current_focused_app_id = "";
            current_focused_window_handle = null;
            app_focused(null);
            window_focused(null);
            update_menu_model("");
        }

        private void handle_app_focused(void* handle) {
            Window? found = null;
            foreach (var win in windows) {
                if (win.handle == handle) { found = win; break; }
            }
            current_focused_window_handle = handle;
            window_focused(handle);
            // Update MRU order
            if (found != null) {
                if (mru_windows.find(found) != null) mru_windows.remove(found);
                mru_windows.prepend(found);
                string clean_id = clean_string(found.app_id);
                if (clean_id == current_focused_app_id) return;
                current_focused_app_id = clean_id;
                app_focused(clean_id.length > 0 ? clean_id : null);
                update_menu_model(clean_id);
            } else {
                // No window focused, desktop is active; show OS menu
                if (current_focused_app_id != "") {
                    current_focused_app_id = "";
                    app_focused(null);
                    update_menu_model("");
                }
            }
        }

        public List<Window> get_mru_windows() {
            // Return windows sorted by MRU, filtered to tracked windows
            var list = new List<Window>();
            foreach (var win in mru_windows) {
                if (windows.find(win) != null) list.append(win);
            }
            // Add any windows not yet focused (append at end)
            foreach (var win in windows) {
                if (list.find(win) == null) list.append(win);
            }
            return list;
        }

        private string clean_string(string input) {
            if (input == null || input == "") return "";

            // Allow only alphanumeric, dots, dashes and underscores
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < input.length; i++) {
                char c = input[i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                    c == '.' || c == '-' || c == '_') {
                    sb.append_c(c);
                } else if (c == '\0' || c < 32) {
                    break; // Stop at first null or control char
                }
            }
            string res = sb.str.strip();
            return (res.length > 0) ? res : "";
        }

        private void update_menu_model(string app_id) {
            menu_generation++;
            int gen = menu_generation;
            string safe_id = clean_string(app_id);
            // Wayland app_id often has .desktop suffix – strip it for DBus lookup
            if (safe_id.has_suffix(".desktop"))
                safe_id = safe_id[0:safe_id.length - 8];

            current_action_group = null;
            current_app_action_group = null;
            current_win_action_group = null;
            dbusmenu_client = null;
            current_menu_model = null;

            var group = new SimpleActionGroup();

            var quit_action = new SimpleAction("quit", null);
            string quit_app_id = safe_id;
            quit_action.activate.connect(() => {
                foreach (var win in windows) {
                    if (win.app_id == quit_app_id ||
                        win.app_id.has_prefix(quit_app_id + ".") ||
                        win.app_id.has_suffix("." + quit_app_id)) {
                        Singularity.close_window(win.handle);
                    }
                }
            });
            group.add_action(quit_action);

            // Capture the window this menu is built for: opening the menu can
            // move the seat focus, so the live focused handle is unreliable at
            // click time.
            void* menu_win = current_focused_window_handle;

            var minimize_action = new SimpleAction("minimize", null);
            minimize_action.activate.connect(() => {
                if (menu_win != null) Singularity.minimize_window(menu_win);
            });
            group.add_action(minimize_action);

            var maximize_action = new SimpleAction("maximize", null);
            maximize_action.activate.connect(() => {
                if (menu_win != null)
                    Singularity.wayland_snap_view(menu_win, TilingLayout.SNAP_MAXIMIZE);
            });
            group.add_action(maximize_action);

            var snap_left_action = new SimpleAction("snap-left", null);
            snap_left_action.activate.connect(() => {
                if (menu_win != null)
                    Singularity.wayland_snap_view(menu_win, TilingLayout.SNAP_LEFT);
            });
            group.add_action(snap_left_action);

            var snap_right_action = new SimpleAction("snap-right", null);
            snap_right_action.activate.connect(() => {
                if (menu_win != null)
                    Singularity.wayland_snap_view(menu_win, TilingLayout.SNAP_RIGHT);
            });
            group.add_action(snap_right_action);

            current_action_group = group;
            current_menu_app_id = safe_id;
            // Emit fallback immediately so panel is never blank
            emit_menu(gen, null, group);

            // Desktop focused: OS menu is already emitted, no DBus lookups needed
            if (safe_id == "") return;

            // Attempt GTK4 DBus menu (async, items arrive via items_changed)
            string? bus_name = derive_bus_name(safe_id);
            if (bus_name != null) {
                try {
                    if (_session_bus == null)
                        _session_bus = Bus.get_sync(BusType.SESSION);
                    var connection = _session_bus;
                    string menu_path = "/" + bus_name.replace(".", "/") + "/menus/menubar";
                    var gtk4_model = GLib.DBusMenuModel.get(connection, bus_name, menu_path);
                    var app_ag = GLib.DBusActionGroup.get(connection, bus_name, "/" + bus_name.replace(".", "/"));
                    var win_ag = GLib.DBusActionGroup.get(connection, bus_name,
                        "/" + bus_name.replace(".", "/") + "/window/1");
                    // Touch model to trigger DBus subscription
                    gtk4_model.get_n_items();
                    _menu_promoted = false;
                    gtk4_model.items_changed.connect((pos, removed, added) => {
                        if (menu_generation != gen || _menu_promoted) return;
                        if (gtk4_model.get_n_items() > 0) {
                            _menu_promoted = true;
                            current_app_action_group = app_ag;
                            current_win_action_group = win_ag;
                            emit_menu(gen, gtk4_model, group);
                        }
                    });
                    Timeout.add(100, () => {
                        if (menu_generation != gen) return Source.REMOVE;
                        if (!_menu_promoted && gtk4_model.get_n_items() > 0) {
                            _menu_promoted = true;
                            current_app_action_group = app_ag;
                            current_win_action_group = win_ag;
                            emit_menu(gen, gtk4_model, group);
                        } else if (!_menu_promoted) {
                            // GTK4 menubar empty, try actions-based menu (libadwaita apps)
                            string captured_bus = bus_name.dup();
                            GtkActionsMenuProvider.build_menu_async(captured_bus, (actions_menu) => {
                                if (menu_generation != gen || _menu_promoted) return;
                                if (actions_menu != null && actions_menu.get_n_items() > 0) {
                                    _menu_promoted = true;
                                    current_app_action_group = app_ag;
                                    current_win_action_group = win_ag;
                                    emit_menu(gen, actions_menu, group);
                                } else {
                                    try_dbusmenu(gen, safe_id, group);
                                }
                            });
                        }
                        return Source.REMOVE;
                    });
                } catch (Error e) {
                    warning("Menu GTK4 lookup error: %s", e.message);
                    try_dbusmenu(gen, safe_id, group);
                }
            } else {
                try_dbusmenu(gen, safe_id, group);
            }
        }

        private string? derive_bus_name(string safe_id) {
            if (safe_id.length == 0) return null;
            if (safe_id.contains(".")) {
                if (is_valid_dbus_name(safe_id)) return safe_id;
                return null;
            }
            var ai = get_app_info(safe_id);
            if (ai != null) {
                string? id = ai.get_id();
                if (id != null && id.has_suffix(".desktop")) id = id[0:id.length - 8];
                if (id != null && id.contains(".") && is_valid_dbus_name(id)) return id;
            }
            return null;
        }

        // Validate a D-Bus well-known bus name: elements separated by dots,
        // each element matches [A-Za-z_][A-Za-z0-9_]* (no hyphens allowed).

        private static bool is_valid_dbus_name(string name) {
            if (name.length == 0) return false;
            string[] parts = name.split(".");
            if (parts.length < 2) return false;
            foreach (string part in parts) {
                if (part.length == 0) return false;
                for (int i = 0; i < part.length; i++) {
                    char c = part[i];
                    bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' ||
                              (i > 0 && (c >= '0' && c <= '9'));
                    if (!ok) return false;
                }
            }
            return true;
        }

        private void try_dbusmenu(int gen, string safe_id, SimpleActionGroup group) {
            if (menu_generation != gen) return;
            if (registrar == null) {
                try_atspi(gen, safe_id, group);
                return;
            }
            // Prefer matching by the active window's XID: the app registered
            // its menu against that window id, and process-name matching fails
            // for sandboxed apps (they all look like "xdg-dbus-proxy") (#82).
            string? bus = null;
            string? path = null;
            uint32 xid = Singularity.xwayland_active_window();
            if (xid != 0) {
                bus = registrar.get_bus_for_window(xid);
                path = registrar.get_path_for_window(xid);
            }
            string name_to_try = safe_id;
            if (safe_id.contains(".")) {
                string[] parts = safe_id.split(".");
                name_to_try = parts[parts.length - 1].down();
            }
            if (bus == null || path == null) {
                bus = registrar.get_bus_for_app(name_to_try);
                path = registrar.get_path_for_app(name_to_try);
            }
            if (bus != null && path != null) {
                var client = new Dbusmenu.Client(bus, path);
                dbusmenu_client = client;
                var dbus_model = new DBusMenuAdapter(client, null, true);
                var act_activate = new SimpleAction("activate", new VariantType("i"));
                act_activate.activate.connect((param) => {
                    int id = param.get_int32();
                    var item = find_dbusmenu_item(client.get_root(), id);
                    if (item != null) item.handle_event(Dbusmenu.MENUITEM_EVENT_ACTIVATED, new Variant.int32(0), 0);
                });
                group.add_action(act_activate);
                emit_menu(gen, dbus_model, group);
                return;
            }
            // No dbusmenu bus/path, try AT-SPI as last resort
            try_atspi(gen, safe_id, group);
        }

        private void enable_atspi_if_needed() {
            enable_atspi_async.begin();
        }

        private async void enable_atspi_async() {
            try {
                var bus = yield GLib.Bus.get(BusType.SESSION);
                yield bus.call(
                    "org.a11y.Bus", "/org/a11y/bus",
                    "org.freedesktop.DBus.Properties", "Set",
                    new Variant("(ssv)", "org.a11y.Status", "IsEnabled", new Variant("b", true)),
                    null, DBusCallFlags.NONE, 1000, null);
            } catch {
                // AT-SPI daemon not running, ignore
            }
        }

        private int _atspi_usable = -1;

        private bool atspi_bus_usable() {
            if (_atspi_usable >= 0) return _atspi_usable == 1;
            _atspi_usable = 0;
            try {
                var bus = GLib.Bus.get_sync(BusType.SESSION);
                var reply = bus.call_sync(
                    "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
                    null, new VariantType("(s)"), DBusCallFlags.NONE, 1000, null);
                string addr;
                reply.get("(s)", out addr);
                if (addr == null || addr.length == 0) return false;
                var conn = new DBusConnection.for_address_sync(addr,
                    DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                    null, null);
                conn.close_sync(null);
                _atspi_usable = 1;
            } catch (Error e) {
                warning("AT-SPI bus not usable, disabling menu scan: %s", e.message);
                _atspi_usable = 0;
            }
            return _atspi_usable == 1;
        }

        private Gee.HashSet<string> atspi_no_menu = new Gee.HashSet<string>();

        private static bool global_menu_denylisted(string app_id) {
            string lid = app_id.down();
            return lid.contains("firefox") || lid.contains("mozilla");
        }

        private void try_atspi(int gen, string safe_id, SimpleActionGroup group) {
            if (menu_generation != gen) return;
            if (atspi_no_menu.contains(safe_id)) return;
            if (global_menu_denylisted(safe_id)) { atspi_no_menu.add(safe_id); return; }
            if (!atspi_bus_usable()) return;
            string captured_id = safe_id.dup();
            AtSpiMenuProvider.build_menu_async(captured_id, group, (menu) => {
                if (menu_generation != gen) return;
                bool real = menu != null && model_has_submenu(menu);
                if (real) {
                    emit_menu(gen, menu, group);
                } else {
                    atspi_no_menu.add(captured_id);
                }
            });
        }

        // True if any top-level entry of the model opens a submenu. A menubar
        // that is all leaves is the lazy/empty case, not a real menu.
        private bool model_has_submenu(MenuModel model) {
            int n = model.get_n_items();
            for (int i = 0; i < n; i++) {
                if (model.get_item_link(i, Menu.LINK_SUBMENU) != null) return true;
            }
            return false;
        }

        private static string get_os_pretty_name() {
            try {
                string content;
                FileUtils.get_contents("/etc/os-release", out content);
                string? os_name = null;
                string? codename = null;
                foreach (string line in content.split("\n")) {
                    string strip = line.strip();
                    if (strip.has_prefix("NAME=")) {
                        os_name = strip.substring("NAME=".length).strip();
                        if (os_name.has_prefix("\"") && os_name.has_suffix("\""))
                            os_name = os_name[1:os_name.length - 1];
                    } else if (strip.has_prefix("VERSION_CODENAME=")) {
                        codename = strip.substring("VERSION_CODENAME=".length).strip();
                        if (codename.has_prefix("\"") && codename.has_suffix("\""))
                            codename = codename[1:codename.length - 1];
                        // Capitalise first letter
                        if (codename.length > 0)
                            codename = codename[0:1].up() + codename[1:codename.length];
                    }
                }
                if (os_name != null && codename != null && codename.length > 0)
                    return "%s %s".printf(os_name, codename);
                if (os_name != null)
                    return os_name;
            } catch {}
            return "Linux";
        }

        private void build_desktop_os_menu(GLib.Menu final_menu, SimpleActionGroup group) {
            string os_name = get_os_pretty_name();
            var os_menu = new GLib.Menu();

            // Section 1: About + System Preferences
            var about_sec = new GLib.Menu();
            about_sec.append("About This Device", "dbusmenu.desktop-about");
            about_sec.append("System Preferences…", "dbusmenu.desktop-settings");
            os_menu.append_section(null, about_sec);

            // Section 2: Sleep + Lock Screen
            var session_sec = new GLib.Menu();
            session_sec.append("Sleep", "dbusmenu.desktop-sleep");
            session_sec.append("Lock Screen", "dbusmenu.desktop-lock");
            os_menu.append_section(null, session_sec);

            // Section 3: Log Out / Restart / Shut Down
            var power_sec = new GLib.Menu();
            power_sec.append("Log Out…", "dbusmenu.desktop-logout");
            power_sec.append("Restart…", "dbusmenu.desktop-restart");
            power_sec.append("Shut Down…", "dbusmenu.desktop-shutdown");
            os_menu.append_section(null, power_sec);

            final_menu.append_submenu(os_name, os_menu);

            // Actions
            var about_act = new SimpleAction("desktop-about", null);
            about_act.activate.connect(() => desktop_action_requested("about"));
            group.add_action(about_act);

            var settings_act = new SimpleAction("desktop-settings", null);
            settings_act.activate.connect(() => desktop_action_requested("settings"));
            group.add_action(settings_act);

            var sleep_act = new SimpleAction("desktop-sleep", null);
            sleep_act.activate.connect(() => {
                try {
                    var bus = Bus.get_sync(BusType.SYSTEM);
                    bus.call_sync("org.freedesktop.login1", "/org/freedesktop/login1",
                        "org.freedesktop.login1.Manager", "Suspend",
                        new Variant("(b)", true), null, DBusCallFlags.NONE, -1);
                } catch (Error e) { warning("Sleep failed: %s", e.message); }
            });
            group.add_action(sleep_act);

            var lock_act = new SimpleAction("desktop-lock", null);
            lock_act.activate.connect(() => SessionManager.get_default().lock_screen());
            group.add_action(lock_act);

            var logout_act = new SimpleAction("desktop-logout", null);
            logout_act.activate.connect(() => SessionManager.get_default().logout());
            group.add_action(logout_act);

            var restart_act = new SimpleAction("desktop-restart", null);
            restart_act.activate.connect(() => SessionManager.get_default().reboot());
            group.add_action(restart_act);

            var shutdown_act = new SimpleAction("desktop-shutdown", null);
            shutdown_act.activate.connect(() => SessionManager.get_default().shutdown());
            group.add_action(shutdown_act);
        }

        private void emit_menu(int gen, MenuModel? app_model, SimpleActionGroup group) {
            if (menu_generation != gen) return;
            var final_menu = new GLib.Menu();
            if (app_model != null) {
                int n = app_model.get_n_items();
                for (int i = 0; i < n; i++) {
                    string? lbl = null;
                    app_model.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out lbl);
                    var mi = new MenuItem(lbl, null);
                    MenuModel? sub = app_model.get_item_link(i, Menu.LINK_SUBMENU);
                    if (sub != null) {
                        mi.set_submenu(sub);
                    } else {
                        MenuModel? sec = app_model.get_item_link(i, Menu.LINK_SECTION);
                        if (sec != null) mi.set_section(sec);
                    }
                    final_menu.append_item(mi);
                }
            } else if (current_menu_app_id == "") {
                // Desktop focused: the global OS menu
                build_desktop_os_menu(final_menu, group);
                current_menu_model = final_menu;
                menu_model_changed(final_menu);
                return;
            } else {
                // Fallback: enrich File menu with desktop entry actions
                var file_menu = new GLib.Menu();
                if (current_menu_app_id.length > 0) {
                    var ai = get_app_info(current_menu_app_id);
                    var dai = ai as DesktopAppInfo;
                    if (dai != null) {
                        string[] entry_actions = dai.list_actions();
                        int entry_counter = 0;
                        foreach (string action_id in entry_actions) {
                            string captured_aid = action_id.dup();
                            entry_counter++;
                            string gact_id = "entry-%d".printf(entry_counter);
                            if (!group.has_action(gact_id)) {
                                var act = new SimpleAction(gact_id, null);
                                act.activate.connect(() => {
                                    dai.launch_action(captured_aid, Gdk.Display.get_default().get_app_launch_context());
                                });
                                group.add_action(act);
                            }
                            file_menu.append(dai.get_action_name(captured_aid), "dbusmenu." + gact_id);
                        }
                    }
                }
                file_menu.append("Quit", "dbusmenu.quit");
                final_menu.append_submenu("File", file_menu);
            }
            var win_menu = new GLib.Menu();
            win_menu.append("Minimize", "dbusmenu.minimize");
            win_menu.append("Maximize", "dbusmenu.maximize");
            win_menu.append("Snap Left", "dbusmenu.snap-left");
            win_menu.append("Snap Right", "dbusmenu.snap-right");
            final_menu.append_submenu("Window", win_menu);
            current_menu_model = final_menu;
            menu_model_changed(final_menu);
        }

        private Dbusmenu.Menuitem? find_dbusmenu_item(Dbusmenu.Menuitem? item, int id) {
            if (item == null) return null;
            if (item.get_id() == id) return item;

            foreach (var child in item.get_children()) {
                var found = find_dbusmenu_item(child, id);
                if (found != null) return found;
            }
            return null;
        }

        private static bool is_digit_char(char c) {
            return c >= '0' && c <= '9';
        }

        private static string? extract_digits_after(string text, string marker) {
            int pos = text.index_of(marker);
            if (pos < 0) return null;

            int start = pos + marker.length;
            if (start >= text.length || !is_digit_char(text[start])) return null;

            int end = start;
            while (end < text.length && is_digit_char(text[end])) end++;

            return text[start:end];
        }

        private static string? extract_steam_appid_from_text(string? text) {
            if (text == null || text == "") return null;

            string lower = text.down();
            string? appid = extract_digits_after(lower, "steam://rungameid/");
            if (appid != null) return appid;

            appid = extract_digits_after(lower, "steam://run/");
            if (appid != null) return appid;

            return extract_digits_after(lower, "steam_app_");
        }

        private static string? steam_runtime_id_from_app_id(string app_id) {
            if (app_id == null || app_id == "") return null;

            string lower = app_id.down();
            if (lower.has_suffix(".desktop")) {
                lower = lower[0:lower.length - 8];
            }

            if (!lower.has_prefix("steam_app_")) return null;
            int start = "steam_app_".length;
            if (start >= lower.length) return null;

            for (int i = start; i < lower.length; i++) {
                if (!is_digit_char(lower[i])) return null;
            }

            return lower;
        }

        private void index_steam_app(AppInfo app) {
            var dapp = app as GLib.DesktopAppInfo;
            if (dapp == null) return;

            string? appid = extract_steam_appid_from_text(dapp.get_startup_wm_class());
            if (appid == null) appid = extract_steam_appid_from_text(dapp.get_string("Exec"));
            if (appid == null) appid = extract_steam_appid_from_text(app.get_id());
            if (appid == null) appid = extract_steam_appid_from_text(dapp.get_filename());
            if (appid == null) return;

            string runtime_id = "steam_app_" + appid;
            if (!steam_app_map.contains(runtime_id)) {
                steam_app_map.insert(runtime_id, app);
            }
        }

        private AppInfo? resolve_steam_app_for_id(string app_id) {
            string? runtime_id = steam_runtime_id_from_app_id(app_id);
            if (runtime_id == null) return null;
            if (!steam_app_map.contains(runtime_id)) return null;
            return steam_app_map.get(runtime_id);
        }

        // Resolve an app_id to its installed AppInfo, trying progressively looser
        // matches. Shared by initial window resolution and the post-scan re-resolve.
        public AppInfo? resolve_app_for_id(string app_id) {
            string icon_name = app_id.down();
            AppInfo? app_info = get_app_info(app_id);
            if (app_info == null) {
                app_info = get_app_info(app_id + ".desktop");
            }
            if (app_info == null) {
                foreach (var app in installed_apps_list) {
                    var dapp = app as GLib.DesktopAppInfo;
                    if (dapp == null) continue;
                    string? wm = dapp.get_startup_wm_class();
                    if (wm != null && wm.down() == icon_name) {
                        app_info = app;
                        break;
                    }
                }
            }
            if (app_info == null) {
                app_info = resolve_steam_app_for_id(app_id);
            }
            if (app_info == null && steam_runtime_id_from_app_id(app_id) != null) {
                return null;
            }
            if (app_info == null) {
                foreach (var app in installed_apps_list) {
                    string? raw_id = app.get_id();
                    if (raw_id == null) continue;
                    string id = raw_id.down();
                    if (id.contains(icon_name) || icon_name.contains(id)) {
                        app_info = app;
                        break;
                    }
                }
            }
            if (app_info == null) {
                AppInfo? best = null;
                int best_len = 0;
                foreach (var app in installed_apps_list) {
                    string? rid = app.get_id();
                    if (rid == null) continue;
                    string stem = rid.down();
                    if (stem.has_suffix(".desktop")) stem = stem[0:stem.length - 8];
                    int dot = stem.last_index_of(".");
                    if (dot >= 0) stem = stem[dot + 1:stem.length];
                    if (stem.length >= 4 && icon_name.has_prefix(stem) && stem.length > best_len) {
                        best = app;
                        best_len = stem.length;
                    }
                }
                app_info = best;
            }
            return app_info;
        }

        private static string icon_name_for(AppInfo app_info, string fallback) {
            var icon = app_info.get_icon();
            if (icon != null && icon is ThemedIcon) {
                var names = ((ThemedIcon)icon).get_names();
                if (names != null && names.length > 0) return names[0].dup();
            }
            return fallback;
        }

        // Windows open before scan_apps populated the app list resolve with a null
        // gicon. The dock re-resolves on refresh, but the overview/alt-tab read
        // win.gicon directly, so re-resolve them once the app list is ready.
        private void reresolve_window_icons() {
            bool running_ids_changed = false;
            foreach (var win in windows) {
                if (win.gicon != null && steam_runtime_id_from_app_id(win.app_id) == null) continue;
                var app_info = resolve_app_for_id(win.app_id);
                if (app_info == null) continue;
                string old_app_id = win.app_id;
                win.gicon = app_info.get_icon();
                win.icon_name = icon_name_for(app_info, win.icon_name);
                string? canonical_id = app_info.get_id();
                if (canonical_id != null && canonical_id != "" && canonical_id != win.app_id) {
                    win.app_id = canonical_id.dup();
                    running_ids_changed = true;

                    unowned List<string> old_running = running_apps_list.find_custom(old_app_id, strcmp);
                    if (old_running != null) {
                        running_apps_list.remove(old_running.data);
                    }
                    if (running_apps_list.find_custom(win.app_id, strcmp) == null) {
                        running_apps_list.append(win.app_id.dup());
                    }
                }
            }
            if (running_ids_changed) {
                schedule_running_apps_changed();
            }
        }

        private void add_running_app(void* handle, string raw_app_id) {
            foreach (var w in windows) {
                if (w.handle == handle) return;
            }
            // Dup immediately - raw_app_id is a const char* from the Wayland protocol
            // buffer which may be freed/reused as soon as this callback returns.
            string app_id = raw_app_id.dup();
            if (app_id == null || app_id.strip() == "") {
                app_id = "unknown-wayland-surface";
            }
            string original_id = app_id;
            string icon_name = app_id.down();
            AppInfo? app_info = resolve_app_for_id(app_id);

            if (app_info != null) {
                string? canonical_id = app_info.get_id();
                if (canonical_id != null) {
                    app_id = canonical_id.dup();
                }
                icon_name = icon_name_for(app_info, icon_name);
            } else {
                warning("AppSystem: FAILED to resolve AppInfo for '%s'. Dock icon may be missing or generic.", original_id);
            }

            var win = new Window(handle, app_id);
            win.icon_name = icon_name;
            if (app_info != null) win.gicon = app_info.get_icon();
            windows.append(win);
            app_opened(handle, app_id);
            Workspace? target_ws = null;
            foreach (var ws in workspaces) {
                if (ws.active) { target_ws = ws; break; }
            }
            if (workspaces.length() == 0) {
                target_ws = new Workspace(null, "1");
                target_ws.active = true;
                workspaces.append(target_ws);
            } else if (target_ws == null) {
                target_ws = workspaces.nth_data(0);
            }
            if (target_ws != null) {
                target_ws.windows.append(win);
                schedule_workspaces_changed();
            }
            if (running_apps_list.find_custom(app_id, strcmp) == null) {
                running_apps_list.append(app_id.dup());
                schedule_running_apps_changed();
            }
        }

        private void remove_running_app(void* handle) {
            Window? found = null;
            foreach (var win in windows) {
                if (win.handle == handle) { found = win; break; }
            }
            if (found != null) {
                string app_id = found.app_id;
                PreviewCache.get_default().invalidate(handle);
                windows.remove(found);
                if (mru_windows.find(found) != null) mru_windows.remove(found);
                app_closed(handle);
                // Closing the focused window (e.g. a fullscreen app or a
                // transient fullscreen grab like flameshot) does not generate a
                // focus event on its own, so the panel and dock would stay
                // hidden-for-fullscreen forever. Drop the stale focus handle and
                // re-evaluate so the bars reappear immediately.
                if (handle == current_focused_window_handle) {
                    current_focused_window_handle = null;
                    window_focused(null);
                    any_fullscreen_changed();
                    // Closing the focused window does not emit a focus event, so
                    // clear the global menu and the panel app-name label here too;
                    // a new focus event will repopulate them if another window
                    // takes focus (#150).
                    current_focused_app_id = "";
                    app_focused(null);
                    update_menu_model("");
                }
                foreach (var ws in workspaces) {
                    if (ws.windows.find(found) != null) {
                        ws.windows.remove(found);
                        schedule_workspaces_changed();
                        break;
                    }
                }
                bool still_running = false;
                foreach (var w in windows) {
                    if (w.app_id == app_id) { still_running = true; break; }
                }
                if (!still_running) {
                    unowned List<string> item = running_apps_list.find_custom(app_id, strcmp);
                    if (item != null) {
                        running_apps_list.remove(item.data);
                        schedule_running_apps_changed();
                    }
                }
            }
        }

        public bool is_app_running(string desktop_id) {
            string search = desktop_id.down();
            foreach (var running_id in running_apps_list) {
                string r = running_id.down();
                if (r == search) return true;
                if (r + ".desktop" == search || r == search + ".desktop") return true;

                // Hyphen replacement
                if (r.contains("-")) {
                    string dot_r = r.replace("-", ".");
                    if (search.has_suffix("." + dot_r + ".desktop") || search == dot_r + ".desktop") return true;
                }

                // Check for domain match reverse
                if (r.has_suffix("." + search) || search.has_suffix("." + r)) return true;
            }
            return false;
        }

        public bool is_pinned(string desktop_id) {
            // Fast path exact match
            foreach (var pinned_id in pinned_apps) {
                if (pinned_id == desktop_id) return true;
            }

            // Resolve running ID to canonical .desktop ID
            var info = get_app_info(desktop_id);
            if (info != null) {
                string? canonical = info.get_id();
                if (canonical != null) {
                    foreach (var pinned_id in pinned_apps) {
                        if (pinned_id == canonical) return true;
                        // Also try resolving the pinned ID (in case config has short names)
                        var pinned_info = get_app_info(pinned_id);
                        if (pinned_info != null && pinned_info.get_id() == canonical) return true;
                    }
                }
            }
            return false;
        }

        public void pin_app(string desktop_id) {
            if (is_pinned(desktop_id)) return;
            string[] new_pinned = new string[pinned_apps.length + 1];
            for (int i = 0; i < pinned_apps.length; i++) new_pinned[i] = pinned_apps[i];
            new_pinned[pinned_apps.length] = desktop_id;
            settings.set_strv("pinned-apps", new_pinned);
            GLib.Settings.sync();
        }

        public void unpin_app(string desktop_id) {
            if (!is_pinned(desktop_id)) return;
            string[] new_pinned = new string[pinned_apps.length - 1];
            int j = 0;
            for (int i = 0; i < pinned_apps.length; i++) {
                if (pinned_apps[i] != desktop_id) new_pinned[j++] = pinned_apps[i];
            }
            settings.set_strv("pinned-apps", new_pinned);
            GLib.Settings.sync();
        }

        public void insert_pinned_app(string desktop_id, int index) {
            if (is_pinned(desktop_id)) return;
            if (index < 0) index = 0;
            if (index > pinned_apps.length) index = pinned_apps.length;
            string[] new_pinned = new string[pinned_apps.length + 1];
            for (int i = 0; i < index; i++) new_pinned[i] = pinned_apps[i];
            new_pinned[index] = desktop_id;
            for (int i = index; i < pinned_apps.length; i++) new_pinned[i + 1] = pinned_apps[i];
            settings.set_strv("pinned-apps", new_pinned);
            GLib.Settings.sync();
        }

        public void move_pinned_app(string desktop_id, int new_pos) {
            if (!is_pinned(desktop_id)) return;
            var list = new List<string>();
            foreach (var app in pinned_apps) list.append(app);
            unowned List<string>? item = list.find_custom(desktop_id, strcmp);
            if (item == null) return;
            list.remove_link(item);
            int len = (int)list.length();
            if (new_pos < 0) new_pos = 0;
            if (new_pos > len) new_pos = len;
            list.insert(desktop_id, new_pos);
            string[] new_pinned = new string[list.length()];
            int i = 0;
            foreach (var app in list) new_pinned[i++] = app;
            settings.set_strv("pinned-apps", new_pinned);
            GLib.Settings.sync();
        }

        private void update_workspaces_config() {
            GLib.Timeout.add(100, () => {
                if (dynamic_workspaces) {
                    if (workspaces.length() == 0) create_workspace("1");
                } else {
                    int current = (int)workspaces.length();
                    if (current < workspace_count) {
                        for (int i = current; i < workspace_count; i++) create_workspace("%d".printf(i + 1));
                    }
                }
                return false;
            });
        }

        public void create_workspace(string name) {
             Singularity.wayland_create_workspace(name);
        }

        private void load_settings() {
            pinned_apps = settings.get_strv("pinned-apps");
            dock_position = settings.get_string("dock-position");
            dynamic_workspaces = settings.get_boolean("dynamic-workspaces");
            workspace_count = settings.get_int("workspace-count");
        }

        public void scan_apps() {
            // Update owner FIRST so new objects are alive before old ones are released
            _app_info_owner = AppInfo.get_all();
            installed_apps_map.remove_all();
            steam_app_map.remove_all();
            installed_apps_list = new List<AppInfo>();
            foreach (var app in _app_info_owner) {
                string id = app.get_id();
                if (id != null) {
                    installed_apps_map.insert(id, app);
                    installed_apps_list.append(app);
                    index_steam_app(app);
                }
            }
            scan_desktop_app_dirs();
            reresolve_window_icons();
            apps_changed();
        }

        private void scan_desktop_app_dirs() {
            string[] data_dirs = {};
            string? data_home = Environment.get_variable("XDG_DATA_HOME");
            data_dirs += data_home != null && data_home != ""
                ? data_home
                : Path.build_filename(Environment.get_home_dir(), ".local", "share");
            foreach (unowned string dir in Environment.get_system_data_dirs()) {
                data_dirs += dir;
            }

            foreach (string data_dir in data_dirs) {
                string applications_dir = Path.build_filename(data_dir, "applications");
                var dir_file = File.new_for_path(applications_dir);
                try {
                    var enumerator = dir_file.enumerate_children(
                        FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                        FileQueryInfoFlags.NONE);
                    while (true) {
                        FileInfo? info = enumerator.next_file();
                        if (info == null) break;
                        if (info.get_file_type() != FileType.REGULAR) continue;
                        string name = info.get_name();
                        if (!name.has_suffix(".desktop")) continue;
                        if (installed_apps_map.contains(name)) continue;

                        string path = Path.build_filename(applications_dir, name);
                        var desktop_app = new DesktopAppInfo.from_filename(path);
                        if (desktop_app == null) continue;
                        string? id = desktop_app.get_id();
                        if (id == null || installed_apps_map.contains(id)) continue;

                        AppInfo app = desktop_app;
                        _app_info_owner.append(app);
                        installed_apps_map.insert(id, app);
                        installed_apps_list.append(app);
                        index_steam_app(app);
                    }
                } catch (Error e) {
                    // Missing or unreadable application dirs are normal for optional prefixes.
                }
            }
        }

        public unowned List<AppInfo> get_all_apps() {
            return installed_apps_list;
        }

        // Resolve a sibling executable next to our own (/proc/self/exe),
        // falling back to a bare name for PATH lookup. Keeps the install prefix
        // (for example /opt) working without hardcoding it.
        public static string resolve_companion_bin(string name) {
            try {
                string exe = GLib.FileUtils.read_link("/proc/self/exe");
                string cand = GLib.Path.build_filename(GLib.Path.get_dirname(exe), name);
                if (GLib.FileUtils.test(cand, GLib.FileTest.IS_EXECUTABLE)) return cand;
            } catch (Error e) { }
            return name;
        }

        // App Folders

        public class AppFolder : Object {
            public string id;
            public string name;
            public string[] app_ids;

            public AppFolder(string id, string name, string[] app_ids) {
                this.id = id;
                this.name = name;
                this.app_ids = app_ids;
            }
        }

        public signal void folders_changed();

        private HashTable<string, AppFolder> _folders = new HashTable<string, AppFolder>(str_hash, str_equal);

        private void load_folders() {
            _folders.remove_all();
            string json = settings.get_string("app-folders");
            try {
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var obj = root.get_object();
                obj.foreach_member((o, folder_id, node) => {
                    if (node.get_node_type() != Json.NodeType.OBJECT) return;
                    var fo = node.get_object();
                    string name = fo.has_member("name") ? fo.get_string_member("name") : folder_id;
                    string[] ids = {};
                    if (fo.has_member("apps")) {
                        var arr = fo.get_array_member("apps");
                        arr.foreach_element((a, i, el) => {
                            ids += el.get_string();
                        });
                    }
                    _folders.insert(folder_id, new AppFolder(folder_id, name, ids));
                });
            } catch (Error e) {
                warning("Failed to load app folders: %s", e.message);
            }
            // Migrate: remove any loose app IDs from grid order that are now in a folder
            sanitize_grid_order();
        }

        // Remove from grid order any app ID that belongs to a folder (migration / consistency fix)

        private void sanitize_grid_order() {
            var order = get_grid_order();
            var folder_apps = new HashTable<string, bool>(str_hash, str_equal);
            _folders.foreach((fid, folder) => {
                foreach (var app_id in folder.app_ids) folder_apps.insert(app_id, true);
            });
            if (folder_apps.size() == 0) return;
            string[] new_order = {};
            bool changed = false;
            foreach (var item in order) {
                if (!item.has_prefix("folder:") && folder_apps.contains(item)) {
                    changed = true;
                } else {
                    new_order += item;
                }
            }
            if (changed) settings.set_strv("app-grid-order", new_order);
        }

        private void save_folders() {
            var builder = new Json.Builder();
            builder.begin_object();
            _folders.foreach((folder_id, folder) => {
                builder.set_member_name(folder_id);
                builder.begin_object();
                builder.set_member_name("name");
                builder.add_string_value(folder.name);
                builder.set_member_name("apps");
                builder.begin_array();
                foreach (var app_id in folder.app_ids) {
                    builder.add_string_value(app_id);
                }
                builder.end_array();
                builder.end_object();
            });
            builder.end_object();
            var gen = new Json.Generator();
            gen.set_root(builder.get_root());
            string json = gen.to_data(null);
            settings.set_string("app-folders", json);
        }

        public List<AppFolder> get_folders() {
            var list = new List<AppFolder>();
            _folders.foreach((id, f) => list.append(f));
            return (owned) list;
        }

        public unowned AppFolder? get_folder(string folder_id) {
            return _folders.lookup(folder_id);
        }

        public string create_folder(string name, string app_id1, string app_id2) {
            string folder_id = "folder-%lld".printf(GLib.get_real_time());
            _folders.insert(folder_id, new AppFolder(folder_id, name, { app_id1, app_id2 }));
            // Insert folder into grid order replacing app_id1; remove app_id2
            var order = get_grid_order();
            int pos = -1;
            for (int i = 0; i < order.length; i++) {
                if (order[i] == app_id1) { pos = i; break; }
            }
            string[] new_order = {};
            for (int i = 0; i < order.length; i++) {
                if (order[i] == app_id2) continue;
                if (order[i] == app_id1) {
                    new_order += "folder:" + folder_id;
                } else {
                    new_order += order[i];
                }
            }
            if (pos < 0) new_order += "folder:" + folder_id;
            settings.set_strv("app-grid-order", new_order);
            save_folders();
            folders_changed();
            return folder_id;
        }

        public void rename_folder(string folder_id, string name) {
            var folder = _folders.lookup(folder_id);
            if (folder == null) return;
            folder.name = name;
            save_folders();
            folders_changed();
        }

        public void delete_folder(string folder_id) {
            var folder = _folders.lookup(folder_id);
            if (folder == null) return;
            // Move all apps back into grid order at position of folder
            var order = get_grid_order();
            string[] new_order = {};
            for (int i = 0; i < order.length; i++) {
                if (order[i] == "folder:" + folder_id) {
                    foreach (var app_id in folder.app_ids) new_order += app_id;
                } else {
                    new_order += order[i];
                }
            }
            settings.set_strv("app-grid-order", new_order);
            _folders.remove(folder_id);
            save_folders();
            folders_changed();
        }

        public void add_app_to_folder(string folder_id, string app_id) {
            var folder = _folders.lookup(folder_id);
            if (folder == null) return;
            foreach (var id in folder.app_ids) if (id == app_id) return;
            var new_ids = folder.app_ids;
            new_ids += app_id;
            folder.app_ids = new_ids;
            // Remove app from grid order
            var order = get_grid_order();
            string[] new_order = {};
            foreach (var item in order) if (item != app_id) new_order += item;
            settings.set_strv("app-grid-order", new_order);
            save_folders();
            folders_changed();
        }

        public void remove_app_from_folder(string folder_id, string app_id, int insert_pos = -1) {
            var folder = _folders.lookup(folder_id);
            if (folder == null) return;
            string[] new_ids = {};
            foreach (var id in folder.app_ids) if (id != app_id) new_ids += id;
            folder.app_ids = new_ids;
            // Put app back in grid order after the folder
            var order = get_grid_order();
            string folder_key = "folder:" + folder_id;
            string[] new_order = {};
            bool inserted = false;
            for (int i = 0; i < order.length; i++) {
                new_order += order[i];
                if (!inserted && order[i] == folder_key) {
                    new_order += app_id;
                    inserted = true;
                }
            }
            if (!inserted) new_order += app_id;
            settings.set_strv("app-grid-order", new_order);
            if (folder.app_ids.length == 0) {
                _folders.remove(folder_id);
            }
            save_folders();
            folders_changed();
        }

        public bool app_in_folder(string app_id, out string folder_id) {
            string tmp_id = "";
            bool found = false;
            _folders.foreach((fid, folder) => {
                if (found) return;
                foreach (var id in folder.app_ids) {
                    if (id == app_id) { tmp_id = fid; found = true; break; }
                }
            });
            folder_id = tmp_id;
            return found;
        }

        // Grid Order

        public string[] get_grid_order() {
            return settings.get_strv("app-grid-order");
        }

        public void set_grid_order(string[] order) {
            if (_setting_grid_order) return;
            _setting_grid_order = true;
            settings.set_strv("app-grid-order", order);
            apps_changed();
            _setting_grid_order = false;
        }

        public void set_grid_order_quiet(string[] order) {
            settings.set_strv("app-grid-order", order);
        }

        // Returns ordered list of (app_id or "folder:folder_id"), filling in
        // any apps not yet in the saved order at the end.

        public string[] get_ordered_grid_items() {
            string[] saved = get_grid_order();
            var seen = new HashTable<string, bool>(str_hash, str_equal);
            string[] result = {};

            // First: mark ALL apps in ANY folder as seen so they never appear loose
            _folders.foreach((fid, folder) => {
                foreach (var app_id in folder.app_ids) seen.insert(app_id, true);
            });

            // Quick lookup of known widget keys - saved `widget:<iid>`
            // entries are otherwise indistinguishable from missing apps and
            // would be silently dropped, sending widgets to the end of the
            // grid on every refresh.
            var widget_keys = new HashTable<string, bool>(str_hash, str_equal);
            foreach (var wi in get_overview_widgets())
                widget_keys.insert("widget:" + wi.instance_id, true);

            // Process saved order
            foreach (var item in saved) {
                if (item.has_prefix("folder:")) {
                    string fid = item.substring(7);
                    if (_folders.contains(fid)) {
                        result += item;
                        seen.insert(item, true);
                    }
                    // else folder was deleted - skip
                } else if (item.has_prefix("widget:")) {
                    if (widget_keys.contains(item) && !seen.contains(item)) {
                        result += item;
                        seen.insert(item, true);
                    }
                    // else widget was removed - skip
                } else {
                    if (get_app_info(item) != null && !seen.contains(item)) {
                        result += item;
                        seen.insert(item, true);
                    }
                }
            }

            // Add folders that exist but aren't in saved order
            _folders.foreach((fid, folder) => {
                string key = "folder:" + fid;
                if (!seen.contains(key)) {
                    result += key;
                    seen.insert(key, true);
                }
            });

            // Append any apps not yet in order (and not in any folder)
            foreach (var app in installed_apps_list) {
                if (!app.should_show()) continue;
                string? id = app.get_id();
                if (id != null && !seen.contains(id)) {
                    result += id;
                    seen.insert(id, true);
                }
            }
            // Append any widget instances that aren't already in saved order.
            foreach (var w in get_overview_widgets()) {
                string key = "widget:" + w.instance_id;
                if (!seen.contains(key)) {
                    result += key;
                    seen.insert(key, true);
                }
            }
            return result;
        }

        // Overview widgets
        public struct OverviewWidgetInstance {
            string instance_id;
            string provider_id;
            int    w;
            int    h;
            string config_json;
        }

        public OverviewWidgetInstance[] get_overview_widgets() {
            var v = settings.get_value("overview-widgets");
            int n = (int) v.n_children();
            var result = new OverviewWidgetInstance[n];
            for (int i = 0; i < n; i++) {
                var t = v.get_child_value(i);
                result[i] = OverviewWidgetInstance() {
                    instance_id = t.get_child_value(0).get_string(),
                    provider_id = t.get_child_value(1).get_string(),
                    w           = t.get_child_value(2).get_int32(),
                    h           = t.get_child_value(3).get_int32(),
                    config_json = t.get_child_value(4).get_string()
                };
            }
            return result;
        }

        public OverviewWidgetInstance? get_overview_widget(string instance_id) {
            foreach (var w in get_overview_widgets())
                if (w.instance_id == instance_id) return w;
            return null;
        }

        public void add_overview_widget(string provider_id, int w, int h,
                                         string config_json = "") {
            string iid = "%s-%lld".printf(provider_id,
                                          (int64) GLib.get_real_time());
            var builder = new VariantBuilder(new VariantType("a(ssiis)"));
            foreach (var existing in get_overview_widgets()) {
                builder.add("(ssiis)", existing.instance_id, existing.provider_id,
                            existing.w, existing.h, existing.config_json);
            }
            builder.add("(ssiis)", iid, provider_id, w, h, config_json);
            settings.set_value("overview-widgets", builder.end());

            // Add to grid order too.
            string[] order = get_grid_order();
            order += "widget:" + iid;
            set_grid_order(order);
        }

        public void remove_overview_widget(string instance_id) {
            var builder = new VariantBuilder(new VariantType("a(ssiis)"));
            foreach (var existing in get_overview_widgets()) {
                if (existing.instance_id == instance_id) continue;
                builder.add("(ssiis)", existing.instance_id, existing.provider_id,
                            existing.w, existing.h, existing.config_json);
            }
            settings.set_value("overview-widgets", builder.end());
            string[] new_order = {};
            string key = "widget:" + instance_id;
            foreach (var k in get_grid_order())
                if (k != key) new_order += k;
            set_grid_order(new_order);
        }

        public void resize_overview_widget(string instance_id, int w, int h) {
            var builder = new VariantBuilder(new VariantType("a(ssiis)"));
            foreach (var existing in get_overview_widgets()) {
                if (existing.instance_id == instance_id) {
                    builder.add("(ssiis)", existing.instance_id, existing.provider_id,
                                w, h, existing.config_json);
                } else {
                    builder.add("(ssiis)", existing.instance_id, existing.provider_id,
                                existing.w, existing.h, existing.config_json);
                }
            }
            settings.set_value("overview-widgets", builder.end());
            apps_changed();
        }

        public void update_overview_widget_config(string instance_id, string config_json) {
            var builder = new VariantBuilder(new VariantType("a(ssiis)"));
            foreach (var existing in get_overview_widgets()) {
                if (existing.instance_id == instance_id) {
                    builder.add("(ssiis)", existing.instance_id, existing.provider_id,
                                existing.w, existing.h, config_json);
                } else {
                    builder.add("(ssiis)", existing.instance_id, existing.provider_id,
                                existing.w, existing.h, existing.config_json);
                }
            }
            settings.set_value("overview-widgets", builder.end());
        }

        public AppInfo? get_app_info(string desktop_id) {
            if (desktop_id == null || desktop_id.strip() == "") return null;

            if (installed_apps_map.contains(desktop_id)) {
                return installed_apps_map.get(desktop_id);
            }

            if (!desktop_id.has_suffix(".desktop")) {
                string with_suffix = desktop_id + ".desktop";
                if (installed_apps_map.contains(with_suffix)) {
                    return installed_apps_map.get(with_suffix);
                }
            }

            string search_id = desktop_id.down();
            string search_desktop = search_id + ".desktop";

            foreach (var app in installed_apps_list) {
                string? raw_id = app.get_id();
                if (raw_id == null) continue;
                string id = raw_id.down();

                if (id == search_id || id == search_desktop) {
                    return app;
                }

                if (id.has_suffix("." + search_desktop)) {
                    return app;
                }

                if (search_id.contains("-")) {
                    string dot_search = search_id.replace("-", ".");
                    if (id == dot_search + ".desktop" || id.has_suffix("." + dot_search + ".desktop")) {
                        return app;
                    }
                }

                if (search_id.length > 2 && id.contains(search_id)) {
                    bool valid_partial = id.has_prefix(search_id + ".") ||
                                         id.has_suffix("." + search_desktop) ||
                                         id.contains("." + search_id + ".");

                    if (valid_partial) {
                        return app;
                    }
                }
            }

            return null;
        }

        // Centralized app launch - injects MangoHud/GameMode env if enabled
        public static void launch_app(GLib.AppInfo app_info, GLib.List<GLib.File>? files = null) {
            var ctx = (GLib.AppLaunchContext) Gdk.Display.get_default().get_app_launch_context();
            var shell_settings = new GLib.Settings("dev.sinty.desktop");
            if (shell_settings.get_boolean("mangohud-auto")) {
                var dai = app_info as GLib.DesktopAppInfo;
                if (dai != null) {
                    string? cats = dai.get_categories();
                    if (cats != null && "Game" in cats) {
                        ctx.setenv("MANGOHUD", "1");
                    }
                }
            }
            try {
                app_info.launch(files, ctx);
            } catch (GLib.Error e) {
                warning("launch_app: %s", e.message);
            }
        }
    }
}
