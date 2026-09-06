using GLib;
using Singularity;

private string make_tmp_dir() {
    return GLib.DirUtils.make_tmp("wprotation-XXXXXX");
}

private void test_selected_collection_defaults_when_unset() {
    var state = new WallpaperRotationState(make_tmp_dir());
    assert(state.get_selected_collection("ncz") == "ncz");
}

private void test_selected_collection_roundtrips() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_selected_collection("brandon-perlow");
    assert(state.get_selected_collection("ncz") == "brandon-perlow");
}

private void test_selected_collection_strips_whitespace() {
    string dir = make_tmp_dir();
    try {
        FileUtils.set_contents(GLib.Path.build_filename(dir, "collection"), " bing \n");
    } catch (Error e) { error("test setup failed: %s", e.message); }
    var state = new WallpaperRotationState(dir);
    assert(state.get_selected_collection("ncz") == "bing");
}

private void test_rotate_enabled_defaults_true() {
    var state = new WallpaperRotationState(make_tmp_dir());
    assert(state.get_rotate_enabled() == true);
}

private void test_rotate_enabled_roundtrips_false() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_rotate_enabled(false);
    assert(state.get_rotate_enabled() == false);
    state.set_rotate_enabled(true);
    assert(state.get_rotate_enabled() == true);
}

private void test_rotate_interval_defaults_to_600() {
    var state = new WallpaperRotationState(make_tmp_dir());
    assert(state.get_rotate_interval_seconds() == 600);
}

private void test_rotate_interval_roundtrips() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_rotate_interval_seconds(1800);
    assert(state.get_rotate_interval_seconds() == 1800);
}

private void test_rotate_interval_clamps_to_30_minimum() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_rotate_interval_seconds(5);
    assert(state.get_rotate_interval_seconds() == 30);
}

private void test_rotate_interval_garbage_on_disk_reads_as_default() {
    string dir = make_tmp_dir();
    try {
        FileUtils.set_contents(GLib.Path.build_filename(dir, "rotate-interval"), "not-a-number\n");
    } catch (Error e) { error("test setup failed: %s", e.message); }
    var state = new WallpaperRotationState(dir);
    assert(state.get_rotate_interval_seconds() == 600);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-rotation-state/selected-collection-defaults-when-unset", test_selected_collection_defaults_when_unset);
    Test.add_func("/wallpaper-rotation-state/selected-collection-roundtrips", test_selected_collection_roundtrips);
    Test.add_func("/wallpaper-rotation-state/selected-collection-strips-whitespace", test_selected_collection_strips_whitespace);
    Test.add_func("/wallpaper-rotation-state/rotate-enabled-defaults-true", test_rotate_enabled_defaults_true);
    Test.add_func("/wallpaper-rotation-state/rotate-enabled-roundtrips-false", test_rotate_enabled_roundtrips_false);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-defaults-to-600", test_rotate_interval_defaults_to_600);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-roundtrips", test_rotate_interval_roundtrips);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-clamps-to-30-minimum", test_rotate_interval_clamps_to_30_minimum);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-garbage-on-disk-reads-as-default", test_rotate_interval_garbage_on_disk_reads_as_default);
    return Test.run();
}