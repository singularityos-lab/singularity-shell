using Gtk;
using Singularity.Widgets;
using Singularity.Accounts;

namespace Singularity.SidebarPages {

    public class AccountDetailPage : SettingsPage {
        private SettingsView view;
        private Account account;
        private Box body;
        private ulong changed_handler;
        private ulong removed_handler;
        private Label message_label;
        private string flow_id = "";
        private ulong flow_handler;

        public AccountDetailPage(SettingsView view, Account account) {
            base(account.display_name);
            this.view = view;
            this.account = account;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("accounts"));
            message_label = new Label("");
            message_label.add_css_class("error");
            message_label.wrap = true;
            message_label.xalign = 0;
            message_label.margin_top = 12;
            message_label.margin_start = 12;
            message_label.margin_end = 12;
            message_label.visible = false;
            add_widget(message_label);
            body = new Box(Orientation.VERTICAL, 0);
            add_widget(body);
            build();
            changed_handler = account.changed.connect(() => build());
            var manager = Manager.get_default();
            removed_handler = manager.account_removed.connect((a) => {
                if (a.id == account.id) view.navigate_to("accounts");
            });
            destroy.connect(() => {
                account.disconnect(changed_handler);
                manager.disconnect(removed_handler);
                if (flow_handler != 0) manager.disconnect(flow_handler);
                if (flow_id != "") manager.cancel_sign_in.begin(flow_id);
            });
        }

        private void clear() {
            Widget? child;
            while ((child = body.get_first_child()) != null) body.remove(child);
        }

        private void add(Widget group) {
            group.margin_top = 12;
            body.append(group);
        }

        private Widget build_header() {
            var box = new Box(Orientation.HORIZONTAL, 16);
            box.margin_top = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            var icon = new Image.from_icon_name(account.icon_name);
            icon.pixel_size = 64;
            box.append(icon);
            var text = new Box(Orientation.VERTICAL, 4);
            text.valign = Align.CENTER;
            var name = new Label(account.display_name);
            name.add_css_class("title-3");
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.END;
            text.append(name);
            var who = new Label("%s, %s".printf(account.provider_name, account.identity));
            who.add_css_class("dim-label");
            who.xalign = 0;
            who.ellipsize = Pango.EllipsizeMode.MIDDLE;
            text.append(who);
            box.append(text);
            return box;
        }

        private void build() {
            clear();
            body.append(build_header());
            if (paste_group != null) {
                paste_group.margin_top = 12;
                body.append(paste_group);
            }
            if (account.attention != "") add(build_reauth());
            add(build_capabilities());
            if (account.provider == "microsoft" && account.auth == "oauth2" && account.supports(Capability.MAIL)) add(build_mail_route());
            add(build_connection());
            add(build_remove());
        }

        private Widget build_capabilities() {
            var group = new PreferencesGroup(_("Use This Account For"),
                _("Switched off items disappear from the apps; their offline copies stay until the account is removed."));
            foreach (var cap in account.get_supported()) {
                var row = new SwitchRow(cap.label(), capability_hint(cap), account.has_capability(cap));
                row.icon_name = cap.icon_name();
                Capability c = cap;
                row.switch_btn.notify["active"].connect(() => {
                    if (row.active == account.has_capability(c)) return;
                    Manager.get_default().set_capability_enabled.begin(account, c, row.active, (obj, res) => {
                        try {
                            Manager.get_default().set_capability_enabled.end(res);
                        } catch (Error e) {
                            warning("accounts: %s", e.message);
                            row.active = account.has_capability(c);
                        }
                    });
                });
                group.add_row(row);
            }
            if (account.get_supported().length == 0) {
                group.add_row(new ActionRow(_("Nothing to Use Yet"), _("This account offers nothing the apps can use."), "dialog-information-symbolic"));
            }
            return group;
        }

