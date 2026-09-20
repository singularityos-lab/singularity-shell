using Gtk;
using Singularity.Widgets;

namespace Singularity {

    private delegate bool TileAvailableFunc();

    private class QuickTileItem : Object {
        public string id;
        public Widget wrapper;
        public QuickSettingTile tile;
        public TileAvailableFunc? available;
        public Overlay editor;
        public Button action;
        public DragSource drag;

        public QuickTileItem(string id, Widget wrapper, QuickSettingTile tile,
                owned TileAvailableFunc? available) {
            this.id = id;
            this.wrapper = wrapper;
            this.tile = tile;
            this.available = (owned) available;
            editor = new Overlay();
            editor.set_child(wrapper);
            editor.set_data<string>("quick-tile-id", id);
            action = new Button.from_icon_name("list-remove-symbolic");
            drag = new DragSource();
        }

        public bool is_available() {
            return available == null || available();
        }
    }

    public class SystemView : Box {
        public signal void toggle_settings();
        public signal void hide_sidebar();
        public signal void open_settings_page(string page_name);
        private bool _bri_updating = false;
        private bool _kbd_updating = false;
        private ExtremeModeManager _extreme_mgr;
        private GLib.Settings _settings;
        private Button _edit_button;
        private Box _content;
        private FlowBox _tile_grid;
        private FlowBox _inactive_tile_grid;
        private PreferencesGroup _quick_settings_preferences;
        private Gee.ArrayList<QuickTileItem> _quick_tiles = new Gee.ArrayList<QuickTileItem>();
        private bool _editing_tiles = false;
        private string? _drop_target_id;

        public SystemView() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            _extreme_mgr = ExtremeModeManager.get_default();
            var header = new Box(Orientation.HORIZONTAL, 12);
            header.add_css_class("page-header");
            var batt_box = new Box(Orientation.HORIZONTAL, 8);
            var batt_icon = new Image.from_icon_name("battery-full-symbolic");
            var batt_label = new Label("100%");
            var batt_status_label = new Label("");
            batt_status_label.add_css_class("dim-label");
            batt_box.append(batt_icon);
            batt_box.append(batt_label);
            batt_box.append(batt_status_label);
            header.append(batt_box);
            var power = SystemMonitor.get_default().power;
            batt_icon.icon_name = power.icon_name;
            batt_label.label = "%d%%".printf((int)power.percentage);
            batt_box.visible = power.is_present;
            SystemView.update_batt_status(power, batt_status_label);
            power.state_changed.connect(() => {
                batt_icon.icon_name = power.icon_name;
                batt_label.label = "%d%%".printf((int)power.percentage);
                batt_box.visible = power.is_present;
                SystemView.update_batt_status(power, batt_status_label);
            });
            var spacer = new Label("");
            spacer.hexpand = true;
            header.append(spacer);
            var settings = new GLib.Settings("dev.sinty.desktop");
            _settings = settings;

            var snap_btn = new Button.from_icon_name("camera-photo-symbolic");
            snap_btn.has_frame = false;
            snap_btn.add_css_class("navigation-button");
            header.append(snap_btn);
            snap_btn.clicked.connect(() => {
                hide_sidebar();
                var app = (Gtk.Application) GLib.Application.get_default();
                var tool = Singularity.ScreenshotTool.get_default(app);
                if (!tool.ensure_screenshots()) return;
                // prepare_for_invocation() resolves _target_monitor/_target_connector
                // and sets the layer-shell output -- without it both stay null and
                // screen-mode capture fails with "no target monitor for screen
                // capture" the instant this opens, since it defaults to screen mode.
                // shortcut_manager.vala's screenshot_tool_action() (the Print-key
                // path) already does this; this entry point never did.
                var handle = Singularity.AppSystem.get_default().get_focused_window_handle();
                tool.prepare_for_invocation(handle);
                tool.open_dialog();
            });
            _edit_button = new Button.from_icon_name("document-edit-symbolic");
            _edit_button.has_frame = false;
            _edit_button.add_css_class("navigation-button");
            _edit_button.tooltip_text = _("Edit quick settings");
            _edit_button.clicked.connect(() => set_editing_tiles(!_editing_tiles));
            header.append(_edit_button);
            var settings_btn = new Button.from_icon_name("emblem-system-symbolic");
            settings_btn.has_frame = false;
            settings_btn.add_css_class("navigation-button");
            settings_btn.clicked.connect(() => {
                if (settings.get_boolean("settings-in-window")) {
                    var app = (SingularityApp) GLib.Application.get_default();
                    if (app != null) app.open_settings_page("desktop");
                    return;
                }
                toggle_settings();
            });
            header.append(settings_btn);
            var power_btn = new Button.from_icon_name("system-shutdown-symbolic");
            power_btn.add_css_class("circular-button");
            power_btn.tooltip_text = _("Session");
            power_btn.clicked.connect(() => {
                show_session_menu(power_btn);
            });
            header.append(power_btn);
            append(header);
                        var content = new Box(Orientation.VERTICAL, 0);
                        _content = content;
                        content.margin_bottom = 0;
                        content.margin_start = 6;
                        content.margin_end = 6;

                        // Listen for plugins (e.g. Status Monitor)
                        var plugin_ctx = PluginManager.get_default().get_context();
                        plugin_ctx.sidebar_widget_added.connect((w) => {
                            content.prepend(w);
                            if (_editing_tiles) {
                                w.set_data<bool>("quick-settings-was-visible", w.visible);
                                w.visible = false;
                            }
                        });
                        plugin_ctx.sidebar_widget_removed.connect((w) => {
                            content.remove(w);
                        });

                        var audio = SystemMonitor.get_default().audio;

