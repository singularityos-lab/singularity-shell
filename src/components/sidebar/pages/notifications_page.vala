using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class NotificationsPage : SettingsPage {

        public NotificationsPage() {
            base(_("Notifications"));

            var clear_btn = new Button.with_label(_("Clear All"));
            clear_btn.valign = Align.CENTER;
            clear_btn.tooltip_text = _("Remove every notification from the history");
            clear_btn.clicked.connect(() => {
                SystemMonitor.get_default().notifications.clear_history();
            });
            header.append(clear_btn);
            var manager = SystemMonitor.get_default().notifications;
            clear_btn.sensitive = manager.get_history().length() > 0;
            ulong h = manager.history_changed.connect(() => {
                clear_btn.sensitive = manager.get_history().length() > 0;
            });
            destroy.connect(() => manager.disconnect(h));

            var nc = new NotificationCenter();
            nc.vexpand = true;
            add_widget(nc);
        }
    }
}
