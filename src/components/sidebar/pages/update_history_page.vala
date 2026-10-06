using Gtk;
using Singularity.Widgets;
using Singularity.Updates;

namespace Singularity.SidebarPages {

    public class UpdateHistoryPage : SettingsPage {
        private const int LIMIT = 25;

        private PreferencesGroup system_group;
        private PreferencesGroup firmware_group;
        private StatusPage empty;

        public UpdateHistoryPage(SettingsView view) {
            base(_("Update History"));

            empty = new StatusPage();
            empty.compact = true;
            empty.icon_name = "document-open-recent";
            empty.title = _("No Updates Yet");
            empty.description = _("Updates appear here after they are installed.");
            empty.visible = false;
            add_widget(empty);

            system_group = new PreferencesGroup(_("System"));
            system_group.visible = false;
            add_group(system_group);
            firmware_group = new PreferencesGroup(_("Firmware"));
            firmware_group.visible = false;
            add_group(firmware_group);

            load.begin();
        }

        private async void load() {
            var provider = yield Backend.get_default();
            if (provider.has_history) {
                try {
                    fill(system_group, yield provider.history());
                } catch (Error e) {
                    system_group.description = e.message;
                    system_group.visible = true;
                }
            }
            var client = Firmware.Client.get_default();
            if (yield client.probe()) {
                try {
                    fill(firmware_group, yield client.history());
                } catch (Error e) {
                    firmware_group.description = e.message;
                    firmware_group.visible = true;
                }
            }
            empty.visible = !system_group.visible && !firmware_group.visible;
        }

        private void fill(PreferencesGroup group, Gee.List<HistoryEntry> entries) {
            group.clear();
            int count = 0;
            foreach (var entry in entries) {
                if (count == LIMIT) break;
                string when = entry.time > 0 ? new DateTime.from_unix_local(entry.time).format(_("%-d %B %Y, %H:%M")).strip() : "";
                string subtitle = entry.detail;
                if (when != "") subtitle = subtitle != "" ? "%s\n%s".printf(when, subtitle) : when;
                var row = new ActionRow(entry.title, subtitle,
                    entry.success ? "object-select-symbolic" : "dialog-warning-symbolic");
                group.add_row(row);
                count++;
            }
            group.visible = count > 0;
        }
    }
}
