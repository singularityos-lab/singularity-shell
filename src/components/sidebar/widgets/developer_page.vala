using Gtk;
using Vte;
using Singularity.Widgets;

namespace Singularity {

    [DBus (name = "io.github.singularityos_lab.ush.Broker1")]
    interface UshBroker : Object {
        public abstract async void dev_shell_status (out string policy, out bool enabled) throws GLib.Error;
        public abstract async void set_dev_shell_enabled (bool enabled) throws GLib.Error;
        public abstract async void arm_bootloader_unlock (bool armed, string pin,
            out bool ok, out string message) throws GLib.Error;
        public abstract async void bootloader_lock_state (out bool locked,
            out bool unlock_armed, out int unlock_count) throws GLib.Error;
        public abstract async void sdb_status (out bool available, out bool active,
            out string message) throws GLib.Error;
        public abstract async void set_sdb_enabled (bool enabled, out bool ok,
            out bool active, out string message) throws GLib.Error;
    }

    public class DeveloperPage : SettingsPage {

        private static string LOG_FILE = GLib.Path.build_filename(
            GLib.Environment.get_user_state_dir(), "singularity", "singularity-desktop.log");

        /* Live-state labels (updated by timer) */
        private class ProcLabels {
            public Label pid;
            public Label cpu;
            public Label mem;
        }

        private Label _focused_val;
        private Label _wins_val;
        private Label _running_val;
        private Label _wallpaper_val;
        private Label _total_cpu_val;
        private Label _total_mem_val;
        private Gee.HashMap<string, ProcLabels> _proc_labels_map;

        /* Vte log terminal */
        private Vte.Terminal? _terminal = null;

        /* Signal handler IDs that must be disconnected on dispose */
        private ulong _sig_dbg_mode   = 0;
        private ulong _sig_hud        = 0;
        private ulong _sig_devtools   = 0;
        private ulong _sig_log        = 0;

        /* Refresh timer (only runs while page is mapped) */
        private uint _timer_id = 0;

        /* Optional per-display CSS provider for widget-border debug mode */
        private Gtk.CssProvider? _border_css = null;

        /* GSettings for tiling (kept alive as field) */
        private GLib.Settings _tiling_settings;

        private PreferencesGroup dsh_group;

        private SettingsView _view;
        private SwitchRow _unlock_switch;
        private Label _unlock_error;
        private bool _unlock_guard = false;

        private PreferencesGroup _sdb_group;
        private SwitchRow _sdb_switch;
        private Label _sdb_error;
        private PreferencesGroup _sdb_pairing_group;
        private Label _sdb_code;
        private Label _sdb_expiry;
        private Label _sdb_fingerprint;
        private Label _sdb_fp_caption;
        private Label _sdb_attempts;
        private Label _sdb_pair_host;
        private ActionRow _sdb_device_row;
        private Label _sdb_device_fp;
        private ActionRow _sdb_pair_row;
        private Button _sdb_pair_btn;
        private PreferencesGroup _sdb_hosts_group;
        private string _sdb_hosts_signature = "";
        private bool _sdb_guard = false;
        private bool _sdb_refreshing = false;
        private uint _sdb_timer_id = 0;

