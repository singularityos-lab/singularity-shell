using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class FocusModePage : SettingsPage {
        private SettingsView view;
        private FocusMode mode;
        private SwitchRow on_row;
        private PreferencesGroup people_group;
        private PreferencesGroup apps_group;
        private PreferencesGroup schedule_group;
        private bool _syncing = false;

        public FocusModePage(SettingsView view, FocusMode mode) {
            base(FocusManager.display_name(mode));
            this.view = view;
            this.mode = mode;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("notifications"));
            var focus = FocusManager.get_default();

            var status = new PreferencesGroup(_("Status"));
            on_row = new SwitchRow(_("Turn On Now"), _("Stays on until you turn it off"));
            on_row.switch_btn.notify["active"].connect(() => {
                if (_syncing) return;
                if (on_row.switch_btn.active) focus.activate(mode.id);
                else if (is_on()) focus.deactivate();
            });
            status.add_row(on_row);
            if (!mode.builtin) {
                var name_row = new EntryRow(_("Name"));
                name_row.text = mode.name;
                name_row.entry_changed.connect(() => {
                    string n = name_row.text.strip();
                    if (n == "" || n == mode.name) return;
                    mode.name = n;
                    focus.save_modes();
                });
                status.add_row(name_row);
            }
            add_group(status);

            people_group = new PreferencesGroup(_("Allowed People"),
                _("Notifications that name these contacts still come through."));
            add_group(people_group);
            apps_group = new PreferencesGroup(_("Allowed Apps"),
                _("These apps can always notify you in this mode."));
            add_group(apps_group);

            var exceptions = new PreferencesGroup(_("Exceptions"));
            var ts = new SwitchRow(_("Time-Sensitive Notifications"),
                _("Apps set to time-sensitive in Notifications come through"));
            ts.switch_btn.active = mode.allow_time_sensitive;
            ts.switch_btn.notify["active"].connect(() => {
                mode.allow_time_sensitive = ts.switch_btn.active;
                focus.save_modes();
            });
            exceptions.add_row(ts);
            add_group(exceptions);

            schedule_group = new PreferencesGroup(_("Schedules"),
                _("The mode turns on and off by itself at these times."));
            add_group(schedule_group);

            var triggers = new PreferencesGroup(_("Turn On Automatically"));
            var presenting = new SwitchRow(_("While Presenting or Sharing the Screen"),
                _("When an app shares your screen or starts a presentation"));
            presenting.switch_btn.active = mode.while_presenting;
            presenting.switch_btn.notify["active"].connect(() => {
                mode.while_presenting = presenting.switch_btn.active;
                focus.save_modes();
            });
            triggers.add_row(presenting);
            var fullscreen = new SwitchRow(_("While a Full-Screen App or Game Runs"),
                _("Videos, games and other apps that fill the screen"));
            fullscreen.switch_btn.active = mode.while_fullscreen;
            fullscreen.switch_btn.notify["active"].connect(() => {
                mode.while_fullscreen = fullscreen.switch_btn.active;
                focus.save_modes();
            });
            triggers.add_row(fullscreen);
            add_group(triggers);

            if (!mode.builtin) {
                var danger = new PreferencesGroup(_("Remove"));
                var remove = new ConfirmRow(_("Remove Focus Mode"), _("Its people, apps and schedules are removed too"),
                    "user-trash-symbolic");
                remove.confirm_label = _("Remove");
                remove.confirmed.connect(() => {
                    focus.remove_mode(mode.id);
                    view.navigate_to("notifications");
                });
                danger.add_row(remove);
                add_group(danger);
            }

            ulong h1 = focus.changed.connect(sync_state);
            ulong h2 = focus.modes_changed.connect(rebuild_lists);
            destroy.connect(() => {
                focus.disconnect(h1);
                focus.disconnect(h2);
            });
            sync_state();
            rebuild_lists();
        }

        private bool is_on() {
            var state = FocusManager.get_default().state;
            return state.active && state.mode.id == mode.id;
        }

        private void sync_state() {
            _syncing = true;
            on_row.switch_btn.active = is_on();
            var state = FocusManager.get_default().state;
            on_row.subtitle = is_on() && state.reason != FocusReason.MANUAL
                ? FocusManager.reason_label(state.reason)
                : _("Stays on until you turn it off");
            _syncing = false;
        }

        private Button remove_button(string tooltip) {
            var b = new Button.from_icon_name("list-remove-symbolic");
            b.add_css_class("flat");
            b.add_css_class("circular");
            b.valign = Align.CENTER;
            b.tooltip_text = tooltip;
            return b;
        }

        private ActionRow add_row(string title, string subtitle) {
            var row = new ActionRow(title, subtitle, "list-add-symbolic");
            row.activatable = true;
            row.add_suffix(NotificationSettingsPage.chevron());
            return row;
        }

        private void rebuild_lists() {
            var focus = FocusManager.get_default();
            people_group.clear();
            foreach (var person in mode.allowed_people) {
                string sub = person.handles.length > 0 ? string.joinv(", ", person.handles) : "";
                var row = new ActionRow(person.name, sub, "avatar-default-symbolic");
                var rm = remove_button(_("Remove"));
                var p = person;
                rm.clicked.connect(() => {
                    mode.allowed_people.remove(p);
                    focus.save_modes();
                });
                row.add_suffix(rm);
                people_group.add_row(row);
            }
            var add_person = add_row(_("Add People…"), _("Pick from your contacts"));
            add_person.activated.connect(() => view.open_subpage(new FocusPeoplePage(view, mode), "focus-people"));
            people_group.add_row(add_person);

            apps_group.clear();
            var store = AppNotificationSettings.get_default();
            foreach (string key in mode.allowed_apps) {
                var row = new ActionRow(store.display_name(key), "");
                var img = new Image();
                img.pixel_size = 24;
                img.margin_end = 8;
                var gicon = store.icon_for(key);
                if (gicon != null) img.gicon = gicon;
                else img.icon_name = "application-x-executable";
                row.add_prefix(img);
                var rm = remove_button(_("Remove"));
                string k = key;
                rm.clicked.connect(() => {
                    mode.allowed_apps.remove(k);
                    focus.save_modes();
                });
                row.add_suffix(rm);
                apps_group.add_row(row);
            }
            var add_app = add_row(_("Add Apps…"), _("Pick apps that may notify you"));
            add_app.activated.connect(() => view.open_subpage(new FocusAppsPage(view, mode), "focus-apps"));
            apps_group.add_row(add_app);

            schedule_group.clear();
            foreach (var schedule in mode.schedules) {
                var row = new ActionRow(schedule_title(schedule), days_label(schedule.days), "preferences-system-time-symbolic");
                row.activatable = true;
                var sw = new Switch();
                sw.valign = Align.CENTER;
                sw.active = schedule.enabled;
                sw.tooltip_text = _("Use this schedule");
                var s = schedule;
                sw.notify["active"].connect(() => {
                    s.enabled = sw.active;
                    focus.save_modes();
                });
                row.add_suffix(sw);
                row.add_suffix(NotificationSettingsPage.chevron());
                row.activated.connect(() => view.open_subpage(new FocusSchedulePage(view, mode, s), "focus-schedule"));
                schedule_group.add_row(row);
            }
            var add_schedule = add_row(_("Add Schedule…"), _("Pick days and hours"));
            add_schedule.activated.connect(() => {
                var s = new FocusSchedule(FocusSchedule.WEEKDAYS, 9 * 60, 17 * 60);
                view.open_subpage(new FocusSchedulePage(view, mode, s, true), "focus-schedule");
            });
            schedule_group.add_row(add_schedule);
        }

        public static string schedule_title(FocusSchedule s) {
            return _("From %s to %s").printf(FocusSchedule.format_minute(s.start_minute),
                FocusSchedule.format_minute(s.end_minute));
        }

        public static string days_label(int days) {
            if (days == FocusSchedule.ALL_DAYS) return _("Every day");
            if (days == FocusSchedule.WEEKDAYS) return _("Weekdays");
            if (days == 0x60) return _("Weekends");
            if (days == 0) return _("No days");
            string[] names = {};
            var monday = new DateTime.local(2024, 1, 1, 12, 0, 0);
            for (int i = 0; i < 7; i++) {
                if ((days & (1 << i)) != 0) names += monday.add_days(i).format("%a");
            }
            return string.joinv(", ", names);
        }
    }

    public class FocusSchedulePage : SettingsPage {
        public FocusSchedulePage(SettingsView view, FocusMode mode, FocusSchedule schedule, bool is_new = false) {
            base(is_new ? _("New Schedule") : _("Schedule"));
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new FocusModePage(view, mode), "focus-mode"));
            var focus = FocusManager.get_default();
            var working = new FocusSchedule(schedule.days, schedule.start_minute, schedule.end_minute, schedule.enabled);

            var time = new PreferencesGroup(_("Hours"),
                _("When the end comes before the start, the schedule runs past midnight."));
            var start_row = new ActionRow(_("Starts"), "");
            start_row.activatable = false;
            var start = new TimePicker(FocusSchedule.format_minute(working.start_minute));
            start.changed.connect(() => working.start_minute = FocusSchedule.parse_minute(start.time, working.start_minute));
            start_row.add_suffix(start);
            time.add_row(start_row);
            var end_row = new ActionRow(_("Ends"), "");
            end_row.activatable = false;
            var end = new TimePicker(FocusSchedule.format_minute(working.end_minute));
            end.changed.connect(() => working.end_minute = FocusSchedule.parse_minute(end.time, working.end_minute));
            end_row.add_suffix(end);
            time.add_row(end_row);
            add_group(time);

            var days_group = new PreferencesGroup(_("Days"));
            var days_box = new Box(Orientation.HORIZONTAL, 4);
            days_box.add_css_class("focus-days");
            days_box.halign = Align.CENTER;
            days_box.margin_top = 8;
            days_box.margin_bottom = 8;
            var monday = new DateTime.local(2024, 1, 1, 12, 0, 0);
            for (int i = 0; i < 7; i++) {
                int bit = 1 << i;
                string label = monday.add_days(i).format("%a");
                var toggle = new ToggleButton.with_label(label.get_char(0).toupper().to_string());
                toggle.tooltip_text = monday.add_days(i).format("%A");
                toggle.add_css_class("focus-day");
                toggle.set_size_request(36, 36);
                toggle.hexpand = false;
                toggle.active = (working.days & bit) != 0;
                toggle.toggled.connect(() => {
                    if (toggle.active) working.days |= bit;
                    else working.days &= ~bit;
                });
                days_box.append(toggle);
            }
            days_box.set_data<string>("settings-title", _("Days"));
            days_group.add_row(days_box);
            add_group(days_group);

            var buttons = new Box(Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 24;
            if (!is_new) {
                var remove = new Button.with_label(_("Remove"));
                remove.add_css_class("destructive-action");
                remove.add_css_class("pill");
                remove.clicked.connect(() => {
                    mode.schedules.remove(schedule);
                    focus.save_modes();
                    view.open_subpage(new FocusModePage(view, mode), "focus-mode");
                });
                buttons.append(remove);
            }
            var save = new Button.with_label(is_new ? _("Add") : _("Save"));
            save.add_css_class("suggested-action");
            save.add_css_class("pill");
            save.clicked.connect(() => {
                schedule.days = working.days;
                schedule.start_minute = working.start_minute;
                schedule.end_minute = working.end_minute;
                if (is_new) {
                    schedule.enabled = true;
                    mode.schedules.add(schedule);
                }
                focus.save_modes();
                view.open_subpage(new FocusModePage(view, mode), "focus-mode");
            });
            buttons.append(save);
            add_widget(buttons);
        }
    }

    public class FocusPeoplePage : SettingsPage {
        private FocusMode mode;
        private PreferencesGroup list;
        private Singularity.Widgets.SearchEntry search;
        private Gee.ArrayList<FocusPerson> people = new Gee.ArrayList<FocusPerson>();

        public FocusPeoplePage(SettingsView view, FocusMode mode) {
            base(_("Add People"));
            this.mode = mode;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new FocusModePage(view, mode), "focus-mode"));

            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search Contacts");
            search.margin_top = 12;
            search.search_changed.connect(fill);
            add_widget(search);

            list = new PreferencesGroup(_("Contacts"), _("From Contacts and your online accounts."));
            add_group(list);
            FocusContacts.load.begin((obj, res) => {
                people = FocusContacts.load.end(res);
                fill();
            });
        }

        private bool chosen(FocusPerson p) {
            foreach (var q in mode.allowed_people) {
                if (q.name == p.name) return true;
            }
            return false;
        }

        private void fill() {
            list.clear();
            string q = search.text.strip().down();
            int shown = 0;
            foreach (var p in people) {
                if (q != "" && !p.name.down().contains(q) && !string.joinv(" ", p.handles).down().contains(q)) continue;
                var row = new ActionRow(p.name, string.joinv(", ", p.handles), "avatar-default-symbolic");
                var check = new CheckButton();
                check.valign = Align.CENTER;
                check.active = chosen(p);
                var person = p;
                check.toggled.connect(() => {
                    if (check.active && !chosen(person)) {
                        mode.allowed_people.add(new FocusPerson(person.name, person.handles));
                    } else if (!check.active) {
                        foreach (var e in mode.allowed_people) {
                            if (e.name == person.name) {
                                mode.allowed_people.remove(e);
                                break;
                            }
                        }
                    }
                    FocusManager.get_default().save_modes();
                });
                row.add_suffix(check);
                row.activatable = true;
                row.activated.connect(() => check.active = !check.active);
                list.add_row(row);
                if (++shown >= 60) break;
            }
            if (shown == 0) {
                list.add_row(new ActionRow(people.size == 0 ? _("No Contacts") : _("No Matches"),
                    people.size == 0 ? _("Add people in the Contacts app or connect an account with contacts.")
                                     : _("Try another name or address."),
                    "avatar-default-symbolic"));
            }
        }
    }

    public class FocusAppsPage : SettingsPage {
        private FocusMode mode;
        private PreferencesGroup list;
        private Singularity.Widgets.SearchEntry search;

        public FocusAppsPage(SettingsView view, FocusMode mode) {
            base(_("Add Apps"));
            this.mode = mode;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new FocusModePage(view, mode), "focus-mode"));
            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search Apps");
            search.margin_top = 12;
            search.search_changed.connect(fill);
            add_widget(search);
            list = new PreferencesGroup(_("Apps"));
            add_group(list);
            fill();
        }

        private void fill() {
            list.clear();
            var store = AppNotificationSettings.get_default();
            var keys = new Gee.ArrayList<string>();
            foreach (string k in store.known_apps()) keys.add(k);
            foreach (var info in AppInfo.get_all()) {
                if (!info.should_show() || info.get_id() == null) continue;
                string k = NotificationRules.app_key_for("", info.get_id());
                if (!keys.contains(k)) keys.add(k);
            }
            keys.sort((a, b) => store.display_name(a).collate(store.display_name(b)));
            string q = search.text.strip().down();
            int shown = 0;
            foreach (string key in keys) {
                string name = store.display_name(key);
                if (q != "" && !name.down().contains(q)) continue;
                var row = new ActionRow(name, "");
                var img = new Image();
                img.pixel_size = 24;
                img.margin_end = 8;
                var gicon = store.icon_for(key);
                if (gicon != null) img.gicon = gicon;
                else img.icon_name = "application-x-executable";
                row.add_prefix(img);
                var check = new CheckButton();
                check.valign = Align.CENTER;
                check.active = mode.allows_app(key);
                string k = key;
                check.toggled.connect(() => {
                    if (check.active && !mode.allows_app(k)) mode.allowed_apps.add(k);
                    else if (!check.active) mode.allowed_apps.remove(k);
                    FocusManager.get_default().save_modes();
                });
                row.add_suffix(check);
                row.activatable = true;
                row.activated.connect(() => check.active = !check.active);
                list.add_row(row);
                if (++shown >= 80) break;
            }
        }
    }
}
