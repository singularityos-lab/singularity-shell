using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AutostartPage : SettingsPage {
        private AutostartManager autostart;
        private PreferencesGroup entries_group;
        private SearchableExpanderRow app_row;

        public AutostartPage(SettingsView view) {
            base(_("Autostart"));
            back_clicked.connect(() => view.go_home());

            autostart = new AutostartManager();

            var add_grp = new PreferencesGroup(_("Autostart Apps"),
                _("Programs added here start automatically when you log in."));

            app_row = new SearchableExpanderRow(_("Add Application"),
                _("Choose an installed app to start at login"), "list-add-symbolic");
            app_row.search_entry.placeholder_text = _("Search applications");
            app_row.search_entry.search_changed.connect((entry) => {
                populate_app_list(entry.text);
            });
            app_row.notify["expanded"].connect(() => {
                if (app_row.expanded) populate_app_list(app_row.search_entry.text);
            });
            add_grp.add_row(app_row);

            var cmd_row = new EntryRow(_("Add Command"));
            var run_btn = new Button.from_icon_name("list-add-symbolic");
            run_btn.has_frame = false;
            run_btn.valign = Align.CENTER;
            run_btn.tooltip_text = _("Add");
            run_btn.clicked.connect(() => {
                string cmd = cmd_row.text.strip();
                if (cmd == "") return;
                autostart.add_command(cmd);
                cmd_row.text = "";
                refresh_entries();
            });
            cmd_row.entry_activated.connect(() => run_btn.clicked());
            cmd_row.add_suffix(run_btn);
            add_grp.add_row(cmd_row);
            add_group(add_grp);

            entries_group = new PreferencesGroup(_("Startup Applications"));
            add_group(entries_group);

            refresh_entries();
        }

        private void refresh_entries() {
            entries_group.clear();
            var entries = autostart.visible_entries();
            if (entries.size == 0) {
                var empty = new ActionRow(_("No startup applications"),
                    _("Add an app or command above"), null);
                empty.activatable = false;
                empty.sensitive = false;
                entries_group.add_row(empty);
                return;
            }
            foreach (var path in entries) {
                var info = new DesktopAppInfo.from_filename(path);
                string name = info != null ? info.get_display_name() : Path.get_basename(path);
                string subtitle = info != null ? (info.get_string("Comment") ?? "") : "";
                var row = new ActionRow(name, subtitle != "" ? subtitle : null, null);
                row.activatable = false;

                if (info != null && info.get_icon() != null) {
                    var img = new Image.from_gicon(info.get_icon());
                    img.pixel_size = 24;
                    img.margin_end = 12;
                    row.add_prefix(img);
                }

                var remove_btn = new Button.from_icon_name("user-trash-symbolic");
                remove_btn.has_frame = false;
                remove_btn.valign = Align.CENTER;
                remove_btn.add_css_class("destructive-action");
                remove_btn.tooltip_text = _("Remove");
                string entry_path = path;
                remove_btn.clicked.connect(() => {
                    row.confirmation_requested(_("Remove"), _("Cancel"),
                        ConfirmationSuggestedAction.CANCEL);
                });
                row.confirmed.connect(() => {
                    autostart.remove(entry_path);
                    refresh_entries();
                });
                row.add_suffix(remove_btn);
                entries_group.add_row(row);
            }
        }

        private void populate_app_list(string query) {
            var list = app_row.list_box;
            Widget? child = list.get_first_child();
            while (child != null) {
                list.remove(child);
                child = list.get_first_child();
            }

            var apps = new Gee.ArrayList<DesktopAppInfo>();
            foreach (var ai in AppInfo.get_all()) {
                var dai = ai as DesktopAppInfo;
                if (dai == null || !dai.should_show()) continue;
                string id = dai.get_id() ?? "";
                if (id != "" && autostart.contains(id)) continue;
                apps.add(dai);
            }
            apps.sort((a, b) => GLib.strcmp(a.get_display_name().down(), b.get_display_name().down()));

            string q = query.strip().down();
            foreach (var dai in apps) {
                if (q != "" && !dai.get_display_name().down().contains(q)) continue;
                var item = new ActionRow(dai.get_display_name());
                item.activatable = true;
                if (dai.get_icon() != null) {
                    var img = new Image.from_gicon(dai.get_icon());
                    img.pixel_size = 24;
                    img.margin_end = 12;
                    item.add_prefix(img);
                }
                var picked = dai;
                item.activated.connect(() => {
                    autostart.add_app(picked);
                    app_row.expanded = false;
                    app_row.search_entry.text = "";
                    refresh_entries();
                });
                list.append(item);
            }
        }
    }
}
