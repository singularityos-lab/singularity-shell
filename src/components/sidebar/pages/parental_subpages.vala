using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public delegate void ParentalUpdate();

    public class ParentalAppsPage : ParentalSubpage {
        private Gtk.SearchEntry search;
        private PreferencesGroup group;
        private Gee.ArrayList<ActionRow> rows = new Gee.ArrayList<ActionRow>();

        public ParentalAppsPage(SettingsView view, string back_name, ParentalSession session) {
            base(view, _("Apps"), back_name, session);
            search = new Gtk.SearchEntry();
            search.placeholder_text = _("Search apps");
            search.margin_top = 12;
            search.margin_start = 12;
            search.margin_end = 12;
            search.search_changed.connect(filter);
            add_widget(search);

            group = new PreferencesGroup(_("Allowed Apps"),
                _("Blocked apps are hidden from %s and cannot be started from the desktop.").printf(session.display_name));
            add_group(group);

            var apps = new Gee.ArrayList<AppInfo>();
            foreach (var app in AppSystem.get_default().get_all_apps()) {
                if (app.should_show() && app.get_id() != null) apps.add(app);
            }
            apps.sort((a, b) => a.get_display_name().collate(b.get_display_name()));
            foreach (var app in apps) {
                string id = app.get_id();
                var row = new SwitchRow(app.get_display_name(), null, !session.policy.blocks_app(id));
                var gicon = app.get_icon();
                if (gicon != null) {
                    var image = new Image.from_gicon(gicon);
                    image.pixel_size = 32;
                    image.margin_end = 4;
                    row.add_prefix(image);
                }
                row.switch_btn.notify["active"].connect(() => {
                    bool blocked = !row.switch_btn.active;
                    if (session.policy.blocks_app(id) == blocked) return;
                    session.policy.set_app_blocked(id, blocked);
                    session.queue_save();
                });
                row.set_data<string>("search-text", (app.get_display_name() + " " + id).down());
                group.add_row(row);
                rows.add(row);
            }
        }

        private void filter() {
            string q = search.text.strip().down();
            foreach (var row in rows) row.visible = q == "" || row.get_data<string>("search-text").contains(q);
        }
    }

    public class ParentalTimePage : ParentalSubpage {
        public ParentalTimePage(SettingsView view, string back_name, ParentalSession session) {
            base(view, _("Time Limits"), back_name, session);
            var policy = session.policy;

            var limit_group = new PreferencesGroup(_("Daily Limit"),
                _("The screen locks when the time is used up. Time counts only while an app is in use."));
            var limit_row = new SwitchRow(_("Limit Screen Time"), null, policy.daily_limit_minutes > 0);
            limit_group.add_row(limit_row);
            var minutes_row = new SpinRow(_("Minutes a Day"), null, 15, 720, 15,
                policy.daily_limit_minutes > 0 ? policy.daily_limit_minutes : 120);
            limit_group.add_row(minutes_row);
            var warn_row = new SpinRow(_("Warn Before"), _("Minutes before the screen locks"), 1, 30, 1, policy.warning_minutes);
            limit_group.add_row(warn_row);
            add_group(limit_group);

            ParentalUpdate update_limit = () => {
                minutes_row.subtitle = Parental.UsageReport.format_duration((int64) minutes_row.spin_btn.get_value() * 60);
                minutes_row.visible = limit_row.active;
                warn_row.visible = limit_row.active || session.policy.bedtime_enabled;
            };
            limit_row.switch_btn.notify["active"].connect(() => {
                session.policy.daily_limit_minutes = limit_row.active ? (int) minutes_row.spin_btn.get_value() : 0;
                update_limit();
                session.queue_save();
            });
            minutes_row.spin_btn.value_changed.connect(() => {
                update_limit();
                if (!limit_row.active) return;
                session.policy.daily_limit_minutes = (int) minutes_row.spin_btn.get_value();
                session.queue_save();
            });
            warn_row.spin_btn.value_changed.connect(() => {
                session.policy.warning_minutes = (int) warn_row.spin_btn.get_value();
                session.queue_save();
            });

            var bed_group = new PreferencesGroup(_("Bedtime"), _("The screen stays locked during these hours."));
            var bed_row = new SwitchRow(_("Lock at Bedtime"), null, policy.bedtime_enabled);
            bed_group.add_row(bed_row);
            TimePicker from_picker;
            TimePicker to_picker;
            var from_row = time_row(_("From"), "weather-clear-night-symbolic", Parental.Policy.format_minutes(policy.bedtime_start), out from_picker);
            var to_row = time_row(_("To"), "weather-clear-symbolic", Parental.Policy.format_minutes(policy.bedtime_end), out to_picker);
            bed_group.add_row(from_row);
            bed_group.add_row(to_row);
            add_group(bed_group);

            ParentalUpdate update_bed = () => {
                from_row.visible = bed_row.active;
                to_row.visible = bed_row.active;
                update_limit();
            };
            bed_row.switch_btn.notify["active"].connect(() => {
                session.policy.bedtime_enabled = bed_row.active;
                update_bed();
                session.queue_save();
            });
            from_picker.changed.connect(() => {
                session.policy.bedtime_start = Parental.Policy.parse_minutes(from_picker.time, session.policy.bedtime_start);
                session.queue_save();
            });
            to_picker.changed.connect(() => {
                session.policy.bedtime_end = Parental.Policy.parse_minutes(to_picker.time, session.policy.bedtime_end);
                session.queue_save();
            });
            update_bed();
        }

        private PreferencesRow time_row(string title, string icon_name, string initial, out TimePicker picker) {
            var row = new PreferencesRow();
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 12;
            box.margin_end = 12;
            box.append(new Image.from_icon_name(icon_name));
            var lbl = new Label(title);
            lbl.add_css_class("title");
            lbl.halign = Align.START;
            lbl.hexpand = true;
            box.append(lbl);
            picker = new TimePicker(initial);
            box.append(picker);
            row.set_child(box);
            return row;
        }
    }

    public class ParentalWebPage : ParentalSubpage {
        private PreferencesGroup sites_group;
        private EntryRow add_row;
        private Gee.ArrayList<Widget> site_rows = new Gee.ArrayList<Widget>();

        public ParentalWebPage(SettingsView view, string back_name, ParentalSession session) {
            base(view, _("Websites"), back_name, session);
            var policy = session.policy;
            var filter_group = new PreferencesGroup(_("Filter"),
                _("Applies to the Singularity browser. Other browsers need their own settings."));
            var filter_row = new SwitchRow(_("Filter Websites"), _("Block the sites listed below"), policy.web_filter_enabled);
            filter_group.add_row(filter_row);
            var allow_row = new SwitchRow(_("Only Allow Listed Sites"), _("Block every site that is not in the list"), policy.web_allow_listed_only);
            filter_group.add_row(allow_row);
            add_group(filter_group);

            sites_group = new PreferencesGroup("");
            add_row = new EntryRow(_("Site, such as example.com"), "web-browser-symbolic");
            add_row.entry_activated.connect(add_site);
            var add_btn = new Button.with_label(_("Add"));
            add_btn.valign = Align.CENTER;
            add_btn.clicked.connect(add_site);
            add_row.add_suffix(add_btn);
            sites_group.add_row(add_row);
            add_group(sites_group);

            filter_row.switch_btn.notify["active"].connect(() => {
                session.policy.web_filter_enabled = filter_row.active;
                allow_row.sensitive = filter_row.active;
                sites_group.sensitive = filter_row.active;
                session.queue_save();
            });
            allow_row.switch_btn.notify["active"].connect(() => {
                session.policy.web_allow_listed_only = allow_row.active;
                filter_row.subtitle = allow_row.active ? _("Open only the sites listed below") : _("Block the sites listed below");
                rebuild();
                session.queue_save();
            });
            allow_row.sensitive = policy.web_filter_enabled;
            sites_group.sensitive = policy.web_filter_enabled;
            if (policy.web_allow_listed_only) filter_row.subtitle = _("Open only the sites listed below");
            rebuild();
        }

        private string[] current_list() {
            return session.policy.web_allow_listed_only ? session.policy.allowed_sites : session.policy.blocked_sites;
        }

        private void set_list(string[] list) {
            if (session.policy.web_allow_listed_only) session.policy.allowed_sites = list;
            else session.policy.blocked_sites = list;
            rebuild();
            session.queue_save();
        }

        private void add_site() {
            string site = Parental.Policy.normalize_site(add_row.text);
            if (site == "" || !site.contains(".")) return;
            string[] list = current_list();
            foreach (string s in list) if (Parental.Policy.normalize_site(s) == site) return;
            list += site;
            add_row.text = "";
            set_list(list);
        }

        private void rebuild() {
            foreach (var row in site_rows) sites_group.remove_row(row);
            site_rows.clear();
            sites_group.title = session.policy.web_allow_listed_only ? _("Allowed Sites") : _("Blocked Sites");
            foreach (string site in current_list()) {
                var row = new ActionRow(site, null, "web-browser-symbolic");
                var remove = new Button.from_icon_name("list-remove-symbolic");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Remove");
                remove.add_css_class("flat");
                string captured = site;
                remove.clicked.connect(() => {
                    string[] list = {};
                    foreach (string s in current_list()) if (s != captured) list += s;
                    set_list(list);
                });
                row.add_suffix(remove);
                sites_group.add_row(row);
                site_rows.add(row);
            }
        }
    }
}
