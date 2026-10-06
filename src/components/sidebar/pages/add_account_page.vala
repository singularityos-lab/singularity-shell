using Gtk;
using Singularity.Widgets;
using Singularity.Accounts;

namespace Singularity.SidebarPages {

    public class AddAccountPage : SettingsPage {
        private SettingsView view;
        private Stack inner_stack;
        private Box form_box;
        private Box waiting_box;
        private Label error_label;
        private Button connect_btn;
        private string selected_provider = "";
        private string selected_name = "";
        private Gee.HashMap<string, ProviderInfo> providers = new Gee.HashMap<string, ProviderInfo>();
        private WelcomePage picker;
        private StatusPage picker_error;

        private EntryRow? server_row;
        private EntryRow? user_row;
        private PasswordRow? pass_row;
        private EmailRow? email_row;
        private EntryRow? name_row;
        private EntryRow? imap_row;
        private EntryRow? smtp_row;
        private EntryRow? mail_user_row;
        private SelectionRow? security_row;
        private EntryRow? imap_port_row;
        private EntryRow? smtp_port_row;
        private EntryRow? calendar_link_row;
        private bool browser_flow;

        private string flow_id = "";
        private string flow_url = "";
        private ulong flow_handler;

        public signal void account_added();

        private struct KnownProvider {
            public string id;
            public string name;
            public string description;
        }

        private static KnownProvider[] known() {
            return {
                KnownProvider() { id = "nextcloud", name = "Nextcloud", description = _("Calendars, contacts, tasks and files on a Nextcloud server") },
                KnownProvider() { id = "google", name = "Google", description = _("Mail, calendar, contacts, tasks and Drive") },
                KnownProvider() { id = "microsoft", name = "Microsoft", description = _("Outlook.com and Microsoft 365 mail, calendar, contacts, To Do and OneDrive") },
                KnownProvider() { id = "owncloud", name = "ownCloud", description = _("Calendars, contacts, tasks and files on an ownCloud server") },
                KnownProvider() { id = "exchange", name = "Exchange", description = _("Mail and calendar on an Exchange server in your organization") },
                KnownProvider() { id = "imap", name = _("Mail (IMAP and SMTP)"), description = _("Any mail account with its server details") },
                KnownProvider() { id = "proton", name = "Proton", description = _("Proton Mail through Proton Mail Bridge") },
                KnownProvider() { id = "caldav", name = _("Calendar and Contacts (CalDAV, CardDAV)"), description = _("Any CalDAV or CardDAV server") },
                KnownProvider() { id = "webdav", name = _("Files (WebDAV)"), description = _("Any WebDAV file server") },
                KnownProvider() { id = "jellyfin", name = "Jellyfin", description = _("Music and videos on your Jellyfin server") },
                KnownProvider() { id = "subsonic", name = _("Navidrome and Subsonic"), description = _("Music on a Navidrome, Subsonic, Airsonic or gonic server") },
                KnownProvider() { id = "listenbrainz", name = "ListenBrainz", description = _("Keep a public history of the music you listen to") },
                KnownProvider() { id = "spotify", name = "Spotify", description = _("Your Spotify library and playback on your devices, with your own developer client ID") }
            };
        }

        private static string icon_for(string id) {
            switch (id) {
                case "proton": return "singularity-account-secure-mail";
                case "jellyfin": case "subsonic": return "singularity-account-media-server";
                case "listenbrainz": return "singularity-account-listening";
                case "spotify": return "singularity-account-music-service";
                default: return "singularity-account-" + id;
            }
        }

        public static void add_provider_search_actions(SettingsPage page, SettingsView view) {
            foreach (var p in known()) {
                string id = p.id;
                string name = p.name;
                page.add_search_action(name, p.description, () => {
                    var add_page = new AddAccountPage(view);
                    view.open_subpage(add_page, "add-account");
                    add_page.select_provider(id, name);
                });
            }
        }

