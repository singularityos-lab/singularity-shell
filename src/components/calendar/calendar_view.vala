using Gtk;
using GLib;
using Gee;
using Singularity.Calendar;

namespace Singularity.Shell {

    public class CalendarView : Box {
        private DateTime current_date;
        private Label month_label;
        private Grid calendar_grid;
        private CalendarManager manager;
        private Singularity.Widgets.PreferencesGroup events_group;
        private DateTime? selected_date = null;
        private Gee.List<CalendarEvent?>? current_events = null;

        public CalendarView() {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            add_css_class("singularity-calendar");
            manager = CalendarManager.get_default();
            manager.events_changed.connect(() => {
                refresh_view();
            });
            current_date = new DateTime.now_local();
            build_header();
            calendar_grid = new Grid();
            calendar_grid.column_spacing = 4;
            calendar_grid.row_spacing = 4;
            calendar_grid.halign = Align.CENTER;
            append(calendar_grid);
            events_group = new Singularity.Widgets.PreferencesGroup(_("Events"));
            events_group.margin_top = 16;
            append(events_group);
            refresh_view();
        }

        private void build_header() {
            var header = new Box(Orientation.HORIZONTAL, 12);
            header.halign = Align.CENTER;
            header.margin_bottom = 8;
            var prev_btn = new Button.from_icon_name("go-previous-symbolic");
            prev_btn.add_css_class("flat");
            prev_btn.add_css_class("circular");
            prev_btn.clicked.connect(() => {
                current_date = current_date.add_months(-1);
                refresh_view();
            });
            month_label = new Label("");
            month_label.add_css_class("title-4");
            month_label.width_chars = 15;
            month_label.justify = Justification.CENTER;
            var next_btn = new Button.from_icon_name("go-next-symbolic");
            next_btn.add_css_class("flat");
            next_btn.add_css_class("circular");
            next_btn.clicked.connect(() => {
                current_date = current_date.add_months(1);
                refresh_view();
            });
            header.append(prev_btn);
            header.append(month_label);
            header.append(next_btn);
            append(header);
        }

        private void refresh_view() {
            month_label.label = current_date.format(_("%B %Y"));
            Widget? child = calendar_grid.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                calendar_grid.remove(child);
                child = next;
            }
            string[] days = {"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"};
            for (int i = 0; i < 7; i++) {
                var lbl = new Label(days[i]);
                lbl.add_css_class("dim-label");
                calendar_grid.attach(lbl, i, 0, 1, 1);
            }
            var first_day_of_month = new DateTime.local(current_date.get_year(), current_date.get_month(), 1, 0, 0, 0);
            int start_weekday = first_day_of_month.get_day_of_week() % 7;
            int days_in_month = get_days_in_month(current_date.get_year(), current_date.get_month());
            var end_of_month = first_day_of_month.add_days(days_in_month);
            fetch_and_draw.begin(first_day_of_month, end_of_month, start_weekday, days_in_month);
        }

        private async void fetch_and_draw(DateTime start, DateTime end, int start_offset, int days_count) {
             var events = yield manager.get_events(start, end);
             current_events = events;
             int row = 1;
             int col = start_offset;
             var today = new DateTime.now_local();
             bool is_current_month = (today.get_year() == current_date.get_year() && today.get_month() == current_date.get_month());
             for (int day = 1; day <= days_count; day++) {
                 var btn = new Button();
                 btn.add_css_class("calendar-day-btn");
                 btn.add_css_class("flat");
                 if (is_current_month && day == today.get_day_of_month()) {
                     btn.add_css_class("today");
                 }
                 bool has_event = false;
                 int month = current_date.get_month();
                 int year = current_date.get_year();
                 foreach (var evt in events) {
                     if (evt.start_time.get_year() == year &&
                         evt.start_time.get_month() == month &&
                         evt.start_time.get_day_of_month() == day) {
                         has_event = true;
                         break;
                     }
                 }
                 var overlay = new Overlay();
                 var lbl = new Label(day.to_string());
                 overlay.set_child(lbl);
                 if (has_event) {
                     var dot = new Box(Orientation.HORIZONTAL, 0);
                     dot.set_size_request(4, 4);
                     dot.add_css_class("event-dot");
                     dot.halign = Align.CENTER;
                     dot.valign = Align.END;
                     dot.margin_bottom = 1;
                     overlay.add_overlay(dot);
                 }
                 btn.set_child(overlay);
                  int clicked_day = day;
                  btn.clicked.connect(() => {
                      select_day(clicked_day);
                  });
                  calendar_grid.attach(btn, col, row, 1, 1);
                 col++;
                 if (col > 6) {
                     col = 0;
                     row++;
                 }
             }
             if (selected_date == null && is_current_month) selected_date = Singularity.Widgets.CalendarLayout.day_start(today);
             update_events_display();
        }

