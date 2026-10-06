using Gtk;
using Singularity.Widgets;
using Singularity.Firmware;

namespace Singularity.SidebarPages {

    public class DeviceSecurityPage : SettingsPage {
        private PreferencesGroup protection_group;
        private ActionRow tpm_row;
        private ActionRow boot_row;
        private ActionRow disk_row;
        private PreferencesGroup firmware_group;
        private Gee.HashMap<ActionRow, Image> status_icons = new Gee.HashMap<ActionRow, Image>();

        public DeviceSecurityPage(SettingsView view) {
            base(_("Security"));

            protection_group = new PreferencesGroup(_("Protection"),
                _("How this computer protects your data while it starts and while it is off."));
            tpm_row = new ActionRow(_("Security Chip"), "", "changes-prevent-symbolic");
            boot_row = new ActionRow(_("Secure Boot"), "", "system-reboot-symbolic");
            disk_row = new ActionRow(_("Disk Encryption"), "", "drive-harddisk-symbolic");
            protection_group.add_row(tpm_row);
            protection_group.add_row(boot_row);
            protection_group.add_row(disk_row);
            add_group(protection_group);

            firmware_group = new PreferencesGroup(_("Firmware Security"),
                _("Checks by fwupd, rated on the Host Security ID scale from 0 to 5."));
            add_group(firmware_group);

            var local = new DeviceSecurity(root());
            local.read_all();
            show_local(local);
            load_fwupd.begin(local);
        }

        private static string root() {
            return Environment.get_variable("SINGULARITY_SECURITY_ROOT") ?? "";
        }

        public static string summary() {
            var local = new DeviceSecurity(root());
            local.read_all();
            string[] parts = {};
            switch (local.secure_boot) {
                case SecureBootState.ENABLED: parts += _("Secure Boot on"); break;
                case SecureBootState.DISABLED:
                case SecureBootState.SETUP_MODE: parts += _("Secure Boot off"); break;
                case SecureBootState.UNSUPPORTED: parts += _("no Secure Boot"); break;
                default: break;
            }
            if (local.tpm_present) parts += local.tpm_version != "" ? _("TPM %s").printf(local.tpm_version) : _("TPM");
            else parts += _("no TPM");
            if (local.encryption == EncryptionState.ENCRYPTED) parts += _("disk encrypted");
            else if (local.encryption == EncryptionState.NOT_ENCRYPTED) parts += _("disk not encrypted");
            string text = string.joinv(", ", parts);
            return text.length > 0 ? text.substring(0, 1).up() + text.substring(1) : text;
        }

        private void set_status(ActionRow row, bool? good) {
            Image? icon = status_icons[row];
            if (icon == null) {
                icon = new Image();
                icon.valign = Align.CENTER;
                row.add_suffix(icon);
                status_icons[row] = icon;
            }
            icon.visible = good != null;
            if (good == null) return;
            icon.icon_name = good ? "object-select-symbolic" : "dialog-warning-symbolic";
            icon.remove_css_class("success");
            icon.remove_css_class("warning");
            icon.add_css_class(good ? "success" : "warning");
        }

        private void show_tpm(bool present, string version) {
            if (present) {
                tpm_row.title = version != "" ? _("TPM %s").printf(version) : _("TPM");
                tpm_row.subtitle = _("Present. It keeps encryption keys safe and records how the computer started.");
                set_status(tpm_row, version != "1.2");
                if (version == "1.2") tpm_row.subtitle = _("Present, but an old version. Some protections need TPM 2.0.");
            } else {
                tpm_row.title = _("Security Chip");
                tpm_row.subtitle = _("No TPM found. Encryption keys cannot be tied to this computer's hardware.");
                set_status(tpm_row, false);
            }
        }

        private void show_secure_boot(SecureBootState state) {
            switch (state) {
                case SecureBootState.ENABLED:
                    boot_row.subtitle = _("On. Only signed boot loaders and kernels can start.");
                    set_status(boot_row, true);
                    break;
                case SecureBootState.DISABLED:
                    boot_row.subtitle = _("Off. Any boot loader can start, including malicious ones. Turn it on in the firmware setup.");
                    set_status(boot_row, false);
                    break;
                case SecureBootState.SETUP_MODE:
                    boot_row.subtitle = _("Setup mode. No keys are enrolled, so nothing is checked when the computer starts.");
                    set_status(boot_row, false);
                    break;
                case SecureBootState.UNSUPPORTED:
                    boot_row.subtitle = _("Not supported. This computer starts in legacy BIOS mode.");
                    set_status(boot_row, false);
                    break;
                default:
                    boot_row.subtitle = _("Unknown. The firmware does not report it.");
                    set_status(boot_row, null);
                    break;
            }
        }

