using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class NearbyDevicePage : SettingsPage {
        private SettingsView view;
        private NearbyClient client;
        private string device_id;
        private Image icon;
        private Label status;
        private Box actions;
        private PreferencesGroup files_group;
        private SwitchRow always_row;
        private PreferencesGroup more_group;
        private Button unpair_btn;
        private bool syncing = false;
        private ulong changed_id = 0;

        public NearbyDevicePage(SettingsView view, string device_id) {
            var d = NearbyClient.get_default().find(device_id);
            base(d != null ? d.name : _("Device"));
            this.view = view;
            this.device_id = device_id;
            client = NearbyClient.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("connected-devices"));

            var card = new Box(Orientation.VERTICAL, 8);
            card.margin_top = 12;
            card.halign = Align.CENTER;
            icon = new Image.from_icon_name("phone");
            icon.pixel_size = 64;
            card.append(icon);
            status = new Label("");
            status.wrap = true;
            status.justify = Justification.CENTER;
            status.add_css_class("dim-label");
            card.append(status);
            actions = new Box(Orientation.HORIZONTAL, 8);
            actions.halign = Align.CENTER;
            actions.margin_top = 6;
            card.append(actions);
            add_widget(card);

            files_group = new PreferencesGroup(_("Files"));
            always_row = new SwitchRow(_("Accept Files Without Asking"), _("Files from this device go straight to the Received Files folder"), false);
            always_row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                client.simple.begin("SetAlwaysAllowFiles", new Variant("(sb)", device_id, always_row.switch_btn.active));
            });
            files_group.add_row(always_row);
            add_group(files_group);

            more_group = new PreferencesGroup(_("Options"));
            add_group(more_group);

            unpair_btn = new Button.with_label(_("Unpair"));
            unpair_btn.add_css_class("pill");
            unpair_btn.add_css_class("destructive-action");
            unpair_btn.halign = Align.CENTER;
            unpair_btn.margin_top = 18;
            unpair_btn.margin_bottom = 12;
            unpair_btn.clicked.connect(() => confirm_unpair());
            add_widget(unpair_btn);

            changed_id = client.changed.connect(() => sync());
            destroy.connect(() => client.disconnect(changed_id));
            sync();
        }

        private NearbyDevice? device {
            owned get { return client.find(device_id); }
        }

        private void sync() {
            var d = device;
            if (d == null || !d.paired) {
                view.navigate_to("connected-devices");
                return;
            }
            icon.icon_name = d.full_icon_name;
            status.label = d.status_text();
            syncing = true;
            always_row.switch_btn.active = d.always_allow_files;
            syncing = false;
            files_group.visible = d.has_plugin("share");

            var child = actions.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                actions.remove(child);
                child = next;
            }
            if (NearbyClient.app_installed()) {
                var open = new Button.with_label(_("Open in Nearby"));
                open.add_css_class("pill");
                open.add_css_class("suggested-action");
                open.tooltip_text = _("Send files, read messages and notifications, ring the device and control its media");
                open.clicked.connect(() => NearbyClient.open_app(device_id));
                actions.append(open);
            }
            actions.visible = actions.get_first_child() != null;

            more_group.clear();
            var features = new ActionRow(_("Features"), _("Choose what this device can do"), "preferences-system-symbolic");
            features.activatable = true;
            features.add_suffix(chevron());
            features.activated.connect(() => view.open_subpage(new NearbyFeaturesPage(view, device_id), "nearby-features"));
            more_group.add_row(features);
            if (d.has_plugin("runcommand")) {
                var commands = new ActionRow(_("Commands"), _("Commands the device can run on this computer"), "utilities-terminal-symbolic");
                commands.activatable = true;
                commands.add_suffix(chevron());
                commands.activated.connect(() => view.open_subpage(new NearbyCommandsPage(view, device_id), "nearby-commands"));
                more_group.add_row(commands);
            }
        }

        private static Image chevron() {
            var img = new Image.from_icon_name("go-next-symbolic");
            img.pixel_size = 12;
            img.add_css_class("dim-label");
            img.valign = Align.CENTER;
            return img;
        }

        private void confirm_unpair() {
            var d = device;
            if (d == null) return;
            var app = GLib.Application.get_default() as Gtk.Application;
            var dlg = new ConfirmDialog(app, _("Unpair %s?").printf(d.name), d.icon_name,
                _("It will no longer share files, the clipboard or notifications with this computer until you pair again."),
                _("Unpair"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) client.simple.begin("Unpair", new Variant("(s)", device_id));
            });
            dlg.present();
        }
    }

    public class NearbyFeaturesPage : SettingsPage {
        public NearbyFeaturesPage(SettingsView view, string device_id) {
            base(_("Features"));
            back_btn.visible = true;
            back_clicked.connect(() => view.show_page_name("nearby-device"));
            var client = NearbyClient.get_default();
            var d = client.find(device_id);
            var group = new PreferencesGroup(_("On This Computer"), _("Turned off features ignore everything the device sends for them."));
            foreach (string plugin in client.features_for_settings()) {
                var row = new SwitchRow(NearbyClient.feature_title(plugin), NearbyClient.feature_description(plugin), d != null && d.has_plugin(plugin));
                string p = plugin;
                row.switch_btn.notify["active"].connect(() => {
                    client.simple.begin("SetPluginEnabled", new Variant("(ssb)", device_id, p, row.switch_btn.active));
                });
                group.add_row(row);
            }
            add_group(group);
        }
    }

    public class NearbyCommandsPage : SettingsPage {
        private PreferencesGroup list_group;

        public NearbyCommandsPage(SettingsView view, string device_id) {
            base(_("Commands"));
            back_btn.visible = true;
            back_clicked.connect(() => view.show_page_name("nearby-device"));
            list_group = new PreferencesGroup(_("Allowed Commands"), _("The device can start these commands on this computer. Add only commands you trust."));
            add_group(list_group);
            var add_group_widget = new PreferencesGroup(_("New Command"));
            var name = new EntryRow(_("Name"));
            var command = new EntryRow(_("Command Line"));
            add_group_widget.add_row(name);
            add_group_widget.add_row(command);
            add_group(add_group_widget);
            var add = new Button.with_label(_("Add Command"));
            add.halign = Align.END;
            add.margin_top = 8;
            add.clicked.connect(() => {
                if (name.text.strip() == "" || command.text.strip() == "") return;
                NearbyClient.get_default().call.begin("AddCommand", new Variant("(ss)", name.text.strip(), command.text.strip()), "(s)", (o, r) => {
                    name.text = "";
                    command.text = "";
                    fill.begin();
                });
            });
            add_widget(add);
            fill.begin();
        }

        private async void fill() {
            var list = yield NearbyClient.get_default().list("ListCommands");
            list_group.clear();
            if (list.length == 0) {
                var empty = new ActionRow(_("No Commands"), _("Add one below."), "utilities-terminal-symbolic");
                list_group.add_row(empty);
                return;
            }
            foreach (var c in list) {
                string key = NearbyClient.text_of(c, "key");
                var row = new ActionRow(NearbyClient.text_of(c, "name"), NearbyClient.text_of(c, "command"), "utilities-terminal-symbolic");
                var remove = new Button.from_icon_name("user-trash-symbolic");
                remove.add_css_class("flat");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Remove");
                remove.update_property(AccessibleProperty.LABEL, _("Remove"), -1);
                remove.clicked.connect(() => {
                    NearbyClient.get_default().call.begin("RemoveCommand", new Variant("(s)", key), null, (o, r) => fill.begin());
                });
                row.add_suffix(remove);
                list_group.add_row(row);
            }
        }
    }
}
