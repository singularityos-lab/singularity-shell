using Gtk;
using Singularity.Widgets;
using Singularity.Dictation;

namespace Singularity.SidebarPages {

    public class DictationPage : SettingsPage {
        private GLib.Settings settings;
        private SettingsView view;
        private WelcomePage welcome;
        private PreferencesGroup engine_group;
        private PreferencesGroup models_group;
        private PreferencesGroup recognition_group;
        private ActionRow engine_row;
        private ulong[] handlers = {};

        public static ActionRow entry_row(SettingsView view) {
            var settings = new GLib.Settings("dev.sinty.desktop");
            var row = new ActionRow(_("Dictation"), status(settings), "audio-input-microphone-symbolic");
            row.activatable = true;
            row.add_suffix(NotificationSettingsPage.chevron());
            row.activated.connect(() => view.open_subpage(new DictationPage(view), "dictation"));
            ulong h = settings.changed["dictation-enabled"].connect(() => row.subtitle = status(settings));
            row.destroy.connect(() => settings.disconnect(h));
            return row;
        }

        private static string status(GLib.Settings settings) {
            if (!settings.get_boolean("dictation-enabled")) return _("Off");
            return _("Press Super+H in any text field");
        }

        public static string size_label(int64 bytes) {
            return GLib.format_size((uint64) bytes);
        }

        public static string model_language(string code) {
            if (code == "multilingual") return _("Many languages");
            return InputMethodsPage.language_name(code);
        }

        public DictationPage(SettingsView view) {
            base(_("Dictation"));
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("keyboard"));
            settings = new GLib.Settings("dev.sinty.desktop");

            var general = new PreferencesGroup(_("Shortcut"),
                _("Speak in any text field. Speech is recognized on this computer and never leaves it."));
            var enabled = new SwitchRow(_("Dictation Shortcut"), _("Press Super+H in a text field to start and stop, Esc cancels"));
            settings.bind("dictation-enabled", enabled.switch_btn, "active", SettingsBindFlags.DEFAULT);
            general.add_row(enabled);
            add_group(general);

            welcome = new WelcomePage();
            welcome.is_section = true;
            welcome.embedded = true;
            welcome.compact = true;
            welcome.app_icon_name = "singularity-dictation";
            welcome.title = _("Get a Speech Model");
            welcome.subtitle = _("Dictation needs a speech model on this computer. Small models are quick, larger ones are more accurate.");
            welcome.add_action("singularity-dictation", _("Download a Speech Model"),
                _("Pick a language and a size"), open_models);
            add_widget(welcome);

            engine_group = new PreferencesGroup(_("Speech Engine"));
            engine_row = new ActionRow(_("Engine"), "", "system-run-symbolic");
            engine_group.add_row(engine_row);
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            string[] ids = { "auto", "whisper", "vosk", "command" };
            string[] names = { _("Automatic"), "whisper.cpp", "Vosk", _("Custom Program") };
            for (int i = 0; i < ids.length; i++) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = ids[i];
                o.label = names[i];
                options.add(o);
            }
            var choice = new SelectionRow.with_options(_("Use"), options, settings.get_string("dictation-engine"));
            choice.selected.connect((id) => settings.set_string("dictation-engine", id));
            engine_group.add_row(choice);
            add_group(engine_group);

            models_group = new PreferencesGroup(_("Speech Models"));
            add_group(models_group);

