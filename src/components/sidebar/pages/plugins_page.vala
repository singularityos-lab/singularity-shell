using Gtk;
using Singularity.Widgets;
using Peas;

namespace Singularity {

    public class AppPluginRows : Object {
        public static Image row_icon (string? icon_name) {
            string name = icon_name != null && icon_name != "" ? icon_name : "application-x-addon-symbolic";
            var icon = new Image.from_icon_name (name);
            icon.pixel_size = name.has_suffix ("-symbolic") ? 16 : 32;
            icon.margin_end = name.has_suffix ("-symbolic") ? 4 : 12;
            return icon;
        }

        public static Image app_icon_image (string app_id) {
            var info = new GLib.DesktopAppInfo (app_id + ".desktop");
            Image icon = info != null && info.get_icon () != null
                ? new Image.from_gicon (info.get_icon ()) : new Image.from_icon_name ("application-x-addon-symbolic");
            icon.pixel_size = info != null && info.get_icon () != null ? 32 : 16;
            icon.margin_end = 12;
            return icon;
        }

        public static Gee.List<Peas.PluginInfo> for_app (string app_id) {
            var list = new Gee.ArrayList<Peas.PluginInfo> ();
            string id = app_id.has_suffix (".desktop") ? app_id.substring (0, app_id.length - 8) : app_id;
            foreach (var info in AppPluginHost.catalog ()) {
                if (!info.is_hidden () && AppPluginHost.is_hosted_by (info, id)) list.add (info);
            }
            return list;
        }

        public static Gee.List<Singularity.OverviewWidgetProvider> widgets_for_app (string app_id) {
            var list = new Gee.ArrayList<Singularity.OverviewWidgetProvider> ();
            string id = app_id.has_suffix (".desktop") ? app_id.substring (0, app_id.length - 8) : app_id;
            var registry = Singularity.OverviewWidgetRegistry.get_default ();
            registry.load_manifests ();
            foreach (var p in registry.list ()) {
                if (p.provider_id == id) list.add (p);
            }
            return list;
        }

        public static int placed_count (string widget_id) {
            var settings = AppPluginHost.desktop_settings ();
            if (settings == null) return 0;
            var v = settings.get_value ("overview-widgets");
            int n = 0;
            for (size_t i = 0; i < v.n_children (); i++) {
                if (v.get_child_value (i).get_child_value (1).get_string () == widget_id) n++;
            }
            return n;
        }

        public static ActionRow widget_row (Singularity.OverviewWidgetProvider provider) {
            var row = new ActionRow (provider.display_name, _("Widget"));
            row.add_prefix (AppPluginRows.row_icon (provider.icon_name));
            var state = new Label ("");
            state.add_css_class ("dim-label");
            state.valign = Align.CENTER;
            row.add_suffix (state);
            string widget_id = provider.id;
            sync_widget_row (row, state, widget_id);
            var settings = AppPluginHost.desktop_settings ();
            if (settings != null) {
                ulong handler = settings.changed["overview-widgets"].connect (() => sync_widget_row (row, state, widget_id));
                row.destroy.connect (() => settings.disconnect (handler));
            }
            return row;
        }

        private static void sync_widget_row (ActionRow row, Label state, string widget_id) {
            int placed = placed_count (widget_id);
            state.label = placed > 0 ? _("Active") : _("Not Added");
            row.subtitle = placed > 0
                ? ngettext ("Added to the launcher", "Added to the launcher %d times", placed).printf (placed)
                : _("Add it from the launcher to use it");
        }

        public static void fill_widgets (PreferencesGroup group, string app_id) {
            group.clear ();
            var widgets = widgets_for_app (app_id);
            foreach (var w in widgets) group.add_row (widget_row (w));
            group.visible = widgets.size > 0;
        }

        public static int item_count (string app_id) {
            return for_app (app_id).size + widgets_for_app (app_id).size;
        }

