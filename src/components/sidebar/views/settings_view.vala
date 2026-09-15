using Gtk;
using Gee;

namespace Singularity {

    public class SettingsView : Box {
        private Stack main_stack; // Toggles between sidebar and content in narrow mode
        private Stack settings_stack; // Holds the settings pages
        private Box split_box;
        private Box nav_box;
        private ScrolledWindow nav_scroller;
        private SearchEntry search_entry;
        private Box search_results_box;
        private SingularityApp app;
        private bool split_mode;
        private bool folded = false;
        private Singularity.SidebarPages.AppDetailsPage app_details_page;
        private Gee.HashMap<string, Widget> _page_cache;
        private Gee.ArrayList<SettingsSearchItem> _search_items = new Gee.ArrayList<SettingsSearchItem>();
        private GLib.Settings _desktop_settings;
        private Widget? _developer_nav_row = null;
        private Widget _keyboard_nav_row;
        public signal void back_to_system();

        private class SettingsSearchItem : Object {
            public string page_name;
            public string page_title;
            public string icon_name;
            public string title;
            public string subtitle;
            public string group;

            public SettingsSearchItem(string page_name, string page_title, string icon_name,
                                      string title, string subtitle, string group) {
                this.page_name = page_name;
                this.page_title = page_title;
                this.icon_name = icon_name;
                this.title = title;
                this.subtitle = subtitle;
                this.group = group;
            }
        }

        public SettingsView(SingularityApp app, bool split_mode = false) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.app = app;
            this.split_mode = split_mode;
            _page_cache = new Gee.HashMap<string, Widget>();
            _desktop_settings = new GLib.Settings("dev.sinty.desktop");

            main_stack = new Stack();
            main_stack.transition_type = StackTransitionType.SLIDE_LEFT_RIGHT;
            main_stack.vexpand = true;
            main_stack.hexpand = true;

            settings_stack = new Stack();
            settings_stack.transition_type = StackTransitionType.SLIDE_LEFT_RIGHT;
            settings_stack.hexpand = true;
            settings_stack.vhomogeneous = false; // Each page takes its own natural height
            settings_stack.hhomogeneous = true; // All pages share one fixed width

            nav_box = new Box(Orientation.VERTICAL, 8);
            nav_box.add_css_class("navigation-sidebar");
            nav_box.vexpand = true; // Ensure it expands

            if (AppSystem.get_default().is_container) {
                var container_box = new Box(Orientation.HORIZONTAL, 12);
                container_box.add_css_class("warning-box");
                container_box.margin_bottom = 12;
                var icon = new Image.from_icon_name("dialog-warning-symbolic");
                container_box.append(icon);
                var lbl = new Label(_("Container Mode\nSome features may be limited."));
                lbl.wrap = true;
                lbl.xalign = 0;
                container_box.append(lbl);
                nav_box.append(container_box);
            }

            setup_settings_search();

            nav_box.append(create_settings_row(_("Network"), "network-wireless-symbolic", "network"));
            nav_box.append(create_settings_row(_("Apps"), "view-app-grid-symbolic", "apps"));
            nav_box.append(create_settings_row(_("Autostart"), "system-run-symbolic", "autostart"));
            nav_box.append(create_settings_row(_("Users"), "system-users-symbolic", "users"));
            nav_box.append(create_settings_row(_("Online Accounts"), "avatar-default-symbolic", "accounts"));
            nav_box.append(create_settings_row(_("Displays"), "video-display-symbolic", "displays"));
            nav_box.append(create_settings_row(_("Region & Language"), "preferences-desktop-locale-symbolic", "region"));
            nav_box.append(create_settings_row(_("Date & Time"), "preferences-system-time-symbolic", "datetime"));
            nav_box.append(create_settings_row(_("Desktop"), "preferences-desktop-wallpaper-symbolic", "desktop"));
            nav_box.append(create_settings_row(_("Sound"), "audio-volume-high-symbolic", "sound"));
            nav_box.append(create_settings_row(_("Bluetooth"), "bluetooth-active-symbolic", "bluetooth"));
            _keyboard_nav_row = create_settings_row(_("Keyboard"), "input-keyboard-symbolic", "keyboard");
            nav_box.append(_keyboard_nav_row);
            // Developer page is hidden until enabled from System (Android-style).
            update_developer_nav_row();
            _desktop_settings.changed["developer-mode"].connect(update_developer_nav_row);
            nav_box.append(create_settings_row(_("Accessibility"), "preferences-desktop-accessibility-symbolic", "accessibility"));
            nav_box.append(create_settings_row(_("Plugins"), "emblem-system-symbolic", "plugins"));
            nav_box.append(create_settings_row(_("Performance"), "power-profile-performance-symbolic", "performance"));
            nav_box.append(create_settings_row(_("System"), "computer-symbolic", "system"));

