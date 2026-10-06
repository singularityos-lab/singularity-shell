using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class ConnectedDevicesPage : SettingsPage {
        private SettingsView view;
        private NearbyClient client;
        private StatusPage unavailable;
        private WelcomePage welcome;
        private PreferencesGroup request_group;
        private PreferencesGroup mine_group;
        private PreferencesGroup available_group;
        private PreferencesGroup computer_group;
        private SwitchRow visible_row;
        private ActionRow name_row;
        private ActionRow folder_row;
        private Label code_label;
        private Label request_title;
        private Singularity.Animation.MotionBin code_bin;
        private string request_id = "";
        private string shown_request = "";
        private Gee.HashSet<string> shown = new Gee.HashSet<string>();
        private bool syncing = false;
        private ulong changed_id = 0;
        private ulong pair_id = 0;

        public ConnectedDevicesPage(SettingsView view) {
            base(_("Connected Devices"));
            this.view = view;
            client = NearbyClient.get_default();
            back_clicked.connect(() => view.go_home());

            unavailable = new StatusPage();
            unavailable.icon_name = "dev.sinty.Nearby";
            unavailable.title = _("Nearby Is Not Available");
            unavailable.description = _("The Nearby service is not installed on this system.");
            unavailable.visible = false;
            add_widget(unavailable);

            welcome = new WelcomePage();
            welcome.is_section = true;
            welcome.embedded = true;
            welcome.compact = true;
            welcome.app_icon_name = "dev.sinty.Nearby";
            welcome.title = _("Connect Your Phone");
            welcome.subtitle = _("Send files and links, share the clipboard, and see the phone's notifications and messages here. Install KDE Connect on Android or iPhone, or GSConnect on another computer, and pair it below.");
            welcome.add_action("phone", _("Get the App for Your Phone"),
                _("KDE Connect is free on Android and iPhone"), () => {
                    try {
                        AppInfo.launch_default_for_uri("https://kdeconnect.kde.org/download.html", null);
                    } catch (Error e) {
                        warning("nearby: %s", e.message);
                    }
                });
            welcome.add_action("network-workgroup", _("Add a Device by Address"),
                _("When the phone is on another network segment"), () => open_address());
            if (NearbyClient.app_installed()) {
                welcome.add_action("dev.sinty.Nearby", _("Open Nearby"),
                    _("Send files, read messages and notifications"), () => NearbyClient.open_app());
            }
            welcome.visible = false;
            add_widget(welcome);

            request_group = new PreferencesGroup(_("Pairing Request"), _("Pair only if both devices show the same code."));
            var request_box = new Box(Orientation.VERTICAL, 10);
            request_box.margin_top = 14;
            request_box.margin_bottom = 14;
            request_box.margin_start = 12;
            request_box.margin_end = 12;
            request_title = new Label("");
            request_title.wrap = true;
            request_title.wrap_mode = Pango.WrapMode.WORD_CHAR;
            request_title.justify = Justification.CENTER;
            request_box.append(request_title);
            code_label = new Label("");
            code_label.add_css_class("title-1");
            code_label.add_css_class("numeric");
            code_label.selectable = true;
            code_bin = new Singularity.Animation.MotionBin(code_label);
            request_box.append(code_bin);
            var buttons = new Box(Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            var decline = new Button.with_label(_("Decline"));
            decline.add_css_class("pill");
            decline.clicked.connect(() => client.simple.begin("RejectPair", new Variant("(s)", request_id)));
            var accept = new Button.with_label(_("Pair"));
            accept.add_css_class("pill");
            accept.add_css_class("suggested-action");
            accept.clicked.connect(() => client.simple.begin("AcceptPair", new Variant("(s)", request_id)));
            buttons.append(decline);
            buttons.append(accept);
            request_box.append(buttons);
            var request_row = new PreferencesRow();
            request_row.child = request_box;
            request_row.activatable = false;
            request_group.add_row(request_row);
            request_group.visible = false;
            add_group(request_group);

            mine_group = new PreferencesGroup(_("My Devices"));
            if (NearbyClient.app_installed()) {
                var open_app = new Button.with_label(_("Open Nearby"));
                open_app.valign = Align.CENTER;
                open_app.tooltip_text = _("Send files, read messages and notifications, ring devices and control their media");
                open_app.clicked.connect(() => NearbyClient.open_app());
                mine_group.add_header_suffix(open_app);
            }
            mine_group.visible = false;
            add_group(mine_group);

            available_group = new PreferencesGroup(_("Available Devices"),
                _("Devices on this network with KDE Connect or GSConnect open."));
            add_group(available_group);

            computer_group = new PreferencesGroup(_("This Computer"),
                _("Found on the local network. A firewall must allow TCP and UDP ports 1714 to 1764."));
            visible_row = new SwitchRow(_("Visible to Nearby Devices"), _("Off keeps paired devices connected but hides this computer from others"), client.discoverable);
            visible_row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                set_prop("Discoverable", new Variant.boolean(visible_row.switch_btn.active));
                if (visible_row.switch_btn.active)
                    FirewallManager.get_default().register_app.begin("nearby", _("Nearby"),
                        { "1714-1764/tcp", "1714-1764/udp" });
            });
            computer_group.add_row(visible_row);
            name_row = new ActionRow(_("Name"), client.device_name);
            name_row.activatable = true;
            name_row.add_suffix(chevron());
            name_row.activated.connect(() => open_name());
            computer_group.add_row(name_row);
            folder_row = new ActionRow(_("Received Files"), "");
            var change = new Button.with_label(_("Change…"));
            change.valign = Align.CENTER;
            change.clicked.connect(() => choose_folder());
            folder_row.add_suffix(change);
            computer_group.add_row(folder_row);
            var address_row = new ActionRow(_("Add a Device by Address"), _("For phones the network hides from discovery"));
            address_row.activatable = true;
            address_row.add_suffix(chevron());
            address_row.activated.connect(() => open_address());
            computer_group.add_row(address_row);
            add_group(computer_group);

            add_search_action(_("Pair a Phone"), _("Nearby, KDE Connect, GSConnect, phone, pair, Android, iPhone"), () => {});
            add_search_action(_("Received Files Folder"), _("Nearby, downloads, incoming files"), () => choose_folder());
            add_search_action(_("Open Nearby"), _("Nearby, phone, send files, messages, SMS, notifications, ring"), () => NearbyClient.open_app());

            changed_id = client.changed.connect(() => sync());
            pair_id = client.pair_requested.connect((id, name, code) => sync());
            destroy.connect(() => {
                client.disconnect(changed_id);
                client.disconnect(pair_id);
            });
            map.connect(() => {
                client.start();
                client.refresh.begin();
                client.simple.begin("Refresh", null);
            });
            sync();
        }

        private static Image chevron() {
            var img = new Image.from_icon_name("go-next-symbolic");
            img.pixel_size = 12;
            img.add_css_class("dim-label");
            img.valign = Align.CENTER;
            return img;
        }

        private void set_prop(string name, Variant value) {
            client.set_service_property.begin(name, value, (o, r) => {
                try {
                    client.set_service_property.end(r);
                } catch (Error e) {
                    warning("nearby: %s", e.message);
                }
            });
        }

        private void sync() {
            bool ok = client.available;
            unavailable.visible = !ok;
            computer_group.visible = ok;
            if (!ok) {
                welcome.visible = false;
                mine_group.visible = false;
                available_group.visible = false;
                request_group.visible = false;
                return;
            }
            syncing = true;
            visible_row.switch_btn.active = client.discoverable;
            syncing = false;
            name_row.subtitle = client.device_name;
            string home = Environment.get_home_dir();
            folder_row.subtitle = client.receive_folder.has_prefix(home + "/") ? "~" + client.receive_folder.substring(home.length) : client.receive_folder;

            NearbyDevice? incoming = null;
            var mine = new Gee.ArrayList<NearbyDevice>();
            var others = new Gee.ArrayList<NearbyDevice>();
            foreach (var d in client.devices) {
                if (d.pair_state == "incoming") incoming = d;
                if (d.paired) mine.add(d);
                else if (d.reachable && d.pair_state != "incoming") others.add(d);
            }
            welcome.visible = mine.size == 0 && incoming == null;
            request_group.visible = incoming != null;
            if (incoming != null) {
                request_id = incoming.id;
                request_title.label = _("%s wants to pair with this computer").printf(incoming.name);
                code_label.label = incoming.verification;
                if (shown_request != incoming.id + incoming.verification) {
                    shown_request = incoming.id + incoming.verification;
                    Motion.reveal(code_bin, Motion.Preset.SCALE_FADE);
                }
            } else {
                shown_request = "";
            }

            Widget[] fresh = {};
            mine_group.clear();
            mine_group.visible = mine.size > 0;
            foreach (var d in mine) {
                var row = new ActionRow(d.name, d.status_text(), d.icon_name);
                row.activatable = true;
                row.add_suffix(chevron());
                string id = d.id;
                row.activated.connect(() => open_device(id));
                mine_group.add_row(row);
                if (!shown.contains(d.id)) fresh += row;
            }

            available_group.clear();
            if (others.size == 0) {
                var row = new ActionRow(_("Looking for Devices…"), _("Open KDE Connect on the phone, on the same network."));
                var spinner = new Spinner();
                spinner.spinning = true;
                spinner.valign = Align.CENTER;
                row.add_suffix(spinner);
                available_group.add_row(row);
            }
            foreach (var d in others) {
                string subtitle = d.pair_state == "requested"
                    ? _("Check that %s shows %s").printf(d.name, d.verification) : d.status_text();
                var row = new ActionRow(d.name, subtitle, d.icon_name);
                string id = d.id;
                if (d.pair_state == "requested") {
                    var cancel = new Button.with_label(_("Cancel"));
                    cancel.valign = Align.CENTER;
                    cancel.clicked.connect(() => client.simple.begin("RejectPair", new Variant("(s)", id)));
                    row.add_suffix(cancel);
                } else if (d.pair_state != "incoming") {
                    var pair = new Button.with_label(_("Pair"));
                    pair.valign = Align.CENTER;
                    pair.add_css_class("suggested-action");
                    pair.clicked.connect(() => client.simple.begin("RequestPair", new Variant("(s)", id)));
                    row.add_suffix(pair);
                }
                available_group.add_row(row);
                if (!shown.contains(d.id)) fresh += row;
            }
            shown.clear();
            foreach (var d in client.devices) shown.add(d.id);
            if (fresh.length > 0) Motion.cascade(fresh, Motion.Preset.FADE);
        }

        private void open_device(string id) {
            view.open_subpage(new NearbyDevicePage(view, id), "nearby-device");
        }

        private void open_name() {
            var page = new SettingsPage(_("Name"));
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("connected-devices"));
            var group = new PreferencesGroup(_("Name"), _("Shown on your phone and on other computers."));
            var entry = new EntryRow(_("Computer Name"));
            entry.text = client.device_name;
            group.add_row(entry);
            page.add_group(group);
            var save = new Button.with_label(_("Save"));
            save.add_css_class("pill");
            save.add_css_class("suggested-action");
            save.halign = Align.CENTER;
            save.margin_top = 16;
            save.clicked.connect(() => {
                set_prop("Name", new Variant.string(entry.text.strip()));
                view.navigate_to("connected-devices");
            });
            entry.entry_activated.connect(() => save.clicked());
            page.add_widget(save);
            view.open_subpage(page, "nearby-name");
        }

        private void open_address() {
            var page = new SettingsPage(_("Add by Address"));
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("connected-devices"));
            var group = new PreferencesGroup(_("Address"), _("The IP address or host name of the phone. It appears under Available Devices when it answers."));
            var entry = new EntryRow(_("Address"));
            group.add_row(entry);
            page.add_group(group);
            var add = new Button.with_label(_("Connect"));
            add.add_css_class("pill");
            add.add_css_class("suggested-action");
            add.halign = Align.CENTER;
            add.margin_top = 16;
            add.clicked.connect(() => {
                string a = entry.text.strip();
                if (a == "") return;
                client.simple.begin("ConnectAddress", new Variant("(s)", a));
                view.navigate_to("connected-devices");
            });
            entry.entry_activated.connect(() => add.clicked());
            page.add_widget(add);
            view.open_subpage(page, "nearby-address");
        }

        private void choose_folder() {
            var dialog = new FileDialog();
            dialog.title = _("Received Files");
            if (client.receive_folder != "") dialog.initial_folder = File.new_for_path(client.receive_folder);
            dialog.select_folder.begin(get_root() as Gtk.Window, null, (o, r) => {
                try {
                    var folder = dialog.select_folder.end(r);
                    if (folder != null && folder.get_path() != null) set_prop("ReceiveFolder", new Variant.string(folder.get_path()));
                } catch (Error e) {
                }
            });
        }
    }
}
