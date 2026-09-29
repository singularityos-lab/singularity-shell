using GLib;
using Gee;
using Singularity;

private string fixture_root;

private string make_dir(string name) {
    string path = Path.build_filename(fixture_root, name);
    DirUtils.create_with_parents(path, 0700);
    return path;
}

private string image_file(string dir, string name, int width = 1920, int height = 1080) {
    string path = Path.build_filename(dir, name + ".svg");
    try {
        DirUtils.create_with_parents(dir, 0700);
        FileUtils.set_contents(path,
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\"><rect width=\"100%%\" height=\"100%%\"/></svg>".printf(width, height));
    } catch (Error e) { error("fixture: %s", e.message); }
    return File.new_for_path(path).get_uri();
}

private void write_collection(string registry, string id, string dir) {
    try {
        DirUtils.create_with_parents(registry, 0700);
        FileUtils.set_contents(Path.build_filename(registry, id + ".collection"),
            "[Collection]\nId=%s\nName=%s\nDir=%s\n".printf(id, id, dir));
    } catch (Error e) { error("fixture: %s", e.message); }
}

private void test_pick_single_candidate() {
    var uris = new ArrayList<string>();
    uris.add("file:///a.png");
    assert(WallpaperRotator.pick(uris, "file:///a.png", 0) == "file:///a.png");
}

private void test_pick_is_deterministic_for_a_given_roll() {
    var uris = new ArrayList<string>();
    uris.add("file:///a.png");
    uris.add("file:///b.png");
    uris.add("file:///c.png");
    assert(WallpaperRotator.pick(uris, null, 0) == "file:///a.png");
    assert(WallpaperRotator.pick(uris, null, 1) == "file:///b.png");
    assert(WallpaperRotator.pick(uris, null, 5) == "file:///c.png");
}

private void test_pick_never_returns_the_current_wallpaper() {
    var uris = new ArrayList<string>();
    uris.add("file:///a.png");
    uris.add("file:///b.png");
    uris.add("file:///c.png");
    for (uint32 roll = 0; roll < 12; roll++) {
        assert(WallpaperRotator.pick(uris, "file:///b.png", roll) != "file:///b.png");
    }
}

private void test_pick_on_empty_list() {
    assert(WallpaperRotator.pick(new ArrayList<string>(), null, 0) == null);
}

private void test_minimum_resolution_excludes_small_candidates() {
    var candidates = new ArrayList<WallpaperCandidate>();
    candidates.add(new WallpaperCandidate("file:///small.jpg", false, 640, 480));
    candidates.add(new WallpaperCandidate("file:///large.jpg", false, 1920, 1080));
    var regarded = WallpaperRotator.regard(candidates, 1280, 720, false, 0.0);
    assert(regarded.size == 1);
    assert(regarded[0].uri == "file:///large.jpg");
}

private void test_empty_resolution_pool_falls_back() {
    var candidates = new ArrayList<WallpaperCandidate>();
    candidates.add(new WallpaperCandidate("file:///small-a.jpg", false, 640, 480));
    candidates.add(new WallpaperCandidate("file:///small-b.jpg", false, 800, 600));
    var regarded = WallpaperRotator.regard(candidates, 1280, 720, false, 0.0);
    assert(regarded.size == 2);
}

private void test_aspect_preference_uses_display_ratio() {
    var candidates = new ArrayList<WallpaperCandidate>();
    candidates.add(new WallpaperCandidate("file:///portrait.jpg", false, 1080, 1920));
    candidates.add(new WallpaperCandidate("file:///wide.jpg", false, 1920, 1080));
    var regarded = WallpaperRotator.regard(candidates, 1, 1, true, 16.0 / 9.0);
    assert(regarded.size == 1);
    assert(regarded[0].uri == "file:///wide.jpg");
}

private void test_favorites_receive_three_times_the_weight() {
    var settings = new GLib.Settings("dev.sinty.desktop");
    var favorites = new WallpaperFavorites(settings);
    string favorite_path = Path.build_filename(fixture_root, "favorite.jpg");
    favorites.toggle_favorite(favorite_path);
    var candidates = new ArrayList<WallpaperCandidate>();
    candidates.add(new WallpaperCandidate(File.new_for_path(favorite_path).get_uri(), false, 1920, 1080));
    candidates.add(new WallpaperCandidate("file:///ordinary.jpg", false, 1920, 1080));
    int favorite_picks = 0;
    for (uint32 roll = 0; roll < 400; roll++) {
        string? chosen = WallpaperRotator.pick_candidates(candidates, null, roll, true, favorites);
        if (chosen == candidates[0].uri) favorite_picks++;
    }
    assert(favorite_picks == 300);
    favorites.toggle_favorite(favorite_path);
}