        private Widget build_mail_route() {
            var group = new PreferencesGroup(_("Advanced"),
                _("Mail goes through Microsoft Graph. Use IMAP and SMTP only if your organization turned Graph mail off."));
            bool imap = account.get_endpoint("mail-api") == "imap";
            bool allowed = (account.get_endpoint("granted-scopes") ?? "").contains("IMAP.AccessAsUser.All");
            var row = new SwitchRow(_("Use IMAP and SMTP for Mail"),
                imap ? _("Mail is read over IMAP and sent over SMTP")
                    : allowed ? _("Already allowed for this account") : _("Asks you to sign in again to allow it"), imap);
            row.icon_name = Capability.MAIL.icon_name();
            row.switch_btn.notify["active"].connect(() => {
                if (row.active == (account.get_endpoint("mail-api") == "imap")) return;
                Manager.get_default().set_mail_imap_fallback.begin(account, row.active, (obj, res) => {
                    try {
                        Manager.get_default().set_mail_imap_fallback.end(res);
                    } catch (AccountsError.NEEDS_REAUTH e) {
                        row.active = account.get_endpoint("mail-api") == "imap";
                    } catch (Error e) {
                        row.active = account.get_endpoint("mail-api") == "imap";
                        show_message(_("Could Not Change How Mail Connects"), friendly(e));
                    }
                });
            });
            group.add_row(row);
            return group;
        }

        private string capability_hint(Capability cap) {
            switch (cap) {
                case Capability.MAIL: return _("In Lettere");
                case Capability.CALENDAR: return _("In Calendar and the panel");
                case Capability.CONTACTS: return _("In Contacts");
                case Capability.TASKS: return _("In Tasks");
                case Capability.FILES: return _("In Files and the office apps");
                case Capability.PHOTOS: return _("In Photos");
                case Capability.MUSIC: return _("In Music");
                case Capability.VIDEOS: return _("In Videos");
                default: return _("Kept for apps that support notes");
            }
        }

        private Widget build_connection() {
            var group = new PreferencesGroup(_("Connection"));
            var name_row = new EntryRow(_("Name"));
            name_row.text = account.display_name;
            name_row.entry_activated.connect(() => {
                string value = name_row.text.strip();
                if (value == "" || value == account.display_name) return;
                Manager.get_default().set_display_name.begin(account, value);
            });
            group.add_row(name_row);
            var identity = new ActionRow(_("Signed In As"), account.identity, null);
            group.add_row(identity);
            if (account.server != "") group.add_row(new ActionRow(_("Server"), account.server, null));
            string method = account.auth == "oauth2"
                ? _("Browser sign-in, renewed automatically")
                : account.provider == "nextcloud" ? _("App password from browser sign-in") : _("Password stored in the keyring");
            group.add_row(new ActionRow(_("Sign-In Method"), method, null));
            if (account.auth == "password" && account.provider != "nextcloud") {
                var pass = new PasswordRow(_("New Password"));
                var status = new Label("");
                status.add_css_class("dim-label");
                status.wrap = true;
                var update = new Button.with_label(_("Update"));
                update.add_css_class("flat");
                update.valign = Align.CENTER;
                pass.add_suffix(update);
                update.clicked.connect(() => update_password(pass, status, update));
                pass.entry_activated.connect(() => update_password(pass, status, update));
                group.add_row(pass);
                status.margin_start = 12;
                status.margin_top = 6;
                status.xalign = 0;
                status.visible = false;
                group.add_row(status);
            } else {
                var again = new ActionRow(_("Sign In Again…"), _("Opens the sign-in page in your browser"), "web-browser-symbolic");
                again.activatable = true;
                again.activated.connect(() => start_reauth());
                group.add_row(again);
            }
            return group;
        }

        private void update_password(PasswordRow pass, Label status, Button update) {
            if (pass.text == "") return;
            update.sensitive = false;
            status.visible = true;
            status.label = _("Checking the password…");
            Manager.get_default().update_password.begin(account, pass.text, (obj, res) => {
                try {
                    Manager.get_default().update_password.end(res);
                    status.label = _("Password updated");
                    pass.text = "";
                } catch (Error e) {
                    status.label = friendly(e);
                }
                update.sensitive = true;
            });
        }

        private Widget build_reauth() {
            var group = account.attention == "consent"
                ? new PreferencesGroup(_("Permission Needed"), _("Sign in again and allow the new access the account asks for. Nothing else changes."))
                : new PreferencesGroup(_("Sign-In Required"),
                    _("The server no longer accepts the saved sign-in, so apps stopped syncing this account. Your offline copies are kept."));
            if (account.auth == "password" && account.provider != "nextcloud") {
                group.add_row(new ActionRow(_("Enter the Password Again"), _("Use New Password below"), "dialog-password-symbolic"));
            } else {
                var row = new ActionRow(_("Sign In Again"), _("Opens the sign-in page in your browser"), "web-browser-symbolic");
                var go = new Button.with_label(_("Sign In"));
                go.add_css_class("suggested-action");
                go.valign = Align.CENTER;
                go.clicked.connect(() => start_reauth());
                row.add_suffix(go);
                group.add_row(row);
            }
            return group;
        }