        public static Gee.List<string> hosts () {
            var ids = new Gee.ArrayList<string> ();
            var registry = Singularity.OverviewWidgetRegistry.get_default ();
            registry.load_manifests ();
            foreach (var p in registry.list ()) {
                if (p.provider_id != "" && p.provider_id.has_prefix ("dev.sinty.") && !ids.contains (p.provider_id)
                        && new GLib.DesktopAppInfo (p.provider_id + ".desktop") != null) ids.add (p.provider_id);
            }
            foreach (var info in AppPluginHost.catalog ()) {
                if (info.is_hidden ()) continue;
                foreach (string host in AppPluginHost.hosts_of (info)) {
                    if (host != "" && !ids.contains (host)) ids.add (host);
                }
            }
            return ids;
        }

        public static SwitchRow row (Peas.PluginInfo info, GLib.Settings? settings) {
            PluginPreferences.bind_translations (info);
            string? domain = PluginPreferences.gettext_domain (info);
            string name = domain != null ? GLib.dgettext (domain, info.get_name ()) : info.get_name ();
            string? desc = info.get_description ();
            if (desc != null && domain != null) desc = GLib.dgettext (domain, desc);
            var row = new SwitchRow (name, desc, AppPluginHost.catalog_enabled (settings, info));
            row.add_prefix (AppPluginRows.row_icon (info.get_icon_name ()));
            row.sensitive = settings != null;
            Peas.PluginInfo plugin = info;
            row.switch_btn.notify["active"].connect (() => {
                if (settings == null) return;
                if (AppPluginHost.catalog_enabled (settings, plugin) != row.switch_btn.active)
                    PluginPreferences.set_enabled (settings, plugin, row.switch_btn.active);
            });
            return row;
        }

        public static void fill (PreferencesGroup group, string app_id) {
            group.clear ();
            var settings = AppPluginHost.desktop_settings ();
            var plugins = for_app (app_id);
            foreach (var info in plugins) group.add_row (row (info, settings));
            group.visible = plugins.size > 0;
        }

        public static string app_name (string app_id) {
            var info = new GLib.DesktopAppInfo (app_id + ".desktop");
            return info != null ? info.get_name () : app_id;
        }

        public static string app_icon (string app_id) {
            var info = new GLib.DesktopAppInfo (app_id + ".desktop");
            return info != null && info.get_icon () != null ? info.get_icon ().to_string () : "application-x-addon-symbolic";
        }
    }

    public class PluginsPage : SettingsPage {
        private const string CATEGORY_KEY = "X-Singularity-Category";

        private struct Category {
            public string id;
            public string title;
            public string subtitle;
            public string icon;
        }

        private static Category[] categories () {
            return {
                { "panel", _("Panel"), _("Indicators and controls in the top panel"), "view-app-grid-symbolic" },
                { "dock", _("Dock"), _("Items and badges in the dock"), "user-desktop-symbolic" },
                { "wallpapers", _("Wallpapers"), _("Online and extra wallpaper sources"), "preferences-desktop-wallpaper-symbolic" },
                { "search", _("Search"), _("Extra results in the launcher"), "system-search-symbolic" },
                { "files", _("Files and Previews"), _("Icons and previews for file types"), "folder-symbolic" },
                { "tools", _("Tools"), _("Small utilities and helpers"), "applications-utilities-symbolic" },
                { "other", _("Other"), _("Plugins without a category"), "application-x-addon-symbolic" }
            };
        }

        private PluginManager manager;
        private SettingsView view;
        private Singularity.SidebarPages.SettingsSubpages subpages;
        private PreferencesGroup desktop_group;
        private PreferencesGroup apps_group;
        private PreferencesGroup more_group;
        private Gee.HashMap<string, SettingsPage> category_pages = new Gee.HashMap<string, SettingsPage> ();
        private Gee.HashMap<string, PreferencesGroup> category_groups = new Gee.HashMap<string, PreferencesGroup> ();
        private Gee.HashMap<string, ActionRow> category_links = new Gee.HashMap<string, ActionRow> ();
        private Gee.HashMap<string, SettingsPage> app_pages = new Gee.HashMap<string, SettingsPage> ();
        private Gee.HashMap<string, PreferencesGroup> app_groups = new Gee.HashMap<string, PreferencesGroup> ();
        private Gee.HashMap<string, ActionRow> app_links = new Gee.HashMap<string, ActionRow> ();
        private Gee.HashMap<string, PreferencesGroup> app_widget_groups = new Gee.HashMap<string, PreferencesGroup> ();
        private PreferencesGroup search_group;
        private Gee.ArrayList<ActionRow> links = new Gee.ArrayList<ActionRow> ();

