namespace Singularity {

    public class HubStore : Object {
        public const string NOTIFICATIONS = "notifications";

        private static HubStore? instance = null;

        private Gee.ArrayList<Hub.Account> _accounts = new Gee.ArrayList<Hub.Account>();
        private Gee.HashMap<string, Hub.Item> _items = new Gee.HashMap<string, Hub.Item>();
        private Gee.HashSet<string> _read_notifications = new Gee.HashSet<string>();
        private HubBus? _bus = null;
        private uint _save_source = 0;

        public signal void changed();
        public signal void action_requested(string account, string id, string action);

        public static HubStore get_default() {
            if (instance == null) instance = new HubStore();
            return instance;
        }

        private HubStore() {
            var notifications = new Hub.Account(NOTIFICATIONS, _("Notifications"), Hub.AccountKind.NOTIFICATIONS);
            notifications.icon_name = "preferences-system-notifications-symbolic";
            _accounts.add(notifications);
            load();
            var mgr = SystemMonitor.get_default().notifications;
            mgr.history_changed.connect(() => sync_notifications());
            sync_notifications();
            HubConfig.get_default().changed.connect(() => sync_notifications());
            _bus = new HubBus(this);
            _bus.own();
        }

        public Gee.List<Hub.Account> accounts {
            owned get { return _accounts.read_only_view; }
        }

        public Hub.Account? account(string id) {
            foreach (var a in _accounts) if (a.id == id) return a;
            return null;
        }

        public Gee.List<Hub.Item> items(string? account = null) {
            var list = new Gee.ArrayList<Hub.Item>();
            foreach (var item in _items.values) {
                if (account == null || item.account == account) list.add(item);
            }
            list.sort((a, b) => a.timestamp == b.timestamp ? strcmp(a.id, b.id) : (a.timestamp > b.timestamp ? -1 : 1));
            return list;
        }

        public int unread(string? account = null) {
            int n = 0;
            foreach (var item in _items.values) {
                if (item.unread && (account == null || item.account == account)) n += item.count;
            }
            return n;
        }

        public void register_account(Hub.Account account) {
            for (int i = 0; i < _accounts.size; i++) {
                if (_accounts[i].id == account.id) {
                    _accounts[i] = account;
                    changed_and_save();
                    return;
                }
            }
            _accounts.add(account);
            sync_notifications();
            changed_and_save();
        }

        public void publish(Hub.Item item) {
            if (account(item.account) == null) return;
            _items[item.key] = item;
            changed_and_save();
        }

        public void withdraw(string account, string id) {
            if (_items.unset(account + "\n" + id)) changed_and_save();
        }

        public void set_unread(Hub.Item item, bool unread) {
            if (item.unread == unread) return;
            item.unread = unread;
            if (item.account == NOTIFICATIONS) {
                if (unread) _read_notifications.remove(item.id);
                else _read_notifications.add(item.id);
            }
            action_requested(item.account, item.id, unread ? "mark-unread" : "mark-read");
            changed_and_save();
        }

        public void set_flagged(Hub.Item item, bool flagged) {
            if (item.flagged == flagged) return;
            item.flagged = flagged;
            action_requested(item.account, item.id, flagged ? "flag" : "unflag");
            changed_and_save();
        }

        public void remove(Hub.Item item) {
            _items.unset(item.key);
            if (item.account == NOTIFICATIONS) {
                uint id = (uint) uint64.parse(item.id);
                SystemMonitor.get_default().notifications.remove_from_history(id);
            } else {
                action_requested(item.account, item.id, "delete");
            }
            changed_and_save();
        }

        public void restore(Hub.Item item) {
            if (item.account == NOTIFICATIONS) return;
            _items[item.key] = item;
            action_requested(item.account, item.id, "restore");
            changed_and_save();
        }

