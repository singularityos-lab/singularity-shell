using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    private delegate void TimeChanged(string time);

    public class DisplaysPage : SettingsPage {
        private DisplayManager display_manager;
        private Singularity.Shell.MonitorPreview preview;
        private ListBox monitor_list;
        private PreferencesGroup settings_group;
        private SelectionRow resolution_row;
        private PreferencesRow scale_row;
        private Scale scale_scale;
        private SelectionRow orientation_row;
        private SwitchRow enabled_row;
        private SwitchRow vrr_row;
        private Button apply_btn;
        private Button shell_monitor_btn;
        private bool is_dirty = false;
        private DisplayManager.Monitor? selected_monitor = null;
        private MonitorOsd _osd;

        private NightLightManager night_light;
        private GLib.Settings nl_settings;
        private SwitchRow night_light_row;
        private SwitchRow adaptive_row;
        private PreferencesRow temp_row;
        private Scale temp_scale;
        private PreferencesRow from_row;
        private TimePicker from_picker;
        private PreferencesRow to_row;
        private TimePicker to_picker;

        public DisplaysPage(SettingsView view) {
            base(_("Displays"));
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
            apply_btn.clicked.connect(() => {
                display_manager.apply_configuration();
                display_manager.save_configuration();
                set_dirty(false);
            });
            header.append(apply_btn);
            var preview_frame = new Frame(null);
            preview_frame.add_css_class("monitor-preview-container");
            preview = new Singularity.Shell.MonitorPreview();
            preview.vexpand = false;
            preview.height_request = 200;
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
            build_hot_corners_ui();
            build_night_light_ui();
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

        private void set_dirty(bool dirty) {
            is_dirty = dirty;
            apply_btn.visible = dirty;
        }

        private void build_settings_ui() {
            enabled_row = new SwitchRow(_("Enabled"), _("Enable or disable this display"));
            enabled_row.switch_btn.notify["active"].connect(() => {
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
            scale_row = new PreferencesRow();
            var scale_box = new Box(Orientation.VERTICAL, 12);
            scale_box.margin_top = 12;
            scale_box.margin_bottom = 12;
            scale_box.margin_start = 12;
            scale_box.margin_end = 12;
            var scale_lbl = new Label(_("Scale"));
            scale_lbl.add_css_class("title");
            scale_lbl.halign = Align.START;
            scale_box.append(scale_lbl);
            scale_scale = new Scale.with_range(Orientation.HORIZONTAL, 1.0, 3.0, 0.25);
            scale_scale.draw_value = true;
            scale_scale.hexpand = true;
            scale_scale.value_changed.connect(() => {
                if (selected_monitor != null) {
                    selected_monitor.scale = scale_scale.get_value();
                    preview.queue_draw();
                    set_dirty(true);
                }
            });
            scale_box.append(scale_scale);
            scale_row.set_child(scale_box);
            settings_group.add_row(scale_row);
            string[] orientations = { "Landscape", "Portrait", "Landscape Flipped", "Portrait Flipped" };
            orientation_row = new SelectionRow(_("Orientation"), orientations);
            orientation_row.selected.connect((val) => {
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

        private void update_controls() {
            if (selected_monitor == null) return;
            SignalHandler.block_matched(enabled_row.switch_btn, SignalMatchType.DATA, 0, 0, null, null, null);
            SignalHandler.block_matched(scale_scale, SignalMatchType.DATA, 0, 0, null, null, null);
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
            scale_scale.set_value(selected_monitor.scale);
            string[] orientations = { "Landscape", "Portrait", "Landscape Flipped", "Portrait Flipped" };
            if (selected_monitor.transform <= 3) {
                orientation_row.current_value = orientations[selected_monitor.transform];
            } else {
                orientation_row.current_value = "Landscape";
            }
            SignalHandler.unblock_matched(enabled_row.switch_btn, SignalMatchType.DATA, 0, 0, null, null, null);
            SignalHandler.unblock_matched(scale_scale, SignalMatchType.DATA, 0, 0, null, null, null);
            resolution_row.sensitive = selected_monitor.enabled;
            scale_row.sensitive = selected_monitor.enabled;
            orientation_row.sensitive = selected_monitor.enabled;
            vrr_row.visible = selected_monitor.vrr_supported;
            vrr_row.active = selected_monitor.vrr_enabled;
            update_shell_monitor_btn();
        }

        private void on_resolution_changed(string val) {
            if (selected_monitor == null) return;
            foreach (var mode in selected_monitor.modes) {
                string s = "%dx%d @ %.2fHz".printf(mode.width, mode.height, mode.refresh / 1000.0);
                if (mode.preferred) s += " (Preferred)";
                if (s == val) {
                    selected_monitor.current_mode = mode;
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
            var hot_corners_group = new PreferencesGroup(_("Hot Corners"));
            add_group(hot_corners_group);

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

        private void build_night_light_ui() {
            night_light = SystemMonitor.get_default().night_light;
            nl_settings = new GLib.Settings("dev.sinty.desktop");
            var group = new PreferencesGroup(_("Night Light"));
            add_group(group);

            night_light_row = new SwitchRow(_("Night Light"), _("Warm the screen color temperature in the evening"));
            nl_settings.bind("night-light-enabled", night_light_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            group.add_row(night_light_row);

            adaptive_row = new SwitchRow(_("Adaptive Schedule"), _("Turn on automatically on a daily schedule"));
            nl_settings.bind("night-light-adaptive", adaptive_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            adaptive_row.switch_btn.notify["active"].connect(() => update_night_light_controls());
            group.add_row(adaptive_row);

            from_row = make_time_row(_("From"), "weather-clear-night-symbolic",
                nl_settings.get_string("night-light-adaptive-from"), (t) => night_light.set_schedule_from(t), out from_picker);
            group.add_row(from_row);

            to_row = make_time_row(_("To"), "weather-clear-symbolic",
                nl_settings.get_string("night-light-adaptive-to"), (t) => night_light.set_schedule_to(t), out to_picker);
            group.add_row(to_row);

            temp_row = new PreferencesRow();
            var temp_box = new Box(Orientation.VERTICAL, 12);
            temp_box.margin_top = 12;
            temp_box.margin_bottom = 12;
            temp_box.margin_start = 12;
            temp_box.margin_end = 12;
            var temp_lbl = new Label(_("Temperature"));
            temp_lbl.add_css_class("title");
            temp_lbl.halign = Align.START;
            temp_box.append(temp_lbl);
            temp_scale = new Scale.with_range(Orientation.HORIZONTAL,
                (double) NightLightManager.TEMP_MIN, (double) NightLightManager.TEMP_MAX, 100);
            temp_scale.draw_value = true;
            temp_scale.hexpand = true;
            temp_scale.value_changed.connect(() => {
                night_light.set_temperature((int) temp_scale.get_value());
            });
            temp_box.append(temp_scale);
            var temp_hint = new Label(_("Color temperature in Kelvin — lower values are warmer"));
            temp_hint.add_css_class("dim-label");
            temp_hint.halign = Align.START;
            temp_hint.wrap = true;
            temp_box.append(temp_hint);
            temp_row.set_child(temp_box);
            group.add_row(temp_row);

            night_light.changed.connect(() => update_night_light_controls());
            update_night_light_controls();
        }

        private PreferencesRow make_time_row(string title, string icon_name, string initial,
                                             TimeChanged on_changed, out TimePicker picker) {
            var row = new PreferencesRow();
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 12;
            box.margin_end = 12;
            var icon = new Image.from_icon_name(icon_name);
            box.append(icon);
            var lbl = new Label(title);
            lbl.add_css_class("title");
            lbl.halign = Align.START;
            lbl.hexpand = true;
            box.append(lbl);
            picker = new TimePicker(initial);
            var p = picker;
            p.changed.connect(() => on_changed(p.time));
            box.append(picker);
            row.set_child(box);
            return row;
        }

        private void update_night_light_controls() {
            if (temp_scale == null) return;
            SignalHandler.block_matched(temp_scale, SignalMatchType.DATA, 0, 0, null, null, null);
            temp_scale.set_value((double) nl_settings.get_int("night-light-temperature"));
            SignalHandler.unblock_matched(temp_scale, SignalMatchType.DATA, 0, 0, null, null, null);
            from_picker.time = nl_settings.get_string("night-light-adaptive-from");
            to_picker.time = nl_settings.get_string("night-light-adaptive-to");
            from_row.visible = adaptive_row.active;
            to_row.visible = adaptive_row.active;
            if (night_light.enabled) {
                night_light_row.subtitle = _("On");
            } else if (night_light_row.active && adaptive_row.active) {
                night_light_row.subtitle = _("Off until %s").printf(from_picker.time);
            } else {
                night_light_row.subtitle = _("Off");
            }
        }
    }
}
