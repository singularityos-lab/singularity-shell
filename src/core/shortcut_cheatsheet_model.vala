namespace Singularity {

    public class AppAccel : Object {
        public string action = "";
        public string label = "";
        public string group = "";
        public string[] accels = {};

        public string action_name() {
            string name = action;
            int dot = name.index_of(".");
            if (dot >= 0) name = name.substring(dot + 1);
            int target = name.index_of("::");
            if (target >= 0) name = name.substring(0, target);
            return name;
        }

        public string display_label() {
            if (label != "") return label;
            string words = action_name().replace("-", " ").replace("_", " ").strip();
            if (words == "") return "";
            return words.substring(0, 1).up() + words.substring(1);
        }
    }

    public class CheatsheetEntry : Object {
        public string label { get; construct; }
        public string accel { get; construct; }
        public string[] keys;
        public string search_text;

        public CheatsheetEntry(string label, string accel, string[] keys) {
            Object(label: label, accel: accel);
            this.keys = keys;
            search_text = (label + " " + string.joinv(" ", keys)).casefold();
        }
    }

    public class CheatsheetSection : Object {
        public string title { get; construct; }
        public string? app_name { get; construct; }
        public GenericArray<CheatsheetEntry> entries = new GenericArray<CheatsheetEntry>();

        public CheatsheetSection(string title, string? app_name = null) {
            Object(title: title, app_name: app_name);
        }

        public bool is_app {
            get { return app_name != null; }
        }
    }

    public class CheatsheetModel : Object {
        public const int MENU_DEPTH = 4;

        public GenericArray<CheatsheetSection> sections = new GenericArray<CheatsheetSection>();
        private HashTable<string, bool> seen = new HashTable<string, bool>(str_hash, str_equal);
        private HashTable<string, bool> app_combos = new HashTable<string, bool>(str_hash, str_equal);

        public static string desktop_group(string action) {
            if (action.has_prefix("custom:")) return _("Custom");
            if (action.has_prefix("snap_") || action.has_prefix("pip_") || action == "retile_windows"
                    || action == "close_window" || action.has_prefix("switch_windows")) {
                return _("Windows");
            }
            if (action.has_prefix("send_to_workspace") || action.has_prefix("go_to_workspace")
                    || action == "toggle_workspace_overview" || action == "toggle_desktop_reveal") {
                return _("Workspaces");
            }
            if (action == "toggle_screen_reader" || action.has_prefix("zoom") || action == "toggle_zoom") {
                return _("Accessibility");
            }
            if (action.has_prefix("screenshot")) return _("Screenshots");
            if (action.has_prefix("volume") || action.has_prefix("brightness") || action.has_prefix("kbd_")
                    || action == "mic_mute" || action == "lock_screen" || action == "switch_input_method") {
                return _("System");
            }
            return _("Launch and Find");
        }

        public static string[] desktop_group_order() {
            return {
                _("Launch and Find"), _("Windows"), _("Workspaces"), _("Screenshots"),
                _("System"), _("Accessibility"), _("Custom")
            };
        }

        public static string modifier_label(Gdk.ModifierType mod) {
            switch (mod) {
                case Gdk.ModifierType.SUPER_MASK: return _("Super");
                case Gdk.ModifierType.CONTROL_MASK: return _("Ctrl");
                case Gdk.ModifierType.ALT_MASK: return _("Alt");
                case Gdk.ModifierType.SHIFT_MASK: return _("Shift");
                case Gdk.ModifierType.META_MASK: return _("Meta");
                case Gdk.ModifierType.HYPER_MASK: return _("Hyper");
                default: return "";
            }
        }

        public static string key_label(uint key) {
            switch (key) {
                case Gdk.Key.Left: return _("Left");
                case Gdk.Key.Right: return _("Right");
                case Gdk.Key.Up: return _("Up");
                case Gdk.Key.Down: return _("Down");
                case Gdk.Key.Return: case Gdk.Key.KP_Enter: return _("Enter");
                case Gdk.Key.space: return _("Space");
                case Gdk.Key.Tab: case Gdk.Key.ISO_Left_Tab: return _("Tab");
                case Gdk.Key.Escape: return _("Esc");
                case Gdk.Key.BackSpace: return _("Backspace");
                case Gdk.Key.Delete: return _("Delete");
                case Gdk.Key.Print: return _("Print Screen");
                case Gdk.Key.Page_Up: return _("Page Up");
                case Gdk.Key.Page_Down: return _("Page Down");
                case Gdk.Key.Home: return _("Home");
                case Gdk.Key.End: return _("End");
                default: break;
            }
            unichar c = Gdk.keyval_to_unicode(key);
            if (c != 0 && c.isgraph()) return c.toupper().to_string();
            string? name = Gdk.keyval_name(key);
            return name ?? "";
        }

        public static string[]? keys_for_accel(string accel) {
            if (accel == "") return null;
            uint key;
            Gdk.ModifierType mods;
            if (!Gtk.accelerator_parse(accel, out key, out mods) || key == 0) return null;
            if ((key & 0xFFFF0000) == 0x10080000) return null;
            string[] keys = {};
            Gdk.ModifierType[] order = {
                Gdk.ModifierType.SUPER_MASK, Gdk.ModifierType.CONTROL_MASK, Gdk.ModifierType.ALT_MASK,
                Gdk.ModifierType.SHIFT_MASK, Gdk.ModifierType.META_MASK, Gdk.ModifierType.HYPER_MASK
            };
            foreach (var mod in order) {
                if ((mods & mod) != 0) keys += modifier_label(mod);
            }
            string label = key_label(key);
            if (label == "") return null;
            keys += label;
            return keys;
        }

        public CheatsheetSection section(string title, string? app_name = null) {
            for (uint i = 0; i < sections.length; i++) {
                var s = sections[i];
                if (s.title == title && s.app_name == app_name) return s;
            }
            var s = new CheatsheetSection(title, app_name);
            sections.add(s);
            return s;
        }

        public bool add(string title, string label, string accel, string? app_name = null) {
            string clean = label.replace("_", "").replace("…", "").strip();
            if (clean == "") return false;
            string[]? keys = keys_for_accel(accel);
            if (keys == null) return false;
            string id = "%s\n%s\n%s\n%s".printf(app_name ?? "", title, clean, string.joinv("+", keys));
            if (seen.contains(id)) return false;
            seen.insert(id, true);
            if (app_name != null) app_combos.insert(app_name + "\n" + string.joinv("+", keys), true);
            section(title, app_name).entries.add(new CheatsheetEntry(clean, accel, keys));
            return true;
        }

        public bool add_keys(string title, string label, string[] keys, string? app_name = null) {
            if (label == "" || keys.length == 0) return false;
            string id = "%s\n%s\n%s\n%s".printf(app_name ?? "", title, label, string.joinv("+", keys));
            if (seen.contains(id)) return false;
            seen.insert(id, true);
            section(title, app_name).entries.add(new CheatsheetEntry(label, "", keys));
            return true;
        }

        public void add_desktop(string action, string label, string accel) {
            add(desktop_group(action), label, accel);
        }

        public int add_accels(string app_name, GenericArray<AppAccel> list) {
            int added = 0;
            foreach (var a in list.data) {
                string label = a.display_label();
                if (label == "") continue;
                foreach (string accel in a.accels) {
                    string[]? keys = keys_for_accel(accel);
                    if (keys == null) continue;
                    if (app_combos.contains(app_name + "\n" + string.joinv("+", keys))) break;
                    if (add(a.group != "" ? a.group : app_name, label, accel, app_name)) added++;
                    break;
                }
            }
            order_sections();
            return added;
        }

        public int add_menu(string app_name, MenuModel menu) {
            int added = 0;
            for (int i = 0; i < menu.get_n_items(); i++) {
                string? label = null;
                menu.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                string title = label != null ? label.replace("_", "").strip() : "";
                if (title == "") title = app_name;
                MenuModel? sub = menu.get_item_link(i, Menu.LINK_SUBMENU);
                if (sub == null) sub = menu.get_item_link(i, Menu.LINK_SECTION);
                if (sub != null) {
                    added += walk_menu(app_name, title, sub, 1);
                } else {
                    string? accel = null;
                    menu.get_item_attribute(i, "accel", "s", out accel);
                    if (accel != null && add(app_name, title, accel, app_name)) added++;
                }
            }
            order_sections();
            return added;
        }

        private int walk_menu(string app_name, string title, MenuModel menu, int depth) {
            if (depth > MENU_DEPTH) return 0;
            int added = 0;
            for (int i = 0; i < menu.get_n_items(); i++) {
                MenuModel? link = menu.get_item_link(i, Menu.LINK_SECTION);
                if (link == null) link = menu.get_item_link(i, Menu.LINK_SUBMENU);
                if (link != null) {
                    added += walk_menu(app_name, title, link, depth + 1);
                    continue;
                }
                string? label = null;
                string? accel = null;
                menu.get_item_attribute(i, Menu.ATTRIBUTE_LABEL, "s", out label);
                menu.get_item_attribute(i, "accel", "s", out accel);
                if (label == null || accel == null) continue;
                if (add(title, label, accel, app_name)) added++;
            }
            return added;
        }

        public void order_sections() {
            var ordered = new GenericArray<CheatsheetSection>();
            for (uint i = 0; i < sections.length; i++) {
                if (sections[i].is_app) ordered.add(sections[i]);
            }
            foreach (string title in desktop_group_order()) {
                for (uint i = 0; i < sections.length; i++) {
                    if (!sections[i].is_app && sections[i].title == title) ordered.add(sections[i]);
                }
            }
            for (uint i = 0; i < sections.length; i++) {
                bool known = sections[i].is_app;
                foreach (string title in desktop_group_order()) {
                    if (sections[i].title == title) known = true;
                }
                if (!known) ordered.add(sections[i]);
            }
            sections = ordered;
        }

        public uint total {
            get {
                uint n = 0;
                for (uint i = 0; i < sections.length; i++) n += sections[i].entries.length;
                return n;
            }
        }

        public static bool entry_matches(CheatsheetEntry e, string head, string token) {
            if (token.char_count() > 1) return e.search_text.contains(token) || head.contains(token);
            foreach (string k in e.keys) {
                if (k.casefold() == token) return true;
            }
            foreach (string word in e.label.casefold().split(" ")) {
                if (word.has_prefix(token)) return true;
            }
            return false;
        }

        public GenericArray<CheatsheetSection> filter(string query) {
            string[] tokens = {};
            foreach (string t in query.casefold().strip().split(" ")) {
                if (t != "") tokens += t;
            }
            if (tokens.length == 0) return sections;
            var result = new GenericArray<CheatsheetSection>();
            for (uint i = 0; i < sections.length; i++) {
                var s = sections[i];
                string head = (s.title + " " + (s.app_name ?? "")).casefold();
                var copy = new CheatsheetSection(s.title, s.app_name);
                for (uint j = 0; j < s.entries.length; j++) {
                    var e = s.entries[j];
                    bool all = true;
                    foreach (string t in tokens) {
                        if (!entry_matches(e, head, t)) {
                            all = false;
                            break;
                        }
                    }
                    if (all) copy.entries.add(e);
                }
                if (copy.entries.length > 0) result.add(copy);
            }
            return result;
        }
    }
}