        public AddAccountPage(SettingsView view) {
            base(_("Add Account"));
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect(() => {
                if (inner_stack.visible_child_name != "providers") {
                    cancel_flow();
                    inner_stack.visible_child_name = "providers";
                } else {
                    view.navigate_to("accounts");
                }
            });

            inner_stack = new Stack();
            inner_stack.transition_type = StackTransitionType.CROSSFADE;
            inner_stack.vhomogeneous = false;

            var picker_box = new Box(Orientation.VERTICAL, 0);
            picker = new WelcomePage();
            picker.is_section = true;
            picker.embedded = true;
            picker.compact = true;
            picker.app_icon_name = "singularity-account-generic";
            picker.title = _("Add an Account");
            picker.subtitle = _("Choose where your account is. Its mail, calendars, contacts, tasks and files appear in your apps.");
            foreach (var p in known()) {
                string id = p.id;
                string name = p.name;
                picker.add_action(icon_for(id),
                    p.name, p.description, () => select_provider(id, name));
            }
            picker_box.append(picker);
            picker_error = new StatusPage();
            picker_error.icon_name = "network-error";
            picker_error.title = _("Online Accounts Unavailable");
            picker_error.visible = false;
            picker_box.append(picker_error);
            inner_stack.add_named(picker_box, "providers");

            form_box = new Box(Orientation.VERTICAL, 0);
            inner_stack.add_named(form_box, "form");
            waiting_box = new Box(Orientation.VERTICAL, 0);
            inner_stack.add_named(waiting_box, "waiting");
            add_widget(inner_stack);

            var manager = Manager.get_default();
            flow_handler = manager.sign_in_finished.connect(on_flow_finished);
            destroy.connect(() => {
                manager.disconnect(flow_handler);
                cancel_flow();
                if (wait_ticket != null) wait_ticket.end_quietly();
            });
            load_providers.begin();
        }

        private async void load_providers() {
            try {
                var list = yield Manager.get_default().list_providers();
                providers.clear();
                foreach (var p in list) providers[p.id] = p;
                picker_error.visible = false;
            } catch (Error e) {
                picker_error.description = AccountDetailPage.friendly(e);
                picker_error.visible = true;
            }
        }

        private void clear_form() {
            Widget? child;
            while ((child = form_box.get_first_child()) != null) form_box.remove(child);
            server_row = null;
            user_row = null;
            pass_row = null;
            email_row = null;
            name_row = null;
            imap_row = null;
            smtp_row = null;
            mail_user_row = null;
            security_row = null;
            imap_port_row = null;
            smtp_port_row = null;
            calendar_link_row = null;
            browser_flow = false;
        }

        private void add_group_to_form(PreferencesGroup group) {
            group.margin_top = 12;
            form_box.append(group);
        }

        private Widget provider_header(string id, string name) {
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 12;
            box.margin_start = 12;
            var icon = new Image.from_icon_name(providers.has_key(id) ? providers[id].icon_name : icon_for(id));
            icon.pixel_size = 48;
            box.append(icon);
            var label = new Label(name);
            label.add_css_class("title-3");
            label.valign = Align.CENTER;
            box.append(label);
            return box;
        }

        public void select_provider(string id, string name) {
            selected_provider = id;
            selected_name = name;
            clear_form();
            form_box.append(provider_header(id, name));
            switch (id) {
                case "nextcloud": build_nextcloud_form(); break;
                case "owncloud": build_server_form(_("ownCloud Server"), _("Use an app password from your ownCloud security settings if two-factor sign-in is on.")); break;
                case "google": case "microsoft": build_oauth_form(id, name); break;
                case "exchange": build_exchange_form(); break;
                case "imap": build_mail_form(); break;
                case "proton": build_proton_form(); break;
                case "caldav": build_server_form(_("CalDAV and CardDAV Server"), _("Enter the server address; calendars and address books are found automatically.")); break;
                case "webdav": build_server_form(_("WebDAV Server"), _("Enter the full address of the folder to show in Files.")); break;
                case "jellyfin": build_server_form(_("Jellyfin Server"), _("Music and Videos show your Jellyfin libraries and play them from the server.")); break;
                case "subsonic": build_server_form(_("Navidrome or Subsonic Server"), _("Music shows your library and plays it from the server.")); break;
                case "listenbrainz": build_listenbrainz_form(); break;
                case "spotify": build_spotify_form(); break;
                default: build_server_form(name, ""); break;
            }
            append_footer();
            inner_stack.visible_child_name = "form";
            load_providers.begin((obj, res) => {
                load_providers.end(res);
                if (id == "google" || id == "microsoft" || id == "spotify") refresh_oauth_state();
            });
        }

