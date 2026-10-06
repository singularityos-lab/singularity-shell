using GLib;

namespace Singularity {

    public class Shortcut : Object {
        public string id;
        public string name;
        public string description;
        public string default_accelerator;
        public string accelerator;
        public string action_name;
        public string? secondary_accelerator;

        public Shortcut(string name, string desc, string default_accel, string action,
                        string? id = null, string? secondary_accel = null) {
            this.id = id ?? action;
            this.name = name;
            this.description = desc;
            this.default_accelerator = default_accel;
            this.accelerator = default_accel;
            this.action_name = action;
            this.secondary_accelerator = secondary_accel;
        }
    }
    public class CustomKeybinding : Object {
        public string id;
        public string name;
        public string accelerator;
        public string command;
        public string app_id;
        public string action;

        public CustomKeybinding(string id, string name, string accelerator,
                                string command, string app_id, string action) {
            this.id = id;
            this.name = name;
            this.accelerator = accelerator;
            this.command = command;
            this.app_id = app_id;
            this.action = action;
        }

        public bool is_app_action {
            get { return app_id != "" && action != ""; }
        }

        public DesktopAppInfo? app_info() {
            if (app_id == "") return null;
            string desktop_id = app_id.has_suffix(".desktop") ? app_id : app_id + ".desktop";
            return new DesktopAppInfo(desktop_id);
        }
    }

    [DBus (name = "dev.sinty.desktop.Shortcuts")]
    public class ShortcutManager : Object {
        public List<Shortcut> shortcuts;
        [DBus (visible = false)]
        public List<CustomKeybinding> custom_keybindings = new List<CustomKeybinding>();
        [DBus (visible = false)]
        public signal void custom_keybindings_changed();
        private GLib.Settings settings;
        private string? last_synced_xkb_layout = null;
        private string? last_synced_xkb_variant = null;
        private GLib.Settings? wm_settings;
        private HashTable<string, GLib.Settings> external_settings =
            new HashTable<string, GLib.Settings>(str_hash, str_equal);
        private GLib.FileMonitor? capslock_monitor = null;
        private GLib.FileMonitor? numlock_monitor = null;
        private ulong screenshot_handler_id = 0;
        private GLib.Subprocess? pip_region_picker = null;
        public signal void shortcut_changed(string action_name, string new_accelerator);
        public signal void run_command_triggered();
        public signal void retile_triggered();
        public signal void launcher_triggered();
        public signal void launcher_hide_triggered();
        public signal void workspace_overview_triggered();
        public signal void workspace_overview_hide_triggered();
        public signal void emoji_picker_triggered();
        public signal void clipboard_history_triggered();
        public signal void shortcut_cheatsheet_triggered();
        public signal void accessibility_feedback(string feature, bool enabled);

        public ShortcutManager() {
            shortcuts = new List<Shortcut>();
            settings = new GLib.Settings("dev.sinty.desktop");
            var schema_source = GLib.SettingsSchemaSource.get_default();
            if (schema_source.lookup("org.gnome.desktop.wm.preferences", true) != null) {
                wm_settings = new GLib.Settings("org.gnome.desktop.wm.preferences");
            }
            register_shortcut("Volume Up", "Increase volume", "", "volume_up", null, "XF86AudioRaiseVolume");
            register_shortcut("Volume Down", "Decrease volume", "", "volume_down", null, "XF86AudioLowerVolume");
            register_shortcut("Mute", "Toggle mute", "<Super>m", "volume_mute", null, "XF86AudioMute");
            register_shortcut("Mute Microphone", "Toggle microphone mute", "", "mic_mute", null, "XF86AudioMicMute");
            register_shortcut("Brightness Up", "Increase brightness", "", "brightness_up", null, "XF86MonBrightnessUp");
            register_shortcut("Brightness Down", "Decrease brightness", "", "brightness_down", null, "XF86MonBrightnessDown");
            register_shortcut("Snap Window Left", "Snap the focused window to the left half", "<Super>Left", "snap_left");
            register_shortcut("Snap Window Right", "Snap the focused window to the right half", "<Super>Right", "snap_right");
            register_shortcut("Snap Window Up", "Snap the focused window to the top half", "<Super>Up", "snap_up");
            register_shortcut("Snap Window Down", "Snap the focused window to the bottom half", "<Super>Down", "snap_down");
            register_shortcut("Keyboard Light Up", "Increase keyboard backlight", "XF86KbdBrightnessUp", "kbd_brightness_up");
            register_shortcut("Keyboard Light Down", "Decrease keyboard backlight", "XF86KbdBrightnessDown", "kbd_brightness_down");
            register_shortcut("Launcher", "Open application launcher", "<Super>space", "toggle_launcher", null, "Super_L");
            register_shortcut("Workspaces", "Show workspace overview", "<Super>w", "toggle_workspace_overview");
            register_shortcut("Desktop", "Reveal the desktop", "<Super>d", "toggle_desktop_reveal");
            register_shortcut("Terminal", "Open terminal", "<Super>Return", "spawn_terminal");
            register_shortcut("Emoji Picker", "Open the emoji picker", "<Super>period", "toggle_emoji_picker");
            register_shortcut("Clipboard History", "Open the clipboard history", "<Super>v", "toggle_clipboard_history");
            register_shortcut("Keyboard Shortcuts", "Show the keyboard shortcuts", "<Super>slash", "toggle_shortcut_cheatsheet");
            register_shortcut("Command Palette", "Open the command palette", "<Super>Tab", "run_command");
            register_shortcut("Command Palette (alt)", "Open the command palette", "<Shift><Alt>F2", "run_command", "run_command_alt");
            register_shortcut("Re-tile Windows", "Re-arrange windows in grid", "<Super>r", "retile_windows");
            register_shortcut("Screenshot", "Open screenshot tool", "Print", "screenshot_tool");
            register_shortcut("Screenshot Region", "Select region to screenshot", "<Shift>Print", "screenshot_region");
            register_shortcut("Screenshot Window", "Screenshot active window", "<Alt>Print", "screenshot_window");
            register_shortcut("Picture in Picture Region", "Show a selected window region in picture in picture", "<Super><Shift>p", "pip_region");
            register_shortcut("Picture in Picture Window", "Show the focused window in picture in picture", "<Super><Alt>p", "pip_window");
            register_shortcut("Lock Screen", "Lock the screen", "<Super>l", "lock_screen");
            register_shortcut("Screen Reader", "Turn the screen reader on or off", "<Super><Alt>s", "toggle_screen_reader");
            register_shortcut("Zoom", "Turn zoom on or off", "<Super><Alt>8", "toggle_zoom");
            register_shortcut("Zoom In", "Increase the zoom level", "<Super><Alt>equal", "zoom_in");
            register_shortcut("Zoom Out", "Decrease the zoom level", "<Super><Alt>minus", "zoom_out");
            register_shortcut("Dictation", "Start or stop dictation in the focused text field", "<Super>h", "toggle_dictation");
            register_shortcut("Switch Input Method", "Switch between the keyboard layout and input methods", "<Control>space", "switch_input_method");
            load_custom_shortcuts();
            load_custom_keybindings();
            settings.changed["custom-keybindings"].connect(() => {
                load_custom_keybindings();
                write_labwc_rc_xml();
                custom_keybindings_changed();
            });
            if (settings.settings_schema.has_key("portal-global-shortcuts"))
                settings.changed["portal-global-shortcuts"].connect(() => write_labwc_rc_xml());
            settings.changed["input-method-engines"].connect(() => write_labwc_rc_xml());
            settings.changed["dictation-enabled"].connect(() => write_labwc_rc_xml());
            Idle.add(() => {
                write_labwc_rc_xml();
                apply_gtk_decoration_layout();
                return Source.REMOVE;
            });
            settings.changed["custom-shortcuts"].connect(() => {
                load_custom_shortcuts();
                write_labwc_rc_xml();
            });
            settings.changed["dark-mode"].connect(() => {
                write_labwc_rc_xml();
            });
            settings.changed["xkb-layout"].connect(() => {
                write_labwc_rc_xml();
            });
            settings.changed["xkb-variant"].connect(() => {
                write_labwc_rc_xml();
            });
            settings.changed["force-ssd"].connect(() => {
                write_labwc_rc_xml();
            });
            settings.changed["mouse-acceleration"].connect(() => {
                write_labwc_rc_xml();
            });
            settings.changed["natural-scrolling"].connect(() => {
                write_labwc_rc_xml();
            });
            foreach (string key in new string[] {"touchpad-scroll-speed", "mouse-scroll-speed", "allow-tearing",
                    "xwayland-native-scaling"}) {
                settings.changed[key].connect(() => {
                    write_labwc_rc_xml();
                });
            }
            settings.changed["workspaces-per-monitor"].connect(() => {
                write_labwc_rc_xml();
            });
            foreach (string key in new string[] {"tablet-output", "tablet-keep-aspect", "tablet-left-handed",
                    "tablet-area-custom", "tablet-area", "tablet-pressure-curve", "tablet-mouse-mode",
                    "tablet-stylus-buttons", "tablet-pad-buttons"}) {
                settings.changed[key].connect(() => write_labwc_rc_xml());
            }
            Singularity.Tablet.TabletManager.get_default().changed.connect(() => write_labwc_rc_xml());
            foreach (string key in new string[] {"gestures-enabled", "gesture-fingers", "gesture-direction",
                    "gesture-two-dimensional", "gesture-sensitivity", "gesture-threshold"}) {
                settings.changed[key].connect(() => {
                    write_labwc_rc_xml();
                });
            }
            foreach (string key in new string[] {"touchpad-two-finger-scroll", "touchpad-edge-scroll",
                    "touchpad-edge-natural-scroll", "touchpad-circular-scroll"}) {
                settings.changed[key].connect(() => {
                    write_labwc_rc_xml();
                });
            }
            Gtk.Settings.get_default().notify["gtk-enable-animations"].connect(() => {
                write_labwc_rc_xml();
            });
            Singularity.Motion.get_default().changed.connect(() => {
                write_labwc_rc_xml();
            });
            watch_accessibility_settings();
            if (wm_settings != null) {
                wm_settings.changed["button-layout"].connect(() => {
                    write_labwc_rc_xml();
                    apply_gtk_decoration_layout();
                });
            }
            Bus.own_name(
                BusType.SESSION,
                "dev.sinty.desktop",
                BusNameOwnerFlags.ALLOW_REPLACEMENT | BusNameOwnerFlags.REPLACE,
                (conn) => {
                    try {
                        conn.register_object("/dev/sinty/desktop/Shortcuts", this);
                    } catch (Error e) {
                        warning("Failed to register shortcuts: %s", e.message);
                    }
                },
                null,
                () => warning("ShortcutManager: lost dev.sinty.desktop name")
            );
            setup_capslock_monitor();
            setup_numlock_monitor();
        }

