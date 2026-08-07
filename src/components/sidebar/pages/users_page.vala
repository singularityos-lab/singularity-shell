using Gtk;
using Singularity.Widgets;
using Singularity.Core.Users;
using Polkit;

// crypt(3) lives in crypt.h on glibc+libxcrypt (the vala posix binding points
// at unistd.h, which no longer declares it), so bind it directly here.
[CCode (cname = "crypt", cheader_filename = "crypt.h")]
private extern unowned string? c_crypt (string key, string salt);

namespace Singularity.SidebarPages {

    public class UsersPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup users_group;
        private Button unlock_btn;
        private Button add_btn;
        private AccountsService service;
        private bool is_locked = true;
        private Polkit.Permission? permission;
        private Gee.HashMap<string, ActionRow> user_rows = new Gee.HashMap<string, ActionRow>();

        public UsersPage(SettingsView view) {
            base(_("Users"));
            this.view = view;
            back_clicked.connect(() => view.go_home());

            // Header: lock/unlock + add
            unlock_btn = new Button.from_icon_name("changes-prevent-symbolic");
            unlock_btn.tooltip_text = _("Unlock to make changes");
            unlock_btn.add_css_class("navigation-button");
            unlock_btn.clicked.connect(on_unlock_clicked);
            header.append(unlock_btn);

            add_btn = new Button.from_icon_name("list-add-symbolic");
            add_btn.tooltip_text = _("Add User");
            add_btn.add_css_class("navigation-button");
            add_btn.sensitive = false;
            add_btn.clicked.connect(on_add_user_clicked);
            header.append(add_btn);

            users_group = new PreferencesGroup(_("System Users"));
            add_group(users_group);

            service = AccountsService.get_default();
            service.user_added.connect(on_user_added);
            service.user_removed.connect(on_user_removed);
            load_users.begin();
            init_permission.begin();
        }

        private async void init_permission() {
            try {
                permission = (Polkit.Permission) new Polkit.Permission.sync(
                    "org.freedesktop.accounts.user-administration", null, null);
                permission.notify["allowed"].connect(update_lock_state);
                update_lock_state();
            } catch (GLib.Error e) {
                warning("Failed to acquire permission object: %s", e.message);
                update_lock_state();
            }
        }

        private void update_lock_state() {
            is_locked = (permission == null) ? true : !permission.allowed;
            unlock_btn.icon_name = is_locked ? "changes-prevent-symbolic" : "changes-allow-symbolic";
            unlock_btn.tooltip_text = is_locked ? _("Unlock to make changes") : _("Lock settings");
            add_btn.sensitive = !is_locked;
            foreach (var row in user_rows.values) {
                var del_btn = row.get_data<Button>("del_btn");
                if (del_btn != null) del_btn.visible = !is_locked;
                var chevron = row.get_data<Image>("chevron");
                bool self = row.get_data<bool>("is_self");
                if (chevron != null) chevron.visible = self || !is_locked;
            }
        }

        private void on_unlock_clicked() {
            if (permission == null) return;
            if (is_locked) {
                permission.acquire_async.begin(null, (obj, res) => {
                    try { permission.acquire_async.end(res); } catch (GLib.Error e) {
                        warning("Failed to acquire permission: %s", e.message);
                    }
                });
            } else {
                permission.release_async.begin(null, (obj, res) => {
                    try { permission.release_async.end(res); } catch (GLib.Error e) {
                        warning("Failed to release permission: %s", e.message);
                    }
                });
            }
        }

        private async void load_users() {
            var users = yield service.list_users();
            foreach (var user in users) add_user_row(user);
        }

        private void on_user_added(AccountUser user) { add_user_row(user); }

        private void on_user_removed(AccountUser user) {
            var row = user_rows[user.uid.to_string()];
            if (row != null) {
                users_group.remove_row(row);
                user_rows.unset(user.uid.to_string());
            }
        }

