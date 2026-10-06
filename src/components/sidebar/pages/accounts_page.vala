using Gtk;
using Singularity.Widgets;
using Singularity.Calendar;
using Singularity.Accounts;

namespace Singularity.SidebarPages {

    public class AccountsPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup accounts_group;
        private PreferencesGroup calendars_group;
        private StatusPage unavailable;
        private Gee.HashMap<string, ActionRow> rows = new Gee.HashMap<string, ActionRow>();
        private Gee.ArrayList<ulong> manager_handlers = new Gee.ArrayList<ulong>();

        public AccountsPage(SettingsView view) {
            base(_("Online Accounts"));
            this.view = view;
            back_clicked.connect(() => {
                view.go_home();
            });

            unavailable = new StatusPage();
            unavailable.icon_name = "singularity-account-generic";
            unavailable.title = _("Online Accounts Unavailable");
            unavailable.visible = false;
            var retry = new Button.with_label(_("Try Again"));
            retry.add_css_class("pill");
            retry.halign = Align.CENTER;
            retry.clicked.connect(() => Manager.get_default().reload.begin());
            unavailable.child = retry;
            add_widget(unavailable);

            accounts_group = new PreferencesGroup(_("Accounts"),
                _("Mail, calendars, contacts, tasks and files from these accounts appear in your apps."));
            add_group(accounts_group);

            var add_group_widget = new PreferencesGroup(_("Add Account"),
                _("Nextcloud, Google, Microsoft, Exchange, mail servers and more."));
            var add_row = new ActionRow(_("Add an Account…"), _("Choose a provider and sign in"), "list-add-symbolic");
            add_row.activatable = true;
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            chevron.add_css_class("dim-label");
            chevron.valign = Align.CENTER;
            add_row.add_suffix(chevron);
            add_row.activated.connect(() => open_add_page());
            add_group_widget.add_row(add_row);
            add_group(add_group_widget);

            calendars_group = new PreferencesGroup(_("Calendars"),
                _("Choose which calendars appear in the panel. Online calendars come from the accounts above."));
            add_group(calendars_group);
            var local_group = new PreferencesGroup(_("Calendar Files"), _("Import events from an .ics file into a new calendar on this computer."));
            var import_row = new ActionRow(_("Add Calendar from File…"), _("Events are kept on this computer"), "x-office-calendar-symbolic");
            var import_btn = new Button.with_label(_("Add"));
            import_btn.add_css_class("flat");
            import_btn.valign = Align.CENTER;
            import_btn.clicked.connect(() => {
                var app = (SingularityApp) GLib.Application.get_default();
                if (app.sidebar != null) {
                    app.sidebar.open_file_picker("Calendar Files", { "*.ics" }, (file) => {
                        import_calendar(file);
                    });
                }
            });
            import_row.add_suffix(import_btn);
            local_group.add_row(import_row);
            add_group(local_group);

            refresh_calendars();
            var manager = CalendarManager.get_default();
            ulong providers_handler = manager.providers_changed.connect(() => refresh_calendars());
            destroy.connect(() => manager.disconnect(providers_handler));

            var accounts = Manager.get_default();
            manager_handlers.add(accounts.account_added.connect(() => refresh_accounts()));
            manager_handlers.add(accounts.account_removed.connect(() => refresh_accounts()));
            manager_handlers.add(accounts.account_changed.connect(() => refresh_accounts()));
            manager_handlers.add(accounts.reloaded.connect(() => refresh_accounts()));
            destroy.connect(() => {
                foreach (ulong h in manager_handlers) accounts.disconnect(h);
                manager_handlers.clear();
            });
            accounts.load.begin((obj, res) => {
                accounts.load.end(res);
                refresh_accounts();
            });
            AccountCalendars.register_all(manager);

            AddAccountPage.add_provider_search_actions(this, view);
        }

        private void open_add_page() {
            var page = new AddAccountPage(view);
            view.open_subpage(page, "add-account");
        }

        public static string describe(Account account) {
            if (account.attention != "") return _("Sign in again to keep using this account");
            string[] used = {};
            foreach (var cap in Capability.all()) {
                if (account.has_capability(cap)) used += cap.label();
            }
            string where = account.provider_name;
            if (account.provider == "imap" || account.provider == "caldav" || account.provider == "webdav" || account.provider == "exchange") {
                string host = account.server;
                try {
                    if (host.contains("://")) host = Uri.parse(host, UriFlags.NONE).get_host() ?? host;
                } catch (GLib.Error e) {
                }
                if (host != "") where = host;
            }
            if (used.length == 0) return _("%s, not used by any app").printf(where);
            return "%s, %s".printf(where, string.joinv(", ", used));
        }

