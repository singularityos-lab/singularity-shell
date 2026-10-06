using GLib;

namespace Singularity {

    public class AppNotificationPolicy : Object {
        public const string LOCK_SHOW = "show";
        public const string LOCK_HIDE_CONTENT = "hide-content";
        public const string LOCK_HIDE = "hide";
        public const string PRIORITY_NORMAL = "normal";
        public const string PRIORITY_TIME_SENSITIVE = "time-sensitive";
        public const string GROUP_BY_APP = "app";
        public const string GROUP_OFF = "off";

        public bool allowed { get; set; default = true; }
        public bool banners { get; set; default = true; }
        public bool sounds { get; set; default = true; }
        public string lock_screen { get; set; default = LOCK_HIDE_CONTENT; }
        public string priority { get; set; default = PRIORITY_NORMAL; }
        public string grouping { get; set; default = GROUP_BY_APP; }

        public bool time_sensitive { get { return priority == PRIORITY_TIME_SENSITIVE; } }
    }

    public class NotificationFacts : Object {
        public string app_key { get; set; default = ""; }
        public string summary { get; set; default = ""; }
        public string body { get; set; default = ""; }
        public uint8 urgency { get; set; default = 1; }
        public bool suppress_sound { get; set; default = false; }
        public bool transient { get; set; default = false; }
    }

    public class NotificationDecision : Object {
        public bool store { get; set; default = true; }
        public bool banner { get; set; default = true; }
        public bool sound { get; set; default = true; }
        public bool silenced { get; set; default = false; }
        public bool time_sensitive { get; set; default = false; }
        public string lock_screen { get; set; default = AppNotificationPolicy.LOCK_HIDE_CONTENT; }
    }

    public class NotificationRules : Object {
        public static bool breaks_through(FocusMode? focus, AppNotificationPolicy policy, NotificationFacts facts) {
            if (focus == null) return true;
            if (facts.urgency >= 2) return true;
            if (focus.allows_app(facts.app_key)) return true;
            if (focus.allows_sender(facts.summary, facts.body)) return true;
            return policy.time_sensitive && focus.allow_time_sensitive;
        }

        public static NotificationDecision decide(AppNotificationPolicy policy, FocusMode? focus, NotificationFacts facts) {
            var d = new NotificationDecision();
            d.time_sensitive = policy.time_sensitive || facts.urgency >= 2;
            d.lock_screen = policy.lock_screen;
            if (!policy.allowed && facts.urgency < 2) {
                d.store = false;
                d.banner = false;
                d.sound = false;
                return d;
            }
            d.silenced = !breaks_through(focus, policy, facts);
            d.banner = !d.silenced && (policy.banners || facts.urgency >= 2);
            d.sound = !d.silenced && policy.sounds && !facts.suppress_sound;
            d.store = !facts.transient || d.silenced;
            return d;
        }

        public static string app_key_for(string app_name, string? desktop_entry) {
            string source = desktop_entry != null && desktop_entry.strip() != "" ? desktop_entry.strip() : app_name.strip();
            if (source.has_suffix(".desktop")) source = source.substring(0, source.length - ".desktop".length);
            var sb = new StringBuilder();
            foreach (char c in source.down().to_utf8()) {
                if (c.isalnum()) {
                    sb.append_c(c);
                } else if (sb.len > 0 && sb.str[sb.len - 1] != '-') {
                    sb.append_c('-');
                }
            }
            string key = sb.str;
            while (key.has_suffix("-")) key = key.substring(0, key.length - 1);
            return key == "" ? "unknown" : key;
        }
    }
}
