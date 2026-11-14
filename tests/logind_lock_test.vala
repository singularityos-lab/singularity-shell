
[DBus (name = "org.freedesktop.login1.Manager")]
public class FakeManager : Object {
    public uint inhibit_calls = 0;
    public string by_pid_path = "/org/freedesktop/login1/session/c7";
    public bool by_pid_fails = false;
    private int write_end = -1;

    [DBus (name = "PrepareForSleep")]
    public signal void prepare_for_sleep(bool start);

    [DBus (name = "GetSession")]
    public ObjectPath get_session(string id) throws DBusError {
        if (id != "c7" && id != "c8") throw new DBusError.FAILED("No session '%s' known".printf(id));
        return new ObjectPath("/org/freedesktop/login1/session/" + id);
    }

    [DBus (name = "GetSessionByPID")]
    public ObjectPath get_session_by_pid(uint32 pid) throws DBusError {
        if (by_pid_fails) throw new DBusError.FAILED("PID %u does not belong to any known session".printf(pid));
        return new ObjectPath(by_pid_path);
    }

    [DBus (name = "Inhibit")]
    public UnixInputStream inhibit(string what, string who, string why, string mode) throws DBusError {
        assert(what == "sleep");
        assert(mode == "delay");
        inhibit_calls++;
        int fds[2];
        if (Posix.pipe(fds) != 0) throw new DBusError.FAILED("pipe");
        if (write_end >= 0) Posix.close(write_end);
        write_end = fds[1];
        return new UnixInputStream(fds[0], true);
    }

    [DBus (visible = false)]
    public bool inhibitor_open() {
        if (write_end < 0) return false;
        var pfd = Posix.pollfd() { fd = write_end, events = Posix.POLLOUT };
        Posix.pollfd[] set = { pfd };
        Posix.poll(set, 0);
        return (set[0].revents & (Posix.POLLERR | Posix.POLLHUP)) == 0;
    }
}

[DBus (name = "org.freedesktop.login1.Session")]
public class FakeSession : Object {
    [DBus (name = "Lock")]
    public signal void lock_requested();
    [DBus (name = "Unlock")]
    public signal void unlock_requested();
}

[DBus (name = "org.freedesktop.login1.Session")]
public class ImpostorSession : Object {
    [DBus (name = "Lock")]
    public signal void lock_requested();
}

public class FakeLocker : Object, Singularity.SessionLocker {
    public uint calls = 0;
    public bool locked = false;
    public uint lock_after_ms = 0;

    public void lock_session() {
        calls++;
        if (lock_after_ms > 0) {
            Timeout.add(lock_after_ms, () => {
                locked = true;
                return Source.REMOVE;
            });
        }
    }

    public bool is_locked() {
        return locked;
    }
}

delegate bool Cond();

static bool wait_for(Cond cond, uint timeout_ms) {
    int64 end = get_monotonic_time() + (int64) timeout_ms * 1000;
    var ctx = MainContext.default();
    while (!cond()) {
        if (get_monotonic_time() > end) return false;
        ctx.iteration(false);
        Thread.usleep(2000);
    }
    return true;
}

static void spin(uint ms) {
    wait_for(() => false, ms);
}

static int failures = 0;
static int passes = 0;

static void check(bool ok, string what) {
    if (ok) {
        passes++;
        print("  PASS: %s\n", what);
    } else {
        failures++;
        print("  FAIL: %s\n", what);
    }
}

static DBusConnection bus_connect(string address) throws Error {
    return new DBusConnection.for_address_sync(address,
        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION, null, null);
}

static bool own_name(DBusConnection conn, string name) throws Error {
    var reply = conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "RequestName", new Variant("(su)", name, 4u), new VariantType("(u)"), DBusCallFlags.NONE, 5000, null);
    uint32 r;
    reply.get("(u)", out r);
    return r == 1;
}

static Singularity.LogindLockListener make_listener(DBusConnection conn, FakeLocker locker, bool* lock_on_suspend) {
    var l = new Singularity.LogindLockListener(conn, locker, () => *lock_on_suspend);
    l.repeat_guard_us = 0;
    l.poll_ms = 20;
    l.settle_ms = 200;
    l.sleep_wait_max_ms = 800;
    return l;
}