        public Gee.List<Hub.ItemAction> actions_for(Hub.Item item) {
            var list = new Gee.ArrayList<Hub.ItemAction>();
            foreach (var spec in item.actions) {
                var a = Hub.ItemAction.decode(spec);
                if (a != null) list.add(a);
            }
            if (list.size == 0 && item.account != NOTIFICATIONS) list.add_all(Hub.ItemAction.defaults(item.kind));
            return list;
        }

        public void invoke(Hub.Item item, string action) {
            if (item.account == NOTIFICATIONS) {
                SystemMonitor.get_default().notifications.invoke_action((uint) uint64.parse(item.id), action);
                return;
            }
            action_requested(item.account, item.id, action);
        }

        public void mark_seen(Hub.Item item) {
            set_unread(item, false);
        }

        public void open(Hub.Item item) {
            set_unread(item, false);
            if (item.account == NOTIFICATIONS) {
                var notif = SystemMonitor.get_default().notifications.find((uint) uint64.parse(item.id));
                if (notif != null) NotificationItem.open_notification(notif);
                return;
            }
            action_requested(item.account, item.id, "open");
            if (item.app_id == "") return;
            string desktop = item.app_id.has_suffix(".desktop") ? item.app_id : item.app_id + ".desktop";
            var info = new DesktopAppInfo(desktop);
            if (info == null) return;
            try {
                var ctx = Gdk.Display.get_default().get_app_launch_context();
                if (item.target != "") {
                    var uris = new List<string>();
                    uris.append(item.target);
                    info.launch_uris(uris, ctx);
                } else {
                    info.launch(null, ctx);
                }
            } catch (Error e) {
                warning("hub: cannot open %s: %s", desktop, e.message);
            }
        }

        private void sync_notifications() {
            var keep = new Gee.HashSet<string>();
            var owned_apps = new Gee.HashSet<string>();
            foreach (var a in _accounts) {
                if (a.app_id != "") owned_apps.add(a.app_id.has_suffix(".desktop") ? a.app_id.substring(0, a.app_id.length - 8) : a.app_id);
            }
            unowned List<Notification> history = SystemMonitor.get_default().notifications.get_history();
            bool show = HubConfig.get_default().show_notifications;
            foreach (unowned Notification n in history) {
                if (!show) break;
                string id = n.id.to_string();
                string app = n.desktop_entry != "" ? n.desktop_entry : n.app_key;
                if (app.has_suffix(".desktop")) app = app.substring(0, app.length - 8);
                if (owned_apps.contains(app)) continue;
                keep.add(id);
                var item = new Hub.Item(NOTIFICATIONS, id, Hub.ItemKind.NOTIFICATION);
                item.sender = n.app_name != "" ? n.app_name : _("System");
                item.subject = n.summary;
                item.preview = n.masked_body();
                item.timestamp = n.timestamp / 1000000;
                item.unread = !_read_notifications.contains(id);
                item.priority = n.time_sensitive;
                item.app_id = app;
                item.icon = n.icon;
                item.body = n.masked_body();
                string[] acts = {};
                for (int i = 0; i + 1 < n.actions.length; i += 2) {
                    if (n.actions[i] == "default" || n.actions[i] == "") continue;
                    acts += new Hub.ItemAction(n.actions[i], n.actions[i + 1], "").encode();
                }
                item.actions = acts;
                _items[item.key] = item;
            }
            var stale = new Gee.ArrayList<string>();
            foreach (var entry in _items.entries) {
                if (entry.value.account == NOTIFICATIONS && !keep.contains(entry.value.id)) stale.add(entry.key);
            }
            foreach (var k in stale) _items.unset(k);
            _read_notifications.retain_all(keep);
            changed();
        }

        private static string path() {
            return Path.build_filename(Environment.get_user_state_dir(), "singularity", "hub.json");
        }

        private void changed_and_save() {
            changed();
            if (_save_source != 0) return;
            _save_source = Timeout.add(400, () => {
                _save_source = 0;
                save();
                return Source.REMOVE;
            });
        }

