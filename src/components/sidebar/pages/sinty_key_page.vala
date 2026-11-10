using Gtk;
using Singularity.Widgets;
using Singularity.SintyKey;

namespace Singularity.SidebarPages {

    public class SintyKeyPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup running_group;
        private PreferencesGroup drives_group;
        private PreferencesGroup trusted_group;
        private PreferencesGroup badge_group;
        private PreferencesGroup rescue_group;
        private bool badge_reverting;
        private StatusPage empty;
        private VolumeMonitor monitor;

        public SintyKeyPage(SettingsView view) {
            base(_("Sinty Key"));
            this.view = view;

            empty = new StatusPage();
            empty.icon_name = "sinty-key";
            empty.title = _("Insert a Drive");
            empty.description = _("A Sinty Key keeps your files encrypted on a USB drive and opens them with your PIN on any Sinty OS computer.");
            add_widget(empty);

            running_group = new PreferencesGroup(_("This Computer"));
            bool guest = FileUtils.test("/run/sinty-key/guest", FileTest.EXISTS);
            running_group.add_row(key_row(_("Running from your Sinty Key"),
                guest ? _("Open as a guest, nothing is kept on this computer") : _("Open, this computer is remembered"),
                guest ? "sinty-key-guest" : "sinty-key-open"));
            running_group.visible = guest || FileUtils.test("/run/sinty-key/portable", FileTest.EXISTS);
            add_group(running_group);

            rescue_group = new PreferencesGroup(_("Rescue This Computer"),
                _("When this computer does not start, its files can be copied, its logs read and Sinty OS reinstalled from your Key."));
            rescue_group.visible = false;
            add_group(rescue_group);
            if (running_group.visible) refresh_rescue.begin();

            drives_group = new PreferencesGroup(_("Drives"));
            add_group(drives_group);
            trusted_group = new PreferencesGroup(_("Trusted Devices"),
                _("Keys, screens and phones this computer trusts. A revoked Key opens here only with its recovery code."));
            trusted_group.visible = false;
            add_group(trusted_group);
            refresh_trusted.begin();
            badge_group = new PreferencesGroup(_("Other Keys"),
                _("A Sinty Key without an account here can open its own session on this computer. Its files stay on the Key, and nothing is left here when it is removed."));
            badge_group.visible = false;
            add_group(badge_group);
            refresh_badge.begin();

            monitor = VolumeMonitor.get();
            monitor.mount_added.connect(() => refresh.begin());
            monitor.mount_removed.connect(() => refresh.begin());
            monitor.drive_connected.connect(() => refresh.begin());
            monitor.drive_disconnected.connect(() => refresh.begin());
            refresh.begin();
        }

