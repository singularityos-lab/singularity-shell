using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AccessibilityPage : SettingsPage {

        // GSettings instances (may be null if schema not installed)
        private GLib.Settings? iface_settings;
        private GLib.Settings? a11y_iface_settings;
        private GLib.Settings? wm_settings;
        private GLib.Settings? a11y_kb_settings;
        private GLib.Settings? a11y_mouse_settings;
        private GLib.Settings? magnifier_settings;
        private GLib.Settings? applications_settings;
        private GLib.Settings? keyboard_settings;
        private GLib.Settings? mouse_settings;
        private GLib.Settings? sound_settings;
        private GLib.Settings desktop_settings;

        // Cursor size options: label, value mapping
        private static int[] CURSOR_SIZES = { 24, 32, 48, 64 };
        private static string[] CURSOR_LABELS = { "Default", "Medium", "Large", "Extra Large" };

        private SettingsSubpages subpages;
        private ActionRow reader_link;

        public AccessibilityPage(SettingsView view) {
            base(_("Accessibility"));
            back_clicked.connect(() => view.go_home());

            iface_settings     = get_settings("org.gnome.desktop.interface");
            a11y_iface_settings = get_settings("org.gnome.desktop.a11y.interface");
            wm_settings        = get_settings("org.gnome.desktop.wm.preferences");
            a11y_kb_settings   = get_settings("org.gnome.desktop.a11y.keyboard");
            a11y_mouse_settings = get_settings("org.gnome.desktop.a11y.mouse");
            magnifier_settings = get_settings("org.gnome.desktop.a11y.magnifier");
            applications_settings = get_settings("org.gnome.desktop.a11y.applications");
            keyboard_settings  = get_settings("org.gnome.desktop.peripherals.keyboard");
            mouse_settings     = get_settings("org.gnome.desktop.peripherals.mouse");
            sound_settings     = get_settings("org.gnome.desktop.sound");
            desktop_settings   = new GLib.Settings("dev.sinty.desktop");
            subpages = new SettingsSubpages(view, this, "accessibility");

            var general_group = new PreferencesGroup(_("General"));
            add_group(general_group);
            var menu_row = new SwitchRow(_("Always Show Accessibility Menu"),
                _("Show the accessibility menu in the top bar"));
            bind_switch(menu_row, desktop_settings, "accessibility-menu");
            general_group.add_row(menu_row);
            var keyboard_enable_row = new SwitchRow(_("Enable by Keyboard"),
                _("Press Shift five times for sticky keys, hold it for slow keys"));
            bind_switch(keyboard_enable_row, a11y_kb_settings, "enable");
            general_group.add_row(keyboard_enable_row);

            var vision_group = new PreferencesGroup(_("Vision"));
            add_group(vision_group);
            var reader_page = new ScreenReaderPage(view, applications_settings);
            reader_link = subpages.link(_("Screen Reader"), "", "preferences-desktop-accessibility-symbolic",
                reader_page, "accessibility-screen-reader");
            vision_group.add_row(reader_link);
            update_reader_subtitle();
            if (has_key(applications_settings, "screen-reader-enabled"))
                applications_settings.changed["screen-reader-enabled"].connect(update_reader_subtitle);
            vision_group.add_row(subpages.link(_("Seeing"), _("Contrast, motion, text size, cursor and color filters"),
                "display-brightness-symbolic", build_seeing_page(), "accessibility-seeing"));
            vision_group.add_row(subpages.link(_("Zoom"), _("Magnify the screen around the pointer"),
                "zoom-in-symbolic", build_zoom_page(), "accessibility-zoom"));

            var input_group = new PreferencesGroup(_("Hearing and Input"));
            add_group(input_group);
            input_group.add_row(subpages.link(_("Hearing"), _("Visual alerts, sound keys and mono audio"),
                "audio-volume-high-symbolic", build_hearing_page(), "accessibility-hearing"));
            input_group.add_row(subpages.link(_("Typing"), _("Screen keyboard, repeat, sticky, slow and bounce keys"),
                "input-keyboard-symbolic", build_typing_page(), "accessibility-typing"));
            input_group.add_row(subpages.link(_("Pointing and Clicking"), _("Mouse keys, hover click and double-click delay"),
                "input-mouse-symbolic", build_pointing_page(), "accessibility-pointing"));
            input_group.add_row(subpages.link(_("Hands-free Control"), _("Control the pointer with hand gestures"),
                "input-touchpad-symbolic", build_hands_page(), "accessibility-hands"));
        }

        private void update_reader_subtitle() {
            if (Singularity.Accessibility.ScreenReaderSettings.detect().kind == Singularity.Accessibility.ScreenReaderBackendKind.NONE
                    && !Singularity.Accessibility.AccessibilityManager.screen_reader_available()) {
                reader_link.subtitle = _("Not installed");
            } else if (has_key(applications_settings, "screen-reader-enabled")
                    && applications_settings.get_boolean("screen-reader-enabled")) {
                reader_link.subtitle = _("On");
            } else {
                reader_link.subtitle = _("Off");
            }
        }

        private SettingsPage build_hands_page() {
            var page = subpages.create(_("Hands-free Control"));
            var hand_manager = Singularity.HandControlManager.get_default();
            var hand_group = new PreferencesGroup(_("Hand Control"));
            page.add_group(hand_group);

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
            return page;
        }

        private SettingsPage build_seeing_page() {
            var page = subpages.create(_("Seeing"));
            var display_group = new PreferencesGroup(_("Display"));
            page.add_group(display_group);

            var high_contrast_row = new SwitchRow(_("High Contrast"),
                _("Increase the contrast of text and controls"));
            bind_switch(high_contrast_row, a11y_iface_settings, "high-contrast");
            display_group.add_row(high_contrast_row);

            var shapes_row = new SwitchRow(_("On and Off Shapes"),
                _("Show shapes on switches as well as colors"));
            bind_switch(shapes_row, a11y_iface_settings, "show-status-shapes");
            display_group.add_row(shapes_row);

            var motion = Singularity.Motion.get_default();
            var reduce_motion_row = new SwitchRow(_("Reduced Motion"),
                _("Replace movement and zoom with short fades"));
            reduce_motion_row.active = motion.is_reduced();
            reduce_motion_row.switch_btn.notify["active"].connect(() => {
                if (motion.is_reduced() != reduce_motion_row.active) motion.set_reduced(reduce_motion_row.active);
            });
            motion.changed.connect(() => {
                if (reduce_motion_row.active != motion.is_reduced()) reduce_motion_row.active = motion.is_reduced();
            });
            display_group.add_row(reduce_motion_row);

            var scrollbars_row = new SwitchRow(_("Always Show Scrollbars"),
                _("Keep scrollbars visible instead of showing them on scroll"));
            bind_switch(scrollbars_row, iface_settings, "overlay-scrolling", true);
            display_group.add_row(scrollbars_row);

            var focus_row = new SwitchRow(_("Always Show Keyboard Focus"),
                _("Keep the focus ring visible after using the mouse"));
            bind_switch(focus_row, desktop_settings, "always-show-focus");
            display_group.add_row(focus_row);

            var size_group = new PreferencesGroup(_("Size"));
            page.add_group(size_group);

            var densities = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            densities.add(new Singularity.Core.AppSettingOption() { id = "compact", label = _("Compact") });
            densities.add(new Singularity.Core.AppSettingOption() { id = "medium", label = _("Medium") });
            densities.add(new Singularity.Core.AppSettingOption() { id = "large", label = _("Large") });
            bool has_density = desktop_settings.settings_schema.has_key("interface-density");
            var density_row = new SelectionRow.with_options(_("Interface Density"), densities,
                has_density ? desktop_settings.get_string("interface-density") : "compact");
            density_row.subtitle = _("Size of rows, groups and pages in Settings and apps");
            density_row.sensitive = has_density;
            density_row.selected.connect((id) => {
                if (has_density) desktop_settings.set_string("interface-density", id);
            });
            if (has_density) {
                desktop_settings.changed["interface-density"].connect(() => {
                    density_row.current_value = desktop_settings.get_string("interface-density");
                });
            }
            size_group.add_row(density_row);

            string[] text_labels = { "100%", "110%", "125%", "150%", "175%", "200%" };
            double[] text_values = { 1.0, 1.1, 1.25, 1.5, 1.75, 2.0 };
            string text_current = text_labels[0];
            if (has_key(iface_settings, "text-scaling-factor")) {
                double factor = iface_settings.get_double("text-scaling-factor");
                for (int i = 0; i < text_values.length; i++) {
                    if ((text_values[i] - factor).abs() < 0.02) text_current = text_labels[i];
                }
            }
            var text_row = new SelectionRow(_("Text Size"), text_labels, text_current);
            if (has_key(iface_settings, "text-scaling-factor")) {
                text_row.selected.connect((item) => {
                    for (int i = 0; i < text_labels.length; i++) {
                        if (text_labels[i] == item) iface_settings.set_double("text-scaling-factor", text_values[i]);
                    }
                });
            } else {
                text_row.sensitive = false;
            }
            size_group.add_row(text_row);

            string cursor_current = CURSOR_LABELS[0];
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
            size_group.add_row(cursor_row);

            var filter_group = new PreferencesGroup(_("Color Filters"));
            page.add_group(filter_group);
            string[] filter_ids = { "none", "invert", "grayscale", "deuteranopia", "protanopia", "tritanopia" };
            string[] filter_labels = { _("None"), _("Inverted Colors"), _("Grayscale"),
                _("Green Weak (Deuteranopia)"), _("Red Weak (Protanopia)"), _("Blue Weak (Tritanopia)") };
            filter_group.add_row(bind_choice(_("Filter"), desktop_settings, "color-filter", filter_ids, filter_labels));
            return page;
        }

        private SettingsPage build_zoom_page() {
            var page = subpages.create(_("Zoom"));
            var zoom_group = new PreferencesGroup(_("Magnifier"));
            page.add_group(zoom_group);
            var zoom_row = new SwitchRow(_("Desktop Zoom"),
                _("Magnify the screen around the pointer, Super+Alt+8 turns it on or off"));
            bind_switch(zoom_row, applications_settings, "screen-magnifier-enabled");
            zoom_group.add_row(zoom_row);
            var factor_row = bind_spin_double(_("Magnification"), null, magnifier_settings, "mag-factor", 1.25, 20, 0.25);
            zoom_group.add_row(factor_row);
            string[] follow_ids = { "centered", "proportional", "push" };
            string[] follow_labels = { _("Keep the pointer centered"), _("Move with the pointer"), _("Push at the edges") };
            var follow_row = bind_choice(_("Follow the Pointer"), magnifier_settings, "mouse-tracking", follow_ids, follow_labels);
            zoom_group.add_row(follow_row);
            var crosshair_row = new SwitchRow(_("Crosshairs"), _("Mark the pointer with lines across the magnified view"));
            bind_switch(crosshair_row, magnifier_settings, "show-cross-hairs");
            zoom_group.add_row(crosshair_row);
            var invert_zoom_row = new SwitchRow(_("Invert Colors in the Magnifier"), null);
            bind_switch(invert_zoom_row, magnifier_settings, "invert-lightness");
            zoom_group.add_row(invert_zoom_row);
            show_with(zoom_row, { factor_row, follow_row, crosshair_row, invert_zoom_row });
            return page;
        }

        private SettingsPage build_hearing_page() {
            var page = subpages.create(_("Hearing"));
            var alerts_group = new PreferencesGroup(_("Alerts"));
            page.add_group(alerts_group);

            var visual_bell_row = new SwitchRow(_("Visual Alerts"), _("Flash the screen or the window when an alert sound plays"));
            bind_switch(visual_bell_row, wm_settings, "visual-bell");
            alerts_group.add_row(visual_bell_row);
            string[] flash_ids = { "frame-flash", "fullscreen-flash" };
            string[] flash_labels = { _("Flash the Window"), _("Flash the Whole Screen") };
            var flash_row = bind_choice(_("Flash Area"), wm_settings, "visual-bell-type", flash_ids, flash_labels);
            alerts_group.add_row(flash_row);
            show_with(visual_bell_row, { flash_row });

            var sound_keys_row = new SwitchRow(_("Sound Keys"),
                _("Beep when Caps Lock or Num Lock is turned on or off"));
            bind_switch(sound_keys_row, a11y_kb_settings, "togglekeys-enable");
            alerts_group.add_row(sound_keys_row);

            var audio_group = new PreferencesGroup(_("Audio"));
            page.add_group(audio_group);
            var overamp_row = new SwitchRow(_("Overamplification"),
                _("Allow the volume to go above 100%, with some loss of quality"));
            bind_switch(overamp_row, sound_settings, "allow-volume-above-100-percent");
            audio_group.add_row(overamp_row);

            var mono_row = new SwitchRow(_("Mono Audio"),
                _("Play the same sound on the left and right speakers"),
                desktop_settings.get_boolean("mono-audio"));
            desktop_settings.bind("mono-audio", mono_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            audio_group.add_row(mono_row);
            return page;
        }

        private SettingsPage build_typing_page() {
            var page = subpages.create(_("Typing"));
            var keys_group = new PreferencesGroup(_("Keyboard"));
            page.add_group(keys_group);

            var screen_keyboard_row = new SwitchRow(_("Screen Keyboard"),
                _("Type with an on-screen keyboard with Ctrl, Alt, Super and Shift"));
            screen_keyboard_row.active = desktop_settings.get_boolean("screen-keyboard-enabled");
            desktop_settings.bind("screen-keyboard-enabled", screen_keyboard_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            keys_group.add_row(screen_keyboard_row);

            var repeat_row = new SwitchRow(_("Repeat Keys"), _("Repeat a key while it is held down"));
            bind_switch(repeat_row, keyboard_settings, "repeat");
            keys_group.add_row(repeat_row);
            var delay_row = bind_spin_uint(_("Repeat Delay"), _("Milliseconds before a held key repeats"), keyboard_settings, "delay", 100, 2000, 50);
            keys_group.add_row(delay_row);
            var interval_row = bind_spin_uint(_("Repeat Interval"), _("Milliseconds between repeats"), keyboard_settings, "repeat-interval", 10, 200, 5);
            keys_group.add_row(interval_row);
            show_with(repeat_row, { delay_row, interval_row });

            var cursor_group = new PreferencesGroup(_("Text Cursor"));
            page.add_group(cursor_group);
            var blink_row = new SwitchRow(_("Cursor Blinking"), _("Let the text cursor blink in text fields"));
            bind_switch(blink_row, iface_settings, "cursor-blink");
            cursor_group.add_row(blink_row);
            var blink_time_row = bind_spin_int(_("Blink Speed"), _("Milliseconds for one blink"), iface_settings, "cursor-blink-time", 100, 2500, 100);
            cursor_group.add_row(blink_time_row);
            show_with(blink_row, { blink_time_row });

            var assist_group = new PreferencesGroup(_("Typing Assistance"));
            page.add_group(assist_group);
            var sticky_keys_row = new SwitchRow(_("Sticky Keys"), _("Press Shift, Ctrl, Alt or Super one at a time for shortcuts"));
            bind_switch(sticky_keys_row, a11y_kb_settings, "stickykeys-enable");
            assist_group.add_row(sticky_keys_row);
            var sticky_off_row = new SwitchRow(_("Turn Off When Two Keys Are Pressed Together"), null);
            bind_switch(sticky_off_row, a11y_kb_settings, "stickykeys-two-key-off");
            assist_group.add_row(sticky_off_row);
            var sticky_beep_row = new SwitchRow(_("Beep When a Modifier Is Pressed"), null);
            bind_switch(sticky_beep_row, a11y_kb_settings, "stickykeys-modifier-beep");
            assist_group.add_row(sticky_beep_row);
            show_with(sticky_keys_row, { sticky_off_row, sticky_beep_row });

            var slow_keys_row = new SwitchRow(_("Slow Keys"), _("Accept a key only after it is held for a moment"));
            bind_switch(slow_keys_row, a11y_kb_settings, "slowkeys-enable");
            assist_group.add_row(slow_keys_row);
            var slow_delay_row = bind_spin_int(_("Acceptance Delay"), _("Milliseconds a key must be held"), a11y_kb_settings, "slowkeys-delay", 50, 2000, 50);
            assist_group.add_row(slow_delay_row);
            show_with(slow_keys_row, { slow_delay_row });

            var bounce_keys_row = new SwitchRow(_("Bounce Keys"), _("Ignore a key pressed again too quickly"));
            bind_switch(bounce_keys_row, a11y_kb_settings, "bouncekeys-enable");
            assist_group.add_row(bounce_keys_row);
            var bounce_delay_row = bind_spin_int(_("Acceptance Delay"), _("Milliseconds before the same key counts again"), a11y_kb_settings, "bouncekeys-delay", 50, 2000, 50);
            assist_group.add_row(bounce_delay_row);
            show_with(bounce_keys_row, { bounce_delay_row });
            return page;
        }

        private SettingsPage build_pointing_page() {
            var page = subpages.create(_("Pointing and Clicking"));
            var pointer_group = new PreferencesGroup(_("Pointer"));
            page.add_group(pointer_group);

            var mouse_keys_row = new SwitchRow(_("Mouse Keys"), _("Move and click the pointer with the numeric keypad"));
            bind_switch(mouse_keys_row, a11y_kb_settings, "mousekeys-enable");
            pointer_group.add_row(mouse_keys_row);

            var locate_row = new SwitchRow(_("Locate Pointer"), _("Show where the pointer is when you press Ctrl"));
            bind_switch(locate_row, iface_settings, "locate-pointer");
            pointer_group.add_row(locate_row);

            var hover_focus_row = new SwitchRow(_("Activate Windows on Hover"), _("Focus a window when the pointer rests on it"));
            if (has_key(wm_settings, "focus-mode")) {
                hover_focus_row.active = wm_settings.get_string("focus-mode") != "click";
                hover_focus_row.switch_btn.notify["active"].connect(() => {
                    wm_settings.set_string("focus-mode", hover_focus_row.active ? "sloppy" : "click");
                });
                wm_settings.changed["focus-mode"].connect(() => {
                    bool hover = wm_settings.get_string("focus-mode") != "click";
                    if (hover_focus_row.active != hover) hover_focus_row.active = hover;
                });
            } else {
                hover_focus_row.sensitive = false;
            }
            pointer_group.add_row(hover_focus_row);

            pointer_group.add_row(bind_spin_int(_("Double-Click Delay"), _("Milliseconds allowed between two clicks"), mouse_settings, "double-click", 100, 1000, 50));

            var click_group = new PreferencesGroup(_("Click Assistance"));
            page.add_group(click_group);
            var secondary_row = new SwitchRow(_("Simulated Secondary Click"), _("Hold the main button to right-click"));
            bind_switch(secondary_row, a11y_mouse_settings, "secondary-click-enabled");
            click_group.add_row(secondary_row);
            var secondary_time_row = bind_spin_double(_("Hold Time"), _("Seconds to hold the button"), a11y_mouse_settings, "secondary-click-time", 0.5, 3.0, 0.1);
            click_group.add_row(secondary_time_row);
            show_with(secondary_row, { secondary_time_row });

            var dwell_row = new SwitchRow(_("Hover Click"), _("Click when the pointer stays still for a moment"));
            bind_switch(dwell_row, a11y_mouse_settings, "dwell-click-enabled");
            click_group.add_row(dwell_row);
            var dwell_time_row = bind_spin_double(_("Delay"), _("Seconds the pointer must rest"), a11y_mouse_settings, "dwell-time", 0.2, 3.0, 0.1);
            click_group.add_row(dwell_time_row);
            var dwell_threshold_row = bind_spin_int(_("Motion Threshold"), _("Pixels the pointer may move while resting"), a11y_mouse_settings, "dwell-threshold", 0, 30, 1);
            click_group.add_row(dwell_threshold_row);
            show_with(dwell_row, { dwell_time_row, dwell_threshold_row });
            return page;
        }

        private static bool has_key(GLib.Settings? settings, string key) {
            return settings != null && settings.settings_schema.has_key(key);
        }

        private void bind_switch(SwitchRow row, GLib.Settings? settings, string key, bool invert = false) {
            if (!has_key(settings, key)) {
                row.sensitive = false;
                return;
            }
            row.active = settings.get_boolean(key) != invert;
            row.switch_btn.notify["active"].connect(() => {
                if (settings.get_boolean(key) != (row.active != invert))
                    settings.set_boolean(key, row.active != invert);
            });
            settings.changed[key].connect(() => {
                bool val = settings.get_boolean(key) != invert;
                if (row.active != val) row.active = val;
            });
        }

        private void show_with(SwitchRow parent, owned Widget[] children) {
            foreach (var child in children) child.visible = parent.active;
            parent.switch_btn.notify["active"].connect(() => {
                foreach (var child in children) child.visible = parent.active;
            });
        }

        private SpinRow bind_spin_int(string title, string? subtitle, GLib.Settings? settings, string key, int min, int max, int step) {
            int current = has_key(settings, key) ? settings.get_int(key) : min;
            var row = new SpinRow(title, subtitle, min, max, step, current);
            if (!has_key(settings, key)) {
                row.sensitive = false;
                return row;
            }
            row.spin_btn.value_changed.connect(() => {
                int val = (int) row.spin_btn.get_value();
                if (settings.get_int(key) != val) settings.set_int(key, val);
            });
            settings.changed[key].connect(() => row.spin_btn.set_value(settings.get_int(key)));
            return row;
        }

        private SpinRow bind_spin_uint(string title, string? subtitle, GLib.Settings? settings, string key, uint min, uint max, uint step) {
            uint current = has_key(settings, key) ? settings.get_uint(key) : min;
            var row = new SpinRow(title, subtitle, min, max, step, current);
            if (!has_key(settings, key)) {
                row.sensitive = false;
                return row;
            }
            row.spin_btn.value_changed.connect(() => {
                uint val = (uint) row.spin_btn.get_value();
                if (settings.get_uint(key) != val) settings.set_uint(key, val);
            });
            settings.changed[key].connect(() => row.spin_btn.set_value(settings.get_uint(key)));
            return row;
        }

        private SpinRow bind_spin_double(string title, string? subtitle, GLib.Settings? settings, string key, double min, double max, double step) {
            double current = has_key(settings, key) ? settings.get_double(key) : min;
            var row = new SpinRow(title, subtitle, min, max, step, current);
            row.spin_btn.digits = step < 1 ? 2 : 0;
            if (!has_key(settings, key)) {
                row.sensitive = false;
                return row;
            }
            row.spin_btn.value_changed.connect(() => {
                double val = row.spin_btn.get_value();
                if ((settings.get_double(key) - val).abs() > 0.001) settings.set_double(key, val);
            });
            settings.changed[key].connect(() => row.spin_btn.set_value(settings.get_double(key)));
            return row;
        }

        private SelectionRow bind_choice(string title, GLib.Settings? settings, string key, owned string[] ids, owned string[] labels) {
            string current = labels[0];
            if (has_key(settings, key)) {
                string val = settings.get_string(key);
                for (int i = 0; i < ids.length; i++) {
                    if (ids[i] == val) current = labels[i];
                }
            }
            var row = new SelectionRow(title, labels, current);
            if (!has_key(settings, key)) {
                row.sensitive = false;
                return row;
            }
            row.selected.connect((item) => {
                for (int i = 0; i < labels.length; i++) {
                    if (labels[i] == item && settings.get_string(key) != ids[i]) settings.set_string(key, ids[i]);
                }
            });
            settings.changed[key].connect(() => {
                string val = settings.get_string(key);
                for (int i = 0; i < ids.length; i++) {
                    if (ids[i] == val) row.current_value = labels[i];
                }
            });
            return row;
        }

        // Returns a GLib.Settings instance only if the schema is installed.
        private GLib.Settings? get_settings(string schema) {
            var src = GLib.SettingsSchemaSource.get_default();
            if (src == null || src.lookup(schema, true) == null) return null;
            return new GLib.Settings(schema);
        }
    }
}