        public PluginsPage (SettingsView view) {
            base (_("Plugins"));
            this.view = view;
            back_clicked.connect (() => view.go_home ());
            manager = PluginManager.get_default ();
            subpages = new Singularity.SidebarPages.SettingsSubpages (view, this, "plugins");

            var search = new Singularity.Widgets.SearchEntry ();
            search.placeholder_text = _("Search plugins...");
            search.search_changed.connect (on_search_changed);
            add_widget (search);

            desktop_group = new PreferencesGroup (_("Desktop"), _("Plugins that add features to the panel, dock and launcher"));
            add_group (desktop_group);
            foreach (var c in categories ()) {
                var page = subpages.create (c.title);
                var group = new PreferencesGroup ();
                page.add_group (group);
                category_pages[c.id] = page;
                category_groups[c.id] = group;
                var link = subpages.link (c.title, c.subtitle, c.icon, page, "plugins-" + c.id);
                link.set_data<string> ("search-text", c.title.down ());
                category_links[c.id] = link;
                links.add (link);
                desktop_group.add_row (link);
            }

            apps_group = new PreferencesGroup (_("Apps"), _("Sources and services each app can load"));
            add_group (apps_group);

            more_group = new PreferencesGroup ();
            add_group (more_group);
            var search_page = subpages.create (_("Search Providers"));
            search_group = new PreferencesGroup (null, _("Apps that show results in the launcher and overview search"));
            search_page.add_group (search_group);
            var search_link = subpages.link (_("Search Providers"), _("Apps that show results in the launcher"),
                "system-search-symbolic", search_page, "plugins-search-providers");
            links.add (search_link);
            more_group.add_row (search_link);

            refresh ();
            map.connect (refresh);

            var refresh_btn = new Button.from_icon_name ("view-refresh-symbolic");
            refresh_btn.add_css_class ("flat");
            refresh_btn.tooltip_text = _("Reload Plugins");
            refresh_btn.clicked.connect (() => {
                Peas.Engine.get_default ().rescan_plugins ();
                refresh ();
            });
            header.append (refresh_btn);
        }

        private static string category_of (Peas.PluginInfo info) {
            string? declared = info.get_external_data (CATEGORY_KEY);
            if (declared != null) {
                string d = declared.strip ().down ();
                foreach (var c in categories ()) if (c.id == d) return d;
            }
            string m = info.get_module_name ().down ();
            if (m.has_prefix ("wallpapers-") || m.contains ("wallpaper")) return "wallpapers";
            if (m.has_suffix ("-dock") || m.contains ("dock")) return "dock";
            if (m.contains ("search")) return "search";
            if (m.contains ("thumbnail") || m.contains ("preview") || m.has_suffix ("-icon")) return "files";
            switch (m) {
                case "caffeine":
                case "sensors":
                case "status-monitor":
                case "tailscale":
                case "media-controls":
                case "weather":
                case "workspaces-indicator":
                case "tray-icons":
                case "disk-usage":
                    return "panel";
                case "quick-notes":
                case "notification-test":
                case "color-picker":
                    return "tools";
                default:
                    return "other";
            }
        }

        private void refresh () {
            refresh_shell_plugins ();
            refresh_app_plugins ();
            refresh_search_providers ();
        }