        public DeveloperPage (SettingsView view) {
            base(_("Developer"));
            _view = view;

            dsh_group = new PreferencesGroup (_("Developer Shell"));
            dsh_group.visible = false;
            add_group (dsh_group);
            setup_dev_shell.begin ();

            var dbg = DebugManager.get_default ();
            _tiling_settings = new GLib.Settings ("dev.sinty.desktop");

            // Consent only: nothing is unlocked here. Recovery performs the unlock
            // later and refuses unless this flag is set. Turning it on re-authenticates
            // with the current PIN; turning it off never does, so consent can always
            // be revoked. The broker socket is the tell that we run on Sinty OS.
            if (Singularity.Runtime.is_sinty_os ()) {
                var boot_group = new PreferencesGroup (_("Bootloader"));
                _unlock_switch = new SwitchRow (_("Allow bootloader unlock"),
                    _("Lets the recovery environment unlock the bootloader. Unlocking erases all data and disables verified boot."));
                _unlock_switch.switch_btn.notify["active"].connect (on_unlock_toggled);
                boot_group.add_row (_unlock_switch);
                add_group (boot_group);

                _unlock_error = new Label ("");
                _unlock_error.add_css_class ("error");
                _unlock_error.wrap = true;
                _unlock_error.visible = false;
                _unlock_error.margin_start = 16;
                _unlock_error.margin_end = 16;
                _unlock_error.halign = Gtk.Align.START;
                var unlock_err_wrapper = new Box (Orientation.VERTICAL, 0);
                unlock_err_wrapper.append (_unlock_error);
                add_widget (unlock_err_wrapper);

                // The agent is the source of truth, so re-read it every time the page
                // is shown rather than trusting the mirrored key.
                this.map.connect (() => { refresh_unlock_state.begin (); });

                build_sdb_ui ();
                this.map.connect (() => refresh_sdb_state.begin ());
            }

            // Debug Control
            var debug_group = new PreferencesGroup (_("Debug"));
            debug_group.description = "Runtime instrumentation and overlay tools";

            var dbg_switch = new SwitchRow (_("Debug Mode"),
                "Enable verbose logging and activate debug sections");
            dbg_switch.active = dbg.debug_mode;
            _sig_dbg_mode = dbg.notify["debug-mode"].connect (() => {
                dbg_switch.active = dbg.debug_mode;
            });
            dbg_switch.switch_btn.notify["active"].connect (() => {
                dbg.debug_mode = dbg_switch.switch_btn.active;
            });
            debug_group.add_row (dbg_switch);

            var hud_switch = new SwitchRow (_("Show HUD Overlay"),
                "Floating live-stats panel above the shell");
            hud_switch.active = dbg.hud_visible;
            _sig_hud = dbg.notify["hud-visible"].connect (() => {
                hud_switch.active = dbg.hud_visible;
            });
            hud_switch.switch_btn.notify["active"].connect (() => {
                dbg.hud_visible = hud_switch.switch_btn.active;
            });
            debug_group.add_row (hud_switch);

            var devtools_switch = new SwitchRow (_("DevTools Overlay"),
                "Modular inspector: live values, widget tree, realtime events");
            devtools_switch.active = dbg.devtools_visible;
            _sig_devtools = dbg.notify["devtools-visible"].connect (() => {
                devtools_switch.active = dbg.devtools_visible;
            });
            devtools_switch.switch_btn.notify["active"].connect (() => {
                dbg.devtools_visible = devtools_switch.switch_btn.active;
            });
            debug_group.add_row (devtools_switch);

            var pin_switch = new SwitchRow (_("Keep Sidebar Open"),
                "Prevent sidebar from closing when focus is lost");
            pin_switch.active = dbg.sidebar_pinned;
            pin_switch.switch_btn.notify["active"].connect (() => {
                dbg.sidebar_pinned = pin_switch.switch_btn.active;
            });
            debug_group.add_row (pin_switch);

            var pin_overview = new SwitchRow (_("Keep Overview Open"),
                "Prevent the apps overview from closing when focus is lost (for screenshots)");
            pin_overview.active = dbg.overview_pinned;
            pin_overview.switch_btn.notify["active"].connect (() => {
                dbg.overview_pinned = pin_overview.switch_btn.active;
            });
            debug_group.add_row (pin_overview);

            var pin_workspaces = new SwitchRow (_("Keep Workspaces Open"),
                "Prevent the workspaces overview from closing when focus is lost (for screenshots)");
            pin_workspaces.active = dbg.workspaces_pinned;
            pin_workspaces.switch_btn.notify["active"].connect (() => {
                dbg.workspaces_pinned = pin_workspaces.switch_btn.active;
            });
            debug_group.add_row (pin_workspaces);

            add_group (debug_group);

            // GTK Rendering Tools
            var gtk_group = new PreferencesGroup (_("GTK Rendering Tools"));

            var inspector_row = new ActionRow (_("Open GTK Inspector"),
                "Inspect widget tree, CSS nodes and render tree",
                "applications-engineering-symbolic");
            var inspector_btn = new Button.with_label (_("Open"));
            inspector_btn.valign = Gtk.Align.CENTER;
            inspector_btn.add_css_class ("pill");
            inspector_btn.clicked.connect (() => {
                Gtk.Window.set_interactive_debugging (true);
            });
            inspector_row.add_suffix (inspector_btn);
            inspector_row.activated.connect (() => {
                Gtk.Window.set_interactive_debugging (true);
            });
            gtk_group.add_row (inspector_row);

            var anim_switch = new SwitchRow (_("Enable Animations"),
                "Toggle GTK animation system-wide");
            anim_switch.active = Gtk.Settings.get_default ().gtk_enable_animations;
            anim_switch.switch_btn.notify["active"].connect (() => {
                Gtk.Settings.get_default ().gtk_enable_animations = anim_switch.switch_btn.active;
            });
            gtk_group.add_row (anim_switch);

            var borders_switch = new SwitchRow (_("Show Widget Borders"),
                "Overlay accent-colored borders on every widget");
            borders_switch.switch_btn.notify["active"].connect (() => {
                toggle_widget_borders (borders_switch.switch_btn.active);
            });
            gtk_group.add_row (borders_switch);

            add_group (gtk_group);

            // App System
            var as_expander = new ExpanderRow (_("App System"),
                "Windows, running apps, focus state",
                "application-x-executable-symbolic");

            _focused_val  = make_val_label ("-");
            _wins_val     = make_val_label ("0");
            _running_val  = make_val_label ("0");

            as_expander.add_row (make_kv_row ("Focused App",   _focused_val));
            as_expander.add_row (make_kv_row ("Open Windows",  _wins_val));
            as_expander.add_row (make_kv_row ("Running Apps",  _running_val));

            var reload_apps = new ActionRow (_("Force apps-changed Signal"), null,
                "view-refresh-symbolic");
            reload_apps.activated.connect (() => {
                AppSystem.get_default ().apps_changed ();
            });
            as_expander.add_row (reload_apps);

            var appsys_group = new PreferencesGroup (_("App System"));
            appsys_group.add_row (as_expander);
            add_group (appsys_group);

            // Wallpaper Manager
            var wp_expander = new ExpanderRow (_("Wallpaper Manager"),
                "Current wallpaper and reload controls",
                "image-x-generic-symbolic");

            _wallpaper_val = make_val_label ("-");
            _wallpaper_val.ellipsize = Pango.EllipsizeMode.MIDDLE;
            _wallpaper_val.max_width_chars = 26;
            wp_expander.add_row (make_kv_row ("Current Path", _wallpaper_val));

            var wp_reload = new ActionRow (_("Reload Wallpaper"), null, "view-refresh-symbolic");
            wp_reload.activated.connect (() => {
                WallpaperManager.get_default ().reload ();
            });
            wp_expander.add_row (wp_reload);

            var wp_group = new PreferencesGroup (_("Wallpaper"));
            wp_group.add_row (wp_expander);
            add_group (wp_group);

            // Tiling Manager
            var tiling_group = new PreferencesGroup (_("Tiling Manager"));

            var tiling_switch = new SwitchRow (_("Auto-Tiling"),
                "Automatically tile windows on the active workspace");
            tiling_switch.active = _tiling_settings.get_boolean ("tiling-enabled");
            tiling_switch.switch_btn.notify["active"].connect (() => {
                _tiling_settings.set_boolean ("tiling-enabled", tiling_switch.switch_btn.active);
            });
            tiling_group.add_row (tiling_switch);

            var retile_row = new ActionRow (_("Apply Layout Now"), null, "view-grid-symbolic");
            retile_row.activated.connect (() => {
                DebugManager.get_default ().tiling_manager?.apply_layout ();
            });
            tiling_group.add_row (retile_row);

            add_group (tiling_group);

            // Hot Corners
            var hc_group = new PreferencesGroup (_("Hot Corners"));
            hc_group.description = "Simulate corner triggers programmatically";

            string[] corner_labels = { "Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right" };
            string[] corner_icons  = {
                "go-up-symbolic", "go-up-symbolic",
                "go-down-symbolic", "go-down-symbolic"
            };
            for (int i = 0; i < 4; i++) {
                int idx = i;
                var row = new ActionRow (
                    "Trigger %s Corner".printf (corner_labels[i]),
                    null, corner_icons[i]);
                var btn = new Button.with_label (_("Trigger"));
                btn.valign = Gtk.Align.CENTER;
                btn.add_css_class ("pill");
                btn.clicked.connect (() => {
                    DebugManager.get_default ().hot_corner_manager?.simulate_corner (idx);
                });
                row.add_suffix (btn);
                hc_group.add_row (row);
            }
            add_group (hc_group);

            // Desktop Resources
            var dr_group = new PreferencesGroup (_("Desktop Resources"));
            dr_group.description = "CPU/RAM usage for desktop processes";

            var cpu_val = make_val_label ("0.0%");
            var mem_val = make_val_label ("0 MB");
            _total_cpu_val = cpu_val;
            _total_mem_val = mem_val;

            var procs_box = new Box (Orientation.VERTICAL, 0);
            procs_box.add_css_class ("linked");
            procs_box.margin_top = 6;
            procs_box.margin_bottom = 6;
            dr_group.add_row (procs_box);

            _proc_labels_map = new Gee.HashMap<string, ProcLabels> ();
            // Add process rows
            string[] desktop_procs = {
                "singularity-pol",
                "singularity-desktop",
                "labwc"
            };

            foreach (string proc in desktop_procs) {
                var row = new ActionRow (proc, null);
                var pid_val = make_val_label ("-");
                var cpu_val_proc = make_val_label ("0.0%");
                var mem_val_proc = make_val_label ("0 MB");

                row.add_suffix (pid_val);
                row.add_suffix (cpu_val_proc);
                row.add_suffix (mem_val_proc);

                procs_box.append (row);
                _proc_labels_map.set (proc, new ProcLabels () { pid = pid_val, cpu = cpu_val_proc, mem = mem_val_proc });
            }

            // Add total row
            var total_row = new ActionRow (_("TOTAL"), null);
            total_row.add_css_class ("bold");
            var lbl_total_cpu = make_val_label ("0.0%");
            var lbl_total_mem = make_val_label ("0 MB");
            _total_cpu_val = lbl_total_cpu;
            _total_mem_val = lbl_total_mem;
            total_row.add_suffix (lbl_total_cpu);
            total_row.add_suffix (lbl_total_mem);
            procs_box.append (total_row);

            add_group (dr_group);

            // Notifications
            var notif_group = new PreferencesGroup (_("Notifications"));

            var test_notif = new ActionRow (_("Send Test Notification"),
                "Bypass DND and inject directly into the notification display",
                "dialog-information-symbolic");
            test_notif.activated.connect (() => {
                // Emit new_notification directly to bypass DND for debug purposes
                SystemMonitor.get_default ().notifications.new_notification (
                    999999u, "Singularity Debug",
                    "Debug Test Notification",
                    "Sent from the Developer Debug Panel.",
                    "dialog-information", new string[0]);
            });
            notif_group.add_row (test_notif);

            add_group (notif_group);

            // XDG Portal
            var portal_group = new PreferencesGroup (_("XDG Portal"));
            portal_group.description = "Test connectivity with the Singularity Portal backend";

            var portal_status_val = make_val_label ("Unknown");
            var portal_status_row = make_kv_row ("Portal Backend Status", portal_status_val);

            var check_portal_btn = new Button.with_label (_("Check"));
            check_portal_btn.valign = Gtk.Align.CENTER;
            check_portal_btn.add_css_class ("pill");
            check_portal_btn.clicked.connect (() => {
                check_portal_status (portal_status_val);
            });
            portal_status_row.add_suffix (check_portal_btn);
            portal_group.add_row (portal_status_row);

            var test_screenshot_row = new ActionRow (_("Test Screenshot Portal"),
                "Trigger a screenshot request via XDG Desktop Portal",
                "camera-photo-symbolic");
            var screenshot_btn = new Button.with_label (_("Trigger"));
            screenshot_btn.valign = Gtk.Align.CENTER;
            screenshot_btn.add_css_class ("pill");
            screenshot_btn.clicked.connect (() => {
                ScreenshotPortal.get_default ().take_screenshot.begin (true);
            });
            test_screenshot_row.add_suffix (screenshot_btn);
            portal_group.add_row (test_screenshot_row);

            var test_chooser_row = new ActionRow (_("Test App Chooser"),
                "Trigger the application selection dialog via XDG Portal",
                "application-x-executable-symbolic");
            var chooser_btn = new Button.with_label (_("Trigger"));
            chooser_btn.valign = Gtk.Align.CENTER;
            chooser_btn.add_css_class ("pill");
            chooser_btn.clicked.connect (() => {
                test_app_chooser.begin ();
            });
            test_chooser_row.add_suffix (chooser_btn);
            portal_group.add_row (test_chooser_row);

            add_group (portal_group);

            // Window Preview
            var preview_group = new PreferencesGroup (_("Window Preview"));

            var preview_image = new Picture ();
            preview_image.content_fit = ContentFit.CONTAIN;
            preview_image.height_request = 180;
            preview_image.add_css_class ("workspace-preview");

            var preview_row = new ActionRow (_("First Window"), null, "view-app-grid-symbolic");
            var preview_btn = new Button.with_label (_("Capture"));
            preview_btn.valign = Gtk.Align.CENTER;
            preview_btn.add_css_class ("pill");
            preview_btn.clicked.connect (() => {
                capture_window_preview (preview_image);
            });
            preview_row.add_suffix (preview_btn);
            preview_group.add_row (preview_row);
            preview_group.add_row (preview_image);

            add_group (preview_group);

            // Shell Log
            var log_expander = new ExpanderRow (_("Shell Log"),
                "Live tail of " + LOG_FILE,
                "utilities-terminal-symbolic");
            log_expander.expanded = false;

            // Feed DebugManager log() calls into the terminal
            _sig_log = DebugManager.get_default ().log_message.connect ((module, level, msg) => {
                if (_terminal != null)
                    _terminal.feed ("[%s][%s] %s\r\n".printf (level, module, msg).data);
            });

            var log_btns = new Box (Orientation.HORIZONTAL, 6);
            log_btns.halign = Gtk.Align.END;
            log_btns.margin_end    = 8;
            log_btns.margin_top    = 4;
            log_btns.margin_bottom = 4;
            var clear_btn = new Button.with_label (_("Clear"));
            clear_btn.add_css_class ("pill");
            clear_btn.clicked.connect (() => ensure_terminal (log_expander).reset (true, true));
            var restart_log_btn = new Button.with_label (_("Restart Tail"));
            restart_log_btn.add_css_class ("pill");
            restart_log_btn.clicked.connect (() => start_tail (log_expander));

            // Restart Shell - must be a Button (ActionRow.activated won't fire in Box)
            var restart_shell_btn = new Button.with_label (_("Restart Shell"));
            restart_shell_btn.add_css_class ("pill");
            restart_shell_btn.add_css_class ("destructive-action");
            restart_shell_btn.clicked.connect (() => {
                Posix.kill ((Posix.pid_t) Posix.getpid (), Posix.Signal.USR1);
            });

            log_btns.append (clear_btn);
            log_btns.append (restart_log_btn);
            log_btns.append (restart_shell_btn);
            log_expander.add_row (log_btns);

            var log_group = new PreferencesGroup (_("Diagnostics"));
            log_group.add_row (log_expander);
            add_group (log_group);

            log_expander.notify["expanded"].connect (() => {
                if (log_expander.expanded && _terminal == null)
                    start_tail (log_expander);
            });
            update_live_labels ();
            update_desktop_resources ();

            map.connect (() => { start_update_timer (); start_sdb_timer (); });
            unmap.connect (() => { stop_update_timer (); stop_sdb_timer (); });
        }

