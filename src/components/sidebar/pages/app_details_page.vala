using Gtk;
using Gee;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AppDetailsPage : SettingsPage {
        private SingularityApp app;
        private AppInfo app_info;
        private SettingsView? view;
        private PreferencesGroup permissions_group;
        private PreferencesGroup sandbox_group;
        private AppPermissions? resolved = null;
        private Gee.ArrayList<Privacy.Source> sources = new Gee.ArrayList<Privacy.Source>();
        private Label source_badge;
        private bool loading = false;
        private bool dirty = false;

        public AppDetailsPage(SingularityApp app, AppInfo info, SettingsView? view = null, string back_page = "apps") {
            base(info.get_name());
            this.app = app;
            this.app_info = info;
            this.view = view;
            back_clicked.connect(() => {
                if (view != null && back_page != "apps") view.navigate_to(back_page);
                else app.open_settings_page("apps");
            });
            build_info_section();
            build_plugins_section();
            build_permissions_section();
            build_settings_section();
        }

        private void build_plugins_section() {
            if (view == null) return;
            string app_id = app_info.get_id() ?? "";
            int count = Singularity.AppPluginRows.item_count(app_id);
            if (count == 0) return;
            var subpages = new SettingsSubpages(view, this, "app-details");
            var page = subpages.create(_("Plugins"));
            var group = new PreferencesGroup(_("Plugins"), _("Sources and services this app can load"));
            page.add_group(group);
            var widgets = new PreferencesGroup(_("Widgets"), _("Widgets become active when you add them to the launcher"));
            page.add_group(widgets);
            Singularity.AppPluginRows.fill(group, app_id);
            Singularity.AppPluginRows.fill_widgets(widgets, app_id);
            var link = subpages.link(_("Plugins and Widgets"), ngettext("%d item", "%d items", count).printf(count),
                "application-x-addon-symbolic", page, "app-details-plugins");
            page.map.connect(() => {
                Singularity.AppPluginRows.fill(group, app_id);
                Singularity.AppPluginRows.fill_widgets(widgets, app_id);
            });
            var plugins_group = new PreferencesGroup();
            plugins_group.add_row(link);
            add_group(plugins_group);
        }

        private void build_info_section() {
            var group = new PreferencesGroup();
            var row = new PreferencesRow();
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            var icon = new Image.from_gicon(app_info.get_icon());
            icon.pixel_size = 64;
            box.append(icon);
            var vbox = new Box(Orientation.VERTICAL, 4);
            vbox.valign = Align.CENTER;
            vbox.hexpand = true;
            var desc = new Label(app_info.get_description() ?? app_info.get_name());
            desc.add_css_class("title");
            desc.xalign = 0;
            desc.wrap = true;
            desc.wrap_mode = Pango.WrapMode.WORD_CHAR;
            desc.lines = 2;
            desc.ellipsize = Pango.EllipsizeMode.END;
            vbox.append(desc);
            var exec = new Label(app_info.get_executable());
            exec.add_css_class("subtitle");
            exec.halign = Align.START;
            exec.ellipsize = Pango.EllipsizeMode.MIDDLE;
            vbox.append(exec);
            box.append(vbox);
            source_badge = PermissionRows.badge("");
            source_badge.visible = false;
            box.append(source_badge);
            row.set_child(box);
            group.add_row(row);
            add_group(group);
        }

        private void build_permissions_section() {
            permissions_group = new PreferencesGroup(_("Permissions"),
                _("What the app asked for through the desktop. Changes also show in Privacy."));
            permissions_group.visible = false;
            add_group(permissions_group);
            sandbox_group = new PreferencesGroup(_("Sandbox"));
            sandbox_group.visible = false;
            add_group(sandbox_group);
            foreach (string category in Privacy.Source.categories()) {
                var source = Privacy.Source.create(category);
                source.changed.connect(() => reload_permissions.begin());
                sources.add(source);
            }
            Sandbox.Backends.get_default().changed.connect(() => reload_permissions.begin());
            map.connect(() => reload_permissions.begin());
            reload_permissions.begin();
        }

        private async void reload_permissions() {
            if (loading) {
                dirty = true;
                return;
            }
            loading = true;
            do {
                dirty = false;
                if (resolved == null) resolved = yield AppPermissions.resolve(app_info);
                yield fill_permissions();
                yield fill_sandbox();
            } while (dirty);
            loading = false;
        }

        private async void fill_permissions() {
            permissions_group.clear();
            int count = 0;
            bool store = yield PermissionStore.get_default().probe();
            foreach (var source in sources) {
                if (source.needs_store && !store) continue;
                foreach (var grant in yield source.for_app(resolved.app_ids)) {
                    var row = new GrantRow(grant, source, false, true);
                    row.updated.connect(() => reload_permissions.begin());
                    permissions_group.add_row(row);
                    count++;
                }
            }
            if (resolved.sandboxed != null && resolved.backend != null) {
                foreach (var permission in yield resolved.backend.permissions(resolved.sandboxed)) {
                    if (permission.category == "" || !permission.enabled && !permission.overridden) continue;
                    var row = new SandboxRow(resolved.backend, resolved.sandboxed, permission, false);
                    row.title = PermissionRows.category_title(permission.category);
                    row.icon_name = PermissionRows.category_icon(permission.category);
                    row.subtitle = _("%s, set in the sandbox").printf(permission.label);
                    row.updated.connect(() => reload_permissions.begin());
                    permissions_group.add_row(row);
                    count++;
                }
            }
            if (count == 0 && resolved.sandboxed == null) {
                permissions_group.visible = false;
                return;
            }
            if (count == 0) {
                permissions_group.add_row(PermissionRows.empty_row("preferences-system-privacy",
                    _("No Permissions Requested"), _("Camera, location and other requests from this app appear here.")));
            }
            permissions_group.visible = true;
        }

        private async void fill_sandbox() {
            sandbox_group.clear();
            if (resolved.sandboxed == null || resolved.backend == null) {
                sandbox_group.visible = false;
                return;
            }
            var backend = resolved.backend;
            var sandboxed = resolved.sandboxed;
            source_badge.label = backend.label;
            source_badge.visible = true;
            sandbox_group.description = _("The app runs in a %s sandbox. These are the limits of that sandbox.").printf(backend.label);
            var permissions = yield backend.permissions(sandboxed);
            bool changed_any = false;
            int other_changes = 0;
            string[] other_titles = {};
            foreach (var group in Sandbox.Group.all()) {
                int n = 0;
                int changes = 0;
                foreach (var permission in permissions) {
                    if (permission.group != group) continue;
                    n++;
                    if (permission.overridden && !permission.revocable) changes++;
                }
                if (changes > 0) changed_any = true;
                if (n == 0) continue;
                if (group != Sandbox.Group.FILES && group != Sandbox.Group.NETWORK) {
                    other_changes += changes;
                    other_titles += Sandbox.Catalog.group_title(group);
                    continue;
                }
                var target = group;
                sandbox_group.add_row(AppSandboxPage.group_row(permissions, group, () => open_group(backend, sandboxed, target)));
            }
            if (other_titles.length > 0) {
                var more = new ActionRow(_("Other Permissions"), other_changes > 0
                    ? ngettext("%d changed by you", "%d changed by you", (ulong) other_changes).printf(other_changes)
                    : _("Devices, display, sound and services"), "view-more-symbolic");
                more.activatable = true;
                more.add_suffix(PermissionRows.chevron());
                more.activated.connect(() => open_overview(backend, sandboxed));
                sandbox_group.add_row(more);
            }
            if (changed_any) {
                var reset = new ActionRow(_("Reset All to Defaults"), _("Undo every change you made to this sandbox"),
                    "edit-undo-symbolic");
                reset.activatable = false;
                var button = new Button.with_label(_("Reset"));
                button.valign = Align.CENTER;
                button.clicked.connect(() => {
                    reset.confirmation_requested(_("Reset"), _("Cancel"), ConfirmationSuggestedAction.CANCEL);
                });
                reset.confirmed.connect(() => backend.reset_all.begin(sandboxed, (obj, res) => {
                    backend.reset_all.end(res);
                    reload_permissions.begin();
                }));
                reset.add_suffix(button);
                sandbox_group.add_row(reset);
            }
            sandbox_group.visible = true;
        }

        private void open_overview(Sandbox.Backend backend, Sandbox.App sandboxed) {
            if (view == null) return;
            var page = new AppSandboxOverviewPage(view, backend, sandboxed);
            page.back_clicked.connect(() => view.show_page_name("app-details"));
            page.permissions_changed.connect(() => reload_permissions.begin());
            view.open_subpage(page, "app-details-sandbox-all");
        }

        private void open_group(Sandbox.Backend backend, Sandbox.App sandboxed, Sandbox.Group group) {
            if (view == null) return;
            var page = new AppSandboxPage(backend, sandboxed, group);
            page.back_clicked.connect(() => view.show_page_name("app-details"));
            page.permissions_changed.connect(() => reload_permissions.begin());
            view.open_subpage(page, "app-details-sandbox");
        }

        private void build_settings_section() {
            var group = new PreferencesGroup(_("App Settings"));
            var loading_row = new PreferencesRow();
            var loading = new Label(_("Loading settings..."));
            loading.add_css_class("dim-label");
            loading.margin_top = 12;
            loading.margin_bottom = 12;
            loading_row.set_child(loading);
            group.add_row(loading_row);
            add_group(group);
            load_settings.begin(group, loading_row);
        }

        private async void load_settings(PreferencesGroup group, PreferencesRow loading_row) {
            string app_id = app_info.get_id();
            message("AppDetailsPage: Loading settings for app_id='%s'", app_id);
            var descriptor = Singularity.Core.AppSettingsLoader.load_for_app(app_id);
            if (descriptor == null) {
                group.remove_row(loading_row);
                var row = new PreferencesRow();
                var lbl = new Label(_("No settings available"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                row.set_child(lbl);
                group.add_row(row);
                return;
            }
            group.remove_row(loading_row);
            GLib.Settings base_settings = null;
            if (descriptor.schema_id != null) {
                try {
                    var source = SettingsSchemaSource.get_default();
                    var schema = source.lookup(descriptor.schema_id, true);
                    if (schema == null) {
                        warning("Schema %s not found", descriptor.schema_id);
                        var row = new PreferencesRow();
                        var err = new Label(_("Settings schema not found"));
                        err.add_css_class("error-label");
                        err.margin_top = 12;
                        err.margin_bottom = 12;
                        row.set_child(err);
                        group.add_row(row);
                        return;
                    }
                    base_settings = new GLib.Settings(descriptor.schema_id);
                } catch (Error e) {
                    warning("Failed to load settings schema: %s", e.message);
                    return;
                }
            }
            foreach (var item in descriptor.items) {
                var settings = item.schema_id != null ? Singularity.Core.AppSettingsLoader.settings_for(descriptor, item) : base_settings;
                if (settings == null) continue;
                if (!settings.settings_schema.has_key(item.key)) {
                    warning("AppDetailsPage: %s has no key %s", settings.schema_id, item.key);
                    continue;
                }
                string wanted = item.setting_type == "boolean" ? "b" : item.setting_type == "int" ? "i" : "s";
                if (settings.settings_schema.get_key(item.key).get_value_type().dup_string() != wanted) {
                    warning("AppDetailsPage: %s key %s is not a %s", settings.schema_id, item.key, item.setting_type);
                    continue;
                }
                if (item.setting_type == "boolean") {
                    var row = new SwitchRow(item.label, item.subtitle, settings.get_boolean(item.key));
                    settings.bind(item.key, row.switch_btn, "active", SettingsBindFlags.DEFAULT);
                    group.add_row(row);
                } else if (item.setting_type == "int") {
                    var row = new ActionRow(item.label, item.subtitle);
                    if (item.widget == "spin") {
                        var adj = new Adjustment(settings.get_int(item.key), item.min, item.max, 1, 10, 0);
                        var spin = new SpinButton(adj, 1, 0);
                        spin.valign = Align.CENTER;
                        settings.bind(item.key, spin, "value", SettingsBindFlags.DEFAULT);
                        row.add_suffix(spin);
                    } else {
                        var entry = new Entry();
                        entry.text = settings.get_int(item.key).to_string();
                        entry.valign = Align.CENTER;
                        entry.width_chars = 5;
                        entry.activate.connect(() => {
                            settings.set_int(item.key, int.parse(entry.text));
                        });
                        row.add_suffix(entry);
                    }
                    group.add_row(row);
                } else if (item.setting_type == "string") {
                    if (item.widget == "color-scheme-selector") {
                        Gee.ArrayList<Singularity.Widgets.ColorTheme> themes = null;
                        if (item.theme_set == "terminal" || item.theme_set == "leafs") {
                            themes = Singularity.Core.TerminalThemes.get_all();
                        } else if (item.theme_set == "edit" || item.theme_set == "write") {
                            themes = Singularity.Core.EditThemes.get_all();
                        } else {
                            // Fallback: try all providers and use the one that
                            // contains the current value, or the first non-empty
                            string current = settings.get_string(item.key);
                            var terminal_themes = Singularity.Core.TerminalThemes.get_all();
                            var edit_themes = Singularity.Core.EditThemes.get_all();
                            if (current != null && current != "") {
                                foreach (var t in terminal_themes)
                                    if (t.id == current) { themes = terminal_themes; break; }
                                if (themes == null) {
                                    foreach (var t in edit_themes)
                                        if (t.id == current) { themes = edit_themes; break; }
                                }
                            }
                            if (themes == null) themes = terminal_themes;
                        }
                        if (themes != null) {
                            var current = settings.get_string(item.key);
                            var row = new ColorSchemeRow(item.label, themes, current);
                            row.scheme_selected.connect((id) => {
                                settings.set_string(item.key, id);
                            });
                            settings.changed[item.key].connect(() => {
                                row.current_scheme = settings.get_string(item.key);
                            });
                            group.add_row(row);
                        }
                    } else if (item.widget == "combo") {
                        var current = settings.get_string(item.key);
                        var row = new SelectionRow.with_options(item.label, item.options, current);
                        if (item.subtitle != null) row.subtitle = item.subtitle;
                        row.selected.connect((id) => {
                            settings.set_string(item.key, id);
                        });
                        settings.changed[item.key].connect(() => {
                            row.current_value = settings.get_string(item.key);
                        });
                        group.add_row(row);
                    } else if (item.widget == "entry") {
                        var row = new EntryRow(item.label);
                        if (item.subtitle != null) row.subtitle = item.subtitle;
                        row.text = settings.get_string(item.key);
                        row.entry_changed.connect(() => {
                            if (settings.get_string(item.key) != row.text.strip()) settings.set_string(item.key, row.text.strip());
                        });
                        group.add_row(row);
                    }
                }
            }
        }
    }
}
