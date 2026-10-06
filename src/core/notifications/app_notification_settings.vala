using GLib;

namespace Singularity {

    public class AppNotificationSettings : Object {
        public const string SCHEMA = "dev.sinty.desktop.notifications";
        public const string APP_SCHEMA = "dev.sinty.desktop.notifications.application";
        private const string APP_PATH = "/dev/sinty/desktop/notifications/application/%s/";

        private static AppNotificationSettings? _instance = null;
        public GLib.Settings settings { get; private set; }
        public bool available { get; private set; default = false; }
        private Gee.HashMap<string, GLib.Settings> _apps = new Gee.HashMap<string, GLib.Settings>();

        public signal void apps_changed();
        public signal void app_changed(string key);

        public static AppNotificationSettings get_default() {
            if (_instance == null) _instance = new AppNotificationSettings();
            return _instance;
        }

        private AppNotificationSettings() {
            var source = SettingsSchemaSource.get_default();
            available = source != null && source.lookup(SCHEMA, true) != null && source.lookup(APP_SCHEMA, true) != null;
            if (!available) {
                warning("notifications: schema %s is not installed, per-app settings are off", SCHEMA);
                return;
            }
            settings = new GLib.Settings(SCHEMA);
            settings.changed["known-applications"].connect(() => apps_changed());
        }

        public GLib.Settings? for_app(string key) {
            if (!available) return null;
            if (_apps.has_key(key)) return _apps[key];
            var s = new GLib.Settings.with_path(APP_SCHEMA, APP_PATH.printf(key));
            s.changed.connect(() => app_changed(key));
            _apps[key] = s;
            return s;
        }

        public AppNotificationPolicy policy_for(string key) {
            var policy = new AppNotificationPolicy();
            var s = for_app(key);
            if (s == null) return policy;
            policy.allowed = s.get_boolean("enabled");
            policy.banners = s.get_boolean("show-banners");
            policy.sounds = s.get_boolean("sounds");
            policy.lock_screen = s.get_string("lock-screen");
            policy.priority = s.get_string("priority");
            policy.grouping = s.get_string("grouping");
            return policy;
        }

        public void remember(string key, string display_name, string icon) {
            if (!available) return;
            var s = for_app(key);
            if (display_name != "" && s.get_string("display-name") != display_name) s.set_string("display-name", display_name);
            if (icon != "" && !icon.has_prefix("/") && s.get_string("icon") != icon) s.set_string("icon", icon);
            string[] known = settings.get_strv("known-applications");
            if (key in known) return;
            known += key;
            settings.set_strv("known-applications", known);
        }

        public string[] known_apps() {
            if (!available) return {};
            return settings.get_strv("known-applications");
        }

        public void forget(string key) {
            if (!available) return;
            string[] kept = {};
            foreach (string k in settings.get_strv("known-applications")) {
                if (k != key) kept += k;
            }
            settings.set_strv("known-applications", kept);
            var s = for_app(key);
            foreach (string k in s.settings_schema.list_keys()) s.reset(k);
        }

        public string display_name(string key) {
            var s = for_app(key);
            string name = s != null ? s.get_string("display-name") : "";
            var info = app_info(key);
            if (info != null) return info.get_display_name();
            return name != "" ? name : key;
        }

        public GLib.Icon? icon_for(string key) {
            var info = app_info(key);
            if (info != null && info.get_icon() != null) return info.get_icon();
            var s = for_app(key);
            string icon = s != null ? s.get_string("icon") : "";
            if (icon != "") return new ThemedIcon(icon);
            return null;
        }

        public static DesktopAppInfo? app_info(string key) {
            foreach (var info in AppInfo.get_all()) {
                var dinfo = info as DesktopAppInfo;
                if (dinfo == null) continue;
                string? id = dinfo.get_id();
                if (id == null) continue;
                if (NotificationRules.app_key_for("", id) == key) return dinfo;
            }
            foreach (var info in AppInfo.get_all()) {
                var dinfo = info as DesktopAppInfo;
                if (dinfo == null) continue;
                if (NotificationRules.app_key_for(dinfo.get_name(), null) == key) return dinfo;
            }
            return null;
        }
    }
}
