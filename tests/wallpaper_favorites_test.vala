using GLib;
using Singularity;

private GLib.Settings make_settings(GLib.SettingsBackend? backend = null) {
    var schema = SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true);
    assert(schema != null);
    return new GLib.Settings.full(schema,
        backend ?? SettingsBackend.memory_settings_backend_new(), null);
}

private void test_toggle_and_list() {
    var favorites = new WallpaperFavorites(make_settings());
    int changes = 0;
    favorites.favorites_changed.connect(() => changes++);
    favorites.toggle_favorite("/a");
    favorites.toggle_favorite("/b");
    assert(favorites.is_favorite("/a"));
    assert(favorites.list_favorites().length == 2);
    favorites.toggle_favorite("/a");
    assert(!favorites.is_favorite("/a"));
    assert(favorites.list_favorites()[0] == "/b");
    assert(changes == 3);
}

private void test_persistence_roundtrip() {
    var backend = SettingsBackend.memory_settings_backend_new();
    var first = new WallpaperFavorites(make_settings(backend));
    first.toggle_favorite("/a");
    first.toggle_favorite("/b");

    var restored = new WallpaperFavorites(make_settings(backend));
    assert(restored.is_favorite("/a"));
    assert(restored.is_favorite("/b"));
    restored.toggle_favorite("/a");
    var again = new WallpaperFavorites(make_settings(backend));
    assert(!again.is_favorite("/a"));
    assert(again.is_favorite("/b"));
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-favorites/toggle-and-list", test_toggle_and_list);
    Test.add_func("/wallpaper-favorites/persistence-roundtrip", test_persistence_roundtrip);
    return Test.run();
}
