using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class DisplayColorPage : SettingsPage {
        private DisplayManager.Monitor monitor;
        private string key;
        private DisplayColor color;
        private ColorProfiles profiles;
        private SelectionRow profile_row;
        private ActionRow profile_status_row;
        private ActionRow import_row;
        private ActionRow calibrate_row;
        private SwitchRow hdr_row;
        private ActionRow sdr_row;
        private Scale sdr_scale;
        private Gee.List<ColorProfile> profile_list = new Gee.ArrayList<ColorProfile>();
        private string[] profile_labels = {};
        private string? assigned = null;
        private bool syncing = false;
        private ulong color_handler = 0;
        private ulong profiles_handler = 0;

        public DisplayColorPage(SettingsView view, DisplayManager.Monitor monitor) {
            base(_("Color"));
            this.monitor = monitor;
            key = DisplayColor.key_for(monitor);
            color = DisplayColor.get_default();
            profiles = ColorProfiles.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("displays"));

            var profile_group = new PreferencesGroup(_("Color Profile"));
            profile_group.description = _("For %s").printf(monitor.description ?? monitor.name ?? "");
            add_group(profile_group);

            profile_row = new SelectionRow(_("Profile"), { _("None") }, _("None"));
            profile_row.selected.connect(on_profile_selected);
            profile_group.add_row(profile_row);

            profile_status_row = new ActionRow(_("Not Applied to the Screen"), "", "dialog-information-symbolic");
            profile_status_row.activatable = false;
            profile_status_row.visible = false;
            profile_group.add_row(profile_status_row);

            import_row = new ActionRow(_("Import Profile"), _("Add an ICC profile from a file"), "document-open-symbolic");
            import_row.activatable = true;
            import_row.activated.connect(on_import);
            profile_group.add_row(import_row);

            calibrate_row = new ActionRow(_("Calibrate"), _("Measure this display with a colorimeter"), "applications-graphics-symbolic");
            calibrate_row.activatable = true;
            calibrate_row.visible = profiles.calibrate_command != null;
            calibrate_row.activated.connect(on_calibrate);
            profile_group.add_row(calibrate_row);

            var hdr_group = new PreferencesGroup(_("High Dynamic Range"));
            add_group(hdr_group);

            hdr_row = new SwitchRow(_("HDR"), "");
            hdr_row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                color.set_hdr(key, hdr_row.active);
                DisplayManager.get_default().apply_color();
                sync_hdr();
            });
            hdr_group.add_row(hdr_row);

            sdr_row = new ActionRow(_("Standard Content Brightness"), "");
            sdr_row.activatable = false;
            sdr_scale = new Scale.with_range(Orientation.HORIZONTAL, DisplayColor.SDR_MIN, DisplayColor.SDR_MAX, 10);
            sdr_scale.width_request = 150;
            sdr_scale.draw_value = true;
            sdr_scale.value_pos = PositionType.RIGHT;
            sdr_scale.set_format_value_func((s, value) => _("%.0f nits").printf(value));
            sdr_scale.value_changed.connect(() => {
                if (syncing) return;
                color.set_sdr_brightness(key, (int) sdr_scale.get_value());
                DisplayManager.get_default().apply_color();
            });
            sdr_row.add_suffix(sdr_scale);
            hdr_group.add_row(sdr_row);

            color_handler = color.changed.connect(() => {
                sync_hdr();
                sync_profile_status();
            });
            profiles_handler = profiles.changed.connect(() => load_profiles.begin());
            sync_hdr();
            load_profiles.begin();
        }

        protected override void dispose() {
            if (color_handler != 0) {
                color.disconnect(color_handler);
                color_handler = 0;
            }
            if (profiles_handler != 0) {
                profiles.disconnect(profiles_handler);
                profiles_handler = 0;
            }
            base.dispose();
        }

        private async void load_profiles() {
            profile_list = yield profiles.backend.list_profiles();
            assigned = yield profiles.backend.get_assigned(key);
            if (assigned == null) assigned = color.profile_path(key);
            string[] labels = { _("None") };
            string current = _("None");
            var seen = new Gee.HashSet<string>();
            foreach (var p in profile_list) {
                string label = p.title;
                int n = 2;
                while (seen.contains(label)) label = "%s (%d)".printf(p.title, n++);
                seen.add(label);
                labels += label;
                if (assigned != null && p.path == assigned) current = label;
            }
            profile_labels = labels;
            syncing = true;
            profile_row.set_items(labels);
            profile_row.current_value = current;
            syncing = false;
            sync_profile_status();
        }

        private void on_profile_selected(string item) {
            if (syncing) return;
            string? path = null;
            for (int i = 1; i < profile_labels.length; i++) {
                if (profile_labels[i] == item && i - 1 < profile_list.size) path = profile_list[i - 1].path;
            }
            assign.begin(path);
        }

        private async void assign(string? path) {
            try {
                yield profiles.assign(key, monitor.make ?? "", monitor.model ?? "", monitor.serial ?? "", path);
                assigned = path;
                DisplayManager.get_default().apply_color();
            } catch (Error e) {
                warning("DisplayColorPage: cannot assign profile: %s", e.message);
                yield load_profiles();
            }
            sync_profile_status();
        }

        private void sync_profile_status() {
            var info = color.info(monitor.name ?? "");
            if (assigned == null) {
                profile_status_row.visible = false;
                return;
            }
            if (info != null && info.icc_active) {
                profile_status_row.visible = false;
                return;
            }
            profile_status_row.visible = true;
            bool shared = profiles.backend.backend_name == "colord";
            profile_status_row.title = shared ? _("Shared with Apps Only") : _("Not Applied to the Screen");
            if (info != null && info.hdr_active) {
                profile_status_row.subtitle = _("Profiles are not applied to the screen while HDR is on");
            } else if (!color.compositor_reports || info == null || !info.icc_supported) {
                profile_status_row.subtitle = shared
                    ? _("The graphics driver cannot apply profiles to the screen, apps that manage color still use it")
                    : _("The graphics driver cannot apply profiles to the screen");
            } else if (info.icc_error != "") {
                profile_status_row.subtitle = _("The profile could not be applied to the screen");
            } else {
                profile_status_row.visible = false;
            }
        }

        private void sync_hdr() {
            syncing = true;
            var info = color.info(monitor.name ?? "");
            bool supported = info != null && info.hdr_supported;
            hdr_row.sensitive = supported;
            hdr_row.active = supported && color.hdr_enabled(key);
            if (supported) {
                hdr_row.subtitle = info.hdr_active
                    ? _("On, highlights and wide colors are shown as the display allows")
                    : _("Brighter highlights and wider colors for HDR videos and games");
            } else {
                hdr_row.subtitle = DisplayColor.hdr_reason_text(info, color.compositor_reports);
            }
            sdr_row.visible = supported && hdr_row.active;
            bool sdr_ok = info != null && info.sdr_brightness_supported;
            sdr_row.sensitive = sdr_ok;
            sdr_row.subtitle = sdr_ok
                ? _("How bright regular apps look while HDR is on")
                : _("The compositor cannot change this yet, regular apps use 203 nits");
            sdr_scale.set_value(color.sdr_brightness(key));
            syncing = false;
        }

        private void on_import() {
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Import Color Profile");
            var filter = new Gtk.FileFilter();
            filter.name = _("Color Profiles");
            filter.add_pattern("*.icc");
            filter.add_pattern("*.icm");
            filter.add_pattern("*.ICC");
            filter.add_pattern("*.ICM");
            var filters = new GLib.ListStore(typeof(Gtk.FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.default_filter = filter;
            SidebarWait.choose_file.begin(this, dialog, null, (obj, result) => {
                try {
                    var file = SidebarWait.choose_file.end(result);
                    import_file.begin(file);
                } catch (Error e) {
                }
            });
        }

        private async void import_file(File file) {
            try {
                var profile = yield profiles.import_profile(file);
                yield load_profiles();
                yield assign(profile.path);
                yield load_profiles();
            } catch (Error e) {
                import_row.subtitle = e.message;
            }
        }

        private void on_calibrate() {
            if (profiles.calibrate_command == null) return;
            try {
                Process.spawn_command_line_async(profiles.calibrate_command);
            } catch (Error e) {
                warning("DisplayColorPage: cannot start calibration: %s", e.message);
            }
        }
    }
}
