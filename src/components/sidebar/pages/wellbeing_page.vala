using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class WellbeingPage : SettingsPage {
        private ScreenTimeView screen_time;
        private StatusPage empty;
        private PreferencesGroup limits_group;
        private ActionRow limit_row;
        private ActionRow bedtime_row;
        private ActionRow apps_row;
        private GLib.Settings settings;
        private ulong tracker_handler = 0;

        public WellbeingPage(SettingsView view) {
            base(_("Wellbeing"));
            back_clicked.connect(() => view.go_home());
            settings = new GLib.Settings("dev.sinty.desktop");
            var tracker = ScreenTimeTracker.get_default();

            empty = new StatusPage();
            empty.icon_name = "singularity-screen-time";
            empty.title = _("No Screen Time Yet");
            empty.description = _("Time spent in each app is recorded on this computer and shown here.");
            empty.compact = true;
            add_widget(empty);

            screen_time = new ScreenTimeView(tracker.store);
            screen_time.app_limit = 4;
            add_widget(screen_time);

            limits_group = new PreferencesGroup(_("Your Limits"), _("Set by an administrator of this computer."));
            limit_row = new ActionRow(_("Daily Limit"), "", "preferences-system-time-symbolic");
            limits_group.add_row(limit_row);
            bedtime_row = new ActionRow(_("Bedtime"), "", "weather-clear-night-symbolic");
            limits_group.add_row(bedtime_row);
            apps_row = new ActionRow(_("Blocked Apps"), "", "action-unavailable-symbolic");
            limits_group.add_row(apps_row);
            add_group(limits_group);

            if (settings.settings_schema.has_key("break-reminder-enabled")) {
                var breaks = new PreferencesGroup(_("Breaks"));
                var remind = new SwitchRow(_("Remind Me to Take Breaks"),
                    _("A five-minute pause starts a new period of use"),
                    settings.get_boolean("break-reminder-enabled"));
                settings.bind("break-reminder-enabled", remind.switch_btn, "active", SettingsBindFlags.DEFAULT);
                breaks.add_row(remind);
                var minutes = new SpinRow(_("Remind After"), _("Minutes of continuous use"), 15, 180, 5,
                    settings.get_int("break-reminder-minutes"));
                settings.bind("break-reminder-enabled", minutes, "sensitive", SettingsBindFlags.GET);
                minutes.spin_btn.value_changed.connect(() => {
                    settings.set_int("break-reminder-minutes", (int) minutes.value);
                });
                settings.changed["break-reminder-minutes"].connect(() => {
                    minutes.value = settings.get_int("break-reminder-minutes");
                });
                breaks.add_row(minutes);
                add_group(breaks);
            }

            var record_group = new PreferencesGroup(_("Recording"));
            var record_row = new SwitchRow(_("Record Screen Time"), _("Only on this computer, never sent anywhere"),
                settings.get_boolean("screen-time-enabled"));
            settings.bind("screen-time-enabled", record_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            record_group.add_row(record_row);
            var clear_row = new ActionRow(_("Clear History"), _("Delete the recorded screen time of this account"), "user-trash-symbolic");
            clear_row.activatable = true;
            clear_row.activated.connect(() => {
                clear_row.confirmation_requested(_("Clear"), _("Cancel"), ConfirmationSuggestedAction.CANCEL);
            });
            clear_row.confirmed.connect(() => {
                tracker.clear_history();
                refresh();
            });
            record_group.add_row(clear_row);
            add_group(record_group);

            ParentalEnforcer.get_default().policy_changed.connect(update_limits);
            map.connect(() => {
                tracker.save();
                refresh();
                if (tracker_handler == 0) tracker_handler = tracker.changed.connect(refresh);
            });
            unmap.connect(() => {
                if (tracker_handler != 0) tracker.disconnect(tracker_handler);
                tracker_handler = 0;
            });
            refresh();
        }

        private void refresh() {
            int64 week = 0;
            foreach (int64 v in Parental.UsageReport.week_totals(ScreenTimeTracker.get_default().store, new DateTime.now_local())) week += v;
            empty.visible = week == 0;
            screen_time.visible = week > 0;
            if (week > 0) screen_time.refresh();
            update_limits();
        }

        private void update_limits() {
            var policy = ParentalEnforcer.get_default().policy;
            limits_group.visible = policy.is_active;
            limit_row.visible = policy.daily_limit_minutes > 0;
            if (policy.daily_limit_minutes > 0) {
                int64 left = policy.seconds_left(ScreenTimeTracker.get_default().today_seconds());
                limit_row.subtitle = _("%s a day, %s left today").printf(
                    Parental.UsageReport.format_duration((int64) policy.daily_limit_minutes * 60),
                    Parental.UsageReport.format_duration(left));
            }
            bedtime_row.visible = policy.bedtime_enabled;
            bedtime_row.subtitle = _("From %s to %s").printf(Parental.Policy.format_minutes(policy.bedtime_start),
                Parental.Policy.format_minutes(policy.bedtime_end));
            apps_row.visible = policy.blocked_apps.length > 0;
            apps_row.subtitle = ngettext("%d app", "%d apps", policy.blocked_apps.length).printf(policy.blocked_apps.length);
        }
    }
}
