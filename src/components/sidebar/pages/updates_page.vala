using Gtk;
using Singularity.Widgets;
using Singularity.Updates;

namespace Singularity.SidebarPages {

    public class UpdatesPage : SettingsPage {
        private SettingsView view;
        private Provider? provider = null;
        private WelcomePage? welcome = null;
        private PreferencesGroup system_group;
        private ActionRow os_row;
        private Button os_btn;
        private Spinner os_spinner;
        private ProgressBar progress_bar;
        private ActionRow progress_row;
        private ExpanderRow notes_row;
        private ActionRow later_row;
        private ActionRow firmware_row;
        private ActionRow auto_row;
        private GLib.Settings settings;
        private ulong provider_handler = 0;
        private ulong firmware_handler = 0;
        private bool busy = false;

        public UpdatesPage(SettingsView view) {
            base(_("Updates"));
            this.view = view;
            settings = new GLib.Settings("dev.sinty.desktop");
            back_clicked.connect(() => view.go_home());

            system_group = new PreferencesGroup(_("System and Firmware"),
                _("Updates for the operating system and for the firmware inside your devices."));
            os_row = new ActionRow(HardwareInfo.os_name(), _("Looking for the update service..."), "computer-symbolic");
            os_spinner = new Spinner();
            os_spinner.valign = Align.CENTER;
            os_spinner.visible = false;
            os_row.add_suffix(os_spinner);
            os_btn = new Button.with_label(_("Check"));
            os_btn.valign = Align.CENTER;
            os_btn.visible = false;
            os_btn.clicked.connect(on_primary);
            os_row.add_suffix(os_btn);
            system_group.add_row(os_row);

            progress_row = new ActionRow(_("Downloading"), "");
            progress_bar = new ProgressBar();
            progress_bar.valign = Align.CENTER;
            progress_bar.width_request = 120;
            progress_row.add_suffix(progress_bar);
            progress_row.visible = false;
            system_group.add_row(progress_row);

            notes_row = new ExpanderRow(_("What's New"), "", "text-x-generic-symbolic");
            notes_row.visible = false;
            system_group.add_row(notes_row);

            later_row = new ActionRow(_("Install Another Time"), _("Keep the download without installing it on restart"));
            var later_btn = new Button.with_label(_("Cancel"));
            later_btn.valign = Align.CENTER;
            later_btn.clicked.connect(() => run_action.begin("unschedule"));
            later_row.add_suffix(later_btn);
            later_row.visible = false;
            system_group.add_row(later_row);

            firmware_row = new ActionRow(_("Firmware"), _("Looking for devices..."), "application-x-firmware-symbolic");
            firmware_row.activatable = true;
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            chevron.add_css_class("dim-label");
            chevron.valign = Align.CENTER;
            firmware_row.add_suffix(chevron);
            firmware_row.activated.connect(open_firmware);
            system_group.add_row(firmware_row);

            auto_row = new ActionRow(_("Automatic Updates"), AutomaticUpdatesPage.summary(settings), "preferences-system-time-symbolic");
            auto_row.activatable = true;
            var auto_chevron = new Image.from_icon_name("go-next-symbolic");
            auto_chevron.pixel_size = 12;
            auto_chevron.add_css_class("dim-label");
            auto_chevron.valign = Align.CENTER;
            auto_row.add_suffix(auto_chevron);
            auto_row.activated.connect(open_automatic);
            auto_row.visible = false;
            system_group.add_row(auto_row);
            settings.changed.connect((key) => {
                if (key.has_prefix("updates-automatic") || key == "updates-check-frequency") {
                    auto_row.subtitle = AutomaticUpdatesPage.summary(settings);
                }
            });
            add_group(system_group);


            add_search_action(_("Check for Updates"), _("Look for a newer version of the system now"), () => run_action.begin("check"));
            add_search_action(_("Firmware"), _("Device firmware, drivers and security metadata"), open_firmware);
            add_search_action(_("Automatic Updates"), _("Check for and download updates in the background"), open_automatic);
            add_search_action(_("Update History"), _("See which updates were installed and when"), open_history);

            destroy.connect(() => {
                if (provider != null && provider_handler != 0) provider.disconnect(provider_handler);
                if (firmware_handler != 0) Firmware.Client.get_default().disconnect(firmware_handler);
            });

            load.begin();
        }

        private async void load() {
            provider = yield Backend.get_default();
            provider_handler = provider.changed.connect(() => update_status());
            build_welcome();
            auto_row.visible = provider.kind != "none";
            update_status();
            yield load_firmware();
        }

        private void build_welcome() {
            welcome = new WelcomePage();
            welcome.is_section = true;
            welcome.embedded = true;
            welcome.compact = true;
            welcome.app_icon_name = "singularity-updates";
            welcome.add_action("dev.sinty.store", _("App Updates"), _("Apps are updated in Store"), open_store);
            welcome.add_action("document-open-recent", _("Update History"), _("See which updates were installed and when"), open_history);
            content_box.insert_child_after(welcome, top_spacer);
        }

