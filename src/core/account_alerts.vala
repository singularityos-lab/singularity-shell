using GLib;
using Singularity.Accounts;

namespace Singularity {

    public class AccountAlerts : Object {
        private Gee.HashMap<uint, string> shown = new Gee.HashMap<uint, string> ();
        private Gee.HashSet<string> alerted = new Gee.HashSet<string> ();

        public signal void open_requested (string page);

        public AccountAlerts () {
            var notifications = SystemMonitor.get_default ().notifications;
            notifications.action_invoked.connect (on_action);
            notifications.notification_closed.connect ((id, reason) => shown.unset (id));
            var manager = Manager.get_default ();
            manager.needs_attention.connect ((account, reason) => alert (account));
            manager.account_changed.connect ((account) => {
                if (account.healthy) alerted.remove (account.id);
            });
            manager.account_removed.connect ((account) => alerted.remove (account.id));
            manager.load.begin ((obj, res) => {
                manager.load.end (res);
                foreach (var account in manager.get_accounts ()) {
                    if (!account.healthy) alert (account);
                }
            });
        }

        private void alert (Account account) {
            if (account.healthy || account.attention == "consent" || alerted.contains (account.id)) return;
            alerted.add (account.id);
            var notifications = SystemMonitor.get_default ().notifications;
            string[] actions = { "default", _("Open Settings") };
            uint id = notifications.notify (_("Online Accounts"), 0, account.icon_name,
                _("Sign In to %s Again").printf (account.provider_name),
                _("%s no longer accepts the saved sign-in. Apps cannot use this account until you sign in again.").printf (account.display_name),
                actions, new HashTable<string, Variant> (str_hash, str_equal), -1);
            shown[id] = account.id;
        }

        private void on_action (uint id, string action) {
            if (!shown.has_key (id)) return;
            if (action == "default") open_requested ("accounts");
        }
    }
}
