using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AccessibilityPage : SettingsPage {

        // GSettings instances (may be null if schema not installed)
        private GLib.Settings? iface_settings;
        private GLib.Settings? a11y_iface_settings;
        private GLib.Settings? wm_settings;
        private GLib.Settings? a11y_kb_settings;
        private GLib.Settings desktop_settings;

        // Cursor size options: label, value mapping
        private static int[] CURSOR_SIZES = { 24, 32, 48, 64 };
        private static string[] CURSOR_LABELS = { "Small", "Default", "Large", "Extra Large" };

        public AccessibilityPage(SettingsView view) {
            base(_("Accessibility"));
            back_clicked.connect(() => view.go_home());

            iface_settings     = get_settings("org.gnome.desktop.interface");
            a11y_iface_settings = get_settings("org.gnome.desktop.a11y.interface");
            wm_settings        = get_settings("org.gnome.desktop.wm.preferences");
            a11y_kb_settings   = get_settings("org.gnome.desktop.a11y.keyboard");
            desktop_settings   = new GLib.Settings("dev.sinty.desktop");

            var hand_manager = Singularity.HandControlManager.get_default();
            var hand_group = new PreferencesGroup(_("Hands-free control"));
            add_group(hand_group);

            var hand_row = new SwitchRow(
                _("Hand Control"),
                _("Point, click, drag, and scroll with natural hand gestures"));
            hand_row.active = desktop_settings.get_boolean("hand-control-enabled");
            hand_row.sensitive = hand_manager.available;
            hand_row.switch_btn.notify["active"].connect(() => {
                desktop_settings.set_boolean("hand-control-enabled", hand_row.active);
            });
            desktop_settings.changed["hand-control-enabled"].connect(() => {
                bool enabled = desktop_settings.get_boolean("hand-control-enabled");
                if (hand_row.active != enabled) hand_row.active = enabled;
            });
            hand_group.add_row(hand_row);

            var calibrate_row = new ActionRow(
                _("Calibrate Hand Control"),
                _("Map your hand movement across every connected display"),
                "input-touchpad-symbolic");
            calibrate_row.sensitive = hand_manager.available && hand_row.active;
            calibrate_row.activated.connect(() => hand_manager.calibrate());
            hand_row.switch_btn.notify["active"].connect(() => {
                calibrate_row.sensitive = hand_manager.available && hand_row.active;
            });
            hand_manager.availability_changed.connect(() => {
                hand_row.sensitive = hand_manager.available;
                calibrate_row.sensitive = hand_manager.available && hand_row.active;
            });
            hand_group.add_row(calibrate_row);

            // Vision
            var vision_group = new PreferencesGroup(_("Vision"));
            add_group(vision_group);

            // Large Text
            var large_text_row = new SwitchRow(_("Large Text"), _("Increase the font size across the desktop"));
            if (iface_settings != null) {
                large_text_row.active = iface_settings.get_double("text-scaling-factor") >= 1.4;
                large_text_row.switch_btn.notify["active"].connect(() => {
                    iface_settings.set_double("text-scaling-factor",
                        large_text_row.active ? 1.5 : 1.0);
                });
                iface_settings.changed["text-scaling-factor"].connect(() => {
                    bool big = iface_settings.get_double("text-scaling-factor") >= 1.4;
                    if (large_text_row.active != big)
                        large_text_row.active = big;
                });
            } else {
                large_text_row.sensitive = false;
            }
            vision_group.add_row(large_text_row);

            // High Contrast
            var high_contrast_row = new SwitchRow(_("High Contrast"), _("Increase contrast for better visibility"));
            if (a11y_iface_settings != null) {
                high_contrast_row.active = a11y_iface_settings.get_boolean("high-contrast");
                high_contrast_row.switch_btn.notify["active"].connect(() => {
                    a11y_iface_settings.set_boolean("high-contrast", high_contrast_row.active);
                });
                a11y_iface_settings.changed["high-contrast"].connect(() => {
                    bool val = a11y_iface_settings.get_boolean("high-contrast");
                    if (high_contrast_row.active != val)
                        high_contrast_row.active = val;
                });
            } else {
                high_contrast_row.sensitive = false;
            }
            vision_group.add_row(high_contrast_row);

            // Reduce Motion (inverted: enable-animations = false means reduce motion = true)
            var reduce_motion_row = new SwitchRow(_("Reduce Motion"), _("Minimise animations throughout the interface"));
            if (iface_settings != null) {
                reduce_motion_row.active = !iface_settings.get_boolean("enable-animations");
                reduce_motion_row.switch_btn.notify["active"].connect(() => {
                    iface_settings.set_boolean("enable-animations", !reduce_motion_row.active);
                });
                iface_settings.changed["enable-animations"].connect(() => {
                    bool reduced = !iface_settings.get_boolean("enable-animations");
                    if (reduce_motion_row.active != reduced)
                        reduce_motion_row.active = reduced;
                });
            } else {
                reduce_motion_row.sensitive = false;
            }
            vision_group.add_row(reduce_motion_row);

            // Cursor Size
            string cursor_current = CURSOR_LABELS[1]; // Default (32)
            if (iface_settings != null) {
                int current_size = iface_settings.get_int("cursor-size");
                for (int i = 0; i < CURSOR_SIZES.length; i++) {
                    if (CURSOR_SIZES[i] == current_size) { cursor_current = CURSOR_LABELS[i]; break; }
                }
            }
            var cursor_row = new SelectionRow(_("Cursor Size"), CURSOR_LABELS, cursor_current);
            if (iface_settings != null) {
                cursor_row.selected.connect((item) => {
                    for (int i = 0; i < CURSOR_LABELS.length; i++) {
                        if (CURSOR_LABELS[i] == item) {
                            iface_settings.set_int("cursor-size", CURSOR_SIZES[i]);
                            break;
                        }
                    }
                });
                iface_settings.changed["cursor-size"].connect(() => {
                    int sz = iface_settings.get_int("cursor-size");
                    for (int i = 0; i < CURSOR_SIZES.length; i++) {
                        if (CURSOR_SIZES[i] == sz) {
                            cursor_row.current_value = CURSOR_LABELS[i];
                            break;
                        }
                    }
                });
            } else {
                cursor_row.sensitive = false;
            }
            vision_group.add_row(cursor_row);

            // Hearing
            var hearing_group = new PreferencesGroup(_("Hearing"));
            add_group(hearing_group);

            var visual_bell_row = new SwitchRow(_("Visual Bell"), _("Flash the screen instead of playing a sound alert"));
            if (wm_settings != null) {
                visual_bell_row.active = wm_settings.get_boolean("visual-bell");
                visual_bell_row.switch_btn.notify["active"].connect(() => {
                    wm_settings.set_boolean("visual-bell", visual_bell_row.active);
                });
                wm_settings.changed["visual-bell"].connect(() => {
                    bool val = wm_settings.get_boolean("visual-bell");
                    if (visual_bell_row.active != val)
                        visual_bell_row.active = val;
                });
            } else {
                visual_bell_row.sensitive = false;
            }
            hearing_group.add_row(visual_bell_row);

            // Keyboard
            var keyboard_group = new PreferencesGroup(_("Keyboard"));
            add_group(keyboard_group);

            var screen_keyboard_row = new SwitchRow(_("Screen Keyboard"),
                _("Type with an on-screen keyboard with Ctrl, Alt, Super and Shift"));
            var desktop_settings = new GLib.Settings("dev.sinty.desktop");
            screen_keyboard_row.active = desktop_settings.get_boolean("screen-keyboard-enabled");
            desktop_settings.bind("screen-keyboard-enabled", screen_keyboard_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            keyboard_group.add_row(screen_keyboard_row);

            // Sticky Keys
            var sticky_keys_row = new SwitchRow(_("Sticky Keys"), _("Hold modifier keys (Shift, Ctrl…) one at a time instead of simultaneously"));
            bind_a11y_keyboard_switch(sticky_keys_row, "stickykeys-enable");
            keyboard_group.add_row(sticky_keys_row);

            // Slow Keys
            var slow_keys_row = new SwitchRow(_("Slow Keys"), _("Require keys to be held for a moment before they are accepted"));
            bind_a11y_keyboard_switch(slow_keys_row, "slowkeys-enable");
            keyboard_group.add_row(slow_keys_row);

            // Bounce Keys
            var bounce_keys_row = new SwitchRow(_("Bounce Keys"), _("Ignore rapid repeated keypresses of the same key"));
            bind_a11y_keyboard_switch(bounce_keys_row, "bouncekeys-enable");
            keyboard_group.add_row(bounce_keys_row);

            // Mouse & Pointer
            var mouse_group = new PreferencesGroup(_("Mouse & Pointer"));
            add_group(mouse_group);

            var mouse_keys_row = new SwitchRow(_("Mouse Keys"), _("Control the mouse pointer using the numeric keypad"));
            bind_a11y_keyboard_switch(mouse_keys_row, "mousekeys-enable");
            mouse_group.add_row(mouse_keys_row);
        }

        // Helper: bind a SwitchRow to a boolean key in org.gnome.desktop.a11y.keyboard
        private void bind_a11y_keyboard_switch(SwitchRow row, string key) {
            if (a11y_kb_settings == null) {
                row.sensitive = false;
                return;
            }
            row.active = a11y_kb_settings.get_boolean(key);
            row.switch_btn.notify["active"].connect(() => {
                a11y_kb_settings.set_boolean(key, row.active);
            });
            a11y_kb_settings.changed[key].connect(() => {
                bool val = a11y_kb_settings.get_boolean(key);
                if (row.active != val)
                    row.active = val;
            });
        }

        // Returns a GLib.Settings instance only if the schema is installed.
        private GLib.Settings? get_settings(string schema) {
            var src = GLib.SettingsSchemaSource.get_default();
            if (src == null || src.lookup(schema, true) == null) return null;
            return new GLib.Settings(schema);
        }
    }
}