        private void add_user_row(AccountUser user) {
            string display = user.real_name != "" ? user.real_name : user.user_name;
            string type_str = (user.account_type == 1) ? "Administrator" : "Standard";
            var row = new ActionRow(display, type_str, "avatar-default-symbolic");
            row.subtitle = user.user_name;
            row.activatable = true;
            user_rows[user.uid.to_string()] = row;

            // Changing your OWN PIN needs no admin unlock: the change-pin polkit action
            // is allow_active=yes and the dialog re-authenticates with the current PIN.
            // Keep the current user's row reachable even while locked so a forgotten
            // unlock never forces the recovery-key path just to set a new PIN.
            bool is_self = user.user_name == Environment.get_user_name();
            row.set_data("is_self", is_self);

            // Chevron - visible when unlocked, or always for the current user (self-service).
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            chevron.add_css_class("dim-label");
            chevron.visible = is_self || !is_locked;
            chevron.valign = Align.CENTER;
            row.set_data("chevron", chevron);
            row.add_suffix(chevron);

            row.activated.connect(() => {
                if (is_locked && !is_self) return;
                var detail = new UserDetailPage(view, user, service, this);
                detail.admin_unlocked = !is_locked;
                detail.self_account = is_self;
                view.open_subpage(detail, "user-detail-%s".printf(user.uid.to_string()));
            });

            users_group.add_row(row);
        }

        private void on_add_user_clicked() {
            var add_page = new AddUserPage(view, service, this);
            view.open_subpage(add_page, "user-add");
        }