        private void build_nextcloud_form() {
            var group = new PreferencesGroup(_("Nextcloud Server"),
                _("A sign-in window shows the Nextcloud page. Singularity receives an app password; your own password is never stored."));
            server_row = new EntryRow(_("Server Address"));
            server_row.text = "https://";
            server_row.entry_activated.connect(on_connect_clicked);
            group.add_row(server_row);
            add_group_to_form(group);
            var manual = new PreferencesGroup(_("App Password"),
                _("Optional. If your browser cannot reach the server, create an app password in Nextcloud, Settings, Security, and enter it here."));
            var expander = new ExpanderRow(_("Sign In with an App Password"), null, "dialog-password-symbolic");
            user_row = new EntryRow(_("User Name"));
            expander.add_row(user_row);
            pass_row = new PasswordRow(_("App Password"));
            pass_row.entry_activated.connect(on_connect_clicked);
            expander.add_row(pass_row);
            manual.add_row(expander);
            add_group_to_form(manual);
            browser_flow = true;
        }

        private void build_server_form(string title, string description) {
            var group = new PreferencesGroup(title, description != "" ? description : null);
            server_row = new EntryRow(_("Server Address"));
            server_row.text = "https://";
            group.add_row(server_row);
            add_group_to_form(group);
            var creds = new PreferencesGroup(_("Credentials"));
            user_row = new EntryRow(_("User Name"));
            creds.add_row(user_row);
            pass_row = new PasswordRow(_("Password"));
            pass_row.entry_activated.connect(on_connect_clicked);
            creds.add_row(pass_row);
            add_group_to_form(creds);
        }

        private void build_listenbrainz_form() {
            var group = new PreferencesGroup(_("ListenBrainz Token"),
                _("Copy the user token from your ListenBrainz settings. Music then records what you listen to in your public history."));
            pass_row = new PasswordRow(_("User Token"));
            pass_row.entry_activated.connect(on_connect_clicked);
            group.add_row(pass_row);
            add_group_to_form(group);
            var advanced = new PreferencesGroup(_("Server"), _("Change it only for a self-hosted ListenBrainz."));
            server_row = new EntryRow(_("Server Address"));
            server_row.text = "https://api.listenbrainz.org";
            advanced.add_row(server_row);
            add_group_to_form(advanced);
        }

        private void build_spotify_form() {
            var sign_in = new PreferencesGroup(_("Sign In"),
                _("A sign-in window shows the Spotify page. Music then shows your library and controls playback on your Spotify devices; it never plays Spotify audio itself."));
            sign_in.set_data<string>("kind", "sign-in");
            sign_in.add_row(new ActionRow(_("Access Requested"), _("Your saved music, playlists and playback on your devices"), "security-high-symbolic"));
            add_group_to_form(sign_in);
            var unconfigured = new PreferencesGroup(_("Client ID Needed"),
                _("Spotify only lets each person connect with their own developer app. Create one on the Spotify developer dashboard with the redirect address http://127.0.0.1, then enter its client ID in Developer, OAuth Clients."));
            unconfigured.set_data<string>("kind", "notice");
            var open = new ActionRow(_("OAuth Clients"), _("Enter your Spotify client ID"), "applications-engineering-symbolic");
            open.activatable = true;
            open.activated.connect(() => view.open_subpage(new Singularity.SidebarPages.DevOAuthClientsPage(view), "dev-oauth-clients"));
            unconfigured.add_row(open);
            add_group_to_form(unconfigured);
            refresh_oauth_state();
        }

