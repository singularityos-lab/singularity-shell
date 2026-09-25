using Gtk;
using GLib;
using Singularity.Widgets;

namespace Singularity {

    public class KeyboardPage : SettingsPage {
        private class ShortcutItem {
            public ActionRow row;
            public string terms;

            public ShortcutItem(ActionRow row, string terms) {
                this.row = row;
                this.terms = terms;
            }
        }

        private class ShortcutSection {
            public PreferencesGroup group;
            public string terms;
            public List<ShortcutItem> items = new List<ShortcutItem>();

            public ShortcutSection(PreferencesGroup group, string terms) {
                this.group = group;
                this.terms = terms;
            }
        }

        private PreferencesGroup input_group;
        private ShortcutManager manager;
        private Singularity.Widgets.SearchEntry shortcut_search;
        private Box shortcuts_box;
        private PreferencesGroup empty_group;
        private List<ShortcutSection> sections = new List<ShortcutSection>();

        public KeyboardPage(SettingsView view) {
            base(_("Keyboard"));
            back_clicked.connect(() => view.go_home());

            manager = SystemMonitor.get_default().shortcuts;

            shortcut_search = new Singularity.Widgets.SearchEntry();
            shortcut_search.placeholder_text = _("Search shortcuts...");
            shortcut_search.margin_top = 4;
            shortcut_search.margin_bottom = 4;
            shortcut_search.margin_start = 12;
            shortcut_search.margin_end = 12;
            shortcut_search.search_changed.connect(filter_shortcuts);
            add_widget(shortcut_search);

            shortcuts_box = new Box(Orientation.VERTICAL, 0);
            add_widget(shortcuts_box);
            rebuild_shortcuts();
            manager.shortcut_changed.connect(() => rebuild_shortcuts());

            input_group = new PreferencesGroup(_("Input Sources"),
                _("Choose the keyboard layouts available in the desktop"));
            add_group(input_group);
            refresh_input_sources(view);

            var settings = new GLib.Settings("dev.sinty.desktop");
            var pointer_group = new PreferencesGroup(_("Mouse & Touchpad"));
            var accel_row = new SwitchRow(_("Mouse Acceleration"),
                _("Turn off for a flat 1:1 pointer profile"),
                settings.get_boolean("mouse-acceleration"));
            settings.bind("mouse-acceleration", accel_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            pointer_group.add_row(accel_row);

            var natural_row = new SwitchRow(_("Natural Scrolling"),
                _("Reverse the touchpad scroll direction"),
                settings.get_boolean("natural-scrolling"));
            settings.bind("natural-scrolling", natural_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            pointer_group.add_row(natural_row);

            var scroll_speed_row = new ActionRow(_("Touchpad Scroll Speed"),
                _("How far content moves as your fingers scroll"));
            scroll_speed_row.activatable = false;
            var scroll_speed_scale = new Scale.with_range(Orientation.HORIZONTAL, 25, 300, 5);
            scroll_speed_scale.width_request = 170;
            scroll_speed_scale.draw_value = true;
            scroll_speed_scale.value_pos = PositionType.RIGHT;
            scroll_speed_scale.add_mark(100, PositionType.BOTTOM, null);
            scroll_speed_scale.set_format_value_func((scale, value) => "%.0f%%".printf(value));
            scroll_speed_scale.set_value(settings.get_double("touchpad-scroll-speed") * 100);
            uint scroll_speed_timeout = 0;
            scroll_speed_scale.value_changed.connect(() => {
                if (scroll_speed_timeout != 0) Source.remove(scroll_speed_timeout);
                scroll_speed_timeout = Timeout.add(200, () => {
                    scroll_speed_timeout = 0;
                    settings.set_double("touchpad-scroll-speed", scroll_speed_scale.get_value() / 100);
                    return Source.REMOVE;
                });
            });
            scroll_speed_row.add_suffix(scroll_speed_scale);
            pointer_group.add_row(scroll_speed_row);
            add_group(pointer_group);
        }

        private void rebuild_shortcuts() {
            Widget? child = shortcuts_box.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                shortcuts_box.remove(child);
                child = next;
            }
            sections = new List<ShortcutSection>();

            var desktop = add_section(_("Desktop"), _("Launch apps and desktop tools"));
            var windows = add_section(_("Windows"), _("Move, tile and switch windows"));
            var workspaces = add_section(_("Workspaces"), _("Switch workspaces or move the focused window"));
            var capture = add_section(_("Capture"), _("Screenshots and picture in picture"));
            var hardware = add_section(_("Hardware"), _("Sound, display and keyboard controls"));

            if (manager.shortcuts != null) {
                foreach (var shortcut in manager.shortcuts) {
                    var section = section_for_action(shortcut.action_name,
                        desktop, windows, workspaces, capture, hardware);
                    add_editable_shortcut(section, shortcut);
                }
            }

            add_fixed_shortcut(windows, _("Switch to Next Window"),
                _("Cycle forward through open windows"), "<Alt>Tab", "focus-windows-symbolic");
            add_fixed_shortcut(windows, _("Switch to Previous Window"),
                _("Cycle backward through open windows"), "<Shift><Alt>Tab", "focus-windows-symbolic");
            add_fixed_shortcut(windows, _("Close Window"),
                _("Close the focused window"), "<Alt>F4", "window-close-symbolic");

            for (int i = 1; i <= 4; i++) {
                add_fixed_shortcut(workspaces, _("Switch to Workspace %d").printf(i),
                    _("Show workspace %d").printf(i), "<Control><Alt>%d".printf(i),
                    "preferences-desktop-workspaces-symbolic");
            }
            for (int i = 1; i <= 4; i++) {
                add_fixed_shortcut(workspaces, _("Move Window to Workspace %d").printf(i),
                    _("Send the focused window to workspace %d").printf(i),
                    "<Control><Alt><Shift>%d".printf(i), "go-jump-symbolic");
            }

            empty_group = new PreferencesGroup();
            empty_group.margin_top = 12;
            empty_group.add_row(new ActionRow(_("No shortcuts found"),
                _("Try a different search"), "system-search-symbolic"));
            shortcuts_box.append(empty_group);
            filter_shortcuts();
        }

        private ShortcutSection add_section(string title, string description) {
            var group = new PreferencesGroup(title, description);
            group.margin_top = 12;
            shortcuts_box.append(group);
            var section = new ShortcutSection(group, "%s %s".printf(title, description).down());
            sections.append(section);
            return section;
        }

        private ShortcutSection section_for_action(string action,
                                                    ShortcutSection desktop,
                                                    ShortcutSection windows,
                                                    ShortcutSection workspaces,
                                                    ShortcutSection capture,
                                                    ShortcutSection hardware) {
            switch (action) {
                case "snap_left":
                case "snap_right":
                case "snap_up":
                case "snap_down":
                case "retile_windows":
                    return windows;
                case "toggle_workspace_overview":
                    return workspaces;
                case "screenshot_tool":
                case "screenshot_region":
                case "screenshot_window":
                case "pip_region":
                case "pip_window":
                    return capture;
                case "volume_up":
                case "volume_down":
                case "volume_mute":
                case "mic_mute":
                case "brightness_up":
                case "brightness_down":
                case "kbd_brightness_up":
                case "kbd_brightness_down":
                    return hardware;
                default:
                    return desktop;
            }
        }

        private void add_editable_shortcut(ShortcutSection section, Shortcut shortcut) {
            var row = new ActionRow(_(shortcut.name), _(shortcut.description),
                icon_for_action(shortcut.action_name));
            row.activatable = false;

            if (shortcut.accelerator != shortcut.default_accelerator) {
                var reset_btn = new Button.from_icon_name("edit-undo-symbolic");
                reset_btn.add_css_class("flat");
                reset_btn.tooltip_text = _("Reset to Default");
                reset_btn.clicked.connect(() => manager.reset_shortcut(shortcut.id));
                row.add_suffix(reset_btn);
            }

            if (shortcut.accelerator != "" &&
                    shortcut.secondary_accelerator != null &&
                    shortcut.secondary_accelerator != shortcut.accelerator) {
                row.add_suffix(new ShortcutLabel(shortcut.secondary_accelerator));
            }

            string shown_accel = shortcut.accelerator;
            if (shown_accel == "" && shortcut.secondary_accelerator != null)
                shown_accel = shortcut.secondary_accelerator;
            var shortcut_label = new ShortcutLabel(shown_accel);
            shortcut_label.disabled_text = _("Disabled");
            var edit_btn = new Button();
            edit_btn.has_frame = false;
            edit_btn.add_css_class("flat");
            edit_btn.tooltip_text = _("Change Shortcut");
            edit_btn.set_child(shortcut_label);
            edit_btn.clicked.connect(() => show_edit_dialog(shortcut));
            row.add_suffix(edit_btn);

            section.group.add_row(row);
            string terms = "%s %s %s %s".printf(shortcut.name, shortcut.description,
                shortcut.accelerator, shortcut.secondary_accelerator ?? "").down();
            section.items.append(new ShortcutItem(row, terms));
        }

        private void add_fixed_shortcut(ShortcutSection section, string title, string description,
                                        string accelerator, string icon_name) {
            var row = new ActionRow(title, description, icon_name);
            row.activatable = false;
            row.add_suffix(new ShortcutLabel(accelerator));
            section.group.add_row(row);
            section.items.append(new ShortcutItem(row,
                "%s %s %s".printf(title, description, accelerator).down()));
        }

        private string icon_for_action(string action) {
            switch (action) {
                case "toggle_launcher": return "view-app-grid-symbolic";
                case "toggle_workspace_overview": return "preferences-desktop-workspaces-symbolic";
                case "toggle_desktop_reveal": return "user-desktop-symbolic";
                case "spawn_terminal": return "utilities-terminal-symbolic";
                case "toggle_emoji_picker": return "face-smile-symbolic";
                case "run_command": return "system-run-symbolic";
                case "lock_screen": return "system-lock-screen-symbolic";
                case "screenshot_tool":
                case "screenshot_region":
                case "screenshot_window": return "camera-photo-symbolic";
                case "pip_region":
                case "pip_window": return "video-display-symbolic";
                case "volume_up": return "audio-volume-high-symbolic";
                case "volume_down": return "audio-volume-low-symbolic";
                case "volume_mute": return "audio-volume-muted-symbolic";
                case "mic_mute": return "microphone-sensitivity-muted-symbolic";
                case "brightness_up":
                case "brightness_down": return "display-brightness-symbolic";
                case "kbd_brightness_up":
                case "kbd_brightness_down": return "input-keyboard-symbolic";
                default: return "focus-windows-symbolic";
            }
        }

        private void filter_shortcuts() {
            string query = shortcut_search.text.strip().down();
            int visible_rows = 0;
            foreach (var section in sections) {
                bool section_match = query == "" || section.terms.contains(query);
                int section_rows = 0;
                foreach (var item in section.items) {
                    bool visible = section_match || item.terms.contains(query);
                    item.row.visible = visible;
                    if (visible) section_rows++;
                }
                section.group.visible = section_rows > 0;
                visible_rows += section_rows;
            }
            empty_group.visible = visible_rows == 0;
        }

        private void show_edit_dialog(Shortcut shortcut) {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Shell.ShellDialog(app);
            var content = new Box(Orientation.VERTICAL, 16);
            content.margin_top = 32;
            content.margin_bottom = 32;
            content.margin_start = 32;
            content.margin_end = 32;
            content.halign = Align.CENTER;
            content.valign = Align.CENTER;
            content.set_size_request(340, -1);

            var icon = new Image.from_icon_name(icon_for_action(shortcut.action_name));
            icon.pixel_size = 48;
            content.append(icon);

            var title = new Label(_(shortcut.name));
            title.add_css_class("title-1");
            title.wrap = true;
            title.justify = Justification.CENTER;
            content.append(title);

            var hint = new Label(_("Press the new key combination"));
            hint.add_css_class("dim-label");
            content.append(hint);

            var current = new ShortcutLabel(shortcut.accelerator);
            current.disabled_text = _("Disabled");
            current.halign = Align.CENTER;
            content.append(current);

            var actions = new Box(Orientation.HORIZONTAL, 8);
            actions.halign = Align.CENTER;
            var disable_btn = new Button.with_label(_("Disable"));
            disable_btn.add_css_class("flat");
            disable_btn.clicked.connect(() => {
                manager.update_shortcut(shortcut.id, "");
                dialog.close_dialog();
            });
            actions.append(disable_btn);
            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("flat");
            cancel_btn.clicked.connect(() => dialog.close_dialog());
            actions.append(cancel_btn);
            content.append(actions);
            dialog.content_box.append(content);

            var controller = new EventControllerKey();
            controller.propagation_phase = PropagationPhase.CAPTURE;
            controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    dialog.close_dialog();
                    return true;
                }
                switch (keyval) {
                    case Gdk.Key.Control_L: case Gdk.Key.Control_R:
                    case Gdk.Key.Shift_L: case Gdk.Key.Shift_R:
                    case Gdk.Key.Alt_L: case Gdk.Key.Alt_R:
                    case Gdk.Key.Super_L: case Gdk.Key.Super_R:
                    case Gdk.Key.Meta_L: case Gdk.Key.Meta_R:
                        return true;
                }
                var modifiers = state & Gtk.accelerator_get_default_mod_mask();
                string accel = Gtk.accelerator_name(keyval, modifiers);
                if (accel != "") {
                    manager.update_shortcut(shortcut.id, accel);
                    dialog.close_dialog();
                }
                return true;
            });
            ((Widget) dialog).add_controller(controller);
            dialog.present();
            dialog.grab_focus();
        }

        private void refresh_input_sources(SettingsView view) {
            input_group.clear();
            var source = SettingsSchemaSource.get_default();
            if (source.lookup("org.gnome.desktop.input-sources", true) != null) {
                var settings = new GLib.Settings("org.gnome.desktop.input-sources");
                var sources = settings.get_value("sources");
                if (sources.is_of_type(new VariantType("a(ss)"))) {
                    int source_count = 0;
                    var iter_count = sources.iterator();
                    string count_type, count_id;
                    while (iter_count.next("(ss)", out count_type, out count_id))
                        source_count++;

                    var iter = sources.iterator();
                    string type, id;
                    while (iter.next("(ss)", out type, out id)) {
                        string label_text = type == "xkb" ? id.up() : id;
                        var row = new ActionRow(label_text, _("Keyboard layout"),
                            "input-keyboard-symbolic");
                        string source_type = type;
                        string source_id = id;
                        var remove_btn = new Button.from_icon_name("user-trash-symbolic");
                        remove_btn.add_css_class("flat");
                        remove_btn.add_css_class("destructive-action");
                        if (source_count <= 1) {
                            remove_btn.sensitive = false;
                            remove_btn.tooltip_text = _("Cannot remove the last input source");
                        } else {
                            remove_btn.tooltip_text = _("Remove Input Source");
                            remove_btn.clicked.connect(() => {
                                row.confirmation_requested(_("Remove"), _("Cancel"),
                                    ConfirmationSuggestedAction.CANCEL);
                            });
                            row.confirmed.connect(() => {
                                remove_input_source(source_type, source_id);
                                refresh_input_sources(view);
                            });
                        }
                        row.add_suffix(remove_btn);
                        input_group.add_row(row);
                    }
                }
            }

            var add_row = new ActionRow(_("Add Input Source"),
                _("Add another keyboard layout"), "list-add-symbolic");
            add_row.activated.connect(() => {
                var page = new Singularity.SidebarPages.AddInputSourcePage(view);
                page.source_selected.connect((id, name) => {
                    add_input_source("xkb", id);
                    refresh_input_sources(view);
                    view.navigate_to("keyboard");
                });
                view.open_subpage(page, "add-input-source");
            });
            input_group.add_row(add_row);
        }

        private void add_input_source(string type, string id) {
            try {
                var settings = new GLib.Settings("org.gnome.desktop.input-sources");
                var current = settings.get_value("sources");
                var builder = new VariantBuilder(new VariantType("a(ss)"));

                builder.add("(ss)", type, id);
                var iter = current.iterator();
                string current_type, current_id;
                while (iter.next("(ss)", out current_type, out current_id)) {
                    if (current_type == type && current_id == id) continue;
                    builder.add("(ss)", current_type, current_id);
                }
                var sources = builder.end();
                settings.set_value("sources", sources);
                sync_to_singularity_schema(sources);
            } catch (Error e) {
                warning("Failed to add input source: %s", e.message);
            }
        }

        private void remove_input_source(string type, string id) {
            try {
                var settings = new GLib.Settings("org.gnome.desktop.input-sources");
                var current = settings.get_value("sources");
                var builder = new VariantBuilder(new VariantType("a(ss)"));
                var iter = current.iterator();
                string current_type, current_id;
                while (iter.next("(ss)", out current_type, out current_id)) {
                    if (current_type == type && current_id == id) continue;
                    builder.add("(ss)", current_type, current_id);
                }
                var sources = builder.end();
                settings.set_value("sources", sources);
                sync_to_singularity_schema(sources);
            } catch (Error e) {
                warning("Failed to remove input source: %s", e.message);
            }
        }

        private void sync_to_singularity_schema(Variant sources) {
            try {
                var desktop_settings = new GLib.Settings("dev.sinty.desktop");
                var iter = sources.iterator();
                string type, id;
                while (iter.next("(ss)", out type, out id)) {
                    if (type != "xkb") continue;
                    string layout = id;
                    string variant = "";
                    if (id.contains("+")) {
                        layout = id.substring(0, id.index_of("+"));
                        variant = id.substring(id.index_of("+") + 1);
                    }
                    desktop_settings.set_string("xkb-layout", layout);
                    desktop_settings.set_string("xkb-variant", variant);
                    return;
                }
            } catch (Error e) {
                warning("Failed to sync keyboard layout to singularity schema: %s", e.message);
            }
        }
    }
}
