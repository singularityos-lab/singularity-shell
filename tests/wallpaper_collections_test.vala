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

private void test_parses_id_name_artist_dir() {
    string root = make_tmp_dir();
    write_collection(root, "brandon.collection",
        "[Collection]\n" +
        "Id=brandon-perlow\n" +
        "Name=Brandon Perlow\n" +
        "Artist=Brandon Perlow\n" +
        "Type=static\n" +
        "Dir=/usr/share/backgrounds/ncz/brandon-perlow\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "brandon-perlow");
    assert(result[0].name == "Brandon Perlow");
    assert(result[0].artist == "Brandon Perlow");
    assert(result[0].dir == "/usr/share/backgrounds/ncz/brandon-perlow");
    assert(result[0].type == "static");
}

private void test_id_falls_back_to_filename_stem() {
    string root = make_tmp_dir();
    write_collection(root, "ncz.collection",
        "[Collection]\n" +
        "Name=NCZ-OS\n" +
        "Dir=/usr/share/backgrounds/ncz\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "ncz");
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
    write_collection(root_a, "ncz.collection",
        "[Collection]\nId=ncz\nName=System\nDir=/system/ncz\n");
    write_collection(root_b, "ncz.collection",
        "[Collection]\nId=ncz\nName=User Override\nDir=/user/ncz\n");

    var result = WallpaperCollections.parse({ root_a, root_b });

    assert(result.size == 1);
    assert(result[0].name == "System");
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-collections/parses-id-name-artist-dir", test_parses_id_name_artist_dir);
    Test.add_func("/wallpaper-collections/id-falls-back-to-filename-stem", test_id_falls_back_to_filename_stem);
    Test.add_func("/wallpaper-collections/skips-dir-less-collection", test_skips_dir_less_collection);
    Test.add_func("/wallpaper-collections/ignores-non-collection-files-and-missing-dirs", test_ignores_non_collection_files_and_missing_dirs);
    Test.add_func("/wallpaper-collections/dedupes-by-id-first-root-wins", test_dedupes_by_id_first_root_wins);
    return Test.run();
}
