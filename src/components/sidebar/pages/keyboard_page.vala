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

        private SettingsView view;

        public KeyboardPage(SettingsView view) {
            base(_("Keyboard"));
            this.view = view;
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
            manager.custom_keybindings_changed.connect(() => rebuild_shortcuts());

            input_group = new PreferencesGroup(_("Input Sources"),
                _("Choose the keyboard layouts available in the desktop"));
            add_group(input_group);
            refresh_input_sources(view);

            var settings = new GLib.Settings("dev.sinty.desktop");
            var languages_group = new PreferencesGroup(_("Input Methods and Dictation"));
            languages_group.add_row(Singularity.SidebarPages.InputMethodsPage.entry_row(view));
            languages_group.add_row(Singularity.SidebarPages.DictationPage.entry_row(view));
            var all_apps_row = new SwitchRow(_("Check Spelling in All Apps"),
                _("Suggest corrections near the cursor in other apps too. Press Tab to take one. Words are not underlined there."),
                settings.get_boolean("spell-check-all-apps"));
            settings.bind("spell-check-all-apps", all_apps_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            languages_group.add_row(all_apps_row);
            add_group(languages_group);
            var typing_group = new PreferencesGroup(_("Typing"));
            var spell_row = new SwitchRow(_("Check Spelling"),
                _("Underline misspelled words and suggest corrections"),
                settings.get_boolean("spell-check-enabled"));
            settings.bind("spell-check-enabled", spell_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            typing_group.add_row(spell_row);
            var autocorrect_row = new SwitchRow(_("Correct Spelling Automatically"),
                _("Fix misspelled words on Space, press Backspace to undo"),
                settings.get_boolean("spell-autocorrect"));
            settings.bind("spell-autocorrect", autocorrect_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            typing_group.add_row(autocorrect_row);
            var suggestions_row = new SwitchRow(_("Show Suggestions"),
                _("Offer corrections under the word or above the screen keyboard"),
                settings.get_boolean("spell-suggestions"));
            settings.bind("spell-suggestions", suggestions_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            typing_group.add_row(suggestions_row);
            var accents_row = new SwitchRow(_("Hold Keys for Accents"),
                _("Hold a letter to pick an accented variant instead of repeating it"),
                settings.get_boolean("press-hold-accents"));
            settings.bind("press-hold-accents", accents_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            typing_group.add_row(accents_row);
            if (settings.settings_schema.has_key("shortcut-cheatsheet-hold")) {
                var cheatsheet_row = new SwitchRow(_("Hold Super for Shortcuts"),
                    _("Hold the Super key to see the shortcuts of the desktop and of the focused app"),
                    settings.get_boolean("shortcut-cheatsheet-hold"));
                settings.bind("shortcut-cheatsheet-hold", cheatsheet_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
                typing_group.add_row(cheatsheet_row);
            }
            typing_group.add_row(Singularity.SidebarPages.ClipboardSettingsPage.entry_row(view));
            add_group(typing_group);

            var pointer_group = new PreferencesGroup(_("Mouse & Touchpad"));
            var accel_row = new SwitchRow(_("Mouse Acceleration"),
                _("Turn off for a flat 1:1 pointer profile"),
                settings.get_boolean("mouse-acceleration"));
            settings.bind("mouse-acceleration", accel_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            pointer_group.add_row(accel_row);

            var two_finger_row = new SwitchRow(_("Two-Finger Scrolling"),
                _("Scroll with two fingers anywhere on the touchpad"),
                settings.get_boolean("touchpad-two-finger-scroll"));
            settings.bind("touchpad-two-finger-scroll", two_finger_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            pointer_group.add_row(two_finger_row);

            var natural_row = new SwitchRow(_("Natural Scrolling"),
                _("Reverse the two-finger scroll direction"),
                settings.get_boolean("natural-scrolling"));
            settings.bind("natural-scrolling", natural_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            settings.bind("touchpad-two-finger-scroll", natural_row, "visible", SettingsBindFlags.GET);
            pointer_group.add_row(natural_row);

            var edge_row = new SwitchRow(_("Edge Scrolling"),
                _("Scroll with one finger along the right or bottom edge"),
                settings.get_boolean("touchpad-edge-scroll"));
            settings.bind("touchpad-edge-scroll", edge_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            pointer_group.add_row(edge_row);

            var edge_natural_row = new SwitchRow(_("Natural Edge Scrolling"),
                _("Reverse the edge scroll direction"),
                settings.get_boolean("touchpad-edge-natural-scroll"));
            settings.bind("touchpad-edge-natural-scroll", edge_natural_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            settings.bind("touchpad-edge-scroll", edge_natural_row, "visible", SettingsBindFlags.GET);
            pointer_group.add_row(edge_natural_row);

            var circular_row = new SwitchRow(_("Circular Scrolling"),
                _("Start on an edge, then keep scrolling by moving in a circle"),
                settings.get_boolean("touchpad-circular-scroll"));
            settings.bind("touchpad-circular-scroll", circular_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            settings.bind("touchpad-edge-scroll", circular_row, "visible", SettingsBindFlags.GET);
            pointer_group.add_row(circular_row);

            pointer_group.add_row(scroll_speed_row(settings, "touchpad-scroll-speed",
                _("Touchpad Scroll Speed"), _("How far content moves as your fingers scroll")));
            pointer_group.add_row(scroll_speed_row(settings, "mouse-scroll-speed",
                _("Mouse Scroll Speed"), _("How far content moves for each wheel step")));
            add_group(pointer_group);

            var gesture_group = new PreferencesGroup(_("Touchpad Gestures"),
                _("Swipe left or right to change workspace, down for the workspace overview and up for the launcher."));
            var gestures_row = new SwitchRow(_("Gestures"),
                _("Turn off to leave every multi-finger swipe to applications"),
                settings.get_boolean("gestures-enabled"));
            settings.bind("gestures-enabled", gestures_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            gesture_group.add_row(gestures_row);

            var fingers_row = choice_row(settings, "gesture-fingers", _("Fingers"),
                { "3", "4", "both" }, { _("Three"), _("Four"), _("Three or Four") });
            settings.bind("gestures-enabled", fingers_row, "visible", SettingsBindFlags.GET);
            gesture_group.add_row(fingers_row);

            var direction_row = choice_row(settings, "gesture-direction", _("Direction"),
                { "natural", "inverted", "follow-scroll" },
                { _("Content Follows Fingers"), _("Inverted"), _("Same as Scrolling") });
            settings.bind("gestures-enabled", direction_row, "visible", SettingsBindFlags.GET);
            gesture_group.add_row(direction_row);

            var two_d_row = new SwitchRow(_("Change Direction Mid-Swipe"),
                _("Switch workspace and open the overview, or move between workspaces in the overview, in one swipe"),
                settings.get_boolean("gesture-two-dimensional"));
            settings.bind("gesture-two-dimensional", two_d_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            settings.bind("gestures-enabled", two_d_row, "visible", SettingsBindFlags.GET);
            gesture_group.add_row(two_d_row);

            var sensitivity_row = scale_row(settings, "gesture-sensitivity", _("Sensitivity"),
                _("Higher values need a shorter swipe for each step"), 50, 200, 100);
            settings.bind("gestures-enabled", sensitivity_row, "visible", SettingsBindFlags.GET);
            gesture_group.add_row(sensitivity_row);

            var threshold_row = scale_row(settings, "gesture-threshold", _("Direction Delay"),
                _("How far the fingers move before a gesture picks its first direction"), 8, 32, 1);
            settings.bind("gestures-enabled", threshold_row, "visible", SettingsBindFlags.GET);
            gesture_group.add_row(threshold_row);
            add_group(gesture_group);
        }

        private SelectionRow choice_row(GLib.Settings settings, string key, string title, string[] ids, string[] labels) {
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            for (int i = 0; i < ids.length; i++) {
                var option = new Singularity.Core.AppSettingOption();
                option.id = ids[i];
                option.label = labels[i];
                options.add(option);
            }
            var row = new SelectionRow.with_options(title, options, settings.get_string(key));
            row.selected.connect((id) => settings.set_string(key, id));
            settings.changed[key].connect(() => row.current_value = settings.get_string(key));
            return row;
        }

        private ActionRow scale_row(GLib.Settings settings, string key, string title, string subtitle,
                double min, double max, double factor) {
            var row = new ActionRow(title, subtitle);
            row.activatable = false;
            var scale = new Scale.with_range(Orientation.HORIZONTAL, min, max, factor >= 100 ? 5 : 1);
            scale.width_request = 170;
            scale.draw_value = true;
            scale.value_pos = PositionType.RIGHT;
            if (factor >= 100) {
                scale.add_mark(100, PositionType.BOTTOM, null);
                scale.set_format_value_func((s, value) => "%.0f%%".printf(value));
            } else {
                scale.set_format_value_func((s, value) => "%.0f".printf(value));
            }
            scale.set_value(settings.get_double(key) * (factor >= 100 ? 100 : 1));
            uint timeout = 0;
            scale.value_changed.connect(() => {
                if (timeout != 0) Source.remove(timeout);
                timeout = Timeout.add(200, () => {
                    timeout = 0;
                    settings.set_double(key, scale.get_value() / (factor >= 100 ? 100 : 1));
                    return Source.REMOVE;
                });
            });
            row.add_suffix(scale);
            return row;
        }

        private ActionRow scroll_speed_row(GLib.Settings settings, string key, string title, string subtitle) {
            var row = new ActionRow(title, subtitle);
            row.activatable = false;
            var scale = new Scale.with_range(Orientation.HORIZONTAL, 25, 175, 5);
            scale.width_request = 170;
            scale.draw_value = true;
            scale.value_pos = PositionType.RIGHT;
            scale.add_mark(100, PositionType.BOTTOM, null);
            scale.set_format_value_func((s, value) => "%.0f%%".printf(value));
            scale.set_value(settings.get_double(key) * 100);
            uint timeout = 0;
            scale.value_changed.connect(() => {
                if (timeout != 0) Source.remove(timeout);
                timeout = Timeout.add(200, () => {
                    timeout = 0;
                    settings.set_double(key, scale.get_value() / 100);
                    return Source.REMOVE;
                });
            });
            row.add_suffix(scale);
            return row;
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

            var custom = add_section(_("Custom"), _("Your own shortcuts for commands and app actions"));
            foreach (var keybinding in manager.custom_keybindings)
                add_custom_shortcut(custom, keybinding);
            var add_row = new ActionRow(_("Add Shortcut"),
                _("Run a command or an app action with a key combination"), "list-add-symbolic");
            add_row.activated.connect(() => open_custom_editor(null));
            custom.group.add_row(add_row);
            custom.items.append(new ShortcutItem(add_row, "%s custom".printf(_("Add Shortcut")).down()));

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

        private void add_custom_shortcut(ShortcutSection section, CustomKeybinding keybinding) {
            string subtitle;
            GLib.Icon? icon = null;
            if (keybinding.is_app_action) {
                var info = keybinding.app_info();
                if (info == null) {
                    if (keybinding.accelerator == "") return;
                    subtitle = _("%s is not installed").printf(keybinding.app_id);
                } else {
                    subtitle = "%s, %s".printf(info.get_display_name(), info.get_action_name(keybinding.action));
                    icon = info.get_icon();
                }
            } else {
                subtitle = keybinding.command;
            }
            var row = new ActionRow(keybinding.name, subtitle, icon == null ? "system-run-symbolic" : null);
            if (icon != null) {
                var image = new Image.from_gicon(icon);
                image.pixel_size = 24;
                row.add_prefix(image);
            }
            row.activatable = false;

            var edit_btn = new Button.from_icon_name("document-edit-symbolic");
            edit_btn.add_css_class("flat");
            edit_btn.tooltip_text = _("Edit");
            edit_btn.valign = Align.CENTER;
            edit_btn.clicked.connect(() => open_custom_editor(keybinding));
            row.add_suffix(edit_btn);

            var remove_btn = new Button.from_icon_name("user-trash-symbolic");
            remove_btn.add_css_class("flat");
            remove_btn.tooltip_text = _("Remove");
            remove_btn.valign = Align.CENTER;
            string id = keybinding.id;
            remove_btn.clicked.connect(() => {
                row.confirmation_requested(_("Remove"), _("Cancel"), ConfirmationSuggestedAction.CANCEL);
            });
            row.confirmed.connect(() => manager.remove_custom_keybinding(id));
            row.add_suffix(remove_btn);

            var shortcut_label = new ShortcutLabel(keybinding.accelerator);
            shortcut_label.disabled_text = _("Disabled");
            var key_btn = new Button();
            key_btn.has_frame = false;
            key_btn.add_css_class("flat");
            key_btn.tooltip_text = _("Change Shortcut");
            key_btn.set_child(shortcut_label);
            string name = keybinding.name;
            string accel = keybinding.accelerator;
            key_btn.clicked.connect(() => show_capture_dialog(name, "system-run-symbolic", accel,
                (new_accel) => manager.set_custom_keybinding_accelerator(id, new_accel)));
            row.add_suffix(key_btn);

            section.group.add_row(row);
            section.items.append(new ShortcutItem(row,
                "%s %s %s custom".printf(keybinding.name, subtitle, keybinding.accelerator).down()));
        }

        private void open_custom_editor(CustomKeybinding? keybinding) {
            view.open_subpage(new Singularity.SidebarPages.CustomShortcutPage(view, manager, keybinding),
                "custom-shortcut");
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
                case "toggle_clipboard_history": return "edit-paste-symbolic";
                case "toggle_dictation": return "audio-input-microphone-symbolic";
                case "switch_input_method": return "input-keyboard-symbolic";
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

        private delegate void AcceleratorChosen(string accelerator);

        private void show_edit_dialog(Shortcut shortcut) {
            string id = shortcut.id;
            show_capture_dialog(_(shortcut.name), icon_for_action(shortcut.action_name), shortcut.accelerator,
                (accel) => manager.update_shortcut(id, accel));
        }

        private void show_capture_dialog(string name, string icon_name, string accelerator,
                                         owned AcceleratorChosen chosen) {
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

            var icon = new Image.from_icon_name(icon_name);
            icon.pixel_size = 48;
            content.append(icon);

            var title = new Label(name);
            title.add_css_class("title-1");
            title.wrap = true;
            title.justify = Justification.CENTER;
            content.append(title);

            var hint = new Label(_("Press the new key combination"));
            hint.add_css_class("dim-label");
            content.append(hint);

            var current = new ShortcutLabel(accelerator);
            current.disabled_text = _("Disabled");
            current.halign = Align.CENTER;
            content.append(current);

            var actions = new Box(Orientation.HORIZONTAL, 8);
            actions.halign = Align.CENTER;
            var disable_btn = new Button.with_label(_("Disable"));
            disable_btn.add_css_class("flat");
            disable_btn.clicked.connect(() => {
                chosen("");
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
                    chosen(accel);
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