        private SidebarWaitTicket? wait_ticket = null;
        private SignInPasteGroup? paste_group = null;

        private void stop_waiting(bool reveal) {
            if (paste_group != null) {
                if (paste_group.get_parent() == body) body.remove(paste_group);
                paste_group = null;
            }
            if (wait_ticket == null) return;
            var t = wait_ticket;
            wait_ticket = null;
            if (reveal) t.end();
            else t.end_quietly();
        }

        private void start_reauth() {
            var manager = Manager.get_default();
            var settings = new HashTable<string, Variant>(str_hash, str_equal);
            settings.insert("account", account.id);
            manager.begin_sign_in.begin(account.provider, settings, (obj, res) => {
                try {
                    string url;
                    flow_id = manager.begin_sign_in.end(res, out url);
                    if (flow_handler == 0) {
                        flow_handler = manager.sign_in_finished.connect((flow, id, error_message) => {
                            if (flow != flow_id) return;
                            flow_id = "";
                            if (error_message != "") show_message(_("Sign-In Failed"), error_message);
                            stop_waiting(true);
                        });
                    }
                    stop_waiting(false);
                    wait_ticket = SidebarWait.get_default().begin(this, _("Waiting for %s").printf(account.provider_name),
                        "web-browser-symbolic", () => {
                            if (flow_id != "") manager.cancel_sign_in.begin(flow_id);
                            flow_id = "";
                            stop_waiting(false);
                        });
                    bool in_window = false;
                    manager.open_sign_in_window.begin(flow_id, url, account.provider_name, account.icon_name, (o, r) => {
                        in_window = manager.open_sign_in_window.end(r);
                        if (in_window) {
                            ulong h = 0;
                            h = manager.sign_in_window_closed.connect((flow, browser) => {
                                if (flow != flow_id) return;
                                manager.disconnect(h);
                                if (browser && account.auth == "oauth2" && paste_group == null) {
                                    paste_group = new SignInPasteGroup(() => flow_id);
                                    paste_group.margin_top = 12;
                                    body.insert_child_after(paste_group, body.get_first_child());
                                }
                            });
                            return;
                        }
                        if (account.auth == "oauth2") {
                            paste_group = new SignInPasteGroup(() => flow_id);
                            paste_group.margin_top = 12;
                            body.insert_child_after(paste_group, body.get_first_child());
                        }
                        open_browser(url);
                    });
                } catch (Error e) {
                    show_message(_("Sign-In Failed"), friendly(e));
                }
            });
        }

        public static void open_browser(string url) {
            try {
                AppInfo.launch_default_for_uri(url, null);
            } catch (Error e) {
                warning("accounts: cannot open %s: %s", url, e.message);
            }
        }

        private void show_message(string title, string text) {
            message_label.label = "%s. %s".printf(title, text);
            message_label.visible = true;
        }

        public static string friendly(Error e) {
            string msg = e.message;
            int colon = msg.index_of("dev.sinty.Accounts.Error.");
            if (colon >= 0) {
                int after = msg.index_of(": ", colon);
                if (after >= 0) msg = msg.substring(after + 2);
            }
            if (msg.has_prefix("GDBus.Error:")) {
                int after = msg.index_of(": ");
                if (after >= 0) msg = msg.substring(after + 2);
            }
            return msg;
        }

        private Widget build_remove() {
            var group = new PreferencesGroup(_("Remove Account"),
                _("Removes the account, its saved sign-in and its offline copies from this computer. Nothing is deleted on the server."));
            var row = new ActionRow(_("Remove Account"), _("Its mail, calendars, contacts, tasks and files disappear from your apps"), "user-trash-symbolic");
            var remove = new Button.with_label(_("Remove"));
            remove.add_css_class("destructive-action");
            remove.valign = Align.CENTER;
            remove.clicked.connect(() => {
                row.confirmation_requested(_("Remove"), _("Cancel"), ConfirmationSuggestedAction.CANCEL);
            });
            row.confirmed.connect(() => {
                Manager.get_default().remove_account.begin(account, (obj, res) => {
                    try {
                        Manager.get_default().remove_account.end(res);
                        view.navigate_to("accounts");
                    } catch (Error e) {
                        show_message(_("Could Not Remove the Account"), friendly(e));
                    }
                });
            });
            row.add_suffix(remove);
            group.add_row(row);
            return group;
        }
    }
}