        private void show_local(DeviceSecurity local) {
            show_tpm(local.tpm_present, local.tpm_version);
            show_secure_boot(local.secure_boot);
            switch (local.encryption) {
                case EncryptionState.ENCRYPTED:
                    disk_row.subtitle = local.encryption_scope == "home"
                        ? _("Your home folder is encrypted with %s. Your files cannot be read without your password.").printf(local.encryption_method)
                        : _("Encrypted with %s. Nothing on the disk can be read without the key.").printf(local.encryption_method);
                    set_status(disk_row, true);
                    break;
                case EncryptionState.NOT_ENCRYPTED:
                    disk_row.subtitle = _("Not encrypted. Anyone who takes the disk out can read your files.");
                    set_status(disk_row, false);
                    break;
                default:
                    disk_row.subtitle = _("Unknown. The storage layout could not be read.");
                    set_status(disk_row, null);
                    break;
            }
        }

        private static string level_explanation(int level) {
            switch (level) {
                case 0: return _("The firmware lacks basic protections, or a problem was found while the system runs.");
                case 1: return _("The most important firmware protections are in place.");
                case 2: return _("Important protections are in place, beyond the basics.");
                case 3: return _("Protections against uncommon attacks are in place too.");
                case 4: return _("The system also protects itself while it runs.");
                case 5: return _("The system can prove to others that it has not been tampered with.");
            }
            return _("The level could not be worked out on this computer.");
        }

        private async void load_fwupd(DeviceSecurity local) {
            var client = Client.get_default();
            if (!(yield client.probe())) {
                firmware_group.add_row(new ActionRow(_("Not Available"),
                    _("Install fwupd to see how well the firmware of this computer is protected."), "dialog-information-symbolic"));
                return;
            }
            Gee.ArrayList<SecurityAttr> attrs;
            try {
                attrs = yield client.security_attrs();
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                firmware_group.add_row(new ActionRow(_("Not Available"), e.message, "dialog-warning-symbolic"));
                return;
            }
            foreach (var attr in attrs) {
                if (attr.obsoleted) continue;
                if (attr.appstream_id == "org.fwupd.hsi.Tpm.Version20" && !local.tpm_present) {
                    show_tpm(attr.success, attr.success ? "2.0" : "");
                } else if (attr.appstream_id == "org.fwupd.hsi.Uefi.SecureBoot" && local.secure_boot == SecureBootState.UNKNOWN) {
                    show_secure_boot(attr.success ? SecureBootState.ENABLED : SecureBootState.DISABLED);
                }
            }

            int level = Client.hsi_level(client.host_security_id);
            var level_row = new ActionRow(level >= 0 ? _("Security Level %d").printf(level) : _("Security Level Unknown"),
                level_explanation(level), "security-high-symbolic");
            if (Client.hsi_has_runtime_issue(client.host_security_id)) {
                level_row.subtitle = _("%s A problem was found while the system runs.").printf(level_explanation(level));
            }
            var id_label = new Label(client.host_security_id.split(" ")[0]);
            id_label.add_css_class("dim-label");
            id_label.valign = Align.CENTER;
            level_row.add_suffix(id_label);
            firmware_group.add_row(level_row);

            var failing = new Gee.ArrayList<SecurityAttr>();
            var passing = new Gee.ArrayList<SecurityAttr>();
            foreach (var attr in attrs) {
                if (attr.failing) failing.add(attr);
                else if (attr.success && !attr.obsoleted && attr.level > 0) passing.add(attr);
            }
            failing.sort((a, b) => (int) a.level - (int) b.level);
            if (failing.size > 0) {
                var fail_row = new ExpanderRow(_("Checks That Failed"),
                    ngettext("%d check needs attention", "%d checks need attention", failing.size).printf(failing.size),
                    "dialog-warning-symbolic");
                foreach (var attr in failing) {
                    string text = "%s %s".printf(attr.result_text, attr.explanation);
                    if (attr.advice != "") text = "%s %s".printf(text, attr.advice);
                    var row = new ActionRow(attr.title, text);
                    if (attr.level > 0) {
                        var lvl = new Label("HSI:%u".printf(attr.level));
                        lvl.add_css_class("dim-label");
                        lvl.valign = Align.CENTER;
                        row.add_suffix(lvl);
                    }
                    fail_row.add_row(row);
                }
                fail_row.expanded = true;
                firmware_group.add_row(fail_row);
            }
            if (passing.size > 0) {
                var pass_row = new ExpanderRow(_("Checks That Passed"),
                    ngettext("%d check", "%d checks", passing.size).printf(passing.size), "object-select-symbolic");
                foreach (var attr in passing) pass_row.add_row(new ActionRow(attr.title, attr.explanation));
                firmware_group.add_row(pass_row);
            }
        }
    }
}