                        var grid = new FlowBox();
                        grid.column_spacing = 10;
                        grid.row_spacing = 10;
                        grid.homogeneous = true;
                        grid.min_children_per_line = 2;
                        grid.max_children_per_line = 2;
                        grid.selection_mode = SelectionMode.NONE;
                        grid.margin_bottom = 12;
                        grid.add_css_class("quick-settings-grid");
                        _tile_grid = grid;

                        // Wi-Fi Tile
                        var network = SystemMonitor.get_default().network;
                        bool wifi_available = network.has_wifi;
                        var wifi_tile = new QuickSettingTile("Wi-Fi", network.wifi_icon, network.wifi_enabled);
                        // The click handler drives the real state via toggle_wifi;
                        // the NetworkManager state_changed signal then sets the
                        // tile's active state. Let the tile manage its own visual
                        // state too and the two fight, flipping it on/off (#177).
                        wifi_tile.auto_toggle = false;
                        wifi_tile.subtitle = network.wifi_ssid;
                        network.state_changed.connect(() => {
                            wifi_tile.active = network.wifi_enabled;
                            wifi_tile.icon_name = network.wifi_icon;
                            wifi_tile.subtitle = network.wifi_ssid;
                            if (wifi_available != network.has_wifi) {
                                wifi_available = network.has_wifi;
                                rebuild_quick_tiles();
                            }
                        });
                        wifi_tile.clicked.connect(() => {
                            network.toggle_wifi();
                        });

                        // Bluetooth Tile
                        var bluetooth = SystemMonitor.get_default().bluetooth;
                        bool bt_available = bluetooth.is_available;
                        var bt_tile = new QuickSettingTile("Bluetooth", "bluetooth-active-symbolic", bluetooth.is_powered);
                        bt_tile.auto_toggle = false;
                        SystemView.update_bt_tile(bt_tile, bluetooth);
                        bluetooth.state_changed.connect(() => {
                            bt_tile.active = bluetooth.is_powered;
                            SystemView.update_bt_tile(bt_tile, bluetooth);
                            if (bt_available != bluetooth.is_available) {
                                bt_available = bluetooth.is_available;
                                rebuild_quick_tiles();
                            }
                        });
                        bluetooth.device_changed.connect((path) => {
                            SystemView.update_bt_tile(bt_tile, bluetooth);
                        });
                        bluetooth.device_added.connect((d) => {
                            SystemView.update_bt_tile(bt_tile, bluetooth);
                        });
                        bluetooth.device_removed.connect((p) => {
                            SystemView.update_bt_tile(bt_tile, bluetooth);
                        });
                        bt_tile.clicked.connect(() => {
                            bluetooth.set_power.begin(!bluetooth.is_powered);
                        });

                        // Theme tile (3-state: Dual, Light, Dark) - same multi-state
                        // model as the power profile tile. Click cycles the mode; the
                        // nav arrow opens the Appearance settings.
                        string tmode = settings.get_string("theme-mode");
                        var theme_tile = new QuickSettingTile(_("Theme"), theme_tile_icon(tmode), false);
                        theme_tile.n_states = 3;
                        theme_tile.auto_toggle = false;
                        theme_tile.state = theme_tile_state(tmode);
                        theme_tile.subtitle = theme_tile_label(tmode);
                        theme_tile.clicked.connect(() => {
                            settings.set_string("theme-mode", theme_next_mode(settings.get_string("theme-mode")));
                        });
                        settings.changed["theme-mode"].connect(() => {
                            string m = settings.get_string("theme-mode");
                            theme_tile.state = theme_tile_state(m);
                            theme_tile.subtitle = theme_tile_label(m);
                            theme_tile.icon_name = theme_tile_icon(m);
                        });

                        // Tiling Tile
                        bool tiling_enabled = settings.get_boolean("tiling-enabled");
                        var tile_tile = new QuickSettingTile("Tiling", "view-grid-symbolic", tiling_enabled);
                        tile_tile.subtitle = tiling_enabled ? _("On") : _("Off");
                        tile_tile.clicked.connect(() => {
                            settings.set_boolean("tiling-enabled", tile_tile.active);
                        });
                        settings.changed["tiling-enabled"].connect(() => {
                            tile_tile.active = settings.get_boolean("tiling-enabled");
                            tile_tile.subtitle = tile_tile.active ? _("On") : _("Off");
                        });
                        var tiling_wrapper = make_tile_with_nav(tile_tile, "desktop");
                        // Bind visibility on the wrapper so the empty group box doesn't show
                        settings.changed["preview-features-enabled"].connect(() => rebuild_quick_tiles());

                        // Airplane Mode
                        bool airplane_on = network.is_airplane_mode;
                        var airplane_tile = new QuickSettingTile("Airplane Mode", "airplane-mode-symbolic", airplane_on);
                        airplane_tile.subtitle = airplane_on ? _("On") : _("Off");
                        network.state_changed.connect(() => {
                            airplane_tile.active = network.is_airplane_mode;
                            airplane_tile.subtitle = network.is_airplane_mode ? _("On") : _("Off");
                        });
                        airplane_tile.clicked.connect(() => {
                            network.toggle_airplane_mode();
                        });

                        // Night Light via wlsunset
                        var night_mgr = SystemMonitor.get_default().night_light;
                        var night_tile = new QuickSettingTile("Night Light", "display-brightness-symbolic", night_mgr.enabled);
                        night_tile.subtitle = night_mgr.enabled ? _("On") : _("Off");
                        night_mgr.changed.connect(() => {
                            night_tile.active = night_mgr.enabled;
                            night_tile.subtitle = night_mgr.enabled ? _("On") : _("Off");
                        });
                        night_tile.clicked.connect(() => {
                            night_mgr.toggle();
                        });

