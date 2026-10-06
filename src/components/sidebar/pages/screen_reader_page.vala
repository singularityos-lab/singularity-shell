using Gtk;
using Singularity.Widgets;
using Singularity.Accessibility;

namespace Singularity.SidebarPages {

    public class ScreenReaderPage : SettingsPage {
        private const string PAGE_NAME = "accessibility-screen-reader";

        private unowned SettingsView view;
        private GLib.Settings? applications_settings;
        private ScreenReaderSettings reader;
        private SpeechVoices voices;
        private bool syncing = false;

        private SettingsPage? voice_page = null;
        private ActionRow? voice_link = null;
        private SelectionRow verbosity_row;
        private SelectionRow punctuation_row;
        private SwitchRow key_echo_row;
        private SwitchRow character_echo_row;
        private SwitchRow word_echo_row;
        private SelectionRow layout_row;
        private SelectionRow modifier_row;

        private PreferencesGroup synth_group;
        private SelectionRow synth_row;
        private SelectionRow voice_row;
        private Scale rate_scale;
        private Scale pitch_scale;
        private Scale volume_scale;
        private string[] modules = {};
        private SpeechVoice[] voice_list = {};
        private uint write_id = 0;

        private string[] verbosity_labels;
        private string[] punctuation_labels;
        private string[] layout_labels;
        private string[] modifier_labels;
        private const string[] MODIFIER_IDS = { "insert", "caps-lock", "both" };

        public ScreenReaderPage(SettingsView view, GLib.Settings? applications_settings) {
            base(_("Screen Reader"));
            this.view = view;
            this.applications_settings = applications_settings;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("accessibility"));
            reader = ScreenReaderSettings.detect();
            voices = new SpeechVoices(reader.config.voices_command);

            verbosity_labels = { _("Brief"), _("Verbose") };
            punctuation_labels = { _("All"), _("Most"), _("Some"), _("None") };
            layout_labels = { _("Desktop"), _("Laptop") };
            modifier_labels = { _("Insert"), _("Caps Lock"), _("Insert or Caps Lock") };

            bool installed = reader.available || AccessibilityManager.screen_reader_available();
            if (!installed) {
                build_missing();
                return;
            }
            build_switch_group();
            if (!reader.available) {
                var status = new StatusPage();
                status.icon_name = "singularity-screen-reader";
                status.title = _("Settings Not Available");
                status.description = _("This version of Orca keeps its settings in a place Singularity cannot read. Open Orca Preferences with Orca Key and Space.");
                status.compact = true;
                add_widget(status);
                return;
            }
            build_settings_groups();
            reader.changed.connect(sync_from_store);
            sync_from_store();
            map.connect(() => sync_from_store());
        }

        private void build_missing() {
            var status = new StatusPage();
            status.icon_name = "singularity-screen-reader";
            status.title = _("Orca Is Not Installed");
            string hint = reader.config.install_hint;
            status.description = hint != "" ? hint
                : _("The screen reader reads out what is on the screen. Install the orca package with the software tool of your system, then come back here to choose its voice, speed and verbosity.");
            add_widget(status);
        }

        private void build_switch_group() {
            var group = new PreferencesGroup(_("Reading"));
            var row = new SwitchRow(_("Screen Reader"), _("Read out what is on the screen as you move the focus"));
            if (applications_settings != null && applications_settings.settings_schema.has_key("screen-reader-enabled")) {
                row.active = applications_settings.get_boolean("screen-reader-enabled");
                row.switch_btn.notify["active"].connect(() => {
                    if (applications_settings.get_boolean("screen-reader-enabled") != row.active)
                        applications_settings.set_boolean("screen-reader-enabled", row.active);
                });
                applications_settings.changed["screen-reader-enabled"].connect(() => {
                    bool v = applications_settings.get_boolean("screen-reader-enabled");
                    if (row.active != v) row.active = v;
                });
            } else {
                row.sensitive = false;
            }
            group.add_row(row);
            if (reader.available) {
                voice_page = build_voice_page();
                voice_link = new ActionRow(_("Voice"), "", "audio-speakers-symbolic");
                voice_link.activatable = true;
                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.add_css_class("dim-label");
                chevron.valign = Align.CENTER;
                voice_link.add_suffix(chevron);
                voice_link.activated.connect(() => view.open_subpage(voice_page, PAGE_NAME + "-voice"));
                group.add_row(voice_link);
            }
            add_group(group);
        }

