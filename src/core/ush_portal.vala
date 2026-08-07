namespace Singularity.Shell {

    [DBus (name = "io.github.singularityos_lab.ush.Portal1")]
    public class UshPortalService : Object {

        public async string show_permission(string category, string resource, string reason) throws Error {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return "deny";

            string decision = "deny";

            var dlg = new Singularity.Widgets.ConfirmDialog(app,
                _("Permission Request"),
                "dialog-password-symbolic",
                "%s\n\n%s: %s".printf(reason, category, resource),
                _("Allow"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);

            var scope_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            var once = new Gtk.CheckButton.with_label(_("Just this once"));
            var session = new Gtk.CheckButton.with_label(_("For this session"));
            session.set_group(once);
            var always = new Gtk.CheckButton.with_label(_("Always"));
            always.set_group(once);
            once.active = true;
            scope_box.append(once);
            scope_box.append(session);
            scope_box.append(always);
            dlg.custom_area.append(scope_box);

            dlg.response.connect((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) {
                    if (always.active) decision = "allow_always";
                    else if (session.active) decision = "allow_session";
                    else decision = "allow";
                }
                show_permission.callback();
            });
            dlg.present();
            yield;
            return decision;
        }

        public async bool show_confirm(string title, string body) throws Error {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return false;

            bool granted = false;
            var dlg = new Singularity.Widgets.ConfirmDialog(app,
                title, "dialog-question-symbolic", body,
                _("Confirm"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.response.connect((r) => {
                granted = (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY);
                show_confirm.callback();
            });
            dlg.present();
            yield;
            return granted;
        }
    }
}
