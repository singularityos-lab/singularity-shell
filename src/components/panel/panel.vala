using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class Panel : Gtk.Window {
        private Label clock_label;
        private Label app_title_label;
        private Box main_box;
        private Box left_box;
        private Box center_box;
        private Box right_box;
        private Box clock_suffix_box;
        private Singularity.Shell.GlobalMenuBar menu_bar;
        private GLib.Settings _settings;
        private string _clock_format_str = "%b %e  %H:%M";
        private bool is_greeter_mode = false;
        private bool is_primary = true;
        private Gdk.Monitor? gdk_monitor = null;
        private string? last_monitor_app_id = null;
        private ulong _sig_clock = 0;
        private bool _hidden_for_fullscreen = false;
        private ulong _sig_app_focused = 0;
        private ulong _sig_menu_model_changed = 0;
        private bool _last_strip_light = false;
        private double _last_strip_lum = -1.0;
        private double _last_frac = -1.0;
        private Button workspace_btn;
        private bool _workspace_overview_active = false;
        private bool _dock_hidden = false;
        private Widget _corner_tl;
        private Widget _corner_tr;
        public signal void activities_clicked();
        public signal void clock_clicked();
        public signal void notifications_clicked();
        public signal void system_clicked();
        public signal void workspace_clicked();

        public Panel(Gtk.Application app, bool greeter_mode = false, bool is_primary = true, Gdk.Monitor? target_monitor = null) {
            Object(application: app);
            this.is_greeter_mode = greeter_mode;
            this.is_primary = is_primary;
            this.height_request = 32;
            _settings = new GLib.Settings("dev.sinty.desktop");
            var app_system = AppSystem.get_default();
            init_for_window(this);
            var _shell_mon = target_monitor ?? find_shell_monitor();
            // Always remember which monitor this panel lives on (even the
            // primary, which is constructed with target_monitor == null) so
            // per-monitor logic like flat-on-maximize works correctly. Without
            // this the primary panel had a null monitor and fell back to the
            // GLOBAL maximized check - flattening on every screen whenever any
            // window was maximized anywhere.
            this.gdk_monitor = _shell_mon;
            if (_shell_mon != null) GtkLayerShell.set_monitor(this, _shell_mon);
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            auto_exclusive_zone_enable(this);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            map.connect_after(() => {
                GLib.Idle.add(() => {
                    if (get_parent() == null) return GLib.Source.REMOVE;
                    int h = get_allocated_height();
                    if (h > 0) app_system.shell_panel_height = h;
                    return GLib.Source.REMOVE;
                });
            });
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("panel-window");
            if (is_greeter_mode) add_css_class("greeter-panel");

            var overlay = new Overlay();
            overlay.overflow = Overflow.VISIBLE;
            set_child(overlay);
            main_box = new Box(Orientation.HORIZONTAL, 10);
            main_box.add_css_class("panel");
            main_box.overflow = Overflow.VISIBLE;
            overlay.set_child(main_box);

            _corner_tl = create_corner_hint("corner-hint-tl");
            _corner_tl.can_target = false;
            _corner_tl.halign = Align.START;
            _corner_tl.valign = Align.START;
            overlay.add_overlay(_corner_tl);

            _corner_tr = create_corner_hint("corner-hint-tr");
            _corner_tr.can_target = false;
            _corner_tr.halign = Align.END;
            _corner_tr.valign = Align.START;
            overlay.add_overlay(_corner_tr);
            left_box = new Box(Orientation.HORIZONTAL, 5);

            if (!is_greeter_mode) {
                var activities_btn = new Button();
                activities_btn.add_css_class("activities-button");

                // Set tooltip with real-time shortcut
                var shortcuts = SystemMonitor.get_default().shortcuts;
                activities_btn.tooltip_text = format_tooltip(_("Overview"), shortcuts, "toggle_launcher");
                shortcuts.shortcut_changed.connect((action, accel) => {
                    if (action == "toggle_launcher")
                        activities_btn.tooltip_text = format_tooltip(_("Overview"), shortcuts, "toggle_launcher");
                });

                var logo = new Image.from_icon_name("emblem-singularity");
                var icon_theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());

                if (icon_theme.has_icon("emblem-singularity")) {
                    logo.icon_name = "emblem-singularity";
                } else if (icon_theme.has_icon("computer-symbolic")) {
                    logo.icon_name = "computer-symbolic";
                } else {
                    logo.icon_name = "view-app-grid-symbolic";
                }

                logo.pixel_size = 18;
                activities_btn.set_child(logo);

                activities_btn.clicked.connect(() => {
                    activities_clicked();
                });
                left_box.append(activities_btn);
            }

            workspace_btn = new Button();
            workspace_btn.add_css_class("activities-button");
            var ws_icon = new Image.from_icon_name("dev.sinty.workspaces");
            ws_icon.pixel_size = 24;
            workspace_btn.set_child(ws_icon);
            workspace_btn.visible = false;
            workspace_btn.clicked.connect(() => {
                workspace_clicked();
            });
            left_box.append(workspace_btn);

            app_title_label = new Label("");
            app_title_label.add_css_class("app-title");
            app_title_label.valign = Align.CENTER;
            app_title_label.margin_start = 5;
            app_title_label.margin_end = 5;
            if (!is_greeter_mode) left_box.append(app_title_label);

            main_box.append(left_box);

            if (!is_greeter_mode && _settings.get_boolean("global-menu-enabled")) {
                menu_bar = new Singularity.Shell.GlobalMenuBar();
                menu_bar.valign = Align.CENTER;
                menu_bar.visible = false;
                main_box.append(menu_bar);

                _sig_menu_model_changed = app_system.menu_model_changed.connect((model) => {
                    menu_bar.register_action_group("dbusmenu", app_system.current_action_group);
                    menu_bar.register_action_group("app", app_system.current_app_action_group);
                    menu_bar.register_action_group("win", app_system.current_win_action_group);
                    menu_bar.update_model(model);
                    bool has_menu = model != null && model.get_n_items() > 0;
                    menu_bar.visible = has_menu;
                });
            }

            if (!is_greeter_mode) {
                _sig_app_focused = app_system.app_focused.connect((app_id) => {
                    // Secondary panels: only update if focused window is on our monitor
                    if (!is_primary && gdk_monitor != null) {
                        var focused_handle = app_system.get_focused_window_handle();
                        if (focused_handle != null) {
                            var wmon = Singularity.wayland_get_window_monitor(focused_handle);
                            if (wmon != gdk_monitor) return;
                        }
                    }
                    last_monitor_app_id = app_id;
                    if (app_id == null || app_id == "") {
                        app_title_label.label = "";
                        return;
                    }
                    var app_info = app_system.resolve_app_for_id(app_id);
                    if (app_info != null) {
                        app_title_label.label = app_info.get_name();
                    } else {
                        app_title_label.label = humanize_app_id(app_id);
                    }
                    app_title_label.visible = true;
                });
            }
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            main_box.append(spacer);
            right_box = new Box(Orientation.HORIZONTAL, 5);

            var sys_btn = new Button();
            sys_btn.has_frame = false;
            sys_btn.add_css_class("system-pill-button");
            var sys_pill = new Box(Orientation.HORIZONTAL, 8);
            sys_pill.add_css_class("system-pill");

            var network = SystemMonitor.get_default().network;
            var network_icon = new Image.from_icon_name("network-wireless-symbolic");
            network_icon.pixel_size = 16;
            network_icon.tooltip_text = network.wifi_ssid;
            network.state_changed.connect(() => {
                network_icon.icon_name = network.wifi_icon;
                network_icon.tooltip_text = network.wifi_ssid;
            });

            var audio = SystemMonitor.get_default().audio;
            var audio_icon = new Image.from_icon_name(audio.icon_name);
            audio_icon.pixel_size = 16;
            audio_icon.tooltip_text = "%d%%".printf((int)audio.volume);
            audio.state_changed.connect(() => {
                audio_icon.icon_name = audio.icon_name;
                audio_icon.tooltip_text = "%d%%".printf((int)audio.volume);
            });

            var battery_icon = new Image.from_icon_name("battery-full-symbolic");
            battery_icon.pixel_size = 16;

            var battery_label = new Label("");
            battery_label.add_css_class("battery-percentage");
            battery_label.visible = false;

            sys_pill.append(network_icon);
            sys_pill.append(audio_icon);
            sys_pill.append(battery_icon);
            sys_pill.append(battery_label);

            var bt = SystemMonitor.get_default().bluetooth;
            var call_mon = SystemMonitor.get_default().call_monitor;
            var bt_icon = new Image.from_icon_name("bluetooth-active-symbolic");
            bt_icon.pixel_size = 16;
            var bt_indicator = new Box(Orientation.HORIZONTAL, 0);
            bt_indicator.add_css_class("bt-indicator");
            bt_indicator.append(bt_icon);
            bt_indicator.visible = false;
            void update_bt_indicator() {
                var dev = bt.get_connected_device();
                if (dev == null) {
                    bt_indicator.visible = false;
                    return;
                }
                bt_indicator.visible = true;
                bt_icon.icon_name = BluetoothManager.bt_icon_for(dev.icon);
                bt_indicator.tooltip_text = dev.name;
                if (call_mon.voice_active) bt_indicator.add_css_class("calling");
                else bt_indicator.remove_css_class("calling");
            }
            update_bt_indicator();
            bt.device_added.connect(() => update_bt_indicator());
            bt.device_removed.connect(() => update_bt_indicator());
            bt.device_changed.connect(() => update_bt_indicator());
            bt.state_changed.connect(() => update_bt_indicator());
            call_mon.changed.connect(() => update_bt_indicator());
            sys_pill.append(bt_indicator);

            var vpn_indicator = new Image.from_icon_name("network-vpn-symbolic");
            vpn_indicator.pixel_size = 16;
            vpn_indicator.visible = false;
            vpn_indicator.tooltip_text = "";
            network.vpn_state_changed.connect(() => {
                vpn_indicator.visible = network.vpn_active;
                vpn_indicator.tooltip_text = network.vpn_active ? _("VPN: %s").printf(network.vpn_name) : "";
            });
            sys_pill.prepend(vpn_indicator);
            sys_btn.set_child(sys_pill);
            sys_btn.clicked.connect(() => {
                system_clicked();
            });
            var power = SystemMonitor.get_default().power;
            battery_icon.icon_name = power.icon_name;
            battery_icon.tooltip_text = "%d%%".printf((int)power.percentage);
            battery_icon.visible = power.is_present;

            void update_battery_label() {
                bool show = _settings.get_boolean("show-battery-percentage");
                battery_label.label = "%d%%".printf((int)power.percentage);
                battery_label.visible = show && power.is_present;
            }
            update_battery_label();
            power.state_changed.connect(() => {
                battery_icon.icon_name = power.icon_name;
                battery_icon.tooltip_text = "%d%%".printf((int)power.percentage);
                battery_icon.visible = power.is_present;
                update_battery_label();
            });
            _settings.changed["show-battery-percentage"].connect(() => update_battery_label());
            right_box.append(sys_btn);

            var notif_btn = new Button();
            notif_btn.has_frame = false;
            notif_btn.valign = Align.CENTER;
            notif_btn.add_css_class("notification-button");

            var notif_overlay = new Overlay();
            var notif_icon = new Image.from_icon_name("preferences-system-notifications-symbolic");
            notif_icon.pixel_size = 16;
            notif_overlay.set_child(notif_icon);

            var notif_badge = new Box(Orientation.HORIZONTAL, 0);
            notif_badge.add_css_class("notification-badge");
            notif_badge.valign = Align.START;
            notif_badge.halign = Align.END;
            notif_badge.visible = false;
            notif_overlay.add_overlay(notif_badge);

            notif_btn.set_child(notif_overlay);
            notif_btn.clicked.connect(() => {
                if (!is_greeter_mode) notifications_clicked();
            });

            var nm = SystemMonitor.get_default().notifications;

            nm.history_changed.connect(() => {
                notif_badge.visible = (nm.get_history().length() > 0);
            });
            _settings.changed["do-not-disturb"].connect(() => {
                bool dnd = _settings.get_boolean("do-not-disturb");
                notif_icon.icon_name = dnd ? "notifications-disabled-symbolic" : "preferences-system-notifications-symbolic";
            });

            // Initial state
            notif_badge.visible = (nm.get_history().length() > 0);
            notif_icon.icon_name = _settings.get_boolean("do-not-disturb") ? "notifications-disabled-symbolic" : "preferences-system-notifications-symbolic";

            // Secondary panels: hide status icons and notifications, show clock only
            sys_btn.visible = is_primary;
            notif_btn.visible = is_primary;

            right_box.append(notif_btn);

            var clock_btn = new Button();
            clock_btn.has_frame = false;
            clock_btn.add_css_class("clock-button");
            clock_label = new Label("00:00");
            clock_label.add_css_class("clock");
            clock_btn.set_child(clock_label);
            clock_btn.clicked.connect(() => {
                if (!is_greeter_mode) clock_clicked();
            });
            right_box.append(clock_btn);

            clock_suffix_box = new Box(Orientation.HORIZONTAL, 4);
            clock_suffix_box.valign = Align.CENTER;
            right_box.append(clock_suffix_box);

            main_box.append(right_box);

            // Clock format from our own settings
            _clock_format_str = _settings.get_boolean("clock-use-12h")
                ? "%a, %b %e  %I:%M %p" : "%a, %b %e  %H:%M";
            _settings.changed["clock-use-12h"].connect(() => {
                _clock_format_str = _settings.get_boolean("clock-use-12h")
                    ? "%a, %b %e  %I:%M %p" : "%a, %b %e  %H:%M";
                update_clock();
            });
            update_clock();
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            _settings.changed["panel-fusion"].connect(() => {
                update_visibility();
            });
            _settings.changed["panel-flat"].connect(() => {
                update_flat_mode();
            });
            _settings.changed["panel-flat-opacity"].connect(() => {
                apply_flat_opacity(_settings);
            });
            apply_flat_opacity(_settings);
            _settings.changed["background-picture-uri"].connect(() => {
                _last_strip_lum = -1.0;
                update_topbar_fg_class();
            });
            WallpaperManager.get_default().wallpaper_changed.connect(() => {
                _last_strip_lum = -1.0;
                update_topbar_fg_class();
            });
            // Auto-flatten when any window is maximized
            var app_sys = AppSystem.get_default();
            app_sys.any_maximized_changed.connect(() => {
                update_flat_mode();
            });
            app_sys.app_closed.connect((handle) => {
                update_flat_mode();
                update_fullscreen_mode();
            });
            app_sys.any_fullscreen_changed.connect(() => {
                update_fullscreen_mode();
            });
            app_sys.window_focused.connect(() => {
                update_fullscreen_mode();
            });
            update_visibility();
            update_flat_mode();
            update_topbar_fg_class();

            /* Request compositor-level background blur (frosted glass) */
        }

        private bool is_any_window_fullscreen_on_my_monitor() {
            var app_sys = AppSystem.get_default();
            void* fh = app_sys.get_focused_window_handle();
            if (fh == null) return false;
            var display = Gdk.Display.get_default();
            var monitor = this.gdk_monitor ?? find_shell_monitor();
            if (monitor == null && display != null && display.get_monitors().get_n_items() > 0)
                monitor = display.get_monitors().get_item(0) as Gdk.Monitor;
            bool single = (display == null) || (display.get_monitors().get_n_items() <= 1);
            string? target_conn = (monitor != null) ? monitor.get_connector() : null;
            Gdk.Monitor? primary = (display != null)
                ? display.get_monitors().get_item(0) as Gdk.Monitor : null;
            bool target_is_primary = (primary != null && monitor != null)
                && (primary == monitor || (target_conn != null && primary.get_connector() == target_conn));
            foreach (var win in app_sys.get_windows()) {
                if (win.handle != fh) continue;
                if (!win.is_fullscreen || win.is_minimized) return false;
                if (single || monitor == null) return true;
                var wmon = Singularity.wayland_get_window_monitor(win.handle);
                if (wmon == null) return target_is_primary;
                if (wmon == monitor) return true;
                if (target_conn != null && wmon.get_connector() == target_conn) return true;
                return false;
            }
            return false;
        }

        private void update_fullscreen_mode() {
            if (is_greeter_mode) return;
            bool fs = is_any_window_fullscreen_on_my_monitor();
            if (fs == _hidden_for_fullscreen) return;
            _hidden_for_fullscreen = fs;
            if (fs) {
                set_exclusive_zone(this, 0);
                set_layer(this, GtkLayerShell.Layer.BACKGROUND);
            } else {
                // A layer change on an idle, occluded surface (e.g. a maximized
                // window covering the top strip) is not composited until a frame
                // is committed, so closing a focused fullscreen window left the
                // topbar buried. Remap to force a fresh buffer and present.
                ((Gtk.Widget) this).hide();
                update_visibility();
                pulse_frame_clock();
            }
        }

        private void pulse_frame_clock() {
            var fc = get_frame_clock();
            if (fc == null) return;
            fc.begin_updating();
            GLib.Timeout.add(350, () => {
                var f = get_frame_clock();
                if (f != null) f.end_updating();
                return GLib.Source.REMOVE;
            });
        }

        private bool has_fullscreen_on_my_monitor() {
            var app_sys = AppSystem.get_default();
            var display = Gdk.Display.get_default();
            var monitor = this.gdk_monitor ?? find_shell_monitor();
            if (monitor == null && display != null && display.get_monitors().get_n_items() > 0)
                monitor = display.get_monitors().get_item(0) as Gdk.Monitor;
            bool single = (display == null) || (display.get_monitors().get_n_items() <= 1);
            string? target_conn = (monitor != null) ? monitor.get_connector() : null;
            Gdk.Monitor? primary = (display != null)
                ? display.get_monitors().get_item(0) as Gdk.Monitor : null;
            bool target_is_primary = (primary != null && monitor != null)
                && (primary == monitor || (target_conn != null && primary.get_connector() == target_conn));
            foreach (var win in app_sys.get_windows()) {
                if (!win.is_fullscreen || win.is_minimized) continue;
                if (single || monitor == null) return true;
                var wmon = Singularity.wayland_get_window_monitor(win.handle);
                if (wmon == null) { if (target_is_primary) return true; continue; }
                if (wmon == monitor) return true;
                if (target_conn != null && wmon.get_connector() == target_conn) return true;
            }
            return false;
        }

        private static Gtk.CssProvider? _flat_provider = null;
        private static void apply_flat_opacity(GLib.Settings s) {
            var disp = Gdk.Display.get_default();
            if (disp == null) return;
            if (_flat_provider == null) {
                _flat_provider = new Gtk.CssProvider();
                Gtk.StyleContext.add_provider_for_display(disp, _flat_provider, Gtk.STYLE_PROVIDER_PRIORITY_USER);
            }
            int op = s.get_int("panel-flat-opacity").clamp(0, 100);
            string a = (op >= 100) ? "1" : "0.%02d".printf(op);
            _flat_provider.load_from_string(".panel-window.flat-panel .panel { background-color: rgba(0,0,0,%s); }".printf(a));
        }

        private void update_flat_mode() {
            bool flat_setting = _settings.get_boolean("panel-flat");
            bool force_flat = (gdk_monitor != null)
                ? (AppSystem.get_default().has_maximized_window_on_monitor(gdk_monitor)
                   || has_fullscreen_on_my_monitor())
                : (AppSystem.get_default().has_any_maximized_window()
                   || AppSystem.get_default().has_any_fullscreen_window());
            if (flat_setting || force_flat) {
                add_css_class("flat-panel");
            } else {
                remove_css_class("flat-panel");
            }
            update_topbar_fg_class();
        }

        private void update_visibility() {
            bool fusion = _settings.get_boolean("panel-fusion");
            if (fusion && !is_greeter_mode) {
                set_exclusive_zone(this, 0);
                set_layer(this, GtkLayerShell.Layer.BACKGROUND);
                set_anchor(this, GtkLayerShell.Edge.TOP, false);
                set_anchor(this, GtkLayerShell.Edge.LEFT, false);
                set_anchor(this, GtkLayerShell.Edge.RIGHT, false);
                this.visible = false;
            } else {
                set_layer(this, GtkLayerShell.Layer.OVERLAY);
                set_anchor(this, GtkLayerShell.Edge.TOP, true);
                set_anchor(this, GtkLayerShell.Edge.LEFT, true);
                set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
                this.visible = true;
                present();
                auto_exclusive_zone_enable(this);
            }
        }

        private bool update_clock() {
            clock_label.label = new DateTime.now_local().format(_clock_format_str);
            return true;
        }

        public void set_overview_mode(bool enabled, bool instant = false) {
            if (instant) {
                main_box.add_css_class("no-transition");
                GLib.Idle.add(() => {
                    main_box.remove_css_class("no-transition");
                    return GLib.Source.REMOVE;
                });
            }
            if (enabled) {
                main_box.add_css_class("overview-mode");
            } else {
                main_box.remove_css_class("overview-mode");
            }
        }
        /**
         * Adds a widget to the panel for plugins.
         */

        public void add_widget(Widget widget, Align alignment) {
            if (alignment == Align.START) {
                left_box.append(widget);
            } else if (alignment == Align.END) {
                right_box.prepend(widget);
            } else {
                left_box.append(widget);
            }
        }

        public void add_clock_suffix_widget(Widget widget) {
            clock_suffix_box.append(widget);
        }

        public void remove_widget(Widget widget) {
             if (widget.parent == left_box) left_box.remove(widget);
             else if (widget.parent == right_box) right_box.remove(widget);
             else if (widget.parent == clock_suffix_box) clock_suffix_box.remove(widget);
             else if (widget.parent == main_box) main_box.remove(widget);
        }

        public void set_workspace_btn_visible(bool visible) {
            _dock_hidden = visible;
            workspace_btn.visible = visible || _workspace_overview_active;
        }

        public void set_workspace_overview_active(bool active) {
            _workspace_overview_active = active;
            workspace_btn.visible = _dock_hidden || _workspace_overview_active;
        }

        protected override void dispose() {
            var as = AppSystem.get_default();
            if (_sig_app_focused != 0) { GLib.SignalHandler.disconnect(as, _sig_app_focused); _sig_app_focused = 0; }
            if (_sig_menu_model_changed != 0) { GLib.SignalHandler.disconnect(as, _sig_menu_model_changed); _sig_menu_model_changed = 0; }
            if (_sig_clock != 0) {
                GLib.SignalHandler.disconnect(SharedClock.get_default(), _sig_clock);
                _sig_clock = 0;
            }
            base.dispose();
        }

        // Returns "Label  Accel" or just "Label" if no shortcut is found for the given action.

        private string format_tooltip(string label, ShortcutManager shortcuts, string action_name) {
            foreach (var sc in shortcuts.shortcuts) {
                if (sc.action_name == action_name && sc.accelerator != "") {
                    return "%s  %s".printf(label, format_accel(sc.accelerator));
                }
            }
            return label;
        }

        // Converts a GTK accelerator string like "<Super>space" to "Super+Space".

        private string format_accel(string accel) {
            var s = accel;
            s = s.replace("<Super>", "Super+");
            s = s.replace("<Shift>", "Shift+");
            s = s.replace("<Control>", "Ctrl+");
            s = s.replace("<Alt>", "Alt+");
            s = s.replace("<Primary>", "Ctrl+");
            // Capitalise single-char keys
            if (s.length >= 1) {
                var last = s.substring(s.last_index_of("+") + 1);
                if (last.length == 1)
                    s = s.substring(0, s.length - 1) + last.up();
                else if (last.length > 1)
                    s = s.substring(0, s.length - last.length) + last[0].toupper().to_string() + last.substring(1);
            }
            return s;
        }

        private static Gdk.Monitor? find_shell_monitor() {
            var settings = new GLib.Settings("dev.sinty.desktop");
            string connector = settings.get_string("shell-monitor");
            if (connector == "") return null;
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var mon = (Gdk.Monitor)monitors.get_item(i);
                if (mon.get_connector() == connector) return mon;
            }
            return null;
        }

        public static Gdk.Monitor? find_primary_monitor() {
            var mon = find_shell_monitor();
            if (mon != null) return mon;
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            return display.get_monitors().get_item(0) as Gdk.Monitor;
        }

        public Gdk.Monitor? get_target_monitor() {
            return gdk_monitor;
        }

        /**
         * Samples the top strip of the current wallpaper and toggles the
         * "light-bg" CSS class on the panel-window so text/icon colors adapt.
         * In flat-panel mode the wallpaper is hidden so we skip sampling.
         */
        public static double topbar_lum_threshold = 0.72;

        public static double topbar_strip_fraction(Gdk.Monitor? mon, int fallback_h) {
            int ph = AppSystem.get_default().shell_panel_height;
            if (ph <= 0) ph = fallback_h > 0 ? fallback_h : 40;
            if (mon != null) {
                var geo = mon.get_geometry();
                if (geo.height > 0) return (double) ph / (double) geo.height;
            }
            return 0.05;
        }

        private bool str_has_letter(string s) {
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return true;
            }
            return false;
        }

        private string humanize_app_id(string app_id) {
            string title = app_id.strip();
            if (title.down().has_suffix(".exe")) {
                title = title.substring(0, title.length - 4);
                if (title.contains("\\")) { var p = title.split("\\"); title = p[p.length - 1]; }
                if (title.contains("/"))  { var p = title.split("/");  title = p[p.length - 1]; }
            } else if (title.contains(" ")) {
                var words = title.split(" ");
                var sb = new StringBuilder();
                foreach (string word in words) {
                    if (word.length > 0 && word[0] >= '0' && word[0] <= '9') break;
                    if (sb.len > 0) sb.append_c(' ');
                    sb.append(word);
                }
                title = (sb.len > 0) ? sb.str : words[0];
            } else if (title.contains(".")) {
                var parts = title.split(".");
                string cand = parts[parts.length - 1];
                if (!str_has_letter(cand)) {
                    for (int i = parts.length - 1; i >= 0; i--) {
                        if (str_has_letter(parts[i])) { cand = parts[i]; break; }
                    }
                }
                title = cand;
            }
            title = title.replace("*", "").replace("_", " ").replace("-", " ").strip();
            if (title.length > 0) title = title.substring(0, 1).up() + title.substring(1);
            return title;
        }

        private void update_topbar_fg_class() {
            if (has_css_class("flat-panel")) {
                remove_css_class("light-bg");
                return;
            }
            double frac = topbar_strip_fraction(gdk_monitor, height_request);
            if (_last_strip_lum < 0.0 || frac != _last_frac) {
                double lum = WallpaperManager.get_default().top_band_luminance(frac);
                if (lum < 0.0) lum = fallback_wallpaper_luminance();
                if (lum >= 0.0) { _last_strip_lum = lum; _last_frac = frac; }
            }
            _last_strip_light = (_last_strip_lum >= 0.0) && (_last_strip_lum > topbar_lum_threshold);
            if (_last_strip_light) add_css_class("light-bg");
            else remove_css_class("light-bg");
        }

        // Fallback used when the WallpaperManager display pixbuf is not yet
        // available: decode the wallpaper file directly and average the whole
        // thumbnail, as the topbar contrast did before the band-sampling change.
        private double fallback_wallpaper_luminance() {
            string uri = _settings.get_string("background-picture-uri");
            if (uri == "") return -1.0;
            string? path = GLib.File.new_for_uri(uri).get_path();
            if (path == null) return -1.0;
            try {
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 128, 72, true);
                if (pixbuf.get_bits_per_sample() != 8 || pixbuf.get_n_channels() < 3) return -1.0;
                int ch = pixbuf.get_n_channels();
                int rs = pixbuf.get_rowstride();
                uint8[] data = pixbuf.get_pixels_with_length();
                int n = data.length;
                double total = 0.0;
                int count = 0;
                for (int y = 0; y < pixbuf.get_height(); y++) {
                    for (int x = 0; x < pixbuf.get_width(); x++) {
                        int idx = y * rs + x * ch;
                        if (idx + 2 >= n) continue;
                        total += ColorUtil.srgb_luminance(data[idx] / 255.0,
                                                          data[idx + 1] / 255.0,
                                                          data[idx + 2] / 255.0);
                        count++;
                    }
                }
                return count > 0 ? total / count : -1.0;
            } catch (Error e) {
                return -1.0;
            }
        }

        private Widget create_corner_hint(string corner_class) {
            var overlay = new Overlay();
            overlay.add_css_class("corner-hint");
            overlay.add_css_class(corner_class);

            var glow = new Box(Orientation.HORIZONTAL, 0);
            glow.add_css_class("corner-hint-glow");
            overlay.set_child(glow);

            var badge = new Box(Orientation.HORIZONTAL, 0);
            badge.add_css_class("corner-hint-badge");
            badge.halign = corner_class.has_suffix("tr") ? Align.END : Align.START;
            badge.valign = Align.START;
            badge.margin_top = 12;
            if (badge.halign == Align.START) badge.margin_start = 12;
            else badge.margin_end = 12;
            badge.homogeneous = true;
            var icon = new Image.from_icon_name("view-app-grid-symbolic");
            icon.pixel_size = 18;
            icon.halign = Align.CENTER;
            icon.valign = Align.CENTER;
            badge.append(icon);
            overlay.add_overlay(badge);
            overlay.set_data<Image>("corner-icon", icon);
            return overlay;
        }

        private static string icon_for_corner_action(string? action) {
            switch (action) {
                case "workspaces": return "dev.sinty.workspaces";
                case "overview":   return "view-app-grid-symbolic";
                case "settings":   return "emblem-system-symbolic";
                default:           return "go-next-symbolic";
            }
        }

        public void set_corner_active(int corner, bool active, string? action = null) {
            Widget? w = null;
            if (corner == 0) w = _corner_tl;
            else if (corner == 1) w = _corner_tr;
            if (w == null) return;
            var icon = w.get_data<Image>("corner-icon");
            if (icon != null && action != null) icon.icon_name = icon_for_corner_action(action);
            if (active) w.add_css_class("visible");
            else w.remove_css_class("visible");
        }
    }
}