        private void setup_led_monitor(string led_key, string icon, string label_on, string label_off,
                                        ref GLib.FileMonitor? monitor_field) {
            string? led_path = null;
            try {
                var leds_dir = Dir.open("/sys/class/leds");
                string? name = null;
                while ((name = leds_dir.read_name()) != null) {
                    if (led_key in name) {
                        led_path = "/sys/class/leds/%s/brightness".printf(name);
                        break;
                    }
                }
            } catch (Error e) { return; }
            if (led_path == null) return;
            try {
                var file = GLib.File.new_for_path(led_path);
                monitor_field = file.monitor_file(GLib.FileMonitorFlags.NONE, null);
                monitor_field.changed.connect((f, _other, event) => {
                    if (event != GLib.FileMonitorEvent.CHANGED &&
                        event != GLib.FileMonitorEvent.CREATED) return;
                    try {
                        string raw;
                        GLib.FileUtils.get_contents(f.get_path(), out raw);
                        bool on = raw.strip() != "0";
                        Singularity.Shell.OsdOverlay.get_default().show_osd(
                            icon, -1, on ? label_on : label_off
                        );
                    } catch (Error e) {}
                });
            } catch (Error e) {
                warning("Failed to monitor %s LED: %s", led_key, e.message);
            }
        }

        private void setup_capslock_monitor() {
            setup_led_monitor("capslock", "input-caps-word-enabled-symbolic",
                "Caps Lock On", "Caps Lock Off", ref capslock_monitor);
        }

        private void setup_numlock_monitor() {
            setup_led_monitor("numlock", "input-num-lock-symbolic",
                "Num Lock On", "Num Lock Off", ref numlock_monitor);
        }

        private void register_shortcut(string name, string desc, string accel, string action,
                                       string? id = null, string? secondary_accel = null) {
            var s = new Shortcut(name, desc, accel, action, id, secondary_accel);
            shortcuts.append(s);
        }

        // Convert a GLib accelerator string to a labwc key spec.
        // e.g. "<Super><Shift>F2", "W-S-F2", "XF86AudioRaiseVolume", "XF86AudioRaiseVolume"
        // labwc modifier order: C- A- S- W-

        private string accel_to_labwc(string accel) {
            bool has_ctrl  = "<Control>" in accel;
            bool has_alt   = "<Alt>" in accel;
            bool has_shift = "<Shift>" in accel;
            bool has_super = "<Super>" in accel;
            // Strip all modifier tokens to get bare key
            string key = accel
                .replace("<Control>", "")
                .replace("<Alt>",     "")
                .replace("<Shift>",   "")
                .replace("<Super>",   "");
            // Rebuild in labwc canonical order: C- A- S- W-
            string prefix = "";
            if (has_ctrl)  prefix += "C-";
            if (has_alt)   prefix += "A-";
            if (has_shift) prefix += "S-";
            if (has_super) prefix += "W-";
            return prefix + key;
        }

        // Write ~/.config/labwc/rc.xml from the current shortcut list, then
        // ask labwc to reconfigure so the new keybinds take effect immediately.

        private GLib.Settings? external_settings_for(string schema_id) {
            var existing = external_settings.lookup(schema_id);
            if (existing != null) return existing;
            var source = GLib.SettingsSchemaSource.get_default();
            if (source == null || source.lookup(schema_id, true) == null) return null;
            var created = new GLib.Settings(schema_id);
            external_settings.insert(schema_id, created);
            return created;
        }

        private Variant? external_value(string schema_id, string key) {
            var external = external_settings_for(schema_id);
            if (external == null || !external.settings_schema.has_key(key)) return null;
            return external.get_value(key);
        }

        private bool external_bool(string schema_id, string key, bool fallback) {
            var value = external_value(schema_id, key);
            return value != null && value.is_of_type(VariantType.BOOLEAN) ? value.get_boolean() : fallback;
        }

        private int external_int(string schema_id, string key, int fallback) {
            var value = external_value(schema_id, key);
            if (value == null) return fallback;
            if (value.is_of_type(VariantType.INT32)) return value.get_int32();
            if (value.is_of_type(VariantType.UINT32)) return (int) value.get_uint32();
            return fallback;
        }

        private double external_double(string schema_id, string key, double fallback) {
            var value = external_value(schema_id, key);
            return value != null && value.is_of_type(VariantType.DOUBLE) ? value.get_double() : fallback;
        }

        private string external_string(string schema_id, string key, string fallback) {
            var value = external_value(schema_id, key);
            return value != null && value.is_of_type(VariantType.STRING) ? value.get_string() : fallback;
        }

        private void watch_accessibility_settings() {
            string[,] watched = {
                { "org.gnome.desktop.a11y.keyboard", "" },
                { "org.gnome.desktop.a11y.mouse", "" },
                { "org.gnome.desktop.a11y.magnifier", "mag-factor" },
                { "org.gnome.desktop.a11y.magnifier", "invert-lightness" },
                { "org.gnome.desktop.a11y.magnifier", "show-cross-hairs" },
                { "org.gnome.desktop.a11y.applications", "screen-magnifier-enabled" },
                { "org.gnome.desktop.interface", "locate-pointer" },
                { "org.gnome.desktop.wm.preferences", "visual-bell" },
                { "org.gnome.desktop.wm.preferences", "visual-bell-type" },
                { "org.gnome.desktop.wm.preferences", "focus-mode" },
                { "org.gnome.desktop.peripherals.keyboard", "repeat" },
                { "org.gnome.desktop.peripherals.keyboard", "delay" },
                { "org.gnome.desktop.peripherals.keyboard", "repeat-interval" },
                { "org.gnome.desktop.peripherals.mouse", "double-click" }
            };
            for (int i = 0; i < watched.length[0]; i++) {
                var external = external_settings_for(watched[i, 0]);
                if (external == null) continue;
                string key = watched[i, 1];
                if (key == "") {
                    external.changed.connect(() => {
                        write_labwc_rc_xml();
                    });
                } else if (external.settings_schema.has_key(key)) {
                    external.changed[key].connect(() => {
                        write_labwc_rc_xml();
                    });
                }
            }
            if (settings.settings_schema.has_key("color-filter")) {
                settings.changed["color-filter"].connect(() => {
                    write_labwc_rc_xml();
                });
            }
        }

        private string yes_no(bool value) {
            return value ? "yes" : "no";
        }

