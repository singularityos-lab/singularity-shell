using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class DisplaysPage : SettingsPage {
        private DisplayManager display_manager;
        private Singularity.Shell.MonitorPreview preview;
        private ListBox monitor_list;
        private PreferencesGroup settings_group;
        private SelectionRow resolution_row;
        private ActionRow scale_row;
        private Label scale_value;
        private SettingsPage scale_page;
        private Button scale_apply_btn;
        private Singularity.Shell.ScaleChooser scale_chooser;
        private HashTable<string, double?> applied_scales = new HashTable<string, double?>(str_hash, str_equal);
        private SelectionRow orientation_row;
        private SwitchRow enabled_row;
        private SwitchRow vrr_row;
        private Button apply_btn;
        private Button shell_monitor_btn;
        private bool is_dirty = false;
        private bool syncing_controls = false;
        private DisplayManager.Monitor? selected_monitor = null;
        private MonitorOsd _osd;

        private SettingsView view;
        private ActionRow color_nav_row;
        private ActionRow brightness_nav_row;
        private ActionRow night_light_nav_row;
        private SettingsPage brightness_page;
        private SettingsPage hot_corners_page;
        private SettingsPage legacy_apps_page;
        private GLib.Settings nl_settings;

        public DisplaysPage(SettingsView view) {
            base(_("Displays"));
            this.view = view;
            back_clicked.connect(() => {
                view.go_home();
            });
            _osd = new MonitorOsd();
            display_manager = DisplayManager.get_default();
            display_manager.monitors_changed.connect(on_monitors_changed);
            apply_btn = new Button.with_label(_("Apply"));
            apply_btn.add_css_class("flat");
            apply_btn.add_css_class("suggested-action");
            apply_btn.visible = false;
            apply_btn.clicked.connect(apply_changes);
            header.append(apply_btn);
            var preview_frame = new Frame(null);
            preview_frame.add_css_class("monitor-preview-container");
            preview = new Singularity.Shell.MonitorPreview();
            preview.vexpand = false;
            preview.height_request = 130;
            preview.shell_monitor_name = display_manager.shell_monitor_name;
            preview.layout_changed.connect(() => set_dirty(true));
            preview.shell_monitor_changed.connect(on_preview_shell_monitor_changed);
            preview_frame.child = preview;
            add_widget(preview_frame);
            var list_frame = new Frame(null);
            list_frame.add_css_class("card");
            monitor_list = new ListBox();
            monitor_list.selection_mode = SelectionMode.SINGLE;
            monitor_list.add_css_class("content");
            monitor_list.row_selected.connect(on_monitor_selected);
            list_frame.child = monitor_list;
            add_widget(list_frame);
            settings_group = new PreferencesGroup(_("Settings"));
            add_group(settings_group);
            build_settings_ui();
            build_brightness_ui();
            build_hot_corners_ui();
            build_legacy_apps_ui();
            build_nav_ui();
            on_monitors_changed();
            map.connect(() => {
                var app = GLib.Application.get_default() as Gtk.Application;
                if (app != null) {
                    _osd.show(app, display_manager.get_monitors());
                }
            });
            unmap.connect(() => {
                _osd.hide();
            });
        }

        private void apply_changes() {
            display_manager.apply_configuration();
            foreach (var m in display_manager.get_monitors()) applied_scales.insert(m.name, m.scale);
            display_manager.save_configuration();
            set_dirty(false);
        }

        private void set_dirty(bool dirty) {
            if (scale_apply_btn != null) scale_apply_btn.visible = dirty;
            is_dirty = dirty;
            apply_btn.visible = dirty;
        }

        private void build_settings_ui() {
            enabled_row = new SwitchRow(_("Enabled"), _("Enable or disable this display"));
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (syncing_controls) return;
                if (selected_monitor != null) {
                    selected_monitor.enabled = enabled_row.active;
                    preview.queue_draw();
                    update_controls();
                    set_dirty(true);
                }
            });
            settings_group.add_row(enabled_row);
            resolution_row = new SelectionRow(_("Resolution"), {});
            resolution_row.selected.connect(on_resolution_changed);
            settings_group.add_row(resolution_row);
            scale_page = make_subpage(_("Scale"));
            scale_apply_btn = new Button.with_label(_("Apply"));
            scale_apply_btn.add_css_class("flat");
            scale_apply_btn.add_css_class("suggested-action");
            scale_apply_btn.visible = false;
            scale_apply_btn.clicked.connect(apply_changes);
            scale_page.header.append(scale_apply_btn);
            var scale_group = new PreferencesGroup(_("Size"));
            scale_group.description = _("Make text and controls bigger or smaller");
            scale_page.add_group(scale_group);
            var chooser_row = new PreferencesRow();
            scale_row = make_nav_row(_("Scale"), "", "zoom-in-symbolic");
            scale_value = new Label("");
            scale_value.add_css_class("dim-label");
            scale_row.add_suffix(scale_value);
            scale_row.activated.connect(() => view.open_subpage(scale_page, "displays-scale"));
            scale_chooser = new Singularity.Shell.ScaleChooser();
            scale_chooser.changed.connect((value) => {
                if (selected_monitor != null) {
                    selected_monitor.scale = value;
                    scale_value.label = "%.0f%%".printf(value * 100);
                    preview.queue_draw();
                    set_dirty(true);
                }
            });
            chooser_row.set_child(scale_chooser);
            scale_group.add_row(chooser_row);
            settings_group.add_row(scale_row);
            string[] orientations = { "Landscape", "Portrait", "Landscape Flipped", "Portrait Flipped" };
            orientation_row = new SelectionRow(_("Orientation"), orientations);
            orientation_row.selected.connect((val) => {
                if (syncing_controls) return;
                if (selected_monitor != null) {
                    int transform = 0;
                    switch (val) {
                        case "Landscape": transform = 0; break;
                        case "Portrait": transform = 1; break;
                        case "Landscape Flipped": transform = 2; break;
                        case "Portrait Flipped": transform = 3; break;
                    }
                    selected_monitor.transform = transform;
                    preview.queue_draw();
                    set_dirty(true);
                }
            });
            settings_group.add_row(orientation_row);
            vrr_row = new SwitchRow(_("Variable Refresh Rate"), _("Reduce screen tearing for games (requires VRR-capable display)"));
            vrr_row.switch_btn.notify["active"].connect(() => {
                if (syncing_controls) return;
                if (selected_monitor != null) {
                    selected_monitor.vrr_enabled = vrr_row.active;
                    set_dirty(true);
                }
            });
            settings_group.add_row(vrr_row);
            // Shell monitor row
            var shell_row = new PreferencesRow();
            var shell_box = new Box(Orientation.HORIZONTAL, 12);
            shell_box.margin_top = 8;
            shell_box.margin_bottom = 8;
            shell_box.margin_start = 12;
            shell_box.margin_end = 12;
            var shell_icon = new Image.from_icon_name("user-desktop-symbolic");
            shell_box.append(shell_icon);
            var shell_lbl = new Label(_("Shell Monitor"));
            shell_lbl.add_css_class("title");
            shell_lbl.halign = Align.START;
            shell_lbl.hexpand = true;
            shell_box.append(shell_lbl);
            shell_monitor_btn = new Button.with_label(_("Set"));
            shell_monitor_btn.add_css_class("pill");
            shell_monitor_btn.clicked.connect(on_set_shell_monitor_clicked);
            shell_box.append(shell_monitor_btn);
            shell_row.set_child(shell_box);
            settings_group.add_row(shell_row);
        }

        private void on_set_shell_monitor_clicked() {
            if (selected_monitor == null) return;
            display_manager.shell_monitor_name = selected_monitor.name;
            display_manager.save_configuration();
            display_manager.apply_shell_monitor();
            preview.shell_monitor_name = selected_monitor.name;
            preview.queue_draw();
            update_shell_monitor_btn();
        }

        private void on_preview_shell_monitor_changed(string connector_name) {
            display_manager.shell_monitor_name = connector_name;
            display_manager.save_configuration();
            display_manager.apply_shell_monitor();
            update_shell_monitor_btn();
        }

        private void update_shell_monitor_btn() {
            if (selected_monitor == null) return;
            bool is_shell = (selected_monitor.name == display_manager.shell_monitor_name);
            shell_monitor_btn.label = is_shell ? _("Active") : _("Set");
            shell_monitor_btn.sensitive = !is_shell;
        }

        private void on_monitors_changed() {
            string? prev_name = selected_monitor != null ? selected_monitor.name : null;
            var child = monitor_list.get_first_child();
            while (child != null) {
                monitor_list.remove(child);
                child = monitor_list.get_first_child();
            }
            int restore_idx = 0;
            int i = 0;
            foreach (var m in display_manager.get_monitors()) {
                var row = new Box(Orientation.HORIZONTAL, 12);
                row.margin_top = 12; row.margin_bottom = 12; row.margin_start = 12; row.margin_end = 12;
                var icon = new Image.from_icon_name("video-display-symbolic");
                row.append(icon);
                var label = new Label(m.description ?? m.name ?? _("Unknown Display"));
                label.hexpand = true;
                label.halign = Align.START;
                row.append(label);
                monitor_list.append(row);
                if (prev_name != null && m.name == prev_name) restore_idx = i;
                i++;
            }
            if (display_manager.get_monitors().length() > 0) {
                monitor_list.select_row(monitor_list.get_row_at_index(restore_idx));
            }
            preview.shell_monitor_name = display_manager.shell_monitor_name;
            preview.queue_draw();
        }

        private void on_monitor_selected(ListBoxRow? row) {
            if (row == null) {
                selected_monitor = null;
                settings_group.sensitive = false;
                return;
            }
            int idx = row.get_index();
            selected_monitor = display_manager.get_monitors().nth_data(idx);
            settings_group.sensitive = true;
            update_controls();
        }

        private PreferencesGroup brightness_group;
        private Scale brightness_scale;
        private Scale brightness_min_scale;
        private Scale brightness_max_scale;
        private DisplayBrightness? shown_brightness = null;
        private ulong shown_brightness_handler = 0;
        private bool syncing_brightness = false;

        private void build_brightness_ui() {
            brightness_page = make_subpage(_("Brightness"));
            brightness_group = new PreferencesGroup(_("Levels"));
            brightness_scale = brightness_slider(_("Brightness"), _("Current brightness of this display"), 0, 100);
            brightness_min_scale = brightness_slider(_("Minimum Brightness"), _("The darkest the display gets at 0%"), 0, 99);
            brightness_max_scale = brightness_slider(_("Maximum Brightness"), _("The brightest the display gets at 100%"), 1, 100);
            brightness_scale.value_changed.connect(() => {
                if (!syncing_brightness && shown_brightness != null) shown_brightness.set_level(brightness_scale.get_value());
            });
            brightness_min_scale.value_changed.connect(store_brightness_limits);
            brightness_max_scale.value_changed.connect(store_brightness_limits);
            brightness_page.add_group(brightness_group);
            BrightnessManager.get_default().displays_changed.connect(update_brightness_controls);
        }

        private Scale brightness_slider(string title, string subtitle, double min, double max) {
            var row = new ActionRow(title, subtitle);
            row.activatable = false;
            var scale = new Scale.with_range(Orientation.HORIZONTAL, min, max, 1);
            scale.width_request = 170;
            scale.draw_value = true;
            scale.value_pos = PositionType.RIGHT;
            scale.set_format_value_func((s, value) => "%.0f%%".printf(value));
            row.add_suffix(scale);
            brightness_group.add_row(row);
            return scale;
        }

        private void store_brightness_limits() {
            if (syncing_brightness || shown_brightness == null) return;
            double min = brightness_min_scale.get_value();
            double max = double.max(brightness_max_scale.get_value(), min + 1);
            shown_brightness.set_limits(min, max);
        }

        private void update_brightness_controls() {
            if (shown_brightness != null && shown_brightness_handler != 0) {
                shown_brightness.disconnect(shown_brightness_handler);
                shown_brightness_handler = 0;
            }
            shown_brightness = selected_monitor != null
                ? BrightnessManager.get_default().for_connector(selected_monitor.name) : null;
            if (brightness_nav_row != null) brightness_nav_row.visible = shown_brightness != null;
            if (shown_brightness == null) return;
            brightness_group.description = selected_monitor.description ?? selected_monitor.name ?? "";
            sync_brightness_controls();
            shown_brightness_handler = shown_brightness.changed.connect(sync_brightness_controls);
        }

        private void sync_brightness_controls() {
            syncing_brightness = true;
            brightness_scale.set_value(shown_brightness.percent);
            brightness_min_scale.set_value(shown_brightness.min_percent);
            brightness_max_scale.set_value(shown_brightness.max_percent);
            syncing_brightness = false;
        }

        private void update_controls() {
            update_brightness_controls();
            if (selected_monitor == null) return;
            syncing_controls = true;
            SignalHandler.block_matched(enabled_row.switch_btn, SignalMatchType.DATA, 0, 0, null, null, null);
            enabled_row.active = selected_monitor.enabled;
            string[] modes_arr = {};
            string current_mode_str = "";
            foreach (var mode in selected_monitor.modes) {
                string s = "%dx%d @ %.2fHz".printf(mode.width, mode.height, mode.refresh / 1000.0);
                if (mode.preferred) s += " (Preferred)";
                modes_arr += s;
                if (selected_monitor.current_mode != null &&
                    mode.width == selected_monitor.current_mode.width &&
                    mode.height == selected_monitor.current_mode.height &&
                    mode.refresh == selected_monitor.current_mode.refresh) {
                    current_mode_str = s;
                }
            }
            resolution_row.set_items(modes_arr);
            resolution_row.current_value = current_mode_str;
            if (!applied_scales.contains(selected_monitor.name)) {
                applied_scales.insert(selected_monitor.name, selected_monitor.scale);
            }
            int mode_w = selected_monitor.current_mode != null ? selected_monitor.current_mode.width : 0;
            int mode_h = selected_monitor.current_mode != null ? selected_monitor.current_mode.height : 0;
            if (selected_monitor.transform % 2 == 1) {
                int swap = mode_w;
                mode_w = mode_h;
                mode_h = swap;
            }
            double? applied = applied_scales.lookup(selected_monitor.name);
            scale_chooser.set_monitor(mode_w, mode_h, selected_monitor.phys_width, selected_monitor.phys_height,
                applied ?? selected_monitor.scale, selected_monitor.scale);
            string[] orientations = { "Landscape", "Portrait", "Landscape Flipped", "Portrait Flipped" };
            if (selected_monitor.transform <= 3) {
                orientation_row.current_value = orientations[selected_monitor.transform];
            } else {
                orientation_row.current_value = "Landscape";
            }
            SignalHandler.unblock_matched(enabled_row.switch_btn, SignalMatchType.DATA, 0, 0, null, null, null);
            resolution_row.sensitive = selected_monitor.enabled;
            scale_row.sensitive = selected_monitor.enabled;
            scale_value.label = "%.0f%%".printf(selected_monitor.scale * 100);
            orientation_row.sensitive = selected_monitor.enabled;
            vrr_row.visible = selected_monitor.vrr_supported;
            vrr_row.active = selected_monitor.vrr_enabled;
            syncing_controls = false;
            update_shell_monitor_btn();
        }

        private void on_resolution_changed(string val) {
            if (syncing_controls) return;
            if (selected_monitor == null) return;
            foreach (var mode in selected_monitor.modes) {
                string s = "%dx%d @ %.2fHz".printf(mode.width, mode.height, mode.refresh / 1000.0);
                if (mode.preferred) s += " (Preferred)";
                if (s == val) {
                    selected_monitor.current_mode = mode;
                    update_controls();
                    preview.queue_draw();
                    set_dirty(true);
                    break;
                }
            }
        }

        private string corner_action_icon(string action) {
            switch (action) {
                case "workspaces": return "view-grid-symbolic";
                case "overview":   return "view-app-grid-symbolic";
                case "settings":   return "emblem-system-symbolic";
                default:           return "list-remove-symbolic";
            }
        }

        private Gtk.Button make_corner_button(string key, GLib.Settings s,
                                              Gtk.Align halign, Gtk.Align valign) {
            string[] labels = { "None", "Workspaces", "Overview", "Settings" };
            string[] values = { "none", "workspaces", "overview", "settings" };
            string current = s.get_string(key);
            var btn = new Gtk.Button();
            btn.add_css_class("flat");
            btn.add_css_class("circular");
            btn.halign = halign;
            btn.valign = valign;

            var icon = new Gtk.Image.from_icon_name(corner_action_icon(current));
            icon.pixel_size = 16;
            btn.set_child(icon);

            if (current == "none") icon.opacity = 0.3;
            else btn.add_css_class("accent");

            btn.clicked.connect(() => {
                // Build popover with action choices
                var popover = new Gtk.Popover();
                popover.set_parent(btn);
                popover.has_arrow = true;

                var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
                box.margin_top = 4; box.margin_bottom = 4;
                box.margin_start = 4; box.margin_end = 4;

                for (int i = 0; i < values.length; i++) {
                    var lbl   = labels[i];
                    var val   = values[i];
                    var item  = new Gtk.Button.with_label(lbl);
                    item.add_css_class("flat");
                    item.halign = Gtk.Align.FILL;
                    if (s.get_string(key) == val) item.add_css_class("accent");
                    item.clicked.connect(() => {
                        s.set_string(key, val);
                        icon.icon_name = corner_action_icon(val);
                        icon.opacity   = val == "none" ? 0.3 : 1.0;
                        if (val == "none") btn.remove_css_class("accent");
                        else btn.add_css_class("accent");
                        popover.popdown();
                    });
                    box.append(item);
                }

                popover.set_child(box);
                popover.popup();
            });

            return btn;
        }

        private void build_hot_corners_ui() {
            hot_corners_page = make_subpage(_("Hot Corners"));
            var hot_corners_group = new PreferencesGroup(_("Corner Actions"));
            hot_corners_group.description = _("Choose what happens when the pointer reaches a corner of the screen");
            hot_corners_page.add_group(hot_corners_group);

            var corners_row = new PreferencesRow();

            var s = new GLib.Settings("dev.sinty.desktop");

            // Outer container
            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            outer.margin_top = 16; outer.margin_bottom = 16;
            outer.margin_start = 24; outer.margin_end = 24;
            outer.halign = Gtk.Align.CENTER;

            // Screen frame
            var screen = new Gtk.Frame(null);
            screen.add_css_class("hot-corner-screen");
            screen.set_size_request(260, 160);
            screen.halign = Gtk.Align.CENTER;

            var overlay = new Gtk.Overlay();
            overlay.set_size_request(260, 160);

            // Dark fill
            var bg = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            bg.hexpand = true; bg.vexpand = true;
            bg.add_css_class("hot-corner-bg");
            overlay.set_child(bg);

            // Center label
            var center = new Gtk.Label(_("Screen"));
            center.add_css_class("dim-label");
            center.halign = Gtk.Align.CENTER;
            center.valign = Gtk.Align.CENTER;
            overlay.add_overlay(center);

            // Four corner buttons
            var tl = make_corner_button("hot-corner-top-left",     s, Gtk.Align.START, Gtk.Align.START);
            var tr = make_corner_button("hot-corner-top-right",    s, Gtk.Align.END,   Gtk.Align.START);
            var bl = make_corner_button("hot-corner-bottom-left",  s, Gtk.Align.START, Gtk.Align.END);
            var br = make_corner_button("hot-corner-bottom-right", s, Gtk.Align.END,   Gtk.Align.END);

            tl.margin_top = 6;    tl.margin_start = 6;
            tr.margin_top = 6;    tr.margin_end   = 6;
            bl.margin_bottom = 6; bl.margin_start = 6;
            br.margin_bottom = 6; br.margin_end   = 6;

            overlay.add_overlay(tl);
            overlay.add_overlay(tr);
            overlay.add_overlay(bl);
            overlay.add_overlay(br);

            screen.set_child(overlay);
            outer.append(screen);

            corners_row.set_child(outer);
            hot_corners_group.add_row(corners_row);
        }

        private void build_legacy_apps_ui() {
            legacy_apps_page = make_subpage(_("Legacy Apps"));
            var group = new PreferencesGroup(_("X11 Apps"));
            legacy_apps_page.add_group(group);
            var s = new GLib.Settings("dev.sinty.desktop");
            var row = new SwitchRow(_("Sharp Scaling"),
                _("Render X11 apps at full resolution on scaled displays. Some apps may look smaller"),
                s.get_boolean("xwayland-native-scaling"));
            s.bind("xwayland-native-scaling", row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            group.add_row(row);
        }

        private SettingsPage make_subpage(string title) {
            var page = new SettingsPage(title);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("displays"));
            return page;
        }

        private ActionRow make_nav_row(string title, string subtitle, string icon_name) {
            var row = new ActionRow(title, subtitle, icon_name);
            row.activatable = true;
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.add_css_class("dim-label");
            row.add_suffix(chevron);
            return row;
        }

        private void build_nav_ui() {
            color_nav_row = make_nav_row(_("Color"), _("Color profile and HDR"), "preferences-color-symbolic");
            color_nav_row.activated.connect(() => {
                if (selected_monitor == null) return;
                view.open_subpage(new DisplayColorPage(view, selected_monitor), "displays-color");
            });
            settings_group.add_row(color_nav_row);
            brightness_nav_row = make_nav_row(_("Brightness"), _("Brightness and its limits"), "display-brightness-symbolic");
            brightness_nav_row.visible = false;
            brightness_nav_row.activated.connect(() => view.open_subpage(brightness_page, "displays-brightness"));
            settings_group.add_row(brightness_nav_row);

            var all_group = new PreferencesGroup(_("All Displays"));
            add_group(all_group);
            night_light_nav_row = make_nav_row(_("Night Light"), "", "night-light-symbolic");
            night_light_nav_row.activated.connect(() =>
                view.open_subpage(new NightLightPage(view), "displays-night-light"));
            all_group.add_row(night_light_nav_row);
            var corners_row = make_nav_row(_("Hot Corners"), _("Actions for the corners of the screen"), "view-grid-symbolic");
            corners_row.activated.connect(() => view.open_subpage(hot_corners_page, "displays-hot-corners"));
            all_group.add_row(corners_row);
            var legacy_row = make_nav_row(_("Legacy Apps"), _("Scaling of X11 apps"), "application-x-executable-symbolic");
            legacy_row.activated.connect(() => view.open_subpage(legacy_apps_page, "displays-legacy-apps"));
            all_group.add_row(legacy_row);

            var night_light = SystemMonitor.get_default().night_light;
            night_light.changed.connect(update_night_light_subtitle);
            nl_settings = new GLib.Settings("dev.sinty.desktop");
            nl_settings.changed.connect((key) => {
                if (key.has_prefix("night-light")) update_night_light_subtitle();
            });
            update_night_light_subtitle();
        }

        private void update_night_light_subtitle() {
            var night_light = SystemMonitor.get_default().night_light;
            var s = nl_settings;
            if (!s.get_boolean("night-light-enabled")) {
                night_light_nav_row.subtitle = _("Off");
            } else if (!s.get_boolean("night-light-adaptive")) {
                night_light_nav_row.subtitle = _("On");
            } else if (s.get_string("night-light-schedule") == "sunset-sunrise") {
                night_light_nav_row.subtitle = night_light.enabled ? _("On until sunrise") : _("Sunset to sunrise");
            } else {
                night_light_nav_row.subtitle = night_light.enabled ? _("On until %s").printf(s.get_string("night-light-adaptive-to"))
                    : _("From %s to %s").printf(s.get_string("night-light-adaptive-from"), s.get_string("night-light-adaptive-to"));
            }
        }
    }
}
