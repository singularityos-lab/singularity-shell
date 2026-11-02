using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AgentPage : SettingsPage {
        private const string[] PROVIDERS = { "claude-code", "codex", "claude-api", "ollama" };
        private SelectionRow provider_row;
        private EntryRow model_row;
        private EntryRow endpoint_row;
        private PasswordRow key_row;
        private SwitchRow enabled_row;
        private PreferencesGroup model_group;
        private bool loading = true;
        private uint key_timeout = 0;
        private string stored_key = "";

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

            model_group.sensitive = enabled_row.switch_btn.active;
            enabled_row.switch_btn.notify["active"].connect(() => {
                model_group.sensitive = enabled_row.switch_btn.active;
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
