using Gtk;
using Singularity.Widgets;
using Singularity.Firmware;

namespace Singularity.SidebarPages {

    public class FirmwarePage : SettingsPage {
        private SettingsView view;
        private StatusPage unavailable;
        private PreferencesGroup devices_group;
        private Button refresh_btn;
        private Spinner refresh_spinner;
        private PreferencesGroup drivers_group;
        private ulong changed_handler = 0;
        private bool installing = false;

        public FirmwarePage(SettingsView view) {
            base(_("Firmware"));
            this.view = view;

            unavailable = new StatusPage();
            unavailable.compact = true;
            unavailable.icon_name = "singularity-firmware";
            unavailable.title = _("Firmware Updates Unavailable");
            unavailable.description = _("The firmware update service, fwupd, is not installed or not running on this system.");
            unavailable.visible = false;
            add_widget(unavailable);

            devices_group = new PreferencesGroup(_("Devices"), _("Firmware comes from device makers through the Linux Vendor Firmware Service."));
            refresh_spinner = new Spinner();
            refresh_spinner.valign = Align.CENTER;
            refresh_spinner.visible = false;
            devices_group.add_header_suffix(refresh_spinner);
            refresh_btn = new Button.with_label(_("Refresh"));
            refresh_btn.valign = Align.CENTER;
            refresh_btn.tooltip_text = _("Download the latest list of firmware from the Linux Vendor Firmware Service");
            refresh_btn.clicked.connect(() => refresh_metadata.begin());
            devices_group.add_header_suffix(refresh_btn);
            devices_group.visible = false;
            add_group(devices_group);

            drivers_group = new PreferencesGroup(_("Drivers"),
                _("Extra drivers from device makers, installed outside the system packages."));
            add_group(drivers_group);

            destroy.connect(() => {
                if (changed_handler != 0) Client.get_default().disconnect(changed_handler);
            });

            load.begin();
            load_drivers.begin();
        }

        private async void load() {
            var client = Client.get_default();
            if (!(yield client.probe())) {
                unavailable.visible = true;
                return;
            }
            devices_group.visible = true;
            changed_handler = client.changed.connect(() => {
                if (!installing) load_devices.begin();
            });
            yield load_devices();
        }

        private async void update_refreshed_label() {
            try {
                uint64 newest = 0;
                foreach (var remote in yield Client.get_default().remotes()) {
                    if (remote.enabled && remote.downloads && remote.modified > newest) newest = remote.modified;
                }
                string base_text = _("Firmware comes from device makers through the Linux Vendor Firmware Service.");
                devices_group.description = newest > 0
                    ? _("%s Last refreshed %s.").printf(base_text, UpdatesPage.ago((int64) newest))
                    : _("%s Not refreshed yet.").printf(base_text);
            } catch (Error e) {
                debug("Firmware: cannot read remotes: %s", e.message);
            }
        }

        private async void load_devices() {
            Gee.ArrayList<Device> devices;
            try {
                devices = yield Client.get_default().devices();
            } catch (Error e) {
                devices_group.clear();
                devices_group.add_row(new ActionRow(_("Cannot List Devices"), e.message, "dialog-warning-symbolic"));
                return;
            }
            yield update_refreshed_label();
            devices_group.clear();
            if (devices.size == 0) {
                devices_group.add_row(new ActionRow(_("No Supported Devices"),
                    _("None of the devices in this computer can receive firmware updates this way."), "object-select-symbolic"));
                return;
            }
            foreach (var device in devices) devices_group.add_row(device_row(device));
        }

        private string device_icon(Device device) {
            var theme = IconTheme.get_for_display(Gdk.Display.get_default());
            foreach (string icon in device.icons) {
                if (theme.has_icon(icon + "-symbolic")) return icon + "-symbolic";
            }
            return "application-x-firmware-symbolic";
        }

