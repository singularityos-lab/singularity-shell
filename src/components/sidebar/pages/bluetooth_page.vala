using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class BluetoothPage : SettingsPage {
        private BluetoothManager manager;
        private SwitchRow power_row;
        private PreferencesGroup devices_group;
        private bool _syncing = false;
        private uint _refresh_id = 0;

        public BluetoothPage(SettingsView view) {
            base(_("Bluetooth"));
            back_clicked.connect(() => {
                view.go_home();
            });
            manager = SystemMonitor.get_default().bluetooth;
            build_ui();
            manager.state_changed.connect(update_state);
            manager.device_added.connect((d) => update_devices());
            manager.device_removed.connect((p) => update_devices());
            manager.device_changed.connect((p) => update_devices());
            update_state();
            update_devices();
        }

        private void build_ui() {
            var group = new PreferencesGroup(_("General"));
            power_row = new SwitchRow(_("Bluetooth"), _("Turn Bluetooth on or off"), false);
            power_row.switch_btn.notify["active"].connect(() => {
                if (_syncing) return;
                manager.set_power.begin(power_row.active);
            });
            group.add_row(power_row);
            add_group(group);
            devices_group = new PreferencesGroup(_("Devices"));
            add_group(devices_group);
            add_group(new NearbyBluetoothGroup());
        }

        private void update_state() {
            if (power_row.active != manager.is_powered) {
                _syncing = true;
                power_row.active = manager.is_powered;
                _syncing = false;
            }
            devices_group.visible = manager.is_powered;
            if (manager.is_powered && !manager.is_discovering) {
                manager.start_discovery.begin();
            } else if (!manager.is_powered && manager.is_discovering) {
                manager.stop_discovery.begin();
            }
            if (manager.is_powered) {
                if (_refresh_id == 0) {
                    _refresh_id = Timeout.add_seconds(3, () => {
                        manager.refresh.begin();
                        return Source.CONTINUE;
                    });
                }
            } else {
                stop_refresh();
            }
        }

        private void stop_refresh() {
            if (_refresh_id != 0) {
                Source.remove(_refresh_id);
                _refresh_id = 0;
            }
        }

        private void update_devices() {
            devices_group.clear();
            if (manager.devices.length() == 0) {
                var empty = new ActionRow(_("No devices found"));
                empty.sensitive = false;
                devices_group.add_row(empty);
                return;
            }
            foreach (var device in manager.devices) {
                string dev_path = device.path;
                string? status = device.connected ? _("Connected") :
                    (device.paired ? _("Paired") : null);
                if (device.connected && device.battery >= 0) {
                    status = _("%s · %d%%").printf(status, device.battery);
                }
                var row = new ActionRow(device.name, status,
                    BluetoothManager.bt_icon_for(device.icon));
                row.activatable = false;
                if (manager.connecting_path == dev_path) {
                    var spinner = new Spinner();
                    spinner.spinning = true;
                    spinner.tooltip_text = _("Connecting...");
                    row.add_suffix(spinner);
                } else {
                    var btn = new Button();
                    btn.add_css_class("flat");
                    if (device.connected) {
                        btn.icon_name = "network-offline-symbolic";
                        btn.tooltip_text = _("Disconnect");
                        btn.clicked.connect(() => {
                            manager.disconnect_device.begin(dev_path);
                        });
                    } else {
                        btn.icon_name = "network-transmit-receive-symbolic";
                        btn.tooltip_text = _("Connect");
                        btn.clicked.connect(() => {
                            manager.connect_device.begin(dev_path);
                        });
                    }
                    row.add_suffix(btn);
                }
                if (device.paired) {
                    var forget_btn = new Button.from_icon_name("user-trash-symbolic");
                    forget_btn.add_css_class("flat");
                    forget_btn.tooltip_text = _("Forget Device");
                    forget_btn.clicked.connect(() => {
                        row.confirmation_requested(_("Forget"), _("Cancel"),
                            ConfirmationSuggestedAction.CANCEL);
                    });
                    row.confirmed.connect(() => {
                        manager.remove_device.begin(dev_path);
                    });
                    row.add_suffix(forget_btn);
                }
                devices_group.add_row(row);
            }
        }

        public override void dispose() {
            stop_refresh();
            if (manager.is_discovering) {
                manager.stop_discovery.begin();
            }
            base.dispose();
        }
    }
}
