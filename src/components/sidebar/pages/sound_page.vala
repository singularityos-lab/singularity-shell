using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class SoundPage : SettingsPage {

        public SoundPage(SettingsView view) {
            base(_("Sound"));
            back_clicked.connect(() => {
                view.go_home();
            });
            var audio = SystemMonitor.get_default().audio;
            var out_group = new PreferencesGroup(_("Output"));
            var vol_row = new PreferencesRow();
            var vol_box = new Box(Orientation.HORIZONTAL, 12);
            vol_box.margin_top = 12;
            vol_box.margin_bottom = 12;
            vol_box.margin_start = 12;
            vol_box.margin_end = 12;
            var vol_icon = new Image.from_icon_name("audio-volume-high-symbolic");
            var vol_scale = new Scale.with_range(Orientation.HORIZONTAL, 0, audio.max_volume, 1);
            vol_scale.draw_value = true;
            if (audio.max_volume > 100) vol_scale.add_mark(100, PositionType.BOTTOM, null);
            audio.notify["max-volume"].connect(() => {
                vol_scale.set_range(0, audio.max_volume);
                vol_scale.clear_marks();
                if (audio.max_volume > 100) vol_scale.add_mark(100, PositionType.BOTTOM, null);
            });
            vol_scale.value_pos = PositionType.RIGHT;
            vol_scale.hexpand = true;
            vol_scale.set_value(audio.volume);
            vol_scale.value_changed.connect(() => {
                audio.update_volume(vol_scale.get_value());
            });
            audio.state_changed.connect(() => {
                if (vol_scale.get_value() != audio.volume)
                    vol_scale.set_value(audio.volume);
            });
            vol_box.append(vol_icon);
            vol_box.append(vol_scale);
            vol_row.set_child(vol_box);
            out_group.add_row(vol_row);
            var eq_row = EqualizerPage.entry_row(view);
            out_group.add_row(eq_row);
            EqualizerPage.register_search(this, view, eq_row);
            var output_device_rows = new List<Widget>();
            update_audio_devices_list(out_group, ref output_device_rows, audio);
            audio.devices_changed.connect(() => {
                update_audio_devices_list(out_group, ref output_device_rows, audio);
            });
            var eq_manager = EqualizerManager.get_default();
            ulong eq_handler = eq_manager.changed.connect(() => {
                update_audio_devices_list(out_group, ref output_device_rows, audio);
            });
            destroy.connect(() => eq_manager.disconnect(eq_handler));
            add_group(out_group);
            var in_group = new PreferencesGroup(_("Input"));
            var in_vol_row = new PreferencesRow();
            var in_vol_box = new Box(Orientation.HORIZONTAL, 12);
            in_vol_box.margin_top = 12;
            in_vol_box.margin_bottom = 12;
            in_vol_box.margin_start = 12;
            in_vol_box.margin_end = 12;
            var in_vol_icon = new Image.from_icon_name("audio-input-microphone-symbolic");
            var in_vol_scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 100, 1);
            in_vol_scale.draw_value = true;
            in_vol_scale.value_pos = PositionType.RIGHT;
            in_vol_scale.hexpand = true;
            in_vol_scale.set_value(audio.input_volume);
            in_vol_scale.value_changed.connect(() => {
                audio.update_input_volume(in_vol_scale.get_value());
            });
            audio.state_changed.connect(() => {
                if (in_vol_scale.get_value() != audio.input_volume)
                    in_vol_scale.set_value(audio.input_volume);
            });
            in_vol_box.append(in_vol_icon);
            in_vol_box.append(in_vol_scale);
            in_vol_row.set_child(in_vol_box);
            in_group.add_row(in_vol_row);
            var input_device_rows = new List<Widget>();
            update_input_devices_list(in_group, ref input_device_rows, audio);
            audio.devices_changed.connect(() => {
                update_input_devices_list(in_group, ref input_device_rows, audio);
            });
            add_group(in_group);
            var app_group = new PreferencesGroup(_("Applications"));
            var app_rows = new List<Widget>();
            update_app_list(app_group, ref app_rows, audio);
            audio.mixer_changed.connect(() => {
                update_app_list(app_group, ref app_rows, audio);
            });
            add_group(app_group);

            var media_group = new PreferencesGroup(_("Media"));
            var media_settings = new GLib.Settings("dev.sinty.desktop");
            var exclusive_row = new SwitchRow(_("One Player at a Time"),
                _("Pause other media when something starts playing"),
                media_settings.get_boolean("media-exclusive-playback"));
            media_settings.bind("media-exclusive-playback", exclusive_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            media_group.add_row(exclusive_row);
            add_group(media_group);
        }

        private void update_audio_devices_list(PreferencesGroup group, ref List<Widget> rows, AudioManager audio) {
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();
            unowned var all_sinks = audio.sinks;
            var equalizer = EqualizerManager.get_default();
            var sinks = new List<AudioManager.AudioDevice?>();
            foreach (var s in all_sinks) {
                if (!equalizer.is_virtual(s.name)) sinks.append(s);
            }
            string routed = equalizer.routed_default();
            if (sinks.length() == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No output devices found"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            foreach (var sink in sinks) {
                bool is_default = (sink.index == audio.default_sink_index) || (routed != "" && sink.name == routed);
                string? detail = equalizer.is_equalizing(sink.name) ? _("Equalizer on") : null;
                var row = new ActionRow(sink.description, detail, "audio-card-symbolic");
                row.activatable = true;
                if (is_default) {
                    row.add_suffix(new Image.from_icon_name("object-select-symbolic"));
                    row.add_css_class("selected");
                }
                var gesture = new GestureClick();
                gesture.released.connect(() => {
                    if (!is_default) {
                        audio.set_default_sink(sink.name);
                    }
                });
                row.add_controller(gesture);
                group.add_row(row);
                rows.append(row);
            }
        }

        private void update_input_devices_list(PreferencesGroup group, ref List<Widget> rows, AudioManager audio) {
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();
            unowned var sources = audio.sources;
            if (sources.length() == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No input devices found"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            foreach (var source in sources) {
                bool is_default = (source.index == audio.default_source_index);
                var row = new ActionRow(source.description, null, "audio-input-microphone-symbolic");
                row.activatable = true;
                if (is_default) {
                    row.add_suffix(new Image.from_icon_name("object-select-symbolic"));
                }
                var gesture = new GestureClick();
                gesture.released.connect(() => {
                    if (!is_default) {
                        audio.set_default_source(source.name);
                    }
                });
                row.add_controller(gesture);
                group.add_row(row);
                rows.append(row);
            }
        }

        private string app_list_key = "";

        private void update_app_list(PreferencesGroup group, ref List<Widget> rows, AudioManager audio) {
            var key = new StringBuilder();
            foreach (var input in audio.sink_inputs) key.append_printf("%u:%s;", input.index, input.app_name);
            if (rows.length() > 0 && key.str == app_list_key) return;
            app_list_key = key.str;
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();
            unowned var inputs = audio.sink_inputs;
            if (inputs.length() == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No applications playing audio"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            foreach (var input in inputs) {
                if (input.app_name.contains("speech-dispatcher") || input.app_name.contains("dummy")) {
                    continue;
                }
                var row = new PreferencesRow();
                var row_box = new Box(Orientation.HORIZONTAL, 12);
                row_box.margin_top = 10;
                row_box.margin_bottom = 10;
                row_box.margin_start = 12;
                row_box.margin_end = 12;

                var app_icon = new Image();
                app_icon.pixel_size = 20;
                app_icon.valign = Align.CENTER;
                load_notification_icon(app_icon, input.icon_name, input.app_name);

                var name_label = new Label(input.app_name);
                name_label.halign = Align.START;
                name_label.hexpand = true;
                name_label.ellipsize = Pango.EllipsizeMode.END;

                var scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 100, 1);
                scale.set_size_request(150, -1);
                scale.draw_value = false;
                scale.set_value(input.volume);
                scale.valign = Align.CENTER;

                row_box.append(app_icon);
                row_box.append(name_label);
                row_box.append(scale);
                row.set_child(row_box);

                uint32 idx = input.index;
                scale.value_changed.connect(() => {
                    audio.update_app_volume(idx, scale.get_value());
                });
                group.add_row(row);
                rows.append(row);
            }
        }
    }
}