        private int get_days_in_month(int year, int month) {
            if (month == 12) return 31;
            var next_month = new DateTime.local(month == 12 ? year + 1 : year, month == 12 ? 1 : month + 1, 1, 0, 0, 0);
            var this_month = new DateTime.local(year, month, 1, 0, 0, 0);
            return (int) (next_month.difference(this_month) / 86400000000L);
        }

        private void select_day(int day) {
            selected_date = new DateTime.local(current_date.get_year(), current_date.get_month(), day, 0, 0, 0);
            update_events_display();
        }

        private void update_events_display() {
            events_group.clear();
            if (selected_date == null || current_events == null) {
                events_group.title = _("Events");
                return;
            }
            events_group.title = _("Events - %s").printf(selected_date.format(_("%B %d, %Y")));
            var day_events = new Gee.ArrayList<CalendarEvent?>();
            foreach (var evt in current_events) {
                if (evt.start_time.get_year() == selected_date.get_year() &&
                    evt.start_time.get_month() == selected_date.get_month() &&
                    evt.start_time.get_day_of_month() == selected_date.get_day_of_month()) {
                    day_events.add(evt);
                }
            }
            if (day_events.size == 0) {
                var no_events_row = new Singularity.Widgets.PreferencesRow();
                no_events_row.activatable = false;
                var empty = new Singularity.Widgets.StatusPage();
                empty.compact = true;
                empty.icon_name = "x-office-calendar-symbolic";
                empty.title = _("No Events");
                empty.description = _("Nothing is planned for this day.");
                var calendar_app = new GLib.DesktopAppInfo("dev.sinty.calendar.desktop");
                if (calendar_app != null) {
                    var open = new Button.with_label(_("Open Calendar"));
                    open.add_css_class("pill");
                    open.clicked.connect(() => {
                        try {
                            calendar_app.launch(null, Gdk.Display.get_default().get_app_launch_context());
                        } catch (Error e) {
                            warning("calendar: %s", e.message);
                        }
                    });
                    empty.child = open;
                }
                no_events_row.set_child(empty);
                events_group.add_row(no_events_row);
            } else {
                foreach (var evt in day_events) {
                    string time_str = evt.all_day ? "All day" : evt.start_time.format("%H:%M");
                    var row = new Singularity.Widgets.PreferencesRow();
                    var hbox = new Box(Orientation.HORIZONTAL, 8);
                    hbox.margin_top = 8;
                    hbox.margin_bottom = 8;
                    hbox.margin_start = 12;
                    hbox.margin_end = 12;

                    var color_box = new Box(Orientation.HORIZONTAL, 0);
                    color_box.set_size_request(4, 24);
                    try {
                        var provider = new CssProvider();
                        provider.load_from_string(".event-color-indicator { background-color: %s; border-radius: 2px; }".printf(evt.color));
                        color_box.add_css_class("event-color-indicator");
                        color_box.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
                    } catch {}
                    hbox.append(color_box);

                    var text_box = new Box(Orientation.VERTICAL, 2);
                    text_box.hexpand = true;
                    var title_lbl = new Label(evt.title);
                    title_lbl.halign = Align.START;
                    title_lbl.add_css_class("title");
                    var time_lbl = new Label(time_str);
                    time_lbl.halign = Align.START;
                    time_lbl.add_css_class("dim-label");
                    time_lbl.add_css_class("caption");
                    text_box.append(title_lbl);
                    text_box.append(time_lbl);
                    hbox.append(text_box);

                    var edit_btn = new Button.from_icon_name("edit-symbolic");
                    edit_btn.add_css_class("flat");
                    edit_btn.tooltip_text = _("Edit event");
                    var captured_evt = evt;
                    edit_btn.clicked.connect(() => {
                        if (needs_calendar_app(captured_evt)) open_calendar_app();
                        else show_event_dialog(captured_evt);
                    });
                    edit_btn.sensitive = writable_for(captured_evt) != null;
                    hbox.append(edit_btn);

                    var del_btn = new Button.from_icon_name("user-trash-symbolic");
                    del_btn.add_css_class("flat");
                    del_btn.tooltip_text = _("Delete event");
                    del_btn.clicked.connect(() => delete_event(captured_evt));
                    del_btn.sensitive = writable_for(captured_evt) != null;
                    hbox.append(del_btn);

                    row.set_child(hbox);
                    events_group.add_row(row);
                }
            }

            // "Add Event" button at the bottom
            var add_row = new Singularity.Widgets.PreferencesRow();
            var add_btn = new Button.with_label(_("Add Event"));
            add_btn.add_css_class("flat");
            add_btn.margin_top = 8;
            add_btn.margin_bottom = 8;
            add_btn.margin_start = 12;
            add_btn.margin_end = 12;
            add_btn.clicked.connect(() => show_event_dialog(null));
            add_row.set_child(add_btn);
            events_group.add_row(add_row);
        }

