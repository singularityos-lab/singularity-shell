using GLib;

namespace Singularity.SettingsSafety {
    private bool accepts(GLib.Settings settings, string key) {
        if (!settings.settings_schema.has_key(key)) {
            warning("Attempt to write unknown gsettings key '%s'; ignored.", key);
            return false;
        }
        return true;
    }

    public bool set_string(GLib.Settings settings, string key, string value) {
        return accepts(settings, key) && settings.set_string(key, value);
    }

    public bool set_value(GLib.Settings settings, string key, GLib.Variant value) {
        return accepts(settings, key) && settings.set_value(key, value);
    }

    public bool set_strv(GLib.Settings settings, string key, string[] value) {
        return accepts(settings, key) && settings.set_strv(key, value);
    }
}