        public static void open(SettingsView view) {
            var page = new SintyKeyPage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("system"));
            view.open_subpage(page, "sinty-key");
        }

        public static string state_icon(KeyInfo info) {
            switch (info.mode) {
                case "trusted": return "sinty-key-open";
                case "guest": return "sinty-key-guest";
            }
            return "sinty-key-locked";
        }

        public static string state_text(KeyInfo info) {
            switch (info.mode) {
                case "trusted": return _("Open, this computer is remembered");
                case "guest": return _("Open as a guest");
            }
            return _("Locked");
        }

        private async void refresh() {
            Gee.ArrayList<KeyDrive> drives;
            try {
                drives = yield Client.get_default().drives();
            } catch (KeyError e) {
                drives = new Gee.ArrayList<KeyDrive>();
            }
            drives_group.clear();
            empty.visible = drives.size == 0 && !running_group.visible;
            drives_group.visible = drives.size > 0;
            foreach (var d in drives) {
                string size = format_size(d.size);
                if (d.key && d.root != "") {
                    string root = d.root;
                    try {
                        var info = yield Client.get_default().inspect(root);
                        var row = key_row(d.name, "%s, %s".printf(state_text(info), size), state_icon(info));
                        row.activatable = true;
                        row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
                        row.activated.connect(() => open_key(root));
                        drives_group.add_row(row);
                        continue;
                    } catch (KeyError e) {
                    }
                }
                if (d.key) {
                    var row = key_row(d.name, "%s, %s".printf(_("Locked"), size), "sinty-key-locked");
                    var unlock = row_button(_("Open…"), true);
                    var drive = d;
                    unlock.clicked.connect(() => open_unlock(drive));
                    row.add_suffix(unlock);
                    drives_group.add_row(row);
                    continue;
                }
                if (d.startup) {
                    var startup = key_row(d.name, "%s, %s".printf(_("Startup Key"), size), "sinty-key-startup");
                    drives_group.add_row(startup);
                    offer_sync.begin(d.device, startup);
                    continue;
                }
                var row = key_row(d.name, "%s, %s".printf(_("Not a Sinty Key"), size), "drive-removable-media");
                var make = row_button(_("Make a Key…"), false);
                var drive = d;
                make.clicked.connect(() => open_create(drive));
                row.add_suffix(make);
                drives_group.add_row(row);
            }
        }

        private async void offer_sync(string device, ActionRow row) {
            string[] st;
            try {
                st = yield Client.get_default().startup_sync(device);
            } catch (KeyError e) {
                return;
            }
            if (st[0] == "") return;
            bool key = st[0] == "key";
            row.subtitle = key ? _("Runs %s, this computer runs %s").printf(st[1], st[2])
                               : _("Runs %s, newer than %s on this computer").printf(st[1], st[2]);
            var update = row_button(key ? _("Update Key") : _("Update This Computer"), true);
            update.clicked.connect(() => run_sync.begin(device, key, row, update));
            row.add_suffix(update);
        }

        private async void run_sync(string device, bool key, ActionRow row, Button update) {
            update.sensitive = false;
            row.subtitle = key ? _("Updating the Key…") : _("Updating this computer from the Key…");
            ulong id = Client.get_default().progress.connect((dev, pct) => {
                if (dev == device) row.subtitle = _("Updating… %u%%").printf(pct);
            });
            try {
                if (key) yield Client.get_default().update_startup_key(device);
                else yield Client.get_default().update_from_startup_key(device);
                row.subtitle = key ? _("Updated. The Key starts the new version the next time it starts a computer.")
                                   : _("Updated. Restart this computer to start the new version.");
                update.visible = false;
            } catch (KeyError e) {
                row.subtitle = e.message;
                update.sensitive = true;
            }
            Client.get_default().disconnect(id);
        }

        private async void refresh_rescue() {
            Gee.ArrayList<KeyDrive> targets;
            try {
                targets = yield Client.get_default().rescue_targets();
            } catch (KeyError e) {
                return;
            }
            foreach (var d in targets) {
                var row = key_row(d.name, format_size(d.size), "drive-harddisk");
                var open = row_button(_("Rescue…"), false);
                var drive = d;
                open.clicked.connect(() => view.open_subpage(new SintyRescuePage(view, drive), "sinty-rescue"));
                row.add_suffix(open);
                rescue_group.add_row(row);
            }
            rescue_group.visible = targets.size > 0;
        }

        private async void refresh_badge() {
            bool on;
            try {
                on = yield Client.get_default().badge_allowed();
            } catch (KeyError e) {
                return;
            }
            var row = new SwitchRow(_("Open Sessions From Other Keys"), null, on);
            row.switch_btn.notify["active"].connect(() => set_badge.begin(row));
            badge_group.add_row(row);
            badge_group.visible = true;
        }

        private async void set_badge(SwitchRow row) {
            if (badge_reverting) return;
            bool want = row.switch_btn.active;
            try {
                yield Client.get_default().set_badge_allowed(want);
                row.subtitle = "";
            } catch (KeyError e) {
                row.subtitle = e.message;
                badge_reverting = true;
                row.switch_btn.active = !want;
                badge_reverting = false;
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
                var row = new ActionRow(d.name, when, device_icon(d.kind));
                var revoke = row_button(_("Revoke"), false);
                revoke.add_css_class("destructive-action");
                string kind = d.kind, id = d.id;
                revoke.clicked.connect(() => revoke_device.begin(kind, id));
                row.add_suffix(revoke);
                trusted_group.add_row(row);
            }
            trusted_group.visible = list.size > 0;
        }

        private static string device_icon(string kind) {
            switch (kind) {
                case "screen": return "video-display-symbolic";
                case "phone": return "phone-symbolic";
            }
            return "drive-removable-media-symbolic";
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

        private void open_unlock(KeyDrive drive) {
            var page = new SintyKeyOpenPage(view, drive);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => SintyKeyPage.open(view));
            view.open_subpage(page, "sinty-key-open");
        }

        private void open_create(KeyDrive drive) {
            var page = new SintyKeyMakePage(view, drive);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => SintyKeyPage.open(view));
            view.open_subpage(page, "sinty-key-make");
        }
    }

    internal ActionRow key_row(string title, string? subtitle, string icon) {
        var row = new ActionRow(title, subtitle);
        var image = new Image.from_icon_name(icon);
        image.pixel_size = 32;
        row.add_prefix(image);
        return row;
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

    internal uint follow_drive_check(string device, owned ProgressFunc report) {
        try {
            var bus = Bus.get_sync(BusType.SYSTEM);
            return bus.signal_subscribe(DriveHealth.BUS_NAME, DriveHealth.INTERFACE, "Progress", DriveHealth.OBJECT_PATH, null,
                DBusSignalFlags.NONE, (conn, sender, path, iface, name, args) => {
                    if (!args.is_of_type(new VariantType("(su)"))) return;
                    if (args.get_child_value(0).get_string() == device) report(args.get_child_value(1).get_uint32());
                });
        } catch (Error e) {
            return 0;
        }
    }

    internal void stop_drive_check(uint id) {
        if (id == 0) return;
        try {
            Bus.get_sync(BusType.SYSTEM).signal_unsubscribe(id);
        } catch (Error e) {
        }
    }

    internal delegate void ProgressFunc(uint percent);

    internal Button row_button(string text, bool suggested) {
        var b = new Button.with_label(text);
        b.valign = Align.CENTER;
        if (suggested) b.add_css_class("suggested-action");
        return b;
    }

    public class SintyKeyMakePage : SettingsPage {
        public SintyKeyMakePage(SettingsView view, KeyDrive drive) {
            base(_("Make a Sinty Key"));
            var group = new PreferencesGroup(_("Choose a Kind of Key"),
                _("Everything on %s is erased.").printf(drive.name));
            group.add_row(choice(view, drive, _("Key for Your Files"),
                _("Your files encrypted with a PIN, opened on any Sinty OS computer"), "sinty-key-new", 0));
            group.add_row(choice(view, drive, _("Startup Key"),
                _("Sinty OS from this computer, started on any computer from the drive"), "sinty-key-startup", 1));
            group.add_row(choice(view, drive, _("Restore a Key"),
                _("From a backup file and its recovery code"), "sinty-key-restore", 2));
            add_group(group);
        }

        private ActionRow choice(SettingsView view, KeyDrive drive, string title, string subtitle, string icon, int kind) {
            var row = key_row(title, subtitle, icon);
            row.activatable = true;
            row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
            row.activated.connect(() => {
                DriveHealth.lookup.begin(drive.device, (o, r) => {
                    var health = DriveHealth.lookup.end(r);
                    if (health == null || !health.troubled) {
                        open_kind(view, drive, kind);
                        return;
                    }
                    var app = GLib.Application.get_default() as Gtk.Application;
                    var dlg = new ConfirmDialog(app, _("Use %s Anyway?").printf(drive.name), health.icon_name(),
                        "%s\n\n%s".printf(health.explain(), _("A Key on this drive may stop working and take your files with it.")),
                        _("Use Anyway"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
                    dlg.response.connect((answer) => {
                        if (answer == ConfirmDialog.Response.PRIMARY) open_kind(view, drive, kind);
                    });
                    dlg.present();
                });
            });
            return row;
        }

        private static void open_kind(SettingsView view, KeyDrive drive, int kind) {
            SettingsPage page;
            if (kind == 0) page = new SintyKeyCreatePage(view, drive);
            else if (kind == 1) page = new SintyKeyBootPage(view, drive);
            else page = new SintyKeyRestorePage(view, drive);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => {
                var back = new SintyKeyMakePage(view, drive);
                back.back_btn.visible = true;
                back.back_clicked.connect(() => SintyKeyPage.open(view));
                view.open_subpage(back, "sinty-key-make");
            });
            view.open_subpage(page, "sinty-key-make-" + kind.to_string());
        }
    }

    public class SintyKeyBootPage : SettingsPage {
        private KeyDrive drive;
        private Button go;
        private Label status;
        private ActionRow progress_row;
        private ProgressBar progress_bar;
        private PreferencesGroup group;
        private PreferencesGroup arch_group;
        private SelectionRow arch_row;
        private string[] archs = {};
        private string arch = "";

        public SintyKeyBootPage(SettingsView view, KeyDrive drive) {
            base(_("Startup Key"));
            this.drive = drive;
            arch_group = new PreferencesGroup(_("Computer"));
            arch_group.visible = false;
            add_group(arch_group);
            group = new PreferencesGroup(_("Copy Sinty OS"), "");
            describe();
            var row = key_row(drive.name, format_size(drive.size), "sinty-key-startup");
            go = row_button(_("Erase and Copy"), true);
            go.add_css_class("destructive-action");
            row.add_suffix(go);
            group.add_row(row);
            progress_row = new ActionRow(_("Copying"), "");
            progress_bar = new ProgressBar();
            progress_bar.valign = Align.CENTER;
            progress_bar.width_request = 120;
            progress_row.add_suffix(progress_bar);
            progress_row.visible = false;
            group.add_row(progress_row);
            status = status_label();
            group.add_row(status);
            add_group(group);
            go.clicked.connect(() => make.begin());
            load_archs.begin();
            ulong id = Client.get_default().progress.connect((device, percent) => {
            if (device != drive.device) return;
            progress_row.visible = true;
            progress_row.title = _("Copying");
            progress_bar.fraction = percent.clamp(0, 100) / 100.0;
            progress_row.subtitle = "%u%%".printf(percent);
            });
            destroy.connect(() => Client.get_default().disconnect(id));
        }

        private static string arch_label(string a) {
            if (a == "aarch64") return _("ARM Computers");
            if (a == "x86_64") return _("Intel and AMD Computers");
            return a;
        }

        private bool foreign() {
            return archs.length > 0 && arch != "" && arch != archs[0];
        }

        private void describe() {
            if (foreign()) {
            group.description = _("Sinty OS for %s is downloaded and copied to %s, which then starts those computers from USB. Everything on the drive is erased.").printf(arch_label(arch), drive.name);
            } else {
            group.description = _("Sinty OS from this computer is copied to %s, which then starts any computer that boots from USB. Everything on the drive is erased.").printf(drive.name);
            }
        }

        private async void load_archs() {
            try {
            archs = yield Client.get_default().architectures();
            } catch (KeyError e) {
            return;
            }
            if (archs.length < 2) return;
            string[] labels = {};
            foreach (var a in archs) labels += arch_label(a);
            arch = archs[0];
            arch_row = new SelectionRow(_("Starts"), labels, labels[0]);
            arch_row.selected.connect((item) => {
            for (int i = 0; i < labels.length; i++) {
                if (labels[i] == item) arch = archs[i];
            }
            describe();
            });
            arch_group.add_row(arch_row);
            arch_group.visible = true;
        }

        private async void make() {
            go.sensitive = false;
            if (arch_row != null) arch_row.sensitive = false;
            status.visible = true;
            status.label = foreign()
            ? _("Downloading Sinty OS for %s. This takes a while, keep the drive connected…").printf(arch_label(arch))
            : _("Copying Sinty OS. This takes a few minutes, keep the drive connected…");
            var ticket = SidebarWait.get_default().begin(this, _("Making a Startup Key"), "drive-removable-media-symbolic");
            progress_bar.fraction = 0;
            progress_row.subtitle = "";
            uint check = follow_drive_check(drive.device, (p) => {
            progress_row.visible = p < 100;
            progress_row.title = _("Checking the Drive");
            progress_bar.fraction = p.clamp(0, 100) / 100.0;
            progress_row.subtitle = "%u%%".printf(p);
            });
            try {
            if (foreign()) {
                yield Client.get_default().make_bootable_for(drive.device, arch);
            } else {
                yield Client.get_default().make_bootable(drive.device);
            }
            status.label = _("The Startup Key is ready. Start a computer from it to use Sinty OS.");
            } catch (KeyError e) {
            status.label = e.message;
            go.sensitive = true;
            }
            stop_drive_check(check);
            if (arch_row != null) arch_row.sensitive = true;
            progress_row.visible = false;
            ticket.end();
        }
    }

    public class SintyKeyOpenPage : SettingsPage {
        private SettingsView view;
        private KeyDrive drive;
        private PasswordRow pin;
        private Label status;
        private Button go;

        public SintyKeyOpenPage(SettingsView view, KeyDrive drive) {
            base(_("Open the Sinty Key"));
            this.view = view;
            this.drive = drive;
            var group = new PreferencesGroup(drive.name);
            pin = new PasswordRow(_("PIN"));
            go = row_button(_("Open"), true);
            pin.add_suffix(go);
            status = status_label();
            group.add_row(pin);
            group.add_row(status);
            add_group(group);
            go.clicked.connect(() => unlock.begin());
            pin.entry_activated.connect(() => unlock.begin());
        }

        private async void unlock() {
            go.sensitive = false;
            status.visible = true;
            status.label = _("Opening…");
            try {
            string root = yield Client.get_default().open(drive.device, pin.text);
            pin.text = "";
            var page = new SintyKeyDetailPage(view, root);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => SintyKeyPage.open(view));
            view.open_subpage(page, "sinty-key-detail");
            } catch (KeyError e) {
            status.label = e.message;
            go.sensitive = true;
            }
        }
    }

    public class SintyKeyCreatePage : SettingsPage {
        private KeyDrive drive;
        private PasswordRow pin;
        private PasswordRow again;
        private Button make;
        private Label status;
        private PreferencesGroup form;

        public SintyKeyCreatePage(SettingsView view, KeyDrive drive) {
            base(_("Key for Your Files"));
            this.drive = drive;
            form = new PreferencesGroup(_("Choose a PIN"),
                _("Everything on %s is erased. Files you put in its Data folder are encrypted.").printf(drive.name));
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
            uint check = follow_drive_check(drive.device, (p) => {
                status.label = p < 100 ? _("Checking the drive, %u%%…").printf(p) : _("Making the Key…");
            });
            try {
                string root = yield Client.get_default().prepare(drive.device);
                string code = yield Client.get_default().create(root, pin.text);
                pin.text = "";
                again.text = "";
                form.visible = false;
                show_code(code);
            } catch (KeyError e) {
                status.label = e.message;
                make.sensitive = true;
            }
            stop_drive_check(check);
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
        private KeyDrive drive;
        private string? source = null;
        private ActionRow file_row;
        private EntryRow code;
        private PasswordRow pin;
        private PasswordRow again;
        private Button go;
        private Label status;
        private PreferencesGroup form;

        public SintyKeyRestorePage(SettingsView view, KeyDrive drive) {
            base(_("Restore a Sinty Key"));
            this.drive = drive;
            form = new PreferencesGroup(_("Restore from a Backup"),
                _("Everything on %s is erased, then the files of the backup go into its Data folder. It becomes a new Key with a new PIN and a new recovery code.").printf(drive.name));
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
                var file = yield SidebarWait.choose_file(this, dialog, null);
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
                string root = yield Client.get_default().prepare(drive.device);
                string fresh = yield Client.get_default().restore(source, code.text, root, pin.text);
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
        private PreferencesGroup home_group;
        private Label home_status;
        private bool moving;
        private string confirm_delete = "";
        private PreferencesGroup computers_group;
        private PreferencesGroup security_group;
        private PreferencesGroup pin_group;
        private PreferencesGroup recovery_group;
        private PreferencesGroup backup_group;
        private Button drop_button;
        private bool strong = false;

        public SintyKeyDetailPage(SettingsView view, string drive) {
            base(Path.get_basename(drive));
            this.drive = drive;
            state_group = new PreferencesGroup();
            computers_group = new PreferencesGroup(_("Remembered Computers"),
                _("On these computers the Key is also sealed in the security chip, which blocks guessing the PIN and refuses older copies of the Key."));
            security_group = new PreferencesGroup(_("Security Keys"),
                _("With a FIDO2 security key the Key opens only when one of its security keys is plugged in and touched, together with the PIN. Register a spare and keep it apart. The recovery code still opens the Key without them."));
            pin_group = new PreferencesGroup(_("Change PIN"));
            backup_group = new PreferencesGroup(_("Backup"),
                _("The backup is one encrypted file that opens only with the recovery code. Keep it on another drive or online."));
            recovery_group = new PreferencesGroup(_("Forgot the PIN?"),
                _("Enter the recovery code you wrote down when the Key was made, then choose a new PIN."));
            home_group = new PreferencesGroup(_("Your Home"),
                _("Move your files and settings between this computer and the Key. They are encrypted again with the keys of the side they land on, and every file is checked before the original can be deleted."));
            home_group.visible = false;
            home_status = status_label();
            add_group(state_group);
            add_group(home_group);
            add_widget(home_status);
            add_group(computers_group);
            add_group(security_group);
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
            yield refresh_security();
            KeyInfo info;
            try {
                info = yield Client.get_default().inspect(drive);
            } catch (KeyError e) {
                state_group.add_row(new ActionRow(e.message, "", "dialog-warning-symbolic"));
                computers_group.visible = false;
                security_group.visible = false;
                return;
            }
            if (info.unlocked) {
                var row = key_row(SintyKeyPage.state_text(info),
                    info.mode == "guest" ? _("Your files in the Data folder are available. This computer is not remembered, so the PIN is the only protection here.") : _("Your files in the Data folder are available."),
                    info.mode == "guest" ? "sinty-key-guest" : "sinty-key-open");
                var lock_btn = row_button(_("Lock"), false);
                lock_btn.clicked.connect(() => lock_key.begin());
                row.add_suffix(lock_btn);
                state_group.add_row(row);
                yield refresh_home();
            } else {
                home_group.visible = false;
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

        private void home_say(string text) {
            home_status.label = text;
            home_status.visible = text != "";
        }

        private async void refresh_home() {
            home_group.clear();
            string to_key, from_key;
            try {
                to_key = yield Client.get_default().move_home_state(drive, "to-key");
                from_key = yield Client.get_default().move_home_state(drive, "from-key");
            } catch (KeyError e) {
                home_group.visible = false;
                return;
            }
            if (to_key == "verified") {
                add_done_row(_("Your Home Is on the Key"), "to-key", _("Delete from This Computer"));
            } else if (from_key == "verified") {
                add_done_row(_("Your Home Is on This Computer"), "from-key", _("Delete from the Key"));
            } else {
                add_move_row(_("Move Your Home to the Key"), "to-key", to_key == "copying",
                    _("Take your files and settings to any Sinty OS computer."), _("Move"));
                add_move_row(_("Bring Your Home from the Key"), "from-key", from_key == "copying",
                    _("Copy the home kept on the Key into your account here."), _("Bring"));
            }
            home_group.visible = true;
        }

        private void add_move_row(string title, string direction, bool stopped, string subtitle, string label) {
            var row = new ActionRow(title, stopped ? _("Interrupted. It continues where it stopped.") : subtitle, "user-home-symbolic");
            var go = row_button(stopped ? _("Continue") : label, false);
            go.clicked.connect(() => move_home.begin(direction, row, go));
            row.add_suffix(go);
            home_group.add_row(row);
        }

        private void add_done_row(string title, string direction, string delete_label) {
            var row = new ActionRow(title, _("Every file was copied and checked."), "user-home-symbolic");
            var keep = row_button(_("Keep Both"), false);
            var del = row_button(delete_label, false);
            del.add_css_class("destructive-action");
            keep.clicked.connect(() => finish_move.begin(direction, false));
            del.clicked.connect(() => {
                if (confirm_delete != direction) {
                    confirm_delete = direction;
                    del.label = _("Delete Now");
                    home_say(direction == "to-key"
                        ? _("The files are checked once more, then deleted from this computer. Sign out right after.")
                        : _("The files are checked once more, then deleted from the Key."));
                    return;
                }
                confirm_delete = "";
                finish_move.begin(direction, true);
            });
            row.add_suffix(keep);
            row.add_suffix(del);
            home_group.add_row(row);
        }

        private async void move_home(string direction, ActionRow row, Button go) {
            if (moving) return;
            moving = true;
            go.sensitive = false;
            home_say("");
            row.subtitle = _("Copying…");
            ulong id = Client.get_default().progress.connect((dev, pct) => {
                if (dev == drive) row.subtitle = pct < 70 ? _("Copying… %u%%").printf(pct * 100 / 70) : _("Checking every file… %u%%").printf((pct - 70) * 100 / 30);
            });
            try {
                yield Client.get_default().move_home(drive, direction);
            } catch (KeyError e) {
                home_say(e.message);
            }
            Client.get_default().disconnect(id);
            moving = false;
            yield refresh_home();
        }

        private async void finish_move(string direction, bool remove) {
            if (moving) return;
            moving = true;
            home_say(remove ? _("Checking and deleting…") : "");
            try {
                yield Client.get_default().finish_move(drive, direction, remove);
                home_say(remove && direction == "to-key" ? _("Your home now lives on the Key. Sign out of this computer.") : "");
            } catch (KeyError e) {
                home_say(e.message);
            }
            moving = false;
            yield refresh_home();
        }

        private async void unlock(PasswordRow pin, Label status, Button open) {
            if (pin.text == "") return;
            open.sensitive = false;
            status.visible = true;
            status.label = strong ? _("Touch the security key when it blinks…") : _("Unlocking…");
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

        private async void refresh_security() {
            security_group.clear();
            Gee.ArrayList<SecurityKey> keys;
            try {
                keys = yield Client.get_default().security_keys(drive);
            } catch (KeyError e) {
                security_group.visible = false;
                return;
            }
            security_group.visible = true;
            strong = keys.size > 0;
            if (drop_button != null) drop_button.visible = strong;
            foreach (var k in keys) {
                string when = _("Added %s").printf(new DateTime.from_unix_local(k.added).format(_("%e %B %Y")).strip());
                var row = new ActionRow(k.name, when, "security-high-symbolic");
                var remove = row_button(_("Remove"), false);
                remove.add_css_class("destructive-action");
                string id = k.id;
                remove.clicked.connect(() => remove_security_key.begin(id));
                row.add_suffix(remove);
                security_group.add_row(row);
            }
            var name = new EntryRow(_("Name"));
            name.text = strong ? _("Spare") : _("Security Key");
            var key_pin = new PasswordRow(_("Security Key PIN, if It Has One"));
            var add = row_button(strong ? _("Add Spare") : _("Add"), false);
            key_pin.add_suffix(add);
            var status = status_label();
            security_group.add_row(name);
            security_group.add_row(key_pin);
            security_group.add_row(status);
            add.clicked.connect(() => add_security_key.begin(name, key_pin, status, add));
        }

        private async void add_security_key(EntryRow name, PasswordRow key_pin, Label status, Button add) {
            status.visible = true;
            if (pin_cache == "") {
                status.label = _("Unlock the Key with its PIN first.");
                return;
            }
            if (name.text.strip() == "") {
                status.label = _("Give the security key a name.");
                return;
            }
            add.sensitive = false;
            status.label = strong
                ? _("Touch a security key of this Key, then touch the new one…")
                : _("Plug in the security key and touch it when it blinks, up to two times…");
            try {
                yield Client.get_default().add_security_key(drive, pin_cache, name.text.strip(), key_pin.text);
                yield refresh();
            } catch (KeyError e) {
                status.label = e.message;
                add.sensitive = true;
            }
        }

        private async void remove_security_key(string id) {
            if (pin_cache == "") {
                security_group.add_row(new ActionRow(_("Unlock the Key with its PIN first."), "", "dialog-warning-symbolic"));
                return;
            }
            try {
                yield Client.get_default().remove_security_key(drive, pin_cache, id);
            } catch (KeyError e) {
                security_group.add_row(new ActionRow(e.message, "", "dialog-warning-symbolic"));
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
                file = yield SidebarWait.save_file(this, dialog, null);
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
            drop_button = row_button(_("Set PIN and Remove Security Keys"), false);
            drop_button.add_css_class("destructive-action");
            drop_button.visible = strong;
            var drop_row = new ActionRow(_("Lost the Security Keys Too?"), _("The Key goes back to PIN and computer only."), "security-high-symbolic");
            drop_row.add_suffix(drop_button);
            drop_button.bind_property("visible", drop_row, "visible", BindingFlags.SYNC_CREATE);
            recovery_group.add_row(code);
            recovery_group.add_row(fresh);
            recovery_group.add_row(drop_row);
            recovery_group.add_row(status);
            reset.clicked.connect(() => recover.begin(code, fresh, status, false));
            drop_button.clicked.connect(() => recover.begin(code, fresh, status, true));
        }

        private async void recover(EntryRow code, PasswordRow fresh, Label status, bool drop) {
            status.visible = true;
            try {
                if (drop) yield Client.get_default().recover_without_security_keys(drive, code.text, fresh.text);
                else yield Client.get_default().recover(drive, code.text, fresh.text);
                code.text = fresh.text = "";
                status.label = _("New PIN set. Unlock the Key with it.");
                yield refresh();
            } catch (KeyError e) {
                status.label = e.message;
            }
        }
    }
}
