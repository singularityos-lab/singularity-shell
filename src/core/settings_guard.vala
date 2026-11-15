namespace Singularity {

    public class SettingsGuard : Object {

        public static bool has(GLib.Settings settings, string key) {
            return settings.settings_schema != null && settings.settings_schema.has_key(key);
        }

        public static Variant value(GLib.Settings settings, string key, string type) {
            if (has(settings, key)) {
                var v = settings.get_value(key);
                if (v != null) return v;
            }
            warning("SettingsGuard: %s has no key %s, using an empty %s", settings.schema_id, key, type);
            var t = new VariantType(type);
            if (t.is_array()) return new Variant.array(t.element(), {});
            return new Variant.maybe(t, null);
        }

        public static void store(GLib.Settings settings, string key, Variant v) {
            if (has(settings, key)) settings.set_value(key, v);
            else warning("SettingsGuard: %s has no key %s, not saved", settings.schema_id, key);
        }
    }
}
