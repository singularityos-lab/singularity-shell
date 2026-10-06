using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AppPermissions : Object {
        public Sandbox.App? sandboxed = null;
        public Sandbox.Backend? backend = null;
        public string[] app_ids = {};

        public static async AppPermissions resolve(AppInfo info) {
            var result = new AppPermissions();
            string desktop_id = info.get_id() ?? "";
            var backends = Sandbox.Backends.get_default();
            yield backends.apps();
            KeyFile? entry = null;
            var desktop = info as DesktopAppInfo;
            if (desktop != null && desktop.get_filename() != null) {
                entry = new KeyFile();
                try {
                    entry.load_from_file(desktop.get_filename(), KeyFileFlags.NONE);
                } catch (Error e) {
                    entry = null;
                }
            }
            result.sandboxed = backends.app_for_desktop(desktop_id, entry);
            string[] ids = {};
            if (result.sandboxed != null) {
                result.backend = backends.find(result.sandboxed.backend);
                if (result.sandboxed.portal_app_id != "") ids += result.sandboxed.portal_app_id;
                if (!(result.sandboxed.id in ids)) ids += result.sandboxed.id;
            }
            string bare = desktop_id.has_suffix(".desktop") ? desktop_id.substring(0, desktop_id.length - 8) : desktop_id;
            if (bare != "" && !(bare in ids)) ids += bare;
            result.app_ids = ids;
            return result;
        }

        public static string summary(Sandbox.Permission[] permissions, Sandbox.Group group) {
            int on = 0;
            int total = 0;
            string[] names = {};
            foreach (var permission in permissions) {
                if (permission.group != group) continue;
                total++;
                if (!permission.enabled) continue;
                on++;
                if (names.length < 2) {
                    names += permission.group == Sandbox.Group.FILES && !permission.revocable
                        ? Sandbox.Catalog.describe_filesystem(permission.key) : permission.label;
                }
            }
            if (group == Sandbox.Group.ENVIRONMENT) {
                return ngettext("%d variable", "%d variables", (ulong) total).printf(total);
            }
            if (on == 0) return _("Nothing allowed");
            if (group == Sandbox.Group.FILES || group == Sandbox.Group.SESSION_BUS || group == Sandbox.Group.SYSTEM_BUS) {
                if (on > names.length) {
                    return ngettext("%s and %d more", "%s and %d more", (ulong) (on - names.length))
                        .printf(string.joinv(", ", names), on - names.length);
                }
                return string.joinv(", ", names);
            }
            return ngettext("%d of %d allowed", "%d of %d allowed", (ulong) total).printf(on, total);
        }
    }

    public delegate void GroupActivated();

    public class AppSandboxOverviewPage : SettingsPage {
        private SettingsView view;
        private Sandbox.Backend backend;
        private Sandbox.App app;
        private PreferencesGroup groups;

        public signal void permissions_changed();

        public AppSandboxOverviewPage(SettingsView view, Sandbox.Backend backend, Sandbox.App app) {
            base(_("Other Permissions"));
            this.view = view;
            this.backend = backend;
            this.app = app;
            back_btn.visible = true;
            groups = new PreferencesGroup(app.display_name,
                _("The app runs in a %s sandbox. These are the rest of its limits.").printf(backend.label));
            add_group(groups);
            reload.begin();
        }

        private async void reload() {
            groups.clear();
            var permissions = yield backend.permissions(app);
            foreach (var group in Sandbox.Group.all()) {
                if (group == Sandbox.Group.FILES || group == Sandbox.Group.NETWORK) continue;
                bool present = false;
                foreach (var permission in permissions) {
                    if (permission.group == group) present = true;
                }
                if (!present) continue;
                var target = group;
                groups.add_row(AppSandboxPage.group_row(permissions, group, () => {
                    var page = new AppSandboxPage(backend, app, target);
                    page.back_clicked.connect(() => view.show_page_name("app-details-sandbox-all"));
                    page.permissions_changed.connect(() => {
                        permissions_changed();
                        reload.begin();
                    });
                    view.open_subpage(page, "app-details-sandbox");
                }));
            }
        }
    }

    public class AppSandboxPage : SettingsPage {
        public static ActionRow group_row(Sandbox.Permission[] permissions, Sandbox.Group group, owned GroupActivated activated) {
            var row = new ActionRow(Sandbox.Catalog.group_title(group), AppPermissions.summary(permissions, group),
                group_icon(group));
            row.activatable = true;
            row.add_suffix(PermissionRows.chevron());
            row.activated.connect(() => activated());
            return row;
        }

        public static string group_icon(Sandbox.Group group) {
            switch (group) {
                case Sandbox.Group.FILES: return "folder-symbolic";
                case Sandbox.Group.NETWORK: return "network-wired-symbolic";
                case Sandbox.Group.DEVICES: return "drive-harddisk-usb-symbolic";
                case Sandbox.Group.SOCKETS: return "video-display-symbolic";
                case Sandbox.Group.FEATURES: return "applications-engineering-symbolic";
                case Sandbox.Group.SESSION_BUS: return "system-run-symbolic";
                case Sandbox.Group.SYSTEM_BUS: return "computer-symbolic";
                default: return "utilities-terminal-symbolic";
            }
        }


        private Sandbox.Backend backend;
        private Sandbox.App app;
        private Sandbox.Group group;
        private PreferencesGroup rows_group;
        private bool loading = false;

        public signal void permissions_changed();

        public AppSandboxPage(Sandbox.Backend backend, Sandbox.App app, Sandbox.Group group) {
            base(Sandbox.Catalog.group_title(group));
            this.backend = backend;
            this.app = app;
            this.group = group;
            back_btn.visible = true;

            rows_group = new PreferencesGroup(app.display_name, description());
            add_group(rows_group);
            reload.begin();
        }

        private string description() {
            switch (group) {
                case Sandbox.Group.FILES:
                    return _("Folders the app can open without asking. Files you pick in the file chooser are always allowed.");
                case Sandbox.Group.SESSION_BUS:
                case Sandbox.Group.SYSTEM_BUS:
                    return _("Services the app can reach directly. Turning one off can break features that use it.");
                case Sandbox.Group.ENVIRONMENT:
                    return _("Variables set inside the sandbox.");
                default:
                    return _("Turn off what the app should not reach. A reset returns to what the app asked for.");
            }
        }

        public async void reload() {
            if (loading) return;
            loading = true;
            rows_group.clear();
            int count = 0;
            foreach (var permission in yield backend.permissions(app)) {
                if (permission.group != group) continue;
                var row = new SandboxRow(backend, app, permission, false);
                row.updated.connect(() => {
                    permissions_changed();
                    reload.begin();
                });
                rows_group.add_row(row);
                count++;
            }
            if (count == 0) {
                rows_group.add_row(PermissionRows.empty_row("dialog-information", _("Nothing Here"),
                    _("The sandbox does not use this kind of permission.")));
            }
            loading = false;
        }
    }
}
