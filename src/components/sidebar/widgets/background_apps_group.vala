using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class BackgroundAppsGroup : PreferencesGroup {
        private BackgroundApps apps;

        public BackgroundAppsGroup() {
            Object(title: _("Background Apps"), description: _("Running with no open windows."));
            add_css_class("background-apps-group");
            visible = false;
            apps = BackgroundApps.get_default();
            apps.changed.connect(rebuild);
            apps.start.begin();
        }

        private void rebuild() {
            clear();
            var list = apps.list();
            foreach (var app in list) {
                var row = new ActionRow(app.display_name, app.message != "" ? app.message : null);
                row.activatable = false;
                var icon = new Image.from_gicon(app.icon ?? new ThemedIcon("application-x-executable"));
                icon.pixel_size = 24;
                icon.margin_end = 12;
                row.add_prefix(icon);
                var stop = new Button.with_label(_("Stop"));
                stop.valign = Align.CENTER;
                var target = app;
                stop.clicked.connect(() => {
                    stop.sensitive = false;
                    apps.stop.begin(target, (obj, res) => {
                        apps.stop.end(res);
                        apps.refresh.begin();
                    });
                });
                row.add_suffix(stop);
                add_row(row);
            }
            visible = list.length > 0;
        }
    }
}
