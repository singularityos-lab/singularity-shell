namespace Singularity.Shell {

    [DBus (name = "dev.sinty.ush.Portal1")]
    public class UshPortalService : Object {
        private const uint PROMPT_TIMEOUT_SECONDS = 290;

        public async string show_permission(string category, string resource, string reason) throws Error {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return "deny";

            string decision = "deny";

            var dlg = new Singularity.Shell.ShellConfirmDialog(app,
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

            bool answered = false;
            dlg.response.connect((r) => {
                if (answered) return;
                answered = true;
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) {
                    if (always.active) decision = "allow_always";
                    else if (session.active) decision = "allow_session";
                    else decision = "allow";
                }
                show_permission.callback();
            });
            dlg.present();
            uint guard = 0;
            guard = Timeout.add_seconds(PROMPT_TIMEOUT_SECONDS, () => {
                guard = 0;
                if (!answered) {
                    answered = true;
                    dlg.close();
                    show_permission.callback();
                }
                return Source.REMOVE;
            });
            yield;
            if (guard != 0) Source.remove(guard);
            return decision;
        }

        public async bool show_confirm(string title, string body) throws Error {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return false;

            bool granted = false;
            var dlg = new Singularity.Shell.ShellConfirmDialog(app,
                title, "dialog-question-symbolic", body,
                _("Confirm"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            bool answered = false;
            dlg.response.connect((r) => {
                if (answered) return;
                answered = true;
                granted = (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY);
                show_confirm.callback();
            });
            dlg.present();
            uint guard = 0;
            guard = Timeout.add_seconds(PROMPT_TIMEOUT_SECONDS, () => {
                guard = 0;
                if (!answered) {
                    answered = true;
                    dlg.close();
                    show_confirm.callback();
                }
                return Source.REMOVE;
            });
            yield;
            if (guard != 0) Source.remove(guard);
            return granted;
        }

        public async bool show_choice(string title, string body, string allow_label, string block_label) throws Error {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return false;

            bool allowed = false;
            var dlg = new Singularity.Shell.ShellConfirmDialog(app,
                title, "dialog-warning", body,
                block_label, Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.set_secondary(allow_label);
            dlg.has_cancel = false;
            bool answered = false;
            dlg.response.connect((r) => {
                if (answered) return;
                answered = true;
                allowed = (r == Singularity.Widgets.ConfirmDialog.Response.SECONDARY);
                show_choice.callback();
            });
            dlg.present();
            dlg.focus_primary();
            uint guard = 0;
            guard = Timeout.add_seconds(PROMPT_TIMEOUT_SECONDS, () => {
                guard = 0;
                if (!answered) {
                    answered = true;
                    dlg.close();
                    show_choice.callback();
                }
                return Source.REMOVE;
            });
            yield;
            if (guard != 0) Source.remove(guard);
            return allowed;
        }
    }
}