        private void open_store() {
            var info = new DesktopAppInfo("dev.sinty.store.desktop");
            if (info == null) {
                os_row.subtitle = _("Store is not installed");
                return;
            }
            var context = Gdk.Display.get_default().get_app_launch_context();
            if (info.list_actions().length > 0 && "updates" in info.list_actions()) {
                info.launch_action("updates", context);
            } else {
                try {
                    info.launch(null, context);
                } catch (Error e) {
                    warning("Updates: cannot open Store: %s", e.message);
                }
            }
        }

        private void open_firmware() {
            var page = new FirmwarePage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("updates"));
            view.open_subpage(page, "firmware");
        }

        private void open_automatic() {
            var page = new AutomaticUpdatesPage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("updates"));
            view.open_subpage(page, "automatic-updates");
        }

        private void open_history() {
            var page = new UpdateHistoryPage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to("updates"));
            view.open_subpage(page, "update-history");
        }

        public static string ago(int64 time) {
            if (time <= 0) return _("never");
            int64 seconds = get_real_time() / 1000000 - time;
            if (seconds < 90) return _("just now");
            if (seconds < 3600) {
                int minutes = (int) (seconds / 60);
                return ngettext("%d minute ago", "%d minutes ago", minutes).printf(minutes);
            }
            if (seconds < 86400) {
                int hours = (int) (seconds / 3600);
                return ngettext("%d hour ago", "%d hours ago", hours).printf(hours);
            }
            if (seconds < 172800) return _("yesterday");
            var date = new DateTime.from_unix_local(time);
            return date.format(_("%-d %B %Y")).strip();
        }

        private int64 last_check() {
            int64 stored = settings.get_int64("updates-last-check");
            return int64.max(stored, provider.last_check);
        }

        private string package_summary() {
            int count = provider.packages.size;
            int security = 0;
            foreach (var pkg in provider.packages) {
                if (pkg.security) security++;
            }
            string text = ngettext("%d package", "%d packages", count).printf(count);
            if (security > 0) text = _("%s, %d with security fixes").printf(text, security);
            if (provider.download_size > 0) text = "%s, %s".printf(text, format_size(provider.download_size));
            return text;
        }

        private void update_status() {
            if (provider == null) return;
            string title = _("Updates");
            string detail = "";
            string button = "";
            bool spinning = provider.state.is_busy() || busy;
            os_row.title = provider.kind == "none" ? HardwareInfo.os_name() : provider.name;
            string version = provider.current_version != "" ? provider.current_version : HardwareInfo.os_name();
            switch (provider.state) {
                case State.CHECKING:
                    title = _("Checking for Updates");
                    detail = _("Looking for a newer version of the system");
                    break;
                case State.UP_TO_DATE:
                    title = _("Up to Date");
                    detail = _("%s. Last checked %s.").printf(version, ago(last_check()));
                    button = _("Check");
                    break;
                case State.AVAILABLE:
                    if (provider.available_version != "") {
                        title = _("Update Available");
                        detail = provider.download_size > 0
                            ? _("%s, %s to download").printf(provider.available_version, format_size(provider.download_size))
                            : provider.available_version;
                    } else {
                        int count = provider.packages.size;
                        title = ngettext("%d Update Available", "%d Updates Available", count).printf(count);
                        detail = package_summary();
                    }
                    button = provider.can_download ? _("Download") : _("Install on Restart");
                    break;
                case State.DOWNLOADING:
                    title = _("Downloading Updates");
                    detail = _("You can keep working while the update downloads");
                    break;
                case State.READY:
                    title = _("Ready to Install");
                    detail = _("Downloaded. Choose Install on Restart to install it when the computer starts again.");
                    button = _("Install on Restart");
                    break;
                case State.SCHEDULED:
                    title = _("Restart to Finish Updating");
                    detail = _("The update installs while the computer restarts.");
                    button = _("Restart");
                    break;
                case State.ERROR:
                    title = _("Update Failed");
                    detail = provider.last_error != "" ? provider.last_error : _("The update service reported a problem");
                    button = _("Try Again");
                    break;
                default:
                    if (provider.kind == "none") {
                        title = _("Updated Outside Settings");
                        detail = _("This system has no update service Settings can use. Use your distribution's own tools to update it.");
                    } else {
                        title = last_check() > 0 ? _("Checked %s").printf(ago(last_check())) : _("Not Checked Yet");
                        detail = version;
                        button = _("Check");
                    }
                    break;
            }
            if (welcome != null) {
                welcome.title = title;
                welcome.subtitle = provider.kind == "none" ? detail : provider.description;
            }
            os_row.subtitle = provider.kind == "none" ? _("Updated with the tools of your distribution") : detail;
            os_spinner.visible = spinning;
            os_spinner.spinning = spinning;
            os_btn.visible = button != "" && !spinning;
            os_btn.label = button;
            if (provider.state == State.AVAILABLE || provider.state == State.READY) {
                os_btn.add_css_class("suggested-action");
            } else {
                os_btn.remove_css_class("suggested-action");
            }
            progress_row.visible = provider.state == State.DOWNLOADING;
            if (provider.progress >= 0) {
                progress_bar.fraction = provider.progress.clamp(0, 1);
                progress_row.subtitle = "%d%%".printf((int) Math.round(provider.progress * 100));
            } else {
                progress_bar.pulse();
                progress_row.subtitle = "";
            }
            later_row.visible = provider.state == State.SCHEDULED && provider.can_unschedule;
            update_notes();
        }

        private void update_notes() {
            bool show = provider.state == State.AVAILABLE || provider.state == State.DOWNLOADING
                || provider.state == State.READY || provider.state == State.SCHEDULED;
            notes_row.clear_rows();
            if (!show || (provider.release_notes == "" && provider.packages.size == 0)) {
                notes_row.visible = false;
                return;
            }
            notes_row.visible = true;
            if (provider.release_notes != "") {
                notes_row.subtitle = provider.available_version != "" ? provider.available_version : "";
                var label = new Label(provider.release_notes);
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.xalign = 0;
                label.margin_start = 12;
                label.margin_end = 12;
                label.margin_top = 6;
                label.margin_bottom = 10;
                label.selectable = true;
                notes_row.add_row(label);
                return;
            }
            notes_row.subtitle = package_summary();
            int shown = 0;
            foreach (var pkg in provider.packages) {
                if (shown == 30) break;
                var row = new ActionRow(pkg.name, pkg.version, pkg.security ? "security-high-symbolic" : null);
                if (pkg.summary != "") row.tooltip_text = pkg.summary;
                notes_row.add_row(row);
                shown++;
            }
            if (provider.packages.size > shown) {
                notes_row.add_row(new ActionRow(_("%d more").printf(provider.packages.size - shown)));
            }
        }

        private void on_primary() {
            if (provider == null) return;
            switch (provider.state) {
                case State.AVAILABLE:
                    run_action.begin(provider.can_download ? "download" : "schedule");
                    break;
                case State.READY:
                    run_action.begin("schedule");
                    break;
                case State.SCHEDULED:
                    confirm_restart();
                    break;
                default:
                    run_action.begin("check");
                    break;
            }
        }

        private void confirm_restart() {
            var app = GLib.Application.get_default() as Gtk.Application;
            var dialog = new ConfirmDialog(app, _("Restart to Update?"), "singularity-updates",
                _("Save your work first. Apps close, and the update installs before the system starts again."),
                _("Restart"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) SessionManager.get_default().reboot();
            });
            dialog.present();
        }

        private async void run_action(string action) {
            if (provider == null || busy) return;
            busy = true;
            update_status();
            try {
                switch (action) {
                    case "check":
                        yield provider.check();
                        settings.set_int64("updates-last-check", get_real_time() / 1000000);
                        break;
                    case "download":
                        yield provider.download();
                        break;
                    case "schedule":
                        yield provider.schedule();
                        break;
                    case "unschedule":
                        yield provider.unschedule();
                        break;
                }
            } catch (Error e) {
                debug("Updates: %s failed: %s", action, e.message);
            }
            busy = false;
            update_status();
        }

        private async void load_firmware() {
            var client = Firmware.Client.get_default();
            if (!(yield client.probe())) {
                firmware_row.subtitle = _("Firmware updates are not available on this system");
                return;
            }
            if (firmware_handler == 0) {
                firmware_handler = client.changed.connect(() => refresh_firmware.begin());
            }
            yield refresh_firmware();
        }

        private async void refresh_firmware() {
            var client = Firmware.Client.get_default();
            try {
                var devices = yield client.devices();
                int updatable = 0;
                int pending = 0;
                foreach (var device in devices) {
                    if (device.upgrades.size > 0) updatable++;
                    if (device.update_state == 4) pending++;
                }
                yield client.read_properties();
                if (client.pending_reboot || pending > 0) {
                    firmware_row.subtitle = _("Restart the computer to finish a firmware update");
                } else if (updatable > 0) {
                    firmware_row.subtitle = ngettext("%d device has an update", "%d devices have updates", updatable).printf(updatable);
                } else {
                    firmware_row.subtitle = ngettext("Up to date, %d device", "Up to date, %d devices", devices.size).printf(devices.size);
                }
            } catch (Error e) {
                firmware_row.subtitle = e.message;
            }
        }
    }
}