        private void build_oauth_form(string id, string name) {
            var sign_in = new PreferencesGroup(_("Sign In"),
                _("A sign-in window shows the %s page. Singularity never sees your password and renews its access by itself.").printf(name));
            sign_in.set_data<string>("kind", "sign-in");
            sign_in.add_row(new ActionRow(_("Access Requested"), id == "google"
                ? _("Mail, calendar, contacts, tasks and Drive; you choose what to use afterwards")
                : _("Mail, calendar, contacts, To Do and OneDrive; you choose what to use afterwards"), "security-high-symbolic"));
            add_group_to_form(sign_in);

            string notice = id == "google"
                ? _("Signing in to Google through the browser is not available on this system. You can still add Gmail with an app password.")
                : _("Signing in to Microsoft through the browser is not available on this system, and Microsoft does not accept app passwords for Outlook.com. Mail on an Exchange server in your organization can still be added.");
            var unconfigured = new PreferencesGroup(_("Browser Sign-In Unavailable"), notice);
            unconfigured.set_data<string>("kind", "notice");
            if (id == "microsoft") {
                var other = new ActionRow(_("Add Exchange or Other Mail"), _("Choose Exchange or Mail (IMAP and SMTP)"), "singularity-account-exchange-symbolic");
                other.activatable = true;
                other.activated.connect(() => inner_stack.visible_child_name = "providers");
                unconfigured.add_row(other);
            }
            add_group_to_form(unconfigured);

            if (id == "google") {
                var app_pw = new PreferencesGroup(_("Gmail with an App Password"),
                    _("Create an app password in your Google account, Security, App passwords. It adds mail only; Google offers calendars, contacts, tasks and Drive only through browser sign-in."));
                app_pw.set_data<string>("kind", "app-password");
                email_row = new EmailRow(_("Gmail Address"));
                app_pw.add_row(email_row);
                pass_row = new PasswordRow(_("App Password"));
                pass_row.entry_activated.connect(on_connect_clicked);
                app_pw.add_row(pass_row);
                add_group_to_form(app_pw);
            }

            refresh_oauth_state();
        }

        private void refresh_oauth_state() {
            bool configured = providers.has_key(selected_provider) && providers[selected_provider].configured;
            Widget? child = form_box.get_first_child();
            while (child != null) {
                string? kind = child.get_data<string>("kind");
                if (kind == "sign-in") child.visible = configured;
                if (kind == "notice") child.visible = !configured;
                if (kind == "app-password") child.visible = !configured;
                child = child.get_next_sibling();
            }
            browser_flow = configured;
            if (connect_btn != null) {
                connect_btn.label = configured ? _("Sign In") : _("Add Mail Account");
                connect_btn.visible = configured || selected_provider == "google";
            }
        }

        private void build_exchange_form() {
            var account = new PreferencesGroup(_("Exchange Account"),
                _("The server is found from your address. Enter it only if that fails."));
            email_row = new EmailRow(_("Email Address"));
            account.add_row(email_row);
            pass_row = new PasswordRow(_("Password"));
            pass_row.entry_activated.connect(on_connect_clicked);
            account.add_row(pass_row);
            add_group_to_form(account);
            var advanced = new PreferencesGroup(_("Server"), _("Optional."));
            server_row = new EntryRow(_("Server Name"));
            advanced.add_row(server_row);
            user_row = new EntryRow(_("User Name (if not the address)"));
            advanced.add_row(user_row);
            imap_row = new EntryRow(_("Incoming (IMAP) Server for Mail"));
            advanced.add_row(imap_row);
            smtp_row = new EntryRow(_("Outgoing (SMTP) Server for Mail"));
            advanced.add_row(smtp_row);
            add_group_to_form(advanced);
        }

        private void build_mail_form() {
            var account = new PreferencesGroup(_("Account"));
            name_row = new EntryRow(_("Your Name"));
            name_row.text = Environment.get_real_name() != "Unknown" ? Environment.get_real_name() : "";
            account.add_row(name_row);
            email_row = new EmailRow(_("Email Address"));
            account.add_row(email_row);
            pass_row = new PasswordRow(_("Password"));
            account.add_row(pass_row);
            add_group_to_form(account);

            var servers = new PreferencesGroup(_("Servers"), _("Add :port after the server name to use a port other than the standard one."));
            imap_row = new EntryRow(_("Incoming (IMAP) Server"));
            servers.add_row(imap_row);
            smtp_row = new EntryRow(_("Outgoing (SMTP) Server"));
            servers.add_row(smtp_row);
            mail_user_row = new EntryRow(_("User Name (if not the address)"));
            servers.add_row(mail_user_row);
            security_row = new SelectionRow(_("Encryption"), { _("SSL/TLS"), _("STARTTLS"), _("None") }, _("SSL/TLS"));
            servers.add_row(security_row);
            add_group_to_form(servers);

            email_row.entry_changed.connect(() => {
                string domain = domain_of(email_row.text);
                if (domain == "") return;
                if (imap_row.text == "" || imap_row.get_data<bool>("auto")) {
                    imap_row.text = "imap." + domain;
                    imap_row.set_data<bool>("auto", true);
                }
                if (smtp_row.text == "" || smtp_row.get_data<bool>("auto")) {
                    smtp_row.text = "smtp." + domain;
                    smtp_row.set_data<bool>("auto", true);
                }
            });
            imap_row.entry_changed.connect(() => {
                if (imap_row.text != "imap." + domain_of(email_row.text)) imap_row.set_data<bool>("auto", false);
            });
            smtp_row.entry_changed.connect(() => {
                if (smtp_row.text != "smtp." + domain_of(email_row.text)) smtp_row.set_data<bool>("auto", false);
            });
        }

