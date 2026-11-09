using Gtk;
using Singularity.Widgets;
using Singularity.InputMethods;

namespace Singularity.SidebarPages {

    internal Gee.ArrayList<Singularity.Core.AppSettingOption> input_options(string[] ids, string[] labels) {
        var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
        for (int i = 0; i < ids.length; i++) {
            var o = new Singularity.Core.AppSettingOption();
            o.id = ids[i];
            o.label = labels[i];
            options.add(o);
        }
        return options;
    }

    internal Label input_error_label() {
        var label = new Label("");
        label.wrap = true;
        label.xalign = 0;
        label.margin_start = 12;
        label.margin_end = 12;
        label.add_css_class("error");
        label.visible = false;
        return label;
    }

    internal void show_input_error(Label label, Error e) {
        label.label = SintyInputSettings.message(e);
        label.visible = true;
    }

    public class InputMethodOptionsPage : SettingsPage {
        private SettingsView view;
        private EngineInfo info;
        private Label error;

        public InputMethodOptionsPage(SettingsView view, EngineInfo info) {
            base(info.label);
            this.view = view;
            this.info = info;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new InputMethodsPage(view), "input-methods"));
            error = input_error_label();
            add_widget(error);
            load.begin();
        }

        public static void open(SettingsView view, EngineInfo info) {
            view.open_subpage(new InputMethodOptionsPage(view, info), "input-method-options");
        }

        private static string conversion_label(string id) {
            switch (id) {
                case "simplified": return _("Simplified Chinese");
                case "traditional": return _("Traditional Chinese");
                case "taiwan": return _("Traditional Chinese, Taiwan");
                case "hongkong": return _("Traditional Chinese, Hong Kong");
            }
            return _("As in the Dictionary");
        }

        private async void load() {
            SintyMethod? m = null;
            var titles = new Gee.HashMap<string, string>();
            try {
                m = yield SintyInputSettings.method(info.name);
                foreach (var d in yield SintyInputSettings.dictionaries()) titles[d.name] = d.title != "" ? d.title : d.name;
            } catch (Error e) {
                show_input_error(error, e);
            }
            if (m == null) {
                var missing = new StatusPage();
                missing.icon_name = "singularity-input-methods";
                missing.title = _("Input Method Not Running");
                missing.description = _("Its options appear here once the Sinty input service is running.");
                add_widget(missing);
                return;
            }
            build(m, titles);
        }

        private void set_option(string key, Variant value) {
            SintyInputSettings.configure.begin(info.name, key, value, (o, r) => {
                try {
                    SintyInputSettings.configure.end(r);
                    error.visible = false;
                } catch (Error e) {
                    show_input_error(error, e);
                }
            });
        }

        private void build(SintyMethod m, Gee.Map<string, string> titles) {
            var characters = new PreferencesGroup(_("Characters"));
            int rows = 0;
            if (m.conversions.length > 0) {
                string[] labels = {};
                foreach (string id in m.conversions) labels += conversion_label(id);
                var conversion = new SelectionRow.with_options(_("Write In"), input_options(m.conversions, labels), m.conversion);
                conversion.subtitle = _("Characters are converted as you type");
                conversion.selected.connect((id) => set_option("conversion", new Variant.string(id)));
                characters.add_row(conversion);
                rows++;
            }
            if (m.dictionaries.length > 1) {
                string[] labels = {};
                foreach (string id in m.dictionaries) labels += titles.has_key(id) ? titles[id] : id;
                var dictionary = new SelectionRow.with_options(_("Dictionary"), input_options(m.dictionaries, labels), m.dictionary);
                dictionary.subtitle = _("Which codes produce which characters");
                dictionary.selected.connect((id) => set_option("dictionary", new Variant.string(id)));
                characters.add_row(dictionary);
                rows++;
            }
            if (m.configurable) {
                var wide = new SwitchRow(_("Full-Width Punctuation"), _("Type ，。？ instead of , . ?"));
                wide.switch_btn.active = m.fullwidth;
                wide.switch_btn.notify["active"].connect(() => set_option("fullwidth", new Variant.boolean(wide.switch_btn.active)));
                characters.add_row(wide);
                rows++;
            }
            if (rows > 0) add_group(characters);

            if (m.configurable) {
                var learning = new PreferencesGroup(_("Learning"),
                    _("What is learned stays on this computer."));
                var learn = new SwitchRow(_("Learn From What You Type"),
                    _("New phrases and the candidates you pick often come first"));
                learn.switch_btn.active = m.learn;
                learn.switch_btn.notify["active"].connect(() => set_option("learn", new Variant.boolean(learn.switch_btn.active)));
                learning.add_row(learn);
                var phrases = new ActionRow(_("Learned Phrases"), m.learned == 0 ? _("None yet")
                    : ngettext("%u phrase", "%u phrases", m.learned).printf(m.learned));
                phrases.activatable = true;
                phrases.add_suffix(NotificationSettingsPage.chevron());
                phrases.activated.connect(() => view.open_subpage(new LearnedPhrasesPage(view, info), "input-method-phrases"));
                learning.add_row(phrases);
                add_group(learning);
            }

            if (info.name.has_prefix("table-")) {
                var mine = new PreferencesGroup();
                var remove = new ActionRow(_("Remove This Table"), _("Deletes the table you imported"));
                var button = row_button(_("Remove"), false);
                button.add_css_class("destructive-action");
                button.clicked.connect(() => remove.confirmation_requested(_("Remove"), _("Cancel"),
                    ConfirmationSuggestedAction.CANCEL));
                remove.confirmed.connect(() => remove_table.begin());
                remove.add_suffix(button);
                mine.add_row(remove);
                add_group(mine);
            }
        }

        private async void remove_table() {
            try {
                yield SintyInputSettings.remove_table(info.name.substring("table-".length));
            } catch (Error e) {
                show_input_error(error, e);
                return;
            }
            var sources = InputSources.get_default();
            sources.remove(info.id);
            sources.reload();
            view.open_subpage(new InputMethodsPage(view), "input-methods");
        }
    }

    public class LearnedPhrasesPage : SettingsPage {
        private SettingsView view;
        private EngineInfo info;
        private PreferencesGroup list;
        private EntryRow phrase_row;
        private EntryRow code_row;
        private Label error;

        public LearnedPhrasesPage(SettingsView view, EngineInfo info) {
            base(_("Learned Phrases"));
            this.view = view;
            this.info = info;
            back_btn.visible = true;
            back_clicked.connect(() => InputMethodOptionsPage.open(view, info));
            error = input_error_label();
            add_widget(error);

            list = new PreferencesGroup(info.label);
            add_group(list);

            var add = new PreferencesGroup(_("Add a Phrase"));
            phrase_row = new EntryRow(_("Phrase"));
            code_row = new EntryRow(_("Typed As"));
            add.add_row(phrase_row);
            add.add_row(code_row);
            var add_row = new ActionRow(_("Comes First When You Type It"), null);
            var add_button = row_button(_("Add"), true);
            add_button.clicked.connect(() => add_phrase.begin());
            code_row.entry_activated.connect(() => add_phrase.begin());
            add_row.add_suffix(add_button);
            add.add_row(add_row);
            add_group(add);

            var copy = new PreferencesGroup(_("Keep a Copy"),
                _("Move what %s has learned to another computer.").printf(info.label));
            var export_row = new ActionRow(_("Export"), _("Save the phrases to a file"));
            var export_button = row_button(_("Export…"), false);
            export_button.clicked.connect(() => export_phrases());
            export_row.add_suffix(export_button);
            copy.add_row(export_row);
            var import_row = new ActionRow(_("Import"), _("Add phrases from an exported file"));
            var import_button = row_button(_("Import…"), false);
            import_button.clicked.connect(() => import_phrases());
            import_row.add_suffix(import_button);
            copy.add_row(import_row);
            var forget = new ActionRow(_("Forget Everything"), _("Removes every learned phrase and frequency"));
            var forget_button = row_button(_("Forget"), false);
            forget_button.add_css_class("destructive-action");
            forget_button.clicked.connect(() => forget.confirmation_requested(_("Forget"), _("Cancel"),
                ConfirmationSuggestedAction.CANCEL));
            forget.confirmed.connect(() => clear.begin());
            forget.add_suffix(forget_button);
            copy.add_row(forget);
            add_group(copy);

            refresh.begin();
        }

        private async void refresh() {
            Gee.List<SintyPhrase> phrases;
            try {
                phrases = yield SintyInputSettings.phrases(info.name);
            } catch (Error e) {
                show_input_error(error, e);
                return;
            }
            list.clear();
            if (phrases.size == 0) {
                list.add_row(new ActionRow(_("Nothing Learned Yet"),
                    _("Phrases you type and pick appear here."), "input-keyboard-symbolic"));
                return;
            }
            phrases.sort((a, b) => b.weight - a.weight);
            foreach (var p in phrases) list.add_row(phrase(p));
        }

        private ActionRow phrase(SintyPhrase p) {
            var row = new ActionRow(p.text, p.code);
            var remove = new Button.from_icon_name("user-trash-symbolic");
            remove.add_css_class("flat");
            remove.valign = Align.CENTER;
            remove.tooltip_text = _("Forget Phrase");
            remove.clicked.connect(() => {
                SintyInputSettings.remove_phrase.begin(info.name, p.code, p.text, (o, r) => {
                    try {
                        SintyInputSettings.remove_phrase.end(r);
                    } catch (Error e) {
                        show_input_error(error, e);
                    }
                    refresh.begin();
                });
            });
            row.add_suffix(remove);
            return row;
        }

        private async void add_phrase() {
            string text = phrase_row.text.strip();
            string code = code_row.text.strip().down();
            if (text == "" || code == "") return;
            try {
                yield SintyInputSettings.add_phrase(info.name, code, text);
                error.visible = false;
            } catch (Error e) {
                show_input_error(error, e);
                return;
            }
            phrase_row.text = "";
            code_row.text = "";
            yield refresh();
        }

        private async void clear() {
            try {
                yield SintyInputSettings.clear_phrases(info.name);
            } catch (Error e) {
                show_input_error(error, e);
            }
            yield refresh();
        }

        private void export_phrases() {
            var dialog = new FileDialog();
            dialog.title = _("Export Learned Phrases");
            dialog.initial_name = "%s.sdict".printf(info.name);
            SidebarWait.save_file.begin(this, dialog, null, (o, r) => {
                try {
                    var file = SidebarWait.save_file.end(r);
                    string? path = file.get_path();
                    if (path == null) return;
                    if (!path.has_suffix(".sdict") && !path.has_suffix(".sdict.gz")) path += ".sdict";
                    SintyInputSettings.export_phrases.begin(info.name, path, (o2, r2) => {
                        try {
                            SintyInputSettings.export_phrases.end(r2);
                        } catch (Error e) {
                            show_input_error(error, e);
                        }
                    });
                } catch (Error e) {
                }
            });
        }

        private void import_phrases() {
            var dialog = new FileDialog();
            dialog.title = _("Import Learned Phrases");
            SidebarWait.choose_file.begin(this, dialog, null, (o, r) => {
                try {
                    var file = SidebarWait.choose_file.end(r);
                    if (file.get_path() == null) return;
                    SintyInputSettings.import_phrases.begin(info.name, file.get_path(), (o2, r2) => {
                        try {
                            SintyInputSettings.import_phrases.end(r2);
                            error.visible = false;
                        } catch (Error e) {
                            show_input_error(error, e);
                        }
                        refresh.begin();
                    });
                } catch (Error e) {
                }
            });
        }
    }

    public class AddInputTablePage : SettingsPage {
        private SettingsView view;
        private File? file = null;
        private ActionRow file_row;
        private EntryRow name_row;
        private string language = "zh-Hans";
        private string license = "LicenseRef-own";
        private Button import_button;
        private Label error;

        public AddInputTablePage(SettingsView view) {
            base(_("Import a Table"));
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new AddInputMethodPage(view), "add-input-method"));
            error = input_error_label();
            add_widget(error);

            var table = new PreferencesGroup(_("Table"),
                _("A table maps what you type to characters or phrases: Wubi, Cangjie and similar methods. Rime and fcitx tables work too."));
            file_row = new ActionRow(_("File"), _("No file chosen"));
            var choose = row_button(_("Choose…"), false);
            choose.clicked.connect(choose_file);
            file_row.add_suffix(choose);
            table.add_row(file_row);
            name_row = new EntryRow(_("Name"));
            name_row.entry_changed.connect(update);
            table.add_row(name_row);
            var languages = new SelectionRow.with_options(_("Language"), input_options(
                { "zh-Hans", "zh-Hant", "yue", "ja", "ko", "" },
                { _("Simplified Chinese"), _("Traditional Chinese"), _("Cantonese"), _("Japanese"), _("Korean"), _("Other") }),
                language);
            languages.selected.connect((id) => language = id);
            table.add_row(languages);
            add_group(table);

            var rights = new PreferencesGroup(_("Where It Comes From"),
                _("Only tables you made, or whose license allows copying, can be imported."));
            var licenses = new SelectionRow.with_options(_("License"), input_options(
                { "LicenseRef-own", "LicenseRef-public-domain", "CC0-1.0", "MIT", "BSD-3-Clause", "Apache-2.0",
                  "CC-BY-4.0", "CC-BY-SA-4.0", "GPL-2.0-or-later", "GPL-3.0-or-later", "LGPL-2.1-or-later", "LGPL-3.0-or-later" },
                { _("I Made It"), _("Public Domain"), "CC0 1.0", "MIT", "BSD 3-Clause", "Apache 2.0",
                  "CC BY 4.0", "CC BY-SA 4.0", "GPL 2.0 or Later", "GPL 3.0 or Later", "LGPL 2.1 or Later", "LGPL 3.0 or Later" }),
                license);
            licenses.selected.connect((id) => license = id);
            rights.add_row(licenses);
            var import_row = new ActionRow(_("Add as an Input Method"), null);
            import_button = row_button(_("Import"), true);
            import_button.sensitive = false;
            import_button.clicked.connect(() => import_table.begin());
            import_row.add_suffix(import_button);
            rights.add_row(import_row);
            add_group(rights);
        }

        private void update() {
            import_button.sensitive = file != null && name_row.text.strip() != "";
        }

        private void choose_file() {
            var dialog = new FileDialog();
            dialog.title = _("Choose a Table");
            SidebarWait.choose_file.begin(this, dialog, null, (o, r) => {
                try {
                    file = SidebarWait.choose_file.end(r);
                    file_row.subtitle = file.get_basename();
                    if (name_row.text.strip() == "") {
                        string name = file.get_basename();
                        foreach (string ext in new string[] { ".dict.yaml", ".sdict.gz", ".sdict", ".txt", ".mb" }) {
                            if (name.has_suffix(ext)) name = name.substring(0, name.length - ext.length);
                        }
                        name_row.text = name;
                    }
                    update();
                } catch (Error e) {
                }
            });
        }

        private async void import_table() {
            if (file == null || file.get_path() == null) return;
            import_button.sensitive = false;
            string name;
            try {
                name = yield SintyInputSettings.add_table(file.get_path(), name_row.text.strip(), language, license);
            } catch (Error e) {
                show_input_error(error, e);
                update();
                return;
            }
            var sources = InputSources.get_default();
            sources.reload();
            sources.add("sinty:" + name);
            view.open_subpage(new InputMethodsPage(view), "input-methods");
        }
    }
}
