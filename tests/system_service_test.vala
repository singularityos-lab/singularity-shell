using GLib;

[DBus (name = "dev.sinty.LoginScreen1")]
public class MockLoginScreen : Object {
    [DBus (visible = false)]
    public string applied = "";
    [DBus (visible = false)]
    public string color = "";
    [DBus (visible = false)]
    public int image_size = -1;

    public void apply(string payload) throws Error {
        applied = payload;
    }

    public void reset() throws Error {
        throw new DBusError.ACCESS_DENIED("no");
    }

    public void set_background_image(uint8[] data) throws Error {
        image_size = data.length;
    }

    public void set_background_color(string value) throws Error {
        if (value == "bad") throw new IOError.INVALID_ARGUMENT("invalid color");
        color = value;
    }

    public void reset_background() throws Error {
    }
}

[DBus (name = "dev.sinty.FingerprintDriver1")]
public class MockFingerprint : Object {
    [DBus (visible = false)]
    public string last = "";

    public HashTable<string, string> info(string id) throws Error {
        if (id != "10a5:9800") throw new IOError.NOT_FOUND("no driver is known for %s", id);
        var table = new HashTable<string, string>(str_hash, str_equal);
        table["id"] = id;
        table["name"] = "FPC";
        table["url"] = "https://example.org/fpc.deb";
        table["size"] = "1050274";
        table["installed"] = "false";
        return table;
    }

    public void install(string id) throws Error {
        last = "install " + id;
    }

    public void uninstall(string id) throws Error {
        throw new DBusError.ACCESS_DENIED("no");
    }
}

private string services;

private void advertise(string name) {
    try {
        FileUtils.set_contents(Path.build_filename(services, name + ".service"), "[D-BUS Service]\nName=%s\n".printf(name));
    } catch (FileError e) {
        error("fixture: %s", e.message);
    }
}

private delegate void Starter(AsyncReadyCallback done);
private delegate void Finisher(AsyncResult res) throws Error;

private Error? run(Starter start, Finisher finish) {
    var loop = new MainLoop();
    Error? failure = null;
    start((obj, res) => {
        try {
            finish(res);
        } catch (Error e) {
            failure = e;
        }
        loop.quit();
    });
    loop.run();
    return failure;
}

private void own(string name, string path, Object mock) {
    try {
        var conn = Bus.get_sync(BusType.SYSTEM);
        if (mock is MockLoginScreen) conn.register_object(path, (MockLoginScreen) mock);
        else conn.register_object(path, (MockFingerprint) mock);
        conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant("(su)", name, 0), null, DBusCallFlags.NONE, -1);
    } catch (Error e) {
        error("mock: %s", e.message);
    }
}

private void test_login_screen() {
    var sync = new Singularity.LoginScreenSync();
    assert(!Singularity.LoginScreenSync.available());
    assert(run((cb) => sync.reset.begin(cb), (r) => sync.reset.end(r)) is IOError.NOT_FOUND);

    advertise(Singularity.LoginScreenSync.SERVICE);
    assert(Singularity.LoginScreenSync.available());
    var mock = new MockLoginScreen();
    own(Singularity.LoginScreenSync.SERVICE, "/dev/sinty/LoginScreen1", mock);

    assert(run((cb) => sync.apply.begin(cb), (r) => sync.apply.end(r)) == null);
    assert(mock.applied == sync.build_payload());
    assert(run((cb) => sync.set_background_color.begin("#102030", cb), (r) => sync.set_background_color.end(r)) == null);
    assert(mock.color == "#102030");
    var bad = run((cb) => sync.set_background_color.begin("bad", cb), (r) => sync.set_background_color.end(r));
    assert(bad is IOError.FAILED);
    assert(bad.message == "invalid color");
    assert(run((cb) => sync.reset.begin(cb), (r) => sync.reset.end(r)) is IOError.PERMISSION_DENIED);

    string image = Path.build_filename(services, "bg.png");
    try {
        FileUtils.set_contents(image, "\x89PNG-fixture-bytes");
    } catch (FileError e) {
        error("fixture: %s", e.message);
    }
    var file = File.new_for_path(image);
    assert(run((cb) => sync.set_background_image.begin(file, cb), (r) => sync.set_background_image.end(r)) == null);
    assert(mock.image_size == 18);
}

private void test_fingerprint() {
    var loop = new MainLoop();
    Singularity.FingerprintDriver? found = null;
    Singularity.FingerprintDriver.find.begin("10a5:9800", (obj, res) => {
        found = Singularity.FingerprintDriver.find.end(res);
        loop.quit();
    });
    loop.run();
    assert(found == null);

    advertise(Singularity.FingerprintDriver.SERVICE);
    var mock = new MockFingerprint();
    own(Singularity.FingerprintDriver.SERVICE, "/dev/sinty/FingerprintDriver1", mock);
    Singularity.FingerprintDriver.find.begin("10a5:9800", (obj, res) => {
        found = Singularity.FingerprintDriver.find.end(res);
        loop.quit();
    });
    loop.run();
    assert(found != null);
    assert(found.name == "FPC");
    assert(found.size == 1050274);
    assert(found.host == "example.org");
    assert(!found.installed);

    var driver = found;
    assert(run((cb) => driver.install.begin(cb), (r) => driver.install.end(r)) == null);
    assert(mock.last == "install 10a5:9800");
    assert(driver.installed);
    assert(run((cb) => driver.uninstall.begin(cb), (r) => driver.uninstall.end(r)) is IOError.CANCELLED);
    assert(driver.installed);

    Singularity.FingerprintDriver.find.begin("ffff:0000", (obj, res) => {
        found = Singularity.FingerprintDriver.find.end(res);
        loop.quit();
    });
    loop.run();
    assert(found == null);
}

public static int main(string[] args) {
    Test.init(ref args);
    try {
        services = DirUtils.make_tmp("services-XXXXXX");
    } catch (FileError e) {
        error("tmp: %s", e.message);
    }
    Singularity.SystemService.service_dirs = { services };
    var bus = new TestDBus(TestDBusFlags.NONE);
    bus.up();
    Environment.set_variable("DBUS_SYSTEM_BUS_ADDRESS", bus.get_bus_address(), true);
    Test.add_func("/system-service/login-screen", test_login_screen);
    Test.add_func("/system-service/fingerprint", test_fingerprint);
    int result = Test.run();
    bus.down();
    return result;
}
