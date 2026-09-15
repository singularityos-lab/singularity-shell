using GLib;
using Singularity;

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/settings-safety/rejects-unknown-key", () => {
        Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
        var settings = new Settings("org.gnome.desktop.interface");
        Test.expect_message(null, LogLevelFlags.LEVEL_WARNING,
            "*unknown gsettings key 'definitely-not-a-real-key'*ignored*");
        assert(!SettingsSafety.set_string(settings, "definitely-not-a-real-key", "value"));
        Test.assert_expected_messages();
    });
    Test.add_func("/settings-safety/writes-known-key", () => {
        Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
        var settings = new Settings("org.gnome.desktop.interface");
        assert(SettingsSafety.set_string(settings, "color-scheme", "prefer-dark"));
        assert(settings.get_string("color-scheme") == "prefer-dark");
    });
    return Test.run();
}
