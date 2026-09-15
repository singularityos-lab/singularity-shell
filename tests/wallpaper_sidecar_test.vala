using GLib;
using Singularity;

private void remove_tree(string path) {
    try {
        var dir = Dir.open(path);
        string? name;
        while ((name = dir.read_name()) != null) {
            string child = Path.build_filename(path, name);
            if (FileUtils.test(child, FileTest.IS_DIR)) remove_tree(child);
            else FileUtils.unlink(child);
        }
        DirUtils.remove(path);
    } catch (Error e) { error("cleanup: %s", e.message); }
}

// OCS sidecar with image.title + top-level artist.name -- the canonical shape
// the helper writes for every imported OCS pack image.
private string make_ocs_sidecar(string image_filename, string title, string artist_name) {
    return "{\"schema\":1,\"origin\":\"ocs\",\"pack_id\":\"imported-ocs\"," +
           "\"image\":{\"file\":\"" + image_filename + "\",\"title\":\"" + title +
           "\"},\"artist\":{\"name\":\"" + artist_name + "\"}," +
           "\"provider\":\"pling\",\"source\":{\"ocs_id\":\"123\"}}";
}

// Bing sidecar as written by ncz-wallpaper-bing.
private string make_bing_sidecar(string image_filename, string caption, string copyright) {
    return "{\"provider\":\"bing\",\"image\":{\"file\":\"" + image_filename + "\"}," +
           "\"caption\":\"" + caption + "\",\"copyright\":\"" + copyright + "\"}";
}

private string fixture_root;
private string img_dir;
private string img_path;

private void setup_fixtures() {
    try {
        fixture_root = DirUtils.make_tmp("wallpaper-sidecar-XXXXXX");
        img_dir = Path.build_filename(fixture_root, "imported-ocs");
        DirUtils.create(img_dir, 0700);
        img_path = Path.build_filename(img_dir, "pling-123-01-foo.jpg");
        FileUtils.set_contents(img_path, "fixture");
    } catch (Error e) { error("fixture: %s", e.message); }
}

private void write_sidecar(string data) {
    string sidecar = Path.build_filename(img_dir, "pling-123-01-foo.json");
    FileUtils.set_contents(sidecar, data);
}

private void test_missing_sidecar_clears_attribution() {
    FileUtils.unlink(Path.build_filename(img_dir, "pling-123-01-foo.json"));
    // No sidecar at all (plain local photo / drag-drop) -- valid=false
    // so the caller MUST clear. This is the common case; failing here
    // would mean every plain local wallpaper shows stale OCS text.
    var attr = WallpaperSidecar.read(img_path);
    assert(!attr.valid);
    assert(attr.title == "");
    assert(attr.author == "");
}

private void test_ocs_sidecar_full_metadata() {
    write_sidecar(make_ocs_sidecar("pling-123-01-foo.jpg",
                                   "Mountain Lake Reflections",
                                   "Jane Photographer"));
    var attr = WallpaperSidecar.read(img_path);
    assert(attr.valid);
    assert(attr.title == "Mountain Lake Reflections");
    assert(attr.author == "Jane Photographer");
}

private void test_ocs_sidecar_partial_title_only() {
    write_sidecar("{\"origin\":\"ocs\",\"image\":{\"file\":\"pling-123-01-foo.jpg\"," +
                  "\"title\":\"Only Title\"}}");
    var attr = WallpaperSidecar.read(img_path);
    assert(attr.valid);
    assert(attr.title == "Only Title");
    assert(attr.author == "");
}

private void test_ocs_sidecar_partial_artist_only() {
    write_sidecar("{\"origin\":\"ocs\",\"image\":{\"file\":\"pling-123-01-foo.jpg\"}," +
                  "\"artist\":{\"name\":\"Lonely Artist\"}}");
    var attr = WallpaperSidecar.read(img_path);
    assert(attr.valid);
    assert(attr.title == "");
    assert(attr.author == "Lonely Artist");
}

private void test_bing_sidecar_copyright_and_caption() {
    write_sidecar(make_bing_sidecar("bing-en-US-20260818.jpg",
                                    "Palmanova",
                                    "Marco Zoccheddu/Getty Images"));
    var attr = WallpaperSidecar.read(img_path);
    assert(attr.valid);
    assert(attr.title == "Palmanova");
    assert(attr.author == "Marco Zoccheddu/Getty Images");
}

private void test_bing_sidecar_partial_metadata() {
    // caption without copyright -- the overlay should still credit the
    // caption and leave the author empty rather than dropping the whole
    // attribution.
    write_sidecar("{\"provider\":\"bing\",\"caption\":\"Cliffside\"}");
    var attr = WallpaperSidecar.read(img_path);
    assert(attr.valid);
    assert(attr.title == "Cliffside");
    assert(attr.author == "");
}