int main(string[] args) {
    var test_bus = new TestDBus(TestDBusFlags.NONE);
    test_bus.up();
    string address = test_bus.get_bus_address();
    try {
        var server = bus_connect(address);
        var manager = new FakeManager();
        var session = new FakeSession();
        var other = new FakeSession();
        server.register_object("/org/freedesktop/login1", manager);
        server.register_object("/org/freedesktop/login1/session/c7", session);
        server.register_object("/org/freedesktop/login1/session/c8", other);
        assert(own_name(server, "org.freedesktop.login1"));

        var client = bus_connect(address);
        var locker = new FakeLocker();
        bool los = true;

        print("== case 1: start follows the XDG_SESSION_ID session and takes a delay inhibitor ==\n");
        Environment.set_variable("XDG_SESSION_ID", "c7", true);
        var l = make_listener(client, locker, &los);
        bool started = false, done = false;
        l.start.begin((o, r) => { started = l.start.end(r); done = true; });
        wait_for(() => done, 3000);
        check(started, "start() resolved a session");
        check(l.session_path == "/org/freedesktop/login1/session/c7", "session path is c7");
        check(l.inhibitor_held && manager.inhibit_calls == 1 && manager.inhibitor_open(), "sleep delay inhibitor held");

        print("== case 2: Session.Lock locks through the shell lock path ==\n");
        session.lock_requested();
        check(wait_for(() => locker.calls == 1, 2000), "lock_session called once");
        locker.locked = true;

        print("== case 3: Lock while locked does nothing ==\n");
        session.lock_requested();
        spin(300);
        check(locker.calls == 1, "no second lock while the lock screen is up");
        check(l.locks_skipped == 1, "skip counted");

        print("== case 4: Unlock is ignored (the user must authenticate) ==\n");
        session.unlock_requested();
        spin(200);
        check(locker.locked && locker.calls == 1, "still locked, no lock call");
        locker.locked = false;

        print("== case 5: Lock for another session is ignored ==\n");
        other.lock_requested();
        spin(300);
        check(locker.calls == 1, "c8 Lock did not lock c7");

        print("== case 6: Lock from a sender that is not logind is ignored ==\n");
        var impostor_conn = bus_connect(address);
        var impostor = new ImpostorSession();
        impostor_conn.register_object("/org/freedesktop/login1/session/c7", impostor);
        impostor.lock_requested();
        spin(300);
        check(locker.calls == 1, "impostor Lock ignored");

        print("== case 7: a repeated request inside the guard window is dropped ==\n");
        l.repeat_guard_us = 500 * 1000;
        spin(600);
        session.lock_requested();
        check(wait_for(() => locker.calls == 2, 2000), "first Lock outside the window locks");
        session.lock_requested();
        spin(300);
        check(locker.calls == 2, "second Lock within 500 ms dropped (no loop)");
        l.repeat_guard_us = 0;

        print("== case 8: PrepareForSleep(true) locks, holds the inhibitor until the lock is up ==\n");
        locker.locked = false;
        locker.lock_after_ms = 300;
        bool released = false;
        int64 t0 = get_monotonic_time();
        int64 t_rel = 0;
        ulong h = l.inhibitor_released.connect(() => { released = true; t_rel = get_monotonic_time(); });
        manager.prepare_for_sleep(true);
        check(wait_for(() => locker.calls == 3, 2000), "lock_session called before sleep");
        spin(150);
        check(l.inhibitor_held && manager.inhibitor_open(), "inhibitor still held while the lock screen comes up");
        check(wait_for(() => released, 3000), "inhibitor released");
        int64 held_ms = (t_rel - t0) / 1000;
        check(held_ms >= 450 && held_ms < 1500, "held for lock (300 ms) + settle (200 ms): %d ms".printf((int) held_ms));
        check(wait_for(() => !manager.inhibitor_open(), 1000), "logind sees the inhibitor closed");

        print("== case 9: PrepareForSleep(false) takes the inhibitor again ==\n");
        manager.prepare_for_sleep(false);
        check(wait_for(() => l.inhibitor_held && manager.inhibit_calls == 2, 2000), "inhibitor re-taken after resume");
        check(manager.inhibitor_open(), "new inhibitor open");

        print("== case 10: sleep while already locked: no new lock, prompt release ==\n");
        released = false;
        uint before = locker.calls;
        t0 = get_monotonic_time();
        manager.prepare_for_sleep(true);
        check(wait_for(() => released, 1000), "inhibitor released");
        check((t_rel - t0) / 1000 < 150, "released without waiting");
        check(locker.calls == before, "no second lock");
        manager.prepare_for_sleep(false);
        wait_for(() => l.inhibitor_held, 2000);

        print("== case 11: lock-on-suspend off: no lock, prompt release ==\n");
        locker.locked = false;
        los = false;
        released = false;
        before = locker.calls;
        manager.prepare_for_sleep(true);
        check(wait_for(() => released, 1000), "inhibitor released");
        spin(100);
        check(locker.calls == before, "no lock with lock-on-suspend off");
        manager.prepare_for_sleep(false);
        wait_for(() => l.inhibitor_held, 2000);
        los = true;

        print("== case 12: a lock screen that never comes up does not block sleep ==\n");
        locker.locked = false;
        locker.lock_after_ms = 0;
        released = false;
        t0 = get_monotonic_time();
        manager.prepare_for_sleep(true);
        check(wait_for(() => released, 3000), "inhibitor released at the deadline");
        held_ms = (t_rel - t0) / 1000;
        check(held_ms >= 700 && held_ms < 1500, "released after sleep_wait_max_ms: %d ms".printf((int) held_ms));
        manager.prepare_for_sleep(false);
        wait_for(() => l.inhibitor_held, 2000);
        l.disconnect(h);

        print("== case 13: session from GetSessionByPID when XDG_SESSION_ID is unset or unknown ==\n");
        Environment.set_variable("XDG_SESSION_ID", "c99", true);
        manager.by_pid_path = "/org/freedesktop/login1/session/c8";
        var l2 = make_listener(client, new FakeLocker(), &los);
        done = false;
        l2.start.begin((o, r) => { started = l2.start.end(r); done = true; });
        wait_for(() => done, 3000);
        check(started && l2.session_path == "/org/freedesktop/login1/session/c8", "fell back to GetSessionByPID");
        l2.stop();

        print("== case 14: no session at all: still follows PrepareForSleep ==\n");
        Environment.unset_variable("XDG_SESSION_ID");
        manager.by_pid_fails = true;
        var locker3 = new FakeLocker();
        locker3.lock_after_ms = 50;
        var l3 = make_listener(client, locker3, &los);
        done = false;
        l3.start.begin((o, r) => { started = l3.start.end(r); done = true; });
        wait_for(() => done, 3000);
        check(!started && l3.session_path == null, "no session resolved");
        l.stop();
        manager.prepare_for_sleep(true);
        check(wait_for(() => locker3.calls == 1, 2000), "sleep still locks");
        manager.prepare_for_sleep(false);
        l3.stop();

        print("== case 15: stop() while start() is in flight leaves no inhibitor ==\n");
        var l4 = make_listener(client, new FakeLocker(), &los);
        done = false;
        l4.start.begin((o, r) => { l4.start.end(r); done = true; });
        l4.stop();
        wait_for(() => done, 3000);
        spin(200);
        check(!l4.inhibitor_held, "no inhibitor kept after an early stop()");

        print("== case 16: stop() closes the inhibitor ==\n");
        check(!l3.inhibitor_held && !l.inhibitor_held, "no inhibitor after stop");

        print("== case 17: the lock-client probe sees a singularity-lockscreen process of this user ==\n");
        string probe_dir = DirUtils.make_tmp("logind-lock-probe-XXXXXX");
        string fake_bin = Path.build_filename(probe_dir, "singularity-lockscreen");
        string sleep_bin = Environment.find_program_in_path("sleep");
        uint8[] sleep_data;
        FileUtils.get_data(sleep_bin, out sleep_data);
        FileUtils.set_data(fake_bin, sleep_data);
        FileUtils.chmod(fake_bin, 0755);
        check(!Singularity.LockClientProbe.running(Posix.getuid(), Posix.getpid()), "no lock client before");
        Pid child;
        Process.spawn_async(null, { fake_bin, "30" }, null, SpawnFlags.DO_NOT_REAP_CHILD, null, out child);
        check(wait_for(() => Singularity.LockClientProbe.running(Posix.getuid(), Posix.getpid()), 2000), "lock client seen");
        check(!Singularity.LockClientProbe.running((Posix.uid_t) ((uint) Posix.getuid() + 1), Posix.getpid()), "another user's lock client is not ours");
        Posix.kill(child, Posix.Signal.TERM);
        int status;
        Posix.waitpid(child, out status, 0);
        Process.close_pid(child);
        check(!Singularity.LockClientProbe.running(Posix.getuid(), Posix.getpid()), "gone after exit");
        FileUtils.remove(fake_bin);
        DirUtils.remove(probe_dir);
    } catch (Error e) {
        print("  FAIL: %s\n", e.message);
        failures++;
    }
    test_bus.down();
    print("== RESULT: %d passed, %d failed ==\n", passes, failures);
    return failures == 0 ? 0 : 1;
}