            recognition_group = new PreferencesGroup(_("Recognition"),
                _("Say comma, period, question mark, new line or new paragraph. In Italian say virgola, punto, punto interrogativo, a capo or nuovo paragrafo."));
            var languages = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            string[] codes = { "auto", "en", "it", "de", "fr", "es", "pt", "nl", "zh", "ja", "ko" };
            foreach (string code in codes) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = code;
                o.label = code == "auto" ? _("Detect Automatically") : InputMethodsPage.language_name(code);
                languages.add(o);
            }
            var language = new SelectionRow.with_options(_("Language"), languages, settings.get_string("dictation-language"));
            language.selected.connect((id) => settings.set_string("dictation-language", id));
            recognition_group.add_row(language);
            var punctuation = new SwitchRow(_("Automatic Punctuation"),
                _("Add periods and commas where you pause. Spoken commands always work."));
            settings.bind("dictation-auto-punctuation", punctuation.switch_btn, "active", SettingsBindFlags.DEFAULT);
            recognition_group.add_row(punctuation);
            var auto_stop = new SwitchRow(_("Stop When Silent"), _("Finish after a pause in speech"));
            settings.bind("dictation-auto-stop", auto_stop.switch_btn, "active", SettingsBindFlags.DEFAULT);
            recognition_group.add_row(auto_stop);
            var pause = new SpinRow(_("Pause Before Stopping"), _("Seconds of silence"), 1, 30, 1,
                settings.get_uint("dictation-silence-seconds"));
            pause.spin_btn.value_changed.connect(() => settings.set_uint("dictation-silence-seconds", (uint) pause.spin_btn.value));
            settings.bind("dictation-auto-stop", pause, "sensitive", SettingsBindFlags.GET);
            recognition_group.add_row(pause);
            add_group(recognition_group);

            handlers += settings.changed["dictation-engine"].connect(refresh);
            handlers += settings.changed["dictation-model"].connect(refresh);
            refresh();
        }

        public override void dispose() {
            foreach (ulong id in handlers) settings.disconnect(id);
            handlers = {};
            base.dispose();
        }

        private void open_models() {
            view.open_subpage(new DictationModelsPage(view), "dictation-models");
        }

        private void refresh() {
            var installed = ModelCatalog.installed();
            string reason;
            var engine = EngineLocator.create(settings, out reason);
            string? whisper = EngineLocator.whisper_binary();
            string? vosk = EngineLocator.vosk_helper();
            if (engine != null) {
                engine_row.subtitle = _("Ready, using %s").printf(engine.id == "whisper" ? "whisper.cpp"
                    : engine.id == "vosk" ? "Vosk" : _("a custom program"));
            } else {
                engine_row.subtitle = reason;
            }
            bool any_engine = whisper != null || vosk != null || settings.get_string("dictation-command").strip() != "";
            welcome.visible = installed.length == 0 && any_engine;
            models_group.visible = installed.length > 0 || !any_engine;
            models_group.clear();
            if (!any_engine) {
                models_group.add_row(new ActionRow(_("No Speech Engine Installed"),
                    _("Install whisper.cpp or Vosk with your software manager to dictate."),
                    "dialog-information-symbolic"));
                return;
            }
            string preferred = settings.get_string("dictation-model");
            var chosen = EngineLocator.pick_model(settings.get_string("dictation-engine") == "vosk" ? "vosk"
                : settings.get_string("dictation-engine") == "whisper" ? "whisper" : "", preferred);
            var catalog = ModelCatalog.load();
            foreach (var model in installed) {
                string engine_name = model.engine == "whisper" ? "whisper.cpp" : "Vosk";
                string title = model.name;
                string subtitle = engine_name;
                foreach (var info in catalog) {
                    if (Path.get_basename(model.path) != info.file) continue;
                    title = info.name;
                    subtitle = "%s, %s".printf(engine_name, model_language(info.language));
                }
                var row = new ActionRow(title, subtitle);
                bool active = chosen != null && chosen.path == model.path;
                if (active) {
                    var check = new Image.from_icon_name("object-select-symbolic");
                    check.valign = Align.CENTER;
                    check.tooltip_text = _("In Use");
                    row.add_suffix(check);
                } else {
                    row.activatable = true;
                    string path = model.path;
                    row.activated.connect(() => settings.set_string("dictation-model", path));
                }
                if (model.removable) {
                    var remove = new Button.from_icon_name("user-trash-symbolic");
                    remove.add_css_class("flat");
                    remove.add_css_class("destructive-action");
                    remove.valign = Align.CENTER;
                    remove.tooltip_text = _("Remove Model");
                    remove.clicked.connect(() => row.confirmation_requested(_("Remove"), _("Cancel"),
                        ConfirmationSuggestedAction.CANCEL));
                    var target = model;
                    row.confirmed.connect(() => {
                        try {
                            ModelDownloader.remove(target);
                        } catch (Error e) {
                            warning("Dictation: cannot remove %s: %s", target.path, e.message);
                        }
                        refresh();
                    });
                    row.add_suffix(remove);
                }
                models_group.add_row(row);
            }
            var more = new ActionRow(_("Download Models"), _("More languages and sizes"), "folder-download-symbolic");
            more.activatable = true;
            more.add_suffix(NotificationSettingsPage.chevron());
            more.activated.connect(open_models);
            models_group.add_row(more);
        }
    }

    public class DictationModelsPage : SettingsPage {
        private SettingsView view;
        private Box groups_box;
        private Gee.HashMap<string, ModelDownloader> downloads = new Gee.HashMap<string, ModelDownloader>();
        private Gee.HashMap<string, Label> progress_labels = new Gee.HashMap<string, Label>();
        private Gee.HashMap<string, int> percents = new Gee.HashMap<string, int>();

        public DictationModelsPage(SettingsView view) {
            base(_("Speech Models"));
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new DictationPage(view), "dictation"));
            groups_box = new Box(Orientation.VERTICAL, 0);
            add_widget(groups_box);
            build();
        }

        public override void dispose() {
            foreach (var downloader in downloads.values) downloader.cancel();
            downloads.clear();
            base.dispose();
        }

        private bool installed(ModelInfo info) {
            return FileUtils.test(info.install_path(), FileTest.EXISTS);
        }

        private void build() {
            for (var child = groups_box.get_first_child(); child != null; ) {
                var next = child.get_next_sibling();
                groups_box.remove(child);
                child = next;
            }
            var catalog = ModelCatalog.load();
            if (catalog.length == 0) {
                var empty = new StatusPage();
                empty.icon_name = "singularity-dictation";
                empty.title = _("No Model List");
                empty.description = _("This system does not provide a list of speech models to download.");
                groups_box.append(empty);
                return;
            }
            bool whisper = EngineLocator.whisper_binary() != null;
            bool vosk = EngineLocator.vosk_helper() != null;
            string[] engines = { "whisper", "vosk" };
            foreach (string engine in engines) {
                bool usable = engine == "whisper" ? whisper : vosk;
                string title = engine == "whisper" ? "whisper.cpp" : "Vosk";
                string description = engine == "whisper"
                    ? _("Accurate, with punctuation. Larger models need a faster computer.")
                    : _("Light and fast, shows words while you speak.");
                if (!usable) description = _("Install %s to use these models.").printf(title);
                var group = new PreferencesGroup(title, description);
                bool any = false;
                foreach (var info in catalog) {
                    if (info.engine != engine) continue;
                    any = true;
                    group.add_row(model_row(info, usable));
                }
                if (any) groups_box.append(group);
            }
            var source = new PreferencesGroup(_("Where Models Come From"),
                _("Models are downloaded from their upstream projects and checked against a known checksum before use."));
            groups_box.append(source);
        }

        private ActionRow model_row(ModelInfo info, bool usable) {
            var row = new ActionRow(info.name, "%s, %s".printf(DictationPage.model_language(info.language),
                DictationPage.size_label(info.size)));
            if (installed(info)) {
                var check = new Image.from_icon_name("object-select-symbolic");
                check.valign = Align.CENTER;
                check.tooltip_text = _("Installed");
                row.add_suffix(check);
                return row;
            }
            var button = new Button.with_label(_("Download"));
            button.valign = Align.CENTER;
            button.sensitive = usable;
            var progress = new Label("");
            progress.add_css_class("dim-label");
            progress.add_css_class("numeric");
            progress.visible = false;
            row.add_suffix(progress);
            row.add_suffix(button);
            if (downloads.has_key(info.id)) {
                button.label = _("Cancel");
                progress.visible = true;
                progress.label = "%d%%".printf(percents.has_key(info.id) ? percents[info.id] : 0);
                progress_labels[info.id] = progress;
            }
            button.clicked.connect(() => start_download(info, row, button, progress));
            return row;
        }

        private void start_download(ModelInfo info, ActionRow row, Button button, Label progress) {
            if (downloads.has_key(info.id)) {
                downloads[info.id].cancel();
                return;
            }
            var downloader = new ModelDownloader();
            downloads[info.id] = downloader;
            progress_labels[info.id] = progress;
            button.label = _("Cancel");
            progress.visible = true;
            progress.label = "0%";
            string id = info.id;
            downloader.progress.connect((fraction) => {
                percents[id] = (int) (fraction * 100);
                if (progress_labels.has_key(id)) progress_labels[id].label = "%d%%".printf(percents[id]);
            });
            downloader.download.begin(info, (obj, res) => {
                downloads.unset(info.id);
                progress_labels.unset(info.id);
                percents.unset(info.id);
                try {
                    downloader.download.end(res);
                    var settings = new GLib.Settings("dev.sinty.desktop");
                    if (settings.get_string("dictation-model") == "") settings.set_string("dictation-model", info.install_path());
                    build();
                } catch (Error e) {
                    progress.visible = false;
                    button.label = _("Download");
                    if (!(e is IOError.CANCELLED)) row.subtitle = _("Download failed: %s").printf(e.message);
                }
            });
        }
    }
}