                        // Keyboard backlight (hidden if not available)
                        var kbd_mgr = SystemMonitor.get_default().kbd_brightness;
                        var kbd_tile = new QuickSettingTile("Keyboard Light", "keyboard-brightness-symbolic", kbd_mgr.brightness > 0);
                        kbd_tile.subtitle = kbd_mgr.brightness > 0 ? _("On") : _("Off");
                        kbd_tile.visible = kbd_mgr.available;
                        kbd_mgr.changed.connect(() => {
                            kbd_tile.active = kbd_mgr.brightness > 0;
                            kbd_tile.subtitle = kbd_mgr.brightness > 0 ? _("On") : _("Off");
                        });
                        kbd_tile.clicked.connect(() => {
                            kbd_mgr.toggle();
                        });

                        // Power Profile tile (4-state: extreme-save, power-saver, balanced, performance)
                        var ppm = SystemMonitor.get_default().power_profiles;
                        bool ppm_available = ppm.available;
                        var ppm_tile = new QuickSettingTile(
                            "Power Profile",
                            SystemView.get_profile_icon_with_extreme(ppm.active_profile, _extreme_mgr.active),
                            false
                        );
                        ppm_tile.n_states = 4;
                        ppm_tile.auto_toggle = false;
                        ppm_tile.state = SystemView.get_profile_state_with_extreme(ppm.active_profile, _extreme_mgr.active);
                        ppm_tile.subtitle = SystemView.format_profile_name_with_extreme(ppm.active_profile, _extreme_mgr.active);
                        var ppm_wrapper = make_tile_with_nav(ppm_tile, "performance");
                        ppm.profile_changed.connect(() => {
                            ppm_tile.icon_name = SystemView.get_profile_icon_with_extreme(ppm.active_profile, _extreme_mgr.active);
                            ppm_tile.subtitle = SystemView.format_profile_name_with_extreme(ppm.active_profile, _extreme_mgr.active);
                            ppm_tile.state = SystemView.get_profile_state_with_extreme(ppm.active_profile, _extreme_mgr.active);
                            if (ppm_available != ppm.available) {
                                ppm_available = ppm.available;
                                rebuild_quick_tiles();
                            }
                        });
                        _extreme_mgr.extreme_mode_changed.connect(() => {
                            ppm_tile.icon_name = SystemView.get_profile_icon_with_extreme(ppm.active_profile, _extreme_mgr.active);
                            ppm_tile.subtitle = SystemView.format_profile_name_with_extreme(ppm.active_profile, _extreme_mgr.active);
                            ppm_tile.state = SystemView.get_profile_state_with_extreme(ppm.active_profile, _extreme_mgr.active);
                        });
                        ppm_tile.clicked.connect(() => {
                            var next = SystemView.get_next_profile_with_extreme(ppm.active_profile, _extreme_mgr.active);
                            var next_state = SystemView.get_next_profile_state(next);
                            ppm_tile.state = next_state;
                            if (next == "extreme-save") {
                                _extreme_mgr.set_extreme_mode(true);
                                ppm.set_profile("power-saver");
                            } else {
                                _extreme_mgr.set_extreme_mode(false);
                                ppm.set_profile(next);
                            }
                        });

                        // Audio mute toggle tile (placed in grid, left of power profile)
                        var audio_tile = new QuickSettingTile("Audio", audio.default_sink_icon, !audio.is_muted);
                        audio_tile.subtitle = audio.default_sink_friendly;
                        audio_tile.auto_toggle = false;
                        audio_tile.clicked.connect(() => { audio.toggle_mute(); });
                        audio.state_changed.connect(() => {
                            audio_tile.active = !audio.is_muted;
                            audio_tile.icon_name = audio.default_sink_icon;
                            audio_tile.subtitle = audio.default_sink_friendly;
                        });
                        audio.devices_changed.connect(() => {
                            audio_tile.icon_name = audio.default_sink_icon;
                            audio_tile.subtitle = audio.default_sink_friendly;
                        });
                        var audio_mute_wrapper = make_tile_with_nav(audio_tile, "sound");

                        // VPN tile
                        string vpn_subtitle = network.vpn_active ? network.vpn_name : (network.vpn_name != "" ? "Connecting…" : "Off");
                        var vpn_tile = new QuickSettingTile("VPN", network.vpn_icon, network.vpn_active);
                        vpn_tile.subtitle = vpn_subtitle;
                        vpn_tile.auto_toggle = false;
                        network.vpn_state_changed.connect(() => {
                            vpn_tile.active = network.vpn_active;
                            vpn_tile.icon_name = network.vpn_icon;
                            vpn_tile.subtitle = network.vpn_active ? network.vpn_name : (network.vpn_name != "" ? _("Connecting…") : _("Off"));
                        });

                        // Do Not Disturb tile
                        bool dnd_on = settings.get_boolean("do-not-disturb");
                        var dnd_tile = new QuickSettingTile("Do Not Disturb",
                            dnd_on ? "notifications-disabled-symbolic" : "preferences-system-notifications-symbolic", dnd_on);
                        dnd_tile.subtitle = dnd_on ? _("On") : _("Off");
                        dnd_tile.auto_toggle = false;
                        dnd_tile.clicked.connect(() => {
                            bool new_val = !settings.get_boolean("do-not-disturb");
                            settings.set_boolean("do-not-disturb", new_val);
                        });
                        settings.changed["do-not-disturb"].connect(() => {
                            dnd_tile.active = settings.get_boolean("do-not-disturb");
                            dnd_tile.icon_name = dnd_tile.active ? "notifications-disabled-symbolic" : "preferences-system-notifications-symbolic";
                            dnd_tile.subtitle = dnd_tile.active ? _("On") : _("Off");
                        });

