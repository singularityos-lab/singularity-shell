using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class ScreenTimeBars : DrawingArea {
        private static bool css_installed = false;
        private int64[] values = new int64[7];
        private string[] names = new string[7];
        public int selected { get; private set; default = 6; }
        public signal void day_selected(int index);

        public ScreenTimeBars() {
            install_css();
            content_height = 96;
            Singularity.Style.StyleManager.get_default().notify["accent-hex"].connect(() => queue_draw());
            hexpand = true;
            has_tooltip = true;
            set_draw_func(draw);
            query_tooltip.connect(on_query_tooltip);
            var click = new GestureClick();
            click.released.connect((n, x, y) => {
                int i = index_at(x);
                if (i < 0) return;
                selected = i;
                queue_draw();
                day_selected(i);
            });
            add_controller(click);
        }

        private static void install_css() {
            if (css_installed) return;
            css_installed = true;
            var provider = new CssProvider();
            provider.load_from_string(".screen-time-hero { font-size: 2em; font-weight: 700; } .screen-time-meter trough, .screen-time-meter block { min-height: 6px; border-radius: 3px; } .screen-time-meter block.filled { background-color: @accent_bg_color; } .screen-time-meter block.empty { background-color: alpha(currentColor, 0.1); }");
            StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        public void set_week(int64[] week, string[] day_names, int selected_index) {
            values = week;
            names = day_names;
            selected = selected_index;
            queue_draw();
        }

        private int index_at(double x) {
            int width = get_width();
            if (width <= 0) return -1;
            int i = (int) (x / (width / 7.0));
            return i >= 0 && i < 7 ? i : -1;
        }

        private bool on_query_tooltip(int x, int y, bool keyboard, Tooltip tooltip) {
            int i = index_at(x);
            if (i < 0) return false;
            tooltip.set_text("%s: %s".printf(names[i], Parental.UsageReport.format_duration(values[i])));
            return true;
        }

        private static void rounded_top(Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min(r, double.min(w / 2, h));
            cr.move_to(x, y + h);
            cr.line_to(x, y + r);
            cr.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
            cr.arc(x + w - r, y + r, r, 1.5 * Math.PI, 2 * Math.PI);
            cr.line_to(x + w, y + h);
            cr.close_path();
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            var fg = get_color();
            var accent = Gdk.RGBA();
            if (!accent.parse(Singularity.Style.StyleManager.get_default().accent_hex)) accent = fg;
            int64 max = 3600;
            foreach (int64 v in values) max = int64.max(max, v);
            int64 hours = (max + 3599) / 3600;
            double top = 4;
            double plot = height - top - 1;
            cr.set_line_width(1);
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.10);
            for (int64 h = 1; h <= hours; h++) {
                if (hours > 6 && h % 2 == 1) continue;
                double y = Math.floor(top + plot - plot * (h * 3600.0 / (hours * 3600.0))) + 0.5;
                cr.move_to(0, y);
                cr.line_to(width, y);
            }
            cr.stroke();
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.28);
            cr.move_to(0, top + plot + 0.5);
            cr.line_to(width, top + plot + 0.5);
            cr.stroke();
            double dim = (fg.red + fg.green + fg.blue) / 3 > 0.5 ? 0.72 : 0.5;
            double slot = width / 7.0;
            double bar = double.min(28, slot - 10);
            for (int i = 0; i < 7; i++) {
                if (values[i] <= 0) continue;
                double h = double.max(2, plot * values[i] / (double) (hours * 3600));
                double x = slot * i + (slot - bar) / 2;
                cr.set_source_rgba(accent.red, accent.green, accent.blue, i == selected ? 1.0 : dim);
                rounded_top(cr, x, top + plot - h, bar, h, 4);
                cr.fill();
            }
        }
    }

    public class ScreenTimeView : Box {
        private Parental.UsageStore store;
        private ScreenTimeBars bars;
        private Label hero;
        private Label hero_caption;
        private PreferencesGroup period_group;
        private PreferencesGroup apps_group;
        private Box day_labels;
        private BubbleSwitcher period;
        private bool week_mode = false;
        private int selected_day = 6;
        private DateTime last_day;
        private Gee.ArrayList<Widget> app_rows = new Gee.ArrayList<Widget>();
        public int app_limit { get; set; default = 5; }

        public ScreenTimeView(Parental.UsageStore store) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.store = store;
            last_day = new DateTime.now_local();

            period = new BubbleSwitcher();
            period.add_option("day", _("Day"));
            period.add_option("week", _("Week"));
            period.set_active("day");
            period.halign = Align.CENTER;
            period.margin_top = 8;
            period.selected.connect((name) => {
                week_mode = name == "week";
                refresh();
            });
            append(period);

            period_group = new PreferencesGroup(_("Today"));
            var hero_row = new PreferencesRow();
            hero_row.activatable = false;
            var hero_box = new Box(Orientation.VERTICAL, 2);
            hero_box.margin_top = 0;
            hero_box.margin_bottom = 0;
            hero_box.margin_start = 16;
            hero_box.margin_end = 16;
            hero = new Label("");
            hero.add_css_class("screen-time-hero");
            hero.halign = Align.START;
            hero_box.append(hero);
            hero_caption = new Label("");
            hero_caption.add_css_class("dim-label");
            hero_caption.wrap = true;
            hero_caption.xalign = 0;
            hero_box.append(hero_caption);
            bars = new ScreenTimeBars();
            bars.margin_top = 8;
            bars.day_selected.connect((i) => {
                selected_day = i;
                if (week_mode) period.set_active("day");
                week_mode = false;
                refresh();
            });
            hero_box.append(bars);
            day_labels = new Box(Orientation.HORIZONTAL, 0);
            day_labels.homogeneous = true;
            day_labels.margin_bottom = 8;
            for (int i = 0; i < 7; i++) {
                var l = new Label("");
                l.add_css_class("caption");
                l.add_css_class("dim-label");
                day_labels.append(l);
            }
            hero_box.append(day_labels);
            hero_row.set_child(hero_box);
            period_group.add_row(hero_row);
            append(period_group);

            apps_group = new PreferencesGroup(_("Most Used"));
            append(apps_group);
            refresh();
        }

        public void set_store(Parental.UsageStore store) {
            this.store = store;
            refresh();
        }

        private DateTime day_at(int index) {
            return last_day.add_days(index - 6);
        }

        public void refresh() {
            last_day = new DateTime.now_local();
            int64[] week = Parental.UsageReport.week_totals(store, last_day);
            string[] names = new string[7];
            int i = 0;
            for (Widget? child = day_labels.get_first_child(); child != null; child = child.get_next_sibling()) {
                var day = day_at(i);
                names[i] = i == 6 ? _("Today") : day.format("%A");
                ((Label) child).label = day.format("%a");
                if (i == (week_mode ? 6 : selected_day)) ((Label) child).remove_css_class("dim-label");
                else ((Label) child).add_css_class("dim-label");
                i++;
            }
            bars.set_week(week, names, week_mode ? -1 : selected_day);

            Gee.List<Parental.AppUsage> apps;
            if (week_mode) {
                int64 sum = 0;
                int active_days = 0;
                foreach (int64 v in week) {
                    sum += v;
                    if (v > 0) active_days++;
                }
                period_group.title = _("Last 7 Days");
                hero.label = Parental.UsageReport.format_duration(sum);
                hero_caption.label = _("Daily average %s").printf(
                    Parental.UsageReport.format_duration(active_days > 0 ? sum / 7 : 0));
                apps = Parental.UsageReport.week_apps(store, last_day);
            } else {
                var day = day_at(selected_day);
                period_group.title = selected_day == 6 ? _("Today")
                    : (selected_day == 5 ? _("Yesterday") : day.format("%A"));
                apps = store.day(Parental.UsageReport.day_key(day));
                hero.label = Parental.UsageReport.format_duration(week[selected_day]);
                int64 avg = 0;
                foreach (int64 v in week) avg += v;
                avg /= 7;
                hero_caption.label = week[selected_day] >= avg
                    ? _("%s above the daily average").printf(Parental.UsageReport.format_duration(week[selected_day] - avg))
                    : _("%s below the daily average").printf(Parental.UsageReport.format_duration(avg - week[selected_day]));
            }
            fill_apps(apps);
        }

        private void fill_apps(Gee.List<Parental.AppUsage> apps) {
            foreach (var row in app_rows) apps_group.remove_row(row);
            app_rows.clear();
            var folded = Parental.UsageReport.fold(apps, app_limit);
            int64 max = 1;
            foreach (var app in folded) max = int64.max(max, app.seconds);
            if (folded.size == 0) {
                var empty = new ActionRow(_("No App Use Recorded"), _("Time spent in apps appears here."), "preferences-system-time-symbolic");
                apps_group.add_row(empty);
                app_rows.add(empty);
                return;
            }
            foreach (var app in folded) {
                var row = build_app_row(app, max);
                apps_group.add_row(row);
                app_rows.add(row);
            }
        }

        private Widget build_app_row(Parental.AppUsage usage, int64 max) {
            string name;
            GLib.Icon? icon = null;
            if (usage.app_id == "other") {
                name = _("Other Apps");
                icon = new ThemedIcon("view-app-grid-symbolic");
            } else {
                var info = AppSystem.get_default().resolve_app_for_id(usage.app_id);
                if (info == null) {
                    var dai = new DesktopAppInfo(usage.app_id + ".desktop");
                    info = dai;
                }
                name = info != null ? info.get_display_name() : usage.app_id;
                if (info != null) icon = info.get_icon();
            }
            var row = new PreferencesRow();
            row.activatable = false;
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 12;
            box.margin_end = 12;
            var image = icon != null ? new Image.from_gicon(icon) : new Image.from_icon_name("application-x-executable");
            image.pixel_size = 32;
            image.valign = Align.CENTER;
            box.append(image);
            var col = new Box(Orientation.VERTICAL, 4);
            col.hexpand = true;
            col.valign = Align.CENTER;
            var top = new Box(Orientation.HORIZONTAL, 8);
            var title = new Label(name);
            title.halign = Align.START;
            title.hexpand = true;
            title.ellipsize = Pango.EllipsizeMode.END;
            top.append(title);
            var dur = new Label(Parental.UsageReport.format_duration(usage.seconds));
            dur.add_css_class("dim-label");
            dur.add_css_class("numeric");
            top.append(dur);
            col.append(top);
            var meter = new LevelBar.for_interval(0, 1);
            meter.value = (double) usage.seconds / max;
            meter.remove_offset_value(Gtk.LEVEL_BAR_OFFSET_LOW);
            meter.remove_offset_value(Gtk.LEVEL_BAR_OFFSET_HIGH);
            meter.remove_offset_value(Gtk.LEVEL_BAR_OFFSET_FULL);
            meter.add_css_class("screen-time-meter");
            meter.hexpand = true;
            col.append(meter);
            box.append(col);
            row.set_child(box);
            row.set_tooltip_text("%s: %s".printf(name, Parental.UsageReport.format_duration(usage.seconds)));
            return row;
        }
    }

    public class ScreenTimePage : SettingsPage {
        private ScreenTimeView view_widget;

        public ScreenTimePage(SettingsView view, string title, Parental.UsageStore store, string back_to) {
            base(title);
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to(back_to));
            if (!store.readable) {
                var status = new StatusPage();
                status.icon_name = "singularity-screen-time";
                status.title = _("Screen Time Not Available");
                status.description = _("The screen time of this account is kept in its own folder, which this account cannot read.");
                add_widget(status);
                return;
            }
            view_widget = new ScreenTimeView(store);
            view_widget.app_limit = 6;
            add_widget(view_widget);
        }
    }
}
