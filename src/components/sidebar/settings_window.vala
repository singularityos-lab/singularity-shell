using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class SettingsWindow : Singularity.Widgets.Window {
        private SettingsView settings_view;
        private SingularityApp app;

        public SettingsWindow(SingularityApp app) {
            base(app);
            this.app = app;

            set_title(_("Settings"));
            set_default_size(980, 680);
            toolbar.is_static = false;

            settings_view = new SettingsView(app, true);
            set_content(settings_view);

            close_request.connect(() => {
                new GLib.Settings("dev.sinty.desktop").set_boolean("bar-layout-edit-mode", false);
                hide();
                return true;
            });
        }

        public void open_page(string page) {
            if (page == null || page == "" || page == "home") page = "desktop";
            settings_view.navigate_to(page);
            present();
        }

        public SettingsView get_settings_view() {
            return settings_view;
        }

        public void reveal_setting(SettingsEntry entry, bool activate) {
            present();
            settings_view.reveal(entry, activate);
        }

        public void open_app_details(AppInfo info) {
            settings_view.open_app_details(info);
            present();
        }
    }
}
