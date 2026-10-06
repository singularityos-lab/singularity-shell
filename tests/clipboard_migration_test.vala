using GLib;
using Singularity;

private const string SCHEMAS = """<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="enabled-plugins" type="as"><default>[]</default></key>
  </schema>
  <schema id="dev.sinty.desktop.clipboard" path="/dev/sinty/desktop/clipboard/">
    <key name="history-enabled" type="b"><default>false</default></key>
  </schema>
</schemalist>
""";

private string root;

private void test_filter() {
    bool found;
    var kept = ClipboardPluginMigration.without_legacy({ "tray-icons", "clipboard-history", "tailscale" }, out found);
    assert(found);
    assert(kept.length == 2 && kept[0] == "tray-icons" && kept[1] == "tailscale");
    kept = ClipboardPluginMigration.without_legacy({ "tray-icons" }, out found);
    assert(!found && kept.length == 1);
    kept = ClipboardPluginMigration.without_legacy({}, out found);
    assert(!found && kept.length == 0);
}

private void test_retires_once() {
    var desktop = new GLib.Settings("dev.sinty.desktop");
    var clip = new GLib.Settings("dev.sinty.desktop.clipboard");
    string dir = Path.build_filename(root, "state-a");
    desktop.set_strv("enabled-plugins", { "tray-icons", "clipboard-history" });
    clip.set_boolean("history-enabled", false);
    assert(ClipboardPluginMigration.needed(dir));
    assert(ClipboardPluginMigration.run(desktop, clip, dir));
    var now = desktop.get_strv("enabled-plugins");
    assert(now.length == 1 && now[0] == "tray-icons");
    assert(clip.get_boolean("history-enabled"));
    assert(!ClipboardPluginMigration.needed(dir));
    desktop.set_strv("enabled-plugins", { "clipboard-history" });
    assert(!ClipboardPluginMigration.run(desktop, clip, dir));
    assert(desktop.get_strv("enabled-plugins").length == 1);
}

private void test_absent_plugin_keeps_settings() {
    var desktop = new GLib.Settings("dev.sinty.desktop");
    var clip = new GLib.Settings("dev.sinty.desktop.clipboard");
    string dir = Path.build_filename(root, "state-b");
    desktop.set_strv("enabled-plugins", { "tailscale" });
    clip.set_boolean("history-enabled", false);
    assert(!ClipboardPluginMigration.run(desktop, clip, dir));
    assert(desktop.get_strv("enabled-plugins")[0] == "tailscale");
    assert(!clip.get_boolean("history-enabled"));
    assert(!ClipboardPluginMigration.needed(dir));
}

int main(string[] args) {
    try {
        root = DirUtils.make_tmp("clipboard-migration-XXXXXX");
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
    Test.add_func("/clipboard/migration/filter", test_filter);
    Test.add_func("/clipboard/migration/retires-once", test_retires_once);
    Test.add_func("/clipboard/migration/absent", test_absent_plugin_keeps_settings);
    return Test.run();
}