        private void append_accessibility_xml(StringBuilder xml, string dbus_shorts) {
            const string KEYBOARD = "org.gnome.desktop.a11y.keyboard";
            const string MOUSE = "org.gnome.desktop.a11y.mouse";
            const string WM = "org.gnome.desktop.wm.preferences";
            xml.append("  <accessibility>\n");
            xml.append_printf("    <keyboardShortcuts>%s</keyboardShortcuts>\n",
                yes_no(external_bool(KEYBOARD, "enable", false)));
            xml.append_printf("    <stickyKeys><enabled>%s</enabled><twoKeyOff>%s</twoKeyOff><modifierBeep>%s</modifierBeep></stickyKeys>\n",
                yes_no(external_bool(KEYBOARD, "stickykeys-enable", false)),
                yes_no(external_bool(KEYBOARD, "stickykeys-two-key-off", true)),
                yes_no(external_bool(KEYBOARD, "stickykeys-modifier-beep", false)));
            xml.append_printf("    <slowKeys><enabled>%s</enabled><delay>%d</delay></slowKeys>\n",
                yes_no(external_bool(KEYBOARD, "slowkeys-enable", false)),
                external_int(KEYBOARD, "slowkeys-delay", 300).clamp(0, 10000));
            xml.append_printf("    <bounceKeys><enabled>%s</enabled><delay>%d</delay></bounceKeys>\n",
                yes_no(external_bool(KEYBOARD, "bouncekeys-enable", false)),
                external_int(KEYBOARD, "bouncekeys-delay", 300).clamp(0, 10000));
            xml.append_printf("    <mouseKeys><enabled>%s</enabled><maxSpeed>%d</maxSpeed><accelTime>%d</accelTime><initDelay>%d</initDelay></mouseKeys>\n",
                yes_no(external_bool(KEYBOARD, "mousekeys-enable", false)),
                external_int(KEYBOARD, "mousekeys-max-speed", 10).clamp(1, 500),
                external_int(KEYBOARD, "mousekeys-accel-time", 300).clamp(0, 10000),
                external_int(KEYBOARD, "mousekeys-init-delay", 160).clamp(0, 10000));
            xml.append_printf("    <toggleKeys>%s</toggleKeys>\n",
                yes_no(external_bool(KEYBOARD, "togglekeys-enable", false)));
            xml.append_printf("    <locatePointer>%s</locatePointer>\n",
                yes_no(external_bool("org.gnome.desktop.interface", "locate-pointer", false)));
            xml.append_printf("    <secondaryClick><enabled>%s</enabled><time>%d</time></secondaryClick>\n",
                yes_no(external_bool(MOUSE, "secondary-click-enabled", false)),
                (int) Math.round(external_double(MOUSE, "secondary-click-time", 1.2).clamp(0.1, 10.0) * 1000));
            xml.append_printf("    <dwellClick><enabled>%s</enabled><time>%d</time><threshold>%d</threshold></dwellClick>\n",
                yes_no(external_bool(MOUSE, "dwell-click-enabled", false)),
                (int) Math.round(external_double(MOUSE, "dwell-time", 1.2).clamp(0.1, 10.0) * 1000),
                external_int(MOUSE, "dwell-threshold", 10).clamp(1, 100));
            xml.append_printf("    <visualBell><enabled>%s</enabled><type>%s</type></visualBell>\n",
                yes_no(external_bool(WM, "visual-bell", false)),
                external_string(WM, "visual-bell-type", "fullscreen-flash") == "frame-flash"
                    ? "frameFlash" : "fullscreenFlash");
            string color_filter = settings.settings_schema.has_key("color-filter")
                ? settings.get_string("color-filter") : "none";
            xml.append_printf("    <colorFilter>%s</colorFilter>\n", Markup.escape_text(color_filter));
            xml.append_printf("    <feedbackCommand>%s</feedbackCommand>\n", dbus_shorts);
            xml.append("  </accessibility>\n");

            const string MAGNIFIER = "org.gnome.desktop.a11y.magnifier";
            char[] factor_buf = new char[double.DTOSTR_BUF_SIZE];
            xml.append("  <magnifier>\n");
            xml.append_printf("    <enabled>%s</enabled>\n",
                yes_no(external_bool("org.gnome.desktop.a11y.applications", "screen-magnifier-enabled", false)));
            xml.append("    <width>-1</width>\n    <height>-1</height>\n");
            xml.append_printf("    <initScale>%s</initScale>\n",
                external_double(MAGNIFIER, "mag-factor", 2.0).clamp(1.0, 32.0).format(factor_buf, "%.2f"));
            xml.append_printf("    <invert>%s</invert>\n",
                yes_no(external_bool(MAGNIFIER, "invert-lightness", false)));
            xml.append_printf("    <crossHairs>%s</crossHairs>\n",
                yes_no(external_bool(MAGNIFIER, "show-cross-hairs", false)));
            xml.append("  </magnifier>\n");

            string focus_mode = external_string(WM, "focus-mode", "click");
            xml.append_printf("  <focus>\n    <followMouse>%s</followMouse>\n  </focus>\n",
                yes_no(focus_mode == "sloppy" || focus_mode == "mouse"));
        }

