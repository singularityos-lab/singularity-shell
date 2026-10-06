using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class NearbyBluetoothGroup : PreferencesGroup {
        private NearbyClient client;
        private ulong changed_id = 0;
        private string status = "";

        public NearbyBluetoothGroup() {
            base(_("File Transfer"), _("Send files to paired devices. Files other devices send you need your approval."));
            client = NearbyClient.get_default();
            visible = false;
            changed_id = client.changed.connect(() => fill.begin());
            client.transfer_finished.connect((id, ok, detail) => {
                status = ok ? _("Sent") : detail;
                fill.begin();
            });
            destroy.connect(() => client.disconnect(changed_id));
            client.start();
            fill.begin();
        }

        private async void fill() {
            if (!client.available || !client.bluetooth_available) {
                visible = false;
                return;
            }
            var devices = yield client.list("ListBluetoothDevices");
            clear();
            visible = devices.length > 0;
            foreach (var d in devices) {
                string address = NearbyClient.text_of(d, "address");
                string name = NearbyClient.text_of(d, "name");
                var row = new ActionRow(name, status != "" ? status : _("Accepts files"), NearbyClient.text_of(d, "icon", "bluetooth-symbolic"));
                var send = new Button.with_label(_("Send Files…"));
                send.valign = Align.CENTER;
                send.clicked.connect(() => choose_files(address));
                row.add_suffix(send);
                add_row(row);
            }
        }

        private void choose_files(string address) {
            var dialog = new FileDialog();
            dialog.title = _("Send Files");
            dialog.open_multiple.begin(get_root() as Gtk.Window, null, (o, r) => {
                try {
                    var model = dialog.open_multiple.end(r);
                    File[] files = {};
                    for (uint i = 0; i < model.get_n_items(); i++) files += (File) model.get_item(i);
                    if (files.length == 0) return;
                    status = _("Sending…");
                    fill.begin();
                    client.bluetooth_send_files.begin(address, files, (o2, r2) => {
                        try {
                            client.bluetooth_send_files.end(r2);
                        } catch (Error e) {
                            status = e.message;
                            fill.begin();
                        }
                    });
                } catch (Error e) {
                }
            });
        }
    }
}
