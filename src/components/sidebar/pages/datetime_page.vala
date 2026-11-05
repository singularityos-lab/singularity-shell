using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class DateTimePage : SettingsPage {
        private DateTimeManager manager;
        private GLib.Settings _desktop_settings;
        private SwitchRow ntp_row;
        private ActionRow date_time_row;
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
        private void show_time_picker(Widget anchor) {
            var pop = new Popover();
            pop.set_parent(anchor);
            var box = new Box(Orientation.VERTICAL, 8);
            box.margin_top = 12; box.margin_bottom = 12;
            box.margin_start = 12; box.margin_end = 12;
            var cal = new Gtk.Calendar();
            box.append(cal);
            var time_box = new Box(Orientation.HORIZONTAL, 6);
            time_box.halign = Align.CENTER;
            var now = new DateTime.now_local();
            var time_picker = new TimePicker();
            time_picker.hour = now.get_hour();
            time_picker.minute = now.get_minute();
            time_box.append(time_picker);
            box.append(time_box);
            var apply = new Button.with_label(_("Apply"));
            apply.add_css_class("suggested-action");
            apply.clicked.connect(() => {
                var date = cal.get_date();
                var dt = new DateTime.local(
                    date.get_year(), date.get_month(), date.get_day_of_month(),
                    time_picker.hour, time_picker.minute, 0);
                manager.set_time(dt.to_unix() * 1000000);
                pop.popdown();
            });
            box.append(apply);
            pop.set_child(box);
            pop.popup();
        }

        private void build_ui() {
            var group = new PreferencesGroup(_("Date & Time"));
            ntp_row = new SwitchRow(_("Automatic Date & Time"), _("Requires internet access"), manager.ntp_active);
            ntp_row.switch_btn.notify["active"].connect(() => {
                manager.set_ntp(ntp_row.active);
            });
            group.add_row(ntp_row);
            date_time_row = new ActionRow(_("Date & Time"));
            time_label = new Label("");
            time_label.add_css_class("dim-label");
            date_time_row.add_suffix(time_label);
            var set_time_btn = new Button.with_label(_("Set"));
            set_time_btn.add_css_class("flat");
            set_time_btn.valign = Align.CENTER;
            set_time_btn.clicked.connect(() => show_time_picker(set_time_btn));
            date_time_row.add_suffix(set_time_btn);
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
