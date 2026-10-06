using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class CrashReportsGroup : PreferencesGroup {
        private GLib.Settings? settings = null;
        private ActionRow source_row;
        private Button clear_button;

        public CrashReportsGroup() {
            base(_("Crash Reports"), _("What happens when an app quits unexpectedly. Nothing is ever sent anywhere."));
            var schema_source = SettingsSchemaSource.get_default();
            if (schema_source != null && schema_source.lookup("dev.sinty.desktop.crash", true) != null) {
                settings = new GLib.Settings("dev.sinty.desktop.crash");
            }

            var toggle = new SwitchRow(_("Show Crash Reports"),
                _("A notification with Reopen and Details"), settings == null || settings.get_boolean("enabled"));
            if (settings != null) settings.bind("enabled", toggle.switch_btn, "active", SettingsBindFlags.DEFAULT);
            else toggle.sensitive = false;
            add_row(toggle);

            source_row = new ActionRow(_("Crash Data"), Singularity.Crash.Reporter.get_default().describe_sources());
            source_row.activatable = false;
            clear_button = new Button.with_label(_("Clear"));
            clear_button.valign = Align.CENTER;
            clear_button.tooltip_text = _("Delete the saved crash reports of your apps");
            clear_button.clicked.connect(() => {
                int removed = Singularity.Crash.Reporter.get_default().clear_user_reports();
                clear_button.sensitive = false;
                source_row.subtitle = removed > 0
                    ? ngettext("%d saved file deleted", "%d saved files deleted", (ulong) removed).printf(removed)
                    : _("No saved crash reports");
            });
            source_row.add_suffix(clear_button);
            add_row(source_row);

            map.connect(() => {
                source_row.subtitle = Singularity.Crash.Reporter.get_default().describe_sources();
                clear_button.sensitive = true;
            });
        }
    }
}
