namespace Singularity {

    public class HubConfig : Object {
        private static HubConfig? instance = null;

        private GLib.Settings? _settings = null;

        private bool _enabled = true;
        private bool _show_notifications = true;
        private string _swipe_start = "read";
        private string _swipe_end = "delete";
        private string[] _hidden_accounts = {};
        private string[] _priority_senders = {};

        public bool enabled { get { return _enabled; } }
        public bool show_notifications { get { return _show_notifications; } }
        public string swipe_start { get { return _swipe_start; } }
        public string swipe_end { get { return _swipe_end; } }
        public string[] hidden_accounts { get { return _hidden_accounts; } }
        public string[] priority_senders { get { return _priority_senders; } }

        public signal void changed();

        public static HubConfig get_default() {
            if (instance == null) instance = new HubConfig();
            return instance;
        }

        private HubConfig() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema != null && schema.has_key("hub-enabled") && schema.has_key("hub-priority-senders")) {
                _settings = new GLib.Settings("dev.sinty.desktop");
                _settings.changed.connect((key) => {
                    if (!key.has_prefix("hub-")) return;
                    load();
                    changed();
                });
            }
            load();
        }

        public bool available {
            get { return _settings != null; }
        }

        private void load() {
            if (_settings == null) return;
            _enabled = _settings.get_boolean("hub-enabled");
            _show_notifications = _settings.get_boolean("hub-show-notifications");
            _swipe_start = _settings.get_string("hub-swipe-start");
            _swipe_end = _settings.get_string("hub-swipe-end");
            _hidden_accounts = _settings.get_strv("hub-hidden-accounts");
            _priority_senders = _settings.get_strv("hub-priority-senders");
        }

        public void set_enabled(bool on) {
            if (_settings != null) _settings.set_boolean("hub-enabled", on);
        }

        public void set_show_notifications(bool on) {
            if (_settings != null) _settings.set_boolean("hub-show-notifications", on);
        }

        public void set_swipe(bool start, string action) {
            if (_settings != null) _settings.set_string(start ? "hub-swipe-start" : "hub-swipe-end", action);
        }

        public bool is_hidden(string account) {
            return account in _hidden_accounts;
        }

        public void set_hidden(string account, bool hidden) {
            if (_settings == null || is_hidden(account) == hidden) return;
            string[] list = {};
            foreach (var a in _hidden_accounts) if (a != account) list += a;
            if (hidden) list += account;
            _settings.set_strv("hub-hidden-accounts", list);
        }

        public bool is_priority(Hub.Item item) {
            if (item.priority) return true;
            foreach (var s in _priority_senders) {
                string needle = s.strip().down();
                if (needle == "") continue;
                if (item.sender.down().contains(needle) || item.target.down() == needle) return true;
            }
            return false;
        }

        public void set_priority_senders(string[] senders) {
            if (_settings != null) _settings.set_strv("hub-priority-senders", senders);
        }
    }
}
