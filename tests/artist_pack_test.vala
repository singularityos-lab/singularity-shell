using GLib;

private string root;

private void put(string path, string contents) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_contents(path, contents);
    } catch (FileError e) {
        error("fixture: %s", e.message);
    }
}

[DBus (name = "org.freedesktop.PackageKit")]
public class MockPackageKit : Object {
    [DBus (visible = false)]
    public DBusConnection conn;
    [DBus (visible = false)]
    public string offered_version = "2.0";
    [DBus (visible = false)]
    public GenericArray<string> installed_ids = new GenericArray<string>();
    [DBus (visible = false)]
    public bool refuse = false;
    private int count = 0;

    public ObjectPath create_transaction() throws Error {
        count++;
        string path = "/tx/%d".printf(count);
        conn.register_object(path, new MockTransaction(this));
        return new ObjectPath(path);
    }
}

[DBus (name = "org.freedesktop.PackageKit.Transaction")]
public class MockTransaction : Object {
    private MockPackageKit owner;

    public signal void package(uint info, string id, string summary);
    public signal void error_code(uint code, string details);
    public signal void finished(uint exit, uint runtime);

    public MockTransaction(MockPackageKit owner) {
        this.owner = owner;
    }

    public void resolve(uint64 filter, string[] names) throws Error {
        foreach (string name in names) package(2, "%s;%s;all;packs".printf(name, owner.offered_version), "");
        finished(1, 0);
    }

    public void install_packages(uint64 flags, string[] ids) throws Error {
        if (owner.refuse) {
            error_code(4, "not authorized");
            finished(2, 0);
            return;
        }
        foreach (string id in ids) owner.installed_ids.add(id);
        finished(1, 0);
    }
}

private const string SOURCE = "https://packs.example.org/debian";
private const string ODD_SOURCE = "http://me:secret@odd_host.example/repo";

private Singularity.ArtistPackManager fixture() {
    string lists = Path.build_filename(root, "lists");
    put(Path.build_filename(lists, "packs.example.org_debian_dists_stable_main_binary-amd64_Packages"),
        "Package: aurora-pack\nVersion: 2.0\nDescription: Northern light wallpapers\n long text\n\n" +
        "Package: dune-pack\nVersion: 1.1\nDescription-en: Sand\n");
    put(Path.build_filename(lists, "packs.example.org_debian_dists_stable_main_binary-amd64_Packages.diff_Index"), "");
    put(Path.build_filename(lists, "odd%5fhost.example_repo_dists_noble_main_binary-arm64_Packages"),
        "Package: odd-pack\nVersion: 3\n\n");
    put(Path.build_filename(lists, "other.example.org_debian_dists_stable_main_binary-amd64_Packages"),
        "Package: stray-pack\nVersion: 1\n\n");
    string status = Path.build_filename(root, "status");
    put(status, "Package: dune-pack\nStatus: install ok installed\n\nPackage: aurora-pack\nStatus: deinstall ok config-files\n\n");
    return new Singularity.ArtistPackManager(lists, status, {
        "deb " + SOURCE + " stable main",
        "deb [arch=arm64 signed-by=/k.gpg] " + ODD_SOURCE + " noble main",
        "# deb https://other.example.org/debian stable main",
    });
}

private void test_prefix() {
    assert(Singularity.ArtistPackManager.list_prefix("https://a.example/b/dists/x/") == "a.example_b_dists_x_");
    assert(Singularity.ArtistPackManager.list_prefix("http://u:p@a_b.example/~c/") == "a%5fb.example_%7ec_");
}

private void test_inventory() {
    var manager = fixture();
    var packs = manager.read_inventory();
    assert(packs.size == 3);
    assert(packs[0].package == "aurora-pack");
    assert(packs[0].version == "2.0");
    assert(packs[0].summary == "Northern light wallpapers");
    assert(packs[0].source == SOURCE);
    assert(!packs[0].installed);
    assert(packs[1].package == "dune-pack");
    assert(packs[1].summary == "Sand");
    assert(packs[1].installed);
    assert(packs[2].package == "odd-pack");
    assert(packs[2].source == ODD_SOURCE);
}

private Error? install(Singularity.ArtistPackManager manager, string package, string source) {
    var loop = new MainLoop();
    Error? failure = null;
    manager.install_async.begin(package, source, null, (obj, res) => {
        try {
            manager.install_async.end(res);
        } catch (Error e) {
            failure = e;
        }
        loop.quit();
    });
    loop.run();
    return failure;
}

private void test_install() {
    var bus = new TestDBus(TestDBusFlags.NONE);
    bus.up();
    Environment.set_variable("DBUS_SYSTEM_BUS_ADDRESS", bus.get_bus_address(), true);
    var mock = new MockPackageKit();
    try {
        mock.conn = Bus.get_sync(BusType.SYSTEM);
        mock.conn.register_object("/org/freedesktop/PackageKit", mock);
        mock.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant("(su)", "org.freedesktop.PackageKit", 0), null, DBusCallFlags.NONE, -1);
    } catch (Error e) {
        error("mock: %s", e.message);
    }
    var manager = fixture();

    assert(install(manager, "aurora-pack", SOURCE) == null);
    assert(mock.installed_ids.length == 1);
    assert(mock.installed_ids[0] == "aurora-pack;2.0;all;packs");

    assert(install(manager, "stray-pack", SOURCE) is Singularity.ArtistPackError.INVALID_RESPONSE);
    assert(install(manager, "aurora-pack", ODD_SOURCE) is Singularity.ArtistPackError.INVALID_RESPONSE);
    assert(install(manager, "../x", SOURCE) is Singularity.ArtistPackError.INVALID_RESPONSE);

    mock.offered_version = "9.9";
    assert(install(manager, "aurora-pack", SOURCE) is Singularity.ArtistPackError.BACKEND_FAILED);
    assert(mock.installed_ids.length == 1);

    mock.offered_version = "2.0";
    mock.refuse = true;
    var refused = install(manager, "aurora-pack", SOURCE);
    assert(refused is Singularity.ArtistPackError.BACKEND_FAILED);
    assert(refused.message == "not authorized");
    assert(mock.installed_ids.length == 1);
    bus.down();
}

public static int main(string[] args) {
    Test.init(ref args);
    try {
        root = DirUtils.make_tmp("artist-pack-XXXXXX");
    } catch (FileError e) {
        error("tmp: %s", e.message);
    }
    Test.add_func("/artist-pack/prefix", test_prefix);
    Test.add_func("/artist-pack/inventory", test_inventory);
    Test.add_func("/artist-pack/install", test_install);
    return Test.run();
}