        private void build_settings_groups() {
            var store = reader.store;
            var verbosity_group = new PreferencesGroup(_("Verbosity"));
            verbosity_row = new SelectionRow(_("Detail Level"), verbosity_labels, verbosity_labels[1]);
            verbosity_row.subtitle = _("How much Orca says about each item");
            verbosity_row.selected.connect((item) => {
                if (!syncing) store.set_string("verbosity", ScreenReaderSettings.VERBOSITY_LEVELS[index_of(verbosity_labels, item)]);
            });
            verbosity_group.add_row(verbosity_row);
            punctuation_row = new SelectionRow(_("Punctuation"), punctuation_labels, punctuation_labels[1]);
            punctuation_row.subtitle = _("Which punctuation marks are spoken");
            punctuation_row.selected.connect((item) => {
                if (!syncing) store.set_string("punctuation", ScreenReaderSettings.PUNCTUATION_LEVELS[index_of(punctuation_labels, item)]);
            });
            verbosity_group.add_row(punctuation_row);
            add_group(verbosity_group);

            var echo_group = new PreferencesGroup(_("Typing Echo"));
            key_echo_row = echo_switch(echo_group, _("Key Echo"), _("Speak each key as you press it"), "key-echo");
            character_echo_row = echo_switch(echo_group, _("Character Echo"), _("Speak each character as it is inserted"), "character-echo");
            word_echo_row = echo_switch(echo_group, _("Word Echo"), _("Speak each word when you finish typing it"), "word-echo");
            add_group(echo_group);

            var key_group = new PreferencesGroup(_("Orca Key"));
            layout_row = new SelectionRow(_("Keyboard Layout"), layout_labels, layout_labels[0]);
            layout_row.subtitle = _("Laptop uses shortcuts that need no numeric keypad");
            layout_row.selected.connect((item) => {
                if (!syncing) store.set_string("keyboard-layout", ScreenReaderSettings.KEYBOARD_LAYOUTS[index_of(layout_labels, item)]);
            });
            key_group.add_row(layout_row);
            modifier_row = new SelectionRow(_("Orca Modifier"), modifier_labels, modifier_labels[0]);
            modifier_row.subtitle = _("The key you hold for Orca commands");
            modifier_row.selected.connect((item) => {
                if (!syncing) reader.set_modifier_choice(MODIFIER_IDS[index_of(modifier_labels, item)]);
            });
            key_group.add_row(modifier_row);
            add_group(key_group);
        }

        private SwitchRow echo_switch(PreferencesGroup group, string title, string subtitle, string key) {
            var row = new SwitchRow(title, subtitle);
            row.switch_btn.notify["active"].connect(() => {
                if (!syncing && reader.store.get_bool(key) != row.active) reader.store.set_bool(key, row.active);
            });
            group.add_row(row);
            return row;
        }

        private SettingsPage build_voice_page() {
            var page = new SettingsPage(_("Voice"));
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.open_subpage(this, PAGE_NAME));

            synth_group = new PreferencesGroup(_("Speech Engine"));
            synth_row = new SelectionRow(_("Synthesizer"), {}, "");
            synth_row.selected.connect((item) => {
                if (syncing) return;
                int i = index_of(modules_labels(), item);
                string module = i > 0 ? modules[i - 1] : "";
                reader.store.set_string("speech-server", i > 0 ? module : "");
                reader.store.set_string("synthesizer", module);
                load_voices.begin(module);
            });
            synth_group.add_row(synth_row);
            voice_row = new SelectionRow(_("Voice"), {}, "");
            voice_row.selected.connect((item) => {
                if (syncing) return;
                int i = index_of(voice_labels(), item);
                if (i <= 0) {
                    reader.store.set_string("voice", "");
                    reader.store.set_string("voice-lang", "");
                    reader.store.set_string("voice-variant", "");
                } else {
                    var v = voice_list[i - 1];
                    reader.store.set_string("voice", v.name);
                    reader.store.set_string("voice-lang", v.language);
                    reader.store.set_string("voice-variant", v.variant == "none" ? "" : v.variant);
                }
                update_voice_link();
            });
            synth_group.add_row(voice_row);
            page.add_group(synth_group);

            var sound_group = new PreferencesGroup(_("Speech"));
            rate_scale = slider(sound_group, _("Rate"), _("How fast Orca speaks"), 0, 100, 1, "%.0f");
            pitch_scale = slider(sound_group, _("Pitch"), _("How high the voice sounds"), 0, 10, 0.1, "%.1f");
            volume_scale = slider(sound_group, _("Volume"), _("How loud the voice is"), 0, 10, 0.1, "%.1f");
            page.add_group(sound_group);

