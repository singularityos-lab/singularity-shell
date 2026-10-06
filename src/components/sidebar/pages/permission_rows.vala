using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class PermissionRows : Object {
        public static Image app_icon(string app_id) {
            var icon = new Image.from_gicon(Privacy.Apps.icon(app_id));
            icon.pixel_size = 24;
            icon.margin_end = 12;
            return icon;
        }

        public static Image chevron() {
            var image = new Image.from_icon_name("go-next-symbolic");
            image.pixel_size = 12;
            image.add_css_class("dim-label");
            image.valign = Align.CENTER;
            return image;
        }

        public static string category_title(string category) {
            var found = PrivacyCategory.find(category);
            return found != null ? found.title : category;
        }

        public static string category_icon(string category) {
            var found = PrivacyCategory.find(category);
            return found != null ? found.icon_name : "preferences-system-privacy-symbolic";
        }

        public static DesktopAppInfo? app_info_for(string any_id) {
            if (any_id == "") return null;
            var sandboxed = Sandbox.Backends.get_default().cached_app(any_id);
            if (sandboxed != null && sandboxed.desktop_id != "") {
                var info = new DesktopAppInfo(sandboxed.desktop_id);
                if (info != null) return info;
            }
            string desktop_id = any_id.has_suffix(".desktop") ? any_id : any_id + ".desktop";
            return new DesktopAppInfo(desktop_id);
        }

        public static bool open_app(SettingsView view, string any_id, string back_page) {
            var info = app_info_for(any_id);
            if (info == null) return false;
            view.open_app_details(info, back_page);
            return true;
        }

        public static Widget empty_row(string icon_name, string title, string description) {
            var empty = new StatusPage();
            empty.compact = true;
            empty.icon_name = icon_name;
            empty.title = title;
            empty.description = description;
            var row = new PreferencesRow();
            row.activatable = false;
            row.set_child(empty);
            return row;
        }

        public static string source_label(Sandbox.App app) {
            var backend = Sandbox.Backends.get_default().find(app.backend);
            return backend != null ? backend.label : app.backend;
        }

        public static Label badge(string text) {
            var label = new Label(text);
            label.add_css_class("caption");
            label.add_css_class("dim-label");
            label.add_css_class("sandbox-badge");
            label.valign = Align.CENTER;
            return label;
        }
    }

    public class GrantRow : ActionRow {
        public Privacy.Grant grant { get; construct; }
        public Privacy.Source source { get; construct; }

        public signal void updated();

        public GrantRow(Privacy.Grant grant, Privacy.Source source, bool master_off, bool app_view) {
            Object(grant: grant, source: source);
            if (app_view) {
                title = PermissionRows.category_title(grant.category);
                subtitle = grant.detail;
                if (grant.category == "shortcuts") {
                    title = grant.title;
                    int comma = grant.detail.index_of(", ");
                    subtitle = comma >= 0 ? _("Global shortcut, %s").printf(grant.detail.substring(comma + 2))
                        : _("Global shortcut");
                }
                icon_name = PermissionRows.category_icon(grant.category);
            } else {
                title = grant.title;
                subtitle = grant.detail;
                add_prefix(PermissionRows.app_icon(grant.app_id));
            }
            activatable = false;
            if (grant.has_switch) {
                var toggle = new Switch();
                toggle.valign = Align.CENTER;
                toggle.active = grant.active;
                toggle.sensitive = !master_off;
                toggle.tooltip_text = _("Allow");
                toggle.notify["active"].connect(() => {
                    if (toggle.active == grant.active) return;
                    grant.active = toggle.active;
                    source.set_allowed.begin(grant, toggle.active, (obj, res) => {
                        if (!source.set_allowed.end(res)) {
                            grant.active = !toggle.active;
                            toggle.active = grant.active;
                        }
                        updated();
                    });
                });
                add_suffix(toggle);
            }
            if (!app_view) {
                activatable = true;
                if (grant.has_switch) {
                    add_suffix(PermissionRows.chevron());
                    return;
                }
            }
            if (grant.can_remove) {
                var remove = new Button.from_icon_name("user-trash-symbolic");
                remove.has_frame = false;
                remove.valign = Align.CENTER;
                remove.tooltip_text = grant.has_switch ? _("Forget and ask again") : _("Remove");
                remove.clicked.connect(() => {
                    confirmation_requested(grant.has_switch ? _("Forget") : _("Remove"), _("Cancel"),
                        ConfirmationSuggestedAction.CANCEL);
                });
                confirmed.connect(() => source.remove.begin(grant, (obj, res) => {
                    source.remove.end(res);
                    updated();
                }));
                add_suffix(remove);
            }
            if (!app_view) add_suffix(PermissionRows.chevron());
        }
    }

    public class SandboxRow : ActionRow {
        public Sandbox.Backend backend { get; construct; }
        public Sandbox.App app { get; construct; }
        public Sandbox.Permission permission { get; construct; }

        public signal void updated();

        public SandboxRow(Sandbox.Backend backend, Sandbox.App app, Sandbox.Permission permission, bool app_title) {
            Object(backend: backend, app: app, permission: permission);
            activatable = false;
            if (app_title) {
                title = app.display_name;
                subtitle = _("%s, %s sandbox").printf(permission.label, backend.label);
                add_prefix(PermissionRows.app_icon(app.portal_app_id != "" ? app.portal_app_id : app.id));
            } else {
                title = permission.label;
                string detail = permission.detail != permission.key || permission.group != Sandbox.Group.FILES
                    ? permission.detail : "";
                if (permission.kind == Sandbox.Kind.BUS_POLICY) detail = bus_policy_label(permission.value);
                if (permission.overridden && !permission.revocable) {
                    subtitle = detail != "" ? _("%s, changed by you").printf(detail) : _("Changed by you");
                } else {
                    subtitle = detail;
                }
            }
            if (permission.overridden && !permission.revocable && permission.kind != Sandbox.Kind.VALUE) {
                var reset = new Button.from_icon_name("edit-undo-symbolic");
                reset.has_frame = false;
                reset.valign = Align.CENTER;
                reset.tooltip_text = _("Reset to Default");
                reset.clicked.connect(() => {
                    reset.sensitive = false;
                    backend.reset.begin(app, permission, (obj, res) => {
                        backend.reset.end(res);
                        updated();
                    });
                });
                add_suffix(reset);
            }
            if (permission.revocable) {
                var revoke = new Button.from_icon_name("user-trash-symbolic");
                revoke.has_frame = false;
                revoke.valign = Align.CENTER;
                revoke.tooltip_text = _("Revoke access");
                revoke.clicked.connect(() => {
                    confirmation_requested(_("Revoke"), _("Cancel"), ConfirmationSuggestedAction.CANCEL);
                });
                confirmed.connect(() => backend.reset.begin(app, permission, (obj, res) => {
                    backend.reset.end(res);
                    updated();
                }));
                add_suffix(revoke);
            } else if (permission.editable) {
                var toggle = new Switch();
                toggle.valign = Align.CENTER;
                toggle.active = permission.enabled;
                toggle.tooltip_text = _("Allow");
                toggle.notify["active"].connect(() => {
                    if (toggle.active == permission.enabled) return;
                    toggle.sensitive = false;
                    bool wanted = toggle.active;
                    backend.set_enabled.begin(app, permission, wanted, (obj, res) => {
                        bool ok = backend.set_enabled.end(res);
                        toggle.sensitive = true;
                        if (!ok) toggle.active = permission.enabled;
                        else permission.enabled = wanted;
                        updated();
                    });
                });
                add_suffix(toggle);
            }
        }

        public static string bus_policy_label(string policy) {
            switch (policy) {
                case "own": return _("Can own this name");
                case "talk": return _("Can talk to this service");
                case "see": return _("Can see this service");
                case "none": return _("Blocked");
            }
            return policy;
        }
    }

    public class PrivacyInUse : Object {
        public string? app_id { get; set; default = null; }
        public string name { get; set; default = ""; }
        public string category { get; set; default = ""; }

        public static async PrivacyInUse[] camera() {
            CameraClient[] clients = {};
            foreach (var client in yield CameraClients.query()) clients += client;
            return yield resolve(clients, "camera");
        }

        public static async PrivacyInUse[] microphone() {
            CameraClient[] clients = {};
            foreach (var client in yield MicrophoneClients.query()) clients += client;
            return yield resolve(clients, "microphone");
        }

        private static async PrivacyInUse[] resolve(CameraClient[] clients, string category) {
            bool unknown = false;
            foreach (var client in clients) {
                if ((client.app_id == null || client.app_id == "") && client.pid > 0) unknown = true;
            }
            if (unknown) {
                var backends = Sandbox.Backends.get_default();
                yield backends.apps();
                yield backends.refresh_runtime();
            }
            PrivacyInUse[] result = {};
            foreach (var client in clients) result += yield from_client(client, category);
            return result;
        }

        private static async PrivacyInUse from_client(CameraClient client, string category) {
            var item = new PrivacyInUse();
            item.name = client.name;
            item.category = category;
            item.app_id = client.app_id;
            if ((item.app_id == null || item.app_id == "") && client.pid > 0) {
                item.app_id = yield Sandbox.Backends.get_default().app_id_for_pid(client.pid);
            }
            if (item.app_id != null && item.app_id != "") Privacy.Usage.get_default().record(item.app_id, category);
            return item;
        }
    }
}