        // Helpers

        private Label make_val_label (string text) {
            var lbl = new Label (text);
            lbl.halign = Gtk.Align.END;
            lbl.hexpand = true;
            lbl.add_css_class ("caption");
            return lbl;
        }

        private ActionRow make_kv_row (string key, Widget value_widget) {
            var row = new ActionRow (key, null);
            row.add_suffix (value_widget);
            return row;
        }

        private void check_portal_status (Label status_label) {
            status_label.set_text ("Checking...");
            try {
                var conn = Bus.get_sync (BusType.SESSION);
                var proxy = new GLib.DBusProxy.for_bus_sync (
                    BusType.SESSION,
                    DBusProxyFlags.NONE,
                    null,
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus"
                );

                var result = proxy.call_sync (
                    "GetNameOwner",
                    new Variant ("(s)", "org.freedesktop.impl.portal.desktop.singularity"),
                    DBusCallFlags.NONE,
                    -1,
                    null
                );

                if (result != null) {
                    string owner;
                    result.get ("(s)", out owner);
                    status_label.set_text ("Active (%s)".printf (owner));
                }
            } catch (Error e) {
                status_label.set_text ("Inactive (Not Running)");
            }
        }

        private async void test_app_chooser () {
            try {
                var conn = yield Bus.get (BusType.SESSION);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                
                // Add some dummy choices to force the dialog to appear
                string[] choices = { "org.gnome.TextEditor", "dev.sinty.edit", "firefox" };
                options.add ("{sv}", "choices", new Variant.strv (choices));
                options.add ("{sv}", "heading", new Variant.string ("Test Portal App Chooser"));

                yield conn.call (
                    "org.freedesktop.portal.Desktop",
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.AppChooser",
                    "OpenAppChooser",
                    new Variant ("(ssa{sv})", "", "", options),
                    null,
                    DBusCallFlags.NONE,
                    -1,
                    null
                );
            } catch (Error e) {
                warning ("Failed to trigger AppChooser portal: %s", e.message);
            }
        }

        // Widget borders debug CSS

        private void toggle_widget_borders (bool on) {
            if (on) {
                if (_border_css == null) {
                    _border_css = new Gtk.CssProvider ();
                    _border_css.load_from_string (
                        "* { box-shadow: inset 0 0 0 1px alpha(@accent_color, 0.55); }");
                }
                Gtk.StyleContext.add_provider_for_display (
                    Gdk.Display.get_default (), _border_css,
                    Gtk.STYLE_PROVIDER_PRIORITY_USER + 100);
            } else if (_border_css != null) {
                Gtk.StyleContext.remove_provider_for_display (
                    Gdk.Display.get_default (), _border_css);
            }
        }

        // Live label refresh

