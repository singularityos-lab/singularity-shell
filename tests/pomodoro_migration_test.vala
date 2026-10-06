using GLib;
using Singularity;

private const string SCHEMAS = """<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="enabled-plugins" type="as"><default>[]</default></key>
    <key name="disabled-plugins" type="as"><default>[]</default></key>
  </schema>
</schemalist>
""";

private string root;

private void test_filter() {
    bool found;
    var kept = PomodoroPluginMigration.without({ "tray-icons", "pomodoro", "tailscale" }, "pomodoro", out found);
    assert(found);
    assert(kept.length == 2 && kept[0] == "tray-icons" && kept[1] == "tailscale");
    kept = PomodoroPluginMigration.without({ "tray-icons" }, "pomodoro", out found);
    assert(!found && kept.length == 1);
}

private void test_retires_once() {
    var desktop = new GLib.Settings("dev.sinty.desktop");
    string dir = Path.build_filename(root, "state-a");
    desktop.set_strv("enabled-plugins", { "tray-icons", "pomodoro" });
    desktop.set_strv("disabled-plugins", { "clock-timer-tile", "other-app-plugin" });
    assert(PomodoroPluginMigration.needed(dir));
    assert(PomodoroPluginMigration.run(desktop, dir));
    var now = desktop.get_strv("enabled-plugins");
    assert(now.length == 1 && now[0] == "tray-icons");
    var off = desktop.get_strv("disabled-plugins");
    assert(off.length == 1 && off[0] == "other-app-plugin");
    assert(!PomodoroPluginMigration.needed(dir));
    desktop.set_strv("enabled-plugins", { "pomodoro" });
    assert(!PomodoroPluginMigration.run(desktop, dir));
    assert(desktop.get_strv("enabled-plugins").length == 1);
}

private void test_absent_plugin_keeps_settings() {
    var desktop = new GLib.Settings("dev.sinty.desktop");
    string dir = Path.build_filename(root, "state-b");
    desktop.set_strv("enabled-plugins", { "tailscale" });
    desktop.set_strv("disabled-plugins", { "clock-timer-tile" });
    assert(!PomodoroPluginMigration.run(desktop, dir));
    assert(desktop.get_strv("enabled-plugins")[0] == "tailscale");
    assert(desktop.get_strv("disabled-plugins")[0] == "clock-timer-tile");
    assert(!PomodoroPluginMigration.needed(dir));
}

int main(string[] args) {
    try {
        root = DirUtils.make_tmp("pomodoro-migration-XXXXXX");
        FileUtils.set_contents(Path.build_filename(root, "test.gschema.xml"), SCHEMAS);
        int status;
        Process.spawn_sync(null, { "glib-compile-schemas", root }, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
        assert(status == 0);
    } catch (Error e) {
        error("setup: %s", e.message);
    }
    Environment.set_variable("GSETTINGS_SCHEMA_DIR", root, true);
    Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
    Test.init(ref args);
    Test.add_func("/pomodoro/migration/filter", test_filter);
    Test.add_func("/pomodoro/migration/retires-once", test_retires_once);
    Test.add_func("/pomodoro/migration/absent", test_absent_plugin_keeps_settings);
    return Test.run();
}
