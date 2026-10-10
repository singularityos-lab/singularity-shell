using Gtk;

namespace Singularity {

    public class CollaborationIndicator : Gtk.Button {
        private Singularity.Collab.Client client;
        private ulong sessions_id = 0;

        public CollaborationIndicator() {
            Object();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("collaboration-indicator");
            var icon = new Image.from_icon_name("system-users-symbolic");
            icon.pixel_size = 16;
            set_child(icon);
            clicked.connect(() => {
                var app = GLib.Application.get_default() as SingularityApp;
                if (app != null) app.open_settings_page("sharing-collab");
            });
            if (!Singularity.Collab.Client.installed()) return;
            client = Singularity.Collab.Client.get_default();
            sessions_id = client.sessions_changed.connect(() => sync.begin());
            sync.begin();
        }

        public override void dispose() {
            if (sessions_id != 0) {
                client.disconnect(sessions_id);
                sessions_id = 0;
            }
            base.dispose();
        }

        private async void sync() {
            var sessions = yield client.sessions();
            visible = sessions.size > 0;
            if (sessions.size == 0) return;
            string[] lines = {};
            foreach (var s in sessions) {
                if (s.hosting) {
                    string who = s.people.length > 0 ? string.joinv(", ", s.people) : _("nobody yet");
                    lines += _("Sharing %s with %s").printf(s.title, who);
                } else {
                    lines += _("Working on %s with %s").printf(s.title, s.host_name);
                }
            }
            tooltip_text = string.joinv("\n", lines);
        }
    }
}