        private void update_live_labels () {
            var as = AppSystem.get_default ();
            _focused_val.set_text (as.get_focused_app_id () ?? "-");
            _wins_val.set_text (as.get_windows ().length ().to_string ());
            _running_val.set_text (as.get_running_apps ().length ().to_string ());

            var wp = WallpaperManager.get_default ().wallpaper_path;
            _wallpaper_val.set_text (wp != null ? GLib.Path.get_basename (wp) : "-");
        }

        // Desktop Resources

        private void update_desktop_resources () {
            if (_total_cpu_val == null || _total_mem_val == null || _proc_labels_map == null) return;

            try {
                double total_cpu = 0.0;
                double total_mem = 0.0;
                var seen = new Gee.HashSet<string> ();

                string ps_output;
                int exit_status;
                GLib.Process.spawn_command_line_sync (
                    "ps -eo pid=,pcpu=,rss=,comm= --sort=-rss",
                    out ps_output, null, out exit_status);
                if (exit_status != 0 || ps_output == null || ps_output.strip () == "") {
                    _total_cpu_val.set_text ("0.0%");
                    _total_mem_val.set_text ("0 MB");
                    return;
                }

                string[] lines = ps_output.strip ().split ("\n");

                foreach (string raw_line in lines) {
                    string line = raw_line.strip ();
                    if (line == "") continue;

                    while (line.contains ("  "))
                        line = line.replace ("  ", " ");

                    string[] parts = line.split (" ", 4);
                    if (parts.length < 4) continue;

                    int pid = int.parse (parts[0]);
                    double cpu = double.parse (parts[1]);
                    double rss_kb = double.parse (parts[2]);
                    double mem = rss_kb / 1024.0;
                    string comm = parts[3];

                    string matched_proc = null;
                    if (comm == "labwc") {
                        matched_proc = "labwc";
                    } else if (comm.has_prefix ("singularity-pol")) {
                        matched_proc = "singularity-pol";
                    } else if (comm.has_prefix ("singularity-des")) {
                        matched_proc = "singularity-desktop";
                    }
                    if (matched_proc == null) continue;
                    if (seen.contains (matched_proc)) continue;
                    seen.add (matched_proc);

                    if (_proc_labels_map.has_key (matched_proc)) {
                        var labels = _proc_labels_map.get (matched_proc);
                        labels.pid.set_text (pid.to_string ());
                        labels.mem.set_text ("%.1f MB".printf (mem));
                        labels.cpu.set_text ("%.2f%%".printf (cpu));
                        total_mem += mem;
                        total_cpu += cpu;
                    }
                }

                _total_cpu_val.set_text ("%.1f%%".printf (total_cpu));
                _total_mem_val.set_text ("%.1f MB".printf (total_mem));
            } catch (Error e) {
                warning ("Failed to update desktop resources: %s", e.message);
                _total_cpu_val.set_text ("0.0%");
                _total_mem_val.set_text ("0 MB");
            }
        }

        private void start_update_timer () {
            if (_timer_id != 0) return;
            update_live_labels ();
            update_desktop_resources ();
            _timer_id = Timeout.add (2000, () => {
                update_live_labels ();
                update_desktop_resources ();
                return Source.CONTINUE;
            });
        }

        private void stop_update_timer () {
            if (_timer_id != 0) {
                Source.remove (_timer_id);
                _timer_id = 0;
            }
        }

        // Window preview

        private void capture_window_preview (Picture target) {
            var windows = AppSystem.get_default ().get_windows ();
            if (windows.length () == 0) return;
            var win = windows.nth_data (0);
            Singularity.wayland_capture_preview (win.handle, (w, h, s, data) => {
                if (data == null) return;
                unowned uint8[] buf = (uint8[]) data;
                buf.length = h * s;
                var bytes   = new Bytes (buf);
                var texture = new Gdk.MemoryTexture (
                    w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, s);
                target.set_paintable (texture);
            });
        }

        // Log tail

        private Vte.Terminal ensure_terminal (ExpanderRow log_expander) {
            if (_terminal != null)
                return _terminal;

            _terminal = new Vte.Terminal ();
            _terminal.set_size (80, 16);
            _terminal.height_request = 220;
            _terminal.vexpand = false;
            _terminal.hexpand = true;
            var bg = Gdk.RGBA (); bg.parse ("#1e1e1e");
            var fg = Gdk.RGBA (); fg.parse ("#ffffff");
            _terminal.set_color_background (bg);
            _terminal.set_color_foreground (fg);
            log_expander.add_row (_terminal);
            return _terminal;
        }

        private void start_tail (ExpanderRow log_expander) {
            try {
                var terminal = ensure_terminal (log_expander);
                terminal.reset (true, true);
                string[] argv = { "/usr/bin/tail", "-f", LOG_FILE };
                terminal.spawn_async (PtyFlags.DEFAULT, null, argv, null,
                    SpawnFlags.SEARCH_PATH, null, -1, null,
                    (term, pid, err) => {
                        if (err != null)
                            terminal.feed (
                                "Failed to start log tail: %s\r\n"
                                .printf (err.message).data);
                    });
            } catch (Error e) {
                warning ("Error starting tail: %s", e.message);
            }
        }

        // Lifecycle