                        var hotspot_tile = new QuickSettingTile("Hotspot", "network-wireless-hotspot-symbolic", network.wifi_hotspot_active);
                        hotspot_tile.auto_toggle = false;
                        hotspot_tile.subtitle = network.wifi_hotspot_active ? _("On") : _("Off");
                        network.hotspot_state_changed.connect(() => {
                            hotspot_tile.active = network.wifi_hotspot_active;
                            hotspot_tile.subtitle = network.wifi_hotspot_active ? _("On") : _("Off");
                        });
                        hotspot_tile.clicked.connect(() => {
                            if (network.wifi_hotspot_active) { network.stop_wifi_hotspot(); return; }
                            var hs = new GLib.Settings("dev.sinty.desktop");
                            string ssid, pw; bool wpa3;
                            NetworkPage.ensure_hotspot_credentials(hs, out ssid, out pw, out wpa3);
                            if (network.hotspot_needs_disconnect()) {
                                var app = GLib.Application.get_default() as Gtk.Application;
                                var dlg = new Singularity.Widgets.ConfirmDialog(app, _("Start Wi-Fi Hotspot?"),
                                    "network-wireless-hotspot-symbolic",
                                    _("Your current Wi-Fi connection will be disconnected, because the adapter can only join a network or host a hotspot, not both."),
                                    _("Start Hotspot"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
                                dlg.response.connect((r) => {
                                    if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY)
                                        network.start_wifi_hotspot(ssid, pw, wpa3);
                                });
                                dlg.present();
                            } else {
                                network.start_wifi_hotspot(ssid, pw, wpa3);
                            }
                        });
                        var hotspot_nav = make_tile_with_nav(hotspot_tile, "network");

                        // Wi-Fi & Bluetooth (only when the hardware exists)
                        var wifi_nav = make_tile_with_nav(wifi_tile, "network");
                        var bt_nav = make_tile_with_nav(bt_tile, "bluetooth");

                        // Keyboard-backlight tile only when the hardware exists (hide the whole
                        // nav wrapper, not just the inner tile, so it leaves no slot).
                        var kbd_nav = make_tile_with_nav(kbd_tile, "keyboard");

                        // GameMode quick tile - only when the gamemode daemon is available.
                        var gm2 = GameModeManager.get_default();
                        Widget? gm_nav = null;
                        if (gm2.available) {
                            var gm_tile = new QuickSettingTile("Game Mode", "applications-games-symbolic", gm2.active);
                            gm_tile.subtitle = gm2.active ? _("Active") : _("Inactive");
                            gm_tile.clicked.connect(() => {
                                if (gm2.active) gm2.deactivate();
                                else gm2.activate("manual");
                            });
                            gm2.state_changed.connect(() => {
                                gm_tile.active = gm2.active;
                                gm_tile.subtitle = gm2.active ? _("Active") : _("Inactive");
                            });
                            gm_nav = make_tile_with_nav(gm_tile, "performance");
                        }

                        add_quick_tile("wifi", wifi_nav, wifi_tile, () => network.has_wifi);
                        add_quick_tile("bluetooth", bt_nav, bt_tile, () => bluetooth.is_available);
                        add_quick_tile("theme", make_tile_with_nav(theme_tile, "desktop"), theme_tile);
                        add_quick_tile("night-light", make_tile_with_nav(night_tile, "displays"), night_tile);
                        add_quick_tile("airplane-mode", make_tile_with_nav(airplane_tile, "network"), airplane_tile);
                        add_quick_tile("keyboard-light", kbd_nav, kbd_tile, () => kbd_mgr.available);
                        add_quick_tile("audio", audio_mute_wrapper, audio_tile);
                        add_quick_tile("power-profile", ppm_wrapper, ppm_tile, () => ppm.available);
                        add_quick_tile("do-not-disturb", make_tile_with_nav(dnd_tile, "notifications"), dnd_tile);
                        add_quick_tile("vpn", make_tile_with_nav(vpn_tile, "network"), vpn_tile);
                        add_quick_tile("tiling", tiling_wrapper, tile_tile,
                            () => settings.get_boolean("preview-features-enabled"));
                        add_quick_tile("hotspot", hotspot_nav, hotspot_tile, () => network.has_wifi);
                        if (gm_nav != null)
                            add_quick_tile("game-mode", gm_nav, (QuickSettingTile) gm_nav.get_first_child(),
                                () => gm2.available);

                        _inactive_tile_grid = new FlowBox();
                        _inactive_tile_grid.column_spacing = 10;
                        _inactive_tile_grid.row_spacing = 10;
                        _inactive_tile_grid.homogeneous = true;
                        _inactive_tile_grid.min_children_per_line = 2;
                        _inactive_tile_grid.max_children_per_line = 2;
                        _inactive_tile_grid.selection_mode = SelectionMode.NONE;
                        _inactive_tile_grid.margin_bottom = 12;
                        _inactive_tile_grid.add_css_class("quick-settings-grid");
                        _inactive_tile_grid.add_css_class("quick-settings-inactive-grid");

                        var compact_row = new SwitchRow(_("Compact Mode"),
                            _("Show quick settings as icon controls"),
                            settings.get_boolean("quick-settings-compact"));
                        settings.bind("quick-settings-compact", compact_row.switch_btn,
                            "active", SettingsBindFlags.DEFAULT);
                        compact_row.switch_btn.notify["active"].connect(() => update_compact_mode());
                        _quick_settings_preferences = new PreferencesGroup(_("Preferences"));
                        _quick_settings_preferences.add_row(compact_row);

                        configure_tile_drop_target(grid, true);
                        configure_tile_drop_target(_inactive_tile_grid, false);
                        rebuild_quick_tiles();

                        content.append(grid);
                        content.append(_inactive_tile_grid);
                        content.append(_quick_settings_preferences);

            var sliders_group = new PreferencesGroup();

            // Volume row: icon | slider
            var vol_row = new PreferencesRow();
            var vol_box = new Box(Orientation.HORIZONTAL, 12);
            vol_box.margin_top = 6;
            vol_box.margin_bottom = 6;
            vol_box.margin_start = 12;
            vol_box.margin_end = 12;
            var vol_icon = new Image.from_icon_name(audio.icon_name);
            var vol_scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 100, 1);
            vol_scale.draw_value = false;
            vol_scale.hexpand = true;
            vol_scale.valign = Align.CENTER;
            vol_scale.set_value(audio.volume);
            vol_scale.value_changed.connect(() => {
                audio.update_volume(vol_scale.get_value());
            });
            audio.state_changed.connect(() => {
                vol_scale.set_value(audio.volume);
                vol_icon.icon_name = audio.icon_name;
            });
            vol_box.append(vol_icon);
            vol_box.append(vol_scale);
            vol_row.set_child(vol_box);
            sliders_group.add_row(vol_row);

