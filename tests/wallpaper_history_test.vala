using GLib;
using Singularity;

private GLib.Settings make_settings(GLib.SettingsBackend? backend = null) {
    var schema = SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true);
    assert(schema != null);
    return new GLib.Settings.full(schema,
        backend ?? SettingsBackend.memory_settings_backend_new(), null);
}

private void test_back_forward_semantics() {
    var history = new WallpaperHistory(make_settings());
    history.record("/a");
    history.record("/b");
    history.record("/c");
    assert(history.go_back() == "/b");
    assert(history.go_back() == "/a");
    assert(history.go_forward() == "/b");
    history.record("/d");
    assert(!history.can_go_forward());
    assert(history.go_back() == "/b");
}

private void test_bounded_size() {
    var history = new WallpaperHistory(make_settings(), 3);
    history.record("/a");
    history.record("/b");
    history.record("/c");
    history.record("/d");
    assert(history.size == 3);
    assert(history.go_back() == "/c");
    assert(history.go_back() == "/b");
    assert(history.go_back() == null);
}

private void test_persistence_roundtrip() {
    var backend = SettingsBackend.memory_settings_backend_new();
    var first = new WallpaperHistory(make_settings(backend));
    first.record("/a");
    first.record("/b");
    first.record("/c");
    assert(first.go_back() == "/b");

    var restored = new WallpaperHistory(make_settings(backend));
    assert(restored.current_path == "/b");
    assert(restored.go_back() == "/a");
    assert(restored.go_forward() == "/b");
    assert(restored.go_forward() == "/c");
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-history/back-forward-semantics", test_back_forward_semantics);
    Test.add_func("/wallpaper-history/bounded-size", test_bounded_size);
    Test.add_func("/wallpaper-history/persistence-roundtrip", test_persistence_roundtrip);
    return Test.run();
}
