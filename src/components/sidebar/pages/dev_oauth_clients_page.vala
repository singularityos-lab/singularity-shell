using Gtk;
using Singularity.Widgets;
using Singularity.Accounts;

namespace Singularity.SidebarPages {

    public class DevOAuthClientsPage : SettingsPage {
        private SettingsView view;
        private Box body;

        public DevOAuthClientsPage (SettingsView view) {
            base (_("OAuth Clients"));
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect (() => view.navigate_to ("developer"));
            body = new Box (Orientation.VERTICAL, 0);
            add_widget (body);
            load.begin ();
        }

        private void clear () {
            Widget? child;
            while ((child = body.get_first_child ()) != null) body.remove (child);
        }

        private async void load () {
            clear ();
            try {
                var list = yield Manager.get_default ().list_providers ();
                foreach (var p in list) {
                    if (p.auth != "oauth2") continue;
                    var group = build_group (p);
                    group.margin_top = 12;
                    body.append (group);
                }
            } catch (Error e) {
                var status = new StatusPage ();
                status.icon_name = "network-error";
                status.title = _("Online Accounts Unavailable");
                status.description = AccountDetailPage.friendly (e);
                var retry = new Button.with_label (_("Try Again"));
                retry.add_css_class ("pill");
                retry.halign = Align.CENTER;
                retry.clicked.connect (() => load.begin ());
                status.child = retry;
                body.append (status);
            }
        }

        private static string describe_source (ProviderInfo p) {
            switch (p.client_source) {
                case "built-in": return _("Built into the accounts service at build time");
                case "distribution": return _("Distribution file %s").printf (p.client_path);
                case "system": return _("System file %s").printf (p.client_path);
                case "user": return _("Your override in %s").printf (p.client_path);
                default: return _("No client configured; browser sign-in is unavailable");
            }
        }

        private PreferencesGroup build_group (ProviderInfo p) {
            bool google = p.id == "google";
            var group = new PreferencesGroup (p.name, google
                ? _("Desktop app client with a secret. The override is stored for your user only and wins over every other source.")
                : _("Public client without a secret. The override is stored for your user only and wins over every other source."));
            var source = new ActionRow (_("Active Source"), describe_source (p), p.icon_name + "-symbolic");
            group.add_row (source);
            var active = new ActionRow (_("Active Client ID"), p.client_id != "" ? p.client_id : _("None"), null);
            group.add_row (active);
            if (google && p.client_id != "") {
                group.add_row (new ActionRow (_("Active Client Secret"), p.client_has_secret ? _("Set, hidden") : _("Not set"), null));
            }

            var id_row = new EntryRow (_("Override Client ID"));
            if (p.client_source == "user") id_row.text = p.client_id;
            group.add_row (id_row);
            PasswordRow? secret_row = null;
            if (google) {
                secret_row = new PasswordRow (_("Override Client Secret"));
                group.add_row (secret_row);
            }

            var actions = new ActionRow (_("Override"), p.client_source == "user"
                ? _("Remove it to go back to the system client") : _("Save to use this client for your user"), null);
            var status = new Label ("");
            status.add_css_class ("dim-label");
            status.wrap = true;
            status.xalign = 0;
            status.margin_start = 12;
            status.margin_top = 6;
            status.visible = false;

            var remove = new Button.with_label (_("Remove"));
            remove.add_css_class ("destructive-action");
            remove.valign = Align.CENTER;
            remove.sensitive = p.client_source == "user";
            remove.clicked.connect (() => store (p.id, "", "", status));
            actions.add_suffix (remove);

            var save = new Button.with_label (_("Save"));
            save.valign = Align.CENTER;
            save.margin_start = 6;
            save.clicked.connect (() => {
                string id = id_row.text.strip ();
                if (id == "") {
                    status.label = _("Enter a client ID");
                    status.visible = true;
                    return;
                }
                store (p.id, id, secret_row != null ? secret_row.text.strip () : "", status);
            });
            actions.add_suffix (save);
            group.add_row (actions);
            group.add_row (status);
            return group;
        }

        private void store (string provider, string id, string secret, Label status) {
            Manager.get_default ().set_oauth_client.begin (provider, id, secret, (obj, res) => {
                try {
                    Manager.get_default ().set_oauth_client.end (res);
                    load.begin ();
                } catch (Error e) {
                    status.label = AccountDetailPage.friendly (e);
                    status.visible = true;
                }
            });
        }
    }
}
