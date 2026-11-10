using Gtk;
using Singularity.Widgets;
using Singularity.SintyKey;

namespace Singularity.SidebarPages {

    public class SintyRescuePage : SettingsPage {
        private SettingsView view;
        private KeyDrive drive;
        private RescueClient? rescue;
        private PreferencesGroup accounts_group;
        private PreferencesGroup startup_group;
        private Label status;
        private Button reinstall;
        private bool confirm_reinstall;
        private uint poll;

        public SintyRescuePage(SettingsView view, KeyDrive drive) {
            base(_("Rescue %s").printf(drive.name));
            this.view = view;
            this.drive = drive;
            back_btn.visible = true;
            back_clicked.connect(() => leave.begin());

            accounts_group = new PreferencesGroup(_("Accounts"),
                _("Open an account with its PIN or recovery code to copy its files to the Rescued folder in your home or to read the logs of this computer."));
            accounts_group.visible = false;
            add_group(accounts_group);

            startup_group = new PreferencesGroup(_("Startup"),
                _("Sinty OS is reinstalled from the copy on your Key. The files of every account stay where they are."));
            startup_group.visible = false;
            add_group(startup_group);

            status = status_label();
            add_widget(status);
            open_drive.begin();
        }

        private void say(string text) {
            status.label = text;
            status.visible = text != "";
        }

        private async void open_drive() {
            say(_("Opening the drive of this computer…"));
            try {
                rescue = new RescueClient(yield Client.get_default().rescue(drive.device));
            } catch (KeyError e) {
                say(e.message);
                return;
            }
            say("");
            build_startup();
            yield refresh();
        }

        private async void leave() {
            if (poll != 0) {
                Source.remove(poll);
                poll = 0;
            }
            if (rescue != null) {
                try {
                    yield Client.get_default().end_rescue();
                } catch (KeyError e) {
                }
                rescue = null;
            }
            SintyKeyPage.open(view);
        }

        private async void refresh() {
            accounts_group.clear();
            Gee.ArrayList<RescueHome> homes;
            string problem;
            try {
                homes = yield rescue.homes(out problem);
            } catch (Error e) {
                say(e.message);
                return;
            }
            if (homes.size == 0) {
                accounts_group.add_row(new ActionRow(problem != "" ? problem : _("No accounts were found on this computer."), "", "dialog-warning-symbolic"));
            }
            foreach (var h in homes) {
                if (h.open) add_open(h);
                else add_locked(h);
            }
            accounts_group.visible = true;
        }

        private void add_open(RescueHome h) {
            var row = new ActionRow(h.name, _("Open"), "avatar-default-symbolic");
            var logs = row_button(_("Logs"), false);
            var copy = row_button(_("Copy Files"), true);
            int uid = h.uid;
            string name = h.name;
            logs.clicked.connect(() => show_log.begin(uid, name));
            copy.clicked.connect(() => run.begin("/copy-home", "{\"uid\":%d}".printf(uid)));
            row.add_suffix(logs);
            row.add_suffix(copy);
            accounts_group.add_row(row);
        }

        private void add_locked(RescueHome h) {
            accounts_group.add_row(new ActionRow(h.name, _("Locked"), "avatar-default-symbolic"));
            var pin = new PasswordRow(_("PIN"));
            var by_pin = row_button(_("Open"), true);
            pin.add_suffix(by_pin);
            var code = new EntryRow(_("Or the Recovery Code"));
            var by_code = row_button(_("Open"), false);
            code.add_suffix(by_code);
            int uid = h.uid;
            by_pin.clicked.connect(() => unlock.begin(uid, pin.text, false));
            by_code.clicked.connect(() => unlock.begin(uid, code.text.strip(), true));
            accounts_group.add_row(pin);
            accounts_group.add_row(code);
        }

        private async void unlock(int uid, string secret, bool recovery) {
            if (secret == "") {
                say(recovery ? _("Enter the recovery code.") : _("Enter the PIN."));
                return;
            }
            say(_("Opening the account…"));
            try {
                yield rescue.unlock(uid, secret, recovery);
                say("");
            } catch (Error e) {
                say(e.message);
                return;
            }
            yield refresh();
        }

        private async void show_log(int uid, string name) {
            string log;
            try {
                log = yield rescue.sealed_log(uid);
            } catch (Error e) {
                say(e.message);
                return;
            }
            var page = new SettingsPage(_("Logs of %s").printf(drive.name));
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.show_page_name("sinty-rescue"));
            var text = new Label(log);
            text.selectable = true;
            text.wrap = true;
            text.xalign = 0;
            text.yalign = 0;
            text.add_css_class("monospace");
            page.add_widget(text);
            view.open_subpage(page, "sinty-rescue-log");
        }

        private void build_startup() {
            var repair = new ActionRow(_("Repair Startup"), _("Puts back the boot files of this computer."), "system-reboot-symbolic");
            var repair_btn = row_button(_("Repair"), false);
            repair_btn.clicked.connect(() => run.begin("/repair-loader", "{}"));
            repair.add_suffix(repair_btn);
            startup_group.add_row(repair);

            var again = new ActionRow(_("Reinstall Sinty OS"), _("From your Key, keeping the files."), "system-software-install-symbolic");
            reinstall = row_button(_("Reinstall"), false);
            reinstall.add_css_class("destructive-action");
            reinstall.clicked.connect(() => {
                if (!confirm_reinstall) {
                    confirm_reinstall = true;
                    reinstall.label = _("Reinstall Now");
                    say(_("Sinty OS on this computer is replaced with the version on your Key. Press again to go on."));
                    return;
                }
                confirm_reinstall = false;
                reinstall.label = _("Reinstall");
                run.begin("/reinstall", "{}");
            });
            again.add_suffix(reinstall);
            startup_group.add_row(again);
            startup_group.visible = true;
        }

        private async void run(string path, string body) {
            if (poll != 0) return;
            try {
                if (!(yield rescue.start(path, body))) {
                    say(_("Something else is still running on this drive."));
                    return;
                }
            } catch (Error e) {
                say(e.message);
                return;
            }
            poll = Timeout.add(700, () => {
                follow.begin();
                return Source.CONTINUE;
            });
            yield follow();
        }

        private async void follow() {
            if (rescue == null) return;
            RescueStatus st;
            try {
                st = yield rescue.status();
            } catch (Error e) {
                return;
            }
            say(st.progress >= 0 && st.working ? "%s %d%%".printf(st.message, st.progress) : st.message);
            if (!st.working && poll != 0) {
                Source.remove(poll);
                poll = 0;
            }
        }
    }
}
