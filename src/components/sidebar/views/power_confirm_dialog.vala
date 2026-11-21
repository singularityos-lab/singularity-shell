using Gtk;

namespace Singularity {

    public class PowerConfirmDialog : Singularity.Shell.ShellConfirmDialog {
        public delegate void ConfirmCallback();

        private ConfirmCallback _on_confirm;

        public PowerConfirmDialog(
            Gtk.Application app,
            string title,
            string icon_name,
            string description,
            string confirm_label,
            owned ConfirmCallback on_confirm,
            bool destructive = true
        ) {
            base(app, title, icon_name, description, confirm_label,
                destructive ? Singularity.Widgets.ConfirmDialog.ActionStyle.DESTRUCTIVE
                            : Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            _on_confirm = (owned) on_confirm;
            response.connect((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) _on_confirm();
            });
        }
    }
}
