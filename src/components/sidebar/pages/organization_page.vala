using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class OrganizationPage : SettingsPage {
        private OrganizationDevice org;
        private StatusPage unavailable;
        private PreferencesGroup enroll_group;
        private EntryRow server_row;
        private EntryRow code_row;
        private EntryRow name_row;
        private Button enroll_btn;
        private PreferencesGroup managed_group;
        private ActionRow server_info;
        private ActionRow device_info;
        private ActionRow group_info;
        private Button leave_btn;
        private Label error_label;
        private bool busy = false;

        public OrganizationPage(SettingsView view) {
            base(_("Organization"));
            org = OrganizationDevice.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("system"));

            unavailable = new StatusPage();
            unavailable.compact = true;
            unavailable.icon_name = "network-workgroup-symbolic";
            unavailable.title = _("Device Management Not Installed");
            unavailable.description = _("This system cannot be managed by an organization.");
            unavailable.visible = false;
            add_widget(unavailable);

            enroll_group = new PreferencesGroup(_("Enroll This Device"),
                _("Your organization gives you its address and an enrollment code. Once enrolled, it can see whether this device is up to date and protected, apply its settings, and lock or erase the device if it is lost."));
            server_row = new EntryRow(_("Organization Address"));
            server_row.input_purpose = InputPurpose.URL;
            code_row = new EntryRow(_("Enrollment Code"));
            name_row = new EntryRow(_("Device Name"));
            var host = HostnameManager.get_default();
            string shown = HostnameManager.display_name(host.pretty_name, host.hostname);
            name_row.text = shown != "" ? shown : Environment.get_host_name();
            enroll_group.add_row(server_row);
            enroll_group.add_row(code_row);
            enroll_group.add_row(name_row);
            add_group(enroll_group);

            enroll_btn = new Button.with_label(_("Enroll"));
            enroll_btn.add_css_class("pill");
            enroll_btn.add_css_class("suggested-action");
            enroll_btn.halign = Align.CENTER;
            enroll_btn.margin_top = 16;
            enroll_btn.clicked.connect(() => enroll.begin());
            code_row.entry_activated.connect(() => enroll.begin());
            name_row.entry_activated.connect(() => enroll.begin());
            add_widget(enroll_btn);

            managed_group = new PreferencesGroup(_("Managed by Your Organization"),
                _("Your organization can see whether this device is up to date and protected, apply its settings, and lock or erase the device if it is lost. It cannot read your files."));
            server_info = info_row(_("Organization"), "network-workgroup-symbolic");
            device_info = info_row(_("Device ID"), "computer-symbolic");
            group_info = info_row(_("Group"), "system-users-symbolic");
            managed_group.add_row(server_info);
            managed_group.add_row(device_info);
            managed_group.add_row(group_info);
            add_group(managed_group);

            leave_btn = new Button.with_label(_("Remove from Organization"));
            leave_btn.add_css_class("pill");
            leave_btn.add_css_class("destructive-action");
            leave_btn.halign = Align.CENTER;
            leave_btn.margin_top = 16;
            leave_btn.clicked.connect(() => leave.begin());
            add_widget(leave_btn);

            error_label = new Label("");
            error_label.add_css_class("caption");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.xalign = 0;
            error_label.margin_start = 12;
            error_label.margin_top = 8;
            error_label.visible = false;
            add_widget(error_label);

            org.changed.connect(sync);
            map.connect(() => org.refresh.begin());
            sync();
            org.refresh.begin();
        }

        public static string summary() {
            var org = OrganizationDevice.get_default();
            if (!org.enrolled) return _("Not managed");
            return _("Managed by %s").printf(org.server_host());
        }

        private ActionRow info_row(string title, string icon) {
            var row = new ActionRow(title, "", icon);
            row.activatable = false;
            return row;
        }

        private void sync() {
            unavailable.visible = !org.available;
            bool on = org.available && org.enrolled;
            enroll_group.visible = org.available && !on;
            enroll_btn.visible = enroll_group.visible;
            managed_group.visible = on;
            leave_btn.visible = on;
            server_info.subtitle = org.server_host();
            device_info.subtitle = org.device;
            group_info.subtitle = org.group;
        }

        private void fail(Error e) {
            error_label.label = e.message;
            error_label.visible = true;
        }

        private async void enroll() {
            if (busy) return;
            string server = server_row.text.strip();
            if (server == "") {
                fail(new OrganizationError.INVALID(_("Enter the address your organization gave you.")));
                return;
            }
            busy = true;
            error_label.visible = false;
            enroll_btn.sensitive = false;
            try {
                yield org.enroll(server, code_row.text.strip(), name_row.text.strip());
                code_row.text = "";
            } catch (Error e) {
                fail(e);
            }
            enroll_btn.sensitive = true;
            busy = false;
        }

        private async void leave() {
            if (busy) return;
            busy = true;
            error_label.visible = false;
            leave_btn.sensitive = false;
            try {
                yield org.leave();
            } catch (Error e) {
                fail(e);
            }
            leave_btn.sensitive = true;
            busy = false;
        }
    }
}
