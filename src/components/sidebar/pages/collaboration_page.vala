using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class CollaborationPage : SettingsPage {
        private SettingsView view;
        private Singularity.Collab.Client client;
        private StatusPage unavailable;
        private SwitchRow enabled_row;
        private PreferencesGroup providers_group;
        private PreferencesGroup people_group;
        private PreferencesGroup sessions_group;
        private PreferencesGroup history_group;
        private bool syncing = false;

        public CollaborationPage(SettingsView view) {
            base(_("Collaboration"));
            this.view = view;
            client = Singularity.Collab.Client.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("sharing"));

            unavailable = new StatusPage();
            unavailable.compact = true;
            unavailable.icon_name = "system-users-symbolic";
            unavailable.title = _("Collaboration Is Not Installed");
            unavailable.description = _("Install Nearby to send things and work together with people around you.");
            unavailable.visible = false;
            add_widget(unavailable);

            var general = new PreferencesGroup(_("Work Together"),
                _("Send notes, tasks and events, and edit documents together with people you trust. Every request has to be accepted."));
            enabled_row = new SwitchRow(_("Collaboration"), _("Paired devices can send you things and invite you"), true);
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                client.set_enabled.begin(enabled_row.active, (o, r) => {
                    client.set_enabled.end(r);
                    refresh.begin();
                });
            });
            general.add_row(enabled_row);
            add_group(general);

            sessions_group = new PreferencesGroup(_("Active Sessions"), null);
            add_group(sessions_group);
            people_group = new PreferencesGroup(_("People"), _("People reachable now, on every provider."));
            add_group(people_group);
            providers_group = new PreferencesGroup(_("Providers"), _("Ways to reach people. Apps can install more."));
            add_group(providers_group);
            history_group = new PreferencesGroup(_("Recent"), null);
            add_group(history_group);

            client.people_changed.connect(() => refresh.begin());
            client.sessions_changed.connect(() => refresh.begin());
            map.connect(() => refresh.begin());
            add_search_action(_("Collaboration"), _("Work together with people nearby"), () => view.navigate_to("sharing-collab"));
        }

        private ActionRow info_row(string title, string? subtitle, string icon) {
            var row = new ActionRow(title, subtitle, icon);
            row.activatable = false;
            return row;
        }

        private async void refresh() {
            bool installed = Singularity.Collab.Client.installed();
            unavailable.visible = !installed;
            bool on = installed && yield client.get_enabled();
            syncing = true;
            enabled_row.active = on;
            syncing = false;
            enabled_row.visible = installed;
            sessions_group.visible = installed && on;
            people_group.visible = installed && on;
            providers_group.visible = installed && on;
            history_group.visible = installed;
            if (!installed) return;

            sessions_group.clear();
            var sessions = yield client.sessions();
            foreach (var s in sessions) {
                string who = s.people.length > 0 ? string.joinv(", ", s.people) : _("Waiting for people to join");
                string subtitle = s.hosting ? _("Shared by you with %s").printf(who) : _("Shared by %s").printf(s.host_name);
                var row = info_row(s.title, "%s · %s".printf(Singularity.Collab.Client.kind_label(s.kind), subtitle), "system-users-symbolic");
                var stop = new Button.with_label(s.hosting ? _("Stop") : _("Leave"));
                stop.add_css_class("pill");
                stop.valign = Align.CENTER;
                string sid = s.id;
                stop.clicked.connect(() => {
                    client.leave.begin(sid, (o, r) => {
                        try {
                            client.leave.end(r);
                        } catch (Error e) {
                            warning("collab: %s", e.message);
                        }
                        refresh.begin();
                    });
                });
                row.add_suffix(stop);
                sessions_group.add_row(row);
            }
            sessions_group.visible = on && sessions.size > 0;

            people_group.clear();
            yield client.refresh_people();
            foreach (var p in client.people) {
                string subtitle = p.can_join ? p.provider_name : _("%s, can receive only").printf(p.provider_name);
                people_group.add_row(info_row(p.name, subtitle, p.icon_name));
            }
            if (client.people.size == 0) {
                var row = new ActionRow(_("Nobody Is Reachable"), _("Pair a computer or phone in Connected Devices"), "network-offline-symbolic");
                row.activatable = true;
                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.pixel_size = 12;
                chevron.add_css_class("dim-label");
                chevron.valign = Align.CENTER;
                row.add_suffix(chevron);
                row.activated.connect(() => view.navigate_to("connected-devices"));
                people_group.add_row(row);
            }

            providers_group.clear();
            foreach (var p in yield client.records("ListProviders")) {
                string name = p.contains("name") ? p["name"].get_string() : "";
                bool builtin = p.contains("builtin") && p["builtin"].get_boolean();
                int n = p.contains("people") ? p["people"].get_int32() : 0;
                string state = ngettext("%d person reachable", "%d people reachable", (ulong) n).printf(n);
                providers_group.add_row(info_row(name, builtin ? _("Built in, %s").printf(state) : state,
                    builtin ? "network-wired-symbolic" : "network-workgroup-symbolic"));
            }

            history_group.clear();
            int shown = 0;
            foreach (var h in yield client.records("History")) {
                if (shown++ >= 8) break;
                string title = h["title"].get_string();
                string name = h["name"].get_string();
                bool incoming = h["incoming"].get_boolean();
                bool accepted = h["accepted"].get_boolean();
                var when = new DateTime.from_unix_local(h["time"].get_int64());
                string what = Singularity.Collab.Client.kind_label(h["kind"].get_string());
                string line = incoming
                    ? (accepted ? _("%s from %s").printf(what, name) : _("%s from %s, declined").printf(what, name))
                    : _("%s to %s").printf(what, name);
                history_group.add_row(info_row(title != "" ? title : what, "%s · %s".printf(line, when.format("%x %H:%M")),
                    incoming ? "mail-receive-symbolic" : "mail-send-symbolic"));
            }
            history_group.visible = shown > 0;
        }
    }
}
