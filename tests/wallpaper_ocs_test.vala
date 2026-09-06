using GLib;
using Singularity;

private const string PROVIDERS = "{\"schema\":1,\"providers\":{\"pling\":{\"base\":\"https://api.pling.com/ocs/v1/\"},\"kde-look\":{\"base\":\"https://api.kde-look.org/ocs/v1/\"}}}";
private const string INDEX = "{\"schema\":1,\"entries\":[{\"ref\":\"pling:300\",\"name\":\"Wallpapers\",\"display_name\":\"Desktop\",\"usable\":true},{\"ref\":\"pling:1\",\"name\":\"Phone\",\"usable\":false},{\"ref\":\"kde-look:2\",\"name\":\"Other\",\"usable\":true},{\"ref\":\"pling:300\",\"name\":\"Duplicate\",\"usable\":true}]}";
private string browse(string items, string provider = "pling", string category = "300") {
    return "{\"schema\":1,\"provider\":\"%s\",\"category\":\"%s\",\"items\":%s}".printf(provider, category, items);
}
private const string ITEM = "{\"provider\":\"pling\",\"id\":\"123\",\"name\":\"Space & <Stars>\",\"author\":null,\"preview\":null}";
private void test_providers() {
    try { var rows = WallpaperOcs.providers(PROVIDERS); assert(rows.size == 2); assert(rows[0].id == "kde-look"); assert(rows[1].id == "pling"); } catch (Error e) { error("%s", e.message); }
}
private void test_categories() {
    try { var rows = WallpaperOcs.categories(INDEX, "pling"); assert(rows.size == 1); assert(rows[0].id == "300"); assert(rows[0].name == "Desktop"); } catch (Error e) { error("%s", e.message); }
}
private void test_items() {
    try { var rows = WallpaperOcs.items(browse("[" + ITEM + "," + ITEM + "]"), "pling", "300"); assert(rows.size == 1); assert(rows[0].key == "pling:123"); assert(rows[0].author == ""); assert(rows[0].license == ""); assert(rows[0].preview == ""); assert(rows[0].name == "Space & <Stars>"); } catch (Error e) { error("%s", e.message); }
}
private void test_empty() {
    try { assert(WallpaperOcs.items(browse("[]"), "pling", "300").size == 0); } catch (Error e) { error("%s", e.message); }
}
private void test_invalid() {
    string[] bad = { "null", "[]", "{}", "not json", "{\"schema\":2,\"providers\":{}}", "{\"schema\":\"1\",\"providers\":{}}", "{\"schema\":1,\"providers\":[]}", "{\"schema\":1,\"providers\":{\"--bad\":{}}}" };
    foreach (string data in bad) { bool rejected = false; try { WallpaperOcs.providers(data); } catch (Error e) { rejected = true; } assert(rejected); }
}
private void test_bad_items() {
    string[] bad = { browse("[]", "kde-look"), browse("[]", "pling", "2"), browse("null"), browse("[null]"), browse("[{\"provider\":\"pling\",\"id\":123,\"name\":\"x\"}]"), browse("[" + ITEM.replace("pling", "kde-look") + "]"), browse("[" + ITEM.replace("null", "42") + "]") };
    foreach (string data in bad) { bool rejected = false; try { WallpaperOcs.items(data, "pling", "300"); } catch (Error e) { rejected = true; } assert(rejected); }
}
private void test_bad_categories() {
    foreach (string data in new string[] { INDEX.replace("true", "\"true\""), INDEX.replace("pling:300", "pling:--bad") }) {
        bool rejected = false; try { WallpaperOcs.categories(data, "pling"); } catch (Error e) { rejected = true; } assert(rejected);
    }
}
private void test_import_retry() {
    var state = new WallpaperOcsImports(); assert(state.begin("pling:123")); assert(state.busy); assert(!state.begin("pling:123")); assert(!state.begin("pling:456")); state.fail("pling:456"); assert(state.busy); state.fail("pling:123"); assert(!state.busy); assert(!state.is_added("pling:123")); assert(state.begin("pling:123"));
}
private void remove_tree(string path) {
    try { var dir = Dir.open(path); string? name; while ((name = dir.read_name()) != null) { string child = Path.build_filename(path, name); if (FileUtils.test(child, FileTest.IS_DIR)) remove_tree(child); else FileUtils.unlink(child); } DirUtils.remove(path); } catch (Error e) { error("cleanup: %s", e.message); }
}
private void test_import_complete() {
    string root = "";
    try {
        root = DirUtils.make_tmp("ocs-test-XXXXXX");
        string pack = Path.build_filename(root, "ocs-pling-123"); DirUtils.create(pack, 0700);
        string collection = Path.build_filename(root, "ocs.collection");
        FileUtils.set_contents(Path.build_filename(pack, "01.jpg"), "fixture");
        FileUtils.set_contents(Path.build_filename(pack, "pack.json"), "{\"origin\":\"ocs\",\"provider\":\"pling\",\"source\":{\"ocs_id\":\"123\"}}");
        FileUtils.set_contents(collection, "[Collection]\nId=ocs-pling-123\nName=Space\nDir=" + pack + "\nOrigin=ocs\n");
        string result = "{\"pack_id\":\"ocs-pling-123\",\"destination\":\"%s\",\"collection\":\"%s\",\"pack_json\":\"%s/pack.json\",\"images\":[{\"file\":\"01.jpg\"}]}".printf(pack, collection, pack);
        var state = new WallpaperOcsImports(); assert(state.begin("pling:123"));
        bool rejected = false; try { state.complete("pling:123", result.replace("01.jpg", "missing.jpg"), {root}); } catch (Error e) { rejected = true; } assert(rejected); assert(!state.is_added("pling:123"));
        state.complete("pling:123", result, {root}); assert(!state.busy); assert(state.is_added("pling:123")); assert(!state.begin("pling:123"));
        var reopened = new WallpaperOcsImports(); reopened.discover(WallpaperCollections.parse({root})); assert(reopened.is_added("pling:123")); assert(!reopened.is_added("kde-look:123"));
        FileUtils.unlink(Path.build_filename(pack, "01.jpg"));
        var missing = new WallpaperOcsImports(); missing.discover(WallpaperCollections.parse({root})); assert(!missing.is_added("pling:123"));
    } catch (Error e) { error("%s", e.message); }
    remove_tree(root);
}
public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/ocs/providers", test_providers); Test.add_func("/ocs/categories", test_categories); Test.add_func("/ocs/items", test_items); Test.add_func("/ocs/empty", test_empty); Test.add_func("/ocs/invalid", test_invalid); Test.add_func("/ocs/bad-items", test_bad_items); Test.add_func("/ocs/bad-categories", test_bad_categories); Test.add_func("/ocs/import-retry", test_import_retry); Test.add_func("/ocs/import-complete", test_import_complete);
    return Test.run();
}
