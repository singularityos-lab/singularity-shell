using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class RegionPage : SettingsPage {
        private LocaleManager manager;
        private ExpanderRow language_row;
        private ExpanderRow formats_row;
        private Label language_label;
        private Label formats_label;
        private List<string> all_locales;
        private SettingsView view;

        public RegionPage(SettingsView view) {
            base(_("Region & Language"));
            this.view = view;
            back_clicked.connect(() => {
                view.go_home();
            });
            manager = SystemMonitor.get_default().locale;
            manager.state_changed.connect(update_ui);
            load_locales();
            build_ui();
            update_ui();
        }

        private void load_locales() {

            new Thread<void>("load-locales", () => {
                var locales = manager.get_available_locales();
                locales.sort(string.collate);
                Idle.add(() => {
                    all_locales = (owned) locales;
                    return false;
                });
            });
        }

        private void build_ui() {
            var group = new PreferencesGroup(_("Language"));
            language_row = new SearchableExpanderRow(_("Language"));
            language_label = new Label("");
            language_label.add_css_class("dim-label");
            language_row.add_suffix(language_label);
            setup_expander((SearchableExpanderRow)language_row, true);
            group.add_row(language_row);
            add_group(group);
            var formats_group = new PreferencesGroup(_("Formats"));
            formats_row = new SearchableExpanderRow(_("Formats"));
            formats_label = new Label("");
            formats_label.add_css_class("dim-label");
            formats_row.add_suffix(formats_label);
            setup_expander((SearchableExpanderRow)formats_row, false);
            formats_group.add_row(formats_row);
            add_group(formats_group);
            var note_box = new Box(Orientation.HORIZONTAL, 12);
            note_box.margin_top = 12;
            note_box.margin_bottom = 12;
            note_box.margin_start = 12;
            note_box.margin_end = 12;
            var icon = new Image.from_icon_name("dialog-information-symbolic");
            note_box.append(icon);
            var lbl = new Label(_("Changes will take effect on next login."));
            lbl.wrap = true;
            lbl.xalign = 0;
            note_box.append(lbl);
            add_widget(note_box);
            var recognition_group = new PreferencesGroup(_("Text in Images"));
            var recognition_row = new ActionRow(_("Text Recognition"), _("Languages used to read text in images"), "singularity-live-text-symbolic");
            recognition_row.activatable = true;
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            chevron.add_css_class("dim-label");
            chevron.valign = Align.CENTER;
            recognition_row.add_suffix(chevron);
            recognition_row.activated.connect(() => {
                view.open_subpage(new TextRecognitionPage(view), "text-recognition");
            });
            recognition_group.add_row(recognition_row);
            add_group(recognition_group);
        }

        private void setup_expander(SearchableExpanderRow row, bool is_language) {
            row.search_entry.placeholder_text = _("Search locale...");
            row.search_entry.search_changed.connect((entry) => {
                populate_list(row.list_box, entry.text, is_language, row);
            });
            row.notify["expanded"].connect(() => {
                if (row.expanded) {
                    if (is_language && formats_row.expanded) formats_row.expanded = false;
                    if (!is_language && language_row.expanded) language_row.expanded = false;
                    populate_list(row.list_box, row.search_entry.text, is_language, row);
                }
            });
        }

        private void populate_list(ListBox list_box, string query, bool is_language, ExpanderRow row) {
            Widget child = list_box.get_first_child();
            while (child != null) {
                list_box.remove(child);
                child = list_box.get_first_child();
            }
            if (all_locales == null) return;
            string q = query.down();
            int count = 0;
            foreach (string loc in all_locales) {
                if (q == "" || loc.down().contains(q)) {
                    var item_row = new ActionRow(loc);
                    item_row.activatable = true;
                    string current = is_language ? manager.get_lang_value() : manager.get_formats_value();
                    if (loc == current) {
                        item_row.add_suffix(new Image.from_icon_name("object-select-symbolic"));
                    }
                    var gesture = new GestureClick();
                    gesture.released.connect(() => {
                        apply_locale(loc, is_language);
                        row.expanded = false;
                    });
                    item_row.add_controller(gesture);
                    list_box.append(item_row);
                    count++;
                    if (count > 50) break;
                }
            }
        }

        private void apply_locale(string loc, bool is_language) {
            if (is_language) {
                manager.update_locale({"LANG=" + loc});
            } else {
                string[] envs = {
                    "LC_TIME=" + loc,
                    "LC_NUMERIC=" + loc,
                    "LC_MONETARY=" + loc,
                    "LC_MEASUREMENT=" + loc,
                    "LC_PAPER=" + loc,
                    "LC_NAME=" + loc,
                    "LC_ADDRESS=" + loc,
                    "LC_TELEPHONE=" + loc,
                    "LC_IDENTIFICATION=" + loc
                };
                manager.update_locale(envs);
            }
        }

        private void update_ui() {
            language_label.label = manager.get_lang_value();
            formats_label.label = manager.get_formats_value();
        }
    }
}
