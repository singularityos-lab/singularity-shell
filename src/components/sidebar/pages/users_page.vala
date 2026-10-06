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

            if (LoginScreenSync.available()) add_group(build_login_screen_group());
            var fingerprint_group = build_fingerprint_group();
            fingerprint_group.visible = false;
            add_group(fingerprint_group);

            service = AccountsService.get_default();
            service.user_added.connect(on_user_added);
            service.user_removed.connect(on_user_removed);
            load_users.begin();
            init_permission.begin();
        }

        private PreferencesGroup build_fingerprint_group() {
            var manager = new FingerprintManager();
            var group = new PreferencesGroup(_("Fingerprint"));
            group.description = _("Unlock the screen with your fingerprint. After a restart your password is needed once, because it also unlocks your keyring and encrypted data.");

            var status_row = new ActionRow(_("Fingerprint Unlock"), "");
            status_row.activatable = false;
            group.add_row(status_row);

            var add_row = new ActionRow(_("Add Fingerprint"), _("Enroll another finger"));
            var add_btn = new Button.with_label(_("Add"));
            add_btn.valign = Align.CENTER;
            add_row.add_suffix(add_btn);
            group.add_row(add_row);

            var enroll_row = new FingerprintEnrollRow(manager);
            enroll_row.visible = false;
            group.add_row(enroll_row);

            var remove_row = new ActionRow(_("Remove All Fingerprints"), _("Unlock only with your password"));
            var remove_btn = new Button.with_label(_("Remove"));
            remove_btn.add_css_class("destructive-action");
            remove_btn.valign = Align.CENTER;
            remove_row.add_suffix(remove_btn);
            remove_btn.clicked.connect(() => remove_row.activated());
            remove_row.activated.connect(() => {
                remove_row.confirmation_requested(_("Remove"), _("Cancel"), ConfirmationSuggestedAction.CANCEL);
            });
            group.add_row(remove_row);

            Callback refresh = () => {
                manager.enrolled.begin((obj, res) => {
                    int count = manager.enrolled.end(res).length;
                    status_row.subtitle = count == 0 ? _("No fingerprints enrolled")
                        : ngettext("%d finger enrolled", "%d fingers enrolled", count).printf(count);
                    remove_row.visible = count > 0;
                });
            };
            manager.finished.connect(() => refresh());
            add_btn.clicked.connect(() => {
                add_btn.visible = false;
                enroll_row.visible = true;
                enroll_row.start();
            });
            enroll_row.closed.connect(() => {
                enroll_row.visible = false;
                add_btn.visible = true;
                refresh();
            });
            remove_row.confirmed.connect(() => {
                manager.remove_all.begin((obj, res) => {
                    manager.remove_all.end(res);
                    add_row.subtitle = _("Enroll another finger");
                    refresh();
                });
            });
            var driver_row = new ActionRow(_("Install the Manufacturer's Driver"), "");
            var driver_spinner = new Spinner();
            driver_spinner.valign = Align.CENTER;
            driver_spinner.visible = false;
            var driver_btn = new Button.with_label(_("Install"));
            driver_btn.valign = Align.CENTER;
            driver_row.add_suffix(driver_spinner);
            driver_row.add_suffix(driver_btn);
            driver_row.visible = false;
            driver_row.activated.connect(() => {
                if (driver_btn.visible) driver_btn.clicked();
            });
            group.add_row(driver_row);

            FingerprintDriver? driver = null;
            Callback show_driver = () => {
                driver_spinner.visible = false;
                driver_spinner.spinning = false;
                driver_btn.visible = true;
                driver_btn.sensitive = true;
                driver_row.visible = true;
                if (driver.installed) {
                    driver_row.title = _("Manufacturer's Driver");
                    driver_row.subtitle = _("%s %s from %s").printf(driver.name, driver.version, driver.vendor);
                    driver_btn.label = _("Remove");
                    driver_btn.remove_css_class("suggested-action");
                } else {
                    driver_row.title = _("Install the Manufacturer's Driver");
                    driver_row.subtitle = _("%s, downloaded from %s").printf(driver.vendor, driver.host);
                    driver_btn.label = _("Install");
                    driver_btn.add_css_class("suggested-action");
                }
            };
            Callback show_ready = () => {
                status_row.visible = true;
                add_row.visible = true;
                group.visible = true;
                refresh();
            };
            Callback show_unsupported = () => {
                add_row.visible = false;
                remove_row.visible = false;
                group.visible = true;
                string sensor = driver != null ? driver.id : (FingerprintManager.unsupported_sensor() ?? "");
                if (driver != null && driver.installed) {
                    status_row.subtitle = _("The driver for fingerprint reader %s is installed. Restart the computer to use it.").printf(sensor);
                } else {
                    status_row.subtitle = _("Fingerprint reader %s needs its manufacturer's driver").printf(sensor);
                }
            };
            Callback reprobe = () => {
                driver_row.subtitle = _("Starting the fingerprint service...");
                start_fprintd.begin((o, r) => {
                    start_fprintd.end(r);
                    manager.probe.begin((o2, r2) => {
                        bool now_ready = manager.probe.end(r2);
                        show_driver();
                        if (now_ready) {
                            show_ready();
                        } else {
                            show_unsupported();
                        }
                    });
                });
            };
            driver_btn.clicked.connect(() => {
                if (driver == null) return;
                bool removing = driver.installed;
                var app = GLib.Application.get_default() as Gtk.Application;
                ConfirmDialog dialog;
                if (removing) {
                    dialog = new ConfirmDialog(app, _("Remove the Manufacturer's Driver?"), "user-trash-symbolic",
                        _("The fingerprint reader stops working until the driver is installed again. Enrolled fingerprints are kept."),
                        _("Remove"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
                } else {
                    dialog = new ConfirmDialog(app, _("Install the Manufacturer's Driver?"), "dialog-warning-symbolic",
                        _("%s is proprietary software from %s. It is not part of Singularity, its source code is not available, and Singularity cannot review or update it.").printf(driver.name, driver.vendor),
                        _("Install"), ConfirmDialog.ActionStyle.SUGGESTED);
                    string[] details = {
                        _("Downloaded from: %s, where the vendor publishes it").printf(driver.host),
                        _("Installed as a Singularity driver plugin. No system packages are installed or changed."),
                        _("Version: %s, %s").printf(driver.version, GLib.format_size((uint64) driver.size)),
                        _("License: %s").printf(driver.license),
                        _("The download is checked against a known fingerprint before anything is installed."),
                    };
                    foreach (string text in details) {
                        var label = new Label(text);
                        label.wrap = true;
                        label.max_width_chars = 42;
                        label.xalign = 0;
                        label.add_css_class("dim-label");
                        dialog.custom_area.append(label);
                    }
                }
                dialog.response.connect((r) => {
                    if (r != ConfirmDialog.Response.PRIMARY) return;
                    driver_btn.visible = false;
                    driver_spinner.visible = true;
                    driver_spinner.spinning = true;
                    driver_row.subtitle = removing ? _("Removing the driver...") : _("Downloading and installing the driver...");
                    AsyncReadyCallback done = (o, r2) => {
                        try {
                            if (removing) {
                                driver.uninstall.end(r2);
                            } else {
                                driver.install.end(r2);
                            }
                            reprobe();
                        } catch (GLib.Error e) {
                            show_driver();
                            if (!(e is IOError.CANCELLED)) driver_row.subtitle = e.message;
                        }
                    };
                    if (removing) {
                        driver.uninstall.begin(done);
                    } else {
                        driver.install.begin(done);
                    }
                });
                dialog.present();
            });

            manager.probe.begin((obj, res) => {
                bool ready = manager.probe.end(res);
                string? sensor = FingerprintManager.unsupported_sensor();
                if (ready) show_ready();
                if (sensor == null) return;
                FingerprintDriver.find.begin(sensor, (o, r) => {
                    driver = FingerprintDriver.find.end(r);
                    if (driver != null && (driver.installed || !ready)) show_driver();
                    if (ready) return;
                    show_unsupported();
                    if (driver != null) return;
                    var info_btn = new Button.with_label(_("Learn More"));
                    info_btn.valign = Align.CENTER;
                    info_btn.clicked.connect(() => {
                        try {
                            AppInfo.launch_default_for_uri("https://fprint.freedesktop.org/supported-devices.html", null);
                        } catch (GLib.Error e) {
                            warning("Cannot open the fingerprint driver page: %s", e.message);
                        }
                    });
                    status_row.add_suffix(info_btn);
                });
            });
            return group;
        }

        private static async void start_fprintd() {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "StartServiceByName", new Variant("(su)", "net.reactivated.Fprint", 0),
                    null, DBusCallFlags.NONE, 20000);
            } catch (GLib.Error e) {
                warning("Cannot start the fingerprint service: %s", e.message);
            }
        }

        private delegate void Callback();

        private PreferencesGroup build_login_screen_group() {
            var sync = new LoginScreenSync();
            var group = new PreferencesGroup(_("Login Screen"));
            group.description = _("Use your displays, keyboard and pointer settings on the login screen");

            var displays_row = new SwitchRow(_("Displays"), _("Arrangement, resolution, scale and rotation"), true);
            displays_row.switch_btn.bind_property("active", sync, "displays", BindingFlags.SYNC_CREATE);
            group.add_row(displays_row);
            var keyboard_row = new SwitchRow(_("Keyboard Layout"), _("Layouts and keyboard options"), true);
            keyboard_row.switch_btn.bind_property("active", sync, "keyboard", BindingFlags.SYNC_CREATE);
            group.add_row(keyboard_row);
            var pointer_row = new SwitchRow(_("Mouse & Touchpad"), _("Tap to click, scrolling and speed"), true);
            pointer_row.switch_btn.bind_property("active", sync, "pointer", BindingFlags.SYNC_CREATE);
            group.add_row(pointer_row);
            var cursor_row = new SwitchRow(_("Cursor"), _("Cursor theme and size"), true);
            cursor_row.switch_btn.bind_property("active", sync, "cursor", BindingFlags.SYNC_CREATE);
            group.add_row(cursor_row);

            string[] bg_labels = { _("Each User's Wallpaper"), _("Picture"), _("Solid Color") };
            string? current_image = LoginScreenSync.background_image();
            string? current_color = LoginScreenSync.background_color();
            int bg_mode = current_image != null ? 1 : (current_color != null ? 2 : 0);
            var bg_row = new SelectionRow(_("Background"), bg_labels, bg_labels[bg_mode]);
            group.add_row(bg_row);

            var picture_row = new ActionRow(_("Picture"), current_image != null ? _("Shown behind the sign-in box") : _("No picture chosen"));
            var thumb = new Picture();
            thumb.content_fit = ContentFit.COVER;
            thumb.set_size_request(64, 36);
            thumb.valign = Align.CENTER;
            thumb.add_css_class("login-bg-thumb");
            if (current_image != null) thumb.set_filename(current_image);
            picture_row.add_suffix(thumb);
            var choose_btn = new Button.with_label(_("Choose"));
            choose_btn.valign = Align.CENTER;
            picture_row.add_suffix(choose_btn);
            group.add_row(picture_row);

            var color_row = new ActionRow(_("Color"), null);
            var picker = new ColorPickerButton();
            var initial = Gdk.RGBA();
            initial.parse(current_color ?? "#1e1e2e");
            picker.color = initial;
            picker.valign = Align.CENTER;
            color_row.add_suffix(picker);
            group.add_row(color_row);

            picture_row.visible = bg_mode == 1;
            color_row.visible = bg_mode == 2;

            choose_btn.clicked.connect(() => {
                var dialog = new FileDialog();
                dialog.title = _("Choose a Login Screen Picture");
                var filter = new FileFilter();
                filter.name = _("Pictures");
                filter.add_mime_type("image/png");
                filter.add_mime_type("image/jpeg");
                filter.add_mime_type("image/webp");
                var filters = new GLib.ListStore(typeof(FileFilter));
                filters.append(filter);
                dialog.filters = filters;
                SidebarWait.choose_file.begin(this, dialog, get_root() as Gtk.Window, (obj, res) => {
                    File file;
                    try {
                        file = SidebarWait.choose_file.end(res);
                    } catch (GLib.Error e) {
                        return;
                    }
                    picture_row.subtitle = _("Applying...");
                    sync.set_background_image.begin(file, (o, r) => {
                        try {
                            sync.set_background_image.end(r);
                            picture_row.subtitle = _("Shown behind the sign-in box");
                            string? stored = LoginScreenSync.background_image();
                            if (stored != null) thumb.set_filename(stored);
                        } catch (GLib.Error e) {
                            picture_row.subtitle = e.message;
                        }
                    });
                });
            });

            picker.color_changed.connect((c) => {
                string hex = "#%02x%02x%02x".printf((uint) (c.red * 255 + 0.5), (uint) (c.green * 255 + 0.5), (uint) (c.blue * 255 + 0.5));
                color_row.subtitle = _("Applying...");
                sync.set_background_color.begin(hex, (o, r) => {
                    try {
                        sync.set_background_color.end(r);
                        color_row.subtitle = hex;
                    } catch (GLib.Error e) {
                        color_row.subtitle = e.message;
                    }
                });
            });

            bg_row.selected.connect((item) => {
                int mode = 0;
                for (int i = 0; i < bg_labels.length; i++) if (bg_labels[i] == item) mode = i;
                picture_row.visible = mode == 1;
                color_row.visible = mode == 2;
                if (mode == 0) {
                    sync.reset_background.begin((o, r) => {
                        try {
                            sync.reset_background.end(r);
                        } catch (GLib.Error e) {
                            bg_row.subtitle = e.message;
                        }
                    });
                } else if (mode == 1 && LoginScreenSync.background_image() == null) {
                    choose_btn.clicked();
                } else if (mode == 2) {
                    picker.color_changed(picker.color);
                }
            });

            var apply_row = new ActionRow(_("Apply My Settings"), _("Copy the selected settings to the login screen"));
            var apply_btn = new Button.with_label(_("Apply"));
            apply_btn.add_css_class("suggested-action");
            apply_btn.valign = Align.CENTER;
            apply_row.add_suffix(apply_btn);
            apply_row.activated.connect(() => apply_btn.clicked());
            apply_btn.clicked.connect(() => {
                apply_btn.sensitive = false;
                sync.apply.begin((obj, res) => {
                    apply_btn.sensitive = true;
                    try {
                        sync.apply.end(res);
                        apply_row.subtitle = _("Applied, used from the next login screen");
                    } catch (GLib.Error e) {
                        apply_row.subtitle = e.message;
                    }
                });
            });
            group.add_row(apply_row);

            var reset_row = new ActionRow(_("Restore Defaults"), _("Go back to the standard login screen settings"));
            var reset_btn = new Button.with_label(_("Restore"));
            reset_btn.valign = Align.CENTER;
            reset_row.add_suffix(reset_btn);
            reset_btn.clicked.connect(() => reset_row.activated());
            reset_row.activated.connect(() => {
                reset_row.confirmation_requested(_("Restore"), _("Cancel"), ConfirmationSuggestedAction.CONFIRM);
            });
            reset_row.confirmed.connect(() => {
                sync.reset.begin((obj, res) => {
                    try {
                        sync.reset.end(res);
                        reset_row.subtitle = _("Restored");
                    } catch (GLib.Error e) {
                        reset_row.subtitle = e.message;
                    }
                });
            });
            group.add_row(reset_row);
            return group;
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
                var detail = new UserDetailPage(view, user, service, this, !is_locked, is_self);
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
                               AccountsService service, UsersPage parent,
                               bool admin_unlocked = false, bool self_account = false) {
            base(user.real_name != "" ? user.real_name : user.user_name);
            this.admin_unlocked = admin_unlocked;
            this.self_account = self_account;
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

            if (admin_unlocked && !self_account && user.account_type == 0) {
                var family_group = new PreferencesGroup(_("Family"));
                var parental_row = new ActionRow(_("Parental Controls"), _("Apps, time limits, websites and screen time"), "singularity-parental-controls");
                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.add_css_class("dim-label");
                parental_row.add_suffix(chevron);
                parental_row.activatable = true;
                parental_row.activated.connect(() => {
                    var page = new ParentalControlsPage(view, user, "user-detail-%s".printf(user.uid.to_string()));
                    view.open_subpage(page, "parental-%s".printf(user.uid.to_string()));
                });
                family_group.add_row(parental_row);
                add_group(family_group);
            }

            // Danger zone: removing an account is administrative -> admin unlock only.
            if (admin_unlocked) {
                var danger_group = new PreferencesGroup(_("Danger Zone"));
                var del_row = new ActionRow(_("Remove User"), _("Permanently delete this account and home folder"), "user-trash-symbolic");
                del_row.activatable = true;
                del_row.add_css_class("destructive-action-row");
                del_row.activated.connect(() => {
                    del_row.confirmation_requested(_("Delete Account"), _("Cancel"),
                        ConfirmationSuggestedAction.CANCEL);
                });
                del_row.confirmed.connect(() => do_delete.begin());
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
            error_label.xalign = 0f;

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
            error_label.xalign = 0f;
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

    public class FingerprintEnrollRow : PreferencesRow {
        public signal void closed();

        private FingerprintManager manager;
        private Label hint;
        private Box marks_box;
        private Label status;
        private Button cancel_btn;
        private Button retry_btn;
        private Button done_btn;
        private Gee.ArrayList<Image> marks = new Gee.ArrayList<Image>();
        private int filled = 0;
        private bool active = false;

        public FingerprintEnrollRow(FingerprintManager manager) {
            this.manager = manager;
            activatable = false;
            add_css_class("fingerprint-enroll");
            ensure_style();

            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_top = 16;
            box.margin_bottom = 16;
            box.margin_start = 16;
            box.margin_end = 16;

            hint = new Label(_("Touch the sensor with the same finger, moving it slightly each time"));
            hint.wrap = true;
            hint.justify = Justification.CENTER;
            box.append(hint);

            marks_box = new Box(Orientation.VERTICAL, 10);
            marks_box.halign = Align.CENTER;
            box.append(marks_box);

            status = new Label("");
            status.add_css_class("fingerprint-status");
            status.wrap = true;
            status.justify = Justification.CENTER;
            box.append(status);

            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.CENTER;
            cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("pill");
            cancel_btn.clicked.connect(on_cancel);
            buttons.append(cancel_btn);
            retry_btn = new Button.with_label(_("Try Again"));
            retry_btn.add_css_class("pill");
            retry_btn.add_css_class("suggested-action");
            retry_btn.clicked.connect(start);
            buttons.append(retry_btn);
            done_btn = new Button.with_label(_("Done"));
            done_btn.add_css_class("pill");
            done_btn.add_css_class("suggested-action");
            done_btn.clicked.connect(() => closed());
            buttons.append(done_btn);
            box.append(buttons);
            set_child(box);

            manager.started.connect(on_started);
            manager.scanning.connect(on_scanning);
            manager.stage_passed.connect(on_stage_passed);
            manager.retry.connect(on_retry);
            manager.finished.connect(on_finished);
            unmap.connect(() => {
                Idle.add(() => {
                    if (active && !get_mapped()) on_cancel();
                    return Source.REMOVE;
                });
            });
        }

        public void start() {
            active = true;
            filled = 0;
            marks.clear();
            for (var line = marks_box.get_first_child(); line != null; line = marks_box.get_first_child()) {
                marks_box.remove(line);
            }
            marks_box.visible = false;
            hint.visible = true;
            show_status(_("Preparing the fingerprint reader..."), null);
            cancel_btn.visible = true;
            retry_btn.visible = false;
            done_btn.visible = false;
            if (auth_wait != null) auth_wait.end_quietly();
            auth_wait = SidebarWait.get_default().begin(this, _("Waiting for Authentication"), "dialog-password-symbolic",
                () => on_cancel(), true);
            manager.enroll.begin();
            reveal();
        }

        private SidebarWaitTicket? auth_wait = null;

        private void end_auth_wait() {
            if (auth_wait == null) return;
            auth_wait.end();
            auth_wait = null;
        }

        private void reveal() {
            int last = -1;
            add_tick_callback(() => {
                int height = get_height();
                if (height <= 0 || height != last) {
                    last = height;
                    return Source.CONTINUE;
                }
                for (var ancestor = get_parent(); ancestor != null; ancestor = ancestor.get_parent()) {
                    var viewport = ancestor as Viewport;
                    if (viewport != null) viewport.scroll_to(this, null);
                }
                return Source.REMOVE;
            });
        }

        private void on_cancel() {
            if (auth_wait != null) {
                auth_wait.end_quietly();
                auth_wait = null;
            }
            if (active) {
                active = false;
                manager.cancel.begin();
            }
            closed();
        }

        private void on_started(int stages) {
            end_auth_wait();
            if (!active) return;
            int per_line = stages > 8 ? (stages + 1) / 2 : stages;
            Box? line = null;
            for (int i = 0; i < stages; i++) {
                if (i % per_line == 0) {
                    line = new Box(Orientation.HORIZONTAL, 10);
                    line.halign = Align.CENTER;
                    marks_box.append(line);
                }
                var mark = new Image.from_gicon(new ThemedIcon.from_names({ "fingerprint-symbolic", "auth-fingerprint-symbolic" }));
                mark.pixel_size = 24;
                mark.width_request = 32;
                mark.height_request = 32;
                mark.add_css_class("fingerprint-stage");
                mark.add_css_class("dim-label");
                line.append(mark);
                marks.add(mark);
            }
            marks_box.visible = stages > 0;
            show_status(_("Waiting for authorization..."), null);
            reveal();
        }

        private void on_scanning() {
            if (!active || filled > 0 || status.has_css_class("warning")) return;
            show_status(_("Touch the fingerprint sensor"), null);
        }

        private void on_stage_passed(int stage, int stages) {
            if (!active) return;
            while (filled < stage && filled < marks.size) {
                fill(marks[filled]);
                filled++;
            }
            if (stages > 0) {
                show_status(_("%d of %d. Lift your finger and touch the sensor again.").printf(stage, stages), null);
            } else {
                show_status(_("Lift your finger and touch the sensor again"), null);
            }
        }

        private void on_retry(string message) {
            if (!active) return;
            show_status(message, "warning");
        }

        private void on_finished(bool success, string message) {
            end_auth_wait();
            if (!active) return;
            active = false;
            hint.visible = false;
            cancel_btn.visible = !success;
            retry_btn.visible = !success;
            done_btn.visible = success;
            if (success) {
                while (filled < marks.size) {
                    fill(marks[filled]);
                    filled++;
                }
                show_status(message, "success");
            } else {
                show_status(message, "error");
            }
        }

        private void show_status(string text, string? style) {
            status.label = text;
            foreach (string name in new string[] { "warning", "success", "error" }) {
                status.remove_css_class(name);
            }
            if (style != null) status.add_css_class(style);
        }

        private static bool styled = false;

        private static void ensure_style() {
            if (styled) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            styled = true;
            var provider = new CssProvider();
            provider.load_from_string(ENROLL_CSS);
            StyleContext.add_provider_for_display(display, provider, STYLE_PROVIDER_PRIORITY_USER + 1);
        }

        private const string ENROLL_CSS = """
.fingerprint-enroll .fingerprint-stage.done {
    color: @accent_color;
}
.fingerprint-enroll .fingerprint-status.warning {
    color: @warning_color;
}
.fingerprint-enroll .fingerprint-status.error {
    color: @error_color;
}
.fingerprint-enroll .fingerprint-status.success {
    color: @success_color;
}
""";

        private void fill(Image mark) {
            mark.remove_css_class("dim-label");
            mark.add_css_class("done");
            if (!Gtk.Settings.get_default().gtk_enable_animations) return;
            var anim = new Singularity.Animation.TimedAnimation(mark, 0, 1, 320,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
            anim.tick.connect(() => {
                mark.opacity = 0.4 + 0.6 * anim.value;
                mark.pixel_size = 24 + (int) Math.round(6 * Math.sin(Math.PI * anim.value));
            });
            anim.done.connect(() => {
                mark.opacity = 1;
                mark.pixel_size = 24;
            });
            anim.play();
        }
    }
}
