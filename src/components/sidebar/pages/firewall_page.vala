using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class FirewallPage : SettingsPage {
        private SettingsView view;
        private FirewallManager firewall;
        private StatusPage unavailable;
        private PreferencesGroup state_group;
        private SwitchRow enabled_row;
        private PreferencesGroup profile_group;
        private ActionRow home_row;
        private ActionRow public_row;
        private ActionRow other_row;
        private Image home_check;
        private Image public_check;
        private PreferencesGroup rules_group;
        private Label error_label;
        private bool syncing = false;
        private bool busy = false;

        public FirewallPage(SettingsView view) {
            base(_("Firewall"));
            this.view = view;
            firewall = FirewallManager.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("network"));

            unavailable = new StatusPage();
            unavailable.compact = true;
            unavailable.icon_name = "security-high";
            unavailable.title = _("No Firewall Available");
            unavailable.description = _("Install firewalld or nftables to block connections you did not ask for.");
            unavailable.visible = false;
            add_widget(unavailable);

            state_group = new PreferencesGroup(_("Protection"));
            enabled_row = new SwitchRow(_("Block Incoming Connections"), _("Only apps and ports you allow can be reached"), false);
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                change.begin(Change.ENABLED, enabled_row.switch_btn.active, FirewallProfile.HOME, "");
            });
            state_group.add_row(enabled_row);
            add_group(state_group);

            profile_group = new PreferencesGroup(_("Network Profile"),
                _("Use Public on networks you do not trust, such as in cafés and airports."));
            home_row = profile_row(_("Home"), _("Allowed apps and nearby discovery work"), FirewallProfile.HOME, out home_check);
            public_row = profile_row(_("Public"), _("Only apps allowed on every network"), FirewallProfile.PUBLIC, out public_check);
            other_row = new ActionRow(_("Other Zone"), "");
            other_row.activatable = false;
            other_row.visible = false;
            profile_group.add_row(home_row);
            profile_group.add_row(public_row);
            profile_group.add_row(other_row);
            add_group(profile_group);

            rules_group = new PreferencesGroup(_("Allowed Apps and Ports"));
            var add_btn = new Button.with_label(_("Add Port"));
            add_btn.add_css_class("pill");
            add_btn.valign = Align.CENTER;
            add_btn.clicked.connect(() => view.open_subpage(new AddFirewallRulePage(view), "firewall-add"));
            rules_group.add_header_suffix(add_btn);
            add_group(rules_group);

            error_label = new Label("");
            error_label.add_css_class("caption");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.xalign = 0;
            error_label.margin_start = 12;
            error_label.margin_top = 8;
            error_label.visible = false;
            add_widget(error_label);

            firewall.changed.connect(sync);
            map.connect(() => firewall.refresh.begin());
            firewall.refresh.begin();
        }

        private enum Change {
            ENABLED,
            PROFILE,
            REVOKE
        }

        private async void change(Change what, bool on, FirewallProfile profile, string id) {
            if (busy) return;
            busy = true;
            error_label.visible = false;
            try {
                switch (what) {
                    case Change.ENABLED:
                        yield firewall.set_enabled(on);
                        break;
                    case Change.PROFILE:
                        yield firewall.set_profile(profile);
                        break;
                    case Change.REVOKE:
                        yield firewall.revoke_app(id);
                        break;
                }
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                error_label.label = e.message;
                error_label.visible = true;
                yield firewall.refresh();
            }
            busy = false;
        }

        private ActionRow profile_row(string title, string subtitle, FirewallProfile profile, out Image check) {
            var row = new ActionRow(title, subtitle);
            row.activatable = true;
            var mark = new Image.from_icon_name("object-select-symbolic");
            mark.valign = Align.CENTER;
            mark.add_css_class("accent");
            row.add_suffix(mark);
            row.activated.connect(() => {
                if (syncing) return;
                change.begin(Change.PROFILE, false, profile, "");
            });
            check = mark;
            return row;
        }

        private void sync() {
            var st = firewall.current;
            bool available = firewall.ready && firewall.backend != null && st != null;
            unavailable.visible = firewall.ready && !available;
            state_group.visible = available;
            profile_group.visible = available;
            rules_group.visible = available;
            if (!available) return;
            syncing = true;
            enabled_row.switch_btn.active = st.enabled;
            enabled_row.sensitive = st.can_toggle;
            enabled_row.subtitle = st.can_toggle ? _("Only apps and ports you allow can be reached")
                : _("Managed by %s").printf(firewall.backend.name);
            profile_group.sensitive = st.enabled;
            home_check.visible = st.profile == FirewallProfile.HOME;
            public_check.visible = st.profile == FirewallProfile.PUBLIC;
            other_row.visible = st.profile == FirewallProfile.OTHER;
            other_row.subtitle = st.zone;
            rules_group.clear();
            foreach (var rule in st.rules) {
                string where = rule.public_too ? _("Every network") : _("Home only");
                string ports = rule.ports_text();
                var row = new ActionRow(rule.label, ports != "" ? "%s · %s".printf(ports, where) : where,
                    "network-server-symbolic");
                row.activatable = false;
                if (rule.removable) {
                    var remove = new Button.from_icon_name("list-remove-symbolic");
                    remove.valign = Align.CENTER;
                    remove.add_css_class("flat");
                    remove.tooltip_text = _("Remove");
                    string id = rule.id;
                    remove.clicked.connect(() => change.begin(Change.REVOKE, false, FirewallProfile.HOME, id));
                    row.add_suffix(remove);
                }
                rules_group.add_row(row);
            }
            if (st.rules.size == 0) {
                var none = new ActionRow(_("Nothing Allowed"), _("Apps that you share on the network appear here"));
                none.activatable = false;
                rules_group.add_row(none);
            }
            syncing = false;
        }
    }

    public class AddFirewallRulePage : SettingsPage {
        private EntryRow name_row;
        private EntryRow ports_row;
        private SwitchRow public_row;
        private Label error_label;
        private Button add_btn;

        public AddFirewallRulePage(SettingsView view) {
            base(_("Add Port"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("firewall"));

            var group = new PreferencesGroup(_("Rule"), _("Ports look like 8080/tcp or 6000-6010/udp. Separate several with commas."));
            name_row = new EntryRow(_("Name"));
            ports_row = new EntryRow(_("Ports"));
            public_row = new SwitchRow(_("Also on Public Networks"), null, false);
            group.add_row(name_row);
            group.add_row(ports_row);
            group.add_row(public_row);
            add_group(group);

            error_label = new Label("");
            error_label.add_css_class("caption");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.xalign = 0;
            error_label.margin_start = 12;
            error_label.margin_top = 8;
            error_label.visible = false;
            add_widget(error_label);

            add_btn = new Button.with_label(_("Add"));
            add_btn.add_css_class("pill");
            add_btn.add_css_class("suggested-action");
            add_btn.halign = Align.CENTER;
            add_btn.margin_top = 16;
            add_btn.clicked.connect(() => add.begin(view));
            ports_row.entry_activated.connect(() => add.begin(view));
            add_widget(add_btn);
        }

        public static string rule_id(string name) {
            string id = HostnameManager.static_name(name);
            if (id.length > 24) id = id.substring(0, 24);
            return "custom-" + id;
        }

        public static string[] parse_ports(string text) {
            string[] ports = {};
            foreach (string part in text.replace(";", ",").split(",")) {
                string p = part.strip().down().replace(" ", "");
                if (p != "") ports += p;
            }
            return ports;
        }

        private async void add(SettingsView view) {
            string name = name_row.text.strip();
            string[] ports = parse_ports(ports_row.text);
            if (name == "") name = ports_row.text.strip();
            if (!FirewallPorts.valid(ports)) {
                error_label.label = _("Enter ports like 8080/tcp or 6000-6010/udp.");
                error_label.visible = true;
                return;
            }
            add_btn.sensitive = false;
            try {
                yield FirewallManager.get_default().allow_app(rule_id(name), name, ports, public_row.switch_btn.active);
                view.navigate_to("firewall");
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                error_label.label = e.message;
                error_label.visible = true;
            }
            add_btn.sensitive = true;
        }
    }
}
