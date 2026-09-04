using Singularity;

private void test_policy() {
    var normal = new SafeMode(false, "/tmp/not-used");
    var safe = new SafeMode(true, "/tmp/not-used");
    SafeFeature[] features = {
        SafeFeature.TILING,
        SafeFeature.PLUGINS,
        SafeFeature.CUSTOM_WIDGETS,
        SafeFeature.HAND_CONTROL,
        SafeFeature.SESSION_RESTORE,
        SafeFeature.AUTOSTART
    };

    foreach (var feature in features) {
        assert(normal.allows(feature));
        assert(!safe.allows(feature));
    }
}

private void test_marker_clear() {
    string dir;
    try {
        dir = DirUtils.make_tmp("singularity-safe-mode-test-XXXXXX");
    } catch (FileError e) {
        assert_not_reached();
    }
    string marker = Path.build_filename(dir, "safe-mode");
    try {
        FileUtils.set_contents(marker, "version=1\n");
    } catch (FileError e) {
        assert_not_reached();
    }

    var safe = new SafeMode(true, marker);
    assert(safe.clear_marker());
    assert(!FileUtils.test(marker, FileTest.EXISTS));
    assert(safe.clear_marker());
    DirUtils.remove(dir);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/safe-mode/policy", test_policy);
    Test.add_func("/safe-mode/marker-clear", test_marker_clear);
    return Test.run();
}