        private Widget device_row(Device device) {
            var latest = device.latest;
            string subtitle;
            if (device.update_state == 4) {
                subtitle = _("Restart the computer to finish the update");
            } else if (latest != null) {
                subtitle = _("Version %s, update to %s available").printf(device.version, latest.version);
            } else if (device.version != "") {
                subtitle = device.updatable ? _("Version %s, up to date").printf(device.version) : _("Version %s").printf(device.version);
            } else {
                subtitle = device.updatable ? _("Up to date") : _("Not updatable");
            }
            var row = new ExpanderRow(device.name, subtitle, device_icon(device));
            if (device.vendor != "") row.add_row(new ActionRow(_("Maker"), device.vendor));
            if (device.summary != "") row.add_row(new ActionRow(_("Description"), device.summary));
            if (device.version != "") row.add_row(new ActionRow(_("Installed Version"), device.version));
            if (latest != null) {
                string notes = latest.notes != "" ? latest.notes : latest.summary;
                var release_row = new ActionRow(_("Version %s").printf(latest.version),
                    notes != "" ? notes : _("The maker did not publish release notes."));
                row.add_row(release_row);
                string[] needs = {};
                if (device.needs_restart) needs += _("The computer restarts to install it.");
                if (device.requires_ac) needs += _("The charger must be connected.");
                if (latest.size > 0) needs += _("Download size %s.").printf(format_size(latest.size));
                var update_row = new ActionRow(_("Update Firmware"), string.joinv(" ", needs));
                var spinner = new Spinner();
                spinner.valign = Align.CENTER;
                spinner.visible = false;
                update_row.add_suffix(spinner);
                var button = new Button.with_label(_("Update"));
                button.valign = Align.CENTER;
                button.add_css_class("suggested-action");
                button.clicked.connect(() => confirm_install(device, latest, update_row, button, spinner));
                update_row.add_suffix(button);
                row.add_row(update_row);
            }
            if (device.update_error != "") {
                row.add_row(new ActionRow(_("Last Update Failed"), device.update_error, "dialog-warning-symbolic"));
            }
            return row;
        }

        private void confirm_install(Device device, Release release, ActionRow row, Button button, Spinner spinner) {
            var app = GLib.Application.get_default() as Gtk.Application;
            string description = device.needs_restart
                ? _("%s updates to version %s. The update finishes while the computer restarts, so save your work first.").printf(device.name, release.version)
                : _("%s updates to version %s. Do not unplug it or turn off the computer until it finishes.").printf(device.name, release.version);
            var dialog = new ConfirmDialog(app, _("Update Firmware?"), "singularity-firmware", description,
                _("Update"), ConfirmDialog.ActionStyle.SUGGESTED);
            if (device.requires_ac) {
                var label = new Label(_("Connect the charger before you continue."));
                label.wrap = true;
                label.max_width_chars = 42;
                label.add_css_class("dim-label");
                dialog.custom_area.append(label);
            }
            dialog.response.connect((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                install.begin(device, release, row, button, spinner);
            });
            dialog.present();
        }

        private async void install(Device device, Release release, ActionRow row, Button button, Spinner spinner) {
            installing = true;
            button.visible = false;
            spinner.visible = true;
            spinner.spinning = true;
            row.subtitle = _("Downloading and installing...");
            try {
                yield Client.get_default().install(device, release);
                installing = false;
                yield load_devices();
                return;
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                row.subtitle = e.message;
                button.visible = true;
            }
            spinner.spinning = false;
            spinner.visible = false;
            installing = false;
        }

        private async void refresh_metadata() {
            refresh_btn.visible = false;
            refresh_spinner.visible = true;
            refresh_spinner.spinning = true;
            try {
                yield Client.get_default().refresh_metadata();
                yield load_devices();
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                devices_group.description = _("Refreshing failed: %s").printf(e.message);
            }
            refresh_spinner.spinning = false;
            refresh_spinner.visible = false;
            refresh_btn.visible = true;
        }

        private async void load_drivers() {
            drivers_group.clear();
            int count = 0;
            foreach (var provider in UserspaceDrivers.providers()) {
                foreach (var driver in yield provider.drivers()) {
                    drivers_group.add_row(driver_row(driver));
                    count++;
                }
            }
            if (count == 0) {
                drivers_group.add_row(new ActionRow(_("No Extra Drivers Needed"),
                    _("The devices in this computer work with the drivers the system already has."), "object-select-symbolic"));
            }
        }

        private string driver_subtitle(UserspaceDriver driver) {
            return driver.installed
                ? _("%s, version %s, installed").printf(driver.provider.name, driver.version)
                : _("%s, not installed").printf(driver.provider.name);
        }

