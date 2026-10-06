using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class NightLightPage : SettingsPage {
        private NightLightManager night_light;
        private GLib.Settings settings;
        private SwitchRow enabled_row;
        private SelectionRow schedule_row;
        private ActionRow sun_row;
        private PreferencesRow from_row;
        private TimePicker from_picker;
        private PreferencesRow to_row;
        private TimePicker to_picker;
        private SwitchRow dark_theme_row;
        private Scale temp_scale;
        private string[] schedule_labels;
        private bool syncing = false;

        public NightLightPage(SettingsView view) {
            base(_("Night Light"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("displays"));
            night_light = SystemMonitor.get_default().night_light;
            settings = new GLib.Settings("dev.sinty.desktop");
            schedule_labels = { _("Always"), _("Sunset to Sunrise"), _("Custom Times") };

            var group = new PreferencesGroup(_("Schedule"));
            add_group(group);

            enabled_row = new SwitchRow(_("Night Light"), _("Warm the screen color temperature in the evening"));
            settings.bind("night-light-enabled", enabled_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            group.add_row(enabled_row);

            schedule_row = new SelectionRow(_("Turn On"), schedule_labels, schedule_labels[schedule_index()]);
            schedule_row.selected.connect(on_schedule_selected);
            group.add_row(schedule_row);

            sun_row = new ActionRow(_("Sunset to Sunrise"), "", "weather-clear-night-symbolic");
            sun_row.activatable = false;
            group.add_row(sun_row);

            from_row = make_time_row(_("From"), "weather-clear-night-symbolic",
                settings.get_string("night-light-adaptive-from"), out from_picker);
            from_picker.changed.connect(() => night_light.set_schedule_from(from_picker.time));
            group.add_row(from_row);

            to_row = make_time_row(_("To"), "weather-clear-symbolic",
                settings.get_string("night-light-adaptive-to"), out to_picker);
            to_picker.changed.connect(() => night_light.set_schedule_to(to_picker.time));
            group.add_row(to_row);

            dark_theme_row = new SwitchRow(_("Dark Theme"), _("Switch to the dark appearance during the schedule"));
            settings.bind("night-light-dark-theme", dark_theme_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            group.add_row(dark_theme_row);

            var color_group = new PreferencesGroup(_("Color"));
            add_group(color_group);
            var temp_row = new PreferencesRow();
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
                if (!syncing) night_light.set_temperature((int) temp_scale.get_value());
            });
            temp_box.append(temp_scale);
            var temp_hint = new Label(_("Color temperature in Kelvin, lower values are warmer"));
            temp_hint.add_css_class("dim-label");
            temp_hint.wrap = true;
            temp_hint.xalign = 0;
            temp_box.append(temp_hint);
            temp_row.set_child(temp_box);
            color_group.add_row(temp_row);

            night_light.changed.connect(sync);
            settings.changed.connect((key) => {
                if (key.has_prefix("night-light")) sync();
            });
            sync();
        }

        private int schedule_index() {
            if (!settings.get_boolean("night-light-adaptive")) return 0;
            return settings.get_string("night-light-schedule") == "sunset-sunrise" ? 1 : 2;
        }

        private void on_schedule_selected(string item) {
            if (syncing) return;
            if (item == schedule_labels[0]) {
                settings.set_boolean("night-light-adaptive", false);
            } else {
                settings.set_string("night-light-schedule", item == schedule_labels[1] ? "sunset-sunrise" : "manual");
                settings.set_boolean("night-light-adaptive", true);
            }
        }

        private PreferencesRow make_time_row(string title, string icon_name, string initial, out TimePicker picker) {
            var row = new PreferencesRow();
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 12;
            box.margin_end = 12;
            box.append(new Image.from_icon_name(icon_name));
            var lbl = new Label(title);
            lbl.add_css_class("title");
            lbl.halign = Align.START;
            lbl.hexpand = true;
            box.append(lbl);
            picker = new TimePicker(initial);
            box.append(picker);
            row.set_child(box);
            return row;
        }

        private string sun_subtitle() {
            string source = settings.get_string("night-light-sun-source");
            string from = settings.get_string("night-light-sun-from");
            string to = settings.get_string("night-light-sun-to");
            if (source == "") return _("Your location and time zone are unknown, so the times cannot be worked out");
            string range;
            if (from == to) range = _("The sun does not set today");
            else if (from == "00:00" && to == "23:59") range = _("The sun does not rise today");
            else range = _("From %s to %s").printf(from, to);
            if (source == "location") return _("%s, from your location").printf(range);
            return _("%s, from your time zone").printf(range);
        }

        private void sync() {
            syncing = true;
            int index = schedule_index();
            schedule_row.current_value = schedule_labels[index];
            temp_scale.set_value((double) settings.get_int("night-light-temperature"));
            from_picker.time = settings.get_string("night-light-adaptive-from");
            to_picker.time = settings.get_string("night-light-adaptive-to");
            sun_row.visible = index == 1;
            sun_row.subtitle = sun_subtitle();
            from_row.visible = index == 2;
            to_row.visible = index == 2;
            dark_theme_row.visible = index != 0;
            if (night_light.enabled) {
                enabled_row.subtitle = _("On");
            } else if (enabled_row.active && index != 0) {
                enabled_row.subtitle = _("Off until %s").printf(settings.get_string(night_light.from_key()));
            } else {
                enabled_row.subtitle = _("Off");
            }
            syncing = false;
        }
    }
}
