using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class ParentalSession : Object {
        public Parental.Policy policy;
        public Parental.PolicyStore store;
        public string display_name;
        public string home;
        private uint save_id = 0;
        public signal void saved();
        public signal void failed(string message);
        public signal void changed();

        public ParentalSession(string user_name, string display_name, string home) {
            store = Parental.Stores.policy_store();
            policy = store.load(user_name);
            this.display_name = display_name;
            this.home = home;
        }

        public void queue_save() {
            changed();
            if (save_id != 0) Source.remove(save_id);
            save_id = Timeout.add(600, () => {
                save_id = 0;
                var snapshot = policy.copy();
                store.save.begin(snapshot, (obj, res) => {
                    try {
                        store.save.end(res);
                        saved();
                    } catch (Error e) {
                        warning("Parental controls: saving failed: %s", e.message);
                        policy = store.load(snapshot.user_name);
                        failed(e.message);
                        changed();
                    }
                });
                return Source.REMOVE;
            });
        }

        public string summary() {
            string[] parts = {};
            if (policy.blocked_apps.length > 0)
                parts += ngettext("%d app blocked", "%d apps blocked", policy.blocked_apps.length).printf(policy.blocked_apps.length);
            if (policy.daily_limit_minutes > 0)
                parts += _("%s a day").printf(Parental.UsageReport.format_duration((int64) policy.daily_limit_minutes * 60));
            if (policy.bedtime_enabled)
                parts += _("bedtime at %s").printf(Parental.Policy.format_minutes(policy.bedtime_start));
            if (policy.web_filter_enabled) parts += _("websites filtered");
            if (parts.length == 0) return _("No restrictions");
            string text = string.joinv(", ", parts);
            return text.substring(0, 1).up() + text.substring(1);
        }
    }

    public class ParentalSubpage : SettingsPage {
        protected SettingsView view;
        protected ParentalSession session;
        private Banner banner;

        public ParentalSubpage(SettingsView view, string title, string back_name, ParentalSession session) {
            base(title);
            this.view = view;
            this.session = session;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to(back_name));
            banner = new Banner("", BannerStyle.ERROR);
            banner.visible = false;
            banner.icon_name = "dialog-warning-symbolic";
            content_box.prepend(banner);
            session.failed.connect((msg) => {
                banner.title = _("The change was not saved: %s").printf(msg);
                banner.visible = true;
            });
            session.saved.connect(() => banner.visible = false);
        }
    }

    public class ParentalControlsPage : SettingsPage {
        private SettingsView view;
        private ParentalSession session;
        private string page_name;
        private ActionRow status_row;

        public ParentalControlsPage(SettingsView view, Singularity.Core.Users.AccountUser user, string back_name) {
            string display = user.real_name != "" ? user.real_name : user.user_name;
            base(_("Parental Controls"));
            this.view = view;
            page_name = "parental-%s".printf(user.uid.to_string());
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to(back_name));
            session = new ParentalSession(user.user_name, display, user.home_directory);

            var welcome = new WelcomePage();
            welcome.is_section = true;
            welcome.embedded = true;
            welcome.compact = true;
            welcome.app_icon_name = "singularity-parental-controls";
            welcome.title = display;
            welcome.subtitle = _("Choose which apps %s can use, for how long, and which websites open.").printf(display);
            welcome.add_action("applications-games-symbolic", _("Apps"), _("Hide apps and stop them from starting"), open_apps);
            welcome.add_action("preferences-system-time-symbolic", _("Time Limits"), _("A daily limit and a bedtime"), open_time);
            welcome.add_action("web-browser-symbolic", _("Websites"), _("Filter what opens in the browser"), open_web);
            welcome.add_action("utilities-system-monitor-symbolic", _("Screen Time"), _("See which apps were used and for how long"), open_screen_time);
            add_widget(welcome);

            var status_group = new PreferencesGroup(_("Status"),
                _("Enforced by the desktop for this account. An administrator, or someone with a terminal, can get around these limits."));
            status_row = new ActionRow(_("Restrictions"), session.summary(), "channel-secure-symbolic");
            status_group.add_row(status_row);
            var backend_row = new ActionRow(_("Stored In"), session.store.name == "malcontent"
                ? _("System settings, shared with other parental controls tools")
                : _("System settings of this computer"), "drive-harddisk-symbolic");
            status_group.add_row(backend_row);
            add_group(status_group);
            session.changed.connect(() => status_row.subtitle = session.summary());
        }

        private void open_apps() {
            view.open_subpage(new ParentalAppsPage(view, page_name, session), page_name + "-apps");
        }

        private void open_time() {
            view.open_subpage(new ParentalTimePage(view, page_name, session), page_name + "-time");
        }

        private void open_web() {
            view.open_subpage(new ParentalWebPage(view, page_name, session), page_name + "-web");
        }

        private void open_screen_time() {
            var store = Parental.Stores.usage_store_for(session.policy.user_name, session.home);
            view.open_subpage(new ScreenTimePage(view, _("Screen Time"), store, page_name), page_name + "-screen-time");
        }
    }

}
