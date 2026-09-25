using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {
    public class PerformancePage : SettingsPage {
        private GLib.Settings _settings;
        private PowerProfilesManager ppm;
        private ExtremeModeManager extreme;
        private SensorMonitor fan_monitor;
        private PreferencesGroup fans_group;
        private Gee.ArrayList<Widget> curve_rows = new Gee.ArrayList<Widget>();
        private FanHistoryGraph? fan_graph = null;
        private ActionRow? fan_profile_row = null;
        private Gee.HashMap<string, ActionRow> fan_rows = new Gee.HashMap<string, ActionRow>();
        private Gee.HashMap<string, Label> fan_values = new Gee.HashMap<string, Label>();
        private Gee.ArrayList<FanCurveEditor> curve_editors = new Gee.ArrayList<FanCurveEditor>();
        private string fan_layout = "";

        public PerformancePage(SettingsView view) {
            base(_("Performance"));
            back_clicked.connect(() => view.go_home());
            _settings = new GLib.Settings("dev.sinty.desktop");

            var gm = GameModeManager.get_default();

            // Game Mode
            var gm_group = new PreferencesGroup(_("Game Mode"));
            gm_group.description = gm.available
                ? "gamemode daemon detected"
                : "Install gamemode for GPU/CPU performance boost in games";

            var auto_row = new SwitchRow(_("Auto Game Mode"),
                "Activate performance mode automatically when a fullscreen game is detected");
            auto_row.sensitive = gm.available;
            auto_row.active = gm.auto_mode;
            auto_row.switch_btn.notify["active"].connect(() => {
                _settings.set_boolean("gamemode-auto", auto_row.active);
            });
            gm_group.add_row(auto_row);

            var manual_row = new SwitchRow(_("Game Mode Active"),
                "Manually force performance mode right now");
            manual_row.sensitive = gm.available;
            manual_row.active = gm.active;
            manual_row.switch_btn.notify["active"].connect(() => {
                if (manual_row.active) gm.activate("manual");
                else gm.deactivate();
            });
            gm_group.add_row(manual_row);

            var tearing_row = new SwitchRow(_("Allow Tearing"),
                _("Lower input lag for fullscreen games that request it"),
                _settings.get_boolean("allow-tearing"));
            _settings.bind("allow-tearing", tearing_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            gm_group.add_row(tearing_row);

            gm.state_changed.connect(() => {
                manual_row.active = gm.active;
                auto_row.sensitive = gm.available;
                manual_row.sensitive = gm.available;
            });

            add_group(gm_group);

            // MangoHud
            bool mangohud_available = GLib.Environment.find_program_in_path("mangohud") != null;
            var hud_group = new PreferencesGroup(_("MangoHud"));
            hud_group.description = mangohud_available
                ? "MangoHud detected - overlay for FPS, temps and more"
                : "Install MangoHud for in-game performance overlay";

            var hud_auto_row = new SwitchRow(_("Auto MangoHud"),
                "Inject MangoHud overlay when launching games via the shell");
            hud_auto_row.sensitive = mangohud_available;
            hud_auto_row.active = mangohud_available && _settings.get_boolean("mangohud-auto");
            hud_auto_row.switch_btn.notify["active"].connect(() => {
                _settings.set_boolean("mangohud-auto", hud_auto_row.active);
            });
            hud_group.add_row(hud_auto_row);
            add_group(hud_group);

            // Power profile. The platform profiles (Power Saver, Balanced,
            // Performance) go through power-profiles-daemon, which sets the CPU
            // governor and platform tuning itself and handles polkit. Extreme
            // Save is Singularity's own profile on top: it also dims the screen
            // and disables animations (ExtremeModeManager) over PPD power-saver.
            // Same four-state model as the system quick-settings tile.
            ppm = SystemMonitor.get_default().power_profiles;
            extreme = ExtremeModeManager.get_default();
            var profile_group = new PreferencesGroup(_("Power Profile"));
            profile_group.description = "Extreme Save also dims the screen and disables animations";
            string[] labels = { "Extreme Save", "Power Saver", "Balanced", "Performance" };
            var profile_row = new SelectionRow(_("Profile"), labels, current_profile_label(ppm, extreme));
            profile_row.selected.connect((item) => {
                apply_profile_label(ppm, extreme, item);
            });
            profile_group.add_row(profile_row);
            add_group(profile_group);

            build_fans();

            // Display link
            var display_group = new PreferencesGroup(_("Display"));
            var vrr_link = new ActionRow(_("Variable Refresh Rate (VRR)"), _("Configure VRR in Display settings"), "video-display-symbolic");
            vrr_link.activatable = true;
            vrr_link.activated.connect(() => view.navigate_to("displays"));
            display_group.add_row(vrr_link);
            add_group(display_group);
        }

        private void build_fans() {
            fans_group = new PreferencesGroup(_("Fans"), _("Live fan speed and temperature"));
            add_group(fans_group);

            var control = FanControlManager.get_default();
            control.changed.connect(() => {
                rebuild_curves();
                update_fan_rows();
            });
            ppm.profile_changed.connect(update_profile_row);

            fan_monitor = new SensorMonitor();
            fan_monitor.updated.connect(update_fans);
            map.connect(() => {
                fan_monitor.start();
                control.refresh.begin();
            });
            unmap.connect(() => fan_monitor.stop());
            fan_monitor.refresh();
        }

        private static string fan_key(FanReading fan) {
            return "%s:%d".printf(fan.hwmon_path, fan.channel);
        }

        private FanControlChannel? control_for(FanReading fan) {
            if (fan.pwm_channel <= 0) return null;
            return FanControlManager.get_default().find(Path.get_basename(fan.hwmon_path), fan.pwm_channel);
        }

        private void update_fans() {
            var fans = fan_monitor.fan_channels();
            string layout = "";
            foreach (var fan in fans) layout += fan_key(fan) + ";";
            if (layout != fan_layout) {
                fan_layout = layout;
                rebuild_fan_rows(fans);
                rebuild_curves();
            }
            update_fan_rows();

            SensorReading? hottest = null;
            foreach (var reading in fan_monitor.readings()) {
                if (reading.kind != SensorKind.CPU) continue;
                if (hottest == null || reading.millidegrees > hottest.millidegrees) hottest = reading;
            }
            if (hottest == null) {
                foreach (var reading in fan_monitor.readings()) {
                    if (hottest == null || reading.millidegrees > hottest.millidegrees) hottest = reading;
                }
            }
            int millidegrees = hottest != null ? hottest.millidegrees : -1;
            if (fan_graph != null) {
                int rpm = 0;
                foreach (var fan in fans) rpm = int.max(rpm, fan.rpm);
                fan_graph.push(rpm, millidegrees, hottest != null ? hottest.heat_fraction : 0.0);
            }
            foreach (var editor in curve_editors) editor.live_millidegrees = millidegrees;
        }

        private void rebuild_fan_rows(FanReading[] fans) {
            fans_group.clear();
            curve_rows.clear();
            fan_rows.clear();
            fan_values.clear();
            fan_graph = null;
            fan_profile_row = null;
            if (fans.length == 0) {
                var empty = new ActionRow(_("No fans reported"),
                    _("This machine does not expose any fan to the system"));
                empty.activatable = false;
                fans_group.add_row(empty);
                return;
            }
            for (int i = 0; i < fans.length; i++) {
                var row = new ActionRow(fans.length == 1 ? _("Fan") : _("Fan %d").printf(i + 1));
                row.activatable = false;
                row.tooltip_text = fans[i].label;
                var value = new Label("");
                value.add_css_class("dim-label");
                row.add_suffix(value);
                fans_group.add_row(row);
                fan_rows[fan_key(fans[i])] = row;
                fan_values[fan_key(fans[i])] = value;
            }
            fan_graph = new FanHistoryGraph();
            var graph_row = new PreferencesRow();
            graph_row.activatable = false;
            graph_row.set_child(fan_graph);
            fans_group.add_row(graph_row);

            fan_profile_row = new ActionRow(_("Fan Behavior"), "");
            fan_profile_row.activatable = false;
            fans_group.add_row(fan_profile_row);
        }

        private string fan_mode_text(FanReading fan, FanControlChannel? channel) {
            if (channel != null && channel.active == "software") return _("Custom curve, kept by the fan control service");
            if (channel != null && channel.active == "hardware") return _("Custom curve, applied by the fan chip");
            switch (fan.mode) {
                case FanMode.AUTOMATIC: return _("Auto (firmware)");
                case FanMode.MANUAL: return _("Manual");
                case FanMode.FULL_SPEED: return _("Full speed");
                default: return _("Speed control not reported");
            }
        }

        private void update_fan_rows() {
            foreach (var fan in fan_monitor.fan_channels()) {
                string key = fan_key(fan);
                if (!fan_rows.has_key(key)) continue;
                fan_rows[key].subtitle = fan_mode_text(fan, control_for(fan));
                string value = _("%d RPM").printf(fan.rpm);
                if (fan.pwm >= 0) value += "   %d%%".printf((int) Math.round(fan.pwm_fraction * 100));
                fan_values[key].label = value;
            }
            update_profile_row();
        }

        private void update_profile_row() {
            if (fan_profile_row == null) return;
            bool follows_firmware = false;
            foreach (var fan in fan_monitor.fan_channels()) {
                var channel = control_for(fan);
                bool custom = channel != null && channel.active != "firmware";
                if (!custom && fan.mode != FanMode.MANUAL) follows_firmware = true;
            }
            fan_profile_row.visible = ppm.available && follows_firmware;
            fan_profile_row.subtitle = _("The fans follow the %s power profile").printf(current_profile_label(ppm, extreme));
        }

        private void add_curve_row(Widget row) {
            fans_group.add_row(row);
            curve_rows.add(row);
        }

        private void rebuild_curves() {
            foreach (var row in curve_rows) fans_group.remove_row(row);
            curve_rows.clear();
            curve_editors.clear();
            if (fan_profile_row == null) return;
            var seen = new Gee.ArrayList<string>();
            FanReading[] controlled = {};
            foreach (var fan in fan_monitor.fan_channels()) {
                if (fan.pwm_channel <= 0) continue;
                string key = "%s:%d".printf(fan.hwmon_path, fan.pwm_channel);
                if (key in seen) continue;
                seen.add(key);
                controlled += fan;
            }
            for (int i = 0; i < controlled.length; i++) {
                string name = controlled.length == 1 ? "" : _("Fan %d").printf(controlled[i].channel);
                add_curve_rows(controlled[i], control_for(controlled[i]), name);
            }
        }

        private static string titled(string name, string title) {
            return name == "" ? title : "%s: %s".printf(name, title);
        }

        private void add_curve_rows(FanReading fan, FanControlChannel? channel, string name) {
            var control = FanControlManager.get_default();
            int[] chip_temps;
            int[] chip_pwms;
            fan.read_auto_points(out chip_temps, out chip_pwms);
            int crit = channel != null ? channel.crit_millidegrees : Thresholds.fallback_limit(SensorKind.CPU);

            var restore_btn = new Button.with_label(_("Restore Firmware"));
            restore_btn.add_css_class("pill");
            restore_btn.valign = Align.CENTER;

            if (channel == null || !channel.tunable) {
                string reason;
                if (channel != null) reason = channel.reason;
                else if (control.available) reason = _("The fan control service does not list this fan");
                else reason = _("The fan control service is not installed");
                var row = new ActionRow(titled(name, _("Managed by firmware")), reason);
                row.activatable = false;
                restore_btn.sensitive = false;
                row.add_suffix(restore_btn);
                add_curve_row(row);
                if (chip_temps.length >= 2) {
                    var editor = new FanCurveEditor(false);
                    editor.crit_millidegrees = crit;
                    int[] percents = {};
                    foreach (int pwm in chip_pwms) percents += (int) Math.round(pwm * 100.0 / 255.0);
                    editor.set_points(chip_temps, percents);
                    editor.tooltip_text = _("Curve programmed in the fan chip");
                    add_editor_row(editor, null);
                }
                return;
            }

            string how = channel.method == "hardware"
                ? _("Written to the fan chip, which keeps applying it even if the service stops")
                : _("Applied by the fan control service, which hands the fan back to the firmware if it stops");
            var header = new ActionRow(titled(name, channel.active == "firmware"
                ? _("Firmware in control") : _("Custom curve active")), how);
            header.activatable = false;
            restore_btn.sensitive = true;
            header.add_suffix(restore_btn);
            add_curve_row(header);

            var editor = new FanCurveEditor(true);
            editor.crit_millidegrees = channel.crit_millidegrees;
            editor.min_percent = channel.min_percent;
            if (valid_curve(channel.temps, channel.percents, channel)) {
                editor.set_points(channel.temps, channel.percents);
            } else {
                int[] temps;
                int[] percents;
                default_curve(int.min(5, channel.max_points), channel.crit_millidegrees, out temps, out percents);
                editor.set_points(temps, percents);
            }

            var controls = new Box(Orientation.HORIZONTAL, 6);
            controls.margin_start = 12;
            controls.margin_end = 12;
            controls.margin_bottom = 10;
            var remove_btn = new Button.from_icon_name("list-remove-symbolic");
            remove_btn.add_css_class("flat");
            remove_btn.tooltip_text = _("Remove a point");
            var add_btn = new Button.from_icon_name("list-add-symbolic");
            add_btn.add_css_class("flat");
            add_btn.tooltip_text = _("Add a point");
            var status = new Label(_("Drag the points to shape the curve"));
            status.add_css_class("caption");
            status.add_css_class("dim-label");
            status.hexpand = true;
            status.xalign = 0;
            status.wrap = true;
            var apply_btn = new Button.with_label(_("Apply"));
            apply_btn.add_css_class("suggested-action");
            apply_btn.add_css_class("pill");
            controls.append(remove_btn);
            controls.append(add_btn);
            controls.append(status);
            controls.append(apply_btn);

            int max_points = channel.max_points;
            sync_point_buttons(editor, add_btn, remove_btn, max_points);
            editor.changed.connect(() => {
                status.label = _("Not applied yet");
                sync_point_buttons(editor, add_btn, remove_btn, max_points);
            });
            add_btn.clicked.connect(() => editor.add_point());
            remove_btn.clicked.connect(() => editor.remove_point());

            string id = channel.id;
            apply_btn.clicked.connect(() => {
                apply_btn.sensitive = false;
                status.label = _("Applying...");
                control.set_curve.begin(id, editor.temps, editor.percents, (obj, res) => {
                    try {
                        control.set_curve.end(res);
                    } catch (Error e) {
                        status.label = e.message;
                        apply_btn.sensitive = true;
                    }
                });
            });
            restore_btn.clicked.connect(() => {
                restore_btn.sensitive = false;
                control.reset_firmware.begin(id, (obj, res) => {
                    try {
                        control.reset_firmware.end(res);
                    } catch (Error e) {
                        status.label = e.message;
                        restore_btn.sensitive = true;
                    }
                });
            });

            add_editor_row(editor, controls);
        }

        private static void sync_point_buttons(FanCurveEditor editor, Button add_btn,
                                               Button remove_btn, int max_points) {
            add_btn.sensitive = editor.temps.length < max_points;
            remove_btn.sensitive = editor.temps.length > 4;
        }

        private void add_editor_row(FanCurveEditor editor, Widget? controls) {
            var box = new Box(Orientation.VERTICAL, 0);
            box.append(editor);
            if (controls != null) box.append(controls);
            var row = new PreferencesRow();
            row.activatable = false;
            row.set_child(box);
            add_curve_row(row);
            curve_editors.add(editor);
        }

        private static bool valid_curve(int[] temps, int[] percents, FanControlChannel channel) {
            int n = temps.length;
            if (n < 4 || n > channel.max_points || n != percents.length) return false;
            int ceiling = channel.crit_millidegrees - 5000;
            for (int i = 0; i < n; i++) {
                if (temps[i] < 20000 || temps[i] > ceiling) return false;
                if (percents[i] < channel.min_percent || percents[i] > 100) return false;
                if (i > 0 && (temps[i] <= temps[i - 1] || percents[i] < percents[i - 1])) return false;
            }
            return true;
        }

        private static void default_curve(int n, int crit, out int[] temps, out int[] percents) {
            int low = 40000;
            int high = crit - 10000;
            int[] t = {};
            int[] p = {};
            for (int i = 0; i < n; i++) {
                t += (low + i * (high - low) / (n - 1)) / 1000 * 1000;
                p += (int) Math.round(25 + i * 75.0 / (n - 1));
            }
            temps = t;
            percents = p;
        }

        // Label for the current state: Extreme Save wins over the PPD profile.
        private static string current_profile_label(PowerProfilesManager ppm, ExtremeModeManager extreme) {
            if (extreme.active) return "Extreme Save";
            switch (ppm.active_profile) {
                case "power-saver": return "Power Saver";
                case "performance": return "Performance";
                default:            return "Balanced";
            }
        }

        // Apply a chosen label, mirroring the system tile: Extreme Save turns on
        // extreme mode over PPD power-saver; the others turn it off and set the
        // matching PPD profile.
        private void apply_profile_label(PowerProfilesManager ppm, ExtremeModeManager extreme, string label) {
            switch (label) {
                case "Extreme Save":
                    extreme.set_extreme_mode(true);
                    ppm.set_profile("power-saver");
                    break;
                case "Power Saver":
                    extreme.set_extreme_mode(false);
                    ppm.set_profile("power-saver");
                    break;
                case "Balanced":
                    extreme.set_extreme_mode(false);
                    ppm.set_profile("balanced");
                    break;
                case "Performance":
                    extreme.set_extreme_mode(false);
                    ppm.set_profile("performance");
                    break;
            }
        }
    }
}
