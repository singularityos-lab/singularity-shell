using Gtk;
using Singularity.Widgets;
using Singularity.SintyCore;

namespace Singularity.SidebarPages {

    public class SintyCorePage : SettingsPage {
        private const string[] FORMS = { "laptop", "desktop", "tv", "headless" };
        private const string[] USB_MODES = { "off", "network", "disk" };

        private Client client;
        private PreferencesGroup request_group;
        private ActionRow waiting_row;
        private EntryRow code_row;
        private Label status;
        private PreferencesGroup screens_group;
        private PreferencesGroup device_group;
        private Button add_button;
        private SelectionRow form_row;
        private SelectionRow usb_row;
        private ActionRow phone_row;
        private ActionRow key_row;
        private PreferencesGroup backup_group;
        private ActionRow lost_row;
        private Label backup_status;
        private PreferencesGroup code_group;
        private ActionRow code_value;
        private PreferencesGroup restore_group;
        private ActionRow file_row;
        private EntryRow recovery_row;
        private Label restore_status;
        private Button restore_button;
        private string? source = null;
        private bool syncing = false;
        private ulong changed_id = 0;
        private ulong request_id = 0;
        private ulong finished_id = 0;

        public SintyCorePage(SettingsView view) {
            base(_("Screens"));
            client = Client.get_default();

            request_group = new PreferencesGroup(_("Pair a Screen"),
                _("Start Sinty Screen on the TV or monitor. It shows a code to type here."));
            var cancel = new Button.with_label(_("Cancel"));
            cancel.valign = Align.CENTER;
            cancel.clicked.connect(() => cancel_pairing.begin());
            request_group.add_header_suffix(cancel);
            waiting_row = new ActionRow(_("Waiting for a screen"), "", "video-display-symbolic");
            request_group.add_row(waiting_row);
            code_row = new EntryRow(_("Code"));
            var pair = row_button(_("Pair"), true);
            pair.clicked.connect(() => confirm.begin());
            code_row.add_suffix(pair);
            code_row.entry_activated.connect(() => confirm.begin());
            request_group.add_row(code_row);
            status = status_label();
            request_group.add_row(status);
            add_group(request_group);

            screens_group = new PreferencesGroup(_("Paired Screens"),
                _("Screens that can show this computer's desktop and send keyboard and pointer input to it."));
            add_button = new Button.with_label(_("Pair a Screen…"));
            add_button.valign = Align.CENTER;
            add_button.clicked.connect(() => start_pairing.begin());
            screens_group.add_header_suffix(add_button);
            add_group(screens_group);

            device_group = new PreferencesGroup(_("This Computer"));
            string[] form_labels = { _("Laptop"), _("Desktop"), _("TV"), _("Core without a screen") };
            form_row = new SelectionRow(_("Used As"), form_labels, form_labels[0]);
            form_row.selected.connect((item) => {
                if (syncing) return;
                int i = index_of(form_labels, item);
                if (i >= 0) set_form.begin(FORMS[i]);
            });
            device_group.add_row(form_row);
            string[] usb_labels = { _("Off"), _("Network Adapter"), _("Disk") };
            usb_row = new SelectionRow(_("USB-C Port"), usb_labels, usb_labels[0]);
            usb_row.subtitle = _("How this computer appears to a computer it is plugged into");
            usb_row.selected.connect((item) => {
                if (syncing) return;
                int i = index_of(usb_labels, item);
                if (i >= 0) set_usb.begin(USB_MODES[i]);
            });
            usb_row.visible = Client.has_usb_port();
            device_group.add_row(usb_row);
            phone_row = new ActionRow(_("Phone"), "", "phone-symbolic");
            device_group.add_row(phone_row);
            key_row = new ActionRow(_("Screen Key"), "", "channel-secure-symbolic");
            device_group.add_row(key_row);
            add_group(device_group);

            backup_group = new PreferencesGroup(_("Backup"),
                _("One encrypted file with the screen key of this computer and the paired screens. It opens only with the recovery code shown when it is saved."));
            lost_row = new ActionRow(_("The screen key was lost"),
                _("The security chip no longer opens it, so paired screens cannot connect. Restore a backup or pair them again."), "dialog-warning-symbolic");
            backup_group.add_row(lost_row);
            var save_row = new ActionRow(_("Back Up Screens"), _("Save the backup on another drive or online"), "document-save-symbolic");
            var save = row_button(_("Back Up…"), false);
            save.clicked.connect(() => back_up.begin(save));
            save_row.add_suffix(save);
            backup_group.add_row(save_row);
            backup_status = status_label();
            backup_group.add_row(backup_status);
            add_group(backup_group);

            code_group = new PreferencesGroup(_("Recovery Code"),
                _("Write it down and keep it apart from the backup. Without it the backup cannot be opened."));
            code_value = new ActionRow("", "", "dialog-password-symbolic");
            var copy = new Button.from_icon_name("edit-copy-symbolic");
            copy.add_css_class("flat");
            copy.valign = Align.CENTER;
            copy.tooltip_text = _("Copy");
            copy.clicked.connect(() => get_clipboard().set_text(code_value.title));
            code_value.add_suffix(copy);
            code_group.add_row(code_value);
            code_group.visible = false;
            add_group(code_group);

            restore_group = new PreferencesGroup(_("Restore from a Backup"),
                _("This computer takes the screen key from the backup, and the screens paired before connect again. Screens paired since the backup have to be paired again."));
            file_row = new ActionRow(_("Backup File"), _("None chosen"), "document-open-symbolic");
            var choose = row_button(_("Choose…"), false);
            choose.clicked.connect(() => choose_file.begin());
            file_row.add_suffix(choose);
            restore_group.add_row(file_row);
            recovery_row = new EntryRow(_("Recovery Code"));
            recovery_row.placeholder_text = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX";
            restore_button = row_button(_("Restore"), true);
            restore_button.clicked.connect(() => restore.begin());
            recovery_row.add_suffix(restore_button);
            recovery_row.entry_activated.connect(() => restore.begin());
            restore_group.add_row(recovery_row);
            restore_status = status_label();
            restore_group.add_row(restore_status);
            add_group(restore_group);

            add_search_action(_("Pair a Screen"), _("Sinty Core, screen, TV, monitor, thin client, stream, desktop"), () => start_pairing.begin());
            add_search_action(_("Back Up Screens"), _("Sinty Core, screen, backup, restore, recovery code"), () => back_up.begin(save));

            changed_id = client.changed.connect(() => sync());
            request_id = client.pairing_request.connect((screen) => {
                code_row.text = "";
                status.visible = false;
                sync();
                code_row.grab_focus();
            });
            finished_id = client.pairing_finished.connect((screen, result) => finished(screen, result));
            destroy.connect(() => {
                client.disconnect(changed_id);
                client.disconnect(request_id);
                client.disconnect(finished_id);
            });
            map.connect(() => client.start.begin());
            sync();
        }