        // Called by detail/add pages to refresh the list
        public void refresh() {
            foreach (var row in user_rows.values) users_group.remove_row(row);
            user_rows.clear();
            load_users.begin();
        }
    }


    // Inline user detail page

    public class UserDetailPage : SettingsPage {
        private SettingsView view;
        private AccountUser user;
        private AccountsService service;
        private UsersPage parent_page;
        private Gee.ArrayList<Avatar> avatar_widgets;

        // admin_unlocked: the admin padlock is open, so administrative controls
        // (account type, account lock, remove) are shown. self_account: this is the
        // signed-in user, who can always change their own PIN without that unlock.
        public bool admin_unlocked = false;
        public bool self_account = false;

        public UserDetailPage(SettingsView view, AccountUser user,
                               AccountsService service, UsersPage parent) {
            base(user.real_name != "" ? user.real_name : user.user_name);
            this.view = view;
            this.user = user;
            this.service = service;
            this.parent_page = parent;
            back_clicked.connect(() => view.navigate_to("users"));
            build_ui();
        }

        private void build_ui() {
            var pic_group = build_avatar_picker();
            if (pic_group != null) add_group(pic_group);

            // User info card
            var info_group = new PreferencesGroup("");
            var name_row  = new ActionRow(_("Full Name"), "", null);
            name_row.subtitle = user.real_name != "" ? user.real_name : _("(not set)");
            var uname_row = new ActionRow(_("Username"), "", null);
            uname_row.subtitle = user.user_name;
            var home_row  = new ActionRow(_("Home"), "", null);
            home_row.subtitle = user.home_directory;
            var shell_row = new ActionRow(_("Shell"), "", null);
            shell_row.subtitle = user.shell;
            info_group.add_row(name_row);
            info_group.add_row(uname_row);
            info_group.add_row(home_row);
            info_group.add_row(shell_row);
            add_group(info_group);

            // Account type and the login-lock switch are administrative operations:
            // shown only when the admin padlock is open (self-service PIN change below
            // never needs it).
            if (admin_unlocked) {
                var type_group = new PreferencesGroup(_("Account"));
                string[] type_labels = { "Standard", "Administrator" };
                var type_row = new SelectionRow(_("Account Type"), type_labels, type_labels[(int)user.account_type]);
                type_row.selected.connect((item) => {
                    set_account_type.begin(item == "Administrator" ? 1 : 0);
                });
                type_group.add_row(type_row);

                var lock_row = new SwitchRow(_("Account Locked"), _("Prevent login"), user.locked);
                lock_row.switch_btn.notify["active"].connect(() => {
                    set_locked.begin(lock_row.switch_btn.active);
                });
                type_group.add_row(lock_row);
                add_group(type_group);
            }

            // Security: change the login credential. On Sinty OS this re-seals the
            // per-user CE key under a new PIN via the sinty-pind broker (a subpage,
            // consistent with the rest of Settings -- no floating dialog).
            var sec_group = new PreferencesGroup(_("Security"));
            string cred = Singularity.Runtime.is_sinty_os() ? _("PIN") : _("Password");
            var pin_row = new ActionRow(_("Change %s").printf(cred),
                _("Set a new %s for this account").printf(cred), "channel-secure-symbolic");
            pin_row.activatable = true;
            pin_row.activated.connect(() => {
                var page = new ChangePinPage(view, user);
                view.open_subpage(page, "change-pin-%s".printf(user.uid.to_string()));
            });
            sec_group.add_row(pin_row);
            add_group(sec_group);

            // Danger zone: removing an account is administrative -> admin unlock only.
            if (admin_unlocked) {
                var danger_group = new PreferencesGroup(_("Danger Zone"));
                var del_row = new ActionRow(_("Remove User"), _("Permanently delete this account and home folder"), "user-trash-symbolic");
                del_row.activatable = true;
                del_row.add_css_class("destructive-action-row");
                del_row.activated.connect(show_delete_confirm);
                danger_group.add_row(del_row);
                add_group(danger_group);
            }
        }

        private static string? avatars_dir() {
            foreach (var d in GLib.Environment.get_system_data_dirs()) {
                var p = Path.build_filename(d, "singularity", "avatars");
                if (FileUtils.test(p, FileTest.IS_DIR)) return p;
            }
            if (FileUtils.test("/usr/share/singularity/avatars", FileTest.IS_DIR))
                return "/usr/share/singularity/avatars";
            return null;
        }

        private PreferencesGroup? build_avatar_picker() {
            string? dir = avatars_dir();
            if (dir == null) return null;
            var ids = new Gee.ArrayList<string>();
            try {
                var en = File.new_for_path(dir).enumerate_children(
                    "standard::name", FileQueryInfoFlags.NONE);
                FileInfo fi;
                while ((fi = en.next_file()) != null) {
                    var nm = fi.get_name();
                    if (nm.has_suffix(".png")) ids.add(nm.substring(0, nm.length - 4));
                }
            } catch (GLib.Error e) {
                return null;
            }
            if (ids.size == 0) return null;
            ids.sort();

            string current = Path.get_basename(user.icon_file);
            if (current.has_suffix(".png"))
                current = current.substring(0, current.length - 4);

            var group = new PreferencesGroup(_("Picture"));
            var flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.max_children_per_line = (uint) ids.size;
            flow.column_spacing = 12;
            flow.row_spacing = 12;
            flow.halign = Align.START;
            flow.margin_top = 8;
            flow.margin_bottom = 8;
            flow.margin_start = 8;
            flow.margin_end = 8;

            avatar_widgets = new Gee.ArrayList<Avatar>();
            foreach (var id in ids) {
                string aid = id;
                string path = dir + "/" + aid + ".png";
                var av = new Avatar(64);
                av.set_from_file(path);
                av.selected = (aid == current);
                av.set_cursor_from_name("pointer");
                av.set_data<string>("aid", aid);
                var click = new GestureClick();
                click.released.connect(() => { choose_avatar(aid, path); });
                av.add_controller(click);
                avatar_widgets.add(av);
                flow.append(av);
            }

            var add_av = new Avatar(64);
            add_av.add_mode = true;
            add_av.set_cursor_from_name("pointer");
            add_av.tooltip_text = _("Choose a custom picture");
            var add_click = new GestureClick();
            add_click.released.connect(() => { pick_custom_avatar(); });
            add_av.add_controller(add_click);
            flow.append(add_av);

            var prow = new PreferencesRow();
            prow.set_child(flow);
            group.add_row(prow);
            return group;
        }

        private void choose_avatar(string id, string path) {
            foreach (var av in avatar_widgets)
                av.selected = (av.get_data<string>("aid") == id);
            apply_icon.begin(path);
        }

        private void pick_custom_avatar() {
            var app = (SingularityApp) GLib.Application.get_default();
            if (app.sidebar == null) return;
            app.sidebar.open_file_picker(_("Images"),
                { "*.png", "*.jpg", "*.jpeg", "*.webp" }, (file) => {
                    var path = file.get_path();
                    if (path != null) {
                        foreach (var av in avatar_widgets) av.selected = false;
                        apply_icon.begin(path);
                    }
                });
        }

        private async void apply_icon(string path) {
            try { yield user.set_icon_file(path); } catch (GLib.Error e) {
                warning("set_icon_file: %s", e.message);
            }
        }

        private async void set_account_type(int t) {
            try { yield user.set_account_type(t); } catch (GLib.Error e) {
                warning("set_account_type: %s", e.message);
            }
        }

        private async void set_locked(bool locked) {
            try { yield user.set_locked(locked); } catch (GLib.Error e) {
                warning("set_locked: %s", e.message);
            }
        }

        private void show_delete_confirm() {
            // Replace page content with inline confirmation
            var confirm_group = new PreferencesGroup(_("Confirm deletion"));
            var msg = new ActionRow(
                "Delete %s?".printf(user.user_name),
                "This will permanently remove the account and all its files.",
                "dialog-warning-symbolic");
            confirm_group.add_row(msg);

            var btn_row = new Box(Orientation.HORIZONTAL, 12);
            btn_row.halign = Align.CENTER;
            btn_row.margin_top = 8;
            btn_row.margin_bottom = 8;

            var cancel = new Button.with_label(_("Cancel"));
            cancel.add_css_class("pill");
            cancel.clicked.connect(() => view.navigate_to("users"));
            btn_row.append(cancel);

            var del = new Button.with_label(_("Delete Account"));
            del.add_css_class("pill");
            del.add_css_class("destructive-action");
            del.clicked.connect(() => do_delete.begin());
            btn_row.append(del);

            var btn_pref_row = new PreferencesRow();
            btn_pref_row.set_child(btn_row);
            confirm_group.add_row(btn_pref_row);
            add_group(confirm_group);
        }

        private async void do_delete() {
            try {
                yield service.delete_user(user, true);
                parent_page.refresh();
                view.navigate_to("users");
            } catch (GLib.Error e) {
                warning("delete_user: %s", e.message);
            }
        }
    }


    // Inline add-user page

    public class AddUserPage : SettingsPage {
        private SettingsView view;
        private AccountsService service;
        private UsersPage parent_page;
        private EntryRow fullname_row;
        private EntryRow username_row;
        private PasswordRow password_row;
        private SelectionRow type_row;
        private Label error_label;
        private Button create_btn;

        public AddUserPage(SettingsView view, AccountsService service, UsersPage parent) {
            base(_("Add User"));
            this.view = view;
            this.service = service;
            this.parent_page = parent;
            back_clicked.connect(() => view.navigate_to("users"));
            build_ui();
        }

        private void build_ui() {
            var group = new PreferencesGroup(_("New Account"));
            fullname_row  = new EntryRow("Full Name");
            username_row  = new EntryRow("Username");
            password_row  = new PasswordRow(Singularity.Runtime.is_sinty_os() ? "PIN" : "Password");
            string[] types = { "Standard", "Administrator" };
            type_row = new SelectionRow(_("Account Type"), types, _("Standard"));

            fullname_row.entry_changed.connect(() => {
                if (username_row.text == "") {
                    username_row.text = fullname_row.text.down().replace(" ", "");
                }
            });

            group.add_row(fullname_row);
            group.add_row(username_row);
            group.add_row(password_row);
            group.add_row(type_row);
            add_group(group);

            error_label = new Label("");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.visible = false;
            error_label.margin_start = 16;
            error_label.margin_end = 16;
            error_label.halign = Align.START;

            var err_wrapper = new Box(Orientation.VERTICAL, 0);
            err_wrapper.append(error_label);
            add_widget(err_wrapper);

            create_btn = new Button.with_label(_("Create User"));
            create_btn.add_css_class("suggested-action");
            create_btn.add_css_class("pill");
            create_btn.halign = Align.CENTER;
            create_btn.margin_top = 8;
            create_btn.clicked.connect(() => on_create.begin());
            add_widget(create_btn);
        }

        private async void on_create() {
            string fullname = fullname_row.text.strip();
            string username = username_row.text.strip();
            string password = password_row.text;
            int type = type_row.current_value == "Administrator" ? 1 : 0;

            if (fullname == "" || username == "" || password == "") {
                error_label.label = _("Fill in all fields");
                error_label.visible = true;
                return;
            }

            create_btn.sensitive = false;
            error_label.visible = false;

            string? crypted = crypt_password(password);
            if (crypted == null) {
                error_label.label = _("Failed to hash password");
                error_label.visible = true;
                create_btn.sensitive = true;
                return;
            }

            try {
                var user = yield service.create_user(username, fullname, type);
                if (user != null) {
                    yield user.set_password(crypted, "");
                    parent_page.refresh();
                    view.navigate_to("users");
                } else {
                    error_label.label = _("Failed to create user");
                    error_label.visible = true;
                    create_btn.sensitive = true;
                }
            } catch (GLib.Error e) {
                error_label.label = e.message;
                error_label.visible = true;
                create_btn.sensitive = true;
            }
        }

        // AccountsService SetPassword expects a crypt(3) hash, not plaintext.
        // Hash with SHA-512 crypt and a random salt; returns null on failure.
        private static string? crypt_password(string plain) {
            const string SALT_CHARS = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
            var salt = new StringBuilder("$6$");
            for (int i = 0; i < 16; i++)
                salt.append_c(SALT_CHARS[Random.int_range(0, SALT_CHARS.length)]);
            salt.append_c('$');
            unowned string? hashed = c_crypt(plain, salt.str);
            return hashed;
        }
    }

    // Change the signed-in user's PIN as an in-shell subpage (consistent with the
    // rest of Settings), using the same libsingularity rows as everywhere else.
    // The re-seal goes through the sinty-pind broker over a peercred socket, so it
    // needs no admin unlock and no polkit -- the current PIN is the authorisation.
    public class ChangePinPage : SettingsPage {
        private SettingsView view;
        private AccountUser user;
        private PasswordRow cur_row;
        private PasswordRow new_row;
        private PasswordRow con_row;
        private Label error_label;
        private Button change_btn;

        public ChangePinPage(SettingsView view, AccountUser user) {
            base(_("Change %s").printf(Singularity.Runtime.is_sinty_os() ? _("PIN") : _("Password")));
            this.view = view;
            this.user = user;
            back_clicked.connect(() => view.navigate_to("user-detail-%s".printf(user.uid.to_string())));
            build_ui();
        }

        private void build_ui() {
            string cred = Singularity.Runtime.is_sinty_os() ? _("PIN") : _("Password");
            var group = new PreferencesGroup(_("Security"));
            cur_row = new PasswordRow(_("Current %s").printf(cred));
            new_row = new PasswordRow(_("New %s").printf(cred));
            con_row = new PasswordRow(_("Confirm new %s").printf(cred));
            group.add_row(cur_row);
            group.add_row(new_row);
            group.add_row(con_row);
            add_group(group);

            error_label = new Label("");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.visible = false;
            error_label.margin_start = 16;
            error_label.margin_end = 16;
            error_label.halign = Align.START;
            var err_wrapper = new Box(Orientation.VERTICAL, 0);
            err_wrapper.append(error_label);
            add_widget(err_wrapper);

            change_btn = new Button.with_label(_("Change %s").printf(cred));
            change_btn.add_css_class("suggested-action");
            change_btn.add_css_class("pill");
            change_btn.halign = Align.CENTER;
            change_btn.margin_top = 8;
            change_btn.clicked.connect(on_change);
            add_widget(change_btn);

            con_row.entry_activated.connect(on_change);
        }

        private void on_change() {
            bool is_pin = Singularity.Runtime.is_sinty_os();
            string cur = cur_row.text, neu = new_row.text, con = con_row.text;
            if (cur == "" || neu == "") {
                error_label.label = _("Fill in all fields");
                error_label.visible = true;
                return;
            }
            if (neu != con) {
                error_label.label = is_pin ? _("The new PINs do not match")
                                           : _("The new passwords do not match");
                error_label.visible = true;
                return;
            }
            change_btn.sensitive = false;
            error_label.visible = false;
            try {
                // sinty-pind: identity comes from SO_PEERCRED (our own uid), the current
                // PIN is the authorisation. No admin unlock, no polkit, no logind-active.
                var sock = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
                sock.set_timeout(5);
                sock.connect(new UnixSocketAddress("/run/sinty-pind.sock"), null);
                var conn = SocketConnection.factory_create_connection(sock);
                size_t written;
                conn.output_stream.write_all("%s\n%s\n".printf(cur, neu).data, out written, null);
                var reply = new DataInputStream(conn.input_stream);
                string? line = reply.read_line_utf8(null, null);
                conn.close();
                if (line != null && line.strip() == "OK") {
                    view.navigate_to("user-detail-%s".printf(user.uid.to_string()));
                } else {
                    string reason = (line ?? "").strip();
                    if (reason.has_prefix("FAIL:")) reason = reason.substring(5).strip();
                    error_label.label = reason != "" ? reason
                        : (is_pin ? _("Could not change the PIN. Is the current PIN correct?")
                                  : _("Could not change the password. Is the current password correct?"));
                    error_label.visible = true;
                    change_btn.sensitive = true;
                }
            } catch (GLib.Error e) {
                error_label.label = e.message;
                error_label.visible = true;
                change_btn.sensitive = true;
            }
        }
    }
}