        private void build_proton_form() {
            var bridge = new PreferencesGroup(_("Proton Mail"),
                _("Proton Mail reaches other apps through Proton Mail Bridge. Install it, sign in there, then copy the Bridge password it shows for your address. It is not your Proton password."));
            var get_bridge = new ActionRow(_("Get Proton Mail Bridge"), "proton.me/mail/bridge", "web-browser-symbolic");
            var open_icon = new Image.from_icon_name("send-to-symbolic");
            open_icon.add_css_class("dim-label");
            get_bridge.add_suffix(open_icon);
            get_bridge.activatable = true;
            get_bridge.activated.connect(() => AccountDetailPage.open_browser("https://proton.me/mail/bridge"));
            bridge.add_row(get_bridge);
            email_row = new EmailRow(_("Proton Address"));
            bridge.add_row(email_row);
            pass_row = new PasswordRow(_("Bridge Password"));
            pass_row.entry_activated.connect(on_connect_clicked);
            bridge.add_row(pass_row);
            add_group_to_form(bridge);

            var ports = new PreferencesGroup(_("Bridge Ports"), _("Change these only if you changed them in Bridge."));
            imap_port_row = new EntryRow(_("IMAP Port"));
            imap_port_row.text = "1143";
            ports.add_row(imap_port_row);
            smtp_port_row = new EntryRow(_("SMTP Port"));
            smtp_port_row.text = "1025";
            ports.add_row(smtp_port_row);
            add_group_to_form(ports);

            var calendar = new PreferencesGroup(_("Proton Calendar"),
                _("Optional. In Proton Calendar open Settings, Calendars, Share with anyone, and copy the link. Events appear read-only and update every 30 minutes."));
            calendar_link_row = new EntryRow(_("Calendar Link"));
            calendar.add_row(calendar_link_row);
            add_group_to_form(calendar);
        }

        private void append_footer() {
            error_label = new Label("");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.xalign = 0;
            error_label.margin_top = 12;
            error_label.margin_start = 12;
            error_label.margin_end = 12;
            form_box.append(error_label);

            connect_btn = new Button.with_label(browser_flow ? _("Sign In") : _("Connect"));
            connect_btn.add_css_class("suggested-action");
            connect_btn.add_css_class("pill");
            connect_btn.halign = Align.CENTER;
            connect_btn.margin_top = 24;
            connect_btn.margin_bottom = 12;
            connect_btn.clicked.connect(on_connect_clicked);
            form_box.append(connect_btn);
        }

        private static string domain_of(string address) {
            int at = address.strip().index_of("@");
            return at < 0 ? "" : address.strip().substring(at + 1);
        }

        private static bool valid_address(string address) {
            string a = address.strip();
            int at = a.index_of("@");
            return at > 0 && a.index_of(".", at) > at + 1 && !a.has_suffix(".");
        }

        private static void split_host(string text, out string host, out string port) {
            host = text.strip();
            port = "";
            int colon = host.last_index_of(":");
            if (colon > 0 && !host.contains("]")) {
                port = host.substring(colon + 1);
                host = host.substring(0, colon);
            }
        }