            // Device picker: ExpanderRow (like timezone selector) that slides open below
            var dev_row = new ExpanderRow(
                "Output Device",
                audio.default_sink_friendly,
                audio.default_sink_icon ?? "audio-card-symbolic"
            );
            dev_row.add_css_class("audio-device-expander");
            SystemView.rebuild_audio_device_expander(dev_row, audio);
            audio.devices_changed.connect(() => {
                dev_row.subtitle = audio.default_sink_friendly;
                dev_row.icon_name = audio.default_sink_icon ?? "audio-card-symbolic";
                SystemView.rebuild_audio_device_expander(dev_row, audio);
            });
            // state_changed fires on every volume change - only update subtitle/icon, no rebuild
            audio.state_changed.connect(() => {
                dev_row.subtitle = audio.default_sink_friendly;
                dev_row.icon_name = audio.default_sink_icon ?? "audio-card-symbolic";
            });
            sliders_group.add_row(dev_row);
            var bri_row = new PreferencesRow();
            var bri_box = new Box(Orientation.HORIZONTAL, 12);
            bri_box.margin_top = 6;
            bri_box.margin_bottom = 6;
            bri_box.margin_start = 12;
            bri_box.margin_end = 12;
            var brightness = SystemMonitor.get_default().brightness;
            var bri_icon = new Image.from_icon_name("display-brightness-symbolic");
            var bri_pct_label = new Label("%d%%".printf((int)(brightness.brightness * 1.0)));
            bri_pct_label.add_css_class("dim-label");
            bri_pct_label.width_chars = 4;
            bri_pct_label.xalign = 1.0f;
            var bri_scale = new Scale.with_range(Orientation.HORIZONTAL, 1, 100, 1);
            bri_scale.draw_value = false;
            bri_scale.hexpand = true;
            bri_scale.valign = Align.CENTER;
            bri_scale.set_value(brightness.brightness);
            bri_scale.value_changed.connect(() => {
                if (_bri_updating) return;
                brightness.set_level(bri_scale.get_value());
                bri_pct_label.label = "%d%%".printf((int)bri_scale.get_value());
            });
            brightness.changed.connect(() => {
                _bri_updating = true;
                bri_scale.set_value(brightness.brightness);
                bri_pct_label.label = "%d%%".printf((int)brightness.brightness);
                _bri_updating = false;
            });
            bri_box.append(bri_icon);
            bri_box.append(bri_scale);
            bri_box.append(bri_pct_label);
            bri_row.set_child(bri_box);
            sliders_group.add_row(bri_row);
            // Keyboard backlight slider (shown only if hardware available)
            var kbd_brightness = SystemMonitor.get_default().kbd_brightness;
            if (kbd_brightness.available) {
                var kbd_row = new PreferencesRow();
                var kbd_box = new Box(Orientation.HORIZONTAL, 12);
                kbd_box.margin_top = 6;
                kbd_box.margin_bottom = 6;
                kbd_box.margin_start = 12;
                kbd_box.margin_end = 12;
                var kbd_icon = new Image.from_icon_name("keyboard-brightness-symbolic");
                var kbd_scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 100, 1);
                kbd_scale.draw_value = false;
                kbd_scale.hexpand = true;
                kbd_scale.valign = Align.CENTER;
                // Snap to discrete hardware levels
                double kbd_step = 100.0 / kbd_brightness.levels;
                kbd_scale.set_increments(kbd_step, kbd_step);
                // Bound decorative marks; one per raw level can exceed GPU surface limits.
                int mark_intervals = int.min(kbd_brightness.levels, 10);
                for (int i = 0; i <= mark_intervals; i++) {
                    double v = (i * 100.0) / mark_intervals;
                    kbd_scale.add_mark(v, PositionType.BOTTOM, null);
                }
                kbd_scale.set_value(kbd_brightness.brightness);
                kbd_scale.value_changed.connect(() => {
                    if (_kbd_updating) return;
                    // Snap to nearest discrete level
                    double step = 100.0 / kbd_brightness.levels;
                    double snapped = Math.round(kbd_scale.get_value() / step) * step;
                    kbd_brightness.set_level(snapped);
                });
                kbd_brightness.changed.connect(() => {
                    _kbd_updating = true;
                    kbd_scale.set_value(kbd_brightness.brightness);
                    _kbd_updating = false;
                });
                kbd_box.append(kbd_icon);
                kbd_box.append(kbd_scale);
                kbd_row.set_child(kbd_box);
                sliders_group.add_row(kbd_row);
            }
            content.append(sliders_group);
            var media_player = new MediaPlayerCard();
            media_player.margin_bottom = 13;
            content.append(media_player);
            _inactive_tile_grid.visible = false;
            _quick_settings_preferences.visible = false;
            append(content);
        }

        private void confirm_session_action(string title, string icon, string description,
                                            string button_label, owned PowerConfirmDialog.ConfirmCallback action) {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dlg = new PowerConfirmDialog(app, title, icon, description, button_label, (owned) action);
            dlg.open_dialog();
        }

        private void show_session_menu(Widget anchor) {
            var menu = new Singularity.Widgets.ContextMenu(anchor);
            menu.add_item("Lock", "system-lock-screen-symbolic", () => {
                SessionManager.get_default().lock_screen();
                hide_sidebar();
            });
            menu.add_item("Suspend", "weather-clear-night-symbolic", () => {
                SessionManager.get_default().suspend();
                hide_sidebar();
            });
            menu.add_separator();
            menu.add_item("Log Out", "system-log-out-symbolic", () => {
                confirm_session_action("Log Out", "system-log-out-symbolic",
                    "All running applications will be closed.", "Log Out",
                    () => SessionManager.get_default().logout());
            });
            menu.add_item("Restart", "system-reboot-symbolic", () => {
                confirm_session_action("Restart", "system-reboot-symbolic",
                    "Your device will restart.", "Restart",
                    () => SessionManager.get_default().reboot());
            });
            menu.add_item("Power Off", "system-shutdown-symbolic", () => {
                confirm_session_action("Power Off", "system-shutdown-symbolic",
                    "Your device will shut down.", "Power Off",
                    () => SessionManager.get_default().shutdown());
            });
            menu.popup();
        }

        private void add_quick_tile(string id, Widget wrapper,
                QuickSettingTile tile, owned TileAvailableFunc? available = null) {
            var item = new QuickTileItem(id, wrapper, tile, (owned) available);
            var action = item.action;
            action.add_css_class("quick-setting-editor-action");
            action.width_request = 24;
            action.height_request = 24;
            action.hexpand = false;
            action.vexpand = false;
            action.halign = Align.END;
            action.valign = Align.START;
            action.clicked.connect(() => {
                if (_editing_tiles)
                    set_tile_active(item, !tile_is_active(id));
            });
            action.set_data<string>("quick-tile-id", id);
            item.editor.add_overlay(action);

            var drag = item.drag;
            drag.actions = Gdk.DragAction.MOVE;
            drag.prepare.connect((x, y) => new Gdk.ContentProvider.for_value(id));
            drag.drag_begin.connect((source) => item.editor.add_css_class("dragging"));
            drag.drag_end.connect((source, action_taken, delete_data) =>
                item.editor.remove_css_class("dragging"));
            item.editor.add_controller(drag);

            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.enter.connect((x, y) => {
                set_drop_target(item);
                return Gdk.DragAction.MOVE;
            });
            drop.leave.connect(() => clear_tile_drop_target());
            drop.drop.connect((value, x, y) => {
                string? dragged = value.get_string();
                clear_tile_drop_target();
                if (dragged == null || dragged == id) return false;
                move_tile(dragged, id, tile_is_active(id));
                return true;
            });
            item.editor.add_controller(drop);
            _quick_tiles.add(item);
        }

        private QuickTileItem? find_quick_tile(string id) {
            foreach (var item in _quick_tiles)
                if (item.id == id) return item;
            return null;
        }

        private bool tile_is_active(string id) {
            foreach (var active in _settings.get_strv("quick-settings-active-tiles"))
                if (active == id) return true;
            return false;
        }

        private string[] tile_order() {
            string[] ordered = {};
            foreach (var id in _settings.get_strv("quick-settings-tile-order"))
                if (find_quick_tile(id) != null && !(id in ordered)) ordered += id;
            foreach (var item in _quick_tiles)
                if (!(item.id in ordered)) ordered += item.id;
            return ordered;
        }

        private void set_tile_active(QuickTileItem item, bool active) {
            string[] values = {};
            foreach (var id in _settings.get_strv("quick-settings-active-tiles"))
                if (id != item.id) values += id;
            if (active) values += item.id;
            _settings.set_strv("quick-settings-active-tiles", values);
            Idle.add(() => {
                rebuild_quick_tiles();
                return Source.REMOVE;
            });
        }

        private void detach_editor(QuickTileItem item) {
            var parent = item.editor.parent as FlowBoxChild;
            if (parent != null && parent.parent is FlowBox)
                ((FlowBox) parent.parent).remove(parent);
        }

        private void rebuild_quick_tiles() {
            foreach (var item in _quick_tiles) detach_editor(item);
            foreach (var id in tile_order()) {
                var item = find_quick_tile(id);
                if (item == null || !item.is_available()) continue;
                bool active = tile_is_active(id);
                if (!_editing_tiles && !active) continue;
                var icon = item.action.get_child() as Image;
                if (icon != null)
                    icon.icon_name = active ? "list-remove-symbolic" : "list-add-symbolic";
                item.action.visible = _editing_tiles;
                item.action.can_target = _editing_tiles;
                item.drag.actions = _editing_tiles
                    ? Gdk.DragAction.MOVE : (Gdk.DragAction) 0;
                item.tile.can_target = !_editing_tiles;
                item.wrapper.can_target = !_editing_tiles;
                if (active) _tile_grid.append(item.editor);
                else _inactive_tile_grid.append(item.editor);
            }
            _inactive_tile_grid.visible = _editing_tiles;
            update_compact_mode();
        }

        private void set_editing_tiles(bool editing) {
            _editing_tiles = editing;
            _edit_button.icon_name = editing ? "object-select-symbolic" : "document-edit-symbolic";
            _edit_button.tooltip_text = editing ? _("Done") : _("Edit quick settings");
            set_css_class(_tile_grid, "quick-settings-editing", editing);
            set_css_class(_inactive_tile_grid, "quick-settings-editing", editing);
            _inactive_tile_grid.visible = editing;
            _quick_settings_preferences.visible = editing;
            Widget? child = _content.get_first_child();
            while (child != null) {
                bool editor_child = child == _tile_grid
                    || child == _inactive_tile_grid
                    || child == _quick_settings_preferences;
                if (!editor_child) {
                    if (editing) {
                        child.set_data<bool>("quick-settings-was-visible", child.visible);
                        child.visible = false;
                    } else if (child.get_data<bool>("quick-settings-was-visible")) {
                        child.visible = true;
                        child.set_data<bool>("quick-settings-was-visible", false);
                    }
                }
                child = child.get_next_sibling();
            }
            rebuild_quick_tiles();
        }

        private void update_compact_mode() {
            bool compact = _settings.get_boolean("quick-settings-compact");
            set_css_class(_tile_grid, "compact", compact);
            set_css_class(_inactive_tile_grid, "compact", compact);
            _tile_grid.min_children_per_line = compact ? 6 : 2;
            _tile_grid.max_children_per_line = compact ? 6 : 2;
            _inactive_tile_grid.min_children_per_line = compact ? 6 : 2;
            _inactive_tile_grid.max_children_per_line = compact ? 6 : 2;
            foreach (var item in _quick_tiles) {
                item.wrapper.hexpand = !compact;
                item.wrapper.halign = compact ? Align.CENTER : Align.FILL;
                item.tile.hexpand = !compact;
                item.tile.compact = compact;
                item.wrapper.tooltip_text = compact ? item.tile.title : null;
                var nav_btn = item.wrapper.get_last_child();
                if (nav_btn != null && nav_btn.has_css_class("quick-setting-nav-btn"))
                    nav_btn.visible = !compact;
                var long_press = item.tile.get_data<GestureLongPress>("quick-setting-long-press");
                if (long_press != null)
                    long_press.propagation_phase = compact
                        ? PropagationPhase.CAPTURE : PropagationPhase.NONE;
            }
        }

        private static void set_css_class(Widget widget, string name, bool enabled) {
            if (enabled) widget.add_css_class(name);
            else widget.remove_css_class(name);
        }

        private void set_drop_target(QuickTileItem item) {
            if (_drop_target_id == item.id) return;
            clear_tile_drop_target();
            item.editor.add_css_class("drop-target-here");
            _drop_target_id = item.id;
        }

        private void clear_tile_drop_target() {
            if (_drop_target_id == null) return;
            var item = find_quick_tile(_drop_target_id);
            if (item != null) item.editor.remove_css_class("drop-target-here");
            _drop_target_id = null;
        }

        private void move_tile(string dragged, string? anchor, bool active) {
            string[] order = {};
            foreach (var id in tile_order()) if (id != dragged) order += id;
            int index = order.length;
            if (anchor != null) {
                for (int i = 0; i < order.length; i++) {
                    if (order[i] == anchor) { index = i; break; }
                }
            }
            string[] updated = {};
            for (int i = 0; i < order.length; i++) {
                if (i == index) updated += dragged;
                updated += order[i];
            }
            if (index == order.length) updated += dragged;
            _settings.set_strv("quick-settings-tile-order", updated);
            var item = find_quick_tile(dragged);
            if (item != null && tile_is_active(dragged) != active)
                set_tile_active(item, active);
            else
                rebuild_quick_tiles();
        }

        private void configure_tile_drop_target(FlowBox grid, bool active) {
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.drop.connect((value, x, y) => {
                string? dragged = value.get_string();
                clear_tile_drop_target();
                if (dragged == null) return false;
                move_tile(dragged, null, active);
                return true;
            });
            drop.leave.connect(() => clear_tile_drop_target());
            grid.add_controller(drop);
        }

        private Widget make_tile_with_nav(QuickSettingTile tile, string page_name) {
            var wrapper = new Box(Orientation.HORIZONTAL, 0);
            wrapper.add_css_class("quick-setting-group");
            tile.hexpand = true;
            wrapper.append(tile);
            var nav_btn = new Button();
            nav_btn.has_frame = false;
            nav_btn.add_css_class("quick-setting-nav-btn");
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            nav_btn.set_child(chevron);
            nav_btn.valign = Align.FILL;
            nav_btn.tooltip_text = _("Open settings");
            nav_btn.clicked.connect(() => {
                open_settings_page(page_name);
            });
            wrapper.append(nav_btn);
            var long_press = new GestureLongPress();
            long_press.propagation_phase = PropagationPhase.NONE;
            long_press.pressed.connect((x, y) => {
                if (_editing_tiles) return;
                long_press.set_state(EventSequenceState.CLAIMED);
                open_settings_page(page_name);
            });
            tile.add_controller(long_press);
            tile.set_data<GestureLongPress>("quick-setting-long-press", long_press);
            return wrapper;
        }

        private static string get_profile_icon(string profile) {
            switch (profile) {
                case "power-saver":  return "power-profile-power-saver-symbolic";
                case "performance":  return "power-profile-performance-symbolic";
                default:             return "power-profile-balanced-symbolic";
            }
        }

        // Theme tile (Dual/Light/Dark) helpers, mirroring the power profile tile.
        private static string theme_tile_label(string mode) {
            switch (mode) {
                case "light": return _("Light");
                case "dark":  return _("Dark");
                default:      return _("Dual");
            }
        }
        private static string theme_tile_icon(string mode) {
            switch (mode) {
                case "light": return "weather-clear-symbolic";
                case "dark":  return "weather-clear-night-symbolic";
                default:      return "weather-few-clouds-symbolic";
            }
        }
        // 0 = light (off), 1 = dual (partial), 2 = dark (fully active).
        private static int theme_tile_state(string mode) {
            switch (mode) {
                case "light": return 0;
                case "dark":  return 2;
                default:      return 1;
            }
        }
        // Click cycles Dual -> Light -> Dark -> Dual.
        private static string theme_next_mode(string mode) {
            switch (mode) {
                case "light": return "dark";
                case "dark":  return "dual";
                default:      return "light";
            }
        }

        private static string get_profile_icon_with_extreme(string profile, bool extreme) {
            if (extreme) return "battery-level-0-symbolic";
            return get_profile_icon(profile);
        }

        private static string format_profile_name(string profile) {
            switch (profile) {
                case "power-saver":  return "Power Saver";
                case "performance":  return "Performance";
                default:             return "Balanced";
            }
        }

        private static string format_profile_name_with_extreme(string profile, bool extreme) {
            if (extreme) return "Extreme Save";
            return format_profile_name(profile);
        }

        private static string get_next_profile_with_extreme(string profile, bool extreme) {
            if (extreme) return "power-saver";  // From extreme, power-saver
            switch (profile) {
                case "power-saver":  return "balanced";
                case "balanced":     return "performance";
                default:             return "extreme-save";  // From performance, extreme-save
            }
        }

        private static int get_profile_state_with_extreme(string profile, bool extreme) {
            if (extreme) return 0;  // Extreme save is state 0
            switch (profile) {
                case "power-saver":  return 1;
                case "balanced":     return 2;
                default:             return 3;  // performance
            }
        }

        private static int get_next_profile_state(string next_profile) {
            // This is called after we know the next profile/extreme state
            // We need to return the state based on the next profile that WILL be active
            // Since get_next_profile_with_extreme was just called, we can deduce:
            if (next_profile == "extreme-save") return 0;
            if (next_profile == "power-saver") return 1;
            if (next_profile == "balanced") return 2;
            return 3; // performance
        }

        private static void update_batt_status(PowerManager power, Label label) {
            if (power.is_charging) {
                int64 secs = power.time_to_full;
                if (secs > 0) {
                    int h = (int)(secs / 3600);
                    int m = (int)((secs % 3600) / 60);
                    label.label = h > 0 ? _("%dh %dm").printf(h, m) : "%dm".printf(m);
                } else {
                    label.label = _("Charging");
                }
            } else {
                int64 secs = power.time_to_empty;
                if (secs > 0) {
                    int h = (int)(secs / 3600);
                    int m = (int)((secs % 3600) / 60);
                    label.label = h > 0 ? _("%dh %dm left").printf(h, m) : _("%dm left").printf(m);
                } else {
                    label.label = "";
                }
            }
        }

        private static void update_bt_tile(QuickSettingTile tile, BluetoothManager bluetooth) {
            BluetoothManager.DeviceInfo? connected_dev = null;
            unowned List<BluetoothManager.DeviceInfo?> l = bluetooth.devices;
            while (l != null) {
                if (l.data != null && l.data.connected) {
                    connected_dev = l.data;
                    break;
                }
                l = l.next;
            }
            if (connected_dev != null) {
                tile.subtitle = connected_dev.name;
                tile.icon_name = BluetoothManager.bt_icon_for(connected_dev.icon);
            } else {
                tile.subtitle = bluetooth.is_powered ? _("On") : _("Off");
                tile.icon_name = "bluetooth-active-symbolic";
            }
        }

        private static void rebuild_audio_device_expander(ExpanderRow dev_row, AudioManager audio) {
            // Remove old device rows
            Widget? child = dev_row.get_first_child();
            // ExpanderRow stores its content inside the revealer, content_box;
            // we must go through add_row/clear via a known-empty rebuild.
            // Simplest: replace the child of the revealer by re-adding rows.
            // Since ExpanderRow.add_row just appends to content_box, we
            // clear it first via a helper that walks the box siblings.
            dev_row.clear_rows();
            unowned List<AudioManager.AudioDevice?> l = audio.sinks;
            while (l != null) {
                if (l.data == null) { l = l.next; continue; }
                var sink = l.data;
                var row_btn = new Button();
                row_btn.add_css_class("flat");
                row_btn.add_css_class("audio-device-row");
                var row_box = new Box(Orientation.HORIZONTAL, 8);
                row_box.margin_top = 8;
                row_box.margin_bottom = 8;
                row_box.margin_start = 12;
                row_box.margin_end = 12;
                var row_icon = new Image.from_icon_name(sink.icon_name ?? "audio-card-symbolic");
                row_icon.pixel_size = 16;
                var row_label = new Label(sink.friendly_name ?? sink.description);
                row_label.xalign = 0;
                row_label.hexpand = true;
                row_label.ellipsize = Pango.EllipsizeMode.END;
                row_box.append(row_icon);
                row_box.append(row_label);
                if (sink.index == audio.default_sink_index) {
                    var check = new Image.from_icon_name("object-select-symbolic");
                    check.pixel_size = 16;
                    row_box.append(check);
                }
                row_btn.set_child(row_box);
                string sink_name = sink.name;
                row_btn.clicked.connect(() => {
                    audio.set_default_sink(sink_name);
                    dev_row.expanded = false;
                });
                dev_row.add_row(row_btn);
                l = l.next;
            }
        }

    }
}
