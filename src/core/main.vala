using Gtk;
using Goa;

// glibc allocator tuning: the shell runs many threads (Mesa + GLib pools), so
// cap malloc arenas to keep heap fragmentation from being pinned in the process.
[CCode (cname = "mallopt", cheader_filename = "malloc.h")]
extern int c_mallopt (int param, int value);
[CCode (cname = "malloc_trim", cheader_filename = "malloc.h")]
extern int c_malloc_trim (size_t pad);

namespace Singularity {
    // M_ARENA_MAX = -8 (malloc.h); cap at 2 arenas.
    public void cap_malloc_arenas () {
        c_mallopt (-8, 2);
    }
    // Return freed heap pages to the OS after large, bursty operations.
    public void trim_heap () {
        c_malloc_trim (0);
    }
}

public class SingularityApp : Singularity.ShellApplication, Singularity.Shell.ShellService {
    public const string VERSION = "0.1.6";

    public SingularityApp() {
        base("dev.sinty.desktop", ApplicationFlags.FLAGS_NONE);
    }
    private GLib.Settings settings;
    private List<Singularity.Background> backgrounds = new List<Singularity.Background>();
    private Singularity.Overview? overview = null;
    private Singularity.AppMenu? app_menu = null;
    private Singularity.WorkspaceOverview? workspace_overview = null;
    private Singularity.Panel panel;
    private Singularity.Dock dock;
    private Singularity.SessionRecovery? session_recovery = null;
    private List<Singularity.Panel> secondary_panels = new List<Singularity.Panel>();
    private List<Singularity.Dock> secondary_docks = new List<Singularity.Dock>();
    private HashTable<unowned Singularity.Panel, Singularity.Overview> secondary_overviews =
        new HashTable<unowned Singularity.Panel, Singularity.Overview>(direct_hash, direct_equal);
    // Tracks which panel is "active" (last focused window on its monitor)
    private unowned Singularity.Panel? last_active_panel = null;
    private bool secondary_monitor_connected = false;
    private bool secondary_update_pending = false;
    private uint _last_monitor_count = 0;
    public Singularity.Sidebar? sidebar = null;
    private Singularity.NotificationDisplay? notification_display = null;
    private Singularity.RunDialog? run_dialog = null;
    private Singularity.EmojiPicker? emoji_picker = null;
    private Singularity.SettingsWindow? settings_window = null;
    private Singularity.AppSwitcher? app_switcher = null;
    private bool icon_theme_probe_done = false;
    public Singularity.DesktopIcons? desktop_icons = null;
    public Singularity.PreviewManager preview_manager;
    public Singularity.TilingManager tiling_manager;
    private Singularity.AppMenuRegistrar menu_registrar;
    private bool _push_ws_pending = false;
    public Singularity.HotCornerManager? hot_corner_manager = null;
    private Singularity.DebugHudWindow? _debug_hud = null;
    private Singularity.DevtoolsOverlay? _devtools_overlay = null;
    private bool _goa_initialized = false;

