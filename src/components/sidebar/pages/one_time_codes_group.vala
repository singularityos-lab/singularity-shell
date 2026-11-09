using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class OneTimeCodesGroup : PreferencesGroup {
        private const string SCHEMA = "dev.sinty.desktop.notifications";
        private GLib.Settings? settings = null;
        private Gee.ArrayList<SwitchRow> dependent = new Gee.ArrayList<SwitchRow>();

        public OneTimeCodesGroup() {
            base(_("One-Time Codes"),
                _("Codes you receive appear when you fill in a code field. They stay in memory for ten minutes and never reach the clipboard or history."));
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup(SCHEMA, true) : null;
            if (schema != null && schema.has_key("one-time-codes")) settings = new GLib.Settings(SCHEMA);

            var master = new SwitchRow(_("Suggest Codes"), _("Offer codes from messages in text fields"),
                settings == null || settings.get_boolean("one-time-codes"));
            if (settings != null) settings.bind("one-time-codes", master.switch_btn, "active", SettingsBindFlags.DEFAULT);
            else master.sensitive = false;
            add_row(master);

            add_source("messages", _("Messages"), _("Text messages on this computer"));
            add_source("mail", _("Mail"), _("Codes in Lettere"));
            add_source("phone", _("Phone"), _("Messages from your phone through Nearby"));
            add_source("apps", _("Other Apps"), _("Apps that declare they send codes"));

            var delete_used = new SwitchRow(_("Delete After Use"), _("Remove the message once its code has been used"),
                settings != null && settings.get_boolean("one-time-code-delete-used"));
            if (settings != null) settings.bind("one-time-code-delete-used", delete_used.switch_btn, "active", SettingsBindFlags.DEFAULT);
            dependent.add(delete_used);
            add_row(delete_used);

            if (settings != null) settings.changed["one-time-codes"].connect(sync_sensitive);
            sync_sensitive();
        }

        private void add_source(string id, string title, string subtitle) {
            bool on = settings != null && (id in settings.get_strv("one-time-code-sources"));
            var row = new SwitchRow(title, subtitle, on);
            row.switch_btn.notify["active"].connect(() => {
                if (settings == null) return;
                string[] current = settings.get_strv("one-time-code-sources");
                bool active = row.switch_btn.active;
                if ((id in current) == active) return;
                string[] next = {};
                foreach (string s in current) if (s != id) next += s;
                if (active) next += id;
                settings.set_strv("one-time-code-sources", next);
            });
            if (settings != null) {
                settings.changed["one-time-code-sources"].connect(() => {
                    bool want = id in settings.get_strv("one-time-code-sources");
                    if (row.switch_btn.active != want) row.switch_btn.active = want;
                });
            }
            dependent.add(row);
            add_row(row);
        }

        private void sync_sensitive() {
            bool on = settings != null && settings.get_boolean("one-time-codes");
            foreach (var row in dependent) row.sensitive = on;
        }
    }
}
