using Gtk;
using Singularity.Widgets;
using Singularity.TextRecognition;

namespace Singularity.SidebarPages {

    public class TextRecognitionPage : SettingsPage {
        private Recognizer recognizer;
        private PreferencesGroup languages_group;
        private bool syncing = false;
        private Gee.HashMap<string, SwitchRow> rows = new Gee.HashMap<string, SwitchRow>();

        public TextRecognitionPage(SettingsView view) {
            base(_("Text Recognition"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("region"));
            recognizer = Recognizer.get_default();

            if (!recognizer.available) {
                var missing = new StatusPage();
                missing.icon_name = "singularity-text-recognition";
                missing.title = _("No Text Recognition Engine");
                missing.description = recognizer.install_hint;
                add_widget(missing);
                return;
            }

            var engine_group = new PreferencesGroup(_("Engine"),
                _("Text in images can be selected and copied in Markup, Photos and Quick Look."));
            engine_group.add_row(new ActionRow(recognizer.engine.name, _("Runs on this computer"), "singularity-live-text-symbolic"));
            add_group(engine_group);

            languages_group = new PreferencesGroup(_("Languages"),
                _("Text is read in the languages turned on here. With none turned on, the system language is used."));
            add_group(languages_group);
            recognizer.languages_changed.connect(sync_rows);
            load_languages.begin();
        }

        private async void load_languages() {
            string[] installed = yield recognizer.installed_languages();
            languages_group.clear();
            rows.clear();
            if (installed.length == 0) {
                languages_group.add_row(new ActionRow(_("No languages installed"), _("Install language data for the text recognition engine")));
                return;
            }
            var sorted = new Gee.ArrayList<string>();
            foreach (var code in installed) sorted.add(code);
            sorted.sort((a, b) => Languages.display_name(a).collate(Languages.display_name(b)));
            foreach (var code in sorted) {
                var row = new SwitchRow(Languages.display_name(code), code);
                row.switch_btn.notify["active"].connect(() => {
                    if (syncing) return;
                    save();
                });
                rows[code] = row;
                languages_group.add_row(row);
            }
            sync_rows();
        }

        private void sync_rows() {
            syncing = true;
            string[] chosen = recognizer.chosen_languages();
            foreach (var entry in rows.entries) entry.value.active = entry.key in chosen;
            syncing = false;
        }

        private void save() {
            string[] chosen = {};
            foreach (var entry in rows.entries) {
                if (entry.value.active) chosen += entry.key;
            }
            recognizer.set_chosen_languages(chosen);
        }
    }
}
