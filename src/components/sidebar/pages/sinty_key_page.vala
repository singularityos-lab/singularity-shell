using Gtk;
using Singularity.Widgets;
using Singularity.SintyKey;

namespace Singularity.SidebarPages {

    public class SintyKeyPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup running_group;
        private PreferencesGroup drives_group;
        private PreferencesGroup trusted_group;
        private StatusPage empty;
        private VolumeMonitor monitor;

        public SintyKeyPage(SettingsView view) {
            base(_("Sinty Key"));
            this.view = view;

            empty = new StatusPage();
            empty.icon_name = "drive-removable-media-symbolic";
            empty.title = _("Insert a Drive");
            empty.description = _("A Sinty Key keeps your files encrypted on a USB drive and opens them with your PIN on any Sinty OS computer.");
            add_widget(empty);

            running_group = new PreferencesGroup(_("This Computer"));
            bool guest = FileUtils.test("/run/sinty-key/guest", FileTest.EXISTS);
            running_group.add_row(new ActionRow(_("Running from your Sinty Key"),
                guest ? _("Open as a guest, nothing is kept on this computer") : _("Open, this computer is remembered"),
                "drive-removable-media-symbolic"));
            running_group.visible = guest || FileUtils.test("/run/sinty-key/portable", FileTest.EXISTS);
            add_group(running_group);

            drives_group = new PreferencesGroup(_("Drives"));
            add_group(drives_group);
            trusted_group = new PreferencesGroup(_("Trusted Devices"),
                _("Keys this computer remembers. Revoke one you lost: it then opens here only with its recovery code."));
            trusted_group.visible = false;
            add_group(trusted_group);
            refresh_trusted.begin();

            monitor = VolumeMonitor.get();
            monitor.mount_added.connect(() => refresh.begin());
            monitor.mount_removed.connect(() => refresh.begin());
            refresh.begin();
        }

