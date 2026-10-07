using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class ClipboardSettingsPage : SettingsPage {
        public static ActionRow entry_row(SettingsView view) {
            var history = ClipboardHistory.get_default();
            var row = new ActionRow(_("Clipboard History"), status(history), "edit-paste-symbolic");
            row.activatable = true;
            row.add_suffix(NotificationSettingsPage.chevron());
            row.activated.connect(() => view.open_subpage(new ClipboardSettingsPage(view), "clipboard"));
            if (history.settings != null) {
                ulong h = history.settings.changed["history-enabled"].connect(() => row.subtitle = status(history));
                row.destroy.connect(() => history.settings.disconnect(h));
            }
            return row;
        }

        private static string status(ClipboardHistory history) {
            return history.enabled ? _("On, open it with Super+V") : _("Off");
        }

        public ClipboardSettingsPage(SettingsView view) {
            base(_("Clipboard History"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("keyboard"));
            var history = ClipboardHistory.get_default();

            if (history.settings == null) {
                var missing = new StatusPage();
                missing.icon_name = "clipboard";
                missing.title = _("Clipboard History Unavailable");
                missing.description = _("The clipboard settings schema is not installed on this system.");
                add_widget(missing);
                return;
            }

            var general = new PreferencesGroup(_("History"),
                _("Copied text and images are kept on this computer. Items that password managers mark as secret are never kept."));
            var enabled = new SwitchRow(_("Keep Clipboard History"), _("Press Super+V to see what you copied"));
            history.settings.bind("history-enabled", enabled.switch_btn, "active", SettingsBindFlags.DEFAULT);
            general.add_row(enabled);
            var paste = new SwitchRow(_("Paste When Chosen"), _("Choosing an item also pastes it into the app you were using"));
            history.settings.bind("paste-on-select", paste.switch_btn, "active", SettingsBindFlags.DEFAULT);
            general.add_row(paste);
            var panel = new SwitchRow(_("Show in Panel"), _("Open the history from a button in the panel"));
            history.settings.bind("show-in-panel", panel.switch_btn, "active", SettingsBindFlags.DEFAULT);
            general.add_row(panel);

            int[] sizes = { 25, 50, 100 };
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            foreach (int n in sizes) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = n.to_string();
                o.label = ngettext("%d item", "%d items", n).printf(n);
                options.add(o);
            }
            var size = new SelectionRow.with_options(_("Items to Keep"), options, history.settings.get_int("history-limit").to_string());
            size.subtitle = _("Pinned items are kept on top of these");
            size.selected.connect((id) => history.settings.set_int("history-limit", int.parse(id)));
            general.add_row(size);
            add_group(general);

            var manage = new PreferencesGroup(_("Stored Items"));
            var clear = new ConfirmRow(_("Clear History"), items_label(history), "user-trash-symbolic");
            clear.confirm_label = _("Clear");
            clear.confirmed.connect(() => history.model.clear());
            ulong h = history.model.changed.connect(() => clear.subtitle = items_label(history));
            clear.destroy.connect(() => history.model.disconnect(h));
            manage.add_row(clear);
            if (!history.watching) {
                var limited = new ActionRow(_("Limited on This System"),
                    _("The compositor does not share the clipboard with the desktop, so only copies made while the desktop has focus are kept."),
                    "dialog-warning-symbolic");
                manage.add_row(limited);
            }
            add_group(manage);
        }

        private static string items_label(ClipboardHistory history) {
            int pinned = 0;
            foreach (var e in history.model.entries) {
                if (e.pinned) pinned++;
            }
            int n = history.model.entries.size;
            if (n == 0) return _("Nothing stored");
            return ngettext("%d item, pinned items stay", "%d items, pinned items stay", n).printf(n);
        }
    }
}