            if (split_mode) {
                            nav_scroller = new ScrolledWindow();
                            nav_scroller.hscrollbar_policy = PolicyType.NEVER;
                            nav_scroller.vexpand = true;
                            nav_scroller.set_size_request(240, -1);
                            nav_scroller.set_child(nav_box);
                split_box = new Box(Orientation.HORIZONTAL, 0);
                split_box.vexpand = true;

                main_stack.add_named(nav_scroller, "sidebar");
                main_stack.add_named(settings_stack, "content");

                append(split_box);

                this.realize.connect(() => {
                    var win = get_root() as Gtk.Window;
                    if (win != null) {
                        win.notify["default-width"].connect(update_adaptive_layout);
                        update_adaptive_layout();
                    }
                });

                navigate_to("desktop");
            } else {
                append(settings_stack);
                var home_page = new SettingsPage(_("Settings"));
                home_page.back_btn.visible = true;
                home_page.back_clicked.connect(() => { back_to_system(); });

                home_page.add_widget(nav_box);

                settings_stack.add_named(home_page, "home");
                settings_stack.visible_child_name = "home";
            }
        }

        private void update_adaptive_layout() {
            var win = get_root() as Gtk.Window;
            if (win == null) return;

            bool should_fold = win.get_width() < 720;
            if (should_fold == folded && (split_box.parent != null || main_stack.parent != null)) return;

            folded = should_fold;

            if (folded) {
                if (split_box.parent == this) remove(split_box);
                if (main_stack.parent != this) append(main_stack);

                if (nav_scroller.parent == split_box) split_box.remove(nav_scroller);
                if (settings_stack.parent == split_box) split_box.remove(settings_stack);

                if (nav_scroller.parent != main_stack) main_stack.add_named(nav_scroller, "sidebar");
                if (settings_stack.parent != main_stack) main_stack.add_named(settings_stack, "content");

                if (settings_stack.visible_child_name == null || settings_stack.visible_child_name == "" || settings_stack.visible_child_name == "home") {
                    main_stack.visible_child_name = "sidebar";
                } else {
                    main_stack.visible_child_name = "content";
                }
            } else {
                if (main_stack.parent == this) remove(main_stack);
                if (split_box.parent != this) append(split_box);

                if (nav_scroller.parent == main_stack) main_stack.remove(nav_scroller);
                if (settings_stack.parent == main_stack) main_stack.remove(settings_stack);

                if (nav_scroller.parent != split_box) split_box.append(nav_scroller);
                if (settings_stack.parent != split_box) split_box.append(settings_stack);
            }

            update_back_buttons();
        }

        private void update_back_buttons() {
            Widget? child = settings_stack.get_first_child();
            while (child != null) {
                var page = child as SettingsPage;
                if (page != null) {
                    page.adaptive_back_btn.visible = (folded && settings_stack.visible_child_name != "home");
                    page.adaptive_back_btn.clicked.connect(() => {
                        main_stack.visible_child_name = "sidebar";
                    });
                }
                child = child.get_next_sibling();
            }
        }

        public void open_app_details(AppInfo info) {
            if (app_details_page != null) {
                settings_stack.remove(app_details_page);
            }
            app_details_page = new Singularity.SidebarPages.AppDetailsPage(app, info);
            app_details_page.back_btn.visible = true;
            app_details_page.adaptive_back_btn.visible = folded;
            app_details_page.adaptive_back_btn.clicked.connect(() => {
                if (folded) main_stack.visible_child_name = "sidebar";
            });
            settings_stack.add_named(app_details_page, "app-details");
            settings_stack.visible_child_name = "app-details";
            if (folded) main_stack.visible_child_name = "content";
        }

        private Singularity.SidebarPages.PluginDetailsPage plugin_details_page;