        private void refresh_shell_plugins () {
            var counts = new Gee.HashMap<string, int> ();
            var enabled_counts = new Gee.HashMap<string, int> ();
            foreach (var g in category_groups.values) g.clear ();
            var plugins = manager.get_available_plugins ();
            if (plugins != null) {
                foreach (var info in plugins) {
                    if (info.is_hidden ()) continue;
                    string cat = category_of (info);
                    string module = info.get_module_name ();
                    bool enabled = manager.is_plugin_enabled (module);
                    var row = new SwitchRow (info.get_name (), info.get_description (), enabled);
                    row.add_prefix (AppPluginRows.row_icon (info.get_icon_name ()));
                    var btn = new Button.from_icon_name ("emblem-system-symbolic");
                    btn.add_css_class ("circular-button");
                    btn.tooltip_text = _("Plugin Settings");
                    btn.valign = Align.CENTER;
                    Peas.PluginInfo plugin = info;
                    btn.clicked.connect (() => view.open_plugin_details (plugin));
                    row.add_suffix (btn);
                    row.switch_btn.notify["active"].connect (() => {
                        if (manager.is_plugin_enabled (module) != row.switch_btn.active)
                            manager.set_plugin_enabled (module, row.switch_btn.active);
                    });
                    category_groups[cat].add_row (row);
                    counts[cat] = (counts.has_key (cat) ? counts[cat] : 0) + 1;
                    if (enabled) enabled_counts[cat] = (enabled_counts.has_key (cat) ? enabled_counts[cat] : 0) + 1;
                    category_links[cat].set_data<string> ("search-text",
                        (category_links[cat].get_data<string> ("search-text") ?? "") + " " + info.get_name ().down ());
                }
            }
            foreach (var c in categories ()) {
                int n = counts.has_key (c.id) ? counts[c.id] : 0;
                int on = enabled_counts.has_key (c.id) ? enabled_counts[c.id] : 0;
                category_links[c.id].visible = n > 0;
                category_links[c.id].subtitle = ngettext ("%d of %d plugin on", "%d of %d plugins on", n).printf (on, n);
            }
        }

        private void refresh_app_plugins () {
            int shown = 0;
            foreach (string host in AppPluginRows.hosts ()) {
                if (!app_pages.has_key (host)) {
                    var page = subpages.create (AppPluginRows.app_name (host));
                    var group = new PreferencesGroup (_("Plugins"));
                    page.add_group (group);
                    var widgets = new PreferencesGroup (_("Widgets"), _("Widgets become active when you add them to the launcher"));
                    page.add_group (widgets);
                    app_pages[host] = page;
                    app_groups[host] = group;
                    app_widget_groups[host] = widgets;
                    var link = subpages.link (AppPluginRows.app_name (host), "", "", page, "plugins-app-" + host);
                    link.add_prefix (AppPluginRows.app_icon_image (host));
                    link.set_data<string> ("app-link", host);
                    link.set_data<string> ("search-text", AppPluginRows.app_name (host).down ());
                    app_links[host] = link;
                    links.add (link);
                    apps_group.add_row (link);
                }
                AppPluginRows.fill (app_groups[host], host);
                AppPluginRows.fill_widgets (app_widget_groups[host], host);
                int n = AppPluginRows.for_app (host).size;
                int w = AppPluginRows.widgets_for_app (host).size;
                app_links[host].subtitle = w == 0 ? ngettext ("%d plugin", "%d plugins", n).printf (n)
                    : n == 0 ? ngettext ("%d widget", "%d widgets", w).printf (w)
                    : _("%d plugins and widgets").printf (n + w);
                shown++;
            }
            apps_group.visible = shown > 0;
        }

        private void refresh_search_providers () {
            search_group.clear ();
            var search = SearchManager.get_default ();
            foreach (var info in search.get_remote_provider_infos ()) {
                var row = new SwitchRow (info.name, null, search.is_remote_provider_enabled (info));
                if (info.app_icon != null) {
                    var icon = new Image.from_gicon (info.app_icon);
                    icon.pixel_size = 32;
                    icon.margin_end = 12;
                    row.add_prefix (icon);
                }
                string id = info.id;
                row.switch_btn.notify["active"].connect (() => {
                    search.set_remote_provider_enabled (id, row.switch_btn.active);
                });
                search_group.add_row (row);
            }
        }

        private void on_search_changed (Singularity.Widgets.SearchEntry entry) {
            string query = entry.text.strip ().down ();
            foreach (var link in links) {
                string text = (link.get_data<string> ("search-text") ?? link.title.down ());
                bool has_content = link.get_data<string> ("app-link") != null || !(link in category_links.values) || category_links_visible (link);
                link.visible = has_content && (query == "" || text.contains (query));
            }
        }

        private bool category_links_visible (ActionRow link) {
            foreach (var e in category_links.entries) {
                if (e.value == link) return category_groups[e.key].get_rows ().size > 0;
            }
            return true;
        }
    }
}
