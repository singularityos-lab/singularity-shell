using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public abstract class MobileSubpage : SettingsPage {
        protected unowned SettingsView view;
        protected MobileNetwork mobile;
        private PreferencesGroup result_group;
        private ActionRow result_row;
        private ulong changed_id = 0;

        protected MobileSubpage(SettingsView view, string title, string parent) {
            base(title);
            this.view = view;
            mobile = MobileNetwork.get_default();
            back_clicked.connect(() => this.view.navigate_to(parent));
            result_group = new PreferencesGroup(_("Last Action"));
            result_row = new ActionRow("", null);
            result_row.set_data<bool>("settings-search-skip", true);
            result_group.add_row(result_row);
            result_group.visible = false;
            add_group(result_group);
        }

        protected void follow_modem() {
            changed_id = mobile.changed.connect(() => sync());
            destroy.connect(() => {
                if (changed_id == 0) return;
                mobile.disconnect(changed_id);
                changed_id = 0;
            });
            sync();
            mobile.refresh.begin();
        }

        protected virtual void sync() {}

        protected void report(string title, string detail = "") {
            result_row.title = title;
            result_row.subtitle = detail;
            result_group.visible = true;
            scroller.vadjustment.value = 0;
        }

        protected ActionRow action_row(PreferencesGroup group, string title, string? subtitle, string icon) {
            var row = new ActionRow(title, subtitle, icon);
            row.activatable = true;
            group.add_row(row);
            return row;
        }

        protected ActionRow link_row(PreferencesGroup group, string title, string? subtitle, string icon, string page) {
            var row = action_row(group, title, subtitle, icon);
            row.add_suffix(PermissionRows.chevron());
            row.activated.connect(() => view.navigate_to(page));
            return row;
        }

        protected async Variant? apply(MobileCommand command, Variant? args, string done, Widget? busy = null) {
            if (busy != null) busy.sensitive = false;
            report(_("Working…"));
            Variant? reply = null;
            try {
                reply = yield mobile.run(command, args);
                report(done);
            } catch (Error e) {
                report(_("That did not work"), ModemError.describe(e));
            }
            if (busy != null) busy.sensitive = true;
            sync();
            return reply;
        }
    }

    public class MobilePage : MobileSubpage {
        public const string PAGE = "network-mobile";

        private ActionRow status_row;
        private ActionRow signal_row;
        private ActionRow calls_row;
        private SwitchRow radio_row;
        private SwitchRow data_row;
        private SwitchRow roaming_row;
        private SwitchRow lte_row;
        private EntryRow apn_row;
        private PreferencesGroup pin_group;
        private Box operators_box;
        private PasswordRow pin_row;
        private PasswordRow puk_row;
        private PasswordRow new_pin_row;
        private ActionRow unblock_row;
        private PasswordRow current_pin_row;
        private PasswordRow next_pin_row;
        private ActionRow change_pin_row;
        private bool syncing = false;

        public MobilePage(SettingsView view) {
            base(view, _("Mobile Network"), "network");

            var connection = new PreferencesGroup(_("Connection"));
            status_row = new ActionRow(_("Carrier"), null, "network-cellular-symbolic");
            connection.add_row(status_row);
            signal_row = new ActionRow(_("Signal"), null);
            connection.add_row(signal_row);
            calls_row = new ActionRow(_("Calls over 4G (VoLTE)"), null);
            connection.add_row(calls_row);
            radio_row = new SwitchRow(_("Mobile Network"), _("Calls, messages and data"));
            connection.add_row(radio_row);
            add_group(connection);

            pin_group = new PreferencesGroup(_("SIM Lock"));
            pin_row = new PasswordRow(_("SIM PIN"));
            pin_row.entry_activated.connect(() => {
                if (pin_row.text == "") return;
                apply.begin(MobileCommand.SEND_PIN, new Variant("(s)", pin_row.text), _("SIM unlocked"), pin_row);
                pin_row.text = "";
            });
            pin_group.add_row(pin_row);
            puk_row = new PasswordRow(_("PUK from Your Carrier"));
            pin_group.add_row(puk_row);
            new_pin_row = new PasswordRow(_("New SIM PIN"));
            new_pin_row.entry_activated.connect(() => unblock());
            pin_group.add_row(new_pin_row);
            unblock_row = action_row(pin_group, _("Unblock SIM"),
                _("Too many wrong PUKs disable the SIM for good"), "dialog-password-symbolic");
            unblock_row.activated.connect(() => unblock());
            current_pin_row = new PasswordRow(_("Current SIM PIN"));
            pin_group.add_row(current_pin_row);
            next_pin_row = new PasswordRow(_("New SIM PIN"));
            next_pin_row.entry_activated.connect(() => change_pin());
            pin_group.add_row(next_pin_row);
            change_pin_row = action_row(pin_group, _("Change SIM PIN"),
                _("Too many wrong PINs block the SIM"), "dialog-password-symbolic");
            change_pin_row.activated.connect(() => change_pin());
            pin_group.visible = false;
            add_group(pin_group);

            var sims = new PreferencesGroup(_("SIMs"));
            link_row(sims, _("eSIM"), _("Add, switch, rename and delete"), "media-flash-symbolic", EsimPage.PAGE);
            var use_esim = action_row(sims, _("Use the eSIM"), _("Moves the line to the built-in chip"), "media-flash-symbolic");
            use_esim.activated.connect(() => apply.begin(MobileCommand.SELECT_SLOT,
                new Variant("(u)", MobileNetwork.ESIM_SLOT), _("Switched to the eSIM"), use_esim));
            var use_sim = action_row(sims, _("Use the SIM Card"), _("Moves the line to the card tray"), "media-flash-symbolic");
            use_sim.activated.connect(() => apply.begin(MobileCommand.SELECT_SLOT,
                new Variant("(u)", MobileNetwork.SIM_SLOT), _("Switched to the SIM card"), use_sim));
            add_group(sims);

            var choice = new PreferencesGroup(_("Carrier Selection"));
            var automatic = action_row(choice, _("Choose Automatically"), null, "emblem-ok-symbolic");
            automatic.activated.connect(() => apply.begin(MobileCommand.SELECT_NETWORK,
                new Variant("(s)", ""), _("The modem chooses the network"), automatic));
            var search = action_row(choice, _("Search Networks"), _("Can take up to three minutes"), "system-search-symbolic");
            search.activated.connect(() => search_networks.begin(search));
            add_group(choice);
            operators_box = new Box(Orientation.VERTICAL, 0);
            add_widget(operators_box);

            var data = new PreferencesGroup(_("Mobile Data"));
            data_row = new SwitchRow(_("Mobile Data"), _("Internet away from Wi-Fi"));
            data.add_row(data_row);
            roaming_row = new SwitchRow(_("Data Roaming"), _("Your carrier may charge for data abroad"));
            data.add_row(roaming_row);
            lte_row = new SwitchRow(_("4G Only"), _("No signal where there is no 4G"));
            data.add_row(lte_row);
            apn_row = new EntryRow(_("Access Point Name"));
            apn_row.placeholder_text = _("Automatic");
            apn_row.entry_activated.connect(() => apply.begin(MobileCommand.SET_APN,
                new Variant("(s)", apn_row.text.strip()), _("Access point saved"), apn_row));
            data.add_row(apn_row);
            add_group(data);

            var device = new PreferencesGroup(_("Identifiers and Help"));
            var imei_row = action_row(device, _("IMEI"), _("Tap to show"), "phone-symbolic");
            imei_row.activated.connect(() => show_imei.begin(imei_row));
            link_row(device, _("Modem Recovery"), _("Restart, slots and diagnostics"), "view-refresh-symbolic", ModemPage.PAGE);
            add_group(device);

            bind_switch(radio_row, MobileCommand.SET_RADIO);
            bind_switch(data_row, MobileCommand.SET_DATA);
            bind_switch(roaming_row, MobileCommand.SET_ROAMING);
            bind_switch(lte_row, MobileCommand.SET_LTE_ONLY);
            follow_modem();
        }

        private void bind_switch(SwitchRow row, MobileCommand command) {
            row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                apply.begin(command, new Variant("(b)", row.active), _("Saved"), row);
            });
        }

        private async void search_networks(Widget row) {
            row.sensitive = false;
            report(_("Searching…"));
            try {
                show_operators(yield mobile.search_operators());
                report(_("Search finished"));
            } catch (Error e) {
                report(_("The search did not work"), ModemError.describe(e));
            }
            row.sensitive = true;
        }

        private void show_operators(Gee.List<MobileOperator> found) {
            Widget? child;
            while ((child = operators_box.get_first_child()) != null) operators_box.remove(child);
            var group = new PreferencesGroup(_("Networks Found"));
            if (found.size == 0) group.add_row(new ActionRow(_("No network found"), null));
            foreach (var op in found) {
                string code = op.code;
                string? state = null;
                if (op.status == 2) state = _("In use");
                else if (op.status == 3) state = _("Not allowed for this SIM");
                string title = op.status == 2 && mobile.operator_name != "" ? mobile.operator_name : code;
                var row = action_row(group, title, state, "network-cellular-symbolic");
                row.activated.connect(() => apply.begin(MobileCommand.SELECT_NETWORK,
                    new Variant("(s)", code), _("Network chosen"), row));
            }
            operators_box.append(group);
        }

        private void unblock() {
            if (puk_row.text == "" || new_pin_row.text == "") {
                report(_("Enter the PUK and a new PIN"));
                return;
            }
            apply.begin(MobileCommand.SEND_PUK, new Variant("(ss)", puk_row.text, new_pin_row.text),
                _("SIM unblocked"), unblock_row);
            puk_row.text = "";
            new_pin_row.text = "";
        }

        private void change_pin() {
            if (current_pin_row.text == "" || next_pin_row.text == "") {
                report(_("Enter the current PIN and a new one"));
                return;
            }
            apply.begin(MobileCommand.CHANGE_PIN, new Variant("(ss)", current_pin_row.text, next_pin_row.text),
                _("SIM PIN changed"), change_pin_row);
            current_pin_row.text = "";
            next_pin_row.text = "";
        }

        private async void show_imei(ActionRow row) {
            var reply = yield apply(MobileCommand.GET_IMEI, null, _("IMEI shown"), row);
            if (reply != null) row.subtitle = reply.get_child_value(0).get_string();
        }

        public static string summary(MobileNetwork mobile) {
            if (!mobile.available) return _("Modem not responding");
            if (mobile.unlock_required == 2) return _("SIM PIN needed");
            if (mobile.unlock_required == 4) return _("SIM blocked");
            if (mobile.sim_missing) return _("No active SIM or eSIM");
            if (mobile.state == -1) return _("Could not connect");
            if (mobile.state == 1) return _("Starting");
            if (mobile.state == 3) return _("Off");
            if (mobile.registration == 3) return _("The network refused this SIM");
            if (mobile.registration != 1 && mobile.registration != 5) return _("Searching for a network");
            string name = mobile.operator_name != "" ? mobile.operator_name : _("Connected");
            return mobile.roaming ? _("%s, roaming").printf(name) : name;
        }

        private static string generation(uint technology) {
            if ((technology & (1 << 15)) != 0) return "5G";
            if ((technology & (1 << 14)) != 0) return "4G";
            if ((technology & 0x3e0) != 0) return "3G";
            return technology != 0 ? "2G" : "";
        }

        protected override void sync() {
            syncing = true;
            status_row.subtitle = summary(mobile);
            string network = generation(mobile.technology);
            signal_row.visible = network != "";
            signal_row.subtitle = "%s, %u%%".printf(network, mobile.signal_quality);
            calls_row.visible = mobile.has_voice;
            calls_row.subtitle = mobile.calls_ready ? _("Ready") : _("Not ready, emergency calls only");
            radio_row.active = mobile.available && mobile.state != 3;
            radio_row.sensitive = mobile.available;
            data_row.active = mobile.data_enabled;
            roaming_row.active = mobile.roaming_enabled;
            lte_row.active = mobile.lte_only;
            lte_row.visible = mobile.has_modes;
            data_row.sensitive = roaming_row.sensitive = apn_row.sensitive = mobile.has_settings;
            if (apn_row.get_focus_child() == null) apn_row.text = mobile.apn;
            bool can_change = mobile.unlock_required == 1 && !mobile.sim_missing;
            pin_group.visible = mobile.unlock_required == 2 || mobile.unlock_required == 4 || can_change;
            current_pin_row.visible = next_pin_row.visible = change_pin_row.visible = can_change;
            pin_row.visible = mobile.unlock_required == 2;
            puk_row.visible = new_pin_row.visible = unblock_row.visible = mobile.unlock_required == 4;
            syncing = false;
        }
    }

    public class EsimPage : MobileSubpage {
        public const string PAGE = "network-esim";

        private Box profiles_box;
        private Gee.List<MobileProfile> profiles = new Gee.ArrayList<MobileProfile>();
        private EntryRow code_row;
        private PasswordRow confirmation_row;

        public EsimPage(SettingsView view) {
            base(view, _("eSIM"), MobilePage.PAGE);

            profiles_box = new Box(Orientation.VERTICAL, 0);
            add_widget(profiles_box);

            var add = new PreferencesGroup(_("Add an eSIM"),
                _("Scan the carrier's QR code with Camera and paste it here, or type the activation code. Adding needs Wi-Fi."));
            code_row = new EntryRow(_("Activation Code"));
            code_row.placeholder_text = "LPA:1$";
            add.add_row(code_row);
            confirmation_row = new PasswordRow(_("Confirmation Code, if Requested"));
            add.add_row(confirmation_row);
            var paste_row = action_row(add, _("Paste Code"), null, "edit-paste-symbolic");
            paste_row.activated.connect(() => paste.begin());
            var install_row = action_row(add, _("Download eSIM"), _("Can take a few minutes"), "list-add-symbolic");
            install_row.activated.connect(() => install.begin(install_row));
            add_group(add);

            var chip = new PreferencesGroup(_("eSIM Chip"));
            var eid_row = action_row(chip, _("EID"), _("Tap to show"), "media-flash-symbolic");
            eid_row.activated.connect(() => show_eid.begin(eid_row));
            var notify_row = action_row(chip, _("Send Pending Notices"), _("Tells the carrier about added or deleted eSIMs"), "send-to-symbolic");
            notify_row.activated.connect(() => apply.begin(MobileCommand.SEND_NOTIFICATIONS, null, _("Notices sent"), notify_row));
            var reload_row = action_row(chip, _("Read the Chip Again"), null, "view-refresh-symbolic");
            reload_row.activated.connect(() => reload.begin());
            add_group(chip);

            reload.begin();
        }

        private async void paste() {
            try {
                string? text = yield get_clipboard().read_text_async(null);
                if (text != null) code_row.text = text.strip();
            } catch (Error e) {
                report(_("Nothing to paste"));
            }
        }

        private async void install(Widget row) {
            string code = code_row.text.strip();
            if (code == "") {
                report(_("Enter the activation code first"));
                return;
            }
            var reply = yield apply(MobileCommand.ADD_PROFILE, new Variant("(ss)", code, confirmation_row.text),
                _("eSIM added. Turn it on below."), row);
            if (reply == null) return;
            code_row.text = "";
            confirmation_row.text = "";
            yield reload();
        }

        private async void show_eid(ActionRow row) {
            var reply = yield apply(MobileCommand.GET_EID, null, _("EID shown"), row);
            if (reply != null) row.subtitle = reply.get_child_value(0).get_string();
        }

        private async void change(MobileCommand command, Variant args, string done, Widget row) {
            var reply = yield apply(command, args, done, row);
            if (reply != null && (command == MobileCommand.ENABLE_PROFILE || command == MobileCommand.DISABLE_PROFILE)) {
                mark_active(command == MobileCommand.ENABLE_PROFILE ? args.get_child_value(0).get_string() : "");
                return;
            }
            yield reload();
        }

        private void mark_active(string iccid) {
            var updated = new Gee.ArrayList<MobileProfile>();
            foreach (var p in profiles)
                updated.add(new MobileProfile(p.iccid, p.name, p.nickname, p.provider, p.iccid == iccid));
            profiles = updated;
            show_profiles();
        }

        private async void reload() {
            try {
                profiles = yield mobile.list_profiles();
            } catch (Error e) {
                report(_("The eSIMs could not be read"), ModemError.describe(e));
                return;
            }
            show_profiles();
        }

        private void show_profiles() {
            Widget? child;
            while ((child = profiles_box.get_first_child()) != null) profiles_box.remove(child);
            if (profiles.size == 0) {
                var empty = new PreferencesGroup(_("Installed"));
                empty.add_row(new ActionRow(_("No eSIM yet"), null, "media-flash-symbolic"));
                profiles_box.append(empty);
            }
            foreach (var profile in profiles) profiles_box.append(build_profile(profile));
        }

        private Widget build_profile(MobileProfile profile) {
            var group = new PreferencesGroup(profile.title);
            string iccid = profile.iccid;
            var use_row = new SwitchRow(_("Use This eSIM"), profile.name, profile.enabled);
            use_row.switch_btn.notify["active"].connect(() => change.begin(
                use_row.active ? MobileCommand.ENABLE_PROFILE : MobileCommand.DISABLE_PROFILE,
                new Variant("(s)", iccid), _("Saved. The modem is reloading."), use_row));
            group.add_row(use_row);
            var name_row = new EntryRow(_("Name"));
            name_row.text = profile.nickname;
            name_row.placeholder_text = profile.title;
            name_row.entry_activated.connect(() => change.begin(MobileCommand.RENAME_PROFILE,
                new Variant("(ss)", iccid, name_row.text.strip()), _("Renamed"), name_row));
            group.add_row(name_row);
            var delete_row = new ConfirmRow(_("Delete eSIM"),
                profile.enabled ? _("Turn it off first") : _("It cannot be undone and may need a new code from the carrier"),
                "user-trash-symbolic");
            delete_row.sensitive = !profile.enabled;
            delete_row.confirm_label = _("Delete");
            delete_row.confirmed.connect(() => change.begin(MobileCommand.DELETE_PROFILE,
                new Variant("(s)", iccid), _("eSIM deleted"), delete_row));
            group.add_row(delete_row);
            return group;
        }
    }

    public class ModemPage : MobileSubpage {
        public const string PAGE = "dev-modem";

        private ActionRow state_row;
        private ActionRow firmware_row;

        public ModemPage(SettingsView view) {
            base(view, _("Modem"), "developer");

            var status = new PreferencesGroup(_("Status"));
            state_row = new ActionRow(_("Service"), null, "network-cellular-symbolic");
            status.add_row(state_row);
            firmware_row = new ActionRow(_("Firmware"), null);
            status.add_row(firmware_row);
            add_group(status);

            var restart = new PreferencesGroup(_("Restart"));
            command_row(restart, _("Restart Modem"), _("Powers the modem off and on and clears the failed start lock"),
                MobileCommand.RESTART_MODEM, null, _("Modem restarted"));
            command_row(restart, _("Restart Modem Service"), _("Reads the SIM and registers again"),
                MobileCommand.RESTART_SERVICE, null, _("Service restarting"));
            command_row(restart, _("Radio Off"), null,
                MobileCommand.SET_RADIO, new Variant("(b)", false), _("Radio is off"));
            command_row(restart, _("Radio On"), null,
                MobileCommand.SET_RADIO, new Variant("(b)", true), _("Radio is on"));
            add_group(restart);

            var slots = new PreferencesGroup(_("SIM Line"));
            command_row(slots, _("Map the Line to the eSIM"), null,
                MobileCommand.SELECT_SLOT, new Variant("(u)", MobileNetwork.ESIM_SLOT), _("Line moved to the eSIM"));
            command_row(slots, _("Map the Line to the Card Tray"), null,
                MobileCommand.SELECT_SLOT, new Variant("(u)", MobileNetwork.SIM_SLOT), _("Line moved to the card tray"));
            command_row(slots, _("Send eSIM Notices"), null,
                MobileCommand.SEND_NOTIFICATIONS, null, _("Notices sent"));
            add_group(slots);

            var logs = new PreferencesGroup(_("Diagnostics"), _("Numbers, addresses and identifiers are hidden."));
            var copy_row = action_row(logs, _("Copy Logs"), null, "edit-copy-symbolic");
            copy_row.activated.connect(() => copy_logs.begin(copy_row));
            var save_row = action_row(logs, _("Save Logs to Documents"), null, "document-save-symbolic");
            save_row.activated.connect(() => save_logs.begin(save_row));
            add_group(logs);

            follow_modem();
        }

        private void command_row(PreferencesGroup group, string title, string? subtitle, MobileCommand command, Variant? args, string done) {
            var row = action_row(group, title, subtitle, "view-refresh-symbolic");
            row.activated.connect(() => apply.begin(command, args, done, row));
        }

        private async void copy_logs(Widget row) {
            var reply = yield apply(MobileCommand.DIAGNOSTICS, null, _("Logs copied"), row);
            if (reply != null) get_clipboard().set_text(reply.get_child_value(0).get_string());
        }

        private async void save_logs(Widget row) {
            var reply = yield apply(MobileCommand.DIAGNOSTICS, null, _("Logs ready"), row);
            if (reply == null) return;
            string dir = Environment.get_user_special_dir(UserDirectory.DOCUMENTS) ?? Environment.get_home_dir();
            string path = Path.build_filename(dir,
                "modem-%s.txt".printf(new DateTime.now_local().format("%Y%m%d-%H%M%S")));
            try {
                DirUtils.create_with_parents(dir, 0700);
                FileUtils.set_contents(path, reply.get_child_value(0).get_string());
                report(_("Logs saved"), path);
            } catch (Error e) {
                report(_("The logs could not be saved"), e.message);
            }
        }

        protected override void sync() {
            state_row.subtitle = MobilePage.summary(mobile);
            firmware_row.subtitle = mobile.revision;
            firmware_row.visible = mobile.revision != "";
        }
    }
}