private void test_rotates_within_the_selected_collection_only() {
    string registry = make_dir("registry-scoped");
    string alpha = make_dir("alpha");
    string beta = make_dir("beta");
    string a1 = image_file(alpha, "a1");
    string a2 = image_file(alpha, "a2");
    image_file(beta, "b1");
    write_collection(registry, "alpha", alpha);
    write_collection(registry, "beta", beta);

    string config = make_dir("config-scoped");
    new WallpaperRotationState(config).set_selected_collection("alpha");

    var rotator = new WallpaperRotator(config, { registry });
    for (int i = 0; i < 8; i++) {
        string? chosen = rotator.choose_next();
        assert(chosen == a1 || chosen == a2);
    }
}

private void test_stale_collection_id_falls_back_to_the_first() {
    string registry = make_dir("registry-stale");
    string alpha = make_dir("alpha-stale");
    string only = image_file(alpha, "only");
    write_collection(registry, "alpha", alpha);

    string config = make_dir("config-stale");
    new WallpaperRotationState(config).set_selected_collection("uninstalled-pack");

    var rotator = new WallpaperRotator(config, { registry });
    assert(rotator.choose_next() == only);
}

private void test_empty_collection_leaves_the_wallpaper_alone() {
    string registry = make_dir("registry-empty");
    string empty = make_dir("empty-pack");
    write_collection(registry, "empty", empty);

    string config = make_dir("config-empty");
    new WallpaperRotationState(config).set_selected_collection("empty");

    var rotator = new WallpaperRotator(config, { registry });
    assert(rotator.choose_next() == null);
}

private void test_no_registry_at_all() {
    var rotator = new WallpaperRotator(make_dir("config-none"),
                                       { Path.build_filename(fixture_root, "no-such-registry") });
    assert(rotator.choose_next() == null);
}

private void test_rotate_now_announces_and_records_the_choice() {
    string registry = make_dir("registry-emit");
    string pack = make_dir("emit-pack");
    string only = image_file(pack, "only");
    write_collection(registry, "emit", pack);

    string config = make_dir("config-emit");
    new WallpaperRotationState(config).set_selected_collection("emit");

    var rotator = new WallpaperRotator(config, { registry });
    string? announced = null;
    rotator.wallpaper_selected.connect((uri) => { announced = uri; });
    rotator.rotate_now();

    assert(announced == only);
    assert(rotator.current_uri == only);
}

private void test_rotate_now_announces_nothing_when_there_is_nothing() {
    string config = make_dir("config-silent");
    var rotator = new WallpaperRotator(config,
                                       { Path.build_filename(fixture_root, "no-such-registry") });
    bool announced = false;
    rotator.wallpaper_selected.connect((uri) => { announced = true; });
    rotator.rotate_now();
    assert(!announced);
}

private void test_manual_trigger_changes_immediately() {
    string registry = make_dir("registry-manual");
    string pack = make_dir("manual-pack");
    string current = image_file(pack, "current");
    string next = image_file(pack, "next");
    write_collection(registry, "manual", pack);
    string config = make_dir("config-manual");
    new WallpaperRotationState(config).set_selected_collection("manual");

    var rotator = new WallpaperRotator(config, { registry });
    rotator.current_uri = current;
    string? announced = null;
    rotator.wallpaper_selected.connect((uri) => { announced = uri; });
    rotator.rotate_now();
    assert(announced == next);
    assert(rotator.current_uri == next);
}

private void test_choose_next_for_excludes_the_supplied_wallpaper() {
    string registry = make_dir("registry-exclude");
    string pack = make_dir("exclude-pack");
    string a = image_file(pack, "a");
    string b = image_file(pack, "b");
    write_collection(registry, "exclude", pack);

    string config = make_dir("config-exclude");
    new WallpaperRotationState(config).set_selected_collection("exclude");

    var rotator = new WallpaperRotator(config, { registry });
    for (int i = 0; i < 8; i++) {
        assert(rotator.choose_next_for(a) == b);
        assert(rotator.choose_next_for(b) == a);
    }
}

