using Gtk;
using Singularity.Widgets;
using Singularity.InputMethods;

namespace Singularity.SidebarPages {

    public class InputMethodsPage : SettingsPage {
        private SettingsView view;
        private InputSources sources;
        private WelcomePage welcome;
        private PreferencesGroup engines_group;
        private PreferencesGroup options_group;
        private ulong changed_id = 0;

        public static ActionRow entry_row(SettingsView view) {
            var sources = InputSources.get_default();
            var row = new ActionRow(_("Input Methods"), status(sources), "input-keyboard-symbolic");
            row.activatable = true;
            row.add_suffix(NotificationSettingsPage.chevron());
            row.activated.connect(() => view.open_subpage(new InputMethodsPage(view), "input-methods"));
            ulong h = sources.changed.connect(() => row.subtitle = status(sources));
            row.destroy.connect(() => sources.disconnect(h));
            return row;
        }

        private static string status(InputSources sources) {
            if (sources.installed_frameworks().length == 0) return _("Not available on this system");
            int count = sources.configured().length;
            if (count == 0) return _("Pinyin, Japanese, Hangul and more");
            return ngettext("%d input method", "%d input methods", count).printf(count);
        }

        public static string language_name(string code) {
            if (code == "") return _("Other Languages");
            string? tag = Singularity.TextRecognition.Languages.code_for_locale(code);
            return tag != null ? Singularity.TextRecognition.Languages.display_name(tag) : code;
        }

        public InputMethodsPage(SettingsView view) {
            base(_("Input Methods"));
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("keyboard"));
            sources = InputSources.get_default();

            if (sources.installed_frameworks().length == 0) {
                var missing = new StatusPage();
                missing.icon_name = "singularity-input-methods";
                missing.title = _("No Input Method Framework");
                missing.description = _("Install Fcitx 5 or IBus together with the engines for your languages, such as Pinyin, Mozc, Anthy or Hangul, then come back here.");
                add_widget(missing);
                return;
            }

            welcome = new WelcomePage();
            welcome.is_section = true;
            welcome.embedded = true;
            welcome.compact = true;
            welcome.app_icon_name = "singularity-input-methods";
            welcome.title = _("Input Methods");
            welcome.subtitle = _("Type Chinese, Japanese, Korean and other languages that need more than a keyboard layout. Candidates appear next to the text cursor.");
            welcome.add_action("singularity-input-methods", _("Add an Input Method"),
                _("Choose from the engines installed on this computer"), open_add);
            add_widget(welcome);

            engines_group = new PreferencesGroup(_("Your Input Methods"),
                _("Switch between them and the keyboard layout with the shortcut or from the panel."));
            add_group(engines_group);

            options_group = new PreferencesGroup(_("Switching"));
            var shortcut = find_shortcut("switch_input_method");
            var shortcut_row = new ActionRow(_("Switch Shortcut"), _("Change it in Keyboard Shortcuts"));
            var label = new ShortcutLabel(shortcut != null ? shortcut.accelerator : "");
            label.disabled_text = _("Disabled");
            label.valign = Align.CENTER;
            shortcut_row.add_suffix(label);
            shortcut_row.activatable = true;
            shortcut_row.activated.connect(() => view.navigate_to("keyboard"));
            options_group.add_row(shortcut_row);
            var indicator = new SwitchRow(_("Show in the Panel"),
                _("See the current input method and switch with a click"));
            sources.settings.bind("input-method-show-indicator", indicator.switch_btn, "active", SettingsBindFlags.DEFAULT);
            options_group.add_row(indicator);
            if (sources.installed_frameworks().length > 1 || sources.settings.get_string("input-method-framework") != "auto") {
                var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                string[] ids = { "auto", "fcitx5", "ibus" };
                string[] names = { _("Automatic"), "Fcitx 5", "IBus" };
                for (int i = 0; i < ids.length; i++) {
                    var o = new Singularity.Core.AppSettingOption();
                    o.id = ids[i];
                    o.label = names[i];
                    options.add(o);
                }
                var framework = new SelectionRow.with_options(_("Framework"), options,
                    sources.settings.get_string("input-method-framework"));
                framework.subtitle = _("Which installed framework provides the engines");
                framework.selected.connect((id) => sources.settings.set_string("input-method-framework", id));
                options_group.add_row(framework);
            }
            var x11 = new ActionRow(_("Apps for X11"),
                _("Older X11 apps type through the framework's own bridge, with its own candidate window."),
                "dialog-information-symbolic");
            options_group.add_row(x11);
            add_group(options_group);

            changed_id = sources.changed.connect(refresh);
            refresh();
        }