        public void write_labwc_rc_xml() {
            // Pin the session bus we actually own the name on: the session runs
            // under dbus-run-session (ephemeral address), not a fixed /run/user path.
            // labwc Execute uses execvp (no shell), so pass it via `env VAR=val cmd`.
            string bus = GLib.Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
            string call = "gdbus call --session --dest dev.sinty.desktop --object-path /dev/sinty/desktop/Shortcuts --method dev.sinty.desktop.Shortcuts.ExecuteAction";
            string dbus_shorts = (bus != null && bus != "")
                ? "env DBUS_SESSION_BUS_ADDRESS=%s %s".printf(bus, call)
                : call;

            // Keyboard layout (xkb)
            string xkb_layout = settings.get_string("xkb-layout");
            string xkb_variant = settings.get_string("xkb-variant");
            try {
                var input_settings = new GLib.Settings("org.gnome.desktop.input-sources");
                var sources = input_settings.get_value("sources");
                var iter = sources.iterator();
                string t, i;
                while (iter.next("(ss)", out t, out i)) {
                    if (t == "xkb") {
                        xkb_layout = i;
                        xkb_variant = "";
                        if (i.contains("+")) {
                            xkb_layout = i.substring(0, i.index_of("+"));
                            xkb_variant = i.substring(i.index_of("+") + 1);
                        }
                        bool sync_layout = last_synced_xkb_layout != xkb_layout;
                        bool sync_variant = last_synced_xkb_variant != xkb_variant;
                        last_synced_xkb_layout = xkb_layout;
                        last_synced_xkb_variant = xkb_variant;
                        if (sync_layout)
                            settings.set_string("xkb-layout", xkb_layout);
                        if (sync_variant)
                            settings.set_string("xkb-variant", xkb_variant);
                        break;
                    }
                }
            } catch (Error e) {
                // GNOME input sources are optional; keep Singularity's own xkb keys.
            }
            if (xkb_layout == "") {
                // No layout chosen in Settings: honour the OOBE keymap that the
                // session exports as XKB_DEFAULT_LAYOUT (from vconsole.conf) instead
                // of forcing a default that would override it in rc.xml (#80).
                xkb_layout = Environment.get_variable("XKB_DEFAULT_LAYOUT") ?? "";
                if (xkb_layout != "")
                    xkb_variant = Environment.get_variable("XKB_DEFAULT_VARIANT") ?? "";
            }
            if (xkb_layout == "") xkb_layout = "it"; // Default to Italian


            var xml = new StringBuilder();
            xml.append("<?xml version=\"1.0\"?>\n<labwc_config>\n");
            xml.append("  <desktops number=\"4\">\n");
            xml.append("    <popupTime>0</popupTime>\n");
            xml.append_printf("    <perOutput>%s</perOutput>\n",
                settings.get_boolean("workspaces-per-monitor") ? "yes" : "no");
            xml.append("  </desktops>\n");

            // Theme (dark/light) + titlebar layout (must be inside <theme>)
            bool dark = settings.get_boolean("dark-mode");
            string button_layout = translate_button_layout();
            xml.append("  <theme>\n");
            xml.append_printf("    <name>%s</name>\n", dark ? "Singularity" : "Adwaita");
            xml.append("    <cornerRadius>12</cornerRadius>\n");
            xml.append("    <titlebar>\n");
            xml.append_printf("      <layout>%s</layout>\n", button_layout);
            xml.append("    </titlebar>\n");
            xml.append("  </theme>\n");

            bool animations = !Singularity.Motion.reduced();
            xml.append("  <core>\n    <decoration>server</decoration>\n");
            xml.append_printf("    <windowAnimations>%s</windowAnimations>\n", animations ? "yes" : "no");
            xml.append_printf("    <allowTearing>%s</allowTearing>\n",
                settings.get_boolean("allow-tearing") ? "fullscreen" : "no");
            xml.append_printf("    <xwaylandNativeScaling>%s</xwaylandNativeScaling>\n",
                settings.get_boolean("xwayland-native-scaling") ? "yes" : "no");
            xml.append("  </core>\n");
            xml.append_printf("  <animations>\n    <durationScale>%s</durationScale>\n  </animations>\n",
                "%.2f".printf(Singularity.Motion.get_default().duration_scale.clamp(0.1, 10.0)).replace(",", "."));

            append_accessibility_xml(xml, dbus_shorts);
            xml.append(Singularity.Tablet.TabletManager.get_default().rc_xml(dbus_shorts));

            // Show the snap/tile preview overlay immediately instead of after
            // labwc's default 500ms, so the tiling rectangles appear instantly (#120).
            xml.append("  <snapping>\n    <overlay>\n      <delay inner=\"0\" outer=\"0\" />\n    </overlay>\n  </snapping>\n");

            bool gestures = settings.get_boolean("gestures-enabled");
            string gesture_fingers = settings.get_string("gesture-fingers");
            string gesture_direction = settings.get_string("gesture-direction");
            bool gesture_invert = gesture_direction == "inverted"
                || (gesture_direction == "follow-scroll" && !settings.get_boolean("natural-scrolling"));
            char[] sensitivity_buf = new char[double.DTOSTR_BUF_SIZE];
            char[] threshold_buf = new char[double.DTOSTR_BUF_SIZE];
            xml.append("  <gestures>\n");
            xml.append_printf("    <enabled>%s</enabled>\n", gestures ? "yes" : "no");
            xml.append_printf("    <fingers>%s</fingers>\n", gesture_fingers);
            xml.append_printf("    <invert>%s</invert>\n", gesture_invert ? "yes" : "no");
            xml.append_printf("    <twoDimensional>%s</twoDimensional>\n",
                settings.get_boolean("gesture-two-dimensional") ? "yes" : "no");
            xml.append_printf("    <sensitivity>%s</sensitivity>\n",
                settings.get_double("gesture-sensitivity").clamp(0.5, 2.0).format(sensitivity_buf, "%.2f"));
            xml.append_printf("    <threshold>%s</threshold>\n",
                settings.get_double("gesture-threshold").clamp(8, 32).format(threshold_buf, "%.0f"));
            xml.append("  </gestures>\n");

            // Pointer/touchpad behaviour from settings.
            bool mouse_accel = settings.get_boolean("mouse-acceleration");
            bool natural_scroll = settings.get_boolean("natural-scrolling");
            char[] scroll_buf = new char[double.DTOSTR_BUF_SIZE];
            unowned string scroll_speed = settings.get_double("touchpad-scroll-speed")
                .clamp(0.25, 1.75).format(scroll_buf, "%.2f");
            string accel_profile = mouse_accel ? "adaptive" : "flat";
            char[] mouse_scroll_buf = new char[double.DTOSTR_BUF_SIZE];
            unowned string mouse_scroll_speed = settings.get_double("mouse-scroll-speed")
                .clamp(0.25, 1.75).format(mouse_scroll_buf, "%.2f");
            xml.append("  <libinput>\n");
            xml.append("    <device category=\"default\">\n");
            xml.append_printf("      <accelProfile>%s</accelProfile>\n", accel_profile);
            xml.append_printf("      <scrollFactor>%s</scrollFactor>\n", mouse_scroll_speed);
            xml.append("    </device>\n");
            xml.append("    <device category=\"touchpad\">\n");
            xml.append_printf("      <accelProfile>%s</accelProfile>\n", accel_profile);
            xml.append_printf("      <naturalScroll>%s</naturalScroll>\n", natural_scroll ? "yes" : "no");
            bool two_finger_scroll = settings.get_boolean("touchpad-two-finger-scroll");
            bool edge_scroll = settings.get_boolean("touchpad-edge-scroll");
            string scroll_method = two_finger_scroll && edge_scroll ? "twofingerAndEdge"
                : two_finger_scroll ? "twofinger" : edge_scroll ? "edge" : "none";
            xml.append_printf("      <scrollMethod>%s</scrollMethod>\n", scroll_method);
            xml.append_printf("      <naturalScrollEdge>%s</naturalScrollEdge>\n",
                settings.get_boolean("touchpad-edge-natural-scroll") ? "yes" : "no");
            xml.append_printf("      <circularScroll>%s</circularScroll>\n",
                edge_scroll && settings.get_boolean("touchpad-circular-scroll") ? "yes" : "no");
            xml.append_printf("      <scrollFactor>%s</scrollFactor>\n", scroll_speed);
            xml.append("    </device>\n");
            xml.append("  </libinput>\n");

            xml.append("  <mouse>\n");
            xml.append("    <default />\n");
            xml.append_printf("    <doubleClickTime>%d</doubleClickTime>\n",
                external_int("org.gnome.desktop.peripherals.mouse", "double-click", 400).clamp(100, 2000));
            xml.append("    <context name=\"Titlebar\">\n");
            xml.append("      <mousebind direction=\"Up\" action=\"Scroll\" />\n");
            xml.append("      <mousebind direction=\"Down\" action=\"Scroll\" />\n");
            xml.append("    </context>\n");
            if (gesture_fingers == "4") {
                xml.append_printf("    <gesturebind type=\"swipe\" fingers=\"3\" direction=\"Down\"><action name=\"Execute\"><command>%s hide_launcher</command></action></gesturebind>\n", dbus_shorts);
            }
            if (gestures) {
                foreach (string count in gesture_fingers == "both" ? new string[] { "3", "4" } : new string[] { gesture_fingers }) {
                    xml.append_printf("    <gesturebind type=\"swipe\" fingers=\"%s\" direction=\"Left\"><action name=\"GoToDesktop\" to=\"right\" wrap=\"yes\" /></gesturebind>\n", count);
                    xml.append_printf("    <gesturebind type=\"swipe\" fingers=\"%s\" direction=\"Right\"><action name=\"GoToDesktop\" to=\"left\" wrap=\"yes\" /></gesturebind>\n", count);
                    xml.append_printf("    <gesturebind type=\"swipe\" fingers=\"%s\" direction=\"Down\"><action name=\"Execute\"><command>%s toggle_workspace_overview</command></action></gesturebind>\n", count, dbus_shorts);
                    xml.append_printf("    <gesturebind type=\"swipe\" fingers=\"%s\" direction=\"Up\"><action name=\"Execute\"><command>%s hide_workspace_overview</command></action></gesturebind>\n", count, dbus_shorts);
                }
            }
            xml.append("  </mouse>\n");

            // Keyboard layout (xkb)
            xml.append("  <keyboard>\n");
            xml.append("    <xkb>\n");
            xml.append_printf("      <layout>%s</layout>\n", xkb_layout);
            if (xkb_variant != "") xml.append_printf("      <variant>%s</variant>\n", xkb_variant);
            xml.append("    </xkb>\n");
            const string PERIPHERAL_KEYBOARD = "org.gnome.desktop.peripherals.keyboard";
            int repeat_interval = external_int(PERIPHERAL_KEYBOARD, "repeat-interval", 30).clamp(1, 1000);
            xml.append_printf("    <repeatRate>%d</repeatRate>\n",
                external_bool(PERIPHERAL_KEYBOARD, "repeat", true) ? int.max(1, (1000 + repeat_interval / 2) / repeat_interval) : 0);
            xml.append_printf("    <repeatDelay>%d</repeatDelay>\n",
                external_int(PERIPHERAL_KEYBOARD, "delay", 500).clamp(100, 5000));
            // Static desktop-switching keybinds
            for (int i = 1; i <= 4; i++) {
                xml.append_printf("    <keybind key=\"C-A-%d\"><action name=\"GoToDesktop\" to=\"%d\" /></keybind>\n", i, i);
            }
            for (int i = 1; i <= 4; i++) {
                xml.append_printf("    <keybind key=\"C-A-S-%d\"><action name=\"Execute\"><command>%s send_to_workspace_%d</command></action></keybind>\n", i, dbus_shorts, i);
            }
            // Close the focused window (Alt-F4)
            xml.append("    <keybind key=\"A-F4\"><action name=\"Close\" /></keybind>\n");
            // Window switcher (Alt-Tab)
            xml.append_printf("    <keybind key=\"A-Tab\"><action name=\"Execute\"><command>%s switch_windows_next</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"A-S-Tab\"><action name=\"Execute\"><command>%s switch_windows_prev</command></action></keybind>\n", dbus_shorts);
            // Super_L/R on release, launcher
            xml.append_printf("    <keybind key=\"Super_L\" onRelease=\"yes\" overrideInhibition=\"yes\"><action name=\"Execute\"><command>%s toggle_launcher</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"Super_R\" onRelease=\"yes\" overrideInhibition=\"yes\"><action name=\"Execute\"><command>%s toggle_launcher</command></action></keybind>\n", dbus_shorts);
            xml.append("    <!-- Singularity Desktop shortcuts -->\n");
            // Dynamic shortcuts from the shortcut registry
            foreach (var s in shortcuts) {
                string key = accel_to_labwc(s.accelerator);
                if (key == "") continue;
                if (s.action_name == "switch_input_method" && settings.get_strv("input-method-engines").length == 0) continue;
                if (s.action_name == "toggle_dictation" && !settings.get_boolean("dictation-enabled")) continue;
                xml.append_printf("    <keybind key=\"%s\"><action name=\"Execute\"><command>%s %s</command></action></keybind>\n",
                    key, dbus_shorts, s.action_name);
            }
            foreach (var k in custom_keybindings) {
                string key = accel_to_labwc(k.accelerator);
                if (key == "") continue;
                xml.append_printf("    <keybind key=\"%s\"><action name=\"Execute\"><command>%s custom:%s</command></action></keybind>\n",
                    key, dbus_shorts, k.id);
            }
            if (settings.settings_schema.has_key("portal-global-shortcuts")) {
                var portal_iter = settings.get_value("portal-global-shortcuts").iterator();
                string p_app, p_id, p_desc, p_accel;
                while (portal_iter.next("(ssss)", out p_app, out p_id, out p_desc, out p_accel)) {
                    string key = accel_to_labwc(p_accel);
                    if (key == "" || xml.str.contains("key=\"%s\"".printf(key))) continue;
                    if (!GLib.DBus.is_name(p_app) || p_id.contains("<") || p_id.contains("&") || p_id.contains(" ")) continue;
                    xml.append_printf("    <keybind key=\"%s\"><action name=\"Execute\"><command>%s portal:%s:%s</command></action></keybind>\n",
                        key, dbus_shorts, p_app, p_id);
                }
            }
            // XF86 hardware media/brightness keys as aliases
            xml.append_printf("    <keybind key=\"XF86AudioRaiseVolume\"><action name=\"Execute\"><command>%s volume_up</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"XF86AudioLowerVolume\"><action name=\"Execute\"><command>%s volume_down</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"XF86AudioMute\"><action name=\"Execute\"><command>%s volume_mute</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"XF86AudioMicMute\"><action name=\"Execute\"><command>%s mic_mute</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"XF86MonBrightnessUp\"><action name=\"Execute\"><command>%s brightness_up</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"XF86MonBrightnessDown\"><action name=\"Execute\"><command>%s brightness_down</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"XF86PowerOff\" overrideInhibition=\"yes\"><action name=\"Execute\"><command>%s power_button</command></action></keybind>\n", dbus_shorts);
            xml.append_printf("    <keybind key=\"XF86Sleep\" overrideInhibition=\"yes\"><action name=\"Execute\"><command>%s sleep_button</command></action></keybind>\n", dbus_shorts);
            xml.append("  </keyboard>\n</labwc_config>\n");

            var labwc = Singularity.Compositor.LabwcBackend.get_default();
            bool menu_changed = labwc.write_config("menu.xml", build_labwc_menu_xml(dbus_shorts));
            if (labwc.write_config("rc.xml", xml.str) || menu_changed) {
                message("ShortcutManager: wrote rc.xml, reloading labwc");
                labwc.reconfigure();
            } else {
                message("ShortcutManager: rc.xml unchanged, skipping reload");
            }
        }

