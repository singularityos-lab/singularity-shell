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
            add_group(device_group);

            add_search_action(_("Pair a Screen"), _("Sinty Core, screen, TV, monitor, thin client, stream, desktop"), () => start_pairing.begin());

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