        public void open_plugin_details(Peas.PluginInfo info) {
             if (plugin_details_page != null) {
                 settings_stack.remove(plugin_details_page);
             }
             plugin_details_page = new Singularity.SidebarPages.PluginDetailsPage(app, info);
             plugin_details_page.back_btn.visible = true;
             plugin_details_page.adaptive_back_btn.visible = folded;
             plugin_details_page.adaptive_back_btn.clicked.connect(() => {
                if (folded) main_stack.visible_child_name = "sidebar";
             });
             settings_stack.add_named(plugin_details_page, "plugin-details");
             settings_stack.visible_child_name = "plugin-details";
             if (folded) main_stack.visible_child_name = "content";
        }

        private bool is_top_level_page(string page_name) {
            switch (page_name) {
                case "network": case "apps": case "users": case "accounts":
                case "displays": case "region": case "datetime": case "desktop":
                case "sound": case "bluetooth": case "keyboard": case "developer":
                case "accessibility": case "plugins": case "performance": case "system":
                case "autostart":
                    return true;
            }
            return false;
        }

        private string get_page_icon(string page_name) {
            switch (page_name) {
                case "network": return "network-wireless-symbolic";
                case "apps": return "view-app-grid-symbolic";
                case "users": return "system-users-symbolic";
                case "accounts": return "avatar-default-symbolic";
                case "displays": return "video-display-symbolic";
                case "region": return "preferences-desktop-locale-symbolic";
                case "datetime": return "preferences-system-time-symbolic";
                case "desktop": return "preferences-desktop-wallpaper-symbolic";
                case "sound": return "audio-volume-high-symbolic";
                case "bluetooth": return "bluetooth-active-symbolic";
                case "keyboard": return "input-keyboard-symbolic";
                case "developer": return "applications-engineering-symbolic";
                case "autostart": return "system-run-symbolic";
                case "accessibility": return "preferences-desktop-accessibility-symbolic";
                case "plugins": return "emblem-system-symbolic";
                case "performance": return "power-profile-performance-symbolic";
                case "system": return "computer-symbolic";
            }
            return "preferences-system-symbolic";
        }

        private string[] get_searchable_pages() {
            return { "network", "apps", "autostart", "users", "accounts", "displays", "region", "datetime",
                     "desktop", "sound", "bluetooth", "keyboard", "developer", "accessibility",
                     "plugins", "performance", "system" };
        }

        private void setup_settings_search() {
            search_entry = new SearchEntry();
            search_entry.placeholder_text = _("Search Settings");
            search_entry.margin_bottom = 8;
            search_entry.search_changed.connect(update_search_results);
            nav_box.append(search_entry);

            search_results_box = new Box(Orientation.VERTICAL, 4);
            search_results_box.visible = false;
            nav_box.append(search_results_box);

            // Type-ahead: start typing anywhere in the window to focus search.
            realize.connect(() => {
                var root = get_root();
                if (root is Gtk.Widget)
                    search_entry.set_key_capture_widget((Gtk.Widget) root);
            });
        }

        private void ensure_search_index() {
            _search_items.clear();
            foreach (string page_name in get_searchable_pages()) {
                ensure_page_cached(page_name);
                if (!_page_cache.has_key(page_name)) continue;
                var page = _page_cache[page_name] as SettingsPage;
                if (page == null) continue;
                collect_page_search_items(page_name, page);
            }
        }

        private void ensure_page_cached(string page_name) {
            if (_page_cache.has_key(page_name)) return;
            build_page(page_name, false);
        }

        private void collect_page_search_items(string page_name, SettingsPage page) {
            string icon_name = get_page_icon(page_name);
            bool has_same_title_child = false;

            foreach (Widget group_widget in page.get_groups()) {
                var group = group_widget as Singularity.Widgets.PreferencesGroup;
                if (group == null) continue;
                string group_title = group.title;
                if (group_title.down() == page.page_title.down()) has_same_title_child = true;
                if (group_title != "" && group_title.down() != page.page_title.down()) {
                    _search_items.add(new SettingsSearchItem(page_name, page.page_title, icon_name,
                        group_title, group.description, ""));
                }
                foreach (Widget row_widget in group.get_rows()) {
                    var row = row_widget as Singularity.Widgets.ActionRow;
                    if (row == null) continue;
                    string row_title = row.title;
                    if (row_title == "") continue;
                    if (row_title.down() == page.page_title.down()) has_same_title_child = true;
                    _search_items.add(new SettingsSearchItem(page_name, page.page_title, icon_name,
                        row_title, row.subtitle, group_title));
                }
            }

            if (!has_same_title_child) {
                _search_items.add(new SettingsSearchItem(page_name, page.page_title, icon_name,
                    page.page_title, "", ""));
            }
        }