        private string build_labwc_menu_xml(string dbus_shorts) {
            var menu = new StringBuilder();
            menu.append("<?xml version=\"1.0\"?>\n<openbox_menu>\n");
            menu.append("  <menu id=\"client-menu\">\n");
            string[,] items = {
                { _("Minimize"), "Iconify" },
                { _("Maximize"), "ToggleMaximize" },
                { _("Fullscreen"), "ToggleFullscreen" },
                { _("Roll Up/Down"), "ToggleShade" },
                { _("Decorations"), "ToggleDecorations" },
                { _("Always on Top"), "ToggleAlwaysOnTop" }
            };
            for (int i = 0; i < items.length[0]; i++) {
                menu.append_printf("    <item label=\"%s\"><action name=\"%s\" /></item>\n",
                    Markup.escape_text(items[i, 0]), items[i, 1]);
            }
            menu.append_printf("    <menu id=\"client-workspace-menu\" label=\"%s\">\n",
                Markup.escape_text(_("Workspace")));
            for (int i = 1; i <= 4; i++) {
                menu.append_printf("      <item label=\"%d\"><action name=\"Execute\"><command>%s send_to_workspace_%d</command></action></item>\n",
                    i, Markup.escape_text(dbus_shorts), i);
            }
            menu.append("      <separator />\n");
            menu.append_printf("      <item label=\"%s\"><action name=\"ToggleOmnipresent\" /></item>\n",
                Markup.escape_text(_("Always on Visible Workspace")));
            menu.append("    </menu>\n");
            menu.append_printf("    <item label=\"%s\"><action name=\"Close\" /></item>\n",
                Markup.escape_text(_("Close")));
            menu.append("  </menu>\n</openbox_menu>\n");
            return menu.str;
        }

        // Translate GNOME button-layout to labwc format.
        // GNOME: "close,minimize,maximize:appmenu", labwc: "close,iconify,max:"

        private string translate_button_layout() {
            if (wm_settings == null) return ":close";
            string raw = wm_settings.get_string("button-layout");
            string[] halves = raw.split(":", 2);
            string left = halves.length > 0 ? translate_buttons(halves[0]) : "";
            string right = halves.length > 1 ? translate_buttons(halves[1]) : "";
            return left + ":" + right;
        }

        private string translate_buttons(string part) {
            var result = new StringBuilder();
            foreach (string token in part.split(",")) {
                string t = token.strip();
                string mapped = "";
                switch (t) {
                    case "close": mapped = "close"; break;
                    case "minimize": mapped = "iconify"; break;
                    case "maximize": mapped = "max"; break;
                    case "appmenu": case "menu": mapped = "menu"; break;
                    default: continue;
                }
                if (result.len > 0) result.append(",");
                result.append(mapped);
            }
            return result.str;
        }

        // Propagate button-layout to GTK4 CSD windows (shell + external apps via xsettingsd).

        private void apply_gtk_decoration_layout() {
            if (wm_settings == null) return;
            string layout = wm_settings.get_string("button-layout");

            // 1. Apply immediately to all GTK4 windows in this process.
            Gtk.Settings.get_default().gtk_decoration_layout = layout;

            // 1b. Persist to the per-user GTK settings.ini so external Wayland
            // GTK3/4 apps (which never read ~/.xsettingsd) pick up the same
            // button layout at startup, instead of falling back to close-only.
            write_decoration_layout_ini(layout);

            // 2. Write Gtk/DecorationLayout to ~/.xsettingsd for X11/XWayland apps.
            try {
                XSettingsDaemon.get_default().update(
                    { "Gtk/DecorationLayout" }, { "Gtk/DecorationLayout \"%s\"".printf(layout) });
            } catch (GLib.Error e) {
                warning("apply_gtk_decoration_layout: %s", e.message);
            }
        }

        // Merge gtk-decoration-layout into both GTK settings.ini files, keeping
        // any other keys (e.g. gtk-theme-name) already present.
        private void write_decoration_layout_ini(string layout) {
            foreach (string ver in new string[]{"gtk-3.0", "gtk-4.0"}) {
                string dir = GLib.Path.build_filename(
                    GLib.Environment.get_user_config_dir(), ver);
                string path = GLib.Path.build_filename(dir, "settings.ini");
                var kf = new GLib.KeyFile();
                try {
                    kf.load_from_file(path, GLib.KeyFileFlags.KEEP_COMMENTS
                        | GLib.KeyFileFlags.KEEP_TRANSLATIONS);
                } catch {}
                kf.set_string("Settings", "gtk-decoration-layout", layout);
                try {
                    GLib.DirUtils.create_with_parents(dir, 0755);
                    GLib.FileUtils.set_contents(path, kf.to_data());
                } catch (GLib.Error e) {
                    warning("decoration-layout settings.ini (%s): %s", ver, e.message);
                }
            }
        }

        private void load_custom_keybindings() {
            custom_keybindings = new List<CustomKeybinding>();
            if (!settings.settings_schema.has_key("custom-keybindings")) return;
            var list = settings.get_value("custom-keybindings");
            var iter = list.iterator();
            string id, name, accel, command, app_id, action;
            while (iter.next("(ssssss)", out id, out name, out accel, out command, out app_id, out action))
                custom_keybindings.append(new CustomKeybinding(id, name, accel, command, app_id, action));
        }

        private void save_custom_keybindings() {
            var builder = new VariantBuilder(new VariantType("a(ssssss)"));
            foreach (var k in custom_keybindings)
                builder.add("(ssssss)", k.id, k.name, k.accelerator, k.command, k.app_id, k.action);
            settings.set_value("custom-keybindings", builder.end());
        }

        [DBus (visible = false)]
        public CustomKeybinding? find_custom_keybinding(string id) {
            foreach (var k in custom_keybindings)
                if (k.id == id) return k;
            return null;
        }

