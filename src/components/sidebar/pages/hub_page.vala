using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class HubPage : SettingsPage {
        private const string[] SWIPE_KEYS = { "read", "flag", "delete", "none" };

        private HubConfig config;
        private HubStore store;
        private string[] swipe_labels;
        private SwitchRow enabled_row;
        private SwitchRow notifications_row;
        private SelectionRow start_row;
        private SelectionRow end_row;
        private PreferencesGroup accounts_group;
        private PreferencesGroup priority_group;
        private EntryRow add_row;
        private bool syncing = false;

        public HubPage(SettingsView view) {
            base(_("Hub"));
            config = HubConfig.get_default();
            store = HubStore.get_default();
            swipe_labels = { _("Mark as Read or Unread"), _("Flag"), _("Delete"), _("Nothing") };

            var display = new PreferencesGroup(_("Display and Actions"));
            add_group(display);
            enabled_row = new SwitchRow(_("Hub on the Home Screen"), _("Swipe right on the first home page to reveal the Hub"));
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (!syncing) config.set_enabled(enabled_row.switch_btn.active);
            });
            display.add_row(enabled_row);
            notifications_row = new SwitchRow(_("Show Notifications"), _("List notifications from apps without their own Hub account"));
            notifications_row.switch_btn.notify["active"].connect(() => {
                if (!syncing) config.set_show_notifications(notifications_row.switch_btn.active);
            });
            display.add_row(notifications_row);
            start_row = new SelectionRow(_("Swipe Right"), swipe_labels, swipe_labels[swipe_index(config.swipe_start)]);
            start_row.selected.connect((label) => {
                if (!syncing) config.set_swipe(true, swipe_key(label));
            });
            display.add_row(start_row);
            end_row = new SelectionRow(_("Swipe Left"), swipe_labels, swipe_labels[swipe_index(config.swipe_end)]);
            end_row.selected.connect((label) => {
                if (!syncing) config.set_swipe(false, swipe_key(label));
            });
            display.add_row(end_row);

            accounts_group = new PreferencesGroup(_("Hub Management"), _("Accounts shown in the combined Hub list. Hidden accounts stay in the account list."));
            add_group(accounts_group);

            priority_group = new PreferencesGroup(_("Priority Hub"), _("Items from these people, addresses or numbers are marked as priority."));
            add_group(priority_group);
            add_row = new EntryRow(_("Add Sender"), "list-add-symbolic");
            add_row.entry_activated.connect(add_sender);

            config.changed.connect(sync);
            store.changed.connect(rebuild_accounts);
            sync();
        }

        private static int swipe_index(string key) {
            for (int i = 0; i < SWIPE_KEYS.length; i++) if (SWIPE_KEYS[i] == key) return i;
            return 0;
        }

        private string swipe_key(string label) {
            for (int i = 0; i < swipe_labels.length; i++) if (swipe_labels[i] == label) return SWIPE_KEYS[i];
            return "none";
        }

        private void sync() {
            syncing = true;
            enabled_row.switch_btn.active = config.enabled;
            notifications_row.switch_btn.active = config.show_notifications;
            start_row.current_value = swipe_labels[swipe_index(config.swipe_start)];
            end_row.current_value = swipe_labels[swipe_index(config.swipe_end)];
            enabled_row.sensitive = config.available;
            syncing = false;
            rebuild_accounts();
            rebuild_priority();
        }

        private void rebuild_accounts() {
            accounts_group.clear();
            foreach (var a in store.accounts) {
                if (a.id == HubStore.NOTIFICATIONS && !config.show_notifications) continue;
                var row = new SwitchRow(a.name, a.detail, !config.is_hidden(a.id));
                string id = a.id;
                row.switch_btn.notify["active"].connect(() => config.set_hidden(id, !row.switch_btn.active));
                accounts_group.add_row(row);
            }
        }

        private void rebuild_priority() {
            accounts_group.sensitive = config.available;
            priority_group.sensitive = config.available;
            priority_group.clear();
            foreach (var sender in config.priority_senders) {
                var row = new ActionRow(sender, null, "starred-symbolic");
                row.activatable = false;
                var remove = new Button.from_icon_name("user-trash-symbolic");
                remove.add_css_class("flat");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Remove");
                string value = sender;
                remove.clicked.connect(() => {
                    string[] list = {};
                    foreach (var s in config.priority_senders) if (s != value) list += s;
                    config.set_priority_senders(list);
                });
                row.add_suffix(remove);
                priority_group.add_row(row);
            }
            priority_group.add_row(add_row);
        }

        private void add_sender() {
            string value = add_row.text.strip();
            if (value == "") return;
            string[] list = config.priority_senders;
            foreach (var s in list) if (s.down() == value.down()) return;
            list += value;
            add_row.text = "";
            config.set_priority_senders(list);
        }
    }
}