        public override void dispose() {
            if (changed_id != 0) {
                sources.disconnect(changed_id);
                changed_id = 0;
            }
            base.dispose();
        }

        private static Shortcut? find_shortcut(string action) {
            foreach (var s in SystemMonitor.get_default().shortcuts.shortcuts) {
                if (s.action_name == action) return s;
            }
            return null;
        }

        private void open_add() {
            view.open_subpage(new AddInputMethodPage(view), "add-input-method");
        }

        private void refresh() {
            string[] configured = sources.configured();
            welcome.visible = configured.length == 0;
            engines_group.visible = configured.length > 0;
            options_group.visible = configured.length > 0;
            engines_group.clear();
            foreach (string id in configured) {
                var info = sources.info_for(id);
                string title = info != null ? info.label : id;
                string subtitle = info != null
                    ? "%s, %s".printf(language_name(info.language), info.framework == "ibus" ? "IBus" : "Fcitx 5")
                    : _("No longer installed");
                var row = new ActionRow(title, subtitle);
                var symbol = new Label(info != null ? info.short_label() : "?");
                symbol.add_css_class("title-4");
                symbol.width_chars = 2;
                symbol.margin_end = 8;
                row.add_prefix(symbol);
                var remove = new Button.from_icon_name("user-trash-symbolic");
                remove.add_css_class("flat");
                remove.add_css_class("destructive-action");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Remove Input Method");
                remove.clicked.connect(() => row.confirmation_requested(_("Remove"), _("Cancel"),
                    ConfirmationSuggestedAction.CANCEL));
                string engine_id = id;
                row.confirmed.connect(() => sources.remove(engine_id));
                row.add_suffix(remove);
                engines_group.add_row(row);
            }
            var add_row = new ActionRow(_("Add Input Method"),
                _("Choose from the engines installed on this computer"), "list-add-symbolic");
            add_row.activatable = true;
            add_row.activated.connect(open_add);
            engines_group.add_row(add_row);
        }
    }

    public class AddInputMethodPage : SettingsPage {
        private Singularity.Widgets.SearchEntry search;
        private Box groups_box;
        private InputSources sources;

        public AddInputMethodPage(SettingsView view) {
            base(_("Add Input Method"));
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new InputMethodsPage(view), "input-methods"));
            sources = InputSources.get_default();

            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search languages and engines...");
            search.margin_start = 12;
            search.margin_end = 12;
            search.margin_bottom = 4;
            add_widget(search);
            groups_box = new Box(Orientation.VERTICAL, 0);
            add_widget(groups_box);
            search.search_changed.connect(() => build(view));
            build(view);
        }

        private void build(SettingsView view) {
            for (var child = groups_box.get_first_child(); child != null; ) {
                var next = child.get_next_sibling();
                groups_box.remove(child);
                child = next;
            }
            string query = search.text.strip().down();
            string[] configured = sources.configured();
            var by_language = new Gee.TreeMap<string, Gee.ArrayList<EngineInfo>>();
            foreach (var info in sources.available()) {
                if (info.id in configured) continue;
                string language = InputMethodsPage.language_name(info.language);
                if (query != "" && !(query in info.label.down()) && !(query in language.down())
                        && !(query in info.name.down())) continue;
                if (!by_language.has_key(language)) by_language[language] = new Gee.ArrayList<EngineInfo>();
                by_language[language].add(info);
            }
            if (by_language.size == 0) {
                var empty = new StatusPage();
                empty.icon_name = "singularity-input-methods";
                empty.title = query == "" ? _("Everything Is Added") : _("No Input Methods Found");
                empty.description = query == ""
                    ? _("Every installed engine is already in your list. Install more engines with your software manager.")
                    : _("Try another language or engine name.");
                groups_box.append(empty);
                return;
            }
            foreach (var entry in by_language.entries) {
                var group = new PreferencesGroup(entry.key);
                foreach (var info in entry.value) {
                    var row = new ActionRow(info.label, info.framework == "ibus" ? "IBus" : "Fcitx 5");
                    var symbol = new Label(info.short_label());
                    symbol.add_css_class("title-4");
                    symbol.width_chars = 2;
                    symbol.margin_end = 8;
                    row.add_prefix(symbol);
                    row.add_suffix(NotificationSettingsPage.chevron());
                    row.activatable = true;
                    string id = info.id;
                    row.activated.connect(() => {
                        sources.add(id);
                        view.open_subpage(new InputMethodsPage(view), "input-methods");
                    });
                    group.add_row(row);
                }
                groups_box.append(group);
            }
        }
    }
}
