using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class EqualizerPage : SettingsPage {
        private EqualizerManager manager;
        private EqualizerProfile? profile = null;
        private StatusPage unavailable;
        private PreferencesGroup output_group;
        private PreferencesGroup tone_group;
        private PreferencesGroup bands_group;
        private SwitchRow enabled_row;
        private SelectionRow preset_row;
        private Scale[] scales = new Scale[EqualizerBands.COUNT];
        private Label[] values = new Label[EqualizerBands.COUNT];
        private bool loading = false;
        private uint save_id = 0;
        private ulong changed_handler = 0;

        public static ActionRow entry_row(SettingsView view) {
            var manager = EqualizerManager.get_default();
            var row = new ActionRow(_("Equalizer"), status(manager), "singularity-equalizer-symbolic");
            row.activatable = true;
            row.add_suffix(SidebarPages.NotificationSettingsPage.chevron());
            row.activated.connect(() => view.open_subpage(new EqualizerPage(view), "equalizer"));
            ulong h = manager.changed.connect(() => row.subtitle = status(manager));
            row.destroy.connect(() => manager.disconnect(h));
            return row;
        }

        public static void register_search(SettingsPage page, SettingsView view, Widget entry) {
            entry.set_data<bool>("settings-search-skip", true);
            string[] names = {};
            foreach (var p in EqualizerBands.presets()) names += p.name;
            page.add_search_action(_("Equalizer"), string.joinv(", ", names),
                () => view.open_subpage(new EqualizerPage(view), "equalizer"));
        }

        public static string status(EqualizerManager manager) {
            if (manager.ready && !manager.available) return _("Not available on this system");
            if (manager.output_device == "") return _("Off");
            var p = manager.profile_for(manager.output_device);
            if (!p.enabled) return _("Off");
            return preset_name(p.preset);
        }

        public static string preset_name(string id) {
            var preset = EqualizerBands.find_preset(id);
            return preset != null ? preset.name : _("Custom");
        }

        public EqualizerPage(SettingsView view) {
            base(_("Equalizer"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("sound"));
            manager = EqualizerManager.get_default();

            unavailable = new StatusPage();
            unavailable.compact = true;
            unavailable.icon_name = "singularity-equalizer";
            unavailable.title = _("Equalizer Not Available");
            unavailable.description = _("The equalizer needs PipeWire. Your distribution can also connect its own sound effects program.");
            unavailable.visible = false;
            add_widget(unavailable);

            output_group = new PreferencesGroup(_("Output"), _("Each output device keeps its own settings."));
            enabled_row = new SwitchRow(_("Output Device"), _("Use the equalizer on this output"), false);
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (loading || profile == null) return;
                profile.enabled = enabled_row.switch_btn.active;
                update_sensitivity();
                manager.save_profile(profile);
            });
            output_group.add_row(enabled_row);
            add_group(output_group);

            tone_group = new PreferencesGroup(_("Tone"));
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            foreach (var p in EqualizerBands.presets()) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = p.id;
                o.label = p.name;
                options.add(o);
            }
            var custom = new Singularity.Core.AppSettingOption();
            custom.id = "custom";
            custom.label = _("Custom");
            options.add(custom);
            preset_row = new SelectionRow.with_options(_("Preset"), options, "flat");
            preset_row.selected.connect(on_preset);
            tone_group.add_row(preset_row);
            add_group(tone_group);

            bands_group = new PreferencesGroup(_("Bands"), _("Drag a slider up to boost a range, down to soften it."));
            var row = new PreferencesRow();
            row.activatable = false;
            var grid = new Box(Orientation.HORIZONTAL, 0);
            grid.homogeneous = true;
            grid.margin_top = 12;
            grid.margin_bottom = 12;
            grid.margin_start = 2;
            grid.margin_end = 2;
            grid.add_css_class("equalizer-bands");
            for (int i = 0; i < EqualizerBands.COUNT; i++) {
                int band = i;
                var column = new Box(Orientation.VERTICAL, 4);
                column.halign = Align.CENTER;
                column.add_css_class("equalizer-band");
                var value = new Label("0");
                value.add_css_class("caption");
                value.add_css_class("numeric");
                value.add_css_class("equalizer-value");
                values[i] = value;
                var scale = new Scale.with_range(Orientation.VERTICAL, EqualizerBands.MIN_GAIN, EqualizerBands.MAX_GAIN, 0.5);
                scale.inverted = true;
                scale.draw_value = false;
                scale.set_size_request(-1, 150);
                scale.halign = Align.CENTER;
                scale.add_mark(0, PositionType.RIGHT, null);
                scale.update_property(AccessibleProperty.LABEL,
                    _("%s Hz").printf(EqualizerBands.label(i)));
                scale.value_changed.connect(() => on_band_changed(band));
                scales[i] = scale;
                var freq = new Label(EqualizerBands.label(i));
                freq.add_css_class("caption");
                freq.add_css_class("dim-label");
                column.append(value);
                column.append(scale);
                column.append(freq);
                grid.append(column);
            }
            row.set_child(grid);
            bands_group.add_row(row);
            add_group(bands_group);

            changed_handler = manager.changed.connect(() => reload());
            destroy.connect(() => {
                if (changed_handler != 0) manager.disconnect(changed_handler);
                changed_handler = 0;
                flush();
            });
            reload();
        }

        private void reload() {
            bool ready = manager.ready;
            unavailable.visible = ready && !manager.available;
            bool usable = ready && manager.available && manager.output_device != "";
            output_group.visible = usable;
            tone_group.visible = usable;
            bands_group.visible = usable;
            if (!usable) return;
            if (profile != null && profile.device == manager.output_device) {
                enabled_row.title = manager.output_description;
                return;
            }
            flush();
            profile = manager.profile_for(manager.output_device);
            loading = true;
            enabled_row.title = manager.output_description;
            enabled_row.switch_btn.active = profile.enabled;
            preset_row.current_value = EqualizerBands.match_preset(profile.gains) == "custom" ? "custom" : profile.preset;
            for (int i = 0; i < EqualizerBands.COUNT; i++) {
                scales[i].set_value(profile.gains[i]);
                values[i].label = short_gain(profile.gains[i]);
            }
            loading = false;
            update_sensitivity();
        }

        private void update_sensitivity() {
            bool on = profile != null && profile.enabled;
            tone_group.sensitive = on;
            bands_group.sensitive = on;
        }

        private static string short_gain(double gain) {
            double g = EqualizerBands.clamp_gain(gain);
            if (g == 0.0) return "0";
            string text = Math.fabs(g - Math.round(g)) < 0.05 ? "%d".printf((int) Math.round(g)) : EqualizerBands.number(g);
            return g > 0 ? "+" + text : text;
        }

        private void on_preset(string id) {
            if (loading || profile == null) return;
            var preset = EqualizerBands.find_preset(id);
            profile.preset = id;
            if (preset != null) {
                loading = true;
                profile.gains = EqualizerBands.normalize(preset.gains);
                for (int i = 0; i < EqualizerBands.COUNT; i++) {
                    scales[i].set_value(profile.gains[i]);
                    values[i].label = short_gain(profile.gains[i]);
                }
                loading = false;
            }
            queue_save();
        }

        private void on_band_changed(int band) {
            if (loading || profile == null) return;
            profile.gains[band] = EqualizerBands.clamp_gain(scales[band].get_value());
            values[band].label = short_gain(profile.gains[band]);
            profile.preset = EqualizerBands.match_preset(profile.gains);
            loading = true;
            preset_row.current_value = profile.preset;
            loading = false;
            scales[band].update_property(AccessibleProperty.VALUE_TEXT, EqualizerBands.format_gain(profile.gains[band]));
            queue_save();
        }

        private void queue_save() {
            if (save_id != 0) Source.remove(save_id);
            save_id = Timeout.add(120, () => {
                save_id = 0;
                if (profile != null) manager.save_profile(profile.copy());
                return Source.REMOVE;
            });
        }

        private void flush() {
            if (save_id == 0) return;
            Source.remove(save_id);
            save_id = 0;
            if (profile != null) manager.save_profile(profile.copy());
        }
    }
}
