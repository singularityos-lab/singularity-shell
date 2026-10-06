using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class NetworkPage : SettingsPage {
        private PreferencesGroup vpn_error_group;
        private ActionRow vpn_error_row;

        private Widget build_wifi_actions(NetworkManagerWrapper network) {
            var group = new Box(Orientation.VERTICAL, 0);
            group.margin_start = 12;
            group.margin_end = 12;
            group.margin_bottom = 12;
            var buttons = new FlowBox();
            buttons.selection_mode = SelectionMode.NONE;
            buttons.homogeneous = false;
            buttons.column_spacing = 8;
            buttons.row_spacing = 8;
            buttons.max_children_per_line = 4;
            buttons.add_css_class("wifi-page-actions");
            group.append(buttons);
            var context = PluginManager.get_default().get_context();
            var shown = new HashTable<SettingsPageAction, Widget>(direct_hash, direct_equal);
            SyncCallback sync = () => {
                bool any = false;
                shown.foreach((action, child) => {
                    if (action.visible) any = true;
                });
                group.visible = any && network.has_wifi;
            };
            ActionCallback add = (action) => {
                if (action.page != SettingsPageAction.WIFI || shown.contains(action)) return;
                var content = new Box(Orientation.HORIZONTAL, 6);
                if (action.icon_name != null) content.append(new Image.from_icon_name(action.icon_name));
                var label = new Label(action.label);
                content.append(label);
                var button = new Button();
                button.set_child(content);
                button.add_css_class("pill");
                action.bind_property("label", label, "label");
                action.bind_property("visible", button, "visible", BindingFlags.SYNC_CREATE);
                action.notify["visible"].connect(() => sync());
                button.clicked.connect(() => action.activate());
                buttons.append(button);
                shown[action] = button.get_parent() ?? button;
                sync();
            };
            foreach (var action in context.get_settings_page_actions(SettingsPageAction.WIFI)) add(action);
            ulong added = context.settings_page_action_added.connect((action) => add(action));
            ulong removed = context.settings_page_action_removed.connect((action) => {
                var child = shown[action];
                if (child == null) return;
                buttons.remove(child);
                shown.remove(action);
                sync();
            });
            ulong state = network.state_changed.connect(() => sync());
            group.destroy.connect(() => {
                context.disconnect(added);
                context.disconnect(removed);
                network.disconnect(state);
            });
            sync();
            return group;
        }

        private delegate void SyncCallback();
        private delegate void ActionCallback(SettingsPageAction action);

        public NetworkPage(SettingsView view) {
            base(_("Network"));
            back_clicked.connect(() => {
                view.go_home();
            });
            var network = SystemMonitor.get_default().network;
            var wifi_group = new PreferencesGroup(_("Wi-Fi"));
            var toggle_row = new SwitchRow(_("Wi-Fi"), null, network.wifi_enabled);
            toggle_row.switch_btn.notify["active"].connect(() => {
                if (toggle_row.switch_btn.active != network.wifi_enabled) {
                    network.toggle_wifi();
                }
            });
            wifi_group.add_row(toggle_row);
            var network_rows = new List<Widget>();
            network.access_points_changed.connect(() => {
                update_networks_list(wifi_group, ref network_rows, network);
            });
            network.state_changed.connect(() => {
                if (toggle_row.switch_btn.active != network.wifi_enabled) {
                    toggle_row.switch_btn.active = network.wifi_enabled;
                }
                update_networks_list(wifi_group, ref network_rows, network);
            });
            update_networks_list(wifi_group, ref network_rows, network);
            network.wifi_connections_changed.connect(() => {
                update_networks_list(wifi_group, ref network_rows, network);
            });
            var plugin_context = PluginManager.get_default().get_context();
            ulong network_action_added = plugin_context.settings_page_action_added.connect((action) => {
                if (action.page == SettingsPageAction.WIFI_NETWORK)
                    update_networks_list(wifi_group, ref network_rows, network);
            });
            ulong network_action_removed = plugin_context.settings_page_action_removed.connect((action) => {
                if (action.page == SettingsPageAction.WIFI_NETWORK)
                    update_networks_list(wifi_group, ref network_rows, network);
            });
            wifi_group.destroy.connect(() => {
                plugin_context.disconnect(network_action_added);
                plugin_context.disconnect(network_action_removed);
            });
            network.request_scan();
            var scan_btn = new Button.from_icon_name("view-refresh-symbolic");
            scan_btn.add_css_class("navigation-button");
            scan_btn.clicked.connect(() => {
                network.request_scan();
            });
            header.append(scan_btn);
            add_group(wifi_group);
            add_group(build_wifi_actions(network));
            var wired_group = new PreferencesGroup(_("Wired"));
            var wired_rows = new List<Widget>();
            update_wired_list(wired_group, ref wired_rows, network);
            network.ethernet_ports_changed.connect(() => {
                update_wired_list(wired_group, ref wired_rows, network);
            });
            add_group(wired_group);

            var dynamic_group = new PreferencesGroup(_("Dynamic Internet"),
                _("Keeps available connections ready and switches when another link is healthier."));
            var dynamic_toggle = new SwitchRow(_("Dynamic Internet"),
                network.dynamic_internet.status, network.dynamic_internet.enabled);
            dynamic_group.add_row(dynamic_toggle);
            var dynamic_rows = new List<Widget>();
            update_dynamic_internet_list(dynamic_group, ref dynamic_rows,
                network.dynamic_internet);
            dynamic_toggle.switch_btn.notify["active"].connect(() => {
                if (dynamic_toggle.active != network.dynamic_internet.enabled)
                    network.set_dynamic_internet_enabled(dynamic_toggle.active);
            });
            network.dynamic_internet.changed.connect(() => {
                if (dynamic_toggle.active != network.dynamic_internet.enabled)
                    dynamic_toggle.active = network.dynamic_internet.enabled;
                dynamic_toggle.subtitle = network.dynamic_internet.status;
                update_dynamic_internet_list(dynamic_group, ref dynamic_rows,
                    network.dynamic_internet);
            });
            add_group(dynamic_group);

            var hs_settings = new GLib.Settings("dev.sinty.desktop");
            string init_ssid, init_pw; bool init_wpa3;
            ensure_hotspot_credentials(hs_settings, out init_ssid, out init_pw, out init_wpa3);

            var hs_group = new PreferencesGroup(_("Hotspot & Sharing"));
            var hotspot_row = new SwitchRow(_("Wi-Fi Hotspot"),
                _("Share your connection over Wi-Fi"), network.wifi_hotspot_active);
            var ssid_row = new EntryRow(_("Hotspot Name"));
            ssid_row.text = init_ssid;
            var pw_row = new EntryRow(_("Hotspot Password"));
            pw_row.text = init_pw;
            var wpa3_row = new SwitchRow(_("WPA3"),
                _("More secure, but newer devices only"), init_wpa3);
            var eth_row = new SwitchRow(_("Share to Wired Device"),
                _("Give internet to a device connected by cable"), network.ethernet_sharing_active);

            hotspot_row.visible = network.has_wifi;
            ssid_row.visible = network.has_wifi;
            pw_row.visible = network.has_wifi;
            wpa3_row.visible = network.has_wifi;
            eth_row.visible = network.has_ethernet;

            hs_group.add_row(hotspot_row);
            hs_group.add_row(ssid_row);
            hs_group.add_row(pw_row);
            hs_group.add_row(wpa3_row);
            hs_group.add_row(eth_row);
            add_group(hs_group);

            string pending_hotspot_ssid = "";
            string pending_hotspot_password = "";
            bool pending_hotspot_wpa3 = false;
            hotspot_row.confirmed.connect(() => {
                network.start_wifi_hotspot(pending_hotspot_ssid,
                    pending_hotspot_password, pending_hotspot_wpa3);
            });
            hotspot_row.confirmation_cancelled.connect(() => {
                hotspot_row.switch_btn.active = false;
            });
            hotspot_row.switch_btn.notify["active"].connect(() => {
                bool on = hotspot_row.switch_btn.active;
                if (on == network.wifi_hotspot_active) return;
                if (!on) { network.stop_wifi_hotspot(); return; }

                string ssid = ssid_row.text.strip();
                if (ssid == "") ssid = GLib.Environment.get_host_name();
                string pw = pw_row.text;
                if (pw.length < 8) { pw = NetworkManagerWrapper.generate_password(); pw_row.text = pw; }
                bool wpa3 = wpa3_row.switch_btn.active;
                hs_settings.set_string("hotspot-ssid", ssid);
                hs_settings.set_string("hotspot-password", pw);
                hs_settings.set_boolean("hotspot-wpa3", wpa3);

                if (network.hotspot_needs_disconnect()) {
                    pending_hotspot_ssid = ssid;
                    pending_hotspot_password = pw;
                    pending_hotspot_wpa3 = wpa3;
                    hotspot_row.confirmation_requested(_("Start Hotspot"), _("Cancel"),
                        ConfirmationSuggestedAction.CONFIRM);
                } else {
                    network.start_wifi_hotspot(ssid, pw, wpa3);
                }
            });

            eth_row.switch_btn.notify["active"].connect(() => {
                bool on = eth_row.switch_btn.active;
                if (on == network.ethernet_sharing_active) return;
                if (on) network.start_ethernet_sharing();
                else network.stop_ethernet_sharing();
            });

            network.hotspot_state_changed.connect(() => {
                if (hotspot_row.switch_btn.active != network.wifi_hotspot_active)
                    hotspot_row.switch_btn.active = network.wifi_hotspot_active;
                if (eth_row.switch_btn.active != network.ethernet_sharing_active)
                    eth_row.switch_btn.active = network.ethernet_sharing_active;
            });
            network.sharing_action_result.connect((ok, msg) => {
                if (!ok) {
                    warning("hotspot/sharing: %s", msg);
                    hotspot_row.switch_btn.active = network.wifi_hotspot_active;
                    eth_row.switch_btn.active = network.ethernet_sharing_active;
                }
            });

            var vpn_group = new PreferencesGroup(_("VPN"));
            var vpn_rows = new List<Widget>();
            update_vpn_list(vpn_group, ref vpn_rows, network);

            vpn_error_group = new PreferencesGroup();
            vpn_error_row = new ActionRow(_("VPN action failed"), "", "dialog-error-symbolic");
            var dismiss_error = new Button.from_icon_name("window-close-symbolic");
            dismiss_error.add_css_class("flat");
            dismiss_error.tooltip_text = _("Dismiss");
            dismiss_error.clicked.connect(() => vpn_error_group.visible = false);
            vpn_error_row.add_suffix(dismiss_error);
            vpn_error_group.add_row(vpn_error_row);
            vpn_error_group.visible = false;

            network.vpn_state_changed.connect(() => {
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });
            network.vpn_connections_changed.connect(() => {
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });
            network.vpn_action_result.connect(on_vpn_action_result);

            var vpn_registry = VpnProviderRegistry.get_default();
            foreach (var p in vpn_registry.list()) {
                p.changed.connect(() => update_vpn_list(vpn_group, ref vpn_rows, network));
                p.action_result.connect(on_vpn_action_result);
            }
            vpn_registry.added.connect((p) => {
                p.changed.connect(() => update_vpn_list(vpn_group, ref vpn_rows, network));
                p.action_result.connect(on_vpn_action_result);
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });
            vpn_registry.removed.connect((p) => {
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });

            add_group(vpn_group);
            add_group(vpn_error_group);

            var vpn_setup_group = new PreferencesGroup(_("VPN Profiles"));
            var add_row = new ActionRow(_("Add VPN"), _("Enter WireGuard or OpenVPN details"), "list-add-symbolic");
            add_row.activated.connect(() => {
                view.open_subpage(new VpnConfigPage(view, network), "vpn-config");
            });
            vpn_setup_group.add_row(add_row);

            var import_row = new ActionRow(_("Import VPN Configuration"), _("OpenVPN .ovpn, WireGuard .conf, or .nmconnection"), "document-open-symbolic");
            import_row.activated.connect(() => {
                var chooser = new FileDialog();
                chooser.title = _("Import VPN Configuration");
                var filter_store = new GLib.ListStore(typeof(Gtk.FileFilter));
                var vpn_filter = new Gtk.FileFilter();
                vpn_filter.name = "VPN Config Files";
                vpn_filter.add_pattern("*.ovpn");
                vpn_filter.add_pattern("*.conf");
                vpn_filter.add_pattern("*.nmconnection");
                filter_store.append(vpn_filter);
                var all_filter = new Gtk.FileFilter();
                all_filter.name = "All Files";
                all_filter.add_pattern("*");
                filter_store.append(all_filter);
                chooser.filters = filter_store;
                SidebarWait.choose_file.begin(this, chooser, null, (obj, res) => {
                    try {
                        var file = SidebarWait.choose_file.end(res);
                        if (file != null) {
                            var path = file.get_path();
                            if (path != null) {
                                network.import_vpn.begin(path);
                            }
                        }
                    } catch (Error e) {
                        if (!e.matches(Gtk.DialogError.quark(), Gtk.DialogError.DISMISSED))
                            on_vpn_action_result(false, e.message);
                    }
                });
            });
            vpn_setup_group.add_row(import_row);
            add_group(vpn_setup_group);

            var security_group = new PreferencesGroup(_("Security"));
            var firewall_row = new ActionRow(_("Firewall"), _("Profiles and allowed apps"), "security-high-symbolic");
            firewall_row.activatable = true;
            var firewall_chevron = new Image.from_icon_name("go-next-symbolic");
            firewall_chevron.pixel_size = 12;
            firewall_chevron.add_css_class("dim-label");
            firewall_chevron.valign = Align.CENTER;
            firewall_row.add_suffix(firewall_chevron);
            firewall_row.activated.connect(() => view.navigate_to("firewall"));
            security_group.add_row(firewall_row);
            add_group(security_group);
            add_search_action(_("Firewall"), _("Home and Public profiles, allowed apps and ports"),
                () => view.navigate_to("firewall"));
            var firewall = FirewallManager.get_default();
            firewall.changed.connect(() => {
                var st = firewall.current;
                if (firewall.backend == null) firewall_row.subtitle = _("Not available on this system");
                else if (st == null || !st.enabled) firewall_row.subtitle = _("Off");
                else firewall_row.subtitle = st.profile == FirewallProfile.PUBLIC ? _("On, Public network") : _("On, Home network");
            });
            firewall.refresh.begin();
        }

        public static void ensure_hotspot_credentials(GLib.Settings s,
                out string ssid, out string password, out bool wpa3) {
            ssid = s.get_string("hotspot-ssid");
            if (ssid == "") { ssid = GLib.Environment.get_host_name(); s.set_string("hotspot-ssid", ssid); }
            password = s.get_string("hotspot-password");
            if (password.length < 8) { password = NetworkManagerWrapper.generate_password(); s.set_string("hotspot-password", password); }
            wpa3 = s.get_boolean("hotspot-wpa3");
        }

        private void update_networks_list(PreferencesGroup group, ref List<Widget> rows, NetworkManagerWrapper network) {
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();
            if (!network.wifi_enabled) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("Wi-Fi is disabled"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            var aps = network.get_access_points();
            if (aps.length == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No networks found"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            var network_actions = PluginManager.get_default().get_context()
                .get_settings_page_actions(SettingsPageAction.WIFI_NETWORK);
            var entries = new GenericArray<WifiEntry>();
            var by_ssid = new HashTable<string, WifiEntry>(str_hash, str_equal);
            foreach (var ap in aps) {
                var ssid_bytes = ap.ssid;
                if (ssid_bytes == null) continue;
                string ssid = NM.Utils.ssid_to_utf8(ssid_bytes.get_data());
                if (ssid == "") continue;
                var known = by_ssid[ssid];
                if (known != null) {
                    if (ap.strength > known.ap.strength) known.ap = ap;
                    continue;
                }
                var entry = new WifiEntry(ap, ssid);
                entry.connected = network.is_wifi_connected(ssid);
                entry.saved = network.has_saved_wifi(ssid);
                by_ssid[ssid] = entry;
                entries.add(entry);
            }
            entries.sort((a, b) => {
                if (a.connected != b.connected) return a.connected ? -1 : 1;
                if (a.saved != b.saved) return a.saved ? -1 : 1;
                return (int) b.ap.strength - (int) a.ap.strength;
            });
            foreach (var entry in entries.data) {
                var ap = entry.ap;
                string ssid = entry.ssid;
                bool is_connected = entry.connected;
                var row = new ActionRow(ssid, null, signal_icon_name(ap.strength));
                row.activatable = true;
                if (is_connected) {
                    row.subtitle = _("Connected");
                    row.add_css_class("selected");
                } else if (entry.saved) {
                    row.subtitle = _("Saved");
                }
                if (entry.saved) add_network_actions(row, ssid, network_actions);
                if (ap.rsn_flags != NM.80211ApSecurityFlags.NONE || ap.wpa_flags != NM.80211ApSecurityFlags.NONE) {
                    var lock_icon = new Image.from_icon_name("channel-secure-symbolic");
                    lock_icon.add_css_class("dim-label");
                    lock_icon.tooltip_text = _("Secured");
                    lock_icon.update_property(AccessibleProperty.LABEL, _("Secured"), -1);
                    row.add_suffix(lock_icon);
                } else {
                    var lock_slot = new Box(Orientation.HORIZONTAL, 0);
                    lock_slot.width_request = 16;
                    row.add_suffix(lock_slot);
                }
                var gesture = new GestureClick();
                gesture.released.connect(() => {
                    if (is_connected) return;
                    if (entry.saved && network.activate_saved_wifi(ssid, ap)) return;
                    bool secured = (ap.rsn_flags != NM.80211ApSecurityFlags.NONE || ap.wpa_flags != NM.80211ApSecurityFlags.NONE);
                    if (secured) {
                        var dialog = new WifiPasswordDialog(ssid);
                        dialog.response.connect((accepted) => {
                            if (accepted) {
                                network.connect_to_ap(ap, dialog.password);
                            }
                        });
                        dialog.open_dialog();
                    } else {
                        network.connect_to_ap(ap, null);
                    }
                });
                row.add_controller(gesture);
                group.add_row(row);
                rows.append(row);
            }
        }

        private class WifiEntry {
            public NM.AccessPoint ap;
            public string ssid;
            public bool connected;
            public bool saved;

            public WifiEntry(NM.AccessPoint ap, string ssid) {
                this.ap = ap;
                this.ssid = ssid;
            }
        }

        private static string signal_icon_name(uint8 strength) {
            if (strength < 25) return "network-wireless-signal-weak-symbolic";
            if (strength < 50) return "network-wireless-signal-ok-symbolic";
            if (strength < 75) return "network-wireless-signal-good-symbolic";
            return "network-wireless-signal-excellent-symbolic";
        }

        private void update_dynamic_internet_list(PreferencesGroup group,
                                                  ref List<Widget> rows,
                                                  DynamicInternetManager manager) {
            foreach (var row in rows) group.remove_row(row);
            rows = new List<Widget>();
            if (!manager.enabled) return;

            foreach (var uplink in manager.get_uplinks()) {
                string icon;
                switch (uplink.kind) {
                    case InternetUplinkKind.ETHERNET: icon = "network-wired-symbolic"; break;
                    case InternetUplinkKind.WIFI: icon = "network-wireless-symbolic"; break;
                    case InternetUplinkKind.MOBILE: icon = "network-cellular-symbolic"; break;
                    default: icon = "network-transmit-receive-symbolic"; break;
                }

                string state;
                if (uplink.captive) state = _("Sign-in required");
                else if (!uplink.reachable) state = _("No internet access");
                else if (uplink.latency_ms >= 0)
                    state = _("%d ms · %d%% loss").printf(uplink.latency_ms,
                        uplink.loss_percent);
                else state = _("Internet available");

                var row = new ActionRow(uplink.display_name, state, icon);
                bool preferred = manager.preferred_id != ""
                    ? uplink.id == manager.preferred_id : uplink.primary;
                if (preferred) {
                    row.add_css_class("selected");
                    row.add_suffix(new Label(_("Preferred")));
                } else {
                    var standby = new Label(_("Standby"));
                    standby.add_css_class("dim-label");
                    row.add_suffix(standby);
                }
                group.add_row(row);
                rows.append(row);
            }

            if (manager.last_error != "") {
                var error = new ActionRow(_("Dynamic Internet error"), manager.last_error,
                    "dialog-error-symbolic");
                group.add_row(error);
                rows.append(error);
            }
        }

        private void add_network_actions(ActionRow row, string ssid, SettingsPageAction[] actions) {
            SettingsPageAction[] shown = {};
            foreach (var action in actions) {
                if (!action.visible) continue;
                shown += action;
                var button = new Button.from_icon_name(action.icon_name ?? "singularity-share-symbolic");
                button.add_css_class("flat");
                button.add_css_class("circular");
                button.valign = Align.CENTER;
                button.tooltip_text = action.label;
                button.update_property(AccessibleProperty.LABEL, action.label,
                    AccessibleProperty.DESCRIPTION, ssid, -1);
                button.clicked.connect(() => action.activate_for(ssid));
                row.add_suffix(button);
            }
            if (shown.length == 0) return;
            var menu_click = new GestureClick();
            menu_click.button = Gdk.BUTTON_SECONDARY;
            menu_click.pressed.connect((n, x, y) => {
                menu_click.set_state(EventSequenceState.CLAIMED);
                var menu = new Singularity.Widgets.ContextMenu(row);
                Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
                menu.set_pointing_to(rect);
                foreach (var action in shown) {
                    var captured = action;
                    menu.add_item(captured.label, captured.icon_name, () => captured.activate_for(ssid));
                }
                menu.popup();
            });
            row.add_controller(menu_click);
        }

        // One row per physical wired port, cable in or out -- a board can
        // have several (O6N: two 2.5GbE Realtek ports), and a single
        // "Connected"/"Not Connected" summary hid every port but whichever
        // one happened to be up.
        private void update_wired_list(PreferencesGroup group, ref List<Widget> rows, NetworkManagerWrapper network) {
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();
            var ports = network.ethernet_ports();
            if (ports.length == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No wired ports found"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            for (int i = 0; i < ports.length; i++) {
                var port = ports.get(i);
                string icon_name = port.connected
                    ? "network-wired-symbolic" : "network-wired-disconnected-symbolic";
                var row = new ActionRow(port.iface, null, icon_name);
                string chipset = port.chipset != "" ? port.chipset : _("Detecting…");
                string subtitle = port.capability != ""
                    ? "%s · %s".printf(chipset, port.capability) : chipset;
                row.subtitle = subtitle;
                if (port.connected) {
                    row.add_suffix(new Label(_("Connected")));
                    row.add_css_class("selected");
                } else {
                    var lbl = new Label(_("Not Connected"));
                    lbl.add_css_class("dim-label");
                    row.add_suffix(lbl);
                }
                group.add_row(row);
                rows.append(row);
            }
        }

        // Shows the result of import / manual-add / remove / provider actions.
        private void on_vpn_action_result(bool success, string message) {
            if (success) {
                vpn_error_group.visible = false;
                return;
            }
            vpn_error_row.subtitle = message;
            vpn_error_group.visible = true;
        }

        private void update_vpn_list(PreferencesGroup group, ref List<Widget> rows, NetworkManagerWrapper network) {
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();

            int total = 0;

            foreach (var vpn_conn in network.get_vpn_connections()) {
                var row = build_nm_vpn_row(vpn_conn, network);
                group.add_row(row);
                rows.append(row);
                total++;
            }

            foreach (var provider in VpnProviderRegistry.get_default().list()) {
                foreach (var conn in provider.get_connections()) {
                    var row = build_provider_vpn_row(conn);
                    group.add_row(row);
                    rows.append(row);
                    total++;
                }
            }

            if (total == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No VPN connections configured"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
            }
        }

        private Widget build_nm_vpn_row(NM.RemoteConnection vpn_conn, NetworkManagerWrapper network) {
            string name = vpn_conn.get_id();
            var link_state = network.vpn_link_state(vpn_conn);

            string state_str;
            switch (link_state) {
                case NetworkManagerWrapper.VpnLinkState.CONNECTED:  state_str = _("Connected"); break;
                case NetworkManagerWrapper.VpnLinkState.CONNECTING: state_str = _("Connecting..."); break;
                default:                                            state_str = _("Disconnected"); break;
            }

            bool is_wireguard = (vpn_conn.get_connection_type() == "wireguard");
            var captured_conn = vpn_conn;
            ActionRow row;
            if (link_state == NetworkManagerWrapper.VpnLinkState.CONNECTING) {
                row = new ActionRow(name, state_str);
                var spinner = new Spinner();
                spinner.spinning = true;
                row.add_suffix(spinner);
            } else {
                var switch_row = new SwitchRow(name, state_str,
                    link_state == NetworkManagerWrapper.VpnLinkState.CONNECTED);
                switch_row.switch_btn.notify["active"].connect(() => {
                    if (switch_row.active)
                        network.activate_vpn.begin(captured_conn);
                    else
                        network.deactivate_connection.begin(captured_conn);
                });
                row = switch_row;
            }
            row.icon_name = is_wireguard ? "network-wireless-symbolic" : "network-vpn-symbolic";

            var remove_btn = new Button.from_icon_name("user-trash-symbolic");
            remove_btn.add_css_class("flat");
            remove_btn.add_css_class("destructive-action");
            remove_btn.tooltip_text = _("Remove VPN");
            remove_btn.clicked.connect(() => {
                row.confirmation_requested(_("Remove"), _("Cancel"),
                    ConfirmationSuggestedAction.CANCEL);
            });
            row.confirmed.connect(() => network.delete_vpn.begin(captured_conn));
            row.add_suffix(remove_btn);

            return row;
        }

        private async void set_provider_vpn_active(VpnConnection conn, bool active) {
            try {
                bool success = active ? yield conn.activate() : yield conn.deactivate();
                on_vpn_action_result(success,
                    success ? "" : _("The VPN provider rejected the request"));
            } catch (Error e) {
                on_vpn_action_result(false, e.message);
            }
        }

        private async void remove_provider_vpn(VpnConnection conn) {
            try {
                bool success = yield conn.remove();
                on_vpn_action_result(success,
                    success ? "" : _("The VPN provider could not remove this profile"));
            } catch (Error e) {
                on_vpn_action_result(false, e.message);
            }
        }

        private Widget build_provider_vpn_row(VpnConnection conn) {
            string state_str;
            switch (conn.state) {
                case VpnState.CONNECTED:  state_str = _("Connected"); break;
                case VpnState.CONNECTING: state_str = _("Connecting..."); break;
                default:                  state_str = _("Disconnected"); break;
            }

            ActionRow row;
            if (conn.state == VpnState.CONNECTING) {
                row = new ActionRow(conn.display_name, state_str);
                var spinner = new Spinner();
                spinner.spinning = true;
                row.add_suffix(spinner);
            } else {
                var switch_row = new SwitchRow(conn.display_name, state_str,
                    conn.state == VpnState.CONNECTED);
                switch_row.switch_btn.notify["active"].connect(() => {
                    set_provider_vpn_active.begin(conn, switch_row.active);
                });
                row = switch_row;
            }
            row.icon_name = conn.icon_name;

            if (conn.can_remove) {
                var remove_btn = new Button.from_icon_name("user-trash-symbolic");
                remove_btn.add_css_class("flat");
                remove_btn.add_css_class("destructive-action");
                remove_btn.tooltip_text = _("Remove VPN");
                remove_btn.clicked.connect(() => {
                    row.confirmation_requested(_("Remove"), _("Cancel"),
                        ConfirmationSuggestedAction.CANCEL);
                });
                row.confirmed.connect(() => remove_provider_vpn.begin(conn));
                row.add_suffix(remove_btn);
            }

            return row;
        }
    }
}
