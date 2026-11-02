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
            provider_row.selected.connect(() => save());
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
            key_row.entry_activated.connect(store_key);
            model_group.add_row(key_row);
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

        private void store_key() {
            var key = key_row.text.strip();
            if (key == "") return;
            try {
                var process = new Subprocess(SubprocessFlags.STDIN_PIPE, AgentConfig.BINARY, "key", provider_row.current_value);
                process.communicate_utf8_async.begin(key, null);
                key_row.text = "";
            } catch (Error e) {
                warning("Cannot store the API key: %s", e.message);
            }
        }
    }
}
