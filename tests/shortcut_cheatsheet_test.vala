using Singularity;

static string keys_of(CheatsheetEntry e) {
    return string.joinv("+", e.keys);
}

static void test_keys() {
    var keys = CheatsheetModel.keys_for_accel("<Super><Shift>p");
    assert(keys != null);
    assert(string.joinv("+", keys) == "Super+Shift+P");
    assert(string.joinv("+", CheatsheetModel.keys_for_accel("<Control><Alt>Left")) == "Ctrl+Alt+Left");
    assert(string.joinv("+", CheatsheetModel.keys_for_accel("<Super>Return")) == "Super+Enter");
    assert(string.joinv("+", CheatsheetModel.keys_for_accel("<Super>period")) == "Super+.");
    assert(CheatsheetModel.keys_for_accel("") == null);
    assert(CheatsheetModel.keys_for_accel("XF86AudioMute") == null);
    assert(CheatsheetModel.keys_for_accel("not a key") == null);
}

static void test_groups() {
    assert(CheatsheetModel.desktop_group("snap_left") == "Windows");
    assert(CheatsheetModel.desktop_group("toggle_workspace_overview") == "Workspaces");
    assert(CheatsheetModel.desktop_group("screenshot_region") == "Screenshots");
    assert(CheatsheetModel.desktop_group("zoom_in") == "Accessibility");
    assert(CheatsheetModel.desktop_group("lock_screen") == "System");
    assert(CheatsheetModel.desktop_group("custom:abc") == "Custom");
    assert(CheatsheetModel.desktop_group("toggle_launcher") == "Launch and Find");
}

static void test_desktop_and_dedupe() {
    var m = new CheatsheetModel();
    assert(m.add(CheatsheetModel.desktop_group("snap_left"), "Snap left", "<Super>Left"));
    assert(!m.add(CheatsheetModel.desktop_group("snap_left"), "Snap left", "<Super>Left"));
    assert(!m.add(CheatsheetModel.desktop_group("volume_up"), "Volume up", ""));
    m.add_desktop("lock_screen", "Lock the screen", "<Super>l");
    m.add_desktop("toggle_launcher", "Open launcher", "<Super>space");
    m.order_sections();
    assert(m.sections.length == 3);
    assert(m.sections[0].title == "Launch and Find");
    assert(m.sections[1].title == "Windows");
    assert(m.sections[2].title == "System");
    assert(m.total == 3);
}

static GLib.Menu make_menu() {
    var root = new GLib.Menu();
    var file = new GLib.Menu();
    var item = new GLib.MenuItem("_Open…", "app.open");
    item.set_attribute_value("accel", new Variant.string("<Control>o"));
    file.append_item(item);
    var sec = new GLib.Menu();
    var save = new GLib.MenuItem("Save", "app.save");
    save.set_attribute_value("accel", new Variant.string("<Control>s"));
    sec.append_item(save);
    sec.append("No Accel", "app.none");
    file.append_section(null, sec);
    root.append_submenu("_File", file);
    var edit = new GLib.Menu();
    var copy = new GLib.MenuItem("Copy", "app.copy");
    copy.set_attribute_value("accel", new Variant.string("<Control>c"));
    edit.append_item(copy);
    root.append_submenu("Edit", edit);
    return root;
}

static void test_menu() {
    var m = new CheatsheetModel();
    m.add_desktop("lock_screen", "Lock the screen", "<Super>l");
    int added = m.add_menu("Files", make_menu());
    assert(added == 3);
    assert(m.sections[0].is_app);
    assert(m.sections[0].title == "File");
    assert(m.sections[0].app_name == "Files");
    assert(m.sections[0].entries.length == 2);
    assert(m.sections[0].entries[0].label == "Open");
    assert(keys_of(m.sections[0].entries[0]) == "Ctrl+O");
    assert(m.sections[1].title == "Edit");
    assert(!m.sections[2].is_app);
}

