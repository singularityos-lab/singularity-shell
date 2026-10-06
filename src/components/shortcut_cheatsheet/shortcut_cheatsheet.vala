using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class ShortcutCheatsheet : Gtk.Window {
        private const int COLUMN_WIDTH = 300;
        private const int CARD_MAX_WIDTH = 1120;
        private const int MARGIN = 40;

        private static ShortcutCheatsheet? instance = null;
        private static GLib.Settings? settings = null;

        private Box stage;
        private Box card;
        private Singularity.Widgets.SearchEntry search;
        private Box content;
        private ScrolledWindow scroller;
        private Singularity.Widgets.StatusPage empty;
        private Stack body;
        private Label hint;
        private CheatsheetModel model = new CheatsheetModel();
        private bool _closing = false;
        private bool holding = false;
        private string? app_name = null;
        private GenericArray<MenuModel> watched = new GenericArray<MenuModel>();
        private uint refresh_id = 0;
        private HashTable<string, GenericArray<AppAccel>> accel_cache =
            new HashTable<string, GenericArray<AppAccel>>(str_hash, str_equal);
        private HashTable<string, bool> accel_pending = new HashTable<string, bool>(str_hash, str_equal);

        public static void setup(Gtk.Application app) {
            get_for(app);
            var source = GLib.SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema != null && schema.has_key("shortcut-cheatsheet-hold")) {
                settings = new GLib.Settings("dev.sinty.desktop");
                settings.changed["shortcut-cheatsheet-hold"].connect(apply_delay);
                settings.changed["shortcut-cheatsheet-delay"].connect(apply_delay);
            }
            SystemMonitor.get_default().shortcuts.shortcut_cheatsheet_triggered.connect(() => {
                get_for(app).toggle();
            });
            if (!Singularity.KeyHold.init(on_hold, app)) {
                message("ShortcutCheatsheet: compositor has no key hold support, use Super+/");
                return;
            }
            apply_delay();
            message("ShortcutCheatsheet: key hold ready");
        }

        private static void apply_delay() {
            uint delay = 800;
            bool enabled = true;
            if (settings != null) {
                enabled = settings.get_boolean("shortcut-cheatsheet-hold");
                delay = settings.get_uint("shortcut-cheatsheet-delay");
            }
            Singularity.KeyHold.set_delay(enabled ? delay : 0);
        }

        private static ShortcutCheatsheet get_for(Gtk.Application app) {
            if (instance == null) instance = new ShortcutCheatsheet(app);
            return instance;
        }

        private static void on_hold(bool started, bool cancelled, void* data) {
            var app = (Gtk.Application) data;
            var sheet = get_for(app);
            if (started) {
                message("ShortcutCheatsheet: hold started");
                sheet.holding = true;
                sheet.open();
                return;
            }
            message("ShortcutCheatsheet: hold ended%s", cancelled ? " (cancelled)" : "");
            sheet.holding = false;
            sheet.update_hint();
            if (cancelled || sheet.search.text == "") sheet.close_sheet();
        }

        public ShortcutCheatsheet(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-shortcuts");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("shortcut-cheatsheet-window");

            stage = new Box(Orientation.VERTICAL, 0);
            stage.hexpand = true;
            stage.vexpand = true;
            stage.add_css_class("shortcut-cheatsheet-scrim");
            set_child(stage);

            card = new Box(Orientation.VERTICAL, 12);
            card.add_css_class("shortcut-cheatsheet");
            card.halign = Align.CENTER;
            card.valign = Align.CENTER;
            card.vexpand = true;

            var header = new Box(Orientation.HORIZONTAL, 12);
            var title = new Label(_("Keyboard Shortcuts"));
            title.add_css_class("shortcut-cheatsheet-title");
            title.halign = Align.START;
            title.hexpand = true;
            header.append(title);
            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search Shortcuts");
            search.width_request = 280;
            search.search_changed.connect(rebuild);
            header.append(search);
            card.append(header);

            content = new Box(Orientation.VERTICAL, 20);
            scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.propagate_natural_height = true;
            scroller.set_child(content);

            empty = new Singularity.Widgets.StatusPage();
            empty.compact = true;
            empty.icon_name = "system-search";
            empty.title = _("No Matching Shortcuts");
            empty.description = _("Try another word, or the name of a key such as Ctrl.");

            body = new Stack();
            body.vhomogeneous = false;
            body.add_named(scroller, "list");
            body.add_named(empty, "empty");
            card.append(body);

            hint = new Label("");
            hint.add_css_class("dim-label");
            hint.add_css_class("caption");
            hint.halign = Align.START;
            card.append(hint);

            var bin = new Singularity.Animation.MotionBin(card);
            bin.halign = Align.CENTER;
            bin.valign = Align.CENTER;
            bin.vexpand = true;
            stage.append(bin);

            var outside = new GestureClick();
            outside.released.connect((n, x, y) => {
                var target = stage.pick(x, y, PickFlags.DEFAULT);
                if (target != null && target != stage) return;
                close_sheet();
            });
            stage.add_controller(outside);

            var keys = new EventControllerKey();
            keys.set_propagation_phase(PropagationPhase.CAPTURE);
            keys.key_pressed.connect(on_key);
            ((Widget) this).add_controller(keys);
            AppSystem.get_default().menu_model_changed.connect((model) => {
                watched = new GenericArray<MenuModel>();
                if (model != null) watch_menu(model, 0);
                string? focused = AppSystem.get_default().get_focused_app_id();
                string? bus = focused != null ? AppSystem.get_default().bus_name_for_app(focused) : null;
                if (bus != null) request_accels(bus);
            });
            this.visible = false;
        }

        private void watch_menu(MenuModel menu, int depth) {
            if (depth > CheatsheetModel.MENU_DEPTH) return;
            for (uint i = 0; i < watched.length; i++) {
                if (watched[i] == menu) return;
            }
            watched.add(menu);
            menu.items_changed.connect(() => {
                if (watched.length == 0 || !is_watched(menu)) return;
                watch_children(menu, depth);
                schedule_refresh();
            });
            watch_children(menu, depth);
        }

        private bool is_watched(MenuModel menu) {
            for (uint i = 0; i < watched.length; i++) {
                if (watched[i] == menu) return true;
            }
            return false;
        }

        private void watch_children(MenuModel menu, int depth) {
            for (int i = 0; i < menu.get_n_items(); i++) {
                MenuModel? link = menu.get_item_link(i, Menu.LINK_SUBMENU);
                if (link != null) watch_menu(link, depth + 1);
                link = menu.get_item_link(i, Menu.LINK_SECTION);
                if (link != null) watch_menu(link, depth + 1);
            }
        }

        private void request_accels(string bus) {
            if (accel_pending.contains(bus)) return;
            accel_pending.insert(bus, true);
            fetch_accels.begin(bus);
        }

        private async void fetch_accels(string bus) {
            GenericArray<AppAccel>? list = null;
            try {
                var conn = yield Bus.get(BusType.SESSION);
                list = yield AppAccelsReader.fetch(conn, bus);
            } catch (Error e) {
            }
            accel_pending.remove(bus);
            if (list != null) {
                foreach (var a in list.data) {
                    if (a.label != "") continue;
                    string? known = GtkActionsMenuProvider.known_label(a.action_name());
                    if (known != null) a.label = known;
                }
            }
            var previous = accel_cache.lookup(bus);
            if (AppAccelsReader.signature(previous) == AppAccelsReader.signature(list)) return;
            if (list != null) accel_cache.insert(bus, list);
            else accel_cache.remove(bus);
            message("ShortcutCheatsheet: %u exported shortcuts from %s", list != null ? list.length : 0, bus);
            if (visible && !_closing) {
                collect();
                rebuild();
            }
        }

        private void schedule_refresh() {
            if (!visible || _closing || refresh_id != 0) return;
            refresh_id = Timeout.add(60, () => {
                refresh_id = 0;
                if (visible && !_closing) {
                    collect();
                    rebuild();
                }
                return Source.REMOVE;
            });
        }

        private bool on_key(uint keyval, uint code, Gdk.ModifierType state) {
            if (keyval == Gdk.Key.Escape) {
                if (search.text != "" && holding) {
                    search.text = "";
                    return true;
                }
                close_sheet();
                return true;
            }
            if (keyval == Gdk.Key.Super_L || keyval == Gdk.Key.Super_R) return true;
            if ((state & Gdk.ModifierType.SUPER_MASK) == 0) return false;
            if (keyval == Gdk.Key.BackSpace) {
                string t = search.text;
                if (t.length > 0) search.text = t.substring(0, t.index_of_nth_char(t.char_count() - 1));
                return true;
            }
            unichar c = Gdk.keyval_to_unicode(keyval);
            if (c != 0 && (c.isgraph() || c == ' ')) {
                search.text = search.text + c.to_string();
                search.entry.set_position(-1);
                return true;
            }
            return true;
        }

        private void collect() {
            model = new CheatsheetModel();
            var app_system = AppSystem.get_default();
            string? app_id = app_system.get_focused_app_id();
            app_name = null;
            if (app_id != null && app_id != "") {
                var info = app_system.resolve_app_for_id(app_id);
                app_name = info != null ? info.get_name() : readable_app_id(app_id);
                var menu = app_system.current_menu_model;
                if (menu != null) {
                    watch_menu(menu, 0);
                    model.add_menu(app_name, menu);
                }
                string? bus = app_system.bus_name_for_app(app_id);
                if (bus != null) {
                    var accels = accel_cache.lookup(bus);
                    if (accels != null) model.add_accels(app_name, accels);
                    request_accels(bus);
                }
            }
            var manager = SystemMonitor.get_default().shortcuts;
            model.add_keys(_("Launch and Find"), _("Open the launcher"), { _("Super") });
            model.add_keys(_("Launch and Find"), _("Show keyboard shortcuts"), { _("Hold Super") });
            foreach (var s in manager.shortcuts) {
                if (s.action_name == "switch_input_method" && !has_input_methods()) continue;
                model.add_desktop(s.action_name, s.description, s.accelerator);
            }
            model.add_desktop("switch_windows_next", _("Switch between windows"), "<Alt>Tab");
            model.add_desktop("close_window", _("Close the window"), "<Alt>F4");
            for (int i = 1; i <= 4; i++) {
                model.add_desktop("go_to_workspace", _("Go to workspace %d").printf(i), "<Control><Alt>%d".printf(i));
            }
            foreach (var k in manager.custom_keybindings) {
                model.add_desktop("custom:" + k.id, k.name, k.accelerator);
            }
            model.order_sections();
            message("ShortcutCheatsheet: %u shortcuts, focused app %s", model.total, app_name ?? "none");
        }

        private static string readable_app_id(string app_id) {
            string id = app_id.has_suffix(".desktop") ? app_id.substring(0, app_id.length - 8) : app_id;
            int dot = id.last_index_of(".");
            string tail = dot >= 0 ? id.substring(dot + 1) : id;
            tail = tail.replace("-", " ").replace("_", " ");
            if (tail == "") return app_id;
            return tail.substring(0, 1).up() + tail.substring(1);
        }

        private static bool has_input_methods() {
            return settings != null && settings.get_strv("input-method-engines").length > 0;
        }

        private int column_count() {
            int width = get_width();
            if (width <= 0) {
                var display = Gdk.Display.get_default();
                var monitors = display != null ? display.get_monitors() : null;
                if (monitors != null && monitors.get_n_items() > 0) {
                    width = ((Gdk.Monitor) monitors.get_item(0)).geometry.width;
                }
            }
            if (width <= 0) width = 1280;
            int usable = int.min(width - 2 * MARGIN, CARD_MAX_WIDTH) - 48;
            return int.max(1, usable / (COLUMN_WIDTH + 24));
        }

        private void rebuild() {
            Widget? child;
            while ((child = content.get_first_child()) != null) content.remove(child);
            var sections = model.filter(search.text);
            int columns = column_count();
            card.width_request = columns * (COLUMN_WIDTH + 24) + 24;
            int height = get_height() > 0 ? get_height() : 720;
            scroller.max_content_height = int.max(200, height - 2 * MARGIN - 140);

            var app_sections = new GenericArray<CheatsheetSection>();
            var desktop_sections = new GenericArray<CheatsheetSection>();
            for (uint i = 0; i < sections.length; i++) {
                if (sections[i].is_app) app_sections.add(sections[i]);
                else desktop_sections.add(sections[i]);
            }
            if (app_sections.length > 0) content.append(build_area(app_name ?? _("App"), app_sections, columns));
            if (desktop_sections.length > 0) content.append(build_area(_("Desktop"), desktop_sections, columns));
            body.visible_child_name = sections.length > 0 ? "list" : "empty";
            update_hint();
        }

        private Widget build_area(string heading, GenericArray<CheatsheetSection> sections, int columns) {
            var area = new Box(Orientation.VERTICAL, 8);
            var label = new Label(heading);
            label.add_css_class("shortcut-cheatsheet-area");
            label.halign = Align.START;
            area.append(label);
            var row = new Box(Orientation.HORIZONTAL, 24);
            row.homogeneous = true;
            var cols = new Box[columns];
            int[] weight = new int[columns];
            for (int i = 0; i < columns; i++) {
                cols[i] = new Box(Orientation.VERTICAL, 16);
                cols[i].width_request = COLUMN_WIDTH;
                row.append(cols[i]);
            }
            for (uint i = 0; i < sections.length; i++) {
                int best = 0;
                for (int c = 1; c < columns; c++) {
                    if (weight[c] < weight[best]) best = c;
                }
                cols[best].append(build_section(sections[i]));
                weight[best] += (int) sections[i].entries.length + 2;
            }
            area.append(row);
            return area;
        }

        private Widget build_section(CheatsheetSection section) {
            var box = new Box(Orientation.VERTICAL, 4);
            var title = new Label(section.title);
            title.add_css_class("shortcut-cheatsheet-section");
            title.halign = Align.START;
            box.append(title);
            for (uint i = 0; i < section.entries.length; i++) {
                var e = section.entries[i];
                var line = new Box(Orientation.HORIZONTAL, 8);
                line.add_css_class("shortcut-cheatsheet-row");
                var name = new Label(e.label);
                name.halign = Align.START;
                name.hexpand = true;
                name.xalign = 0;
                name.wrap = true;
                name.wrap_mode = Pango.WrapMode.WORD_CHAR;
                name.max_width_chars = 20;
                line.append(name);
                var caps = new Box(Orientation.HORIZONTAL, 3);
                caps.valign = Align.CENTER;
                foreach (string k in e.keys) {
                    var cap = new Label(k);
                    cap.add_css_class("shortcut-cheatsheet-key");
                    caps.append(cap);
                }
                line.append(caps);
                box.append(line);
            }
            return box;
        }

        private void update_hint() {
            if (search.text != "") {
                hint.label = _("Esc clears the search, release Super to keep the results open");
                if (!holding) hint.label = _("Esc closes");
            } else if (holding) {
                hint.label = _("Type to search, release Super to close");
            } else {
                hint.label = _("Type to search, Esc closes");
            }
        }

        public void toggle() {
            if (visible && !_closing) {
                close_sheet();
                return;
            }
            open();
        }

        public void open() {
            _closing = false;
            collect();
            search.text = "";
            rebuild();
            present();
            search.grab_focus();
            stage.opacity = 0.0;
            Singularity.Motion.tween(stage, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM.ms(),
                Singularity.Motion.Curve.ENTER);
            Singularity.Motion.reveal(card, Singularity.Motion.Preset.SCALE_FADE);
            Idle.add(() => {
                if (visible && !_closing) rebuild();
                return Source.REMOVE;
            });
        }

        public void close_sheet() {
            if (holding) {
                holding = false;
                Singularity.KeyHold.finish();
            }
            if (!visible || _closing) return;
            _closing = true;
            Singularity.Motion.tween(stage, "opacity", 0.0, Singularity.Motion.Duration.MEDIUM.exit_ms(),
                Singularity.Motion.Curve.EXIT);
            var anim = Singularity.Motion.conceal(card, Singularity.Motion.Preset.SCALE_FADE);
            anim.done.connect(() => {
                if (!_closing) return;
                _closing = false;
                close_layer_window(this);
            });
        }
    }
}