        private void on_connect_clicked() {
            if (!connect_btn.sensitive) return;
            error_label.label = "";
            var settings = new HashTable<string, Variant>(str_hash, str_equal);
            string secret = pass_row != null ? pass_row.text : "";
            switch (selected_provider) {
                case "nextcloud":
                    settings.insert("server", server_row.text.strip());
                    if (user_row.text.strip() != "" && secret != "") {
                        settings.insert("username", user_row.text.strip());
                        add_password_account.begin("nextcloud", settings, secret);
                    } else {
                        if (server_row.text.strip() == "" || server_row.text.strip() == "https://") {
                            error_label.label = _("Enter the server address");
                            return;
                        }
                        start_browser_flow.begin("nextcloud", settings);
                    }
                    return;
                case "google":
                case "microsoft":
                    if (browser_flow) {
                        start_browser_flow.begin(selected_provider, settings);
                    } else if (selected_provider == "google") {
                        if (!valid_address(email_row.text) || secret == "") {
                            error_label.label = _("Enter your Gmail address and the app password");
                            return;
                        }
                        settings.insert("email", email_row.text.strip());
                        add_password_account.begin("google", settings, secret);
                    }
                    return;
                case "exchange":
                    if (!valid_address(email_row.text) || secret == "") {
                        error_label.label = _("Enter your address and password");
                        return;
                    }
                    settings.insert("email", email_row.text.strip());
                    if (server_row.text.strip() != "") settings.insert("server", server_row.text.strip());
                    if (user_row.text.strip() != "") settings.insert("username", user_row.text.strip());
                    if (imap_row.text.strip() != "" && smtp_row.text.strip() != "") {
                        string h, p;
                        split_host(imap_row.text, out h, out p);
                        settings.insert("imap-host", h);
                        if (p != "") settings.insert("imap-port", p);
                        split_host(smtp_row.text, out h, out p);
                        settings.insert("smtp-host", h);
                        if (p != "") settings.insert("smtp-port", p);
                    }
                    add_password_account.begin("exchange", settings, secret);
                    return;
                case "imap": {
                    if (!valid_address(email_row.text) || secret == "" || imap_row.text.strip() == "" || smtp_row.text.strip() == "") {
                        error_label.label = _("Please fill in all fields");
                        return;
                    }
                    settings.insert("email", email_row.text.strip());
                    settings.insert("name", name_row.text.strip());
                    if (mail_user_row.text.strip() != "") settings.insert("username", mail_user_row.text.strip());
                    string security = security_row.current_value == _("STARTTLS") ? "starttls" : security_row.current_value == _("None") ? "none" : "tls";
                    string h, p;
                    split_host(imap_row.text, out h, out p);
                    settings.insert("imap-host", h);
                    if (p != "") settings.insert("imap-port", p);
                    settings.insert("imap-security", security);
                    split_host(smtp_row.text, out h, out p);
                    settings.insert("smtp-host", h);
                    if (p != "") settings.insert("smtp-port", p);
                    settings.insert("smtp-security", security);
                    add_password_account.begin("imap", settings, secret);
                    return;
                }
                case "proton":
                    perform_proton.begin();
                    return;
                case "spotify":
                    if (browser_flow) start_browser_flow.begin("spotify", settings);
                    return;
                case "listenbrainz":
                    if (secret.strip() == "") {
                        error_label.label = _("Enter your ListenBrainz user token");
                        return;
                    }
                    settings.insert("server", server_row.text.strip());
                    add_password_account.begin("listenbrainz", settings, secret.strip());
                    return;
                default:
                    if (server_row.text.strip() == "" || user_row.text.strip() == "" || secret == "") {
                        error_label.label = _("Please fill in all fields");
                        return;
                    }
                    settings.insert("server", server_row.text.strip());
                    settings.insert("username", user_row.text.strip());
                    add_password_account.begin(selected_provider, settings, secret);
                    return;
            }
        }

        private async void add_password_account(string provider, HashTable<string, Variant> settings, string secret) {
            connect_btn.sensitive = false;
            error_label.label = _("Connecting…");
            try {
                string id = yield Manager.get_default().add_account(provider, settings, secret);
                finish_success(id);
            } catch (Error e) {
                error_label.label = AccountDetailPage.friendly(e);
            }
            connect_btn.sensitive = true;
        }

