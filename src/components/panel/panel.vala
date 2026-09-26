using Gtk;
using GtkLayerShell;
using Gee;
using Singularity.Widgets;

namespace Singularity {

    private class WallpaperIndicator : Gtk.Box {
        private GLib.Settings settings;
        private WallpaperHistory history;
        private WallpaperFavorites favorites;
        private WallpaperRotationState rotation_state;
        private Button previous_button;
        private Button next_button;
        private Button pause_button;
        private Button favorite_button;
        private string? navigation_target = null;

        public WallpaperIndicator(GLib.Settings settings) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            valign = Align.CENTER;
            this.settings = settings;
            history = new WallpaperHistory(settings);
            favorites = new WallpaperFavorites(settings);
            rotation_state = new WallpaperRotationState(
                WallpaperRotationState.default_config_dir());

            var button = new MenuButton();
            button.add_css_class("flat");
            button.tooltip_text = _("Wallpaper controls");
            var icon = new Image.from_icon_name("preferences-desktop-wallpaper-symbolic");
            icon.pixel_size = 16;
            button.child = icon;
            append(button);

            var controls = new Box(Orientation.HORIZONTAL, 6);
            controls.margin_top = 10;
            controls.margin_bottom = 10;
            controls.margin_start = 12;
            controls.margin_end = 12;

            previous_button = new Button.from_icon_name("go-previous-symbolic");
            previous_button.tooltip_text = _("Previous wallpaper");
            previous_button.clicked.connect(() => navigate(history.go_back()));
            controls.append(previous_button);

            next_button = new Button.from_icon_name("go-next-symbolic");
            next_button.tooltip_text = _("Next wallpaper");
            next_button.clicked.connect(() => navigate(history.go_forward()));
            controls.append(next_button);

            pause_button = new Button();
            pause_button.clicked.connect(() => {
                rotation_state.set_rotate_enabled(!rotation_state.get_rotate_enabled());
                update_controls();
            });
            controls.append(pause_button);

            favorite_button = new Button();
            favorite_button.clicked.connect(() => {
                string? path = WallpaperManager.get_default().wallpaper_path;
                if (path != null) favorites.toggle_favorite(path);
            });
            controls.append(favorite_button);

            var popover = new Popover();
            popover.child = controls;
            button.popover = popover;
            popover.notify["visible"].connect(() => {
                if (popover.visible) update_controls();
            });

            var manager = WallpaperManager.get_default();
            manager.wallpaper_path_changed.connect((path) => {
                if (navigation_target == path) navigation_target = null;
                else history.record(path);
                update_controls();
            });
            favorites.favorites_changed.connect(update_controls);
            if (manager.wallpaper_path != null && history.current_path != manager.wallpaper_path)
                history.record(manager.wallpaper_path);
            update_controls();
        }

        private void navigate(string? path) {
            if (path == null) return;
            navigation_target = path;
            settings.delay();
            SettingsSafety.set_string(settings, "background-picture-uri",
                File.new_for_path(path).get_uri());
            SettingsSafety.set_string(settings, "background-attribution-title", "");
            SettingsSafety.set_string(settings, "background-attribution-author", "");
            settings.apply();
            update_controls();
        }

