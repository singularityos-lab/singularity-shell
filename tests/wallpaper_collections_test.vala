using GLib;
using Gee;
using Singularity;

private string make_tmp_dir() {
    string path = GLib.DirUtils.make_tmp("wpcollections-XXXXXX");
    return path;
}

private void write_collection(string dir, string filename, string contents) {
    string path = GLib.Path.build_filename(dir, filename);
    try {
        FileUtils.set_contents(path, contents);
    } catch (Error e) {
        error("test setup failed: %s", e.message);
    }
}

private void remove_tree(string path) {
    try {
        var file = File.new_for_path(path);
        if (!file.query_exists()) return;
        if (file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
            var en = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo info;
            while ((info = en.next_file()) != null) remove_tree(file.get_child(info.get_name()).get_path());
        }
        file.delete();
    } catch (Error e) { error("cleanup failed: %s", e.message); }
}

private WallpaperCollectionInfo user_collection(string root, string id = "user-pack") {
    string dir = Path.build_filename(root, id);
    DirUtils.create_with_parents(dir, 0700);
    string registry = Path.build_filename(root, id + ".collection");
    write_collection(root, id + ".collection", "registry\n");
    return new WallpaperCollectionInfo(id, "User Pack", "", dir, "static", "ocs", registry, root);
}