private void test_unrecognised_origin_clears_attribution() {
    // Anything other than "ocs" / "bing" is treated as untrusted --
    // a third-party pack that ships its own sidecar format MUST NOT
    // leak metadata into the desktop overlay.
    write_sidecar("{\"origin\":\"unknown\",\"image\":{\"title\":\"Sneaky\"}}");
    var attr = WallpaperSidecar.read(img_path);
    assert(!attr.valid);
    assert(attr.title == "");
}

private void test_malformed_json_clears_attribution() {
    // Truncated JSON is not an OCS sidecar. The parser must not crash.
    FileUtils.set_contents(Path.build_filename(img_dir,
                          "pling-123-01-foo.json"), "{\"origin\":\"ocs");
    var attr = WallpaperSidecar.read(img_path);
    assert(!attr.valid);
}

private void test_non_object_top_level_clears_attribution() {
    // A sidecar that is a JSON array (the helper never writes this shape
    // but a future archival flow might) is not a valid OCS / Bing payload.
    write_sidecar("[{\"origin\":\"ocs\"}]");
    var attr = WallpaperSidecar.read(img_path);
    assert(!attr.valid);
}

private void test_empty_path_clears_attribution() {
    var attr = WallpaperSidecar.read("");
    assert(!attr.valid);
    assert(attr.title == "");
    assert(attr.author == "");
}

private void test_no_extension_clears_attribution() {
    // A wallpaper file without an extension has no obvious "basename"
    // to derive the sidecar name from -- treat it as no sidecar.
    string weird = Path.build_filename(img_dir, "noextension");
    FileUtils.set_contents(weird, "x");
    var attr = WallpaperSidecar.read(weird);
    assert(!attr.valid);
}

public int main(string[] args) {
    Test.init(ref args);
    setup_fixtures();
    Test.add_func("/wallpaper-sidecar/openverse-chooser", () => {
        write_sidecar("{\"provider\":\"openverse\",\"name\":\"A <Mountain>\",\"attribution\":\"Credit & <literal>\",\"license\":\"by-sa\",\"license_version\":\"2.5\",\"page_url\":\"https://example.org/image\"}");
        var metadata = WallpaperSidecar.read(img_path);
        assert(metadata.valid);
        assert(metadata.author == "Credit & <literal>");
        assert(WallpaperSidecar.display_text(metadata) == "A <Mountain>\nCredit & <literal>\nOpenverse · by-sa 2.5");
        assert(metadata.page_url == "https://example.org/image");
        assert(WallpaperSidecar.display_text(WallpaperSidecar.read("")) == "");
    });
    Test.add_func("/wallpaper-sidecar/unsplash-chooser", () => {
        write_sidecar("{\"provider\":\"unsplash\",\"name\":\"Mountain\",\"author\":\"Ada\",\"attribution\":\"Photo by Ada on Unsplash\",\"license\":\"Unsplash License\",\"page_url\":\"https://unsplash.com/photos/a\",\"license_url\":\"https://unsplash.com/license\"}");
        var metadata = WallpaperSidecar.read(img_path);
        assert(metadata.valid);
        assert(WallpaperSidecar.display_text(metadata) == "Mountain\nPhoto by Ada on Unsplash\nUnsplash · Unsplash License");
    });
    Test.add_func("/wallpaper-sidecar/missing-sidecar", test_missing_sidecar_clears_attribution);
    Test.add_func("/wallpaper-sidecar/ocs-full-metadata", test_ocs_sidecar_full_metadata);
    Test.add_func("/wallpaper-sidecar/ocs-title-only", test_ocs_sidecar_partial_title_only);
    Test.add_func("/wallpaper-sidecar/ocs-artist-only", test_ocs_sidecar_partial_artist_only);
    Test.add_func("/wallpaper-sidecar/bing-copyright-and-caption", test_bing_sidecar_copyright_and_caption);
    Test.add_func("/wallpaper-sidecar/bing-partial-metadata", test_bing_sidecar_partial_metadata);
    Test.add_func("/wallpaper-sidecar/unrecognised-origin", test_unrecognised_origin_clears_attribution);
    Test.add_func("/wallpaper-sidecar/malformed-json", test_malformed_json_clears_attribution);
    Test.add_func("/wallpaper-sidecar/non-object-top-level", test_non_object_top_level_clears_attribution);
    Test.add_func("/wallpaper-sidecar/empty-path", test_empty_path_clears_attribution);
    Test.add_func("/wallpaper-sidecar/no-extension", test_no_extension_clears_attribution);
    Test.add_func("/wallpaper/html-attribution", () => {
        assert(WallpaperSidecar.plain_text("<a href=\"https://example.org\">© A &amp; B</a>") == "© A & B");
        assert(WallpaperSidecar.plain_text("Space &lt;Stars&gt;") == "Space <Stars>");
        assert(WallpaperSidecar.plain_text("Plain © credit") == "Plain © credit");
    });
    int ret = Test.run();
    remove_tree(fixture_root);
    return ret;
}