static void test_filter() {
    var m = new CheatsheetModel();
    m.add_menu("Files", make_menu());
    m.add_desktop("lock_screen", "Lock the screen", "<Super>l");
    m.add_desktop("snap_left", "Snap the window left", "<Super>Left");
    var r = m.filter("");
    assert(r.length == m.sections.length);
    r = m.filter("  SAVE ");
    assert(r.length == 1 && r[0].entries.length == 1 && r[0].entries[0].label == "Save");
    r = m.filter("super");
    uint n = 0;
    for (uint i = 0; i < r.length; i++) n += r[i].entries.length;
    assert(n == 2);
    r = m.filter("ctrl c");
    assert(r.length == 1 && r[0].entries[0].label == "Copy");
    r = m.filter("windows");
    assert(r.length == 1 && r[0].title == "Windows");
    r = m.filter("files edit");
    assert(r.length == 1 && r[0].entries.length == 1);
    assert(m.filter("nothing-here").length == 0);
    assert(m.sections.length == 4);
}

static Variant accel_entry(string action, string[] accels, string label, string group) {
    var d = new VariantDict();
    d.insert_value("action", new Variant.string(action));
    d.insert_value("accels", new Variant.strv(accels));
    d.insert_value("label", new Variant.string(label));
    d.insert_value("group", new Variant.string(group));
    return d.end();
}

static void test_exported_accels() {
    Variant[] items = {
        accel_entry("win.zoom-in", { "<Control>plus", "<Control>equal" }, "", "View"),
        accel_entry("app.new-note", { "<Control>n" }, "New Note", ""),
        accel_entry("win.hidden-thing", { "<Control>h" }, "Hidden", ""),
        accel_entry("app.quit", { "<Control>q" }, "Quit", ""),
        accel_entry("win.open-recent::1", { "<Control>1" }, "", ""),
        accel_entry("app.no-keys", {}, "Nothing", "")
    };
    var list = new Variant.array(VariantType.VARDICT, items);
    var enabled = new HashTable<string, bool>(str_hash, str_equal);
    enabled.insert("win.zoom-in", true);
    enabled.insert("app.new-note", true);
    enabled.insert("app.quit", true);
    enabled.insert("win.open-recent", true);
    var parsed = AppAccelsReader.parse(list, enabled, true, true);
    assert(parsed.length == 4);
    assert(parsed[0].display_label() == "Zoom in");
    assert(parsed[3].action_name() == "open-recent");
    assert(parsed[3].display_label() == "Open recent");
    assert(AppAccelsReader.parse(list, enabled, true, false).length == 5);
    assert(AppAccelsReader.parse(list, null, false, false).length == 5);
    assert(AppAccelsReader.object_path_for("dev.sinty.My-App") == "/dev/sinty/My_App");

    var m = new CheatsheetModel();
    var menu = new Menu();
    var file = new Menu();
    var item = new MenuItem("_Quit", "app.quit");
    item.set_attribute_value("accel", new Variant.string("<Control>q"));
    file.append_item(item);
    menu.append_submenu("File", file);
    m.add_menu("Notes", menu);
    int added = m.add_accels("Notes", parsed);
    assert(added == 3);
    assert(m.total == 4);
    bool view = false;
    bool top = false;
    for (uint i = 0; i < m.sections.length; i++) {
        var sec = m.sections[i];
        assert(sec.is_app);
        if (sec.title == "View") {
            view = true;
            assert(keys_of(sec.entries[0]) == "Ctrl++");
        }
        if (sec.title == "Notes") top = true;
    }
    assert(view && top);
    assert(AppAccelsReader.signature(parsed) != AppAccelsReader.signature(null));
}

public static int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "C");
    Test.init(ref args);
    Test.add_func("/cheatsheet/keys", test_keys);
    Test.add_func("/cheatsheet/groups", test_groups);
    Test.add_func("/cheatsheet/desktop", test_desktop_and_dedupe);
    Test.add_func("/cheatsheet/menu", test_menu);
    Test.add_func("/cheatsheet/filter", test_filter);
    Test.add_func("/cheatsheet/exported-accels", test_exported_accels);
    return Test.run();
}
