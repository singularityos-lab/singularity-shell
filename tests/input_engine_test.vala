using GLib;
using Singularity.InputMethods;

private Variant ibus_text(string text) {
    return Serial.ibus_text_variant(text);
}

private Variant lookup_table(string[] items, uint page_size, uint cursor, bool visible, int orientation) {
    var candidates = new VariantBuilder(new VariantType("av"));
    foreach (string item in items) candidates.add("v", ibus_text(item).get_variant());
    var labels = new VariantBuilder(new VariantType("av"));
    return new Variant.variant(new Variant("(sa{sv}uubbiavav)", "IBusLookupTable",
        new VariantBuilder(new VariantType("a{sv}")), page_size, cursor, visible, true, orientation,
        candidates, labels));
}

private void test_ibus_text() {
    assert(Serial.ibus_text(ibus_text("한")) == "한");
    assert(Serial.ibus_text(new Variant.string("plain")) == "plain");
    assert(Serial.ibus_text(new Variant("(sa{sv}sv)", "Other", new VariantBuilder(new VariantType("a{sv}")), "x", new Variant.string(""))) == "");
}

private void test_ibus_table_single_page() {
    var table = Serial.ibus_table(lookup_table({ "你", "尼", "泥" }, 5, 1, true, 0));
    assert(table != null);
    assert(table.items.length == 3);
    assert(table.items[1] == "尼");
    assert(table.labels[0] == "1" && table.labels[2] == "3");
    assert(table.selected == 1);
    assert(!table.has_previous && !table.has_next);
    assert(!table.vertical);
}

private void test_ibus_table_paging() {
    string[] all = {};
    for (int i = 0; i < 12; i++) all += "c%d".printf(i);
    var table = Serial.ibus_table(lookup_table(all, 5, 7, true, 1));
    assert(table.items.length == 5);
    assert(table.items[0] == "c5");
    assert(table.selected == 2);
    assert(table.has_previous && table.has_next);
    assert(table.vertical);
    var hidden = Serial.ibus_table(lookup_table(all, 5, 11, false, 0));
    assert(hidden.items[0] == "c10" && hidden.items.length == 2);
    assert(hidden.selected == -1);
    assert(!hidden.has_next);
}

private void test_fcitx() {
    var formatted = new VariantBuilder(new VariantType("a(si)"));
    formatted.add("(si)", "ni", 0);
    formatted.add("(si)", "hao", 8);
    assert(Serial.fcitx_formatted(formatted.end()) == "nihao");
    var list = new VariantBuilder(new VariantType("a(ss)"));
    list.add("(ss)", "1.", "你好");
    list.add("(ss)", "2. ", "拟好");
    var c = Serial.fcitx_candidates(list.end(), 0, false, true, 0, "ni'hao");
    assert(c.items.length == 2);
    assert(c.labels[0] == "1" && c.labels[1] == "2");
    assert(c.items[0] == "你好");
    assert(c.selected == 0 && c.has_next && !c.has_previous);
    assert(c.auxiliary == "ni'hao");
}

private void test_ibus_component() {
    string xml = """<?xml version="1.0"?>
<component><name>org.freedesktop.IBus.Hangul</name>
<engines>
  <engine><name>hangul</name><language>ko</language><longname>Korean</longname><symbol>&#xD55C;</symbol></engine>
  <engine><name>xkb:us::eng</name><language>en</language><longname>English (US)</longname></engine>
  <engine><name>pinyin</name><language>zh_CN</language><longname>Intelligent Pinyin &amp; more</longname></engine>
</engines></component>""";
    var engines = Serial.parse_ibus_component(xml);
    assert(engines.length == 2);
    assert(engines[0].id == "ibus:hangul");
    assert(engines[0].language == "ko");
    assert(engines[1].label == "Intelligent Pinyin & more");
    assert(engines[1].short_label() == "ZH");
}

private void test_fcitx_conf() {
    var info = Serial.parse_fcitx_conf("pinyin", "[InputMethod]\nName=Pinyin\nIcon=fcitx-pinyin\nLabel=拼\nLangCode=zh_CN\nAddon=pinyin\n");
    assert(info != null);
    assert(info.id == "fcitx5:pinyin");
    assert(info.label == "Pinyin");
    assert(info.short_label() == "拼");
    assert(info.language == "zh_CN");
    assert(Serial.parse_fcitx_conf("x", "[Addon]\nName=x\n") == null);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/input/ibus/text", test_ibus_text);
    Test.add_func("/input/ibus/table", test_ibus_table_single_page);
    Test.add_func("/input/ibus/paging", test_ibus_table_paging);
    Test.add_func("/input/fcitx/serial", test_fcitx);
    Test.add_func("/input/ibus/component", test_ibus_component);
    Test.add_func("/input/fcitx/conf", test_fcitx_conf);
    return Test.run();
}
