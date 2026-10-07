namespace Singularity {

    /**
     * GtkActionsMenuProvider - builds a GLib.Menu for any GTK4/GLib application
     * by querying its exported org.gtk.Actions.DescribeAll() D-Bus interface.
     *
     * This is used for libadwaita apps (Nautilus, GNOME Calendar, etc.) that
     * do NOT export a traditional GtkMenuBar via org.gtk.Menus, but DO export
     * their actions.  We map known action names to human-readable labels and
     * group them into File / Edit / View / Go / Help submenus.
     *
     * Menu items use the "app." prefix and rely on the DBusActionGroup already
     * inserted into the panel's action muxer as "app".
     */
    public class GtkActionsMenuProvider : GLib.Object {

        public delegate void MenuReadyCallback (GLib.Menu? menu);

        // Static action->label mapping
        // Format: { action-name, human label, category, prefix }
        // prefix: "app" | "win"   - determines the action group used in the panel

        private struct ActionDef {
            public string name;
            public string label;
            public string cat;
            public string prefix;
        }

        // This has to be a regular array since Vala doesn't allow const structs with strings.
        private static ActionDef[] KNOWN;

        private static void ensure_map () {
            if (KNOWN != null) return;
            KNOWN = {
                // File - app-level
                { "new-window",             "New Window",             "file", "app" },
                { "clone-window",           "Move to New Window",     "file", "app" },
                { "new-document",           "New",                    "file", "app" },
                { "open",                   "Open…",                  "file", "app" },
                { "open-location",          "Open Location…",         "file", "app" },
                { "open-in-new-window",     "Open in New Window",     "file", "app" },
                { "open-with-files",        "Show in Files",          "file", "app" },
                { "save",                   "Save",                   "file", "app" },
                { "save-as",                "Save As…",               "file", "app" },
                { "export",                 "Export…",                "file", "app" },
                { "print",                  "Print…",                 "file", "app" },
                { "preferences",            "Preferences…",           "file", "app" },
                // File - win-level
                { "new-tab",                "New Tab",                "file", "win" },
                { "close-current-view",     "Close Tab",              "file", "win" },
                { "restore-tab",            "Reopen Closed Tab",      "file", "win" },
                { "tab-move-new-window",    "Move Tab to New Window", "file", "win" },
                { "close",                  "Close",                  "file", "win" },
                { "close-all",              "Close All",              "file", "win" },
                // Edit - app-level
                { "copy",                   "Copy",                   "edit", "app" },
                { "cut",                    "Cut",                    "edit", "app" },
                { "paste",                  "Paste",                  "edit", "app" },
                { "paste-into",             "Paste Into Folder",      "edit", "app" },
                { "select-all",             "Select All",             "edit", "app" },
                { "delete",                 "Delete",                 "edit", "app" },
                { "move-to-trash",          "Move to Trash",          "edit", "app" },
                { "trash",                  "Move to Trash",          "edit", "app" },
                { "rename",                 "Rename…",                "edit", "app" },
                { "find",                   "Find…",                  "edit", "app" },
                { "show-find-panel",        "Find…",                  "edit", "app" },
                { "find-replace",           "Find & Replace…",        "edit", "app" },
                { "replace",                "Replace…",               "edit", "app" },
                { "duplicate",              "Duplicate",              "edit", "app" },
                { "select-none",            "Select None",            "edit", "app" },
                // Edit - win-level
                { "undo",                   "Undo",                   "edit", "win" },
                { "redo",                   "Redo",                   "edit", "win" },
                // View - app-level
                { "list-view",              "List View",              "view", "app" },
                { "grid-view",              "Grid View",              "view", "app" },
                { "view-list",              "List View",              "view", "app" },
                { "view-grid",              "Grid View",              "view", "app" },
                { "current-view",           "View Mode",              "view", "app" },
                { "zoom-in",                "Zoom In",                "view", "app" },
                { "zoom-out",               "Zoom Out",               "view", "app" },
                { "zoom-reset",             "Actual Size",            "view", "app" },
                { "zoom-default",           "Actual Size",            "view", "app" },
                { "show-hidden",            "Show Hidden Files",      "view", "app" },
                { "sort-by-name",           "Sort by Name",           "view", "app" },
                { "sort-by-date",           "Sort by Date",           "view", "app" },
                { "sort-by-size",           "Sort by Size",           "view", "app" },
                { "show-line-numbers",      "Show Line Numbers",      "view", "app" },
                { "show-overview",          "Overview",               "view", "app" },
                { "show-toolbar",           "Show Toolbar",           "view", "app" },
                // View - win-level
                { "show-sidebar",           "Show Sidebar",           "view", "win" },
                { "toggle-sidebar",         "Show Sidebar",           "view", "win" },
                { "sidebar-on",             "Show Sidebar",           "view", "win" },
                { "reload",                 "Reload",                 "view", "win" },
                { "refresh",                "Refresh",                "view", "win" },
                { "fullscreen",             "Full Screen",            "view", "win" },
                { "toggle-fullscreen",      "Full Screen",            "view", "win" },
                // Go - win-level
                { "go-home",                "Home",                   "go",   "win" },
                { "home",                   "Home",                   "go",   "app" },
                { "back",                   "Back",                   "go",   "win" },
                { "forward",                "Forward",                "go",   "win" },
                { "up",                     "Up",                     "go",   "win" },
                { "enter-location",         "Enter Location…",        "go",   "win" },
                { "recent",                 "Recent Files",           "go",   "app" },
                // Help - app-level
                { "about",                  "About",                  "help", "app" },
                { "help",                   "Help",                   "help", "app" },
                { "whats-new",              "What's New",             "help", "app" },
                { "show-help",              "Help",                   "help", "app" },
                // Help - win-level
                { "keyboard-shortcuts",     "Keyboard Shortcuts",     "help", "win" },
                { "show-help-overlay",      "Keyboard Shortcuts",     "help", "win" },
            };
        }

        public static string? known_label (string action_name) {
            ensure_map ();
            foreach (unowned ActionDef def in KNOWN) {
                if (def.name == action_name) return def.label;
            }
            return null;
        }

        // Public entry point

        /**
         * Asynchronously build a menu from the app's exported actions.
         * Calls `callback` on the main thread with the menu (or null on failure).
         */
        public static void build_menu_async (string bus_name,
                                              owned MenuReadyCallback callback) {
            ensure_map ();
            // Chrome/Chromium don't export org.gtk.Actions - skip immediately
            string bus_lower = bus_name.down ();
            if ("chrome" in bus_lower || "chromium" in bus_lower) {
                callback (null);
                return;
            }
            string captured_bus = bus_name.dup ();
            owned MenuReadyCallback captured_cb = (owned) callback;

            new GLib.Thread<void> ("gtk-actions-menu", () => {
                GLib.Menu? menu = null;
                try {
                    menu = build_sync (captured_bus);
                } catch (GLib.Error e) {
                    // Not a GTK4/GLib app or no accessible actions - fine, returns null
                }
                var result = menu;
                GLib.Idle.add (() => {
                    captured_cb (result);
                    return GLib.Source.REMOVE;
                });
            });
        }

        // Internal sync implementation (background thread)

        private static GLib.Menu? build_sync (string bus_name) throws GLib.Error {
            var conn = GLib.Bus.get_sync (GLib.BusType.SESSION);
            if (!GLib.DBus.is_name (bus_name)) return null;
            string base_path = "/" + bus_name.replace (".", "/").replace ("-", "_");
            if (!GLib.Variant.is_object_path (base_path)) return null;
            string win_path  = Singularity.AppSystem.resolve_window_path (conn, bus_name, base_path);

            // Collect enabled actions from both app and window level
            var app_actions = collect_actions (conn, bus_name, base_path);
            var win_actions = collect_actions (conn, bus_name, win_path);

            if (app_actions.size () == 0 && win_actions.size () == 0) return null;

            // Build categorised menu
            var file_menu = new GLib.Menu ();
            var edit_menu = new GLib.Menu ();
            var view_menu = new GLib.Menu ();
            var go_menu   = new GLib.Menu ();
            var help_menu = new GLib.Menu ();

            var seen = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);

            foreach (unowned ActionDef def in KNOWN) {
                bool is_app = def.prefix == "app" && app_actions.contains (def.name);
                bool is_win = def.prefix == "win" && win_actions.contains (def.name);
                if (!is_app && !is_win) continue;

                string key = def.cat + ":" + def.label;
                if (seen.contains (key)) continue;
                seen.set (key, true);

                string action = def.prefix + "." + def.name;
                switch (def.cat) {
                    case "file": file_menu.append (def.label, action); break;
                    case "edit": edit_menu.append (def.label, action); break;
                    case "view": view_menu.append (def.label, action); break;
                    case "go":   go_menu.append   (def.label, action); break;
                    case "help": help_menu.append  (def.label, action); break;
                }
            }

            var menu = new GLib.Menu ();
            if (file_menu.get_n_items () > 0) menu.append_submenu ("File", file_menu);
            if (edit_menu.get_n_items () > 0) menu.append_submenu ("Edit", edit_menu);
            if (view_menu.get_n_items () > 0) menu.append_submenu ("View", view_menu);
            if (go_menu.get_n_items ()   > 0) menu.append_submenu ("Go",   go_menu);
            if (help_menu.get_n_items () > 0) menu.append_submenu ("Help", help_menu);

            return menu.get_n_items () > 0 ? menu : null;
        }

        /** Call org.gtk.Actions.DescribeAll and return a set of enabled parameterless action names. */
        private static GLib.HashTable<string, bool> collect_actions (
                GLib.DBusConnection conn, string bus_name, string obj_path) {
            var result = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);
            if (!GLib.Variant.is_object_path (obj_path)) return result;
            try {
                var resp = conn.call_sync (
                    bus_name, obj_path,
                    "org.gtk.Actions", "DescribeAll",
                    null, null,
                    GLib.DBusCallFlags.NONE, 2000);
                if (resp == null) return result;
                var dict = resp.get_child_value (0);
                for (size_t i = 0; i < dict.n_children (); i++) {
                    var entry = dict.get_child_value (i);
                    string aname = entry.get_child_value (0).get_string ();
                    var info  = entry.get_child_value (1);
                    bool enabled    = info.get_child_value (0).get_boolean ();
                    string param_t  = info.get_child_value (1).get_string ();
                    // Skip disabled or parameterised actions
                    if (enabled && param_t.length == 0)
                        result.set (aname, true);
                }
            } catch { /* not a GLib/GTK4 app, or path not found - silently ignore */ }
            return result;
        }
    }
}