private void test_parses_id_name_artist_dir() {
    string root = make_tmp_dir();
    write_collection(root, "brandon.collection",
        "[Collection]\n" +
        "Id=brandon-perlow\n" +
        "Name=Brandon Perlow\n" +
        "Artist=Brandon Perlow\n" +
        "Type=static\n" +
        "Dir=/usr/share/backgrounds/vendor/brandon-perlow\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "brandon-perlow");
    assert(result[0].name == "Brandon Perlow");
    assert(result[0].artist == "Brandon Perlow");
    assert(result[0].dir == "/usr/share/backgrounds/vendor/brandon-perlow");
    assert(result[0].type == "static");
}

private void test_id_falls_back_to_filename_stem() {
    string root = make_tmp_dir();
    write_collection(root, "vendor.collection",
        "[Collection]\n" +
        "Name=Vendor OS\n" +
        "Dir=/usr/share/backgrounds/vendor\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "vendor");
}

private void test_skips_dir_less_collection() {
    string root = make_tmp_dir();
    write_collection(root, "broken.collection",
        "[Collection]\n" +
        "Id=broken\n" +
        "Name=Broken\n");
    write_collection(root, "good.collection",
        "[Collection]\n" +
        "Id=good\n" +
        "Name=Good\n" +
        "Dir=/some/dir\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "good");
}

private void test_ignores_non_collection_files_and_missing_dirs() {
    string root = make_tmp_dir();
    write_collection(root, "notes.txt", "not a collection\n");

    var result = WallpaperCollections.parse({ root, "/definitely/does/not/exist" });

    assert(result.size == 0);
}

private void test_dedupes_by_id_first_root_wins() {
    string root_a = make_tmp_dir();
    string root_b = make_tmp_dir();
    write_collection(root_a, "vendor.collection",
        "[Collection]\nId=vendor\nName=System\nDir=/system/vendor\n");
    write_collection(root_b, "vendor.collection",
        "[Collection]\nId=vendor\nName=User Override\nDir=/user/vendor\n");

    var result = WallpaperCollections.parse({ root_a, root_b });

    assert(result.size == 1);
    assert(result[0].name == "System");
}

private void test_unsplash_is_theme_pack() {
    var collection = new WallpaperCollectionInfo("unsplash", "Unsplash", "", "/tmp/unsplash", "static");
    assert(collection.theme_pack);
}

private void test_protected_requires_origin_and_home_path() {
    string root = make_tmp_dir();
    string user_dir = Path.build_filename(root, "user-pack");
    DirUtils.create_with_parents(user_dir, 0700);
    string registry = Path.build_filename(root, "user-pack.collection");
    write_collection(root, "user-pack.collection", "registry\n");
    var no_origin = new WallpaperCollectionInfo("ncz", "NCZ", "", user_dir, "static", "", registry, root);
    var system_path = new WallpaperCollectionInfo("bing", "Bing", "", "/var/cache/ncz-wallpapers/bing", "static", "bing", registry, root);
    var user = new WallpaperCollectionInfo("ocs-x", "OCS", "", user_dir, "static", "ocs", registry, root);
    assert(!no_origin.deletable);
    assert(!system_path.deletable);
    assert(user.deletable);
    remove_tree(root);
}

private void test_delete_pack_is_scoped() {
    string root = make_tmp_dir();
    var target = user_collection(root, "target");
    var other = user_collection(root, "other");
    write_collection(target.dir, "one.jpg", "image");
    write_collection(other.dir, "keep.jpg", "image");
    try { WallpaperCollections.delete_pack(target); } catch (Error e) { error("delete failed: %s", e.message); }
    assert(!FileUtils.test(target.dir, FileTest.EXISTS));
    assert(!FileUtils.test(target.registry_path, FileTest.EXISTS));
    assert(FileUtils.test(other.dir, FileTest.IS_DIR));
    assert(FileUtils.test(other.registry_path, FileTest.IS_REGULAR));
    remove_tree(root);
}

private void test_delete_image_updates_sidecar_and_manifest() {
    string root = make_tmp_dir();
    var collection = user_collection(root);
    write_collection(collection.dir, "one.jpg", "image");
    write_collection(collection.dir, "one.json", "{}");
    write_collection(collection.dir, "two.jpg", "image");
    write_collection(collection.dir, "pack.json", "{\"images\":[{\"file\":\"one.jpg\"},{\"file\":\"two.jpg\"}]}");
    try {
        bool removed_pack = WallpaperCollections.delete_image(collection,
            File.new_for_path(Path.build_filename(collection.dir, "one.jpg")).get_uri());
        assert(!removed_pack);
    } catch (Error e) { error("delete image failed: %s", e.message); }
    assert(!FileUtils.test(Path.build_filename(collection.dir, "one.jpg"), FileTest.EXISTS));
    assert(!FileUtils.test(Path.build_filename(collection.dir, "one.json"), FileTest.EXISTS));
    assert(FileUtils.test(Path.build_filename(collection.dir, "two.jpg"), FileTest.IS_REGULAR));
    string manifest;
    try { FileUtils.get_contents(Path.build_filename(collection.dir, "pack.json"), out manifest); }
    catch (Error e) { error("manifest read failed: %s", e.message); }
    assert(!manifest.contains("one.jpg"));
    assert(manifest.contains("two.jpg"));
    remove_tree(root);
}

private void test_delete_last_image_removes_pack_and_active_match() {
    string root = make_tmp_dir();
    var collection = user_collection(root);
    string path = Path.build_filename(collection.dir, "only.jpg");
    write_collection(collection.dir, "only.jpg", "image");
    string uri = File.new_for_path(path).get_uri();
    assert(collection.contains_uri(uri));
    assert(WallpaperCollections.needs_background_fallback(collection, uri));
    assert(!WallpaperCollections.needs_background_fallback(collection,
        File.new_for_path(Path.build_filename(root, "other.jpg")).get_uri()));
    try { assert(WallpaperCollections.delete_image(collection, uri)); }
    catch (Error e) { error("delete last image failed: %s", e.message); }
    assert(!FileUtils.test(collection.dir, FileTest.EXISTS));
    assert(!FileUtils.test(collection.registry_path, FileTest.EXISTS));
    remove_tree(root);
}

private WallpaperCollectionInfo import_collection(string root) {
    string dir = Path.build_filename(root, "backgrounds", "singularity-dynamic");
    DirUtils.create_with_parents(dir, 0700);
    write_collection(root, "dynamic-imports.collection", "registry\n");
    return new WallpaperCollectionInfo("dynamic-imports", "Dynamic", "", dir, "dynamic", "import",
        Path.build_filename(root, "dynamic-imports.collection"), root);
}

private string write_manifest(string dir, string name, string[] images) {
    DirUtils.create_with_parents(dir, 0700);
    var sb = new StringBuilder("{\"version\": 1, \"kind\": \"time\", \"frames\": [");
    for (int i = 0; i < images.length; i++) {
        if (i > 0) sb.append(", ");
        sb.append("{\"image\": \"%s\", \"time\": \"%02d:00\"}".printf(images[i], i * 6));
    }
    sb.append("]}");
    write_collection(dir, name, sb.str);
    return Path.build_filename(dir, name);
}

private void test_delete_dynamic_removes_own_frames_only() {
    string root = make_tmp_dir();
    var collection = import_collection(root);
    string system_dir = Path.build_filename(root, "usr-share", "backgrounds");
    DirUtils.create_with_parents(system_dir, 0700);
    write_collection(system_dir, "shared.png", "system image");
    string system_image = Path.build_filename(system_dir, "shared.png");

    string sunset = Path.build_filename(collection.dir, "sunset");
    DirUtils.create_with_parents(sunset, 0700);
    write_collection(sunset, "frame-00.png", "a");
    write_collection(sunset, "frame-01.png", "b");
    write_collection(collection.dir, "outside.png", "sibling");
    FileUtils.symlink(system_image, Path.build_filename(sunset, "link.png"));
    string manifest = write_manifest(sunset, "sunset.dynamic.json",
        { "frame-00.png", "frame-01.png", system_image, "link.png", "../outside.png" });

    string other = Path.build_filename(collection.dir, "other");
    DirUtils.create_with_parents(other, 0700);
    write_collection(other, "own.png", "c");
    write_manifest(other, "other.dynamic.json", { "own.png", "../sunset/frame-01.png" });

    string[] planned = WallpaperCollections.dynamic_files_to_delete(collection, manifest);
    assert(planned.length == 2);

    try {
        assert(!WallpaperCollections.delete_image(collection, File.new_for_path(manifest).get_uri()));
    } catch (Error e) { error("delete dynamic failed: %s", e.message); }
    assert(!FileUtils.test(manifest, FileTest.EXISTS));
    assert(!FileUtils.test(Path.build_filename(sunset, "frame-00.png"), FileTest.EXISTS));
    assert(!FileUtils.test(Path.build_filename(sunset, "link.png"), FileTest.EXISTS | FileTest.IS_SYMLINK));
    assert(FileUtils.test(Path.build_filename(sunset, "frame-01.png"), FileTest.IS_REGULAR));
    assert(FileUtils.test(system_image, FileTest.IS_REGULAR));
    assert(FileUtils.test(Path.build_filename(collection.dir, "outside.png"), FileTest.IS_REGULAR));
    assert(FileUtils.test(Path.build_filename(other, "own.png"), FileTest.IS_REGULAR));
    assert(FileUtils.test(Path.build_filename(other, "other.dynamic.json"), FileTest.IS_REGULAR));
    assert(FileUtils.test(collection.registry_path, FileTest.IS_REGULAR));
    remove_tree(root);
}

private void test_delete_last_dynamic_removes_folder_and_pack() {
    string root = make_tmp_dir();
    var collection = import_collection(root);
    string only = Path.build_filename(collection.dir, "only");
    DirUtils.create_with_parents(only, 0700);
    write_collection(only, "frame-00.png", "a");
    write_collection(only, "frame-01.png", "b");
    string manifest = write_manifest(only, "only.dynamic.json", { "frame-00.png", "frame-01.png" });
    try {
        assert(WallpaperCollections.delete_image(collection, File.new_for_path(manifest).get_uri()));
    } catch (Error e) { error("delete last dynamic failed: %s", e.message); }
    assert(!FileUtils.test(only, FileTest.EXISTS));
    assert(!FileUtils.test(collection.dir, FileTest.EXISTS));
    assert(!FileUtils.test(collection.registry_path, FileTest.EXISTS));
    remove_tree(root);
}

private void test_delete_dynamic_keeps_unknown_files() {
    string root = make_tmp_dir();
    var collection = import_collection(root);
    string mine = Path.build_filename(collection.dir, "mine");
    DirUtils.create_with_parents(mine, 0700);
    write_collection(mine, "frame-00.png", "a");
    write_collection(mine, "notes.txt", "user file");
    string manifest = write_manifest(mine, "mine.dynamic.json", { "frame-00.png" });
    try {
        assert(!WallpaperCollections.delete_image(collection, File.new_for_path(manifest).get_uri()));
    } catch (Error e) { error("delete dynamic failed: %s", e.message); }
    assert(!FileUtils.test(Path.build_filename(mine, "frame-00.png"), FileTest.EXISTS));
    assert(FileUtils.test(Path.build_filename(mine, "notes.txt"), FileTest.IS_REGULAR));
    assert(FileUtils.test(collection.registry_path, FileTest.IS_REGULAR));
    remove_tree(root);
}

private void test_delete_dynamic_refuses_protected_collection() {
    string root = make_tmp_dir();
    string dir = Path.build_filename(root, "system");
    string waves = Path.build_filename(dir, "waves");
    DirUtils.create_with_parents(waves, 0700);
    write_collection(waves, "frame.png", "a");
    string manifest = write_manifest(waves, "waves.dynamic.json", { "frame.png" });
    var system = new WallpaperCollectionInfo("singularity", "Singularity", "", dir, "static", "", "", root);
    bool refused = false;
    try {
        WallpaperCollections.delete_image(system, File.new_for_path(manifest).get_uri());
    } catch (Error e) {
        refused = true;
    }
    assert(refused);
    assert(FileUtils.test(manifest, FileTest.IS_REGULAR));
    assert(FileUtils.test(Path.build_filename(waves, "frame.png"), FileTest.IS_REGULAR));
    remove_tree(root);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-collections/parses-id-name-artist-dir", test_parses_id_name_artist_dir);
    Test.add_func("/wallpaper-collections/id-falls-back-to-filename-stem", test_id_falls_back_to_filename_stem);
    Test.add_func("/wallpaper-collections/skips-dir-less-collection", test_skips_dir_less_collection);
    Test.add_func("/wallpaper-collections/ignores-non-collection-files-and-missing-dirs", test_ignores_non_collection_files_and_missing_dirs);
    Test.add_func("/wallpaper-collections/dedupes-by-id-first-root-wins", test_dedupes_by_id_first_root_wins);
    Test.add_func("/wallpaper-collections/unsplash-theme-pack", test_unsplash_is_theme_pack);
    Test.add_func("/wallpaper-collections/protected-requires-origin-and-home-path", test_protected_requires_origin_and_home_path);
    Test.add_func("/wallpaper-collections/delete-pack-is-scoped", test_delete_pack_is_scoped);
    Test.add_func("/wallpaper-collections/delete-image-updates-sidecar-and-manifest", test_delete_image_updates_sidecar_and_manifest);
    Test.add_func("/wallpaper-collections/delete-last-image-removes-pack-and-active-match", test_delete_last_image_removes_pack_and_active_match);
    Test.add_func("/wallpaper-collections/delete-dynamic-removes-own-frames-only", test_delete_dynamic_removes_own_frames_only);
    Test.add_func("/wallpaper-collections/delete-last-dynamic-removes-folder-and-pack", test_delete_last_dynamic_removes_folder_and_pack);
    Test.add_func("/wallpaper-collections/delete-dynamic-keeps-unknown-files", test_delete_dynamic_keeps_unknown_files);
    Test.add_func("/wallpaper-collections/delete-dynamic-refuses-protected-collection", test_delete_dynamic_refuses_protected_collection);
    return Test.run();
}