        private void save() {
            var accounts = new VariantBuilder(new VariantType("aa{sv}"));
            foreach (var a in _accounts) if (a.id != NOTIFICATIONS) accounts.add_value(a.to_variant());
            var items = new VariantBuilder(new VariantType("aa{sv}"));
            foreach (var item in _items.values) if (item.account != NOTIFICATIONS) items.add_value(item.to_variant());
            var read = new VariantBuilder(new VariantType("as"));
            foreach (var id in _read_notifications) read.add("s", id);
            var root = new Variant("(aa{sv}aa{sv}as)", accounts, items, read);
            try {
                DirUtils.create_with_parents(Path.get_dirname(path()), 0700);
                FileUtils.set_contents(path(), Json.gvariant_serialize_data(root, null));
            } catch (Error e) {
                warning("hub: cannot save: %s", e.message);
            }
        }

        private void load() {
            string data;
            try {
                if (!FileUtils.get_contents(path(), out data)) return;
                var root = Json.gvariant_deserialize_data(data, -1, "(aa{sv}aa{sv}as)");
                var accounts = root.get_child_value(0);
                for (size_t i = 0; i < accounts.n_children(); i++) {
                    var a = Hub.Account.from_variant(accounts.get_child_value(i));
                    if (a != null && a.id != NOTIFICATIONS) _accounts.add(a);
                }
                var items = root.get_child_value(1);
                for (size_t i = 0; i < items.n_children(); i++) {
                    var item = Hub.Item.from_variant(items.get_child_value(i));
                    if (item != null && account(item.account) != null) _items[item.key] = item;
                }
                var read = root.get_child_value(2);
                for (size_t i = 0; i < read.n_children(); i++) _read_notifications.add(read.get_child_value(i).get_string());
            } catch (Error e) {
                if (!(e is FileError.NOENT)) warning("hub: cannot load: %s", e.message);
            }
        }
    }

    [DBus (name = "dev.sinty.Hub1")]
    public class HubBus : Object {
        private unowned HubStore store;

        public signal void action_requested(string account, string id, string action);

        [DBus (visible = false)]
        public HubBus(HubStore store) {
            this.store = store;
            store.action_requested.connect((a, i, act) => {
                var account = store.account(a);
                if (account != null && account.app_id != "") Hub.deliver(account.app_id, a, i, act);
                else action_requested(a, i, act);
            });
        }

        [DBus (visible = false)]
        public void own() {
            GLib.Bus.own_name(BusType.SESSION, Hub.BUS_NAME,
                BusNameOwnerFlags.REPLACE | BusNameOwnerFlags.ALLOW_REPLACEMENT,
                (conn) => {
                    try {
                        conn.register_object(Hub.OBJECT_PATH, this);
                    } catch (IOError e) {
                        warning("hub: cannot register: %s", e.message);
                    }
                },
                null,
                () => warning("hub: name lost"));
        }

        public void register_account(HashTable<string, Variant> account) throws DBusError, IOError {
            var a = Hub.Account.from_variant(dict(account));
            if (a == null || a.id == HubStore.NOTIFICATIONS) throw new DBusError.INVALID_ARGS("invalid account");
            store.register_account(a);
        }

        public void publish(HashTable<string, Variant> item) throws DBusError, IOError {
            var i = Hub.Item.from_variant(dict(item));
            if (i == null || i.account == HubStore.NOTIFICATIONS) throw new DBusError.INVALID_ARGS("invalid item");
            if (store.account(i.account) == null) throw new DBusError.INVALID_ARGS("unknown account %s".printf(i.account));
            store.publish(i);
        }

        public void withdraw(string account, string id) throws DBusError, IOError {
            store.withdraw(account, id);
        }

        private static Variant dict(HashTable<string, Variant> table) {
            var b = new VariantBuilder(new VariantType("a{sv}"));
            var it = HashTableIter<string, Variant>(table);
            unowned string k;
            unowned Variant v;
            while (it.next(out k, out v)) b.add("{sv}", k, v);
            return b.end();
        }
    }
}