        private void refresh_accounts() {
            var manager = Manager.get_default();
            unavailable.visible = !manager.available;
            unavailable.description = manager.last_error;
            accounts_group.visible = manager.available;
            accounts_group.clear();
            rows.clear();
            var list = manager.get_accounts();
            if (list.size == 0) {
                var empty = new ActionRow(_("No Accounts Yet"), _("Add an account to see its mail, calendars, contacts and files in your apps."), "singularity-account-generic-symbolic");
                accounts_group.add_row(empty);
                return;
            }
            foreach (var account in list) {
                var row = new ActionRow(account.display_name, describe(account), account.symbolic_icon_name);
                row.activatable = true;
                row.tooltip_text = account.identity;
                if (account.attention != "") {
                    var warn = new Image.from_icon_name("dialog-warning-symbolic");
                    warn.add_css_class("warning");
                    warn.valign = Align.CENTER;
                    warn.tooltip_text = _("Sign in again");
                    row.add_suffix(warn);
                }
                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.pixel_size = 12;
                chevron.add_css_class("dim-label");
                chevron.valign = Align.CENTER;
                row.add_suffix(chevron);
                string id = account.id;
                row.activated.connect(() => open_account(id));
                accounts_group.add_row(row);
                rows[account.id] = row;
            }
        }

        private void open_account(string id) {
            var account = Manager.get_default().get_account(id);
            if (account == null) return;
            var page = new AccountDetailPage(view, account);
            view.open_subpage(page, "account-" + id);
        }

        private void import_calendar(File file) {
            var path = file.get_path();
            if (path == null) return;
            string name = file.get_basename();
            if (name.has_suffix(".ics")) name = name.substring(0, name.length - 4);
            string id = "local-" + name;
            var manager = CalendarManager.get_default();
            if (manager.get_provider(id) != null) {
                warning("Calendar %s already exists", name);
                return;
            }
            var provider = new LocalProvider(name, id, name + ".json", "#3584e4");
            provider.import_file.begin(path, (obj, res) => {
                try {
                    provider.import_file.end(res);
                    manager.register_provider(provider);
                    refresh_calendars();
                } catch (GLib.Error e) {
                    warning("Failed to import calendar: %s", e.message);
                }
            });
        }

        private void refresh_calendars() {
            calendars_group.clear();
            var manager = CalendarManager.get_default();
            foreach (var provider in manager.get_providers()) {
                string subtitle = provider.id;
                var web = provider as WebCalendarProvider;
                var online = provider as AccountCalendarProvider;
                if (provider is LocalProvider) {
                    subtitle = _("On this computer");
                } else if (online != null) {
                    subtitle = online.synced.offline
                        ? _("%s, offline").printf(online.account_name)
                        : online.synced.last_error != ""
                            ? _("%s, not synced").printf(online.account_name)
                            : online.account_name;
                } else if (web != null) {
                    string host = web.url;
                    try {
                        host = Uri.parse(web.url, UriFlags.NONE).get_host() ?? web.url;
                    } catch (GLib.Error e) {
                    }
                    subtitle = _("Subscribed from %s").printf(host);
                }
                var row = new SwitchRow(provider.name, subtitle, provider.is_visible);
                row.switch_btn.notify["active"].connect(() => {
                    provider.is_visible = row.active;
                    if (web != null) web.remember_visibility();
                    var local = provider as LocalProvider;
                    if (local != null) local.remember_visibility();
                });
                if (web != null) {
                    var unsub_btn = new Button.from_icon_name("user-trash-symbolic");
                    unsub_btn.add_css_class("flat");
                    unsub_btn.add_css_class("destructive-action");
                    unsub_btn.tooltip_text = _("Unsubscribe");
                    unsub_btn.clicked.connect(() => {
                        row.confirmation_requested(_("Unsubscribe"), _("Cancel"),
                            ConfirmationSuggestedAction.CANCEL);
                    });
                    row.confirmed.connect(() => {
                        web.unsubscribe(manager);
                        refresh_calendars();
                    });
                    row.add_suffix(unsub_btn);
                } else if (provider.id != "local-provider" && provider.id.has_prefix("local-")) {
                    var del_btn = new Button.from_icon_name("user-trash-symbolic");
                    del_btn.add_css_class("flat");
                    del_btn.add_css_class("destructive-action");
                    del_btn.tooltip_text = _("Remove");
                    del_btn.clicked.connect(() => {
                        row.confirmation_requested(_("Remove"), _("Cancel"),
                            ConfirmationSuggestedAction.CANCEL);
                    });
                    row.confirmed.connect(() => {
                        if (provider is LocalProvider) {
                            ((LocalProvider) provider).delete();
                        }
                        manager.unregister_provider(provider.id);
                        refresh_calendars();
                    });
                    row.add_suffix(del_btn);
                }
                calendars_group.add_row(row);
            }
        }
    }
}