        private Widget driver_row(UserspaceDriver driver) {
            var row = new ExpanderRow(driver.name, driver_subtitle(driver), driver.provider.icon_name);
            row.add_row(new ActionRow(_("Device"), "%s %s".printf(driver.provider.name, driver.device_id)));
            row.add_row(new ActionRow(_("Maker"), driver.vendor));
            if (driver.source != "") row.add_row(new ActionRow(_("Source"), driver.source));
            if (driver.license != "") row.add_row(new ActionRow(_("License"), driver.license));

            if (driver.installed) {
                row.add_row(driver_action(driver, "reinstall", _("Reinstall the Driver"), _("Download it again if the device stops working"), _("Reinstall"), row));
                row.add_row(driver_action(driver, "remove", _("Remove the Driver"), _("The device stops working until the driver is installed again"), _("Remove"), row));
            } else {
                row.add_row(driver_action(driver, "install", _("Install Driver"), _("Downloaded from %s").printf(driver.host), _("Install"), row));
            }
            if (driver.provider.setup_page != "") {
                var setup = new ActionRow(_("Set Up the Device"), _("Open the settings that use this device"));
                setup.activatable = true;
                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.pixel_size = 12;
                chevron.add_css_class("dim-label");
                chevron.valign = Align.CENTER;
                setup.add_suffix(chevron);
                setup.activated.connect(() => view.navigate_to(driver.provider.setup_page));
                row.add_row(setup);
            }
            return row;
        }

        private ActionRow driver_action(UserspaceDriver driver, string mode, string title, string subtitle, string label, ExpanderRow parent) {
            var action_row = new ActionRow(title, subtitle);
            var spinner = new Spinner();
            spinner.valign = Align.CENTER;
            spinner.visible = false;
            action_row.add_suffix(spinner);
            var button = new Button.with_label(label);
            button.valign = Align.CENTER;
            if (mode == "remove") button.add_css_class("destructive-action");
            if (mode == "install") button.add_css_class("suggested-action");
            button.clicked.connect(() => confirm_driver(driver, mode, action_row, button, spinner, parent));
            action_row.add_suffix(button);
            return action_row;
        }

        private void confirm_driver(UserspaceDriver driver, string mode, ActionRow row, Button button, Spinner spinner, ExpanderRow parent) {
            var app = GLib.Application.get_default() as Gtk.Application;
            ConfirmDialog dialog;
            if (mode == "remove") {
                dialog = new ConfirmDialog(app, _("Remove the Manufacturer's Driver?"), "user-trash",
                    _("The %s stops working until the driver is installed again. Its settings are kept.").printf(driver.provider.name.down()),
                    _("Remove"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            } else {
                dialog = new ConfirmDialog(app,
                    mode == "reinstall" ? _("Reinstall the Manufacturer's Driver?") : _("Install the Manufacturer's Driver?"),
                    "dialog-warning",
                    _("%s is proprietary software from %s. It is not part of Singularity, its source code is not available, and Singularity cannot review or update it.").printf(driver.name, driver.vendor),
                    mode == "reinstall" ? _("Reinstall") : _("Install"), ConfirmDialog.ActionStyle.SUGGESTED);
                string[] details = {
                    _("Downloaded from: %s, where the vendor publishes it").printf(driver.host),
                    _("Installed as a Singularity driver plugin. No system packages are installed or changed."),
                    _("Version: %s, %s").printf(driver.version, format_size((uint64) driver.size)),
                    _("License: %s").printf(driver.license),
                    _("The download is checked against a known fingerprint before anything is installed."),
                };
                foreach (string text in details) {
                    var label = new Label(text);
                    label.wrap = true;
                    label.max_width_chars = 42;
                    label.xalign = 0;
                    label.add_css_class("dim-label");
                    dialog.custom_area.append(label);
                }
            }
            dialog.response.connect((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                run_driver.begin(driver, mode, row, button, spinner, parent);
            });
            dialog.present();
        }

        private async void run_driver(UserspaceDriver driver, string mode, ActionRow row, Button button, Spinner spinner, ExpanderRow parent) {
            button.visible = false;
            spinner.visible = true;
            spinner.spinning = true;
            row.subtitle = mode == "remove" ? _("Removing the driver...") : _("Downloading and installing the driver...");
            try {
                if (mode == "remove") {
                    yield driver.uninstall();
                } else {
                    yield driver.install();
                }
                yield load_drivers();
                return;
            } catch (Error e) {
                row.subtitle = (e is IOError.CANCELLED) ? _("Nothing was changed") : e.message;
            }
            spinner.spinning = false;
            spinner.visible = false;
            button.visible = true;
        }
    }
}
