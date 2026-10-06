using Gtk;
using Singularity.Widgets;

namespace Singularity {

    /**
     * Native "Add VPN" page - a multi-level settings page (with a back arrow,
     * like the Applications page), not a popup dialog or an external settings
     * app. Lets the user enter a WireGuard or OpenVPN
     * connection by hand. The work is done by NetworkManagerWrapper, which
     * reports success/failure via vpn_action_result (shown on the Network page).
     */
    public class VpnConfigPage : SettingsPage {
        private NetworkManagerWrapper network;
        private SettingsView view;

        private SelectionRow type_row;
        private EntryRow name_row;
        private PreferencesGroup wg_group;
        private PreferencesGroup ov_group;
        private Label error_label;

        // WireGuard
        private PasswordRow wg_privkey;
        private EntryRow wg_address;
        private EntryRow wg_dns;
        private EntryRow wg_peer_pubkey;
        private EntryRow wg_endpoint;
        private EntryRow wg_allowed;
        private PasswordRow wg_psk;

        // OpenVPN
        private EntryRow ov_gateway;
        private EntryRow ov_username;
        private PasswordRow ov_password;
        private EntryRow ov_ca;

        public VpnConfigPage(SettingsView view, NetworkManagerWrapper network) {
            base(_("Add VPN"));
            this.network = network;
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("network"));

            // Connection type + name.
            var general = new PreferencesGroup(_("Connection"));
            type_row = new SelectionRow(_("Type"), { _("WireGuard"), _("OpenVPN") }, _("WireGuard"));
            type_row.selected.connect((item) => set_type(item));
            general.add_row(type_row);
            name_row = new EntryRow("Name");
            general.add_row(name_row);
            add_group(general);

            wg_group = build_wireguard_group();
            add_group(wg_group);
            ov_group = build_openvpn_group();
            add_group(ov_group);
            set_type("WireGuard");

            error_label = new Label("");
            error_label.add_css_class("error-label");
            error_label.wrap = true;
            error_label.justify = Justification.CENTER;
            error_label.margin_top = 8;
            error_label.visible = false;
            content_box.append(error_label);

            // Pinned action bar at the bottom of the page (below the scroller).
            var action_bar = new Box(Orientation.HORIZONTAL, 0);
            action_bar.add_css_class("page-action-bar");
            action_bar.margin_top = 10;
            action_bar.margin_bottom = 14;
            action_bar.margin_start = 16;
            action_bar.margin_end = 16;
            var add_btn = new Button.with_label(_("Add VPN"));
            add_btn.add_css_class("pill");
            add_btn.add_css_class("suggested-action");
            add_btn.hexpand = true;
            add_btn.clicked.connect(on_save);
            action_bar.append(add_btn);
            append(action_bar);
        }

        private void set_type(string item) {
            bool wg = (item == "WireGuard");
            wg_group.visible = wg;
            ov_group.visible = !wg;
        }

        private PreferencesGroup build_wireguard_group() {
            var group = new PreferencesGroup(_("WireGuard"));
            wg_privkey = new PasswordRow("Private Key");
            group.add_row(wg_privkey);
            wg_address = new EntryRow("Address (e.g. 10.0.0.2/32)");
            group.add_row(wg_address);
            wg_dns = new EntryRow("DNS (optional)");
            group.add_row(wg_dns);
            wg_peer_pubkey = new EntryRow("Peer Public Key");
            group.add_row(wg_peer_pubkey);
            wg_endpoint = new EntryRow("Endpoint (host:port)");
            group.add_row(wg_endpoint);
            wg_allowed = new EntryRow("Allowed IPs");
            wg_allowed.text = "0.0.0.0/0, ::/0";
            group.add_row(wg_allowed);
            wg_psk = new PasswordRow("Preshared Key (optional)");
            group.add_row(wg_psk);
            return group;
        }

        private PreferencesGroup build_openvpn_group() {
            var group = new PreferencesGroup(_("OpenVPN"));
            ov_gateway = new EntryRow("Gateway (host or host:port)");
            group.add_row(ov_gateway);
            ov_username = new EntryRow("Username");
            group.add_row(ov_username);
            ov_password = new PasswordRow("Password");
            group.add_row(ov_password);
            ov_ca = new EntryRow("CA Certificate path (optional)");
            group.add_row(ov_ca);
            return group;
        }

        private void show_error(string msg) {
            error_label.label = msg;
            error_label.visible = true;
        }

        private void on_save() {
            string name = name_row.text.strip();
            if (name == "") { show_error("Please enter a name for the connection."); return; }

            if (type_row.current_value == "WireGuard") {
                if (wg_privkey.text.strip() == "") { show_error("Private key is required."); return; }
                if (wg_peer_pubkey.text.strip() == "") { show_error("Peer public key is required."); return; }
                if (wg_endpoint.text.strip() == "") { show_error("Endpoint is required."); return; }
                network.add_wireguard.begin(
                    name, wg_privkey.text, wg_address.text, wg_dns.text,
                    wg_peer_pubkey.text, wg_endpoint.text, wg_allowed.text, wg_psk.text);
            } else {
                if (ov_gateway.text.strip() == "") { show_error("Gateway is required."); return; }
                if (ov_username.text.strip() == "") { show_error("Username is required."); return; }
                if (ov_password.text == "") { show_error("Password is required."); return; }
                string? ca = ov_ca.text.strip() == "" ? null : ov_ca.text.strip();
                network.add_openvpn.begin(name, ov_gateway.text.strip(),
                    ov_username.text.strip(), ov_password.text, ca);
            }
            // Return to the Network page so the new VPN (or any error) shows up.
            view.navigate_to("network");
        }
    }
}
