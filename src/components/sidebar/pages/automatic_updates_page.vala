using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AutomaticUpdatesPage : SettingsPage {

        public AutomaticUpdatesPage(SettingsView view) {
            base(_("Automatic Updates"));
            var settings = new GLib.Settings("dev.sinty.desktop");

            var group = new PreferencesGroup(_("Schedule"),
                _("Updates are installed only when you restart, never while you work."));
            var check_row = new SwitchRow(_("Check Automatically"), _("Look for system updates in the background"),
                settings.get_boolean("updates-automatic-check"));
            settings.bind("updates-automatic-check", check_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            group.add_row(check_row);
            string[] labels = { _("Every Day"), _("Every Week") };
            string[] values = { "daily", "weekly" };
            string current = settings.get_string("updates-check-frequency") == "weekly" ? labels[1] : labels[0];
            var frequency_row = new SelectionRow(_("How Often"), labels, current);
            frequency_row.selected.connect((label) => {
                for (int i = 0; i < labels.length; i++) {
                    if (labels[i] == label) settings.set_string("updates-check-frequency", values[i]);
                }
            });
            check_row.switch_btn.bind_property("active", frequency_row, "sensitive", BindingFlags.SYNC_CREATE);
            group.add_row(frequency_row);
            var download_row = new SwitchRow(_("Download Automatically"),
                _("Get updates ready in the background, except on metered connections"),
                settings.get_boolean("updates-automatic-download"));
            settings.bind("updates-automatic-download", download_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            check_row.switch_btn.bind_property("active", download_row, "sensitive", BindingFlags.SYNC_CREATE);
            group.add_row(download_row);
            add_group(group);
        }

        public static string summary(GLib.Settings settings) {
            if (!settings.get_boolean("updates-automatic-check")) return _("Off. Check for updates yourself.");
            bool weekly = settings.get_string("updates-check-frequency") == "weekly";
            if (settings.get_boolean("updates-automatic-download")) {
                return weekly ? _("Checks every week and downloads updates") : _("Checks every day and downloads updates");
            }
            return weekly ? _("Checks every week") : _("Checks every day");
        }
    }
}