        private bool search_matches(SettingsSearchItem item, string query) {
            string haystack = "%s %s %s %s".printf(item.title, item.subtitle, item.group, item.page_title).down();
            return haystack.contains(query);
        }

        private void clear_search_results() {
            Widget? child = search_results_box.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                search_results_box.remove(child);
                child = next;
            }
        }

        private void update_search_results() {
            string query = search_entry.text.strip().down();
            clear_search_results();
            search_results_box.visible = query != "";
            if (query == "") return;

            ensure_search_index();
            int count = 0;
            var seen = new Gee.HashSet<string>();
            foreach (var item in _search_items) {
                if (!search_matches(item, query)) continue;
                string key = "%s|%s|%s|%s".printf(item.page_name, item.title.down(), item.subtitle.down(), item.group.down());
                if (seen.contains(key)) continue;
                seen.add(key);
                search_results_box.append(create_search_result_row(item));
                count++;
                if (count >= 12) break;
            }

            if (count == 0) {
                var empty = new Label(_("No Results"));
                empty.add_css_class("dim-label");
                empty.margin_top = 6;
                empty.margin_bottom = 6;
                search_results_box.append(empty);
            }
        }

        private Widget create_search_result_row(SettingsSearchItem item) {
            var row = new Box(Orientation.HORIZONTAL, 10);
            row.add_css_class("sidebar-row");
            row.add_css_class("settings-search-result");

            var icon = new Image.from_icon_name(item.icon_name);
            icon.pixel_size = 18;
            row.append(icon);

            var labels = new Box(Orientation.VERTICAL, 2);
            labels.hexpand = true;
            var title = new Label(item.title);
            title.halign = Align.START;
            title.ellipsize = Pango.EllipsizeMode.END;
            labels.append(title);

            string path = item.group != "" ? "%s / %s".printf(item.page_title, item.group) : item.page_title;
            var sub = new Label(path);
            sub.add_css_class("dim-label");
            sub.halign = Align.START;
            sub.ellipsize = Pango.EllipsizeMode.END;
            labels.append(sub);
            row.append(labels);

            var gesture = new GestureClick();
            gesture.released.connect(() => {
                navigate_to(item.page_name);
                search_entry.text = "";
            });
            row.add_controller(gesture);
            return row;
        }

        private void notify_wallpaper_imported() {
            if (_page_cache.has_key("desktop")) {
                var desktop_page = _page_cache["desktop"] as DesktopPage;
                if (desktop_page != null) desktop_page.refresh_after_import();
            }
        }

        private Widget? build_page(string page_name, bool connect_navigation) {
            Widget? page = null;
            switch (page_name) {
                case "network": page = new NetworkPage(this); break;
                case "apps": page = new Singularity.SidebarPages.AppsPage(app, this); break;
                case "users": page = new Singularity.SidebarPages.UsersPage(this); break;
                case "accounts": page = new Singularity.SidebarPages.AccountsPage(this); break;
                case "displays": page = new Singularity.SidebarPages.DisplaysPage(this); break;
                case "region": page = new Singularity.SidebarPages.RegionPage(this); break;
                case "datetime": page = new Singularity.SidebarPages.DateTimePage(this); break;
                case "desktop": page = new DesktopPage(this); break;
                case "sound": page = new SoundPage(this); break;
                case "bluetooth": page = new Singularity.SidebarPages.BluetoothPage(this); break;
                case "keyboard": page = new KeyboardPage(this); break;
                case "developer": page = new DeveloperPage(this); break;
                case "autostart": page = new Singularity.SidebarPages.AutostartPage(this); break;
                case "accessibility": page = new Singularity.SidebarPages.AccessibilityPage(this); break;
                case "plugins": page = new Singularity.PluginsPage(this); break;
                case "performance": page = new Singularity.SidebarPages.PerformancePage(this); break;
                case "system": page = new Singularity.SidebarPages.SystemPage(this); break;
                case "wallpaper-browser":
                    string[] roots = DesktopPage.compute_collection_roots();
                    page = new Singularity.Shell.WallpaperOcsBrowserPage(this, roots);
                    var browser = page as Singularity.Shell.WallpaperOcsBrowserPage;
                    if (browser != null)
                        browser.imported.connect(notify_wallpaper_imported);
                    break;
            }

            if (page == null) return null;

            var sp = page as SettingsPage;
            if (sp != null) {
                sp.show_top_spacer(split_mode && !folded);
                if (split_mode && is_top_level_page(page_name)) {
                    sp.back_btn.visible = false;
                } else {
                    sp.back_btn.visible = true;
                    // This drill-down page returns to Desktop, not Settings home.
                    if (page_name != "wallpaper-browser") {
                        sp.back_clicked.connect(() => { go_home(); });
                    }
                }
                sp.adaptive_back_btn.clicked.connect(() => {
                    main_stack.visible_child_name = "sidebar";
                });
            }

            settings_stack.add_named(page, page_name);
            _page_cache[page_name] = page;
            return page;
        }

        public void navigate_to(string page_name) {
            Widget? page = null;

            // Reuse cached pages - they self-update via GSettings listeners.
            if (_page_cache.has_key(page_name)) {
                page = _page_cache[page_name];
                // Re-add to stack if it was removed (e.g. by go_home cleanup).
                if (settings_stack.get_child_by_name(page_name) == null) {
                    settings_stack.add_named(page, page_name);
                }
            } else {
                page = build_page(page_name, true);
            }

            if (page != null) {
                // Update adaptive back button visibility - folded state may have changed.
                var sp = page as SettingsPage;
                if (sp != null) sp.adaptive_back_btn.visible = folded;
            }

            settings_stack.visible_child_name = page_name;
            if (folded) main_stack.visible_child_name = "content";
        }

        public void open_subpage(Widget page, string name) {
            if (settings_stack.get_child_by_name(name) != null) {
                settings_stack.remove(settings_stack.get_child_by_name(name));
            }
            var sp = page as SettingsPage;
            if (sp != null) {
                sp.adaptive_back_btn.visible = folded;
                sp.adaptive_back_btn.clicked.connect(() => {
                    main_stack.visible_child_name = "sidebar";
                });
            }
            settings_stack.add_named(page, name);
            settings_stack.visible_child_name = name;
            if (folded) main_stack.visible_child_name = "content";
        }

        public void go_home() {
            if (search_entry != null) search_entry.text = "";
            if (split_mode) {
                if (folded) main_stack.visible_child_name = "sidebar";
                else navigate_to("desktop");
            } else {
                // For non-split mode: just go back to the home list.
                // Cached pages stay in the stack (hidden) - no need to remove them.
                settings_stack.visible_child_name = "home";
            }
        }

        // Show or hide the Developer nav row to match the developer-mode toggle.
        private void update_developer_nav_row() {
            bool on = _desktop_settings.get_boolean("developer-mode");
            if (on && _developer_nav_row == null) {
                _developer_nav_row = create_settings_row(_("Developer"), "applications-engineering-symbolic", "developer");
                nav_box.insert_child_after(_developer_nav_row, _keyboard_nav_row);
            } else if (!on && _developer_nav_row != null) {
                nav_box.remove(_developer_nav_row);
                _developer_nav_row = null;
            }
        }

        private Widget create_settings_row(string label, string icon_name, string target_page) {
            var row = new Box(Orientation.HORIZONTAL, 12);
            row.add_css_class("sidebar-row");
            var icon = new Image.from_icon_name(icon_name);
            icon.pixel_size = 20;
            row.append(icon);
            var lbl = new Label(label);
            lbl.hexpand = true;
            lbl.halign = Align.START;
            row.append(lbl);
            var arrow = new Image.from_icon_name("go-next-symbolic");
            arrow.add_css_class("dim-label");
            arrow.pixel_size = 16;
            row.append(arrow);
            var gesture = new GestureClick();
            gesture.released.connect(() => {
                navigate_to(target_page);
            });
            row.add_controller(gesture);
            return row;
        }
    }
}