private void test_rotate_async_announces_on_the_main_loop() {
    string registry = make_dir("registry-async");
    string pack = make_dir("async-pack");
    string only = image_file(pack, "only");
    write_collection(registry, "async", pack);

    string config = make_dir("config-async");
    new WallpaperRotationState(config).set_selected_collection("async");

    var rotator = new WallpaperRotator(config, { registry });
    var loop = new MainLoop();
    string? announced = null;
    rotator.wallpaper_selected.connect((uri) => {
        announced = uri;
        loop.quit();
    });
    // Avoid removing a timeout source after its callback already removed it.
    bool timed_out = false;
    uint bail = Timeout.add_seconds(10, () => {
        timed_out = true;
        loop.quit();
        return Source.REMOVE;
    });

    rotator.rotate_async();
    loop.run();
    if (!timed_out) Source.remove(bail);

    assert(!timed_out);
    assert(announced == only);
    assert(rotator.current_uri == only);
}

private void test_untouched_install_does_not_rotate() {
    string config = make_dir("config-untouched");
    var rotator = new WallpaperRotator(config, { make_dir("registry-untouched") });
    rotator.start();
    assert(rotator.armed_interval_seconds == 0);
    rotator.stop();
}

private void test_timer_follows_the_rotation_state() {
    string config = make_dir("config-timer");
    var state = new WallpaperRotationState(config);
    var rotator = new WallpaperRotator(config, { make_dir("registry-timer") });

    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 0);

    state.set_rotate_enabled(true);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 600);

    state.set_rotate_interval_seconds(3600);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 3600);

    state.set_rotate_enabled(false);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 0);

    state.set_rotate_enabled(true);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 3600);

    rotator.stop();
    assert(rotator.armed_interval_seconds == 0);
}

public int main(string[] args) {
    Test.init(ref args);
    try { fixture_root = DirUtils.make_tmp("wallpaper-rotator-XXXXXX"); }
    catch (Error e) { error("fixture: %s", e.message); }

    Test.add_func("/wallpaper-rotator/pick-single-candidate", test_pick_single_candidate);
    Test.add_func("/wallpaper-rotator/pick-deterministic-roll", test_pick_is_deterministic_for_a_given_roll);
    Test.add_func("/wallpaper-rotator/pick-skips-current", test_pick_never_returns_the_current_wallpaper);
    Test.add_func("/wallpaper-rotator/pick-empty", test_pick_on_empty_list);
    Test.add_func("/wallpaper-rotator/regard-minimum-resolution", test_minimum_resolution_excludes_small_candidates);
    Test.add_func("/wallpaper-rotator/regard-empty-fallback", test_empty_resolution_pool_falls_back);
    Test.add_func("/wallpaper-rotator/regard-aspect", test_aspect_preference_uses_display_ratio);
    Test.add_func("/wallpaper-rotator/favorites-weighting", test_favorites_receive_three_times_the_weight);
    Test.add_func("/wallpaper-rotator/scoped-to-selected-collection", test_rotates_within_the_selected_collection_only);
    Test.add_func("/wallpaper-rotator/stale-id-falls-back", test_stale_collection_id_falls_back_to_the_first);
    Test.add_func("/wallpaper-rotator/empty-collection-is-a-no-op", test_empty_collection_leaves_the_wallpaper_alone);
    Test.add_func("/wallpaper-rotator/no-registry", test_no_registry_at_all);
    Test.add_func("/wallpaper-rotator/rotate-now-announces", test_rotate_now_announces_and_records_the_choice);
    Test.add_func("/wallpaper-rotator/rotate-now-silent-when-empty", test_rotate_now_announces_nothing_when_there_is_nothing);
    Test.add_func("/wallpaper-rotator/manual-trigger-changes", test_manual_trigger_changes_immediately);
    Test.add_func("/wallpaper-rotator/choose-next-for-excludes", test_choose_next_for_excludes_the_supplied_wallpaper);
    Test.add_func("/wallpaper-rotator/rotate-async-announces", test_rotate_async_announces_on_the_main_loop);
    Test.add_func("/wallpaper-rotator/untouched-install-does-not-rotate", test_untouched_install_does_not_rotate);
    Test.add_func("/wallpaper-rotator/timer-follows-state", test_timer_follows_the_rotation_state);
    return Test.run();
}