        [DBus (visible = false)]
        public void set_custom_keybinding(string? id, string name, string accelerator,
                                          string command, string app_id, string action) {
            var existing = id != null ? find_custom_keybinding(id) : null;
            if (existing != null) {
                existing.name = name;
                existing.accelerator = accelerator;
                existing.command = command;
                existing.app_id = app_id;
                existing.action = action;
            } else {
                string new_id = "custom-%lld".printf(GLib.get_real_time());
                custom_keybindings.append(new CustomKeybinding(new_id, name, accelerator, command, app_id, action));
            }
            save_custom_keybindings();
        }

        [DBus (visible = false)]
        public void set_custom_keybinding_accelerator(string id, string accelerator) {
            var k = find_custom_keybinding(id);
            if (k == null) return;
            k.accelerator = accelerator;
            save_custom_keybindings();
        }

        [DBus (visible = false)]
        public void remove_custom_keybinding(string id) {
            var k = find_custom_keybinding(id);
            if (k == null) return;
            custom_keybindings.remove(k);
            save_custom_keybindings();
        }

        private void activate_portal_shortcut(string target) {
            int split = target.index_of(":");
            if (split <= 0) return;
            string app_id = target.substring(0, split);
            string shortcut_id = target.substring(split + 1);
            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    var conn = Bus.get.end(res);
                    conn.call.begin("org.freedesktop.impl.portal.desktop.singularity", "/org/freedesktop/portal/desktop",
                        "dev.sinty.portal.GlobalShortcuts", "Activate", new Variant("(ss)", app_id, shortcut_id),
                        new VariantType("(u)"), DBusCallFlags.NO_AUTO_START, 2000, null, (o, r) => {
                            try {
                                conn.call.end(r);
                            } catch (Error e) {
                                warning("ShortcutManager: portal shortcut %s failed: %s", target, e.message);
                            }
                        });
                } catch (Error e) {
                    warning("ShortcutManager: %s", e.message);
                }
            });
        }

        private void run_custom_keybinding(string id) {
            var k = find_custom_keybinding(id);
            if (k == null) {
                warning("ShortcutManager: no custom shortcut %s", id);
                return;
            }
            var context = Gdk.Display.get_default().get_app_launch_context();
            try {
                if (k.is_app_action) {
                    var info = k.app_info();
                    if (info == null) {
                        warning("ShortcutManager: %s is not installed", k.app_id);
                        return;
                    }
                    if (!ParentalEnforcer.get_default().allows(info)) return;
                    info.launch_action(k.action, context);
                } else if (k.command.strip() != "") {
                    if (!ParentalEnforcer.get_default().allows_command(k.command)) return;
                    var info = AppInfo.create_from_commandline(k.command, k.name, AppInfoCreateFlags.NONE);
                    info.launch(null, context);
                }
            } catch (Error e) {
                warning("ShortcutManager: custom shortcut %s failed: %s", k.name, e.message);
            }
        }

        private void load_custom_shortcuts() {
            var custom = settings.get_value("custom-shortcuts");
            if (custom.is_of_type(new VariantType("a{ss}"))) {
                var iter = custom.iterator();
                string action;
                string accel;
                foreach (var s in shortcuts) {
                    if (s.accelerator != s.default_accelerator) {
                        s.accelerator = s.default_accelerator;
                        shortcut_changed(s.action_name, s.accelerator);
                    }
                }
                while (iter.next("{ss}", out action, out accel)) {
                    foreach (var s in shortcuts) {
                        if (s.id == action) {
                            if (s.accelerator != accel) {
                                s.accelerator = accel;
                                shortcut_changed(s.action_name, s.accelerator);
                            }
                            break;
                        }
                    }
                }
            }
        }

        public void update_shortcut(string shortcut_id, string new_accelerator) {
            foreach (var s in shortcuts) {
                if (s.id == shortcut_id) {
                    s.accelerator = new_accelerator;
                    shortcut_changed(s.action_name, s.accelerator);
                    break;
                }
            }
            var builder = new VariantBuilder(new VariantType("a{ss}"));
            foreach (var s in shortcuts) {
                if (s.accelerator != s.default_accelerator) {
                    builder.add("{ss}", s.id, s.accelerator);
                }
            }
            settings.set_value("custom-shortcuts", builder.end());
            write_labwc_rc_xml();
        }

        public void reset_shortcut(string shortcut_id) {
            foreach (var s in shortcuts) {
                if (s.id == shortcut_id) {
                    update_shortcut(shortcut_id, s.default_accelerator);
                    break;
                }
            }
        }

        public void execute_action(string action_name) {
            if (action_name.has_prefix("custom:")) {
                run_custom_keybinding(action_name.substring(7));
                return;
            }
            if (action_name.has_prefix("portal:")) {
                activate_portal_shortcut(action_name.substring(7));
                return;
            }
            if (action_name.has_prefix("tablet-key:")) {
                Singularity.Tablet.TabletManager.send_shortcut(action_name.substring(11));
                return;
            }
            try {
                switch (action_name) {
                    case "volume_up":    volume_up(); break;
                    case "volume_down":  volume_down(); break;
                    case "volume_mute":  volume_mute(); break;
                    case "mic_mute":     mic_mute(); break;
                    case "brightness_up":   brightness_up(); break;
                    case "brightness_down": brightness_down(); break;
                    case "kbd_brightness_up":   kbd_brightness_up(); break;
                    case "kbd_brightness_down": kbd_brightness_down(); break;
                    case "toggle_launcher": toggle_launcher(); break;
                    case "hide_launcher": launcher_hide_triggered(); break;
                    case "toggle_workspace_overview": workspace_overview_triggered(); break;
                    case "hide_workspace_overview": workspace_overview_hide_triggered(); break;
                    case "toggle_desktop_reveal": Singularity.wayland_toggle_desktop_reveal(); break;
                    case "spawn_terminal": spawn_terminal(); break;
                    case "run_command": run_command(); break;
                    case "toggle_emoji_picker": emoji_picker_triggered(); break;
                    case "toggle_clipboard_history": clipboard_history_triggered(); break;
                    case "toggle_shortcut_cheatsheet": shortcut_cheatsheet_triggered(); break;
                    case "switch_windows_next": switch_windows_next(); break;
                    case "switch_windows_prev": switch_windows_prev(); break;
                    case "retile_windows": retile_windows(); break;
                    case "lock_screen":    lock_screen(); break;
                    case "power_button": PowerKeyManager.get_default().power_pressed(); break;
                    case "sleep_button": PowerKeyManager.get_default().sleep_pressed(); break;
                    case "screenshot_tool":     screenshot_tool_action(); break;
                    case "screenshot_region":   screenshot_region_action(); break;
                    case "screenshot_window":   screenshot_window_action(); break;
                    case "pip_region": pip_region_action(); break;
                    case "pip_window": pip_window_action(); break;
                    case "snap_left":  snap_focused(TilingLayout.SNAP_LEFT); break;
                    case "snap_right": snap_focused(TilingLayout.SNAP_RIGHT); break;
                    case "snap_up":    snap_focused(TilingLayout.SNAP_TOP); break;
                    case "snap_down":  snap_focused(TilingLayout.SNAP_BOTTOM); break;
                    case "toggle_screen_keyboard":
                        settings.set_boolean("screen-keyboard-enabled", !settings.get_boolean("screen-keyboard-enabled"));
                        break;
                    case "send_to_workspace_1": send_focused_to_workspace(0); break;
                    case "send_to_workspace_2": send_focused_to_workspace(1); break;
                    case "send_to_workspace_3": send_focused_to_workspace(2); break;
                    case "send_to_workspace_4": send_focused_to_workspace(3); break;
                    case "toggle_screen_reader":
                        toggle_external_bool("org.gnome.desktop.a11y.applications", "screen-reader-enabled");
                        break;
                    case "toggle_zoom":
                        toggle_external_bool("org.gnome.desktop.a11y.applications", "screen-magnifier-enabled");
                        break;
                    case "zoom_in": step_zoom(0.5); break;
                    case "zoom_out": step_zoom(-0.5); break;
                    case "toggle_dictation": Singularity.Dictation.DictationService.get_default().toggle(); break;
                    case "switch_input_method": switch_input_method(); break;
                    default:
                        if (action_name.has_prefix("a11y:")) {
                            handle_accessibility_feedback(action_name.substring(5));
                        } else {
                            warning("Unknown action: %s", action_name);
                        }
                        break;
                }
            } catch (Error e) {
                warning("Failed to execute action %s: %s", action_name, e.message);
            }
        }

        private void toggle_external_bool(string schema_id, string key) {
            var external = external_settings_for(schema_id);
            if (external == null || !external.settings_schema.has_key(key)) return;
            external.set_boolean(key, !external.get_boolean(key));
        }

        private void step_zoom(double step) {
            var magnifier = external_settings_for("org.gnome.desktop.a11y.magnifier");
            if (magnifier == null || !magnifier.settings_schema.has_key("mag-factor")) return;
            magnifier.set_double("mag-factor", (magnifier.get_double("mag-factor") + step).clamp(1.25, 20.0));
        }

        private void handle_accessibility_feedback(string event) {
            string[] parts = event.split(":");
            if (parts.length != 2) return;
            string feature = parts[0];
            bool enabled = parts[1] == "on";
            var keyboard = external_settings_for("org.gnome.desktop.a11y.keyboard");
            if (keyboard != null) {
                if (feature == "sticky-keys" && keyboard.get_boolean("stickykeys-enable") != enabled) {
                    keyboard.set_boolean("stickykeys-enable", enabled);
                } else if (feature == "slow-keys" && keyboard.get_boolean("slowkeys-enable") != enabled) {
                    keyboard.set_boolean("slowkeys-enable", enabled);
                }
            }
            accessibility_feedback(feature, enabled);
        }

        private void send_focused_to_workspace(int index) {
            var app_system = AppSystem.get_default();
            void* handle = app_system.get_focused_window_handle();
            var win = handle != null ? app_system.get_window_by_handle(handle) : null;
            if (win == null) return;
            var monitor = (Gdk.Monitor?)Singularity.wayland_get_window_monitor(handle);
            var target = app_system.get_workspaces_for_monitor(monitor).nth_data(index);
            if (target == null) return;
            app_system.move_window_to_workspace(win, target);
            app_system.activate_workspace(target);
            Singularity.wayland_activate_window(handle);
        }

        private void* _last_snap_handle = null;
        private uint _last_snap = TilingLayout.SNAP_NONE;

        private void snap_focused(uint snap) {
            var tiling = TilingManager.get_default();
            if (tiling != null) {
                if (snap == TilingLayout.SNAP_LEFT
                        && tiling.move_focused_slot(-1)) return;
                if (snap == TilingLayout.SNAP_RIGHT
                        && tiling.move_focused_slot(1)) return;
            }
            void* handle = AppSystem.get_default().get_focused_window_handle();
            if (handle == null) return;
            uint effective = snap;
            if (snap == TilingLayout.SNAP_TOP
                    && handle == _last_snap_handle
                    && _last_snap == TilingLayout.SNAP_TOP) {
                effective = TilingLayout.SNAP_MAXIMIZE;
            }
            Singularity.wayland_snap_view(handle, effective);
            _last_snap_handle = handle;
            _last_snap = effective;
        }

        public void volume_up() throws Error {
            var audio = SystemMonitor.get_default().audio;
            audio.update_volume((audio.volume + 5.0).clamp(0.0, 100.0));
            Singularity.Shell.OsdOverlay.get_default().show_osd(audio.icon_name, audio.volume);
        }

        public void switch_windows_next() throws Error {
            var app = GLib.Application.get_default() as SingularityApp;
            if (app == null) throw new IOError.FAILED("Singularity app unavailable");
            app.switch_windows_next();
        }

        public void switch_windows_prev() throws Error {
            var app = GLib.Application.get_default() as SingularityApp;
            if (app == null) throw new IOError.FAILED("Singularity app unavailable");
            app.switch_windows_prev();
        }

        public void volume_down() throws Error {
            var audio = SystemMonitor.get_default().audio;
            audio.update_volume((audio.volume - 5.0).clamp(0.0, 100.0));
            Singularity.Shell.OsdOverlay.get_default().show_osd(audio.icon_name, audio.volume);
        }

        public void volume_mute() throws Error {
            var audio = SystemMonitor.get_default().audio;
            audio.toggle_mute();
            Singularity.Shell.OsdOverlay.get_default().show_osd(
                audio.icon_name,
                audio.is_muted ? -1 : audio.volume
            );
        }

        private void switch_input_method() {
            var sources = Singularity.InputMethods.InputSources.get_default();
            if (sources.configured().length == 0) return;
            ulong handler = 0;
            handler = sources.changed.connect(() => {
                sources.disconnect(handler);
                Singularity.Shell.OsdOverlay.get_default().show_osd("input-keyboard-symbolic", -1,
                    sources.name_for(sources.current));
            });
            sources.cycle();
        }

        public void mic_mute() throws Error {
            var audio = SystemMonitor.get_default().audio;
            audio.toggle_input_mute();
            Singularity.Shell.OsdOverlay.get_default().show_osd(
                audio.input_muted ? "microphone-disabled-symbolic" : "audio-input-microphone-symbolic",
                audio.input_muted ? -1 : audio.input_volume
            );
        }

        public void brightness_up() throws Error {
            var b = SystemMonitor.get_default().brightness;
            b.step_up();
            Singularity.Shell.OsdOverlay.get_default().show_osd(
                "display-brightness-symbolic", b.brightness);
        }

        public void brightness_down() throws Error {
            var b = SystemMonitor.get_default().brightness;
            b.step_down();
            Singularity.Shell.OsdOverlay.get_default().show_osd(
                "display-brightness-symbolic", b.brightness);
        }

        public void kbd_brightness_up() throws Error {
            var k = SystemMonitor.get_default().kbd_brightness;
            k.step_up();
            Singularity.Shell.OsdOverlay.get_default().show_osd(
                "keyboard-brightness-symbolic", k.brightness);
        }

        public void kbd_brightness_down() throws Error {
            var k = SystemMonitor.get_default().kbd_brightness;
            k.step_down();
            Singularity.Shell.OsdOverlay.get_default().show_osd(
                "keyboard-brightness-symbolic", k.brightness);
        }

        public void toggle_launcher() throws Error {
            launcher_triggered();
        }

        public void spawn_terminal() throws Error {
            if (spawn_host_terminal()) return;

            // Try terminals in preference order
            string[] candidates = {
                "singularity-leafs",
                "singularity-terminal",
                "kgx",
                "gnome-terminal",
                "alacritty",
                "foot",
                "kitty",
                "xterm"
            };
            foreach (var cmd in candidates) {
                if (GLib.Environment.find_program_in_path(cmd) != null) {
                    try {
                        Process.spawn_command_line_async(cmd);
                        return;
                    } catch (Error e) {
                        continue;
                    }
                }
            }
            // Fall back to flatpak BlackBox if no native terminal found
            try {
                Process.spawn_command_line_async("flatpak run com.raggesilver.BlackBox");
            } catch (Error e) {
                warning("spawn_terminal: no terminal emulator found: %s", e.message);
            }
        }

        private bool spawn_host_terminal() {
            string? data_path = Environment.get_variable("CPAK_HOST_APPLICATIONS");
            if (data_path == null || data_path == "") return false;

            string applications_path = Path.build_filename(data_path, "applications");
            try {
                var directory = Dir.open(applications_path);
                string? name;
                while ((name = directory.read_name()) != null) {
                    if (!name.has_suffix(".desktop")) continue;
                    var info = new DesktopAppInfo.from_filename(
                        Path.build_filename(applications_path, name));
                    if (info == null) continue;
                    string? categories = info.get_categories();
                    if (categories == null || !(";" + categories + ";").contains(";TerminalEmulator;"))
                        continue;
                    if (ParentalEnforcer.get_default().hides(info.get_id())) continue;
                    try {
                        info.launch(null, Gdk.Display.get_default().get_app_launch_context());
                        return true;
                    } catch (Error e) {
                        continue;
                    }
                }
            } catch (Error e) {
                warning("spawn_terminal: failed to launch host terminal: %s", e.message);
            }
            return false;
        }

        // Run a command in a terminal, used as a fallback when GLib's
        // NEEDS_TERMINAL resolver finds no terminal it recognises. Honours the
        // same preference order as spawn_terminal() (singularity-leafs first),
        // passing the command with each terminal's exec syntax.
        public void spawn_terminal_with_command(string command) throws Error {
            string[] cmd_argv;
            try {
                GLib.Shell.parse_argv(command, out cmd_argv);
            } catch (Error e) {
                cmd_argv = { "sh", "-lc", command };
            }
            string[] candidates = {
                "singularity-leafs",
                "singularity-terminal",
                "kgx",
                "gnome-terminal",
                "alacritty",
                "foot",
                "kitty",
                "xterm"
            };
            foreach (var term in candidates) {
                if (GLib.Environment.find_program_in_path(term) == null) continue;
                string[] argv = build_terminal_argv(term, cmd_argv);
                try {
                    Process.spawn_async(null, argv, null,
                        SpawnFlags.SEARCH_PATH, null, null);
                    return;
                } catch (Error e) {
                    continue;
                }
            }
            warning("spawn_terminal_with_command: no terminal emulator found");
        }

        // Prepend the right exec flag for `term` to the command argv.
        private string[] build_terminal_argv(string term, string[] cmd_argv) {
            string mode;
            switch (term) {
                case "kgx":
                case "gnome-terminal":
                    mode = "--";   break;   // term -- cmd args
                case "foot":
                case "kitty":
                    mode = "bare"; break;   // term cmd args
                default:
                    mode = "-e";   break;   // term -e cmd args
            }
            string[] argv = { term };
            if (mode != "bare") argv += mode;
            foreach (var a in cmd_argv) argv += a;
            return argv;
        }

        public void run_command() throws Error {
            run_command_triggered();
        }

        public void retile_windows() throws Error {
            retile_triggered();
        }

        public void lock_screen() throws Error {
            SessionManager.get_default().lock_screen();
        }

        private void screenshot_tool_action() {
            var app = GLib.Application.get_default() as Gtk.Application;
            var tool = ScreenshotTool.get_default(app);
            if (tool.visible) {
                tool.close_dialog();
                return;
            }
            if (!tool.ensure_screenshots()) return;
            var handle = AppSystem.get_default().get_focused_window_handle();
            tool.prepare_for_invocation(handle);
            tool.open_dialog();
        }

        private void screenshot_region_action() {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (!ScreenshotTool.get_default(app).ensure_screenshots()) return;
            screenshot_interactive_action();
        }

        private void screenshot_window_action() {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (!ScreenshotTool.get_default(app).ensure_screenshots()) return;
            var handle = AppSystem.get_default().get_focused_window_handle();
            if (handle != null) {
                _screenshot_window(handle);
            } else {
                _screenshot_fullscreen();
            }
        }

        public void capture_fullscreen() {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (!ScreenshotTool.get_default(app).ensure_screenshots()) return;
            _screenshot_fullscreen();
        }

        public void capture_region(int x, int y, int width, int height) {
            if (width < 1 || height < 1) return;
            var app = GLib.Application.get_default() as Gtk.Application;
            if (!ScreenshotTool.get_default(app).ensure_screenshots()) return;
            string geometry = "%d,%d %dx%d".printf(x, y, width, height);
            _capture_geometry(geometry, "Region captured and copied to clipboard", false);
        }

        private void pip_window_action() {
            var handle = AppSystem.get_default().get_focused_window_handle();
            if (handle == null || !Singularity.wayland_show_window_pip(handle)) {
                warning("[PiP] no focused window or compositor support");
            }
        }

        private void pip_region_action() {
            if (pip_region_picker != null) return;
            string helper = AppSystem.resolve_companion_bin("singularity-region-picker");
            GLib.Subprocess picker;
            try {
                picker = new GLib.Subprocess(
                    GLib.SubprocessFlags.STDOUT_PIPE |
                    GLib.SubprocessFlags.STDERR_SILENCE,
                    helper);
            } catch (Error e) {
                warning("[PiP] failed to start region picker: %s", e.message);
                return;
            }
            pip_region_picker = picker;

            picker.communicate_utf8_async.begin(null, null, (obj, res) => {
                string? output = null;
                try {
                    picker.communicate_utf8_async.end(res, out output, null);
                } catch (Error e) {
                    pip_region_picker = null;
                    return;
                }
                pip_region_picker = null;
                if (!picker.get_if_exited() || picker.get_exit_status() != 0 ||
                        output == null) {
                    return;
                }
                int x, y, width, height;
                if (!parse_region_geometry(output, out x, out y,
                        out width, out height)) {
                    warning("[PiP] invalid region picker output: %s", output.strip());
                    return;
                }
                if (!Singularity.wayland_show_region_pip(x, y, width, height)) {
                    warning("[PiP] compositor protocol unavailable");
                }
            });
        }

        private bool parse_region_geometry(string value, out int x, out int y,
                out int width, out int height) {
            x = y = width = height = 0;
            string[] fields = value.strip().split(" ");
            if (fields.length != 2) return false;
            string[] position = fields[0].split(",");
            string[] size = fields[1].split("x");
            if (position.length != 2 || size.length != 2) return false;
            return int.try_parse(position[0], out x)
                && int.try_parse(position[1], out y)
                && int.try_parse(size[0], out width)
                && int.try_parse(size[1], out height)
                && width > 0 && height > 0;
        }

        private void _screenshot_window(void* handle) {
            int x, y, w, h, maximized, fullscreen;
            string? connector;
            bool got_geometry = Singularity.wayland_get_window_geometry(handle,
                out x, out y, out w, out h, out maximized, out fullscreen, out connector);
            if (!got_geometry || w <= 0 || h <= 0) {
                warning("[Screenshot] no valid focused window geometry, falling back");
                _screenshot_fullscreen();
                return;
            }

            string geometry = "%d,%d %dx%d".printf(x, y, w, h);
            _capture_geometry(geometry, "Window captured and copied to clipboard", true);
        }

        private void _capture_geometry(string geometry,
                                       string notification,
                                       bool fallback_fullscreen) {
            string temp_path;
            try {
                int fd = GLib.FileUtils.open_tmp("singularity-screenshot-XXXXXX.png", out temp_path);
                Posix.close(fd);
            } catch (Error e) {
                warning("[Screenshot] temp file: %s", e.message);
                if (fallback_fullscreen) _screenshot_fullscreen();
                return;
            }
            message("[Screenshot] Using singularity-screenshot -g \"%s\", %s",
                geometry, temp_path);
            try {
                string helper = AppSystem.resolve_companion_bin("singularity-screenshot");
                string[] argv = { helper, "-g", geometry, temp_path };
                var proc = new GLib.Subprocess.newv(argv,
                    GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE);
                proc.wait_check_async.begin(null, (obj, res) => {
                    bool ok = false;
                    try {
                        ok = proc.wait_check_async.end(res);
                    } catch (Error e) {
                        warning("[Screenshot] singularity-screenshot failed: %s", e.message);
                    }
                    if (!ok || !screenshot_file_has_data(temp_path)) {
                        GLib.FileUtils.unlink(temp_path);
                        if (fallback_fullscreen) _screenshot_fullscreen();
                        return;
                    }
                    var portal = ScreenshotPortal.get_default();
                    portal.copy_to_clipboard(temp_path);
                    portal.save_to_pictures("file://" + temp_path);
                    Singularity.Shell.ScreenFlash.flash();
                    var app_system = AppSystem.get_default();
                    string? focused_app = app_system.get_focused_app_id();
                    if (focused_app != null && focused_app != "")
                        app_system.pulse_app_requested(focused_app);
                    try {
                        Process.spawn_async(null,
                            { "notify-send", "Screenshot", notification },
                            null, SpawnFlags.SEARCH_PATH, null, null);
                    } catch {}
                    GLib.Timeout.add(3000, () => { GLib.FileUtils.unlink(temp_path); return false; });
                });
            } catch (Error e) {
                warning("[Screenshot] singularity-screenshot spawn failed: %s", e.message);
                GLib.FileUtils.unlink(temp_path);
                if (fallback_fullscreen) _screenshot_fullscreen();
            }
        }

        private bool screenshot_file_has_data(string path) {
            try {
                var info = File.new_for_path(path).query_info(
                    "standard::size", FileQueryInfoFlags.NONE, null);
                return info.get_size() > 0;
            } catch (Error e) {
                return false;
            }
        }

        private void _screenshot_fullscreen() {
            var portal = ScreenshotPortal.get_default();
            if (screenshot_handler_id != 0) {
                portal.disconnect(screenshot_handler_id);
                screenshot_handler_id = 0;
            }
            screenshot_handler_id = portal.screenshot_taken.connect((uri) => {
                if (screenshot_handler_id != 0) {
                    portal.disconnect(screenshot_handler_id);
                    screenshot_handler_id = 0;
                }
                var file = GLib.File.new_for_uri(uri);
                string? path = file.get_path();
                if (path != null) portal.copy_to_clipboard(path);
                portal.save_to_pictures(uri);
                Singularity.Shell.ScreenFlash.flash();
                string? focused_app = AppSystem.get_default().get_focused_app_id();
                if (focused_app != null && focused_app != "")
                    AppSystem.get_default().pulse_app_requested(focused_app);
                try {
                    Process.spawn_command_line_async("notify-send 'Screenshot' 'Saved and copied to clipboard'");
                } catch (Error e) {}
            });
            portal.take_screenshot.begin(false);
        }

        private void screenshot_interactive_action() {
            var portal = ScreenshotPortal.get_default();
            if (screenshot_handler_id != 0) {
                portal.disconnect(screenshot_handler_id);
                screenshot_handler_id = 0;
            }
            screenshot_handler_id = portal.screenshot_taken.connect((uri) => {
                if (screenshot_handler_id != 0) {
                    portal.disconnect(screenshot_handler_id);
                    screenshot_handler_id = 0;
                }
                var file = GLib.File.new_for_uri(uri);
                string? path = file.get_path();
                if (path != null) portal.copy_to_clipboard(path);
                portal.save_to_pictures(uri);
                Singularity.Shell.ScreenFlash.flash();
                try {
                    Process.spawn_command_line_async("notify-send 'Screenshot' 'Saved and copied to clipboard'");
                } catch (Error e) {}
            });
            portal.take_screenshot.begin(true);
        }
    }
}