        protected override void dispose () {
            stop_update_timer ();
            stop_sdb_timer ();
            var dbg = DebugManager.get_default ();
            if (_sig_dbg_mode != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_dbg_mode);
                _sig_dbg_mode = 0;
            }
            if (_sig_hud != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_hud);
                _sig_hud = 0;
            }
            if (_sig_devtools != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_devtools);
                _sig_devtools = 0;
            }
            if (_sig_log != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_log);
                _sig_log = 0;
            }
            if (_border_css != null) {
                Gtk.StyleContext.remove_provider_for_display (
                    Gdk.Display.get_default (), _border_css);
                _border_css = null;
            }
            base.dispose ();
        }

        private async void setup_dev_shell () {
            try {
                UshBroker broker = yield Bus.get_proxy (BusType.SESSION,
                    "io.github.singularityos_lab.ush.Broker",
                    "/io/github/singularityos_lab/ush/Broker");
                string policy;
                bool enabled;
                yield broker.dev_shell_status (out policy, out enabled);
                build_dsh_ui (broker, policy, enabled);
                dsh_group.visible = true;
            } catch (GLib.Error e) {
            }
        }

        private void build_dsh_ui (UshBroker broker, string policy, bool enabled) {
            if (policy == "forbidden") {
                dsh_group.add_row (new ActionRow (_("Developer Shell"),
                    _("Disabled by your device or organization policy"),
                    "changes-prevent-symbolic"));
                return;
            }
            var sw = new SwitchRow (_("Developer Shell"),
                "Run isolated developer containers (dsh) from the terminal");
            sw.active = enabled;
            if (policy == "enabled") {
                sw.sensitive = false;
            } else {
                sw.switch_btn.notify["active"].connect (() => {
                    apply_dev_shell.begin (broker, sw.switch_btn.active);
                });
            }
            dsh_group.add_row (sw);
        }

        private async void apply_dev_shell (UshBroker broker, bool en) {
            try {
                yield broker.set_dev_shell_enabled (en);
            } catch (GLib.Error e) {
                warning ("set_dev_shell_enabled: %s", e.message);
            }
        }

        private void on_unlock_toggled () {
            if (_unlock_guard) return;
            if (!_unlock_switch.switch_btn.active) {
                disarm_unlock.begin ();
                return;
            }
            // Stays off until the broker confirms the flag was actually armed.
            set_unlock_switch (false);
            show_unlock_error (null);
            _view.open_subpage (new BootloaderUnlockPage (_view, _tiling_settings),
                "bootloader-unlock");
        }

        // Revoking needs no PIN, but it must not appear to have worked while the
        // authoritative flag is still armed.
        private async void disarm_unlock () {
            string message;
            if (yield BootloaderConsent.arm (false, "", out message)) {
                _tiling_settings.set_boolean ("bootloader-unlock-allowed", false);
                show_unlock_error (null);
            } else {
                set_unlock_switch (true);
                show_unlock_error (
                    _("Consent could not be revoked, so unlocking is still allowed. %s")
                        .printf (message));
            }
        }

        private async void refresh_unlock_state () {
            bool armed;
            if (yield BootloaderConsent.lock_state (out armed)) {
                set_unlock_switch (armed);
                _tiling_settings.set_boolean ("bootloader-unlock-allowed", armed);
                show_unlock_error (null);
            } else {
                set_unlock_switch (false);
                show_unlock_error (
                    _("The security service is not available, so the consent state cannot be confirmed."));
            }
        }

        private void show_unlock_error (string? message) {
            if (_unlock_error == null) return;
            _unlock_error.label = message ?? "";
            _unlock_error.visible = message != null;
        }

        private void set_unlock_switch (bool active) {
            _unlock_guard = true;
            _unlock_switch.switch_btn.active = active;
            _unlock_guard = false;
        }

        private void build_sdb_ui () {
            _sdb_group = new PreferencesGroup (_("Debug bridge"));
            _sdb_group.description = _("Lets a paired development machine connect over the network for a shell, file transfer and logs. Privileged actions still ask for approval one by one.");

            _sdb_switch = new SwitchRow (_("Debug bridge"),
                _("A host must be paired with a code shown on this screen before it can connect"));
            _sdb_switch.switch_btn.notify["active"].connect (on_sdb_toggled);
            _sdb_group.add_row (_sdb_switch);
            add_group (_sdb_group);

            _sdb_error = new Label ("");
            _sdb_error.add_css_class ("error");
            _sdb_error.wrap = true;
            _sdb_error.visible = false;
            _sdb_error.margin_start = 16;
            _sdb_error.margin_end = 16;
            _sdb_error.halign = Gtk.Align.START;
            var sdb_err_wrapper = new Box (Orientation.VERTICAL, 0);
            sdb_err_wrapper.append (_sdb_error);
            add_widget (sdb_err_wrapper);

            _sdb_device_row = new ActionRow (_("This device fingerprint"), null,
                "fingerprint-symbolic");
            _sdb_device_fp = new Label ("");
            _sdb_device_fp.selectable = true;
            _sdb_device_fp.halign = Gtk.Align.END;
            _sdb_device_fp.hexpand = true;
            _sdb_device_fp.wrap = true;
            _sdb_device_fp.wrap_mode = Pango.WrapMode.WORD_CHAR;
            _sdb_device_fp.justify = Justification.RIGHT;
            _sdb_device_fp.add_css_class ("monospace");
            _sdb_device_fp.add_css_class ("caption");
            _sdb_device_row.add_suffix (_sdb_device_fp);
            _sdb_device_row.visible = false;
            _sdb_group.add_row (_sdb_device_row);

            _sdb_pair_row = new ActionRow (_("Pair a new host"),
                _("Shows a code on this screen for a development machine to type"),
                "list-add-symbolic");
            _sdb_pair_btn = new Button.with_label (_("Start"));
            _sdb_pair_btn.valign = Gtk.Align.CENTER;
            _sdb_pair_btn.add_css_class ("pill");
            _sdb_pair_btn.clicked.connect (() => {
                string message;
                if (SdbAgent.pairing_start (out message)) {
                    show_sdb_error (null);
                    refresh_sdb_bridge ();
                } else {
                    show_sdb_error (_("Pairing could not be started. %s").printf (message));
                }
            });
            _sdb_pair_row.add_suffix (_sdb_pair_btn);
            _sdb_pair_row.visible = false;
            _sdb_group.add_row (_sdb_pair_row);

            _sdb_pairing_group = new PreferencesGroup (_("Pairing request"));
            _sdb_pairing_group.description = _("Type this code on the host. Before you do, check that the key fingerprint below is the same one the host is showing you. If it differs, do not pair.");
            _sdb_pairing_group.visible = false;

            _sdb_pair_host = new Label ("");
            _sdb_pair_host.wrap = true;
            _sdb_pair_host.halign = Gtk.Align.CENTER;
            _sdb_pair_host.add_css_class ("dim-label");
            _sdb_pair_host.visible = false;

            _sdb_code = new Label ("");
            _sdb_code.halign = Gtk.Align.CENTER;
            _sdb_code.selectable = true;
            _sdb_code.add_css_class ("large-title");
            _sdb_code.add_css_class ("monospace");

            _sdb_expiry = new Label ("");
            _sdb_expiry.halign = Gtk.Align.CENTER;
            _sdb_expiry.wrap = true;
            _sdb_expiry.add_css_class ("caption");
            _sdb_expiry.add_css_class ("dim-label");

            _sdb_fp_caption = new Label (_("Host key fingerprint"));
            _sdb_fp_caption.halign = Gtk.Align.CENTER;
            _sdb_fp_caption.add_css_class ("heading");

            _sdb_fingerprint = new Label ("");
            _sdb_fingerprint.halign = Gtk.Align.CENTER;
            _sdb_fingerprint.justify = Justification.CENTER;
            _sdb_fingerprint.wrap = true;
            _sdb_fingerprint.wrap_mode = Pango.WrapMode.WORD_CHAR;
            _sdb_fingerprint.selectable = true;
            _sdb_fingerprint.add_css_class ("monospace");
            _sdb_fingerprint.add_css_class ("caption");

            _sdb_attempts = new Label ("");
            _sdb_attempts.halign = Gtk.Align.CENTER;
            _sdb_attempts.wrap = true;
            _sdb_attempts.add_css_class ("caption");
            _sdb_attempts.visible = false;

            var cancel_btn = new Button.with_label (_("Cancel pairing"));
            cancel_btn.halign = Gtk.Align.CENTER;
            cancel_btn.add_css_class ("pill");
            cancel_btn.clicked.connect (() => {
                string message;
                if (SdbAgent.pairing_cancel (out message)) {
                    show_sdb_error (null);
                } else {
                    show_sdb_error (
                        _("Pairing could not be cancelled, so the code may still be accepted. %s")
                            .printf (message));
                }
                refresh_sdb_bridge ();
            });

            var pair_box = new Box (Orientation.VERTICAL, 8);
            pair_box.margin_start = 16;
            pair_box.margin_end = 16;
            pair_box.margin_top = 12;
            pair_box.margin_bottom = 12;
            pair_box.append (_sdb_pair_host);
            pair_box.append (_sdb_code);
            pair_box.append (_sdb_expiry);
            pair_box.append (_sdb_fp_caption);
            pair_box.append (_sdb_fingerprint);
            pair_box.append (_sdb_attempts);
            pair_box.append (cancel_btn);
            _sdb_pairing_group.add_row (pair_box);
            add_group (_sdb_pairing_group);

            _sdb_hosts_group = new PreferencesGroup (_("Paired hosts"));
            _sdb_hosts_group.description = _("Hosts allowed to connect to this device. Revoking a host takes effect at once and it must pair again from scratch.");
            _sdb_hosts_group.visible = false;
            add_group (_sdb_hosts_group);
        }

        private void on_sdb_toggled () {
            if (_sdb_guard) return;
            apply_sdb_enabled.begin (_sdb_switch.switch_btn.active);
        }

        private async void apply_sdb_enabled (bool wanted) {
            _sdb_switch.sensitive = false;
            bool ok = false;
            bool active = false;
            string message = "";
            bool answered = yield SdbService.set_enabled (wanted, out ok, out active,
                out message);
            _sdb_switch.sensitive = true;

            if (!answered) {
                show_sdb_error (wanted
                    ? _("The debug bridge could not be turned on. %s").printf (message)
                    : _("The debug bridge could not be turned off, so it may still be listening. %s").printf (message));
                yield refresh_sdb_state ();
                return;
            }

            set_sdb_switch (active);
            if (ok && active == wanted) {
                show_sdb_error (null);
            } else if (wanted) {
                show_sdb_error (_("The debug bridge could not be turned on. %s").printf (message));
            } else {
                show_sdb_error (_("The debug bridge could not be turned off and is still listening. %s").printf (message));
            }
            refresh_sdb_bridge ();
        }

        private async void refresh_sdb_state () {
            if (_sdb_switch == null || _sdb_refreshing) return;
            _sdb_refreshing = true;

            bool available = false;
            bool active = false;
            string message = "";
            bool answered = yield SdbService.status (out available, out active,
                out message);
            _sdb_refreshing = false;

            if (!answered) {
                set_sdb_switch (false);
                _sdb_switch.sensitive = false;
                hide_sdb_bridge_ui ();
                show_sdb_error (_("The debug bridge state could not be confirmed. %s It is shown as off because nothing was confirmed, not because it is known to be off.").printf (message));
                return;
            }
            if (!available) {
                set_sdb_switch (false);
                _sdb_switch.sensitive = false;
                hide_sdb_bridge_ui ();
                show_sdb_error (_("The debug bridge is not available on this device, so it cannot be turned on."));
                return;
            }

            _sdb_switch.sensitive = true;
            set_sdb_switch (active);
            show_sdb_error (null);

            if (!active) {
                hide_sdb_bridge_ui ();
                return;
            }
            refresh_sdb_bridge ();
        }

        private void hide_sdb_bridge_ui () {
            _sdb_device_row.visible = false;
            _sdb_pair_row.visible = false;
            _sdb_pairing_group.visible = false;
            _sdb_hosts_group.visible = false;
            _sdb_hosts_signature = "";
        }

        private void refresh_sdb_bridge () {
            var device = SdbAgent.device ();
            if (device != null) {
                _sdb_device_fp.label = device.display ();
                _sdb_device_row.visible = true;
            } else {
                _sdb_device_row.visible = false;
            }

            var pairing = SdbAgent.pairing_state ();
            if (pairing == null) {
                _sdb_pair_row.visible = false;
                _sdb_pairing_group.visible = false;
                show_sdb_error (_("The debug bridge is running, but its pairing state could not be read, so no code is shown."));
            } else if (pairing.locked_out ()) {
                _sdb_pair_row.visible = false;
                _sdb_pairing_group.visible = false;
                show_sdb_error (
                    _("Too many wrong codes were entered. Pairing is blocked until %s.")
                        .printf (pairing.locked_until_text ()));
            } else if (pairing.active && pairing.code != "") {
                _sdb_pair_row.visible = false;
                _sdb_code.label = pairing.code;
                _sdb_expiry.label = pairing.expires_text ();

                bool has_host = pairing.pending_fingerprint_display != ""
                    || pairing.pending_fingerprint != "";
                if (has_host) {
                    _sdb_fp_caption.visible = true;
                    _sdb_fingerprint.visible = true;
                    _sdb_fingerprint.label = pairing.fingerprint_display ();
                } else {
                    _sdb_fp_caption.visible = false;
                    _sdb_fingerprint.visible = false;
                }

                if (pairing.pending_label != "") {
                    _sdb_pair_host.label = _("Requested by %s").printf (pairing.pending_label);
                    _sdb_pair_host.visible = true;
                } else if (has_host) {
                    _sdb_pair_host.visible = false;
                } else {
                    _sdb_pair_host.label = _("Waiting for a host to connect. The fingerprint appears once one does, and it must match before you type the code.");
                    _sdb_pair_host.visible = true;
                }

                if (pairing.attempts > 0) {
                    _sdb_attempts.label =
                        ngettext ("%d wrong code has been tried.",
                                  "%d wrong codes have been tried.",
                                  pairing.attempts).printf (pairing.attempts);
                    _sdb_attempts.add_css_class ("error");
                    _sdb_attempts.visible = true;
                } else {
                    _sdb_attempts.visible = false;
                }
                _sdb_pairing_group.visible = true;
            } else {
                _sdb_pair_row.visible = true;
                _sdb_pairing_group.visible = false;
            }

            refresh_sdb_hosts ();
        }

        private void refresh_sdb_hosts () {
            var hosts = SdbAgent.hosts ();
            if (hosts == null) {
                _sdb_hosts_signature = "";
                _sdb_hosts_group.clear ();
                _sdb_hosts_group.add_row (new ActionRow (_("Paired hosts"),
                    _("The list could not be read, so it is not shown. No host has been revoked."),
                    "dialog-warning-symbolic"));
                _sdb_hosts_group.visible = true;
                return;
            }

            var sig = new StringBuilder ();
            foreach (var host in hosts) {
                sig.append (host.label);
                sig.append ("|");
                sig.append (host.last_used);
                sig.append ("\n");
            }
            if (sig.str == _sdb_hosts_signature) {
                _sdb_hosts_group.visible = true;
                return;
            }
            _sdb_hosts_signature = sig.str;

            _sdb_hosts_group.clear ();
            if (hosts.size == 0) {
                _sdb_hosts_group.add_row (new ActionRow (_("No paired hosts"),
                    _("No development machine can connect to this device yet."),
                    "computer-symbolic"));
                _sdb_hosts_group.visible = true;
                return;
            }

            foreach (var host in hosts) {
                var entry = host;
                var row = new ConfirmRow (entry.label,
                    _("Last used %s. Fingerprint %s").printf (
                        entry.last_used_text (), entry.fingerprint_display ()),
                    "computer-symbolic");
                row.confirm_label = _("Revoke");
                row.confirmed.connect (() => {
                    string message;
                    if (SdbAgent.revoke (entry.label, out message)) {
                        show_sdb_error (null);
                        _sdb_hosts_signature = "";
                        refresh_sdb_hosts ();
                    } else {
                        show_sdb_error (
                            _("%s was not revoked and can still connect. %s")
                                .printf (entry.label, message));
                    }
                });
                _sdb_hosts_group.add_row (row);
            }
            _sdb_hosts_group.visible = true;
        }

        public static string format_fingerprint (string? fingerprint) {
            if (fingerprint == null || fingerprint.strip () == "")
                return _("not provided");
            string text = fingerprint.strip ();
            int colons = 0;
            for (int i = 0; i < text.length; i++)
                if (text[i] == ':') colons++;

            string prefix = "";
            int colon = text.index_of (":");
            if (colons == 1 && colon > 0) {
                prefix = text.substring (0, colon + 1) + " ";
                text = text.substring (colon + 1);
            }
            if (text.index_of (" ") >= 0) return prefix + text;

            var grouped = new StringBuilder ();
            int count = 0;
            for (int i = 0; i < text.length; i++) {
                if (text[i] == ':') continue;
                if (count > 0 && count % 4 == 0) grouped.append_c (' ');
                grouped.append_c (text[i]);
                count++;
            }
            return prefix + grouped.str;
        }

        private void show_sdb_error (string? message) {
            if (_sdb_error == null) return;
            _sdb_error.label = message ?? "";
            _sdb_error.visible = message != null;
        }

        private void set_sdb_switch (bool active) {
            _sdb_guard = true;
            _sdb_switch.switch_btn.active = active;
            _sdb_guard = false;
        }

        private void start_sdb_timer () {
            if (_sdb_switch == null || _sdb_timer_id != 0) return;
            _sdb_timer_id = Timeout.add_seconds (2, () => {
                refresh_sdb_state.begin ();
                return Source.CONTINUE;
            });
        }

        private void stop_sdb_timer () {
            if (_sdb_timer_id != 0) {
                Source.remove (_sdb_timer_id);
                _sdb_timer_id = 0;
            }
        }
    }

    class SdbDevice {
        public string fingerprint;
        public string fingerprint_display;

        public string display () {
            return fingerprint_display != "" ? fingerprint_display
                                             : DeveloperPage.format_fingerprint (fingerprint);
        }
    }

    class SdbPairingState {
        public bool active;
        public string code;
        public string expires_at;
        public string pending_fingerprint;
        public string pending_fingerprint_display;
        public string pending_label;
        public int attempts;
        public string locked_until;

        public string fingerprint_display () {
            return pending_fingerprint_display != ""
                ? pending_fingerprint_display
                : DeveloperPage.format_fingerprint (pending_fingerprint);
        }

        public bool locked_out () {
            var until = SdbAgent.parse_time (locked_until);
            if (until == null) return false;
            return until.compare (new DateTime.now_utc ()) > 0;
        }

        public string locked_until_text () {
            var until = SdbAgent.parse_time (locked_until);
            if (until == null) return "";
            return until.to_local ().format ("%H:%M").strip ();
        }

        public string expires_text () {
            var at = SdbAgent.parse_time (expires_at);
            if (at == null) return "";
            int64 left = at.difference (new DateTime.now_utc ()) / TimeSpan.SECOND;
            if (left <= 0) return _("This code has expired. Start pairing again.");
            if (left < 60)
                return ngettext ("Expires in %d second.", "Expires in %d seconds.",
                                 (ulong) left).printf ((int) left);
            int mins = (int) ((left + 59) / 60);
            return ngettext ("Expires in %d minute.", "Expires in %d minutes.",
                             (ulong) mins).printf (mins);
        }
    }

    class SdbPairedHost {
        public string label;
        public string fingerprint;
        public string fingerprint_display_raw;
        public string paired_at;
        public string last_used;

        public string fingerprint_display () {
            return fingerprint_display_raw != ""
                ? fingerprint_display_raw
                : DeveloperPage.format_fingerprint (fingerprint);
        }

        public string last_used_text () {
            var when = SdbAgent.parse_time (last_used);
            if (when == null) return _("never");
            return when.to_local ().format ("%e %b %Y, %H:%M").strip ();
        }
    }

    class SdbService {
        private const string BUS_NAME = "io.github.singularityos_lab.ush.Broker";
        private const string OBJ_PATH = "/io/github/singularityos_lab/ush/Broker";

        public static async bool status (out bool available, out bool active,
                                         out string message) {
            available = false;
            active = false;
            message = "";
            try {
                UshBroker broker = yield Bus.get_proxy (BusType.SESSION, BUS_NAME, OBJ_PATH);
                bool avail;
                bool act;
                string msg;
                yield broker.sdb_status (out avail, out act, out msg);
                available = avail;
                active = act;
                if (msg != null) message = msg;
                return true;
            } catch (GLib.Error e) {
                warning ("SdbService: sdb_status failed: %s", e.message);
                message = _("The security service is not available.");
                return false;
            }
        }

        public static async bool set_enabled (bool enabled, out bool ok, out bool active,
                                              out string message) {
            ok = false;
            active = false;
            message = "";
            try {
                UshBroker broker = yield Bus.get_proxy (BusType.SESSION, BUS_NAME, OBJ_PATH);
                bool res;
                bool act;
                string msg;
                yield broker.set_sdb_enabled (enabled, out res, out act, out msg);
                ok = res;
                active = act;
                if (msg != null && msg != "") message = msg;
                else if (!res) message = _("The request was refused.");
                return true;
            } catch (GLib.Error e) {
                warning ("SdbService: set_sdb_enabled failed: %s", e.message);
                message = _("The security service is not available.");
                return false;
            }
        }
    }

    class SdbAgent {
        private const string SOCKET_PATH = "/run/sinty-sdb.sock";

        public static DateTime? parse_time (string? value) {
            if (value == null || value.strip () == "") return null;
            var when = new DateTime.from_iso8601 (value, null);
            if (when == null) return null;
            if (when.get_year () <= 1) return null;
            return when.to_utc ();
        }

        private static string? request (string method, string path, string? body,
                                        out int status) {
            status = 0;
            try {
                var sock = new Socket (SocketFamily.UNIX, SocketType.STREAM,
                                       SocketProtocol.DEFAULT);
                sock.set_timeout (2);
                sock.connect (new UnixSocketAddress (SOCKET_PATH), null);

                var req = new StringBuilder ();
                req.append ("%s %s HTTP/1.1\r\n".printf (method, path));
                req.append ("Host: localhost\r\n");
                req.append ("Connection: close\r\n");
                if (body != null) {
                    req.append ("Content-Type: application/json\r\n");
                    req.append ("Content-Length: %d\r\n".printf (body.length));
                }
                req.append ("\r\n");
                if (body != null) req.append (body);
                sock.send (req.str.data);

                var raw = new ByteArray ();
                var buf = new uint8[4096];
                while (true) {
                    ssize_t n = sock.receive (buf);
                    if (n <= 0) break;
                    raw.append (buf[0:(int) n]);
                }
                sock.close ();
                if (raw.len == 0) return null;
                raw.append ({ 0 });

                string text = (string) raw.data;
                int sep = text.index_of ("\r\n\r\n");
                if (sep < 0) return null;
                string head = text.substring (0, sep);
                int eol = head.index_of ("\r\n");
                string status_line = eol < 0 ? head : head.substring (0, eol);
                string[] parts = status_line.split (" ");
                if (parts.length >= 2) status = int.parse (parts[1]);
                return text.substring (sep + 4);
            } catch (GLib.Error e) {
                warning ("SdbAgent: %s %s failed: %s", method, path, e.message);
                return null;
            }
        }

        private static Json.Object? parse_object (string? body) {
            if (body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (body);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                    return null;
                return root.get_object ();
            } catch (GLib.Error e) {
                return null;
            }
        }

        private static string member_string (Json.Object obj, string name) {
            if (!obj.has_member (name)) return "";
            var node = obj.get_member (name);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE)
                return "";
            return node.get_string () ?? "";
        }

        private static bool member_bool (Json.Object obj, string name) {
            if (!obj.has_member (name)) return false;
            var node = obj.get_member (name);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE)
                return false;
            return node.get_boolean ();
        }

        private static string failure_message (Json.Object? obj) {
            if (obj == null)
                return _("The debug bridge service sent a reply that could not be read.");
            string err = member_string (obj, "error");
            if (err == "") err = member_string (obj, "message");
            if (err != "") return err;
            return _("The debug bridge service refused the request.");
        }

        public static SdbDevice? device () {
            int http_status;
            string? body = request ("GET", "/device", null, out http_status);
            if (body == null || http_status != 200) return null;
            var obj = parse_object (body);
            if (obj == null || !obj.has_member ("fingerprint")) return null;
            var dev = new SdbDevice ();
            dev.fingerprint = member_string (obj, "fingerprint");
            dev.fingerprint_display = member_string (obj, "fingerprint_display");
            if (dev.fingerprint == "" && dev.fingerprint_display == "") return null;
            return dev;
        }

        public static SdbPairingState? pairing_state () {
            int http_status;
            string? body = request ("GET", "/pairing/state", null, out http_status);
            if (body == null || http_status != 200) return null;
            var obj = parse_object (body);
            if (obj == null || !obj.has_member ("active")) return null;

            var st = new SdbPairingState ();
            st.active = member_bool (obj, "active");
            st.code = member_string (obj, "code");
            st.expires_at = member_string (obj, "expires_at");
            st.pending_fingerprint = member_string (obj, "pending_fingerprint");
            st.pending_fingerprint_display = member_string (obj, "pending_fingerprint_display");
            st.pending_label = member_string (obj, "pending_label");
            st.locked_until = member_string (obj, "locked_until");
            st.attempts = 0;
            if (obj.has_member ("attempts")) {
                var node = obj.get_member ("attempts");
                if (node != null && node.get_node_type () == Json.NodeType.VALUE)
                    st.attempts = (int) node.get_int ();
            }
            return st;
        }

        public static bool pairing_start (out string message) {
            int http_status;
            string? body = request ("POST", "/pairing/start", null, out http_status);
            if (body == null) {
                message = _("The debug bridge service is not available.");
                return false;
            }
            var obj = parse_object (body);
            bool ok = http_status == 200 && obj != null && member_bool (obj, "ok");
            message = ok ? "" : failure_message (obj);
            return ok;
        }

        public static bool pairing_cancel (out string message) {
            int http_status;
            string? body = request ("POST", "/pairing/cancel", null, out http_status);
            if (body == null) {
                message = _("The debug bridge service is not available.");
                return false;
            }
            var obj = parse_object (body);
            bool ok = http_status == 200 && obj != null && member_bool (obj, "ok");
            message = ok ? "" : failure_message (obj);
            return ok;
        }

        public static Gee.ArrayList<SdbPairedHost>? hosts () {
            int http_status;
            string? body = request ("GET", "/hosts", null, out http_status);
            if (body == null || http_status != 200) return null;
            var obj = parse_object (body);
            if (obj == null || !obj.has_member ("hosts")) return null;
            var node = obj.get_member ("hosts");
            if (node == null || node.get_node_type () != Json.NodeType.ARRAY) return null;

            var list = new Gee.ArrayList<SdbPairedHost> ();
            var array = node.get_array ();
            for (uint i = 0; i < array.get_length (); i++) {
                var item = array.get_element (i);
                if (item == null || item.get_node_type () != Json.NodeType.OBJECT)
                    return null;
                var entry = item.get_object ();
                string label = member_string (entry, "label");
                if (label == "") return null;
                var host = new SdbPairedHost ();
                host.label = label;
                host.fingerprint = member_string (entry, "fingerprint");
                host.fingerprint_display_raw = member_string (entry, "fingerprint_display");
                host.paired_at = member_string (entry, "paired_at");
                host.last_used = member_string (entry, "last_used");
                list.add (host);
            }
            return list;
        }

        public static bool revoke (string label, out string message) {
            int http_status;
            var node = new Json.Node (Json.NodeType.VALUE);
            node.set_string (label);
            string? body = request ("POST", "/hosts/revoke",
                "{\"label\":%s}".printf (Json.to_string (node, false)), out http_status);
            if (body == null) {
                message = _("The debug bridge service is not available.");
                return false;
            }
            var obj = parse_object (body);
            bool ok = http_status == 200 && obj != null && member_bool (obj, "ok");
            message = ok ? "" : failure_message (obj);
            return ok;
        }
    }

    // The atom-recovery socket is root-only by design and is deliberately not
    // widened, so the desktop never touches it. The ush broker is already
    // privileged, already checks peer credentials and already rate limits, so it
    // verifies the PIN and performs the arming on our behalf. Keeping the PIN gate
    // inside the broker means it cannot be bypassed by reaching the socket directly.
    class BootloaderConsent {
        private const string BUS_NAME = "io.github.singularityos_lab.ush.Broker";
        private const string OBJ_PATH = "/io/github/singularityos_lab/ush/Broker";

        public static async bool arm (bool armed, string pin, out string message) {
            message = "";
            try {
                UshBroker broker = yield Bus.get_proxy (BusType.SESSION, BUS_NAME, OBJ_PATH);
                bool ok;
                string msg;
                yield broker.arm_bootloader_unlock (armed, pin, out ok, out msg);
                if (msg != null && msg != "") message = msg;
                else if (!ok) message = _("The request was refused.");
                return ok;
            } catch (GLib.Error e) {
                warning ("BootloaderConsent: arm_bootloader_unlock failed: %s", e.message);
                message = _("The security service is not available.");
                return false;
            }
        }

        public static async bool lock_state (out bool armed) {
            armed = false;
            try {
                UshBroker broker = yield Bus.get_proxy (BusType.SESSION, BUS_NAME, OBJ_PATH);
                bool locked;
                bool unlock_armed;
                int unlock_count;
                yield broker.bootloader_lock_state (out locked, out unlock_armed,
                    out unlock_count);
                armed = unlock_armed;
                return true;
            } catch (GLib.Error e) {
                warning ("BootloaderConsent: bootloader_lock_state failed: %s", e.message);
                return false;
            }
        }
    }

    // Step 1 of the bootloader unlock flow: record the user's consent, gated by the
    // current PIN. The check goes to the root sinty-recoverd broker over its socket
    // (verify action, SO_PEERCRED-gated to our own uid, rate-limited), the same one
    // the lock screen unlocks with. Consent alone unlocks nothing.
    public class BootloaderUnlockPage : SettingsPage {
        private SettingsView view;
        private GLib.Settings settings;
        private PasswordRow pin_row;
        private Label error_label;
        private Button allow_btn;

        public BootloaderUnlockPage (SettingsView view, GLib.Settings settings) {
            base (_("Allow bootloader unlock"));
            this.view = view;
            this.settings = settings;
            back_clicked.connect (() => view.navigate_to ("developer"));
            build_ui ();
        }

        private void build_ui () {
            var group = new PreferencesGroup (_("Confirm"));
            group.description = _("A later unlock from recovery will erase all data on this device and disable verified boot. Enter your PIN to allow it.");
            pin_row = new PasswordRow (_("PIN"));
            group.add_row (pin_row);
            add_group (group);

            error_label = new Label ("");
            error_label.add_css_class ("error");
            error_label.wrap = true;
            error_label.visible = false;
            error_label.margin_start = 16;
            error_label.margin_end = 16;
            error_label.halign = Gtk.Align.START;
            var err_wrapper = new Box (Orientation.VERTICAL, 0);
            err_wrapper.append (error_label);
            add_widget (err_wrapper);

            allow_btn = new Button.with_label (_("Allow"));
            allow_btn.add_css_class ("destructive-action");
            allow_btn.add_css_class ("pill");
            allow_btn.halign = Gtk.Align.CENTER;
            allow_btn.margin_top = 8;
            allow_btn.clicked.connect (on_allow);
            add_widget (allow_btn);

            pin_row.entry_activated.connect (on_allow);
        }

        private void on_allow () {
            string pin = pin_row.text;
            if (pin == "") {
                error_label.label = _("Enter your PIN");
                error_label.visible = true;
                return;
            }
            allow_btn.sensitive = false;
            error_label.visible = false;
            submit.begin (pin);
        }

        // The PIN is checked by the broker, not here: a check done in the UI would be
        // bypassable by anything able to reach the broker directly.
        private async void submit (string pin) {
            string message;
            if (yield BootloaderConsent.arm (true, pin, out message)) {
                settings.set_boolean ("bootloader-unlock-allowed", true);
                view.navigate_to ("developer");
            } else {
                error_label.label = _("Unlocking was not allowed. %s").printf (message);
                error_label.visible = true;
                pin_row.text = "";
                allow_btn.sensitive = true;
            }
        }
    }
}
