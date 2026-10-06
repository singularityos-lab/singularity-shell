using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class PrivacyCategoryPage : SettingsPage {
        private SettingsView view;
        private PrivacyCategory category;
        private Privacy.Source? source = null;
        private PreferencesGroup? live_group = null;
        private PreferencesGroup apps_group;
        private StatusPage unavailable;
        private SwitchRow? master_row = null;
        private PreferencesGroup? master_group = null;
        private GLib.Settings settings;
        private uint poll_id = 0;
        private bool loading = false;

        public PrivacyCategoryPage(SettingsView view, PrivacyCategory category) {
            base(category.title);
            this.view = view;
            this.category = category;
            back_clicked.connect(() => view.navigate_to("privacy"));
            settings = new GLib.Settings("dev.sinty.desktop");

            unavailable = new StatusPage();
            unavailable.icon_name = category.large_icon;
            unavailable.visible = false;
            add_widget(unavailable);

            if (category.master_key != "" && settings.settings_schema.has_key(category.master_key)) {
                master_group = new PreferencesGroup(category.master_title);
                master_row = new SwitchRow(category.master_subtitle, null, settings.get_boolean(category.master_key));
                settings.bind(category.master_key, master_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
                master_group.add_row(master_row);
                add_group(master_group);
                settings.changed[category.master_key].connect(() => reload.begin());
            }

            if (category.id == "camera" || category.id == "microphone") {
                live_group = new PreferencesGroup(_("In Use Now"));
                live_group.visible = false;
                add_group(live_group);
            } else if (category.id == "background") {
                live_group = new PreferencesGroup(_("Running in Background"),
                    _("Stop an app to close it until you open it again."));
                live_group.visible = false;
                add_group(live_group);
                BackgroundApps.get_default().changed.connect(() => refresh_live.begin());
            }

            apps_group = new PreferencesGroup(_("Apps"), category.description);
            add_group(apps_group);

            if (category.id != "files") {
                source = Privacy.Source.create(category.id);
                source.changed.connect(() => reload.begin());
            }
            Sandbox.Backends.get_default().changed.connect(() => reload.begin());

            map.connect(() => {
                reload.begin();
                if (live_group != null && poll_id == 0) poll_id = Timeout.add_seconds(3, () => {
                    refresh_live.begin();
                    return Source.CONTINUE;
                });
            });
            unmap.connect(() => {
                if (poll_id != 0) Source.remove(poll_id);
                poll_id = 0;
            });
            reload.begin();
        }

        private async void reload() {
            if (loading) return;
            loading = true;
            if (category.id == "location" && !(yield location_service_available())) {
                show_unavailable(_("Location Services Unavailable"),
                    _("This computer has no location service. Install GeoClue to let apps find where you are."));
                loading = false;
                return;
            }
            bool store = source == null || !source.needs_store || (yield PermissionStore.get_default().probe());
            var sandboxed = yield sandboxed_rows();
            if (!store && sandboxed.length == 0) {
                show_unavailable(_("Permissions Unavailable"),
                    _("The permission store of the desktop portal is not running, so app permissions cannot be read."));
                loading = false;
                return;
            }
            unavailable.visible = false;
            apps_group.visible = true;
            if (master_group != null) master_group.visible = true;

            apps_group.clear();
            int count = 0;
            if (category.id == "files") {
                count = yield load_files();
            } else {
                bool master_off = master_row != null && !master_row.active;
                if (store) {
                    foreach (var grant in yield source.load()) {
                        var row = new GrantRow(grant, source, master_off, false);
                        string app_id = grant.app_id;
                        row.activated.connect(() => PermissionRows.open_app(view, app_id, "privacy-" + category.id));
                        row.updated.connect(() => reload.begin());
                        apps_group.add_row(row);
                        count++;
                    }
                }
                foreach (var row in sandboxed) {
                    apps_group.add_row(row);
                    count++;
                }
            }
            if (count == 0) {
                apps_group.add_row(PermissionRows.empty_row(category.large_icon, category.empty_title,
                    category.empty_description));
            }
            yield refresh_live();
            loading = false;
        }

        private async SandboxRow[] sandboxed_rows() {
            SandboxRow[] rows = {};
            if (category.id == "files") return rows;
            var backends = Sandbox.Backends.get_default();
            foreach (var app in yield backends.apps()) {
                var backend = backends.find(app.backend);
                if (backend == null) continue;
                var permission = yield backend.category_permission(app, category.id);
                if (permission == null || (!permission.enabled && !permission.overridden)) continue;
                var row = new SandboxRow(backend, app, permission, true);
                row.activatable = true;
                row.add_suffix(PermissionRows.chevron());
                var target = app;
                row.activated.connect(() => PermissionRows.open_app(view, target.portal_app_id != "" ? target.portal_app_id : target.id,
                    "privacy-" + category.id));
                row.updated.connect(() => reload.begin());
                rows += row;
            }
            return rows;
        }

        private void show_unavailable(string title, string description) {
            unavailable.title = title;
            unavailable.description = description;
            unavailable.visible = true;
            apps_group.visible = false;
            if (live_group != null) live_group.visible = false;
            if (master_group != null) master_group.visible = false;
        }

        private async bool location_service_available() {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var owner = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new Variant("(s)", "org.freedesktop.GeoClue2"), new VariantType("(b)"),
                    DBusCallFlags.NONE, 2000, null);
                if (owner.get_child_value(0).get_boolean()) return true;
                var names = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, new VariantType("(as)"), DBusCallFlags.NONE, 2000, null);
                foreach (string name in names.get_child_value(0).get_strv()) {
                    if (name == "org.freedesktop.GeoClue2") return true;
                }
            } catch (Error e) {
            }
            return false;
        }

        private async int load_files() {
            int count = 0;
            var backends = Sandbox.Backends.get_default();
            foreach (var app in yield backends.apps(true)) {
                var backend = backends.find(app.backend);
                if (backend == null) continue;
                var permissions = yield backend.permissions(app);
                var row = new ActionRow(app.display_name, AppPermissions.summary(permissions, Sandbox.Group.FILES));
                row.add_prefix(PermissionRows.app_icon(app.portal_app_id != "" ? app.portal_app_id : app.id));
                row.add_suffix(PermissionRows.badge(backend.label));
                row.add_suffix(PermissionRows.chevron());
                row.activatable = true;
                var target = app;
                row.activated.connect(() => {
                    var page = new AppSandboxPage(backend, target, Sandbox.Group.FILES);
                    page.back_clicked.connect(() => view.navigate_to("privacy-files"));
                    page.permissions_changed.connect(() => reload.begin());
                    view.open_subpage(page, "privacy-files-app");
                });
                apps_group.add_row(row);
                count++;
            }
            return count;
        }

        private async void refresh_live() {
            if (live_group == null) return;
            live_group.clear();
            int count = 0;
            if (category.id == "camera" || category.id == "microphone") {
                PrivacyInUse[] clients = category.id == "camera" ? yield PrivacyInUse.camera() : yield PrivacyInUse.microphone();
                foreach (var client in clients) {
                    var row = live_row(client.app_id, client.name,
                        category.id == "camera" ? _("Using a camera now") : _("Recording sound now"));
                    live_group.add_row(row);
                    count++;
                }
            } else {
                var background = BackgroundApps.get_default();
                yield background.start();
                foreach (var app in background.list()) {
                    var row = live_row(app.app_id, app.display_name,
                        app.message != "" ? app.message : _("No open windows"));
                    var stop = new Button.with_label(_("Stop"));
                    stop.valign = Align.CENTER;
                    var target = app;
                    stop.clicked.connect(() => {
                        stop.sensitive = false;
                        background.stop.begin(target, (obj, res) => {
                            background.stop.end(res);
                            background.refresh.begin();
                        });
                    });
                    row.add_suffix(stop);
                    live_group.add_row(row);
                    count++;
                }
            }
            live_group.visible = count > 0;
        }

        private ActionRow live_row(string? app_id, string name, string what) {
            string title = app_id != null && app_id != "" ? Privacy.Apps.display_name(app_id) : name;
            var row = new ActionRow(title != "" ? title : _("Unknown App"), what);
            row.add_prefix(PermissionRows.app_icon(app_id ?? ""));
            if (app_id != null && app_id != "" && PermissionRows.app_info_for(app_id) != null) {
                row.activatable = true;
                string target = app_id;
                row.activated.connect(() => PermissionRows.open_app(view, target, "privacy-" + category.id));
            } else {
                row.activatable = false;
            }
            return row;
        }
    }
}