        public static void open(SettingsView view) {
            var page = new SintyCorePage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("connected-devices"));
            view.open_subpage(page, "sinty-core");
        }

        private static int index_of(string[] list, string item) {
            for (int i = 0; i < list.length; i++) {
                if (list[i] == item) return i;
            }
            return -1;
        }

        private static string phone_address(string path) {
            string tail = Path.get_basename(path);
            return tail.has_prefix("dev_") ? tail.substring(4).replace("_", ":") : tail;
        }

        private void sync() {
            syncing = true;
            request_group.visible = client.pairing;
            add_button.visible = !client.pairing;
            bool asked = client.pairing_screen != "";
            waiting_row.visible = !asked;
            code_row.visible = asked;
            if (asked) {
                code_row.title = _("Code shown on %s").printf(client.pairing_screen);
                code_row.placeholder_text = _("6 digits");
            }
            if (!asked) waiting_row.subtitle = client.direct != ""
                ? _("On the screen, join the Wi-Fi network %s").printf(client.direct)
                : _("The screen must be on the same network or plugged in with a cable");

            screens_group.clear();
            foreach (var s in client.screens) {
                var row = new ActionRow(s.name, s.connected ? _("Showing the desktop") : _("Not connected"), "video-display-symbolic");
                var remove = row_button(_("Remove"), false);
                remove.add_css_class("destructive-action");
                string id = s.id;
                remove.clicked.connect(() => revoke.begin(id));
                row.add_suffix(remove);
                screens_group.add_row(row);
            }
            if (client.screens.size == 0) screens_group.add_row(new ActionRow(_("No screens yet"), "", "video-display-symbolic"));

            int f = index_of(FORMS, client.form);
            form_row.visible = f >= 0;
            if (f >= 0) form_row.selected_index = f;
            int u = index_of(USB_MODES, client.usb_mode);
            if (u >= 0) usb_row.selected_index = u;
            phone_row.visible = client.phone != "";
            phone_row.subtitle = _("Last command from %s").printf(phone_address(client.phone));
            key_row.visible = client.identity != "";
            switch (client.identity) {
                case "tpm":
                    key_row.subtitle = _("Sealed in the security chip");
                    break;
                case "replaced":
                    key_row.subtitle = _("New, the previous key was lost");
                    break;
                default:
                    key_row.subtitle = _("Kept in a file, this computer has no security chip");
                    break;
            }
            lost_row.visible = client.identity == "replaced";
            syncing = false;
        }

