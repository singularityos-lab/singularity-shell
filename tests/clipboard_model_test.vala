using GLib;
using Singularity;

private Bytes b(string s) {
    return new Bytes(s.data);
}

private void test_add_and_dedupe() {
    var m = new ClipboardModel();
    m.add("text/plain;charset=utf-8", b("alpha"), 1);
    m.add("UTF8_STRING", b("beta"), 2);
    m.add("text/plain", b("alpha"), 3);
    assert(m.entries.size == 2);
    assert(m.entries[0].text == "alpha" && m.entries[0].timestamp == 3);
    assert(m.add("text/plain", b("   \n"), 4) == null);
    assert(m.add("application/octet-stream", b("x"), 5) == null);
    assert(m.entries.size == 2);
}

private void test_limit_keeps_pinned() {
    var m = new ClipboardModel();
    m.limit = 2;
    var first = m.add("text/plain", b("one"), 1);
    m.set_pinned(first.id, true);
    m.add("text/plain", b("two"), 2);
    m.add("text/plain", b("three"), 3);
    m.add("text/plain", b("four"), 4);
    assert(m.entries.size == 3);
    assert(m.find(first.id) != null);
    var ordered = m.ordered("");
    assert(ordered[0].text == "one" && ordered[1].text == "four" && ordered[2].text == "three");
}

private void test_search_remove_clear() {
    var m = new ClipboardModel();
    var a = m.add("text/plain", b("Hello World"), 1);
    m.add("text/plain", b("goodbye"), 2);
    m.add("image/png", b("\x89PNGfake"), 3);
    assert(m.ordered("world").size == 1);
    assert(m.ordered("image").size == 1);
    m.set_pinned(a.id, true);
    m.clear();
    assert(m.entries.size == 1 && m.entries[0].pinned);
    m.remove(a.id);
    assert(m.entries.size == 0);
}

private void test_preview() {
    var m = new ClipboardModel();
    var e = m.add("text/plain", b("  first line\n\n second\tline \nthird\nfourth"), 1);
    assert(e.preview(100) == "first line second line third");
    assert(e.preview(5) == "first…");
}

private void test_pinned_roundtrip() {
    string dir = "";
    try {
        dir = DirUtils.make_tmp("clip-XXXXXX");
    } catch (FileError err) {
        error("setup: %s", err.message);
    }
    var m = new ClipboardModel();
    var t = m.add("text/plain", b("keep me"), 5);
    var i = m.add("image/png", b("\x89PNGdata"), 6);
    m.add("text/plain", b("forget me"), 7);
    m.set_pinned(t.id, true);
    m.set_pinned(i.id, true);
    string json = m.pinned_to_json(dir);
    var back = new ClipboardModel();
    back.load_pinned(json, dir);
    assert(back.entries.size == 2);
    int images = 0;
    foreach (var e in back.entries) {
        assert(e.pinned);
        if (e.is_image) images++;
        else assert(e.text == "keep me");
    }
    assert(images == 1);
}

public static int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/clipboard/add-dedupe", test_add_and_dedupe);
    Test.add_func("/clipboard/limit-pinned", test_limit_keeps_pinned);
    Test.add_func("/clipboard/search-remove-clear", test_search_remove_clear);
    Test.add_func("/clipboard/preview", test_preview);
    Test.add_func("/clipboard/pinned-roundtrip", test_pinned_roundtrip);
    return Test.run();
}
