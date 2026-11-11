using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AgentPage : SettingsPage {
        private const string[] PROVIDERS = { "local", "claude-code", "codex", "claude-api", "ollama" };
        private const string[] MODES = { "plan", "ask", "auto" };
        private SelectionRow provider_row;
        private EntryRow model_row;
        private EntryRow endpoint_row;
        private PasswordRow key_row;
        private SwitchRow enabled_row;
        private PreferencesGroup model_group;
        private PreferencesGroup behaviour_group;
        private bool loading = true;
        private uint key_timeout = 0;
        private string stored_key = "";

        private static string phones_summary() {
            string[] names = {};
            foreach (var d in NearbyClient.get_default().devices) {
                if (d.paired && d.has_plugin("sinty-ai")) names += d.name;
            }
            if (names.length == 0) return _("Turn on Sinty AI for a phone in Connected Devices");
            return string.joinv(", ", names);
        }

        public AgentPage(SettingsView view) {
            base(_("Sinty AI"));
            back_btn.visible = true;
            back_clicked.connect(() => view.go_home());

            var general = new PreferencesGroup(_("Sinty AI"),
                _("Off unless you turn it on. Without a model nothing on this computer uses AI."));
            enabled_row = new SwitchRow(_("Use AI"), _("Press Super+A to ask"));
            general.add_row(enabled_row);
            add_group(general);

            string provider, model, endpoint;
            AgentConfig.load(out provider, out model, out endpoint);
            enabled_row.switch_btn.active = AgentConfig.configured();

            model_group = new PreferencesGroup(_("Model"),
                _("Claude Code and Codex use your own login in their programs. Keys stay in the keyring."));
            provider_row = new SelectionRow(_("Provider"), PROVIDERS, provider != "" ? provider : PROVIDERS[0]);
            provider_row.selected.connect(() => {
                save();
                refresh_key_state.begin();
            });
            model_group.add_row(provider_row);
            model_row = new EntryRow(_("Model Name"));
            model_row.text = model;
            model_row.entry_changed.connect(save);
            model_group.add_row(model_row);
            endpoint_row = new EntryRow(_("Server Address"));
            endpoint_row.text = endpoint;
            endpoint_row.entry_changed.connect(save);
            model_group.add_row(endpoint_row);
            key_row = new PasswordRow(_("API Key"));
            key_row.entry_activated.connect(finish_key);
            key_row.entry_changed.connect(() => {
                if (key_timeout != 0) Source.remove(key_timeout);
                key_timeout = Timeout.add(800, () => {
                    key_timeout = 0;
                    store_key.begin();
                    return Source.REMOVE;
                });
            });
            var key_focus = new EventControllerFocus();
            key_focus.leave.connect(finish_key);
            key_row.add_controller(key_focus);
            model_group.add_row(key_row);
            refresh_key_state.begin();
            add_group(model_group);

            behaviour_group = new PreferencesGroup(_("Behaviour"), null);
            string[] mode_names = { _("Suggest Only"), _("Ask Before Lasting Changes"), _("Act on Its Own") };
            int mode_index = 1;
            for (int i = 0; i < MODES.length; i++) if (MODES[i] == AgentConfig.mode()) mode_index = i;
            var mode_row = new SelectionRow(_("Mode"), mode_names, mode_names[mode_index]);
            mode_row.selected.connect(() => {
                int i = mode_row.selected_index;
                if (i < 0 || i >= MODES.length) return;
                try {
                    AgentConfig.set_mode(MODES[i]);
                } catch (Error e) {
                    warning("Cannot save the AI mode: %s", e.message);
                }
            });
            behaviour_group.add_row(mode_row);
            var voice_row = new SwitchRow(_("Voice"), _("Listen while Super+Shift+A is held"), AgentConfig.flag("voice", true));
            voice_row.switch_btn.notify["active"].connect(() => save_flag("voice", voice_row.switch_btn.active));
            behaviour_group.add_row(voice_row);
            var background_row = new SwitchRow(_("Work in the Background"),
                _("Finish tasks while you use other apps. It still asks before anything that cannot be undone."),
                AgentConfig.flag("background", false));
            background_row.switch_btn.notify["active"].connect(() => save_flag("background", background_row.switch_btn.active));
            behaviour_group.add_row(background_row);
            add_group(behaviour_group);

            var phones = new PreferencesGroup(_("Phones"),
                _("Ask Sinty AI from a paired phone. It has the same powers as this panel and asks you the same questions."));
            var phones_row = new ActionRow(_("Paired Phones"), phones_summary(), "phone-symbolic");
            phones_row.activatable = true;
            var arrow = new Image.from_icon_name("go-next-symbolic");
            arrow.pixel_size = 12;
            arrow.add_css_class("dim-label");
            arrow.valign = Align.CENTER;
            phones_row.add_suffix(arrow);
            phones_row.activated.connect(() => view.navigate_to("connected-devices"));
            var nearby = NearbyClient.get_default();
            ulong watch = nearby.changed.connect(() => phones_row.subtitle = phones_summary());
            phones_row.destroy.connect(() => nearby.disconnect(watch));
            phones.add_row(phones_row);
            add_group(phones);

            model_group.sensitive = enabled_row.switch_btn.active;
            behaviour_group.sensitive = enabled_row.switch_btn.active;
            enabled_row.switch_btn.notify["active"].connect(() => {
                model_group.sensitive = enabled_row.switch_btn.active;
                behaviour_group.sensitive = enabled_row.switch_btn.active;
                if (enabled_row.switch_btn.active) save();
                else if (!loading) AgentConfig.remove();
            });
            loading = false;
        }

        private void save() {
            if (loading || !enabled_row.switch_btn.active) return;
            try {
                AgentConfig.save(provider_row.current_value, model_row.text.strip(), endpoint_row.text.strip());
            } catch (Error e) {
                warning("Cannot save the AI settings: %s", e.message);
            }
        }

        private void save_flag(string name, bool value) {
            if (loading || !enabled_row.switch_btn.active) return;
            try {
                AgentConfig.set_flag(name, value);
            } catch (Error e) {
                warning("Cannot save the AI settings: %s", e.message);
            }
        }

        private void finish_key() {
            if (key_timeout != 0) {
                Source.remove(key_timeout);
                key_timeout = 0;
            }
            store_key.begin((obj, res) => {
                if (store_key.end(res)) key_row.text = "";
            });
        }

        private async void refresh_key_state() {
            var uses_key = provider_row.current_value == "claude-api" || provider_row.current_value == "ollama";
            key_row.visible = uses_key;
            if (!uses_key) return;
            var state = yield AgentConfig.key_state(provider_row.current_value);
            if (state < 0) key_row.placeholder_text = _("Keyring locked");
            else key_row.placeholder_text = state > 0 ? _("Saved in the keyring") : _("Not set");
        }

        private async bool store_key() {
            var key = key_row.text.strip();
            if (key == "") return false;
            if (key == stored_key) return true;
            try {
                var process = new Subprocess(SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDERR_SILENCE,
                    AgentConfig.BINARY, "key", provider_row.current_value);
                yield process.communicate_utf8_async(key, null, null, null);
                if (!process.get_successful()) {
                    key_row.placeholder_text = _("Not saved: the keyring refused the key");
                    return false;
                }
                stored_key = key;
                yield refresh_key_state();
                return true;
            } catch (Error e) {
                warning("Cannot store the API key: %s", e.message);
                key_row.placeholder_text = _("Not saved: the keyring refused the key");
                return false;
            }
        }
    }
}
