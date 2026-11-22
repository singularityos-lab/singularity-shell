using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class DateTimePage : SettingsPage {
        private DateTimeManager manager;
        private GLib.Settings _desktop_settings;
        private SwitchRow ntp_row;
        private ExpanderRow date_time_row;
        private TimePicker time_picker;
        private Button apply_btn;
        private DateTime picked_date = new DateTime.now_local();
        private SelectionRow timezone_row;
        private SwitchRow format_row;
        private Label time_label;
        private uint _time_timer_id = 0;

        public DateTimePage(SettingsView view) {
            base(_("Date & Time"));
            back_clicked.connect(() => {
                view.go_home();
            });
            manager = SystemMonitor.get_default().datetime;
            _desktop_settings = new GLib.Settings("dev.sinty.desktop");
            manager.state_changed.connect(update_ui);
            build_ui();
            update_ui();
            update_time_label();
            _start_time_timer();
        }

        private void _start_time_timer() {
            var now = new DateTime.now_local();
            uint secs_to_next = (uint)(60 - now.get_second());
            _time_timer_id = Timeout.add_seconds(secs_to_next, () => {
                update_time_label();
                _time_timer_id = Timeout.add_seconds(60, () => {
                    update_time_label();
                    return true;
                });
                return Source.REMOVE;
            });
        }

        protected override void dispose() {
            if (_time_timer_id != 0) {
                Source.remove(_time_timer_id);
                _time_timer_id = 0;
            }
            base.dispose();
        }

        // Manual date/time picker: only meaningful when NTP is off. Applies the
        // chosen local date and time through timedate1 (DateTimeManager.set_time).
        private ExpanderRow build_date_time_row() {
            var row = new ExpanderRow(_("Date & Time"));
            time_label = new Label("");
            time_label.add_css_class("dim-label");
            row.prepend_suffix(time_label);

            var calendar = new CalendarNavPicker();
            calendar.halign = Align.CENTER;
            calendar.margin_top = 8;
            row.add_row(calendar);

            time_picker = new TimePicker();
            var time_row = new ActionRow(_("Time"));
            time_row.add_suffix(time_picker);
            row.add_row(time_row);

            apply_btn = new Button.with_label(_("Apply"));
            apply_btn.add_css_class("suggested-action");
            apply_btn.halign = Align.END;
            apply_btn.margin_top = 8;
            apply_btn.margin_end = 12;
            apply_btn.margin_bottom = 12;
            apply_btn.clicked.connect(() => {
                var dt = new DateTime.local(
                    picked_date.get_year(), picked_date.get_month(), picked_date.get_day_of_month(),
                    time_picker.hour, time_picker.minute, 0);
                manager.set_time(dt.to_unix() * 1000000);
                row.expanded = false;
            });
            row.add_row(apply_btn);

            calendar.date_selected.connect((date) => pick_date(date));
            calendar.today_clicked.connect(() => pick_date(new DateTime.now_local()));
            time_picker.changed.connect(() => apply_btn.sensitive = true);
            calendar.map.connect(() => {
                var now = new DateTime.now_local();
                picked_date = now;
                calendar.set_date(now);
                time_picker.hour = now.get_hour();
                time_picker.minute = now.get_minute();
                apply_btn.sensitive = false;
            });
            return row;
        }

        private void pick_date(DateTime date) {
            picked_date = date;
            apply_btn.sensitive = true;
        }

        private void build_ui() {
            var group = new PreferencesGroup();
            ntp_row = new SwitchRow(_("Automatic Date & Time"), _("Requires internet access"), manager.ntp_active);
            ntp_row.switch_btn.notify["active"].connect(() => {
                manager.set_ntp(ntp_row.active);
            });
            group.add_row(ntp_row);
            date_time_row = build_date_time_row();
            group.add_row(date_time_row);
            string[] timezones = TimezoneUtil.list();
            timezone_row = new SelectionRow(_("Time Zone"), timezones, manager.timezone);
            timezone_row.selected.connect((tz) => {
                manager.update_timezone(tz);
            });
            group.add_row(timezone_row);
            bool use_12h = _desktop_settings.get_boolean("clock-use-12h");
            format_row = new SwitchRow(_("24-hour Time"), null, !use_12h);
            format_row.switch_btn.notify["active"].connect(() => {
                _desktop_settings.set_boolean("clock-use-12h", !format_row.active);
            });
            group.add_row(format_row);
            add_group(group);
        }

        private void update_ui() {
            ntp_row.active = manager.ntp_active;
            date_time_row.sensitive = !manager.ntp_active;
            if (manager.ntp_active) date_time_row.expanded = false;
            timezone_row.current_value = manager.timezone;
            update_time_label();
        }

        private void update_time_label() {
            var now = new DateTime.now_local();
            bool use_12h = _desktop_settings.get_boolean("clock-use-12h");
            time_label.label = now.format(use_12h ? _("%a %b %d, %I:%M %p") : _("%a %b %d, %H:%M"));
        }
    }
}