            page.map.connect(() => load_modules.begin());
            return page;
        }

        private Scale slider(PreferencesGroup group, string title, string subtitle, double min, double max, double step, string format) {
            var row = new ActionRow(title, subtitle);
            row.activatable = false;
            var scale = new Scale.with_range(Orientation.HORIZONTAL, min, max, step);
            scale.width_request = 150;
            scale.draw_value = true;
            scale.value_pos = PositionType.RIGHT;
            scale.set_format_value_func((s, value) => format.printf(value));
            scale.value_changed.connect(schedule_voice_write);
            row.add_suffix(scale);
            group.add_row(row);
            return scale;
        }

        private void schedule_voice_write() {
            if (syncing) return;
            if (write_id != 0) Source.remove(write_id);
            write_id = Timeout.add(250, () => {
                write_id = 0;
                var store = reader.store;
                int rate = (int) Math.round(rate_scale.get_value());
                if (store.get_int("rate") != rate) store.set_int("rate", rate);
                double pitch = Math.round(pitch_scale.get_value() * 10) / 10.0;
                if ((store.get_double("pitch") - pitch).abs() > 0.001) store.set_double("pitch", pitch);
                double volume = Math.round(volume_scale.get_value() * 10) / 10.0;
                if ((store.get_double("volume") - volume).abs() > 0.001) store.set_double("volume", volume);
                return Source.REMOVE;
            });
        }

        private string[] modules_labels() {
            string[] labels = { _("Default") };
            foreach (unowned string m in modules) labels += m;
            return labels;
        }

        private string[] voice_labels() {
            string[] labels = { _("Default") };
            foreach (var v in voice_list) labels += "%s (%s)".printf(v.name, v.language);
            return labels;
        }

        private async void load_modules() {
            modules = yield voices.list_modules();
            bool has = modules.length > 0;
            synth_row.visible = has;
            voice_row.visible = has;
            synth_group.description = has ? ""
                : _("Install Speech Dispatcher with at least one synthesizer to choose a voice.");
            syncing = true;
            synth_row.set_items(modules_labels());
            string current = reader.store.get_string("synthesizer");
            synth_row.current_value = current != "" ? current : _("Default");
            syncing = false;
            if (has) yield load_voices(current);
        }

        private async void load_voices(string module) {
            voice_list = yield voices.list_voices(module);
            syncing = true;
            voice_row.set_items(voice_labels());
            string name = reader.store.get_string("voice");
            string label = _("Default");
            foreach (var v in voice_list) {
                if (v.name == name) label = "%s (%s)".printf(v.name, v.language);
            }
            voice_row.current_value = label;
            syncing = false;
        }

        private void update_voice_link() {
            if (voice_link == null) return;
            string synth = reader.store.get_string("synthesizer");
            string name = reader.store.get_string("voice");
            string synth_label = synth != "" ? synth : _("Default synthesizer");
            voice_link.subtitle = name != "" ? "%s, %s".printf(synth_label, name) : synth_label;
        }

        private void sync_from_store() {
            var store = reader.store;
            if (store == null) return;
            syncing = true;
            verbosity_row.current_value = verbosity_labels[index_of(ScreenReaderSettings.VERBOSITY_LEVELS, store.get_string("verbosity"))];
            punctuation_row.current_value = punctuation_labels[index_of(ScreenReaderSettings.PUNCTUATION_LEVELS, store.get_string("punctuation"))];
            key_echo_row.active = store.get_bool("key-echo");
            character_echo_row.active = store.get_bool("character-echo");
            word_echo_row.active = store.get_bool("word-echo");
            layout_row.current_value = layout_labels[index_of(ScreenReaderSettings.KEYBOARD_LAYOUTS, store.get_string("keyboard-layout"))];
            modifier_row.current_value = modifier_labels[index_of(MODIFIER_IDS, reader.modifier_choice())];
            if (write_id == 0) {
                rate_scale.set_value(store.get_int("rate"));
                pitch_scale.set_value(store.get_double("pitch"));
                volume_scale.set_value(store.get_double("volume"));
            }
            syncing = false;
            update_voice_link();
        }

        private static int index_of(string[] values, string value) {
            for (int i = 0; i < values.length; i++) if (values[i] == value) return i;
            return 0;
        }
    }
}