        private void update_controls() {
            previous_button.sensitive = history.can_go_back();
            next_button.sensitive = history.can_go_forward();
            bool rotating = rotation_state.get_rotate_enabled();
            pause_button.icon_name = rotating ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            pause_button.tooltip_text = rotating ? _("Pause wallpaper rotation") : _("Resume wallpaper rotation");
            string? path = WallpaperManager.get_default().wallpaper_path;
            bool is_favorite = path != null && favorites.is_favorite(path);
            favorite_button.icon_name = is_favorite ? "starred-symbolic" : "non-starred-symbolic";
            favorite_button.tooltip_text = is_favorite ? _("Remove from favorites") : _("Add to favorites");
            favorite_button.sensitive = path != null;
        }
    }

    private class TilingPositionIndicator : Gtk.Fixed {
        private const int TRACK_WIDTH = 58;
        private const int TRACK_HEIGHT = 18;
        private const int INSET = 4;
        private Box thumb;

        public TilingPositionIndicator() {
            set_size_request(TRACK_WIDTH, TRACK_HEIGHT);
            valign = Align.CENTER;
            add_css_class("tiling-position-track");
            tooltip_text = _("Scrolling position");
            thumb = new Box(Orientation.HORIZONTAL, 0);
            thumb.add_css_class("tiling-position-thumb");
            put(thumb, INSET, 5);
            set_position(0.5, 1.0);
        }

        public void set_position(double position, double visible_fraction) {
            int available = TRACK_WIDTH - 2 * INSET;
            int width = (int)Math.round(available
                * double.max(0, double.min(1, visible_fraction)));
            width = int.max(12, int.min(available, width));
            double progress = double.max(0, double.min(1, position));
            double x = INSET + (available - width) * progress;
            thumb.set_size_request(width, 8);
            move(thumb, x, 5);
        }
    }

    private class TilingSlotPreview : Gtk.Box {
        public AppSystem.Window window { get; private set; }
        public double current_x = 0;
        public double start_x = 0;
        public double target_x = 0;

        public TilingSlotPreview(AppSystem.Window window, int width,
                                 int height, bool dragged) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            this.window = window;
            set_size_request(width, height);
            overflow = Overflow.HIDDEN;
            add_css_class("tiling-slot-preview");
            if (dragged) add_css_class("dragged");

            var overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;
            append(overlay);

            var picture = new Picture();
            picture.content_fit = ContentFit.COVER;
            overlay.set_child(picture);

            var fallback = new Image();
            if (window.gicon != null) fallback.set_from_gicon(window.gicon);
            else fallback.set_from_icon_name(window.icon_name);
            fallback.pixel_size = 24;
            fallback.halign = Align.CENTER;
            fallback.valign = Align.CENTER;
            overlay.add_overlay(fallback);

            PreviewCache.get_default().request(window.handle, width, height,
                (texture) => {
                    if (texture == null || get_parent() == null) return;
                    picture.set_paintable(texture);
                    fallback.visible = false;
                });
        }
    }

    private class TilingSlotOrganizer : Gtk.Window {
        private const int HEIGHT = 112;
        private const int PADDING = 12;
        private const int GAP = 7;
        private Gtk.Fixed slots;
        private Overlay card;
        private Box seed;
        private ArrayList<TilingSlotPreview> items =
            new ArrayList<TilingSlotPreview>();
        private TilingSlotPreview? dragged_item;
        private TilingManager manager;
        private AppSystem.Window dragged;
        private int surface_x;
        private int surface_y;
        private int preview_width;
        private int preview_height = 76;
        private int initial_cursor_x;
        private bool cursor_moved = false;
        private uint seed_timeout_id = 0;
        private uint close_timeout_id = 0;
        private Singularity.Animation.TimedAnimation? reorder_animation;

        public TilingSlotOrganizer(Gtk.Application app, TilingManager manager,
                                   AppSystem.Window dragged,
                                   Gdk.Monitor monitor, int anchor_x,
                                   int cursor_x) {
            Object(application: app);
            this.manager = manager;
            this.dragged = dragged;
            initial_cursor_x = cursor_x;

            var geometry = monitor.get_geometry();
            int width = int.min(620, geometry.width - 24);
            surface_x = int.max(geometry.x + 12,
                int.min(geometry.x + geometry.width - width - 12,
                    anchor_x - width / 2));
            surface_y = geometry.y + 3;
            set_default_size(width, HEIGHT);
            resizable = false;

            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_namespace(this, "singularity-tiling-organizer");
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_monitor(this, monitor);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP,
                surface_y - geometry.y);
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.LEFT,
                surface_x - geometry.x);
            GtkLayerShell.set_exclusive_zone(this, 0);
            GtkLayerShell.set_keyboard_mode(this,
                GtkLayerShell.KeyboardMode.NONE);

            card = new Overlay();
            card.add_css_class("tiling-slot-organizer");
            card.set_size_request(width, HEIGHT);
            set_child(card);

            slots = new Gtk.Fixed();
            slots.overflow = Overflow.HIDDEN;
            card.set_child(slots);

            seed = new Box(Orientation.HORIZONTAL, 0);
            seed.add_css_class("tiling-slot-seed");
            seed.halign = Align.CENTER;
            seed.valign = Align.CENTER;
            card.add_overlay(seed);

            build_items(width);
            map.connect(() => {
                var surface = get_surface();
                if (surface != null) surface.set_input_region(new Cairo.Region());
            });
        }

        private void build_items(int width) {
            var windows = manager.slot_organizer_windows(dragged);
            if (windows.length == 0) return;
            int available = width - PADDING * 2 - GAP * (windows.length - 1);
            preview_width = int.max(34, available / windows.length);
            for (int i = 0; i < windows.length; i++) {
                var item = new TilingSlotPreview(windows[i], preview_width,
                    preview_height, windows[i] == dragged);
                item.current_x = slot_x(i);
                item.start_x = item.current_x;
                item.target_x = item.current_x;
                slots.put(item, item.current_x, 18);
                items.add(item);
                if (windows[i] == dragged) dragged_item = item;
            }
            seed_timeout_id = Timeout.add(190, () => {
                seed_timeout_id = 0;
                seed.visible = false;
                return Source.REMOVE;
            });
        }

        private double slot_x(int index) {
            return PADDING + index * (preview_width + GAP);
        }

        public void update_cursor(int cursor_x) {
            if (dragged_item == null || items.size < 2) return;
            if (!cursor_moved) {
                if (Math.fabs(cursor_x - initial_cursor_x) < 8) return;
                cursor_moved = true;
            }
            int target = (int)Math.floor((cursor_x - surface_x - PADDING
                + (preview_width + GAP) / 2.0) / (preview_width + GAP));
            target = int.max(0, int.min(items.size - 1, target));
            int current = items.index_of(dragged_item);
            if (target == current) return;
            items.remove_at(current);
            items.insert(target, dragged_item);
            manager.move_slot_organizer_window(dragged, target);
            animate_order();
        }

        private void animate_order() {
            reorder_animation?.reset();
            for (int i = 0; i < items.size; i++) {
                items[i].start_x = items[i].current_x;
                items[i].target_x = slot_x(i);
            }
            var animation = new Singularity.Animation.TimedAnimation(
                slots, 0, 1, 150);
            reorder_animation = animation;
            animation.tick.connect(() => {
                foreach (var item in items) {
                    item.current_x = item.start_x
                        + (item.target_x - item.start_x) * animation.value;
                    slots.move(item, item.current_x, 18);
                }
            });
            animation.done.connect(() => reorder_animation = null);
            animation.play();
        }

        public void close_animated() {
            if (close_timeout_id != 0) return;
            card.add_css_class("closing");
            close_timeout_id = Timeout.add(140, () => {
                close_timeout_id = 0;
                close();
                return Source.REMOVE;
            });
        }

        protected override void dispose() {
            if (seed_timeout_id != 0) {
                Source.remove(seed_timeout_id);
                seed_timeout_id = 0;
            }
            if (close_timeout_id != 0) {
                Source.remove(close_timeout_id);
                close_timeout_id = 0;
            }
            reorder_animation?.reset();
            base.dispose();
        }
    }

    public class Panel : Gtk.Window {
        private Label clock_label;
        private Label app_title_label;
        private CenterBox main_box;
        private Box left_box;
        private Box center_box;
        private Box right_box;
        private Box clock_suffix_box;
        private HashMap<string, Gtk.Widget> layout_items = new HashMap<string, Gtk.Widget>();
        private BarLayout? bar_layout;
        private BarLayoutEditController? layout_editor;
        private bool saving_bar_layout = false;
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
        private ulong _sig_background_effect = 0;
        private ulong _sig_blur_strength = 0;
        private bool _last_strip_light = false;
        private double _last_strip_lum = -1.0;
        private double _last_frac = -1.0;
        private Button workspace_btn;
        private TilingPositionIndicator tiling_position;
        private bool _tiling_position_active = false;
        private uint _tiling_hover_id = 0;
        private AppSystem.Window? _tiling_drag_window;
        private bool _tiling_drag_hovering = false;
        private TilingSlotOrganizer? _tiling_organizer;
        private bool _overview_active = false;
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
            var _shell_mon = target_monitor ?? find_primary_monitor();
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
                    var tiling = TilingManager.get_default();
                    if (tiling != null) tiling.workarea_changed();
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
            main_box = new CenterBox();
            main_box.orientation = Orientation.HORIZONTAL;
            main_box.add_css_class("panel");
            main_box.overflow = Overflow.VISIBLE;
            overlay.set_child(main_box);
            if (is_primary && !is_greeter_mode) main_box.opacity = 0;

            _sig_background_effect = _settings.changed["background-effect"].connect(
                update_background_effect);
            _sig_blur_strength = _settings.changed["blur-strength"].connect(
                update_background_effect);
            map.connect_after(update_background_effect);

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
            center_box = new Box(Orientation.HORIZONTAL, 5);
            right_box = new Box(Orientation.HORIZONTAL, 5);
            main_box.set_start_widget(left_box);
            main_box.set_center_widget(center_box);
            main_box.set_end_widget(right_box);

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
                layout_items["overview"] = activities_btn;
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
            layout_items["workspaces"] = workspace_btn;

            tiling_position = new TilingPositionIndicator();
            tiling_position.visible = false;
            layout_items["tiling-position"] = tiling_position;
            var tiling = TilingManager.get_default();
            if (tiling != null) {
                var tiling_scroll = new EventControllerScroll(
                    EventControllerScrollFlags.BOTH_AXES);
                double tiling_scroll_delta = 0;
                tiling_scroll.scroll_begin.connect(() => {
                    tiling_scroll_delta = 0;
                });
                tiling_scroll.scroll.connect((dx, dy) => {
                    double delta = Math.fabs(dx) > Math.fabs(dy) ? dx : dy;
                    tiling_scroll_delta += delta;
                    if (Math.fabs(tiling_scroll_delta) < 1.0) return true;
                    int direction = tiling_scroll_delta > 0 ? 1 : -1;
                    tiling_scroll_delta = 0;
                    tiling.scroll_on_monitor(gdk_monitor, direction);
                    return true;
                });
                tiling_scroll.scroll_end.connect(() => {
                    tiling_scroll_delta = 0;
                });
                tiling_position.add_controller(tiling_scroll);
                tiling.scrolling_position_changed.connect((monitor, position,
                        visible_fraction, active) => {
                    if (!active && (monitor == null
                            || panel_monitor_matches(monitor))) {
                        _tiling_position_active = false;
                    } else if (panel_monitor_matches(monitor)) {
                        _tiling_position_active = true;
                        tiling_position.set_position(position, visible_fraction);
                    } else {
                        return;
                    }
                    update_tiling_position_visibility();
                });
                tiling.scrolling_drag_changed.connect((win, monitor, phase,
                        cursor_x, cursor_y) => {
                    handle_tiling_drag(tiling, win, monitor, phase,
                        cursor_x, cursor_y);
                });
                tiling.refresh_scrolling_position();
            }

            app_title_label = new Label("");
            app_title_label.add_css_class("app-title");
            app_title_label.valign = Align.CENTER;
            app_title_label.margin_start = 5;
            app_title_label.margin_end = 5;
            if (!is_greeter_mode) layout_items["app-title"] = app_title_label;

            if (!is_greeter_mode && _settings.get_boolean("global-menu-enabled")) {
                menu_bar = new Singularity.Shell.GlobalMenuBar();
                menu_bar.valign = Align.CENTER;
                menu_bar.visible = false;
                layout_items["global-menu"] = menu_bar;

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
            layout_items["system"] = sys_btn;

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

            layout_items["notifications"] = notif_btn;

            var clock_btn = new Button();
            clock_btn.has_frame = false;
            clock_btn.add_css_class("clock-button");
            clock_label = new Label("00:00");
            clock_label.add_css_class("clock");
            clock_btn.set_child(clock_label);
            clock_btn.clicked.connect(() => {
                if (!is_greeter_mode) clock_clicked();
            });
            clock_suffix_box = new Box(Orientation.HORIZONTAL, 4);
            clock_suffix_box.valign = Align.CENTER;
            var clock_box = new Box(Orientation.HORIZONTAL, 4);
            clock_box.append(clock_btn);
            clock_box.append(clock_suffix_box);
            layout_items["clock"] = clock_box;
            if (is_primary && !is_greeter_mode)
                layout_items["wallpaper"] = new WallpaperIndicator(_settings);
            reload_bar_layout();
            _settings.changed["panel-layout-left"].connect(() => {
                if (!saving_bar_layout) reload_bar_layout();
            });
            _settings.changed["panel-layout-center"].connect(() => {
                if (!saving_bar_layout) reload_bar_layout();
            });
            _settings.changed["panel-layout-right"].connect(() => {
                if (!saving_bar_layout) reload_bar_layout();
            });
            if (!is_greeter_mode) {
                layout_editor = new BarLayoutEditController(
                    _settings,
                    "panel",
                    left_box,
                    center_box,
                    right_box,
                    layout_items,
                    { "overview", "workspaces", "tiling-position", "app-title", "global-menu", "system", "notifications", "clock", "wallpaper" },
                    { _("Overview"), _("Workspaces"), _("Scrolling Position"), _("App Title"), _("Global Menu"), _("System Status"), _("Notifications"), _("Clock"), _("Wallpaper") }
                );
                layout_editor.move_requested.connect((item_id, section, index) => {
                    if (bar_layout != null && bar_layout.move(item_id, section, index)) save_bar_layout();
                });
                layout_editor.edit_mode_changed.connect(() => {
                    update_visibility();
                    update_tiling_position_visibility();
                });
            }

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
            if (_settings.get_boolean("bar-layout-edit-mode")) {
                _hidden_for_fullscreen = fs;
                update_visibility();
                return;
            }
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

        private void update_background_effect() {
            Singularity.Style.BackgroundEffect.apply(this,
                Singularity.Style.BackgroundEffect.read(_settings));
        }

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
            if (!_overview_active && !_workspace_overview_active
                    && (flat_setting || force_flat)) {
                add_css_class("flat-panel");
            } else {
                remove_css_class("flat-panel");
            }
            update_topbar_fg_class();
        }

        private void update_visibility() {
            bool fusion = _settings.get_boolean("panel-fusion");
            bool editing = !is_greeter_mode && _settings.get_boolean("bar-layout-edit-mode");
            if (_hidden_for_fullscreen && !editing) {
                set_exclusive_zone(this, 0);
                set_layer(this, GtkLayerShell.Layer.BACKGROUND);
            } else if (fusion && !is_greeter_mode) {
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
            var tiling = TilingManager.get_default();
            if (tiling != null) tiling.workarea_changed();
        }

        private bool update_clock() {
            clock_label.label = new DateTime.now_local().format(_clock_format_str);
            return true;
        }

        private bool panel_monitor_matches(Gdk.Monitor? monitor) {
            if (monitor == null || gdk_monitor == null) return is_primary;
            if (monitor == gdk_monitor) return true;
            string? source = monitor.get_connector();
            string? target = gdk_monitor.get_connector();
            return source != null && target != null && source == target;
        }

        private void handle_tiling_drag(TilingManager manager,
                                        AppSystem.Window win,
                                        Gdk.Monitor? monitor, uint32 phase,
                                        int cursor_x, int cursor_y) {
            if (!panel_monitor_matches(monitor)) return;
            if (phase == 2) {
                cancel_tiling_hover(manager);
                if (_tiling_organizer != null) {
                    _tiling_organizer.update_cursor(cursor_x);
                    _tiling_organizer.close_animated();
                    _tiling_organizer = null;
                }
                _tiling_drag_window = null;
                return;
            }
            if (_tiling_organizer != null) {
                _tiling_organizer.update_cursor(cursor_x);
                return;
            }

            bool hovering = cursor_over_tiling_position(cursor_x, cursor_y);
            if (!hovering) {
                cancel_tiling_hover(manager);
                return;
            }
            if (_tiling_drag_hovering && _tiling_drag_window == win) return;
            cancel_tiling_hover(manager);
            _tiling_drag_window = win;
            _tiling_drag_hovering = true;
            manager.set_slot_organizer_hover(win, true);
            _tiling_hover_id = Timeout.add(1000, () => {
                _tiling_hover_id = 0;
                if (!_tiling_drag_hovering || _tiling_drag_window != win)
                    return Source.REMOVE;
                var target = gdk_monitor;
                var app = get_application();
                if (target == null || app == null
                        || !manager.begin_slot_organizer(win))
                    return Source.REMOVE;
                int anchor_x = tiling_position_center_x();
                _tiling_organizer = new TilingSlotOrganizer(app, manager,
                    win, target, anchor_x, cursor_x);
                _tiling_organizer.present();
                _tiling_organizer.update_cursor(cursor_x);
                return Source.REMOVE;
            });
        }

        private void cancel_tiling_hover(TilingManager manager) {
            if (_tiling_hover_id != 0) {
                Source.remove(_tiling_hover_id);
                _tiling_hover_id = 0;
            }
            if (_tiling_drag_hovering && _tiling_drag_window != null)
                manager.set_slot_organizer_hover(_tiling_drag_window, false);
            _tiling_drag_hovering = false;
        }

        private bool cursor_over_tiling_position(int x, int y) {
            if (!tiling_position.visible || gdk_monitor == null) return false;
            Graphene.Rect bounds;
            if (!tiling_position.compute_bounds(this, out bounds)) return false;
            var geometry = gdk_monitor.get_geometry();
            int left = geometry.x + (int)Math.floor(bounds.origin.x);
            int top = geometry.y + (int)Math.floor(bounds.origin.y);
            return x >= left && x < left + (int)Math.ceil(bounds.size.width)
                && y >= top && y < top + (int)Math.ceil(bounds.size.height);
        }

        private int tiling_position_center_x() {
            if (gdk_monitor == null) return 0;
            Graphene.Rect bounds;
            var geometry = gdk_monitor.get_geometry();
            if (!tiling_position.compute_bounds(this, out bounds))
                return geometry.x + geometry.width / 2;
            return geometry.x + (int)Math.round(bounds.origin.x
                + bounds.size.width / 2.0);
        }

        private void update_tiling_position_visibility() {
            bool editing = !is_greeter_mode
                && _settings.get_boolean("bar-layout-edit-mode");
            tiling_position.visible = _tiling_position_active || editing;
        }

        public void play_intro() {
            if (!is_primary || is_greeter_mode) return;
            main_box.opacity = 1.0;
            main_box.add_css_class("panel-intro");
            GLib.Timeout.add(560, () => {
                main_box.remove_css_class("panel-intro");
                return GLib.Source.REMOVE;
            });
        }

        public void set_overview_mode(bool enabled, bool instant = false) {
            _overview_active = enabled;
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
            update_overview_surface_mode();
        }

        private void update_overview_surface_mode() {
            if (_overview_active || _workspace_overview_active)
                set_exclusive_zone(this, 0);
            else
                update_visibility();
            update_flat_mode();
        }

        private void reload_bar_layout() {
            string[] item_ids = {
                "overview", "workspaces", "tiling-position", "app-title", "global-menu",
                "system", "notifications", "clock", "wallpaper"
            };
            bar_layout = new BarLayout(
                item_ids,
                { "overview", "workspaces", "app-title", "global-menu" },
                { "tiling-position" },
                { "system", "notifications", "clock", "wallpaper" },
                _settings.get_strv("panel-layout-left"),
                _settings.get_strv("panel-layout-center"),
                _settings.get_strv("panel-layout-right")
            );
            apply_bar_layout();
        }

        private void apply_bar_layout() {
            if (bar_layout == null) return;
            layout_editor?.detach_controls();
            foreach (Gtk.Widget widget in layout_items.values) detach_layout_item(widget);
            append_section(left_box, bar_layout.get_items(BarSection.LEFT));
            append_section(center_box, bar_layout.get_items(BarSection.CENTER));
            append_section(right_box, bar_layout.get_items(BarSection.RIGHT));
            layout_editor?.sync();
        }

        private void save_bar_layout() {
            if (bar_layout == null) return;
            saving_bar_layout = true;
            _settings.delay();
            _settings.set_value(
                "panel-layout-left",
                new GLib.Variant.strv(bar_layout.get_items(BarSection.LEFT))
            );
            _settings.set_value(
                "panel-layout-center",
                new GLib.Variant.strv(bar_layout.get_items(BarSection.CENTER))
            );
            _settings.set_value(
                "panel-layout-right",
                new GLib.Variant.strv(bar_layout.get_items(BarSection.RIGHT))
            );
            _settings.apply();
            saving_bar_layout = false;
            apply_bar_layout();
        }

        private void append_section(Box section, string[] item_ids) {
            foreach (string item_id in item_ids) {
                Gtk.Widget? widget = layout_items[item_id];
                if (widget != null) section.append(widget);
            }
        }

        private void detach_layout_item(Gtk.Widget widget) {
            if (widget.parent is Box) ((Box) widget.parent).remove(widget);
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
                center_box.append(widget);
            }
        }

        public void add_clock_suffix_widget(Widget widget) {
            clock_suffix_box.append(widget);
        }

        public void remove_widget(Widget widget) {
             if (widget.parent == left_box) left_box.remove(widget);
             else if (widget.parent == center_box) center_box.remove(widget);
             else if (widget.parent == right_box) right_box.remove(widget);
             else if (widget.parent == clock_suffix_box) clock_suffix_box.remove(widget);
        }

        public void set_workspace_btn_visible(bool visible) {
            _dock_hidden = visible;
            workspace_btn.visible = visible || _workspace_overview_active;
        }

        public void set_workspace_overview_active(bool active) {
            _workspace_overview_active = active;
            if (active) main_box.add_css_class("workspace-overview-mode");
            else main_box.remove_css_class("workspace-overview-mode");
            workspace_btn.visible = _dock_hidden || _workspace_overview_active;
            update_overview_surface_mode();
        }

        protected override void dispose() {
            var tiling = TilingManager.get_default();
            if (tiling != null) cancel_tiling_hover(tiling);
            if (_tiling_organizer != null) {
                _tiling_organizer.close();
                _tiling_organizer = null;
            }
            var as = AppSystem.get_default();
            if (_sig_app_focused != 0) { GLib.SignalHandler.disconnect(as, _sig_app_focused); _sig_app_focused = 0; }
            if (_sig_menu_model_changed != 0) { GLib.SignalHandler.disconnect(as, _sig_menu_model_changed); _sig_menu_model_changed = 0; }
            if (_sig_background_effect != 0) {
                _settings.disconnect(_sig_background_effect);
                _sig_background_effect = 0;
            }
            if (_sig_blur_strength != 0) {
                _settings.disconnect(_sig_blur_strength);
                _sig_blur_strength = 0;
            }
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
