using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class SystemPage : SettingsPage {
        private SettingsView view;
        private EntryRow hostname_row;
        private SystemComponents.Component[] _components;
        private SettingsSubpages subpages;

        public SystemPage(SettingsView view) {
            base(_("About"));
            this.view = view;
            subpages = new SettingsSubpages(view, this, "system");
            back_clicked.connect(() => {
                view.go_home();
            });
            build_ui();
        }

        private void build_ui() {
            var runtime_identity = OsIdentity.load();
            var host_identity = OsIdentity.load_host();

            // Copy-all-as-markdown action, far right in the page header.
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            header.append(spacer);
            var copy_btn = new Button.from_icon_name("edit-copy-symbolic");
            copy_btn.has_frame = false;
            copy_btn.tooltip_text = _("Copy system info as Markdown");
            copy_btn.add_css_class("navigation-button");
            copy_btn.clicked.connect(copy_info_markdown);
            header.append(copy_btn);

            var logo_box = new Box(Orientation.VERTICAL, 12);
            logo_box.margin_top = 12;
            logo_box.margin_bottom = 4;
            logo_box.halign = Align.CENTER;
            var logo = new Image.from_icon_name("computer-symbolic");
            logo.icon_name = get_distro_icon_name();
            logo.pixel_size = 96;
            logo.add_css_class("accent-color");
            logo_box.append(logo);
            add_widget(logo_box);
            var device_group = new PreferencesGroup(_("Device Name"));
            hostname_row = new EntryRow("Device Name");
            hostname_row.text = GLib.Environment.get_host_name();
            var apply_btn = new Button.from_icon_name("object-select-symbolic");
            apply_btn.add_css_class("flat");
            apply_btn.tooltip_text = _("Apply Hostname");
            apply_btn.clicked.connect(apply_hostname);
            hostname_row.add_suffix(apply_btn);
            device_group.add_row(hostname_row);
            add_group(device_group);
            var hardware_page = subpages.create(_("Hardware"));
            var software_page = subpages.create(_("Software"));
            var components_page = subpages.create(_("System Components"));
            var hw_group = new PreferencesGroup();
            hw_group.add_row(create_info_row("Model", get_hardware_model()));
            hw_group.add_row(create_info_row("Memory", get_memory_info()));
            hw_group.add_row(create_info_row("Processor", get_processor_info()));
            hw_group.add_row(create_info_row("Graphics", get_graphics_info()));
            hw_group.add_row(create_info_row("Disk Capacity", get_disk_info()));
            hardware_page.add_group(hw_group);
            var sw_group = new PreferencesGroup();
            sw_group.add_row(create_info_row("Firmware Version", get_firmware_version()));
            if (OsIdentity.has_host_identity()) {
                sw_group.add_row(create_info_row("Host OS", host_identity.menu_label()));
                sw_group.add_row(create_info_row("cpak Runtime", runtime_identity.menu_label()));
            } else {
                sw_group.add_row(create_info_row("OS Name", runtime_identity.name));
                if (runtime_identity.version_id != "")
                    sw_group.add_row(create_info_row("OS Version", runtime_identity.version_id));
                if (runtime_identity.build_id != "")
                    sw_group.add_row(create_info_row("OS Build", runtime_identity.build_id));
            }
            sw_group.add_row(create_info_row("OS Type", sizeof(void*) == 8 ? "64-bit" : "32-bit"));
            sw_group.add_row(create_info_row("Singularity Desktop", SingularityApp.VERSION));
            sw_group.add_row(create_info_row("Windowing System", "Wayland"));
            sw_group.add_row(create_info_row("Kernel Version", get_kernel_version()));
            software_page.add_group(sw_group);

            var details_group = new PreferencesGroup(_("Details"));
            details_group.add_row(subpages.link(_("Hardware"), get_hardware_model(),
                "computer-symbolic", hardware_page, "system-hardware"));
            string os_summary = OsIdentity.has_host_identity() ? host_identity.menu_label() : runtime_identity.menu_label();
            details_group.add_row(subpages.link(_("Software"), os_summary,
                "system-software-install-symbolic", software_page, "system-software"));
            add_group(details_group);
            var security_group = details_group;
            var security_row = new ActionRow(_("Device Security"), DeviceSecurityPage.summary(), "security-high-symbolic");
            security_row.activatable = true;
            var security_chevron = new Image.from_icon_name("go-next-symbolic");
            security_chevron.add_css_class("dim-label");
            security_chevron.valign = Align.CENTER;
            security_row.add_suffix(security_chevron);
            security_row.activated.connect(open_security);
            security_group.add_row(security_row);

            _components = SystemComponents.collect();
            var comp_group = new PreferencesGroup(null,
                _("Versions, licenses and build details of the components the session relies on"));
            foreach (var c in _components) {
                if (c.caps.length == 0) {
                    var row = new ActionRow(c.name, c.license);
                    var vlabel = new Label(c.version);
                    vlabel.add_css_class("dim-label");
                    vlabel.valign = Align.CENTER;
                    row.add_suffix(vlabel);
                    comp_group.add_row(row);
                    continue;
                }
                var row = new ExpanderRow(c.name, c.license);
                if (c.warn) {
                    row.icon_name = "dialog-warning-symbolic";
                    row.add_css_class("component-warning");
                }
                var vlabel = new Label(c.version);
                vlabel.add_css_class("dim-label");
                vlabel.valign = Align.CENTER;
                row.add_suffix(vlabel);
                foreach (var cap in c.caps) {
                    var cap_row = new ActionRow(cap.label);
                    if (cap.ok) {
                        var ok_icon = new Image.from_icon_name("object-select-symbolic");
                        ok_icon.add_css_class("success");
                        ok_icon.valign = Align.CENTER;
                        cap_row.add_suffix(ok_icon);
                    } else {
                        var fail_label = new Label(cap.required ? _("Not available") : _("Optional, not available"));
                        fail_label.add_css_class("dim-label");
                        fail_label.valign = Align.CENTER;
                        cap_row.add_suffix(fail_label);
                        var fail_icon = new Image.from_icon_name("dialog-warning-symbolic");
                        if (cap.required) fail_icon.add_css_class("error");
                        else fail_icon.add_css_class("dim-label");
                        fail_icon.valign = Align.CENTER;
                        cap_row.add_suffix(fail_icon);
                    }
                    row.add_row(cap_row);
                }
                comp_group.add_row(row);
            }
            components_page.add_group(comp_group);
            details_group.add_row(subpages.link(_("System Components"), _("Versions and licenses of what the session relies on"),
                "application-x-addon-symbolic", components_page, "system-components"));

            var graphics_group = new PreferencesGroup(_("Advanced"));
            var gfx_settings = new GLib.Settings("dev.sinty.desktop");
            string[] gfx_labels = { _("Automatic"), _("Hardware acceleration"), _("Software") };
            string[] gfx_values = { "auto", "hardware", "software" };
            string cur_mode = gfx_settings.get_string("rendering-mode");
            string cur_label = gfx_labels[0];
            for (int i = 0; i < gfx_values.length; i++)
                if (gfx_values[i] == cur_mode) cur_label = gfx_labels[i];
            var gfx_row = new SelectionRow(_("Rendering"), gfx_labels, cur_label);
            gfx_row.subtitle = _("Software is a safe fallback if the screen glitches or crashes. Restart to apply.");
            gfx_row.selected.connect((val) => {
                for (int i = 0; i < gfx_labels.length; i++)
                    if (gfx_labels[i] == val) gfx_settings.set_string("rendering-mode", gfx_values[i]);
            });
            graphics_group.add_row(gfx_row);
            add_group(graphics_group);

            var preview_group = graphics_group;
            var settings = new GLib.Settings("dev.sinty.desktop");
            bool preview_enabled = settings.get_boolean("preview-features-enabled");
            var preview_row = new SwitchRow(_("Preview Features"), _("Enable experimental features like Auto-Tiling"), preview_enabled);
            settings.bind("preview-features-enabled", preview_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            preview_group.add_row(preview_row);
            var dev_row = new SwitchRow(_("Developer Mode"), _("Show the Developer settings page"), settings.get_boolean("developer-mode"));
            settings.bind("developer-mode", dev_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            preview_group.add_row(dev_row);
        }

        private void open_security() {
            var page = new DeviceSecurityPage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("system"));
            view.open_subpage(page, "device-security");
        }

        private void copy_info_markdown() {
            var sb = new StringBuilder();
            sb.append("## Singularity report\n\n");
            sb.append_printf("- Singularity Desktop: %s\n", SingularityApp.VERSION);
            var runtime_identity = OsIdentity.load();
            if (OsIdentity.has_host_identity()) {
                sb.append_printf("- Host OS: %s\n", OsIdentity.load_host().menu_label());
                sb.append_printf("- cpak runtime: %s\n", runtime_identity.menu_label());
            } else {
                sb.append_printf("- OS: %s\n", runtime_identity.pretty_name);
                if (runtime_identity.build_id != "")
                    sb.append_printf("- OS build: %s\n", runtime_identity.build_id);
            }
            sb.append_printf("- Kernel: %s\n", get_kernel_version());
            sb.append_printf("- Graphics: %s\n", get_graphics_info());
            sb.append_printf("- Processor: %s\n", get_processor_info());
            sb.append_printf("- Memory: %s\n\n", get_memory_info());
            sb.append(SystemComponents.to_markdown(_components));
            get_clipboard().set_text(sb.str);
        }

        private Widget create_info_row(string title, string value) {
            var row = new ActionRow(title);
            var val_label = new Label(value);
            val_label.add_css_class("dim-label");
            val_label.selectable = true;
            row.add_suffix(val_label);
            return row;
        }

        private void apply_hostname() {
            string new_name = hostname_row.text.strip();
            if (new_name != "" && new_name != GLib.Environment.get_host_name())
                set_hostname_async.begin(new_name);
        }

        // Set the static hostname through systemd-hostnamed over the system bus.
        // interactive=true lets the polkit agent prompt for authorization, which
        // hostnamed handles itself; setting the static name also updates the
        // transient (kernel) hostname.
        private async void set_hostname_async(string new_name) {
            try {
                var conn = yield Bus.get(BusType.SYSTEM);
                yield conn.call(
                    "org.freedesktop.hostname1",
                    "/org/freedesktop/hostname1",
                    "org.freedesktop.hostname1",
                    "SetStaticHostname",
                    new Variant("(sb)", new_name, true),
                    null, DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                warning("Failed to set hostname: %s", e.message);
            }
        }

        private string get_distro_icon_name() {
            string? logo_icon = HardwareInfo.os_release("LOGO");
            string? distro_id = HardwareInfo.os_release("ID");
            var icon_theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
            if (logo_icon != null && logo_icon != "" && icon_theme.has_icon(logo_icon)) {
                return logo_icon;
            }
            if (distro_id != null && distro_id != "" && icon_theme.has_icon(distro_id)) {
                return distro_id;
            }
            if (icon_theme.has_icon("emblem-singularity")) {
                return "emblem-singularity";
            }
            return "computer-symbolic";
        }

        private string get_hardware_model() {
            return HardwareInfo.hardware_model();
        }

        private string get_processor_info() {
            return HardwareInfo.processor();
        }

        private string get_memory_info() {
            return HardwareInfo.memory();
        }

        private string get_disk_info() {
            return HardwareInfo.disk();
        }

        private string get_kernel_version() {
            return HardwareInfo.kernel();
        }

        private string get_firmware_version() {
            return HardwareInfo.firmware();
        }

        private string get_graphics_info() {
            return HardwareInfo.graphics();
        }
    }
}