        private WritableCalendarProvider? writable_for(CalendarEvent evt) {
            string id = evt.calendar_id != null && evt.calendar_id != "" ? evt.calendar_id : "local-provider";
            return manager.get_provider(id) as WritableCalendarProvider;
        }

        private bool needs_calendar_app(CalendarEvent evt) {
            return evt.is_recurring() || (evt.attendees != null && evt.attendees.size > 0);
        }

        private void open_calendar_app() {
            var info = new GLib.DesktopAppInfo("dev.sinty.calendar.desktop");
            if (info == null) return;
            try {
                info.launch(null, null);
            } catch (Error e) {
                warning("Failed to open Calendar: %s", e.message);
            }
        }

        private void delete_event(CalendarEvent evt) {
            var provider = writable_for(evt);
            if (provider == null) return;
            var master = provider.find_event(evt.id);
            if (master == null) return;
            if (master.is_recurring() && evt.occurrence_start != null) {
                CalendarEvent updated = master;
                updated.exdates = Ics.with_string(master.exdates, evt.occurrence_start.format_iso8601());
                provider.update_event(updated);
            } else {
                provider.delete_event(evt.id);
            }
        }

        private string default_calendar_id() {
            var source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup("dev.sinty.calendar", true) != null) {
                string id = new GLib.Settings("dev.sinty.calendar").get_string("default-calendar");
                if (manager.get_provider(id) is WritableCalendarProvider) return id;
            }
            return "local-provider";
        }

        private void show_event_dialog(CalendarEvent? existing) {
            var app = (Gtk.Application?) GLib.Application.get_default();
            if (app == null) return;
            var dialog = new Singularity.Shell.ShellDialog(app);
            dialog.set_default_size(360, -1);

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var title_entry = new Entry();
            title_entry.placeholder_text = _("Event title");
            title_entry.text = existing != null ? existing.title : "";
            box.append(title_entry);

            var desc_entry = new Entry();
            desc_entry.placeholder_text = _("Description (optional)");
            desc_entry.text = existing != null ? existing.description : "";
            box.append(desc_entry);

            var all_day_box = new Box(Orientation.HORIZONTAL, 12);
            var all_day_lbl = new Label(_("All Day"));
            all_day_lbl.hexpand = true;
            all_day_lbl.halign = Align.START;
            var all_day_sw = new Switch();
            all_day_sw.active = existing != null ? existing.all_day : false;
            all_day_box.append(all_day_lbl);
            all_day_box.append(all_day_sw);
            box.append(all_day_box);

            // Time row (hidden when all-day)
            var time_box = new Box(Orientation.HORIZONTAL, 8);
            var start_spin = build_time_spin(existing != null ? existing.start_time.get_hour() : 9,
                                             existing != null ? existing.start_time.get_minute() : 0);
            var end_spin = build_time_spin(existing != null ? existing.end_time.get_hour() : 10,
                                           existing != null ? existing.end_time.get_minute() : 0);
            time_box.append(new Label(_("From")));
            time_box.append(start_spin);
            time_box.append(new Label(_("To")));
            time_box.append(end_spin);
            time_box.visible = !all_day_sw.active;
            all_day_sw.notify["active"].connect(() => {
                time_box.visible = !all_day_sw.active;
            });
            box.append(time_box);

            var btn_box = new Box(Orientation.HORIZONTAL, 8);
            btn_box.halign = Align.END;
            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.clicked.connect(() => dialog.close_dialog());
            var save_btn = new Button.with_label(existing != null ? _("Update") : _("Add"));
            save_btn.add_css_class("suggested-action");
            save_btn.clicked.connect(() => {
                if (title_entry.text.strip().length == 0) return;
                CalendarEvent evt;
                if (existing != null) {
                    var provider = writable_for(existing);
                    var stored = provider != null ? provider.find_event(existing.id) : null;
                    evt = stored ?? existing;
                } else {
                    evt = CalendarEvent();
                    evt.id = GLib.Uuid.string_random();
                    evt.color = "";
                    evt.location = "";
                    evt.recurrence = "";
                    evt.organizer = "";
                    evt.organizer_name = "";
                    evt.exdates = {};
                    evt.alarms = {};
                    evt.attendees = new Gee.ArrayList<CalendarAttendee>();
                    evt.calendar_id = default_calendar_id();
                }
                evt.title = title_entry.text.strip();
                evt.description = desc_entry.text.strip();
                evt.all_day = all_day_sw.active;

                int start_h = (int) start_spin.get_value();
                int start_m = existing != null ? existing.start_time.get_minute() : 0;
                int end_h = (int) end_spin.get_value();
                int end_m = existing != null ? existing.end_time.get_minute() : 0;

                DateTime base_date = existing != null ? existing.start_time : (selected_date ?? new DateTime.now_local());
                if (evt.all_day) {
                    evt.start_time = new DateTime.local(base_date.get_year(), base_date.get_month(), base_date.get_day_of_month(), 0, 0, 0);
                    evt.end_time = evt.start_time.add_hours(24);
                } else {
                    evt.start_time = new DateTime.local(base_date.get_year(), base_date.get_month(), base_date.get_day_of_month(), start_h, start_m, 0);
                    evt.end_time = new DateTime.local(base_date.get_year(), base_date.get_month(), base_date.get_day_of_month(), end_h, end_m, 0);
                    if (evt.end_time.compare(evt.start_time) <= 0)
                        evt.end_time = evt.start_time.add_hours(1);
                }

                var target = writable_for(evt);
                if (target != null) {
                    if (existing != null) target.update_event(evt);
                    else target.add_event(evt);
                }
                dialog.close_dialog();
            });
            btn_box.append(cancel_btn);
            btn_box.append(save_btn);
            box.append(btn_box);

            dialog.content_box.append(box);
            dialog.present();
            title_entry.grab_focus();
        }

        private SpinButton build_time_spin(int hour, int minute) {
            var adj = new Adjustment((double)hour, 0, 23, 1, 1, 0);
            var spin = new SpinButton(adj, 1, 0);
            spin.width_chars = 3;
            return spin;
        }

    }
}