        private async void perform_proton() {
            string address = email_row.text.strip();
            string password = pass_row.text;
            string link = calendar_link_row.text.strip();
            bool wants_mail = address != "" || password != "";
            if (!wants_mail && link == "") {
                error_label.label = _("Enter your Proton address and Bridge password, a calendar link, or both");
                return;
            }
            if (wants_mail && (!valid_address(address) || password == "")) {
                error_label.label = _("Enter your Proton address and the Bridge password");
                return;
            }
            uint64 imap_port = 0, smtp_port = 0;
            if (!uint64.try_parse(imap_port_row.text.strip(), out imap_port) || imap_port == 0 || imap_port > 65535
                || !uint64.try_parse(smtp_port_row.text.strip(), out smtp_port) || smtp_port == 0 || smtp_port > 65535) {
                error_label.label = _("The Bridge ports must be numbers between 1 and 65535");
                return;
            }
            connect_btn.sensitive = false;
            error_label.label = _("Connecting…");
            string account_id = "";
            if (wants_mail) {
                var settings = new HashTable<string, Variant>(str_hash, str_equal);
                settings.insert("email", address);
                settings.insert("imap-host", "127.0.0.1");
                settings.insert("imap-port", imap_port.to_string());
                settings.insert("imap-security", "starttls");
                settings.insert("smtp-host", "127.0.0.1");
                settings.insert("smtp-port", smtp_port.to_string());
                settings.insert("smtp-security", "starttls");
                try {
                    account_id = yield Manager.get_default().add_account("proton", settings, password);
                } catch (Error e) {
                    string msg = AccountDetailPage.friendly(e);
                    error_label.label = msg.contains("127.0.0.1")
                        ? _("Proton Mail Bridge is not running on this computer. Start Bridge, sign in, and try again.")
                        : msg;
                    connect_btn.sensitive = true;
                    return;
                }
            }
            if (link != "") {
                try {
                    yield Singularity.Calendar.WebCalendarProvider.subscribe(
                        Singularity.Calendar.CalendarManager.get_default(), _("Proton Calendar"), link);
                } catch (Error e) {
                    error_label.label = wants_mail
                        ? _("The mail account was added, but the calendar link did not work: %s").printf(e.message)
                        : _("The calendar link did not work: %s").printf(e.message);
                    connect_btn.sensitive = true;
                    return;
                }
            }
            connect_btn.sensitive = true;
            if (account_id != "") finish_success(account_id);
            else view.navigate_to("accounts");
        }

        private SidebarWaitTicket? wait_ticket = null;

        private async void start_browser_flow(string provider, HashTable<string, Variant> settings) {
            connect_btn.sensitive = false;
            error_label.label = _("Starting the sign-in…");
            try {
                string url;
                flow_id = yield Manager.get_default().begin_sign_in(provider, settings, out url);
                flow_url = url;
                in_window = yield Manager.get_default().open_sign_in_window(flow_id, url, selected_name, providers.has_key(selected_provider) ? providers[selected_provider].icon_name : "");
                show_waiting();
                if (wait_ticket != null) wait_ticket.end_quietly();
                wait_ticket = SidebarWait.get_default().begin(this, _("Waiting for %s").printf(selected_name),
                    "web-browser-symbolic", () => {
                        cancel_flow();
                        error_label.label = "";
                        inner_stack.visible_child_name = "form";
                    }, true);
                if (!in_window) AccountDetailPage.open_browser(url);
            } catch (Error e) {
                error_label.label = AccountDetailPage.friendly(e);
            }
            connect_btn.sensitive = true;
        }

        private bool in_window = false;

        private void end_wait(string? page = null) {
            if (wait_ticket == null) return;
            var t = wait_ticket;
            wait_ticket = null;
            t.end(page);
        }

