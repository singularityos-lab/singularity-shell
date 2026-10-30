using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class SavedNetworksPage : SettingsPage {
        public SavedNetworksPage(SettingsView view, NetworkManagerWrapper network) {
            base(_("Saved Networks"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("network"));
            var group = new PreferencesGroup(null);
            var saved = network.saved_wifi_connections();
            for (int i = 0; i < saved.length; i++) {
                var conn = saved.get(i);
                string name = conn.get_id();
                var row = new ActionRow(name, null, "network-wireless-symbolic");
                row.activatable = true;
                row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
                var click = new GestureClick();
                click.released.connect(() => {
                    view.open_subpage(new ConnectionDetailPage(view, network, conn, name, null),
                        "connection-detail");
                });
                row.add_controller(click);
                group.add_row(row);
            }
            add_group(group);
        }
    }

    public class ConnectionDetailPage : SettingsPage {
        private const double LINK_CEILING = 125000000.0;

        private NetworkManagerWrapper network;
        private NM.RemoteConnection conn;
        private string? wired_iface;
        private uint timer = 0;
        private uint64 last_rx = 0;
        private uint64 last_tx = 0;
        private string? sampled_iface = null;

        private PreferencesGroup traffic_group;
        private ActionRow down_row;
        private ActionRow up_row;
        private SparkLine down_line;
        private SparkLine up_line;
        private PreferencesGroup status_group;
        private ActionRow address_row;
        private ActionRow gateway_row;
        private ActionRow dns_row;
        private ActionRow hardware_row;
        private ActionRow speed_row;
        private ActionRow disconnect_row;
        private SelectionRow method_row;
        private EntryRow address_entry;
        private EntryRow gateway_entry;
        private EntryRow dns_entry;
        private SwitchRow only_dns_row;
        private SwitchRow auto_row;
        private Label error_label;

        public ConnectionDetailPage(SettingsView view, NetworkManagerWrapper network,
                                    NM.RemoteConnection conn, string title, string? wired_iface) {
            base(title);
            this.network = network;
            this.conn = conn;
            this.wired_iface = wired_iface;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("network"));

            traffic_group = new PreferencesGroup(_("Traffic"));
            down_row = traffic_row(_("Download"), "go-down-symbolic", out down_line);
            up_row = traffic_row(_("Upload"), "go-up-symbolic", out up_line);
            traffic_group.add_row(down_row);
            traffic_group.add_row(up_row);
            add_group(traffic_group);

            status_group = new PreferencesGroup(_("Status"));
            address_row = new ActionRow(_("IP Address"), null, "network-workgroup-symbolic");
            gateway_row = new ActionRow(_("Gateway"), null, "network-server-symbolic");
            dns_row = new ActionRow(_("DNS"), null, "network-transmit-receive-symbolic");
            hardware_row = new ActionRow(_("Hardware Address"), null, "network-wired-symbolic");
            speed_row = new ActionRow(_("Link Speed"), null, "preferences-other-symbolic");
            status_group.add_row(address_row);
            status_group.add_row(gateway_row);
            status_group.add_row(dns_row);
            status_group.add_row(hardware_row);
            status_group.add_row(speed_row);
            add_group(status_group);

            add_group(build_ipv4_group());
            add_group(build_actions_group(view));

            error_label = new Label("");
            error_label.add_css_class("error-label");
            error_label.wrap = true;
            error_label.justify = Justification.CENTER;
            error_label.margin_top = 8;
            error_label.visible = false;
            content_box.append(error_label);

            var action_bar = new Box(Orientation.HORIZONTAL, 0);
            action_bar.add_css_class("page-action-bar");
            action_bar.margin_top = 10;
            action_bar.margin_bottom = 14;
            action_bar.margin_start = 16;
            action_bar.margin_end = 16;
            var save_btn = new Button.with_label(_("Apply"));
            save_btn.add_css_class("pill");
            save_btn.add_css_class("suggested-action");
            save_btn.hexpand = true;
            save_btn.clicked.connect(() => save.begin());
            action_bar.append(save_btn);
            append(action_bar);

            ulong state = network.state_changed.connect(refresh_status);
            destroy.connect(() => network.disconnect(state));
            map.connect(() => {
                refresh_status();
                if (timer == 0) timer = Timeout.add_seconds(1, sample);
            });
            unmap.connect(() => {
                if (timer != 0) Source.remove(timer);
                timer = 0;
            });
        }

        private ActionRow traffic_row(string title, string icon, out SparkLine line) {
            var row = new ActionRow(title, null, icon);
            line = new SparkLine(60);
            line.hexpand = false;
            line.vexpand = false;
            line.valign = Align.CENTER;
            line.set_size_request(160, 32);
            row.add_suffix(line);
            return row;
        }

        private PreferencesGroup build_ipv4_group() {
            var group = new PreferencesGroup(_("IPv4"));
            var s_ip4 = conn.get_setting_ip4_config();
            bool manual = s_ip4 != null && s_ip4.method == "manual";
            string automatic = _("Automatic (DHCP)");
            string by_hand = _("Manual");
            method_row = new SelectionRow(_("Method"), { automatic, by_hand },
                manual ? by_hand : automatic);
            method_row.icon_name = "preferences-other-symbolic";
            group.add_row(method_row);

            address_entry = new EntryRow(_("Address"), "network-workgroup-symbolic");
            address_entry.placeholder_text = "192.168.1.20/24";
            gateway_entry = new EntryRow(_("Gateway"), "network-server-symbolic");
            gateway_entry.placeholder_text = "192.168.1.1";
            dns_entry = new EntryRow(_("DNS Servers"), "network-transmit-receive-symbolic");
            dns_entry.placeholder_text = "9.9.9.9, 1.1.1.1";
            only_dns_row = new SwitchRow(_("Use Only These DNS Servers"), _("Ignore the ones offered by the network"),
                s_ip4 != null && s_ip4.ignore_auto_dns);
            group.add_row(address_entry);
            group.add_row(gateway_entry);
            group.add_row(dns_entry);
            group.add_row(only_dns_row);

            if (s_ip4 != null) {
                if (s_ip4.get_num_addresses() > 0) {
                    unowned var first = s_ip4.get_address(0);
                    address_entry.text = "%s/%u".printf(first.get_address(), first.get_prefix());
                }
                gateway_entry.text = s_ip4.gateway ?? "";
                string[] servers = {};
                for (uint i = 0; i < s_ip4.get_num_dns(); i++) servers += s_ip4.get_dns((int) i);
                dns_entry.text = string.joinv(", ", servers);
            }
            method_row.selected.connect((item) => set_manual(item == by_hand));
            set_manual(manual);
            return group;
        }

        private void set_manual(bool manual) {
            address_entry.visible = manual;
            gateway_entry.visible = manual;
            only_dns_row.visible = !manual;
        }

        private PreferencesGroup build_actions_group(SettingsView view) {
            var group = new PreferencesGroup(_("Connection"));
            var s_con = conn.get_setting_connection();
            auto_row = new SwitchRow(_("Connect Automatically"), null,
                s_con == null || s_con.autoconnect);
            auto_row.icon_name = "view-refresh-symbolic";
            group.add_row(auto_row);

            disconnect_row = new ActionRow(_("Disconnect"), null, "network-offline-symbolic");
            disconnect_row.activatable = true;
            var disconnect_click = new GestureClick();
            disconnect_click.released.connect(() => network.disconnect_connection.begin(conn));
            disconnect_row.add_controller(disconnect_click);
            group.add_row(disconnect_row);

            var forget_row = new ActionRow(_("Forget This Network"), null, "user-trash-symbolic");
            forget_row.activatable = true;
            var forget_click = new GestureClick();
            forget_click.released.connect(() => {
                forget_row.confirmation_requested(_("Forget"), _("Cancel"),
                    ConfirmationSuggestedAction.CANCEL);
            });
            forget_row.add_controller(forget_click);
            forget_row.confirmed.connect(() => {
                network.forget_connection.begin(conn, (obj, res) => {
                    network.forget_connection.end(res);
                    view.navigate_to("network");
                });
            });
            group.add_row(forget_row);
            return group;
        }

        private async void save() {
            error_label.visible = false;
            string[] servers = {};
            foreach (var part in dns_entry.text.split(",")) {
                string server = part.strip();
                if (server != "") servers += server;
            }
            bool manual = address_entry.visible;
            string? failure = yield network.save_ipv4(conn, manual, address_entry.text,
                gateway_entry.text, servers, only_dns_row.active, auto_row.active);
            if (failure != null) {
                error_label.label = failure;
                error_label.visible = true;
            }
        }

        private NM.Device? current_device() {
            return network.active_device(conn);
        }

        private void refresh_status() {
            var device = current_device();
            bool active = device != null;
            traffic_group.visible = active;
            status_group.visible = active;
            disconnect_row.visible = active;
            if (!active) return;
            var ip4 = device.get_ip4_config();
            string address = "";
            string gateway = "";
            string dns = "";
            if (ip4 != null) {
                var addresses = ip4.get_addresses();
                if (addresses.length > 0) {
                    unowned var first = addresses.get(0);
                    address = "%s/%u".printf(first.get_address(), first.get_prefix());
                }
                gateway = ip4.get_gateway() ?? "";
                var servers = ip4.get_nameservers();
                if (servers != null) dns = string.joinv(", ", servers);
            }
            address_row.subtitle = address != "" ? address : _("None");
            gateway_row.subtitle = gateway != "" ? gateway : _("None");
            dns_row.subtitle = dns != "" ? dns : _("None");
            hardware_row.subtitle = device.get_hw_address() ?? _("Unknown");
            uint speed = 0;
            if (device is NM.DeviceWifi) speed = ((NM.DeviceWifi) device).get_bitrate() / 1000;
            else if (device is NM.DeviceEthernet) speed = ((NM.DeviceEthernet) device).get_speed();
            speed_row.subtitle = speed > 0 ? "%u Mb/s".printf(speed) : _("Unknown");
        }

        private static uint64 read_counter(string iface, string name) {
            string text;
            try {
                FileUtils.get_contents("/sys/class/net/%s/statistics/%s".printf(iface, name), out text);
            } catch (Error e) {
                return 0;
            }
            return uint64.parse(text.strip());
        }

        private static double scaled(double rate) {
            return (Math.log10(1.0 + rate) / Math.log10(1.0 + LINK_CEILING)).clamp(0.0, 1.0);
        }

        private bool sample() {
            var device = current_device();
            string? iface = device != null ? device.get_iface() : wired_iface;
            if (iface == null || device == null) return Source.CONTINUE;
            uint64 rx = read_counter(iface, "rx_bytes");
            uint64 tx = read_counter(iface, "tx_bytes");
            if (sampled_iface == iface) {
                double down = rx >= last_rx ? (double) (rx - last_rx) : 0.0;
                double up = tx >= last_tx ? (double) (tx - last_tx) : 0.0;
                down_line.push(scaled(down));
                up_line.push(scaled(up));
                down_row.subtitle = _("%s/s").printf(format_size((uint64) down));
                up_row.subtitle = _("%s/s").printf(format_size((uint64) up));
            }
            sampled_iface = iface;
            last_rx = rx;
            last_tx = tx;
            return Source.CONTINUE;
        }
    }
}