        public static void open(SettingsView view) {
            var page = new SintyKeyPage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("system"));
            view.open_subpage(page, "sinty-key");
        }

        public static string state_text(KeyInfo info) {
            switch (info.mode) {
                case "trusted": return _("Open, this computer is remembered");
                case "guest": return _("Open as a guest");
            }
            return _("Locked");
        }

        private async void refresh() {
            drives_group.clear();
            var drives = Client.removable_drives();
            empty.visible = drives.size == 0 && !running_group.visible;
            drives_group.visible = drives.size > 0;
            foreach (string root in drives) {
                string name = Path.get_basename(root);
                try {
                    var info = yield Client.get_default().inspect(root);
                    var row = new ActionRow(name, state_text(info), info.unlocked ? "changes-allow-symbolic" : "changes-prevent-symbolic");
                    row.activatable = true;
                    row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
                    row.activated.connect(() => open_key(root));
                    drives_group.add_row(row);
                } catch (KeyError e) {
                    bool blank = e.code == KeyError.NOT_A_KEY;
                    var row = new ActionRow(name, blank ? _("Not a Sinty Key") : e.message, "drive-removable-media-symbolic");
                    if (blank) {
                        var make = new Button.with_label(_("Make a Key…"));
                        make.valign = Align.CENTER;
                        make.clicked.connect(() => open_create(root));
                        var restore = new Button.with_label(_("Restore…"));
                        restore.valign = Align.CENTER;
                        restore.clicked.connect(() => open_restore(root));
                        row.add_suffix(restore);
                        row.add_suffix(make);
                    }
                    drives_group.add_row(row);
                }
            }
        }

        private async void refresh_trusted() {
            trusted_group.clear();
            Gee.ArrayList<TrustedDevice> list;
            try {
                list = yield Client.get_default().devices();
            } catch (KeyError e) {
                trusted_group.visible = false;
                return;
            }
            foreach (var d in list) {
                string when = d.last_used > 0
                    ? _("Last used %s").printf(new DateTime.from_unix_local(d.last_used).format(_("%e %B %Y")).strip())
                    : "";
                var row = new ActionRow(d.name, when, "drive-removable-media-symbolic");
                var revoke = row_button(_("Revoke"), false);
                revoke.add_css_class("destructive-action");
                string kind = d.kind, id = d.id;
                revoke.clicked.connect(() => revoke_device.begin(kind, id));
                row.add_suffix(revoke);
                trusted_group.add_row(row);
            }
            trusted_group.visible = list.size > 0;
        }

        private async void revoke_device(string kind, string id) {
            try {
                yield Client.get_default().revoke(kind, id);
            } catch (KeyError e) {
                trusted_group.add_row(new ActionRow(e.message, "", "dialog-warning-symbolic"));
                return;
            }
            yield refresh_trusted();
        }

        private void open_key(string root) {
            var page = new SintyKeyDetailPage(view, root);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => SintyKeyPage.open(view));
            view.open_subpage(page, "sinty-key-detail");
        }

        private void open_restore(string root) {
            var page = new SintyKeyRestorePage(view, root);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => SintyKeyPage.open(view));
            view.open_subpage(page, "sinty-key-restore");
        }

        private void open_create(string root) {
            var page = new SintyKeyCreatePage(view, root);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => SintyKeyPage.open(view));
            view.open_subpage(page, "sinty-key-create");
        }
    }

    internal Label status_label() {
        var status = new Label("");
        status.add_css_class("dim-label");
        status.wrap = true;
        status.xalign = 0;
        status.margin_start = 12;
        status.margin_top = 6;
        status.visible = false;
        return status;
    }

    internal Button row_button(string text, bool suggested) {
        var b = new Button.with_label(text);
        b.valign = Align.CENTER;
        if (suggested) b.add_css_class("suggested-action");
        return b;
    }

    public class SintyKeyCreatePage : SettingsPage {
        private string drive;
        private PasswordRow pin;
        private PasswordRow again;
        private Button make;
        private Label status;
        private PreferencesGroup form;

        public SintyKeyCreatePage(SettingsView view, string drive) {
            base(_("Make a Sinty Key"));
            this.drive = drive;
            form = new PreferencesGroup(_("Choose a PIN"),
                _("Files you put in the Data folder of %s are encrypted. Files already on the drive stay as they are.").printf(Path.get_basename(drive)));
            pin = new PasswordRow(_("PIN"));
            again = new PasswordRow(_("Repeat PIN"));
            make = row_button(_("Make Key"), true);
            again.add_suffix(make);
            status = status_label();
            form.add_row(pin);
            form.add_row(again);
            form.add_row(status);
            add_group(form);
            make.clicked.connect(() => create.begin());
            again.entry_activated.connect(() => create.begin());
        }

        private async void create() {
            status.visible = true;
            if (pin.text.length < 4) {
                status.label = _("The PIN needs at least 4 characters.");
                return;
            }
            if (pin.text != again.text) {
                status.label = _("The two PINs are different.");
                return;
            }
            make.sensitive = false;
            status.label = _("Making the Key…");
            try {
                string code = yield Client.get_default().create(drive, pin.text);
                pin.text = "";
                again.text = "";
                form.visible = false;
                show_code(code);
            } catch (KeyError e) {
                status.label = e.message;
                make.sensitive = true;
            }
        }

        private void show_code(string code) {
            add_group(code_group(code, this));
        }
    }

    internal PreferencesGroup code_group(string code, Widget owner) {
        var group = new PreferencesGroup(_("Recovery Code"),
            _("Write it down and keep it apart from the Key. It is the only way back in if you forget the PIN or lose the Key."));
        var row = new ActionRow(code, "", "dialog-password-symbolic");
        var copy = new Button.from_icon_name("edit-copy-symbolic");
        copy.add_css_class("flat");
        copy.valign = Align.CENTER;
        copy.tooltip_text = _("Copy");
        copy.clicked.connect(() => owner.get_clipboard().set_text(code));
        row.add_suffix(copy);
        group.add_row(row);
        return group;
    }

    public class SintyKeyRestorePage : SettingsPage {
        private string drive;
        private string? source = null;
        private ActionRow file_row;
        private EntryRow code;
        private PasswordRow pin;
        private PasswordRow again;
        private Button go;
        private Label status;
        private PreferencesGroup form;

        public SintyKeyRestorePage(SettingsView view, string drive) {
            base(_("Restore a Sinty Key"));
            this.drive = drive;
            form = new PreferencesGroup(_("Restore from a Backup"),
                _("The files of the backup go into the Data folder of %s. It becomes a new Key with a new PIN and a new recovery code.").printf(Path.get_basename(drive)));
            file_row = new ActionRow(_("Backup File"), _("None chosen"), "document-open-symbolic");
            var choose = row_button(_("Choose…"), false);
            choose.clicked.connect(() => choose_file.begin());
            file_row.add_suffix(choose);
            code = new EntryRow(_("Recovery Code"));
            code.placeholder_text = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX";
            pin = new PasswordRow(_("New PIN"));
            again = new PasswordRow(_("Repeat New PIN"));
            go = row_button(_("Restore"), true);
            again.add_suffix(go);
            status = status_label();
            form.add_row(file_row);
            form.add_row(code);
            form.add_row(pin);
            form.add_row(again);
            form.add_row(status);
            add_group(form);
            go.clicked.connect(() => restore.begin());
            again.entry_activated.connect(() => restore.begin());
        }

        private async void choose_file() {
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Choose a Backup");
            try {
                var file = yield SidebarWait.choose_file(this, dialog, get_root() as Gtk.Window);
                if (file == null || file.get_path() == null) return;
                source = file.get_path();
                file_row.subtitle = file.get_basename();
            } catch (Error e) {
            }
        }

        private async void restore() {
            status.visible = true;
            if (source == null) {
                status.label = _("Choose the backup file first.");
                return;
            }
            if (pin.text.length < 4) {
                status.label = _("The PIN needs at least 4 characters.");
                return;
            }
            if (pin.text != again.text) {
                status.label = _("The two PINs are different.");
                return;
            }
            go.sensitive = false;
            status.label = _("Restoring…");
            try {
                string fresh = yield Client.get_default().restore(source, code.text, drive, pin.text);
                pin.text = again.text = code.text = "";
                form.visible = false;
                add_group(code_group(fresh, this));
            } catch (KeyError e) {
                status.label = e.message;
                go.sensitive = true;
            }
        }
    }

    public class SintyKeyDetailPage : SettingsPage {
        private string drive;
        private string pin_cache = "";
        private PreferencesGroup state_group;
        private PreferencesGroup computers_group;
        private PreferencesGroup pin_group;
        private PreferencesGroup recovery_group;
        private PreferencesGroup backup_group;

        public SintyKeyDetailPage(SettingsView view, string drive) {
            base(Path.get_basename(drive));
            this.drive = drive;
            state_group = new PreferencesGroup();
            computers_group = new PreferencesGroup(_("Remembered Computers"),
                _("On these computers the Key is also sealed in the security chip, which blocks guessing the PIN and refuses older copies of the Key."));
            pin_group = new PreferencesGroup(_("Change PIN"));
            backup_group = new PreferencesGroup(_("Backup"),
                _("The backup is one encrypted file that opens only with the recovery code. Keep it on another drive or online."));
            recovery_group = new PreferencesGroup(_("Forgot the PIN?"),
                _("Enter the recovery code you wrote down when the Key was made, then choose a new PIN."));
            add_group(state_group);
            add_group(computers_group);
            add_group(backup_group);
            add_group(pin_group);
            add_group(recovery_group);
            build_backup();
            build_pin();
            build_recovery();
            refresh.begin();
        }

        private async void refresh() {
            state_group.clear();
            computers_group.clear();
            KeyInfo info;
            try {
                info = yield Client.get_default().inspect(drive);
            } catch (KeyError e) {
                state_group.add_row(new ActionRow(e.message, "", "dialog-warning-symbolic"));
                computers_group.visible = false;
                return;
            }
            if (info.unlocked) {
                var row = new ActionRow(SintyKeyPage.state_text(info),
                    info.mode == "guest" ? _("Your files in the Data folder are available. This computer is not remembered, so the PIN is the only protection here.") : _("Your files in the Data folder are available."),
                    "changes-allow-symbolic");
                var lock_btn = row_button(_("Lock"), false);
                lock_btn.clicked.connect(() => lock_key.begin());
                row.add_suffix(lock_btn);
                state_group.add_row(row);
            } else {
                var pin = new PasswordRow(_("PIN"));
                var open = row_button(_("Unlock"), true);
                pin.add_suffix(open);
                var status = status_label();
                state_group.add_row(pin);
                state_group.add_row(status);
                open.clicked.connect(() => unlock.begin(pin, status, open));
                pin.entry_activated.connect(() => unlock.begin(pin, status, open));
            }
            bool here = false;
            foreach (var s in info.slots) {
                if (s.here) here = true;
                string when = s.last_used > 0
                    ? _("Last opened %s").printf(new DateTime.from_unix_local(s.last_used).format(_("%e %B %Y")).strip())
                    : "";
                var row = new ActionRow(s.here ? _("%s (this computer)").printf(s.name) : s.name, when, "computer-symbolic");
                var forget = row_button(_("Forget"), false);
                forget.add_css_class("destructive-action");
                string fp = s.fingerprint;
                forget.clicked.connect(() => forget_computer.begin(fp));
                row.add_suffix(forget);
                computers_group.add_row(row);
            }
            if (!here && info.unlocked) {
                var row = new ActionRow(_("Remember This Computer"), _("Unlock here with the PIN alone, protected by this computer's security chip."), "computer-symbolic");
                var remember = row_button(_("Remember"), false);
                remember.clicked.connect(() => remember_computer.begin());
                row.add_suffix(remember);
                computers_group.add_row(row);
            }
            computers_group.visible = computers_group.get_rows().size > 0;
        }

        private async void unlock(PasswordRow pin, Label status, Button open) {
            if (pin.text == "") return;
            open.sensitive = false;
            status.visible = true;
            status.label = _("Unlocking…");
            try {
                yield Client.get_default().unlock(drive, pin.text);
                pin_cache = pin.text;
                yield refresh();
            } catch (KeyError e) {
                status.label = e.message;
                open.sensitive = true;
            }
        }

        private async void lock_key() {
            try {
                yield Client.get_default().lock(drive);
            } catch (KeyError e) {
                warning("lock %s: %s", drive, e.message);
            }
            pin_cache = "";
            yield refresh();
        }

        private async void remember_computer() {
            try {
                yield Client.get_default().remember(drive, pin_cache, "");
            } catch (KeyError e) {
                computers_group.add_row(new ActionRow(e.message, "", "dialog-warning-symbolic"));
                return;
            }
            yield refresh();
        }

        private async void forget_computer(string fingerprint) {
            try {
                yield Client.get_default().forget(drive, pin_cache, fingerprint);
            } catch (KeyError e) {
                computers_group.add_row(new ActionRow(e.message, "", "dialog-warning-symbolic"));
                return;
            }
            yield refresh();
        }

        private void build_backup() {
            var pin = new PasswordRow(_("PIN"));
            var save = row_button(_("Back Up…"), false);
            pin.add_suffix(save);
            var status = status_label();
            backup_group.add_row(pin);
            backup_group.add_row(status);
            save.clicked.connect(() => back_up.begin(pin, status, save));
        }

        private async void back_up(PasswordRow pin, Label status, Button save) {
            string secret = pin.text != "" ? pin.text : pin_cache;
            status.visible = true;
            if (secret == "") {
                status.label = _("Enter the PIN of the Key.");
                return;
            }
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Save Backup");
            dialog.initial_name = "%s.sintykey".printf(Path.get_basename(drive));
            File? file = null;
            try {
                file = yield dialog.save(get_root() as Gtk.Window, null);
            } catch (Error e) {
                status.visible = false;
                return;
            }
            if (file == null || file.get_path() == null) return;
            save.sensitive = false;
            status.label = _("Backing up…");
            try {
                yield Client.get_default().backup(drive, secret, file.get_path());
                pin.text = "";
                status.label = _("Backup saved as %s.").printf(file.get_basename());
            } catch (KeyError e) {
                status.label = e.message;
            }
            save.sensitive = true;
        }

        private void build_pin() {
            var current = new PasswordRow(_("Current PIN"));
            var fresh = new PasswordRow(_("New PIN"));
            var again = new PasswordRow(_("Repeat New PIN"));
            var change = row_button(_("Change"), false);
            again.add_suffix(change);
            var status = status_label();
            pin_group.add_row(current);
            pin_group.add_row(fresh);
            pin_group.add_row(again);
            pin_group.add_row(status);
            change.clicked.connect(() => change_pin.begin(current, fresh, again, status));
        }

        private async void change_pin(PasswordRow current, PasswordRow fresh, PasswordRow again, Label status) {
            status.visible = true;
            if (fresh.text != again.text) {
                status.label = _("The two PINs are different.");
                return;
            }
            try {
                yield Client.get_default().change_pin(drive, current.text, fresh.text);
                if (pin_cache != "") pin_cache = fresh.text;
                current.text = fresh.text = again.text = "";
                status.label = _("PIN changed.");
                yield refresh();
            } catch (KeyError e) {
                status.label = e.message;
            }
        }

        private void build_recovery() {
            var code = new EntryRow(_("Recovery Code"));
            code.placeholder_text = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX";
            var fresh = new PasswordRow(_("New PIN"));
            var reset = row_button(_("Set PIN"), false);
            fresh.add_suffix(reset);
            var status = status_label();
            recovery_group.add_row(code);
            recovery_group.add_row(fresh);
            recovery_group.add_row(status);
            reset.clicked.connect(() => recover.begin(code, fresh, status));
        }

        private async void recover(EntryRow code, PasswordRow fresh, Label status) {
            status.visible = true;
            try {
                yield Client.get_default().recover(drive, code.text, fresh.text);
                code.text = fresh.text = "";
                status.label = _("New PIN set. Unlock the Key with it.");
                yield refresh();
            } catch (KeyError e) {
                status.label = e.message;
            }
        }
    }
}
