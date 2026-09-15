using Gtk;
using Singularity.Widgets;

namespace Singularity.Shell {
    // Shared credential UI: providers choose an email or a secret-key row
    // and handle submission without putting credentials in command arguments.
    public class ProviderCredentialGroup : PreferencesGroup {
        public signal void submitted(string value);
        private EntryRow entry;
        private Button submit;
        private ActionRow state;

        public ProviderCredentialGroup(string provider, string prompt, bool secret, string explanation) {
            title = provider;
            description = explanation;
            entry = secret ? new PasswordRow(prompt) : new EntryRow(prompt);
            submit = new Button.with_label(_("Submit"));
            submit.valign = Align.CENTER;
            submit.clicked.connect(() => {
                string value = entry.text.strip();
                if (value != "") submitted(value);
            });
            entry.add_suffix(submit);
            add_row(entry);
            state = new ActionRow("");
            state.visible = false;
            add_row(state);
        }

        public void set_state(string message, bool can_submit) {
            state.title = message;
            state.visible = message != "";
            entry.sensitive = can_submit;
            submit.sensitive = can_submit;
            if (!can_submit) entry.text = "";
        }
    }
}