        private void show_error(string message) {
            request_group.visible = true;
            status.label = message;
            status.visible = true;
        }

        private async void start_pairing() {
            status.visible = false;
            string ssid = "", passphrase = "";
            try {
                string route = yield client.start_pairing();
                if (route == "direct") yield client.direct_network(out ssid, out passphrase);
            } catch (CoreError e) {
                show_error(e.message);
                return;
            }
            if (passphrase != "") waiting_row.subtitle = _("On the screen, join the Wi-Fi network %s with the password %s").printf(ssid, passphrase);
        }

        private async void confirm() {
            string code = code_row.text.replace(" ", "");
            if (code.length != 6) {
                show_error(_("The code has 6 digits."));
                return;
            }
            try {
                yield client.confirm_pairing(code);
            } catch (CoreError e) {
                show_error(e.message);
            }
        }

        private async void cancel_pairing() {
            try {
                yield client.cancel_pairing();
            } catch (CoreError e) {
                show_error(e.message);
            }
        }

        private void finished(string screen, string result) {
            switch (result) {
                case "paired":
                    status.visible = false;
                    break;
                case "wrong-code":
                    show_error(_("The code does not match. Type the new code shown on %s.").printf(screen));
                    break;
                case "cancelled":
                    status.visible = false;
                    break;
                default:
                    show_error(_("%s could not be paired.").printf(screen));
                    break;
            }
        }

        private async void revoke(string id) {
            try {
                yield client.revoke_screen(id);
            } catch (CoreError e) {
                show_error(e.message);
            }
        }

        private async void back_up(Button save) {
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Save Backup");
            dialog.initial_name = "%s.sintycore".printf(client.core_name != "" ? client.core_name : "screens");
            File? file = null;
            try {
                file = yield dialog.save(get_root() as Gtk.Window, null);
            } catch (Error e) {
                return;
            }
            if (file == null || file.get_path() == null) return;
            save.sensitive = false;
            backup_status.visible = true;
            backup_status.label = _("Backing up…");
            try {
                string code = yield client.backup(file.get_path());
                code_value.title = code;
                code_group.visible = true;
                backup_status.label = _("Backup saved as %s.").printf(file.get_basename());
            } catch (CoreError e) {
                backup_status.label = e.message;
            }
            save.sensitive = true;
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
            restore_status.visible = true;
            if (source == null) {
                restore_status.label = _("Choose the backup file first.");
                return;
            }
            if (recovery_row.text.strip() == "") {
                restore_status.label = _("Type the recovery code of the backup.");
                return;
            }
            restore_button.sensitive = false;
            restore_status.label = _("Restoring…");
            try {
                yield client.restore(source, recovery_row.text);
                recovery_row.text = "";
                restore_status.label = _("Restored. The screens in the backup can connect again.");
            } catch (CoreError e) {
                restore_status.label = e.message;
            }
            restore_button.sensitive = true;
        }

        private async void set_form(string form) {
            try {
                yield client.change_form(form);
            } catch (CoreError e) {
                show_error(e.message);
                sync();
            }
        }

        private async void set_usb(string mode) {
            try {
                yield client.change_usb_mode(mode);
            } catch (CoreError e) {
                show_error(e.message);
                sync();
            }
        }
    }
}
