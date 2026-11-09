namespace Singularity {

    public class HeldCode : Object {
        public uint id;
        public string code;
        public string token;
        public string service;
        public string domain;
        public string app;
        public string message;
        public uint notification;
        public int64 expires;
        public OneTimeCodes.Match match;
    }

    [DBus (name = "dev.sinty.OneTimeCodes1")]
    public class OneTimeCodeService : Object {
        public const int64 LIFETIME = 600;
        private const string SCHEMA = "dev.sinty.desktop.notifications";

        private static OneTimeCodeService? instance;
        private Gee.ArrayList<HeldCode> held = new Gee.ArrayList<HeldCode>();
        private GLib.Settings? settings;
        private uint next_id = 1;
        private uint expiry_source = 0;

        public signal void changed();

        [DBus (visible = false)]
        public signal void released(uint notification, OneTimeCodes.Match match);

        [DBus (visible = false)]
        public signal void close_requested(uint notification);

        [DBus (visible = false)]
        public static OneTimeCodeService get_default() {
            if (instance == null) instance = new OneTimeCodeService();
            return instance;
        }

        private OneTimeCodeService() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup(SCHEMA, true) : null;
            if (schema == null || !schema.has_key("one-time-codes")) return;
            settings = new GLib.Settings(SCHEMA);
            settings.changed["one-time-codes"].connect(() => {
                if (!settings.get_boolean("one-time-codes")) clear();
            });
        }

        [DBus (visible = false)]
        public void export() {
            Bus.own_name(BusType.SESSION, "dev.sinty.OneTimeCodes", BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        conn.register_object<OneTimeCodeService>("/dev/sinty/OneTimeCodes", this);
                    } catch (IOError e) {
                        warning("one-time codes: %s", e.message);
                    }
                }, () => {}, () => {});
        }

        private static bool hint_flag(HashTable<string, Variant> hints, string key) {
            var v = hints.lookup(key);
            if (v == null) return false;
            if (v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            if (v.is_of_type(VariantType.BOOLEAN)) return v.get_boolean();
            if (v.is_of_type(VariantType.BYTE)) return v.get_byte() != 0;
            if (v.is_of_type(VariantType.INT32)) return v.get_int32() != 0;
            return false;
        }

        private static string hint_text(HashTable<string, Variant> hints, string key) {
            var v = hints.lookup(key);
            if (v == null) return "";
            if (v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            return v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }

        [DBus (visible = false)]
        public static string? source_of(string app_key, string desktop_entry) {
            string id = desktop_entry != "" ? desktop_entry : app_key;
            if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
            string low = id.down();
            if (low == "dev.sinty.messages") return "messages";
            if (low == "dev.sinty.lettere") return "mail";
            if (low.has_prefix("dev.sinty.nearby")) return "phone";
            if (id == "") return null;
            var info = new DesktopAppInfo(id + ".desktop");
            if (info != null && info.has_key("X-Sinty-One-Time-Codes") && info.get_boolean("X-Sinty-One-Time-Codes")) return "apps";
            return null;
        }

        [DBus (visible = false)]
        public static bool is_spam(HashTable<string, Variant> hints) {
            if (hint_flag(hints, "x-sinty-spam")) return true;
            string category = hint_text(hints, "category");
            return category == "x-sinty.spam" || category.has_suffix(".spam") || category.has_suffix(".junk");
        }

        [DBus (visible = false)]
        public OneTimeCodes.Match? offer(uint notification, string app_key, string desktop_entry,
                                         string summary, string body, HashTable<string, Variant> hints) {
            if (settings == null || !settings.get_boolean("one-time-codes")) return null;
            string? source = source_of(app_key, desktop_entry);
            if (source == null || !(source in settings.get_strv("one-time-code-sources"))) return null;
            if (is_spam(hints)) return null;
            var match = OneTimeCodes.find(summary, body, null);
            if (match == null) return null;

            foreach (var old in held) {
                if (old.notification == notification) {
                    held.remove(old);
                    break;
                }
            }
            var entry = new HeldCode();
            entry.id = next_id++;
            entry.code = match.code;
            entry.token = match.token;
            entry.service = match.service != "" ? match.service : summary;
            entry.domain = match.domain ?? "";
            entry.app = desktop_entry != "" ? desktop_entry : app_key;
            entry.message = hint_text(hints, "x-sinty-message-id");
            entry.notification = notification;
            entry.expires = get_real_time() / 1000000 + LIFETIME;
            entry.match = match;
            held.insert(0, entry);
            while (held.size > 5) release(held[held.size - 1], false);
            arm_expiry();
            changed();
            return match;
        }

        [DBus (visible = false)]
        public string safe_text(uint notification, string text) {
            foreach (var h in held) {
                if (h.notification == notification) return h.match.mask(text);
            }
            return text;
        }

        [DBus (visible = false)]
        public bool holds(string text) {
            string t = text.strip().replace(" ", "").replace("-", "");
            foreach (var h in held) {
                if (h.code == t) return true;
            }
            return false;
        }

        private void drop_expired() {
            int64 now = get_real_time() / 1000000;
            var gone = new Gee.ArrayList<HeldCode>();
            foreach (var h in held) {
                if (h.expires <= now) gone.add(h);
            }
            foreach (var h in gone) release(h, false);
            if (gone.size > 0) changed();
        }

        private void arm_expiry() {
            if (expiry_source != 0) Source.remove(expiry_source);
            expiry_source = 0;
            if (held.size == 0) return;
            int64 now = get_real_time() / 1000000;
            int64 soonest = int64.MAX;
            foreach (var h in held) soonest = int64.min(soonest, h.expires);
            uint wait = (uint) int64.max(1, soonest - now);
            expiry_source = Timeout.add_seconds(wait, () => {
                expiry_source = 0;
                drop_expired();
                arm_expiry();
                return Source.REMOVE;
            });
        }

        private void release(HeldCode h, bool used) {
            held.remove(h);
            released(h.notification, h.match);
            if (used && settings != null && settings.get_boolean("one-time-code-delete-used")) delete_message(h);
        }

        private void delete_message(HeldCode h) {
            close_requested(h.notification);
            if (h.message == "" || h.app == "" || !GLib.DBus.is_name(h.app)) return;
            string path = "/" + h.app.replace(".", "/").replace("-", "_");
            Bus.get.begin(BusType.SESSION, null, (o, r) => {
                try {
                    var conn = Bus.get.end(r);
                    var platform = new HashTable<string, Variant>(str_hash, str_equal);
                    conn.call.begin(h.app, path, "org.freedesktop.Application", "ActivateAction",
                        new Variant("(sav@a{sv})", "delete-one-time-code", new Variant[] { new Variant.string(h.message) }, platform),
                        null, DBusCallFlags.NO_AUTO_START, 5000, null);
                } catch (Error e) {
                }
            });
        }

        [DBus (visible = false)]
        public void clear() {
            while (held.size > 0) release(held[0], false);
            arm_expiry();
            changed();
        }

        public void latest(out bool found, out uint id, out string code, out string service,
                           out string domain, out string app, out int64 expires) throws Error {
            drop_expired();
            found = held.size > 0;
            var h = found ? held[0] : null;
            id = h != null ? h.id : 0;
            code = h != null ? h.code : "";
            service = h != null ? h.service : "";
            domain = h != null ? h.domain : "";
            app = h != null ? h.app : "";
            expires = h != null ? h.expires : 0;
        }

        public void use(uint id) throws Error {
            foreach (var h in held) {
                if (h.id == id) {
                    release(h, true);
                    arm_expiry();
                    changed();
                    return;
                }
            }
        }

        public void forget(uint id) throws Error {
            foreach (var h in held) {
                if (h.id == id) {
                    release(h, false);
                    arm_expiry();
                    changed();
                    return;
                }
            }
        }
    }
}
