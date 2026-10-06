using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AppsPage : SettingsPage {
        private SingularityApp app;
        private SettingsView view;
        private List<AppRow> app_rows = new List<AppRow>();
        private PreferencesGroup apps_group;
        private class AppRow {
            public ActionRow row;
            public AppInfo info;
            public AppRow(ActionRow r, AppInfo i) { row = r; info = i; }
        }

        public AppsPage(SingularityApp app, SettingsView view) {
            base(_("Applications"));
            this.app = app;
            this.view = view;
            back_clicked.connect(() => {
                view.go_home();
            });
            // Default Apps entry
            var defaults_group = new PreferencesGroup(_("Defaults"));
            var defaults_row = new ActionRow(_("Default Apps"), _("Set which app opens each file type"));
            var defaults_icon = new Image.from_icon_name("preferences-system-symbolic");
            defaults_icon.pixel_size = 24;
            defaults_icon.margin_end = 8;
            defaults_row.add_prefix(defaults_icon);
            var nav_btn = new Button.from_icon_name("go-next-symbolic");
            nav_btn.add_css_class("flat");
            nav_btn.valign = Align.CENTER;
            nav_btn.clicked.connect(() => {
                view.open_subpage(new DefaultAppsPage(view), "default-apps");
            });
            defaults_row.add_suffix(nav_btn);
            defaults_row.activatable = false;
            defaults_group.add_row(defaults_row);
            add_group(defaults_group);

            var privacy_group = new PreferencesGroup(_("Privacy"));
            var history_row = new SwitchRow(_("File History"),
                _("Let apps and the dock remember recently used files"), true);
            var desktop_settings = new GLib.Settings("dev.sinty.desktop");
            if (desktop_settings.settings_schema.has_key(Singularity.Runtime.FILE_HISTORY_KEY)) {
                desktop_settings.bind(Singularity.Runtime.FILE_HISTORY_KEY, history_row.switch_btn, "active",
                    SettingsBindFlags.DEFAULT);
                privacy_group.add_row(history_row);
                add_group(privacy_group);
            }

            // Installed apps
            apps_group = new PreferencesGroup(_("Installed"));
            var search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search apps...");
            search.margin_top = 4;
            search.margin_bottom = 4;
            search.margin_start = 8;
            search.margin_end = 8;
            search.search_changed.connect(on_search_changed);
            apps_group.add_header_suffix(search);
            add_group(apps_group);
            Idle.add(() => {
                load_apps();
                return false;
            });
            // Rebuild the list when software is installed or removed so it
            // stays in sync with the overview and command palette.
            AppSystem.get_default().apps_changed.connect(reload_apps);
        }
        private bool loaded = false;
        private string current_query = "";

        private void reload_apps() {
            foreach (var item in app_rows) {
                apps_group.remove_row(item.row);
            }
            app_rows = new List<AppRow>();
            badges.clear();
            loaded = false;
            load_apps();
            // Re-apply any active search filter to the fresh rows.
            if (current_query != "") {
                foreach (var item in app_rows) {
                    item.row.visible = item.info.get_name().down().contains(current_query);
                }
            }
        }

        private void load_apps() {
            if (loaded) return;
            loaded = true;
            // Use AppSystem's merged list (same source as the overview): it
            // augments AppInfo.get_all() by scanning every XDG_DATA_DIRS
            // applications dir, so apps installed under /opt/local/share
            // (the Singularity apps) are included here too.
            unowned List<AppInfo> apps = AppSystem.get_default().get_all_apps();
            foreach (var app_info in apps) {
                if (!app_info.should_show()) continue;
                var row = new ActionRow(app_info.get_name());
                var icon = new Image.from_gicon(app_info.get_icon());
                icon.pixel_size = 32;
                icon.margin_end = 12;
                row.add_prefix(icon);
                var btn = new Button.from_icon_name("emblem-system-symbolic");
                btn.add_css_class("circular-button");
                btn.tooltip_text = _("App Settings");
                btn.valign = Align.CENTER;
                btn.clicked.connect(() => {
                    view.open_app_details(app_info);
                });
                var badge = PermissionRows.badge("");
                badge.visible = false;
                row.add_suffix(badge);
                row.add_suffix(btn);
                apps_group.add_row(row);
                app_rows.append(new AppRow(row, app_info));
                badges[app_info.get_id() ?? ""] = badge;
            }
            mark_sandboxed.begin();
        }

        private Gee.HashMap<string, Label> badges = new Gee.HashMap<string, Label>();

        private async void mark_sandboxed() {
            var backends = Sandbox.Backends.get_default();
            yield backends.apps();
            foreach (var entry in badges.entries) {
                if (entry.key == "") continue;
                var sandboxed = backends.app_for_desktop(entry.key);
                if (sandboxed == null) continue;
                var backend = backends.find(sandboxed.backend);
                entry.value.label = backend != null ? backend.label : sandboxed.backend;
                entry.value.visible = true;
            }
        }

        private void on_search_changed(Singularity.Widgets.SearchEntry entry) {
            string query = entry.text.down();
            current_query = query;
            foreach (var item in app_rows) {
                bool match = item.info.get_name().down().contains(query);
                item.row.visible = match;
            }
        }
    }
}
