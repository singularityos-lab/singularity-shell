using GLib;
using Gee;
using Singularity;

private string fixture_root;
private string ncz;
private string artist;
private string bing;

private string image_file(string dir, string name) {
    string path = Path.build_filename(dir, name + ".svg");
    try {
        DirUtils.create_with_parents(dir, 0700);
        FileUtils.set_contents(path, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"><rect width=\"1\" height=\"1\"/></svg>");
    } catch (Error e) { error("fixture: %s", e.message); }
    return File.new_for_path(path).get_uri();
}

private void test_recent_membership() {
    string base_uri = image_file(ncz, "base");
    string art_uri = image_file(artist, "art");
    string bing_uri = image_file(bing, "daily");
    var result = WallpaperGallery.scan(artist, {ncz, artist, bing},
                                      {bing_uri, base_uri, art_uri, art_uri});
    assert(result.size == 1);
    assert(result[0].uri == art_uri);
    assert(result[0].is_recent);
}

private void test_nested_collection_boundary() {
    string base_uri = image_file(ncz, "base");
    string art_uri = image_file(artist, "art");
    var result = WallpaperGallery.scan(ncz + "/./", {ncz, artist + "/", bing}, {art_uri});
    assert(result.size == 1);
    assert(result[0].uri == base_uri);
    assert(!result[0].is_recent);
}

private void test_provider_subdirectories() {
    string daily = image_file(Path.build_filename(bing, "en-US"), "nested");
    var result = WallpaperGallery.scan(bing, {ncz, artist, bing}, {});
    assert(result.size == 2);
    bool found = false;
    foreach (var candidate in result) if (candidate.uri == daily) found = true;
    assert(found);
}

private void test_missing_collection() {
    string uri = image_file(ncz, "base");
    assert(WallpaperGallery.scan(null, {ncz}, {uri}).size == 0);
    assert(WallpaperGallery.scan(fixture_root + "/missing", {ncz}, {uri}).size == 0);
}

private void test_default_alias_and_directory_loop() {
    try {
        File.new_for_path(ncz + "/default.svg").make_symbolic_link("base.svg");
        File.new_for_path(ncz + "/loop").make_symbolic_link(ncz);
    } catch (Error e) { error("fixture: %s", e.message); }
    string alias = File.new_for_path(ncz + "/default.svg").get_uri();
    var result = WallpaperGallery.scan(ncz, {ncz, artist, bing}, {alias});
    assert(result.size == 1);
    assert(!result[0].is_recent);
}

public int main(string[] args) {
    Test.init(ref args);
    try { fixture_root = DirUtils.make_tmp("wallpaper-gallery-XXXXXX"); }
    catch (Error e) { error("fixture: %s", e.message); }
    ncz = fixture_root + "/ncz";
    artist = ncz + "/artist";
    bing = fixture_root + "/bing";
    image_file(ncz, "base");
    image_file(artist, "art");
    image_file(bing, "daily");
    Test.add_func("/wallpaper-gallery/recent-membership", test_recent_membership);
    Test.add_func("/wallpaper-gallery/nested-boundary", test_nested_collection_boundary);
    Test.add_func("/wallpaper-gallery/provider-subdirectories", test_provider_subdirectories);
    Test.add_func("/wallpaper-gallery/missing-collection", test_missing_collection);
    Test.add_func("/wallpaper-gallery/default-alias-loop", test_default_alias_and_directory_loop);
    return Test.run();
}
