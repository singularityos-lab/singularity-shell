using Singularity;

private string test_dir;
private string fake_program;
private string hup_log;

private void setup_fake() {
    try {
        test_dir = DirUtils.make_tmp("singularity-xsettings-test-XXXXXX");
    } catch (FileError e) {
        assert_not_reached();
    }
    string bin = Path.build_filename(test_dir, "bin");
    DirUtils.create(bin, 0700);
    fake_program = Path.build_filename(bin, "fake-xsettingsd");
    hup_log = Path.build_filename(test_dir, "hups");
    string? built = Environment.get_variable("FAKE_XSETTINGSD");
    assert(built != null);
    assert(FileUtils.symlink(built, fake_program) == 0);
    Environment.set_variable("FAKE_XSETTINGSD_LOG", hup_log, true);
    Environment.set_variable("PATH", bin + ":" + Environment.get_variable("PATH"), true);
    Environment.set_variable("DISPLAY", ":test-xsettings", true);
}

private void spin(uint ms) {
    var loop = new MainLoop();
    Timeout.add(ms, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
}

private int count_hups(int pid) {
    string contents;
    try {
        if (!FileUtils.get_contents(hup_log, out contents)) return 0;
    } catch (FileError e) {
        return 0;
    }
    int n = 0;
    foreach (string line in contents.split("\n")) {
        if (line.strip() == pid.to_string()) n++;
    }
    return n;
}

private void test_merge() {
    string merged = XSettingsDaemon.merge(
        "Net/IconThemeName \"Old\"\n\nGtk/CursorThemeName \"A\"\n",
        { "Net/IconThemeName" }, { "Net/IconThemeName \"New\"" });
    assert(merged == "Gtk/CursorThemeName \"A\"\nNet/IconThemeName \"New\"\n");
}

private void test_update_starts_once_and_reloads_own_child() {
    string config = Path.build_filename(test_dir, "xsettingsd.conf");
    string state = Path.build_filename(test_dir, "run", "xsettingsd.pid");
    var daemon = new XSettingsDaemon(config, "fake-xsettingsd", state);

    Pid decoy;
    try {
        Process.spawn_async(null, { fake_program, "-c", config }, null,
            SpawnFlags.DO_NOT_REAP_CHILD, null, out decoy);
    } catch (SpawnError e) {
        assert_not_reached();
    }

    try {
        daemon.update({ "Net/IconThemeName" }, { "Net/IconThemeName \"One\"" });
    } catch (Error e) {
        assert_not_reached();
    }
    int first = daemon.pid;
    assert(first > 0);
    assert(first != (int) decoy);
    string recorded;
    try {
        FileUtils.get_contents(state, out recorded);
    } catch (FileError e) {
        assert_not_reached();
    }
    assert(int.parse(recorded.strip()) == first);

    spin(1500);
    try {
        daemon.update({ "Gtk/CursorThemeName" }, { "Gtk/CursorThemeName \"Two\"" });
        daemon.update({ "Gtk/CursorThemeName" }, { "Gtk/CursorThemeName \"Three\"" });
    } catch (Error e) {
        assert_not_reached();
    }
    spin(600);
    assert(daemon.pid == first);
    assert(count_hups(first) == 1);
    assert(count_hups((int) decoy) == 0);
    assert(Posix.kill(decoy, 0) == 0);

    string body;
    try {
        FileUtils.get_contents(config, out body);
    } catch (FileError e) {
        assert_not_reached();
    }
    assert(body == "Net/IconThemeName \"One\"\nGtk/CursorThemeName \"Three\"\n");

    Posix.kill((Posix.pid_t) first, Posix.Signal.KILL);
    spin(1500);
    int second = daemon.pid;
    assert(second > 0 && second != first);
    assert(Posix.kill(decoy, 0) == 0);

    daemon.stop();
    spin(500);
    assert(!daemon.running);
    assert(!FileUtils.test(state, FileTest.EXISTS));

    Posix.kill(decoy, Posix.Signal.TERM);
    int status;
    Posix.waitpid(decoy, out status, 0);
}

private void test_missing_program_degrades() {
    string config = Path.build_filename(test_dir, "missing.conf");
    var daemon = new XSettingsDaemon(config, "no-such-xsettingsd-binary",
        Path.build_filename(test_dir, "missing.pid"));
    try {
        daemon.update({ "Gtk/FontName" }, { "Gtk/FontName \"Sans 10\"" });
    } catch (Error e) {
        assert_not_reached();
    }
    assert(!daemon.running);
    assert(FileUtils.test(config, FileTest.EXISTS));
}

private void test_owns_process_rejects_strangers() {
    assert(!XSettingsDaemon.owns_process(1, "xsettingsd", "/nonexistent", ":0"));
    assert(!XSettingsDaemon.owns_process(Posix.getpid(), "xsettingsd", "/nonexistent", ":0"));

    string config = Path.build_filename(test_dir, "owned.conf");
    Pid other;
    try {
        Process.spawn_async(null, { fake_program, "-c", config }, null,
            SpawnFlags.DO_NOT_REAP_CHILD, null, out other);
    } catch (SpawnError e) {
        assert_not_reached();
    }
    spin(200);
    assert(XSettingsDaemon.owns_process((int) other, fake_program, config, ":test-xsettings"));
    assert(!XSettingsDaemon.owns_process((int) other, fake_program, config, ":1"));
    assert(!XSettingsDaemon.owns_process((int) other, fake_program, config + ".other", ":test-xsettings"));
    Posix.kill(other, Posix.Signal.TERM);
    int status;
    Posix.waitpid(other, out status, 0);
}

private void remove_tree(string path) {
    if (FileUtils.test(path, FileTest.IS_DIR) && !FileUtils.test(path, FileTest.IS_SYMLINK)) {
        try {
            var dir = Dir.open(path);
            string? name;
            while ((name = dir.read_name()) != null) remove_tree(Path.build_filename(path, name));
        } catch (FileError e) {
            return;
        }
        DirUtils.remove(path);
    } else {
        FileUtils.remove(path);
    }
}

int main(string[] args) {
    Test.init(ref args);
    setup_fake();
    Test.add_func("/xsettings/merge", test_merge);
    Test.add_func("/xsettings/own-child", test_update_starts_once_and_reloads_own_child);
    Test.add_func("/xsettings/missing", test_missing_program_degrades);
    Test.add_func("/xsettings/owns-process", test_owns_process_rejects_strangers);
    int result = Test.run();
    remove_tree(test_dir);
    return result;
}