    protected override void activate() {
        // Ensure Qt apps use the Wayland backend instead of XCB
        Environment.set_variable("QT_QPA_PLATFORM", "wayland", false);

        // SIGUSR1 = restart: exit cleanly so the wrapper script restarts us
        GLib.Unix.signal_add(Posix.Signal.USR1, () => {
            Process.exit(0);
            return GLib.Source.REMOVE;
        });

        // The brand GTK and icon themes are pinned by ShellApplication.startup
        // (shared with regular apps via StyleManager.pin_brand_themes), so the
        // shell only needs to load its style here.
        Singularity.Style.StyleManager.get_default().load_theme();
        settings = new GLib.Settings("dev.sinty.desktop");
        settings.changed["accent-color"].connect(() => {
            update_accent_color();
        });
        settings.changed["custom-accent-color"].connect(() => {
            if (settings.get_string("accent-color") == "custom") {
                update_accent_color();
            }
        });
        settings.changed["background-picture-uri"].connect(() => {
            if (settings.get_string("accent-color") == "wallpaper") {
                update_accent_color();
            } else {
                persist_user_appearance();
            }
        });
        settings.changed["dark-mode"].connect(() => {
            update_theme_mode();
        });
        settings.changed["singularity-theme"].connect(() => {
            Singularity.Style.StyleManager.get_default().load_user_theme(
                settings.get_string("singularity-theme"));
        });
        Idle.add(() => {
            update_accent_color();
            update_theme_mode();
            Singularity.Style.StyleManager.get_default().load_user_theme(
                settings.get_string("singularity-theme"));
            return Source.REMOVE;
        });

#if DEBUG
        // Optional debug: probe icon rendering by switching to Adwaita for 1s
        if (GLib.Environment.get_variable("SINGULARITY_ICON_THEME_PROBE") == "1" && !icon_theme_probe_done) {
            icon_theme_probe_done = true;
            var gtk_settings = Gtk.Settings.get_default();
            if (gtk_settings != null) {
                string original_icon_theme = gtk_settings.gtk_icon_theme_name;
                message("DEBUG: Icon theme probe: switching to Adwaita for 1s (was '%s')", original_icon_theme);
                gtk_settings.gtk_icon_theme_name = "Adwaita";
                GLib.Timeout.add(1000, () => {
                    gtk_settings.gtk_icon_theme_name = original_icon_theme;
                    message("DEBUG: Icon theme probe: restored '%s'", original_icon_theme);
                    return GLib.Source.REMOVE;
                });
            }
        }
#endif

        var display = Gdk.Display.get_default();
        if (display != null) {
            var icon_theme = Gtk.IconTheme.get_for_display(display);
            var build_icons_path = GLib.Environment.get_current_dir() + "/build/share/icons";
            if (FileUtils.test(build_icons_path, FileTest.IS_DIR)) {
                icon_theme.add_search_path(build_icons_path);
            }
        }

        apply_icon_theme();
        settings.changed["icon-theme"].connect(apply_icon_theme);
        apply_cursor_theme();
        settings.changed["cursor-theme"].connect(apply_cursor_theme);
        apply_x_font_settings();
        Singularity.AppSystem.get_default();
        // Launch the user's autostart entries once the session has settled
        // (bus, portals); nothing else in the shell did this before (#170).
        Timeout.add_seconds(1, () => { launch_autostart_apps(); return Source.REMOVE; });
        var cal_manager = Singularity.Calendar.CalendarManager.get_default();
        cal_manager.register_provider(new Singularity.Calendar.LocalProvider());
        Bus.own_name(
            BusType.SESSION,
            "org.freedesktop.Notifications",
            BusNameOwnerFlags.NONE,
            (conn) => {
                try {
                    conn.register_object<Singularity.NotificationManager>(
                        "/org/freedesktop/Notifications",
                        Singularity.SystemMonitor.get_default().notifications
                    );
                } catch (IOError e) {
                    warning("Failed to register Notification Service: %s", e.message);
                }
            },
            () => {},
            () => { warning("Lost name org.freedesktop.Notifications"); }
        );

        // Fan notifications out to plugins so they can react (e.g. Telegram
        // dock-bubble plugin) without each one re-implementing the daemon.
        var _nm = Singularity.SystemMonitor.get_default().notifications;
        _nm.new_notification.connect(
            (id, app_name, summary, body, icon, actions) => {
                Singularity.PluginManager.get_default().get_context()
                    .emit_notification(id, app_name, summary, body, icon);
            });
        Singularity.PluginManager.get_default().get_context()
            .notification_dismiss_requested.connect((id) => {
                _nm.close_notification(id);
            });
        // Mirror "notification closed" events out to plugins so they can
        // keep their derived state in sync (e.g. the messaging-dock plugin
        // decrements unread counts when the user clears notifications).
        _nm.notification_closed.connect((id, reason) => {
            Singularity.PluginManager.get_default().get_context()
                .emit_notification_closed(id, reason);
        });

        // Register Global Menu Registrar. When the global menu is disabled we
        // do not own this name, so apps find no menu host and keep their own
        // in-window menu bar instead (#146). Takes effect on next login.
        if (settings.get_boolean("global-menu-enabled")) {
            menu_registrar = new Singularity.AppMenuRegistrar();
            Bus.own_name(
                BusType.SESSION,
                "com.canonical.AppMenu.Registrar",
                BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        conn.register_object<Singularity.AppMenuRegistrar>(
                            "/com/canonical/AppMenu/Registrar",
                            menu_registrar
                        );
                    } catch (IOError e) {
                        warning("Failed to register AppMenu Registrar: %s", e.message);
                    }
                },
                () => {},
                () => { warning("Lost name com.canonical.AppMenu.Registrar"); }
            );
        }

        setup_backgrounds();
        hot_corner_manager = new Singularity.HotCornerManager(this);
        hot_corner_manager.overview_triggered.connect(() => toggle_overview());
        hot_corner_manager.workspaces_triggered.connect(() => toggle_workspace_overview());
        hot_corner_manager.settings_triggered.connect(() => { ensure_sidebar(); sidebar.toggle_system(); });
        var surfaces = Singularity.ShellSurfaceRegistry.get_default();
        // A plugin can claim the panel / dock role and replace the built-in.
        if (!surfaces.is_claimed(Singularity.ShellRole.PANEL)) {
            panel = new Singularity.Panel(this);
            hot_corner_manager.attach_to_panel(panel);
        } else {
            activate_shell_surface(Singularity.ShellRole.PANEL);
        }
        if (!surfaces.is_claimed(Singularity.ShellRole.DOCK)) {
            dock = new Singularity.Dock(this);
            hot_corner_manager.attach_to_dock(dock);
            Singularity.DebugManager.get_default().dock_inspect = dock;
        } else {
            activate_shell_surface(Singularity.ShellRole.DOCK);
        }
        notification_display = new Singularity.NotificationDisplay(this);
        setup_shell_monitor_listener();
        setup_secondary_surfaces();
        tiling_manager = new Singularity.TilingManager(Singularity.AppSystem.get_default());

        // Session recovery: snapshot windows on session end; offer to reopen
        // them (via a dialog) at the next login.
        session_recovery = new Singularity.SessionRecovery();
        Singularity.SessionManager.get_default().session_ending.connect(() => {
            session_recovery.capture();
        });
        maybe_offer_session_restore();

        // Deferred non-critical module creation
        Idle.add(() => {
            update_desktop_icons();
            preview_manager = new Singularity.PreviewManager(this);
            var _resources = Singularity.SystemMonitor.get_default().resources;
            _resources.alert.connect((summary, body, icon) => {
                var mgr = Singularity.SystemMonitor.get_default().notifications;
                uint nid = mgr.next_id++;
                mgr.new_notification(nid, "Singularity", summary, body, icon, new string[0]);
            });
            _resources.start();
            GLib.Timeout.add(200, () => {
                var _rt = GLib.Environment.get_variable("XDG_RUNTIME_DIR");
                if (_rt != null && _rt != "") {
                    try { GLib.FileUtils.set_contents(_rt + "/singularity-shell-ready", ""); }
                    catch (GLib.Error e) {}
                }
                return GLib.Source.REMOVE;
            });
            // Pre-warm widget modules (dlopen) at login so the first overview
            // open isn't stalled loading them.
            Singularity.OverviewWidgetRegistry.get_default().load_manifests();
            // Pre-create the search manager so the file provider's Tracker
            // connection is established at login, not on the first search.
            Singularity.SearchManager.get_default();
            Singularity.NowPlayingCache.get_default();
            // Once the startup allocation storm (GL shader compile, icon and
            // theme loading) has settled, hand the freed pages back to the OS.
            GLib.Timeout.add_seconds(10, () => {
                Singularity.trim_heap();
                return GLib.Source.REMOVE;
            });
            return Source.REMOVE;
        });
        settings.changed["show-desktop-icons"].connect(() => {
            update_desktop_icons();
        });

        // Wire DebugManager references for use from the Developer page
        var dbg = Singularity.DebugManager.get_default();
        dbg.hot_corner_manager = hot_corner_manager;
        dbg.tiling_manager = tiling_manager;

        // HUD is created lazily the first time it's toggled on
        dbg.notify["hud-visible"].connect(() => {
            if (dbg.hud_visible) {
                if (_debug_hud == null)
                    _debug_hud = new Singularity.DebugHudWindow(this);
                _debug_hud.present ();
                _debug_hud.start_updates ();
            } else if (_debug_hud != null) {
                _debug_hud.hide ();
                _debug_hud.stop_updates ();
            }
        });

        // DevTools overlay is created lazily the first time it's toggled on
        dbg.notify["devtools-visible"].connect(() => {
            if (dbg.devtools_visible) {
                if (_devtools_overlay == null)
                    _devtools_overlay = new Singularity.DevtoolsOverlay(this);
                _devtools_overlay.present ();
            } else if (_devtools_overlay != null) {
                _devtools_overlay.hide ();
            }
        });

         Singularity.AppSystem.get_default().set_registrar(menu_registrar);
        Idle.add(() => {
            ensure_global_menu_support();
            return Source.REMOVE;
        });
        apply_window_management_settings();
        Singularity.SystemMonitor.get_default().shortcuts.launcher_triggered.connect(() => {
            toggle_overview();
        });
        Singularity.SystemMonitor.get_default().shortcuts.workspace_overview_triggered.connect(() => {
            toggle_workspace_overview();
        });
        Singularity.SystemMonitor.get_default().shortcuts.run_command_triggered.connect(() => {
            ensure_run_dialog();
            run_dialog.toggle();
        });
        Singularity.SystemMonitor.get_default().shortcuts.emoji_picker_triggered.connect(() => {
            ensure_emoji_picker();
            emoji_picker.toggle();
        });
        Singularity.SystemMonitor.get_default().shortcuts.retile_triggered.connect(() => {
            if (tiling_manager != null) {
                tiling_manager.apply_layout();
            } else {
                warning("TilingManager is null, cannot apply layout");
            }
        });
        Singularity.AppSystem.get_default().desktop_action_requested.connect((action) => {
            ensure_sidebar();
            switch (action) {
                case "about":    sidebar.open_page("system"); break;
                case "settings": sidebar.open_page("home");  break;
            }
        });
        connect_shell_signals();
        // Close any open overview when an app gains focus (covers dock launches).
        Singularity.AppSystem.get_default().app_focused.connect((app_id) => {
            if (app_id == null) return;
            if (overview != null && overview.showing) overview.toggle();
            if (app_menu != null && app_menu.visible) app_menu.toggle();
            secondary_overviews.foreach((p, ov) => {
                if (ov.showing) ov.toggle();
            });
        });
        var conn = get_dbus_connection();
        if (conn != null) {
            try {
                conn.register_object<Singularity.Shell.ShellService>("/dev/sinty/Shell", this);
            } catch (IOError e) {
                warning("Failed to register Shell Service: %s", e.message);
            }
        }
        // Initialize Plugin Manager
        var plugin_manager = Singularity.PluginManager.get_default();
        var context = plugin_manager.get_context();
        context.panel_widget_added.connect((widget, align) => {
            if (panel != null) panel.add_widget(widget, align);
        });
        context.panel_widget_removed.connect((widget) => {
            if (panel != null) panel.remove_widget(widget);
        });
        context.clock_suffix_widget_added.connect((widget) => {
            if (panel != null) panel.add_clock_suffix_widget(widget);
        });

        // Funnel plugin-registered overview widgets / search providers into
        // the global registries that the overview consumes.
        context.overview_widget_added.connect((p) =>
            Singularity.OverviewWidgetRegistry.get_default().add(p));
        context.overview_widget_removed.connect((p) =>
            Singularity.OverviewWidgetRegistry.get_default().remove(p));
        context.search_provider_added.connect((p) =>
            Singularity.SearchProviderRegistry.get_default().add(p));
        context.search_provider_removed.connect((p) =>
            Singularity.SearchProviderRegistry.get_default().remove(p));
        context.vpn_provider_added.connect((p) =>
            Singularity.VpnProviderRegistry.get_default().add(p));
        context.vpn_provider_removed.connect((p) =>
            Singularity.VpnProviderRegistry.get_default().remove(p));
        context.shell_surface_provider_added.connect((p) =>
            Singularity.ShellSurfaceRegistry.get_default().add(p));
        context.shell_surface_provider_removed.connect((p) =>
            Singularity.ShellSurfaceRegistry.get_default().remove(p));
        // Live re-arbitration: when a plugin claims / releases a surface
        // role at runtime, rebuild the shell surfaces so the built-in dock /
        // panel is suppressed (or restored) - no restart needed.
        Singularity.ShellSurfaceRegistry.get_default().changed.connect(() => {
            GLib.Idle.add(() => { recreate_shell_surfaces(); return GLib.Source.REMOVE; });
        });

        // Wire AppSystem workspaces, PluginContext
        var app_sys = Singularity.AppSystem.get_default();
        app_sys.workspaces_changed.connect(() => {
            if (_push_ws_pending) return;
            _push_ws_pending = true;
            GLib.Idle.add(() => {
                _push_ws_pending = false;
                var descs = new List<Singularity.WorkspaceDescriptor>();
                int idx = 0;
                foreach (var ws in app_sys.get_workspaces()) {
                    descs.append(new Singularity.WorkspaceDescriptor(ws.name, ws.active, idx++));
                }
                context.update_workspaces(descs);
                return GLib.Source.REMOVE;
            });
        });
        // Initial push
        {
            var descs = new List<Singularity.WorkspaceDescriptor>();
            int idx = 0;
            foreach (var ws in app_sys.get_workspaces()) {
                descs.append(new Singularity.WorkspaceDescriptor(ws.name, ws.active, idx++));
            }
            context.update_workspaces(descs);
        }
        context.workspace_switch_requested.connect((index) => {
            int i = 0;
            foreach (var ws in app_sys.get_workspaces()) {
                if (i++ == index) {
                    app_sys.activate_workspace(ws);
                    break;
                }
            }
        });

        // Load plugins after a short delay so shell surfaces are ready first
        Timeout.add(500, () => {
            plugin_manager.load_plugins();
            return Source.REMOVE;
        });

    }

    private async void init_goa() {
        if (_goa_initialized) return;
        _goa_initialized = true;
        try {
            var client = yield new global::Goa.Client(null);
            var objects = client.get_accounts();
            foreach (var object in objects) {
                if (object.calendar != null) {
                    var provider = new Singularity.Goa.GoaCalendarProvider(object);
                    Singularity.Calendar.CalendarManager.get_default().register_provider(provider);
                }
            }
            client.account_added.connect((object) => {
                if (object.calendar != null) {
                    var provider = new Singularity.Goa.GoaCalendarProvider(object);
                    Singularity.Calendar.CalendarManager.get_default().register_provider(provider);
                }
            });
        } catch (GLib.Error e) {
            warning("Failed to initialize GOA: %s", e.message);
        }
    }

    public void ensure_goa_calendar() {
        init_goa.begin();
    }

    private void ensure_emoji_picker() {
        if (emoji_picker == null) {
            emoji_picker = new Singularity.EmojiPicker(this);
        }
    }

    private void ensure_run_dialog() {
        if (run_dialog == null) {
            run_dialog = new Singularity.RunDialog(this);
        }
    }

    private void update_desktop_icons() {
        if (settings.get_boolean("show-desktop-icons")) {
            // Recreate so the surface re-anchors to the current primary monitor;
            // this also brings the icons back after a monitor is toggled (#56).
            if (desktop_icons != null) {
                desktop_icons.destroy();
                desktop_icons = null;
            }
            desktop_icons = new Singularity.DesktopIcons(this,
                Singularity.Panel.find_primary_monitor());
        } else if (desktop_icons != null) {
            desktop_icons.destroy();
            desktop_icons = null;
        }
    }

    // After login, if the previous session was snapshotted, offer to reopen
    // the windows via a dialog (nothing is restored without confirmation).
    private void maybe_offer_session_restore() {
        if (session_recovery == null || !session_recovery.has_session()) return;
        var entries = session_recovery.load();
        if (entries.size == 0) { session_recovery.clear(); return; }
        // Defer a moment so the shell surfaces are settled before the prompt.
        GLib.Timeout.add(700, () => {
            var dialog = new Singularity.SessionRestoreDialog(this, entries, (sel) => {
                session_recovery.restore(sel);
            });
            dialog.open_dialog();
            return GLib.Source.REMOVE;
        });
    }

    private void connect_shell_signals() {
        // panel / dock may be null when a plugin has claimed that surface.
        if (panel != null) {
            panel.activities_clicked.connect(() => toggle_overview());
            panel.clock_clicked.connect(() => { ensure_sidebar(); sidebar.toggle_calendar(); });
            panel.notifications_clicked.connect(() => { ensure_sidebar(); sidebar.toggle_notifications(); });
            panel.system_clicked.connect(() => { ensure_sidebar(); sidebar.toggle_system(); });
            panel.workspace_clicked.connect(() => toggle_workspace_overview());
        }
        if (dock != null) {
            dock.activities_clicked.connect(() => toggle_overview());
            dock.workspace_clicked.connect(() => toggle_workspace_overview());
            dock.dock_visibility_changed.connect((hidden) => {
                if (panel != null) panel.set_workspace_btn_visible(hidden);
            });
            dock.system_clicked.connect(() => { ensure_sidebar(); sidebar.toggle_system(); });
        }
    }

    // Currently-active plugin surface hosts, keyed by role, for cleanup.
    private Gee.HashMap<int, Singularity.ShellSurfaceHost> _surface_hosts =
        new Gee.HashMap<int, Singularity.ShellSurfaceHost>();

    // Hand a claimed role over to its plugin provider.
    private void activate_shell_surface(Singularity.ShellRole role) {
        var provider = Singularity.ShellSurfaceRegistry.get_default().claimant(role);
        if (provider == null) return;
        var display = Gdk.Display.get_default();
        if (display == null) return;
        if (provider.mode == Singularity.ShellSurfaceMode.CONTENT_INJECTION) {
            // Shell-owned host window on the primary monitor (multi-monitor
            // hosts can be added the same way as secondary surfaces).
            var mon = Singularity.Panel.find_primary_monitor();
            if (mon == null && display.get_monitors().get_n_items() > 0)
                mon = display.get_monitors().get_item(0) as Gdk.Monitor;
            if (mon != null)
                _surface_hosts[(int) role] =
                    new Singularity.ShellSurfaceHost(this, provider, mon);
        } else {
            // SURFACE_OWNERSHIP: the provider runs its own surface.
            var mon = Singularity.Panel.find_primary_monitor();
            if (mon == null && display.get_monitors().get_n_items() > 0)
                mon = display.get_monitors().get_item(0) as Gdk.Monitor;
            if (mon != null) provider.surface_activate(mon);
        }
    }

    private bool _shell_monitor_update_pending = false;

    private void setup_shell_monitor_listener() {
        settings.changed.connect((key) => {
            if (key != "shell-monitor" && key != "dock-multi-monitor" && key != "panel-multi-monitor") return;
            if (_shell_monitor_update_pending) return;
            _shell_monitor_update_pending = true;
            GLib.Idle.add(() => {
                _shell_monitor_update_pending = false;
                recreate_shell_surfaces();
                return GLib.Source.REMOVE;
            });
        });
    }

    private bool _recreating = false;

    private void recreate_shell_surfaces() {
        if (_recreating) return;
        _recreating = true;

        // Mark windows insensitive before destruction to prevent at-spi2
        // from iterating children of a window already in dispose (SIGSEGV).
        if (panel != null) { panel.sensitive = false; panel.destroy(); }
        if (dock != null) { dock.sensitive = false; dock.destroy(); }
        foreach (var p in secondary_panels) { p.sensitive = false; p.destroy(); }
        foreach (var d in secondary_docks) { d.sensitive = false; d.destroy(); }
        secondary_overviews.remove_all();
        secondary_panels = new List<Singularity.Panel>();
        secondary_docks = new List<Singularity.Dock>();

        // Tear down any plugin-owned surfaces before rebuilding so we don't
        // leave a stale host / double surface around.
        teardown_shell_surface(Singularity.ShellRole.PANEL);
        teardown_shell_surface(Singularity.ShellRole.DOCK);

        var surfaces = Singularity.ShellSurfaceRegistry.get_default();
        panel = null;
        dock = null;
        if (surfaces.is_claimed(Singularity.ShellRole.PANEL)) {
            activate_shell_surface(Singularity.ShellRole.PANEL);
        } else {
            panel = new Singularity.Panel(this);
        }
        if (surfaces.is_claimed(Singularity.ShellRole.DOCK)) {
            activate_shell_surface(Singularity.ShellRole.DOCK);
        } else {
            dock = new Singularity.Dock(this);
        }
        connect_shell_signals();
        if (hot_corner_manager != null) {
            if (panel != null) hot_corner_manager.attach_to_panel(panel);
            if (dock != null) hot_corner_manager.attach_to_dock(dock);
        }
        setup_secondary_surfaces();
        _recreating = false;
    }

    // Tear down a plugin-owned surface for a role (host window + provider).
    private void teardown_shell_surface(Singularity.ShellRole role) {
        if (_surface_hosts.has_key((int) role)) {
            _surface_hosts[(int) role].destroy();
            _surface_hosts.unset((int) role);
        }
        var provider = Singularity.ShellSurfaceRegistry.get_default().claimant(role);
        if (provider != null &&
            provider.mode == Singularity.ShellSurfaceMode.SURFACE_OWNERSHIP) {
            var display = Gdk.Display.get_default();
            if (display != null) {
                for (uint i = 0; i < display.get_monitors().get_n_items(); i++) {
                    var mon = display.get_monitors().get_item(i) as Gdk.Monitor;
                    if (mon != null) provider.surface_deactivate(mon);
                }
            }
        }
    }

    private void setup_secondary_surfaces() {
        bool dock_multi = settings.get_boolean("dock-multi-monitor");
        bool panel_multi = settings.get_boolean("panel-multi-monitor");
        if (!dock_multi && !panel_multi) return;

        var primary_mon = Singularity.Panel.find_primary_monitor();
        var display = Gdk.Display.get_default();
        if (display == null) return;
        var monitors = display.get_monitors();

        for (uint i = 0; i < monitors.get_n_items(); i++) {
            var mon = (Gdk.Monitor)monitors.get_item(i);
            if (mon == primary_mon) continue;
            if (panel_multi) {
                var sec_panel = new Singularity.Panel(this, false, false, mon);
                secondary_panels.append(sec_panel);
                sec_panel.activities_clicked.connect(() => toggle_overview_on_panel(sec_panel));
                if (hot_corner_manager != null) hot_corner_manager.attach_to_panel(sec_panel);
            }
            if (dock_multi) {
                var sec_dock = new Singularity.Dock(this, false, mon);
                secondary_docks.append(sec_dock);
                sec_dock.workspace_clicked.connect(() => toggle_workspace_overview());
                if (hot_corner_manager != null) hot_corner_manager.attach_to_dock(sec_dock);
            }
        }

        // Tell primary dock which secondary monitors exist so it can filter
        if (dock_multi) {
            var sec_mons = new Gee.ArrayList<Gdk.Monitor>();
            foreach (var sd in secondary_docks) {
                var sm = sd.get_target_monitor();
                if (sm != null) sec_mons.add(sm);
            }
            if (dock != null) dock.set_secondary_monitors(sec_mons);
        }

        if (!secondary_monitor_connected) {
            secondary_monitor_connected = true;
            _last_monitor_count = monitors.get_n_items();
            monitors.items_changed.connect((pos, removed, added) => {
                if (secondary_update_pending) return;
                uint new_count = monitors.get_n_items();
                if (new_count == _last_monitor_count) return;
                secondary_update_pending = true;
                Idle.add(() => {
                    secondary_update_pending = false;
                    _last_monitor_count = new_count;
                    recreate_shell_surfaces();
                    return false;
                });
            });
        }
    }

    private void ensure_sidebar() {
        if (sidebar == null) {
            sidebar = new Singularity.Sidebar(this);
        }
        sidebar.update_max_height(Singularity.AppSystem.get_default().shell_panel_height, Singularity.AppSystem.get_default().shell_dock_height);
    }

    private void ensure_settings_window() {
        if (settings_window == null) {
            settings_window = new Singularity.SettingsWindow(this);
        }
    }
    // Opens overview anchored to the given panel (for secondary monitors)

    private void toggle_overview_on_panel(Singularity.Panel anchor_panel) {
        if (workspace_overview != null && workspace_overview.visible) {
            workspace_overview.toggle();
        }
        string mode = settings.get_string("app-launcher-mode");
        if (mode == "menu") {
            if (overview != null && overview.showing) overview.toggle();
            if (app_menu == null) {
                app_menu = new Singularity.AppMenu(this);
            }
            app_menu.toggle();
        } else {
            if (app_menu != null && app_menu.visible) app_menu.toggle();
            // Close primary overview if open
            if (overview != null && overview.showing) overview.toggle();
            // Close other secondary overviews
            secondary_overviews.foreach((p, ov) => {
                if (p != anchor_panel && ov.showing) ov.toggle();
            });
            // Toggle this panel's overview (create if needed)
            var existing = secondary_overviews.lookup(anchor_panel);
            if (existing != null) {
                existing.toggle();
            } else {
                var sec_overview = new Singularity.Overview(this, anchor_panel);
                secondary_overviews.insert(anchor_panel, sec_overview);
                sec_overview.shown.connect(() => {
                    anchor_panel.set_overview_mode(true);
                });
                sec_overview.hiding.connect(() => {
                    anchor_panel.set_overview_mode(false);
                });
                sec_overview.toggle();
            }
        }
    }

    private void toggle_overview() {
        // A plugin can claim the overview / launcher role and handle the
        // toggle itself (built-in overview is never constructed).
        var surfaces = Singularity.ShellSurfaceRegistry.get_default();
        var ov_claim = surfaces.claimant(Singularity.ShellRole.OVERVIEW)
                       ?? surfaces.claimant(Singularity.ShellRole.LAUNCHER);
        if (ov_claim != null) { ov_claim.toggle(); return; }

        if (workspace_overview != null && workspace_overview.visible) {
            workspace_overview.toggle();
        }

        // Detect which monitor the focused window is on and open overview there
        if (!secondary_panels.is_empty()) {
            var app_system = Singularity.AppSystem.get_default();
            var focused = app_system.get_focused_window_handle();
            if (focused != null) {
                var wmon = Singularity.wayland_get_window_monitor(focused);
                if (wmon != null) {
                    foreach (var sp in secondary_panels) {
                        if (sp.get_target_monitor() == wmon) {
                            toggle_overview_on_panel(sp);
                            return;
                        }
                    }
                }
            }
        }

        string mode = settings.get_string("app-launcher-mode");
        if (mode == "menu") {
            if (overview != null && overview.showing) overview.toggle();
            if (app_menu == null) {
                app_menu = new Singularity.AppMenu(this);
            }
            app_menu.toggle();
        } else {
            if (app_menu != null && app_menu.visible) app_menu.toggle();
            // Close any secondary overviews before opening primary
            secondary_overviews.foreach((p, ov) => {
                if (ov.showing) ov.toggle();
            });
            if (overview == null) {
                overview = new Singularity.Overview(this, panel);
                overview.shown.connect(() => {
                    if (panel != null) panel.set_overview_mode(true);
                    if (dock != null) dock.set_overview_mode(true);
                });
                overview.hiding.connect(() => {
                    if (panel != null) panel.set_overview_mode(false);
                    if (dock != null) dock.set_overview_mode(false);
                });
            }
            overview.toggle();
        }
    }

    private void toggle_workspace_overview() {
        // A plugin can claim the workspaces role.
        var ws_claim = Singularity.ShellSurfaceRegistry.get_default()
                       .claimant(Singularity.ShellRole.WORKSPACES);
        if (ws_claim != null) { ws_claim.toggle(); return; }

        if (overview != null && overview.showing) {
            overview.toggle();
        }
        if (workspace_overview == null) {
            workspace_overview = new Singularity.WorkspaceOverview(this);
            workspace_overview.shown.connect(() => {
                if (panel != null) {
                    panel.set_overview_mode(true);
                    panel.set_workspace_overview_active(true);
                }
                if (dock != null) dock.set_overview_mode(true);
                foreach (var p in secondary_panels) p.set_overview_mode(true);
                foreach (var d in secondary_docks) d.set_overview_mode(true);
            });
            workspace_overview.hidden.connect(() => {
                if (dock != null) dock.set_overview_mode(false);
                if (panel != null) {
                    panel.set_overview_mode(false, true);
                    panel.set_workspace_overview_active(false);
                }
                foreach (var p in secondary_panels) p.set_overview_mode(false, true);
                foreach (var d in secondary_docks) d.set_overview_mode(false);
            });
        }
        workspace_overview.toggle();
    }

    private void setup_backgrounds() {
        foreach (var bg in backgrounds) {
            bg.destroy();
        }
        backgrounds = new List<Singularity.Background>();
        var display = Gdk.Display.get_default();
        var monitors = display.get_monitors();
        for (uint i = 0; i < monitors.get_n_items(); i++) {
            var monitor = (Gdk.Monitor)monitors.get_item(i);
            backgrounds.append(new Singularity.Background(this, monitor));
        }
        // Connect items_changed only once on first call (store the ListModel)
        if (!backgrounds_monitor_connected) {
            backgrounds_monitor_connected = true;
            monitors.items_changed.connect((pos, removed, added) => {
                // Debounce: wait one idle cycle so labwc finishes surface commits
                if (backgrounds_update_pending) return;
                backgrounds_update_pending = true;
                Idle.add(() => {
                    backgrounds_update_pending = false;
                    setup_backgrounds();
                    // Re-anchor the desktop icons to the primary monitor too,
                    // so they do not jump or vanish when a monitor toggles (#56/#105).
                    update_desktop_icons();
                    return false;
                });
            });
        }
    }
    private bool backgrounds_monitor_connected = false;
    private bool backgrounds_update_pending = false;

    private void update_accent_color() {
        string color_name = settings.get_string("accent-color");
        string? wallpaper_path = null;
        if (color_name == "wallpaper") {
            string uri = settings.get_string("background-picture-uri");
            if (uri != "") {
                var file = File.new_for_uri(uri);
                wallpaper_path = file.get_path();
            }
        } else if (color_name == "custom") {
            // Pass hex directly; apply_accent_color handles "#rrggbb" as-is.
            string hex = settings.get_string("custom-accent-color");
            if (hex == "" || hex == null) hex = "#3584e4";
            color_name = hex;
        }
        Singularity.Style.StyleManager.get_default().apply_accent_color(color_name, wallpaper_path);
        // Sync to org.gnome.desktop.interface so GTK4/libadwaita apps pick up the accent color.
        // Wallpaper-derived and custom colors have no named equivalent; skip syncing.
        if (color_name != "wallpaper" && !color_name.has_prefix("#")) {
            try {
                var iface = new GLib.Settings("org.gnome.desktop.interface");
                iface.set_string("accent-color", color_name);
            } catch (GLib.Error e) {
                warning("Failed to sync accent-color to org.gnome.desktop.interface: %s", e.message);
            }
        }
        // Re-tint the labwc SSD titlebar to follow the new accent.
        apply_labwc_theme(settings.get_boolean("dark-mode"));
        persist_user_appearance();
    }

    private void persist_user_appearance() {
        string accent = Singularity.Style.StyleManager.get_default().accent_hex;
        string bg = settings.get_string("background-picture-uri");
        var acc = Singularity.Core.Users.AccountsService.get_default();
        acc.set_desktop_string.begin("Accent", accent);
        acc.set_desktop_string.begin("Background", bg);
    }

    private void update_theme_mode() {
        bool dark = settings.get_boolean("dark-mode");
        var gtk_settings = Gtk.Settings.get_default();
        if (gtk_settings != null) {
            gtk_settings.gtk_application_prefer_dark_theme = dark;
        } else {
            warning("Gtk.Settings.get_default() returned null");
        }
        Singularity.Style.StyleManager.get_default().apply_color_scheme(dark);
        // Re-apply accent after scheme change so derived accent colors are
        // re-generated against the correct dark/light palette.
        update_accent_color();
        // Propagate dark/light preference so non-Singularity apps follow our mode.
        try {
            var iface = new GLib.Settings("org.gnome.desktop.interface");
            iface.set_string("color-scheme", dark ? "prefer-dark" : "default");
            // Do NOT touch gtk-theme in GSettings - that is a system-wide setting
            // affecting all GTK apps. Our per-process gtk_theme_name override (set
            // at startup with a notify guard) is sufficient for Singularity processes.
        } catch (GLib.Error e) {
            warning("Failed to sync theme to org.gnome.desktop.interface: %s", e.message);
        }
        // GTK3 has no portal appearance backend, so write its settings.ini for
        // dark mode. GTK4 apps already follow color-scheme through the portal.
        string prefer = dark ? "1" : "0";
        try {
            string gtk3_dir = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".config", "gtk-3.0");
            GLib.DirUtils.create_with_parents(gtk3_dir, 0755);
            GLib.FileUtils.set_contents(
                GLib.Path.build_filename(gtk3_dir, "settings.ini"),
                "[Settings]\ngtk-application-prefer-dark-theme=%s\n".printf(prefer));
        } catch (GLib.Error e) {
            warning("Failed to write gtk-3.0/settings.ini: %s", e.message);
        }
        // labwc themerc is refreshed by update_accent_color() above (called via
        // the accent re-apply), so no separate call is needed here.
    }

    private void apply_labwc_theme(bool dark) {
        // Neutral SSD bases (dark/light), lightly tinted with the system accent
        // so the labwc titlebar follows the accent without becoming a strong
        // colour. Accent hex comes from the StyleManager (single source).
        string accent = Singularity.Style.StyleManager.get_default().accent_hex;
        string title_base    = dark ? "#2d2d2e" : "#f0efee";
        string border_base   = dark ? "#444444" : "#cccccc";
        string inact_base     = dark ? "#1e1e1f" : "#f6f5f4";
        string inact_brd_base = dark ? "#2a2a2a" : "#dddddd";
        string text_active   = dark ? "#ffffff" : "#1a1a1a";
        string btn_base      = dark ? "#cccccc" : "#444444";
        string btn_hover_base = dark ? "#ffffff" : "#1a1a1a";
        string btn_inact     = dark ? "#555555" : "#bbbbbb";

        string title  = mix_hex(title_base,     accent, dark ? 0.06 : 0.05);
        string border = mix_hex(border_base,    accent, 0.10);
        string inact  = mix_hex(inact_base,     accent, 0.03);
        string inactb = mix_hex(inact_brd_base, accent, 0.06);
        string btn    = mix_hex(btn_base,       accent, 0.20);
        string btnh   = mix_hex(btn_hover_base, accent, 0.20);

        string themerc = """# Singularity labwc theme (accent-tinted)
window.active.title.bg.color: %s
window.active.title.bg: flat
window.active.label.text.color: %s
window.active.border.color: %s
window.active.handle.bg.color: %s
window.active.handle.bg: flat
window.active.grip.bg.color: %s
window.active.grip.bg: flat
window.inactive.title.bg.color: %s
window.inactive.title.bg: flat
window.inactive.label.text.color: #888888
window.inactive.border.color: %s
window.inactive.handle.bg.color: %s
window.inactive.handle.bg: flat
window.inactive.grip.bg.color: %s
window.inactive.grip.bg: flat
window.active.button.unpressed.image.color: %s
window.active.button.hover.image.color: %s
window.inactive.button.unpressed.image.color: %s
window.active.shadow.size: %d
window.inactive.shadow.size: %d
window.active.shadow.color: %s
window.inactive.shadow.color: %s
""".printf(
            title, text_active, border, title, title,
            inact, inactb, inact, inact,
            btn, btnh, btn_inact,
            dark ? 40 : 24, dark ? 28 : 12,
            dark ? "#00000055" : "#00000030",
            dark ? "#00000030" : "#00000015");
        var labwc = Singularity.Compositor.LabwcBackend.get_default();
        if (labwc.write_config("themerc-override", themerc)) {
            labwc.reconfigure();
        }
    }

    // Blends two "#rrggbb" colours: t=0 returns a, t=1 returns b.
    private string mix_hex(string a, string b, double t) {
        uint8 ar, ag, ab, br, bg, bb;
        parse_hex6(a, out ar, out ag, out ab);
        parse_hex6(b, out br, out bg, out bb);
        uint8 r = (uint8)(ar * (1.0 - t) + br * t + 0.5);
        uint8 g = (uint8)(ag * (1.0 - t) + bg * t + 0.5);
        uint8 bl = (uint8)(ab * (1.0 - t) + bb * t + 0.5);
        return "#%02x%02x%02x".printf(r, g, bl);
    }

    private void parse_hex6(string hex, out uint8 r, out uint8 g, out uint8 b) {
        string h = hex.has_prefix("#") ? hex.substring(1) : hex;
        if (h.length < 6) { r = 0; g = 0; b = 0; return; }
        r = (uint8)(hex_nib(h[0]) * 16 + hex_nib(h[1]));
        g = (uint8)(hex_nib(h[2]) * 16 + hex_nib(h[3]));
        b = (uint8)(hex_nib(h[4]) * 16 + hex_nib(h[5]));
    }

    private int hex_nib(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
    }

    public void open_settings(string page) throws IOError {
        Idle.add(() => {
            open_settings_page(page);
            return false;
        });
    }

    public void open_settings_page(string page) {
        if (settings != null && settings.get_boolean("settings-in-window")) {
            // Ensure sidebar exists for file picker helpers used by some settings pages
            ensure_sidebar();
            ensure_settings_window();
            settings_window.open_page(page);
            return;
        }
        ensure_sidebar();
        sidebar.open_page(page);
    }

    public void open_app_details(AppInfo info) {
        if (settings != null && settings.get_boolean("settings-in-window")) {
            ensure_sidebar();
            ensure_settings_window();
            settings_window.open_app_details(info);
            return;
        }
        ensure_sidebar();
        sidebar.open_app_details(info);
    }

    public void open_app_settings(string app_id) throws IOError {
        Idle.add(() => {
            var app_info = Singularity.AppSystem.get_default().resolve_app_for_id(app_id);
            if (app_info != null) {
                open_app_details(app_info);
            } else {
                open_settings_page("apps");
            }
            return false;
        });
    }

    public string show_permission(string category, string resource, string reason) throws IOError {
        string decision = "deny";
        bool done = false;

        var dialog = new Singularity.Shell.ShellDialog.anchored(this, true, true, true, true);
        dialog.add_css_class("permission-dialog");

        var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
        card.halign = Gtk.Align.CENTER;
        card.valign = Gtk.Align.CENTER;
        card.add_css_class("power-card");
        card.margin_top = 28;
        card.margin_bottom = 28;
        card.margin_start = 40;
        card.margin_end = 40;

        string icon_name = "dialog-question-symbolic";
        string cat_display = category;
        switch (category) {
            case "network": icon_name = "network-wired-symbolic"; cat_display = "Network"; break;
            case "device": icon_name = "computer-symbolic"; cat_display = "Device"; break;
            case "filesystem": icon_name = "folder-symbolic"; cat_display = "Filesystem"; break;
            case "dbus.sensitive": icon_name = "dialog-password-symbolic"; cat_display = "D-Bus"; break;
        }

        var icon = new Gtk.Image.from_icon_name(icon_name);
        icon.pixel_size = 56;
        card.append(icon);

        var title_lbl = new Gtk.Label(_("Permission Request"));
        title_lbl.add_css_class("title-1");
        card.append(title_lbl);

        var reason_lbl = new Gtk.Label(reason);
        reason_lbl.add_css_class("dim-label");
        reason_lbl.add_css_class("body");
        reason_lbl.wrap = true;
        reason_lbl.justify = Gtk.Justification.CENTER;
        card.append(reason_lbl);

        var detail_lbl = new Gtk.Label(_("%s: %s").printf(cat_display, resource));
        detail_lbl.add_css_class("dim-label");
        detail_lbl.wrap = true;
        detail_lbl.justify = Gtk.Justification.CENTER;
        card.append(detail_lbl);

        var group = new Singularity.Widgets.PreferencesGroup();
        var allow_row = new Singularity.Widgets.ActionRow(_("Allow"), _("Grant this time only"));
        allow_row.activated.connect(() => { decision = "allow"; done = true; dialog.close_dialog(); });
        group.add_row(allow_row);

        var session_row = new Singularity.Widgets.ActionRow(_("This Session"), _("Grant until you log out"));
        session_row.activated.connect(() => { decision = "allow_session"; done = true; dialog.close_dialog(); });
        group.add_row(session_row);

        var always_row = new Singularity.Widgets.ActionRow(_("Always"), _("Remember and never ask again"));
        always_row.activated.connect(() => { decision = "allow_always"; done = true; dialog.close_dialog(); });
        group.add_row(always_row);

        card.append(group);

        var deny_btn = new Gtk.Button.with_label(_("Deny"));
        deny_btn.add_css_class("pill");
        deny_btn.add_css_class("destructive-action");
        deny_btn.width_request = 128;
        deny_btn.halign = Gtk.Align.CENTER;
        deny_btn.margin_top = 4;
        deny_btn.clicked.connect(() => { decision = "deny"; done = true; dialog.close_dialog(); });
        card.append(deny_btn);

        dialog.content_box.append(card);

        dialog.close_request.connect(() => {
            if (!done) { decision = "deny"; done = true; }
            return false;
        });

        dialog.open_dialog();

        var ctx = MainContext.default();
        while (!done) { ctx.iteration(true); }

        return decision;
    }

    public void add_favorite(string app_id) throws IOError {
        Idle.add(() => {
            Singularity.AppSystem.get_default().pin_app(app_id);
            return false;
        });
    }

    public void remove_favorite(string app_id) throws IOError {
        Idle.add(() => {
            Singularity.AppSystem.get_default().unpin_app(app_id);
            return false;
        });
    }

    public void move_favorite(string app_id, int position) throws IOError {
        Idle.add(() => {
            Singularity.AppSystem.get_default().move_pinned_app(app_id, position);
            return false;
        });
    }

    public void switch_windows_next() throws IOError {
        Idle.add(() => {
            if (app_switcher == null || !app_switcher.visible) {
                if (app_switcher != null) { app_switcher.sensitive = false; app_switcher.destroy(); }
                app_switcher = new Singularity.AppSwitcher(this);
            }
            app_switcher.show_and_cycle_next();
            return false;
        });
    }

    public void switch_windows_prev() throws IOError {
        Idle.add(() => {
            if (app_switcher == null || !app_switcher.visible) {
                if (app_switcher != null) { app_switcher.sensitive = false; app_switcher.destroy(); }
                app_switcher = new Singularity.AppSwitcher(this);
            }
            app_switcher.show_and_cycle_prev();
            return false;
        });
    }

    private bool _autostart_done = false;

    // Launch the .desktop entries in ~/.config/autostart that the Autostart
    // settings page writes. should_show() honours Hidden, TryExec and
    // OnlyShowIn/NotShowIn; X-GNOME-Autostart-enabled=false opts an entry out.
    private void launch_autostart_apps() {
        if (_autostart_done) return;
        _autostart_done = true;
        string dir = GLib.Path.build_filename(
            GLib.Environment.get_user_config_dir(), "autostart");
        GLib.Dir d;
        try {
            d = GLib.Dir.open(dir, 0);
        } catch (GLib.Error e) {
            return;
        }
        string? name;
        while ((name = d.read_name()) != null) {
            if (!name.has_suffix(".desktop")) continue;
            string path = GLib.Path.build_filename(dir, name);
            var info = new GLib.DesktopAppInfo.from_filename(path);
            if (info == null || !info.should_show()) continue;
            var kf = new GLib.KeyFile();
            try {
                kf.load_from_file(path, GLib.KeyFileFlags.NONE);
                if (kf.has_key("Desktop Entry", "X-GNOME-Autostart-enabled")
                        && !kf.get_boolean("Desktop Entry", "X-GNOME-Autostart-enabled"))
                    continue;
            } catch (GLib.Error e) {}
            try {
                info.launch(null, null);
            } catch (GLib.Error e) {
                warning("autostart: failed to launch %s: %s", name, e.message);
            }
        }
    }

    private void apply_x_font_settings() {
        if (GLib.Environment.get_variable("DISPLAY") == null) return;
        string res = "Xft.antialias:\t1\n"
            + "Xft.hinting:\t1\n"
            + "Xft.hintstyle:\thintslight\n"
            + "Xft.rgba:\trgb\n"
            + "Xft.lcdfilter:\tlcddefault\n";
        try {
            var xrdb = new GLib.Subprocess(GLib.SubprocessFlags.STDIN_PIPE
                | GLib.SubprocessFlags.STDERR_SILENCE, "xrdb", "-merge");
            xrdb.communicate_utf8_async(res, null, null);
        } catch (GLib.Error e) {
            warning("x font settings: xrdb merge failed: %s", e.message);
        }
    }

    private void apply_cursor_theme() {
        string theme = settings.get_string("cursor-theme");
        if (theme == "") return;

        var gtk_settings = Gtk.Settings.get_default();
        if (gtk_settings != null) gtk_settings.gtk_cursor_theme_name = theme;

        // Sync to the XDG interface settings (the portal proxies cursor-theme,
        // so Wayland apps follow) and export XCURSOR_THEME for newly spawned
        // apps and the compositor.
        var src = GLib.SettingsSchemaSource.get_default();
        if (src != null && src.lookup("org.gnome.desktop.interface", true) != null) {
            var iface = new GLib.Settings("org.gnome.desktop.interface");
            if (iface.get_string("cursor-theme") != theme)
                iface.set_string("cursor-theme", theme);
        }
        GLib.Environment.set_variable("XCURSOR_THEME", theme, true);

        try {
            string path = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".xsettingsd");
            string body = "";
            string existing = "";
            if (GLib.FileUtils.test(path, FileTest.EXISTS) && GLib.FileUtils.get_contents(path, out existing)) {
                foreach (string line in existing.split("\n")) {
                    if (line.strip() == "" || line.has_prefix("Gtk/CursorThemeName")) continue;
                    body += line + "\n";
                }
            }
            body += "Gtk/CursorThemeName \"%s\"\n".printf(theme);
            GLib.FileUtils.set_contents(path, body);
            Process.spawn_command_line_async("pkill -HUP xsettingsd");
        } catch (GLib.Error e) {
            warning("cursor theme: failed to update xsettingsd: %s", e.message);
        }

        // The running compositor only reads XCURSOR_THEME/XCURSOR_SIZE from its
        // own environment, so exporting them here does not change the live
        // pointer. labwc re-reads ~/.config/labwc/environment and reloads the
        // cursor on SIGHUP, so persist the values there and reconfigure (#149).
        int cursor_size = 24;
        if (src != null && src.lookup("org.gnome.desktop.interface", true) != null) {
            var iface = new GLib.Settings("org.gnome.desktop.interface");
            int sz = iface.get_int("cursor-size");
            if (sz > 0) cursor_size = sz;
        }
        try {
            string env_dir = GLib.Path.build_filename(
                GLib.Environment.get_user_config_dir(), "labwc");
            GLib.DirUtils.create_with_parents(env_dir, 0700);
            string env_path = GLib.Path.build_filename(env_dir, "environment");
            string body = "";
            string existing = "";
            if (GLib.FileUtils.test(env_path, FileTest.EXISTS) &&
                GLib.FileUtils.get_contents(env_path, out existing)) {
                foreach (string line in existing.split("\n")) {
                    string s = line.strip();
                    if (s == "" || s.has_prefix("XCURSOR_THEME") ||
                        s.has_prefix("XCURSOR_SIZE")) continue;
                    body += line + "\n";
                }
            }
            body += "XCURSOR_THEME=%s\n".printf(theme);
            body += "XCURSOR_SIZE=%d\n".printf(cursor_size);
            GLib.FileUtils.set_contents(env_path, body);
            Process.spawn_command_line_async("labwc --reconfigure");
        } catch (GLib.Error e) {
            warning("cursor theme: failed to update labwc environment: %s", e.message);
        }

        // XWayland apps that use libXcursor directly (Qt, Java, games, Wine)
        // read Xcursor.theme/Xcursor.size from the X resource database, not
        // XSETTINGS, so without this they fall back to the default cursor
        // (#154). Merge them into RESOURCE_MANAGER for newly spawned X apps.
        if (GLib.Environment.get_variable("DISPLAY") != null) {
            try {
                var xrdb = new GLib.Subprocess(GLib.SubprocessFlags.STDIN_PIPE
                    | GLib.SubprocessFlags.STDERR_SILENCE, "xrdb", "-merge");
                xrdb.communicate_utf8_async(
                    "Xcursor.theme: %s\nXcursor.size: %d\n".printf(theme, cursor_size),
                    null, null);
            } catch (GLib.Error e) {
                warning("cursor theme: failed to merge Xcursor resources: %s", e.message);
            }
        }
    }

    private void apply_icon_theme() {
        string theme = settings.get_string("icon-theme");
        if (theme == "") return;

        var gtk_settings = Gtk.Settings.get_default();
        if (gtk_settings != null) gtk_settings.gtk_icon_theme_name = theme;

        var src = GLib.SettingsSchemaSource.get_default();
        if (src != null && src.lookup("org.gnome.desktop.interface", true) != null) {
            var iface = new GLib.Settings("org.gnome.desktop.interface");
            if (iface.get_string("icon-theme") != theme)
                iface.set_string("icon-theme", theme);
        }

        try {
            string path = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".xsettingsd");
            string body = "";
            string existing = "";
            if (GLib.FileUtils.test(path, FileTest.EXISTS) && GLib.FileUtils.get_contents(path, out existing)) {
                foreach (string line in existing.split("\n")) {
                    if (line.strip() == "" || line.has_prefix("Net/IconThemeName")) continue;
                    body += line + "\n";
                }
            }
            body += "Net/IconThemeName \"%s\"\n".printf(theme);
            GLib.FileUtils.set_contents(path, body);
            Process.spawn_command_line_async("pkill -HUP xsettingsd");
        } catch (GLib.Error e) {
            warning("icon theme: failed to update xsettingsd: %s", e.message);
        }
    }

    private void apply_window_management_settings() {
        bool force_ssd = settings.get_boolean("force-ssd");
        if (force_ssd) {
            GLib.Environment.set_variable("GTK_CSD", "0", true);
            GLib.Environment.set_variable("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1", true);
            GLib.Environment.unset_variable("QT_WAYLAND_FORCE_LIBDECOR");
        } else {
            GLib.Environment.unset_variable("GTK_CSD");
            GLib.Environment.unset_variable("QT_WAYLAND_DISABLE_WINDOWDECORATION");
            GLib.Environment.unset_variable("QT_WAYLAND_FORCE_LIBDECOR");
        }
    }

    private void ensure_global_menu_support() {
        // 1. GSettings: Tell GTK that the shell shows the menubar
        try {
            var gtk_settings = new GLib.Settings("org.gnome.desktop.interface");
            var keys = gtk_settings.settings_schema.list_keys();
            bool has_key = false;
            foreach (var key in keys) {
                if (key == "gtk-shell-shows-menubar") { has_key = true; break; }
            }
            if (has_key) {
                gtk_settings.set_boolean("gtk-shell-shows-menubar", true);
            }
        } catch (GLib.Error e) {
            warning("Could not set GSettings for global menu: %s", e.message);
        }

        // 2. XSettings: Support for XWayland and older apps
        string xsettings_conf = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".xsettingsd");
        string content = "Gtk/ShellShowsMenubar 1\n";
        try {
            if (FileUtils.test(xsettings_conf, FileTest.EXISTS)) {
                string current_content;
                FileUtils.get_contents(xsettings_conf, out current_content);
                if (!current_content.contains("Gtk/ShellShowsMenubar")) {
                    FileUtils.set_contents(xsettings_conf, current_content + content);
                }
            } else {
                FileUtils.set_contents(xsettings_conf, content);
            }

            Process.spawn_command_line_async("/bin/sh -c 'pkill -HUP xsettingsd || xsettingsd'");
        } catch (GLib.Error e) {
            warning("Could not configure xsettingsd: %s", e.message);
        }

        // 3. Environment variables: Force apps to use the menu proxy
        GLib.Environment.set_variable("UBUNTU_MENUPROXY", "1", true);

        string current_modules = GLib.Environment.get_variable("GTK_MODULES") ?? "";
        if (!current_modules.contains("appmenu-gtk-module")) {
            string new_modules = (current_modules == "") ? "appmenu-gtk-module" : current_modules + ":appmenu-gtk-module";
            GLib.Environment.set_variable("GTK_MODULES", new_modules, true);
        }
    }

    public static int main(string[] args) {
        // Isolated AT-SPI helper modes: run the scan/activate in a throwaway
        // process so a fatal libatspi abort can never take down the shell.
        if (args.length >= 3 && args[1] == "--atspi-menu") {
            return Singularity.AtSpiMenuProvider.run_scan(args[2]);
        }
        if (args.length >= 4 && args[1] == "--atspi-activate") {
            return Singularity.AtSpiMenuProvider.run_activate(args[2], args[3]);
        }
        // Internationalization: resolve the locale dir from the install prefix
        // (next to our binary) so translations work whatever the prefix.
        Intl.setlocale(LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = GLib.FileUtils.read_link("/proc/self/exe");
            locale_dir = GLib.Path.build_filename(
                GLib.Path.get_dirname(GLib.Path.get_dirname(exe)), "share", "locale");
        } catch (GLib.Error e) { }
        Intl.bindtextdomain("singularity-desktop", locale_dir);
        Intl.bind_textdomain_codeset("singularity-desktop", "UTF-8");
        Intl.textdomain("singularity-desktop");

        // Must run before GTK/Mesa spin up their worker threads so the cap
        // applies to every arena they would otherwise each create.
        Singularity.cap_malloc_arenas();
        // Don't keep a large herd of idle worker threads alive.
        GLib.ThreadPool.set_max_unused_threads(2);
        Environment.set_variable("GDK_BACKEND", "wayland", true);
        if (Environment.get_variable("GSK_RENDERER") == null) {
            var rs = GLib.SettingsSchemaSource.get_default();
            if (rs != null && rs.lookup("dev.sinty.desktop", true) != null) {
                string mode = new GLib.Settings("dev.sinty.desktop").get_string("rendering-mode");
                if (mode == "hardware") Environment.set_variable("GSK_RENDERER", "gl", true);
                else if (mode == "software") Environment.set_variable("GSK_RENDERER", "cairo", true);
            }
        }
        string? wayland_display = Environment.get_variable("WAYLAND_DISPLAY");
        if (wayland_display == null) {
            printerr("WARNING: WAYLAND_DISPLAY is not set!\n");
        }
        // Log under the user-owned XDG state dir, not a predictable name in
        // world-writable /tmp (which a symlink there could hijack).
        string log_dir = GLib.Path.build_filename(GLib.Environment.get_user_state_dir(), "singularity");
        GLib.DirUtils.create_with_parents(log_dir, 0700);
        string log_path = GLib.Path.build_filename(log_dir, "singularity-desktop.log");
        // Start each session with a fresh log: rotate the previous one to .old
        // and truncate. Appending across sessions let the file grow without
        // bound (it reached 1.1 GB), which bloated disk and startup IO.
        if (FileUtils.test(log_path, FileTest.EXISTS)) {
            FileUtils.rename(log_path, log_path + ".old");
        }
        try {
            int log_fd = Posix.open(log_path, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_TRUNC, 0644);
            if (log_fd >= 0) {
                Posix.dup2(log_fd, Posix.STDOUT_FILENO);
                Posix.dup2(log_fd, Posix.STDERR_FILENO);
            }
        } catch (GLib.Error e) {
            printerr("Failed to setup logging: %s\n", e.message);
        }
        string host_bus_socket = "/run/host/run/dbus/system_bus_socket";
        if (FileUtils.test(host_bus_socket, FileTest.EXISTS)) {
            Environment.set_variable("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=" + host_bus_socket, true);
        }
        if (Environment.get_variable("GSETTINGS_SCHEMA_DIR") == null) {
            try {
                string exe_path = FileUtils.read_link("/proc/self/exe");
                var exe_dir = File.new_for_path(exe_path).get_parent();
                var schema_dir = exe_dir.get_child("data");
                if (schema_dir.get_child("gschemas.compiled").query_exists()) {
                    Environment.set_variable("GSETTINGS_SCHEMA_DIR", schema_dir.get_path(), true);
                }
            } catch (GLib.Error e) { }
        }
        var app = new SingularityApp();
        return app.run(args);
    }
}