        private void show_waiting() {
            Widget? child;
            while ((child = waiting_box.get_first_child()) != null) waiting_box.remove(child);
            waiting_box.append(provider_header(selected_provider, selected_name));
            var group = in_window
                ? new PreferencesGroup(_("Sign-In Window"),
                    _("Finish signing in in the window that opened. This page continues by itself."))
                : new PreferencesGroup(_("Waiting for Your Browser"),
                    _("Finish signing in on the page that opened in your browser. This page continues by itself."));
            var spinner_row = new ActionRow(_("Waiting for %s").printf(selected_name),
                in_window ? _("The window shows the real address of the sign-in page") : _("You can switch to the browser now"),
                in_window ? "dialog-password-symbolic" : "web-browser-symbolic");
            var spinner = new Spinner();
            spinner.spinning = true;
            spinner.valign = Align.CENTER;
            spinner_row.add_suffix(spinner);
            group.add_row(spinner_row);
            SignInPasteGroup? paste = null;
            if (selected_provider == "google" || selected_provider == "microsoft") {
                paste = new SignInPasteGroup(() => flow_id);
                paste.margin_top = 12;
                paste.visible = !in_window;
            }
            if (in_window && paste != null) {
                var shown_paste = paste;
                ulong h = 0;
                h = Manager.get_default().sign_in_window_closed.connect((flow, browser) => {
                    if (flow != flow_id) return;
                    Manager.get_default().disconnect(h);
                    if (browser) shown_paste.visible = true;
                });
            }
            if (in_window) {
                var external = new ActionRow(_("Open in Your Browser Instead"), _("Use this if the sign-in window does not work for you"), "web-browser-symbolic");
                external.activatable = true;
                external.activated.connect(() => {
                    AccountDetailPage.open_browser(flow_url);
                    if (paste != null) paste.visible = true;
                });
                group.add_row(external);
            } else {
                var again = new ActionRow(_("Open the Sign-In Page Again"), _("Use this if the browser did not open"), "view-refresh-symbolic");
                again.activatable = true;
                again.activated.connect(() => AccountDetailPage.open_browser(flow_url));
                group.add_row(again);
            }
            group.margin_top = 12;
            waiting_box.append(group);
            if (paste != null) waiting_box.append(paste);
            var cancel = new Button.with_label(_("Cancel"));
            cancel.add_css_class("pill");
            cancel.halign = Align.CENTER;
            cancel.margin_top = 24;
            cancel.clicked.connect(() => {
                cancel_flow();
                error_label.label = "";
                inner_stack.visible_child_name = "form";
                if (wait_ticket != null) {
                    wait_ticket.end_quietly();
                    wait_ticket = null;
                }
            });
            waiting_box.append(cancel);
            inner_stack.visible_child_name = "waiting";
        }

        private void cancel_flow() {
            if (flow_id == "") return;
            string id = flow_id;
            flow_id = "";
            Manager.get_default().cancel_sign_in.begin(id);
        }

        private void on_flow_finished(string flow, string account_id, string error_message) {
            if (flow != flow_id || flow == "") return;
            flow_id = "";
            if (error_message != "" || account_id == "") {
                inner_stack.visible_child_name = "form";
                error_label.label = error_message != "" ? error_message : _("The sign-in failed.");
                end_wait();
                return;
            }
            finish_success(account_id);
        }

        private void finish_success(string account_id) {
            account_added();
            var manager = Manager.get_default();
            var account = manager.get_account(account_id);
            if (account == null) {
                manager.reload.begin((obj, res) => {
                    manager.reload.end(res);
                    var a = manager.get_account(account_id);
                    if (a != null) {
                        view.open_subpage(new AccountDetailPage(view, a), "account-" + account_id);
                        end_wait("account-" + account_id);
                    } else {
                        view.navigate_to("accounts");
                        end_wait("accounts");
                    }
                });
                return;
            }
            view.open_subpage(new AccountDetailPage(view, account), "account-" + account_id);
            end_wait("account-" + account_id);
        }
    }

    public delegate string SignInFlowGetter();

    public class SignInPasteGroup : PreferencesGroup {
        private EntryRow address_row;
        private Label status;
        private Button go;
        private SignInFlowGetter flow;

        public SignInPasteGroup(owned SignInFlowGetter flow) {
            base(_("Browser Shows an Error"),
                _("If your browser shows an error page after you approve, copy its address here."));
            this.flow = (owned) flow;
            address_row = new EntryRow(_("Address From Your Browser"));
            address_row.entry_activated.connect(submit);
            add_row(address_row);
            var action = new ActionRow(_("Finish Signing In"), _("Uses the approval in that address"), null);
            go = new Button.with_label(_("Continue"));
            go.valign = Align.CENTER;
            go.clicked.connect(submit);
            action.add_suffix(go);
            add_row(action);
            status = new Label("");
            status.add_css_class("error");
            status.wrap = true;
            status.xalign = 0;
            status.margin_start = 12;
            status.margin_top = 6;
            status.visible = false;
            add_row(status);
        }

        private void submit() {
            string text = address_row.text.strip();
            string id = flow();
            if (text == "" || id == "") return;
            go.sensitive = false;
            status.visible = false;
            Manager.get_default().complete_sign_in.begin(id, text, (obj, res) => {
                try {
                    Manager.get_default().complete_sign_in.end(res);
                } catch (Error e) {
                    status.label = AccountDetailPage.friendly(e);
                    status.visible = true;
                }
                go.sensitive = true;
            });
        }
    }
}
