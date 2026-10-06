using Singularity;

private Pid spawn(string[] argv) {
    Pid pid;
    try {
        Process.spawn_async(null, argv, null,
            SpawnFlags.DO_NOT_REAP_CHILD | SpawnFlags.SEARCH_PATH, null, out pid);
    } catch (SpawnError e) {
        assert_not_reached();
    }
    return pid;
}

private bool alive(Pid pid) {
    string stat;
    try {
        if (!FileUtils.get_contents("/proc/%d/stat".printf((int) pid), out stat)) return false;
    } catch (FileError e) {
        return false;
    }
    return stat.get_char(stat.last_index_of_char(')') + 2) != 'Z';
}

private void reap(Pid pid) {
    int status;
    Posix.waitpid(pid, out status, 0);
}

private void spin(uint ms) {
    var loop = new MainLoop();
    Timeout.add(ms, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
}

private int run_terminate(ProcessTerminator terminator) {
    var loop = new MainLoop();
    int killed = -1;
    terminator.terminate.begin((obj, res) => {
        killed = terminator.terminate.end(res);
        loop.quit();
    });
    loop.run();
    return killed;
}

private void test_refuses_protected_pids() {
    var terminator = new ProcessTerminator(500);
    assert(!terminator.may_signal(0));
    assert(!terminator.may_signal(1));
    assert(!terminator.may_signal(Posix.getpid()));
    assert(!terminator.may_signal((int) Posix.getppid()));
    assert(!terminator.add(Posix.getpid()));
    assert(terminator.list_pids().length == 0);
}

private void test_term_then_kill_only_targets() {
    Pid polite = spawn({ "sleep", "300" });
    Pid stubborn = spawn({ "sh", "-c", "trap '' TERM; exec sleep 300" });
    Pid decoy = spawn({ "sleep", "300" });
    spin(200);

    var terminator = new ProcessTerminator(800);
    assert(terminator.add((int) polite, false));
    assert(terminator.add((int) stubborn, false));
    assert(terminator.list_pids().length == 2);

    int killed = run_terminate(terminator);
    assert(killed == 1);
    spin(100);
    assert(!alive(polite));
    assert(!alive(stubborn));
    assert(alive(decoy));

    Posix.kill(decoy, Posix.Signal.TERM);
    reap(polite);
    reap(stubborn);
    reap(decoy);
}

private void test_reused_pid_is_not_signalled() {
    Pid target = spawn({ "sleep", "300" });
    spin(100);
    var terminator = new ProcessTerminator(300);
    assert(terminator.add((int) target, false));
    Posix.kill(target, Posix.Signal.KILL);
    reap(target);
    assert(run_terminate(terminator) == 0);
}

private void test_scope_members_from_cgroup_root() {
    string dir;
    try {
        dir = DirUtils.make_tmp("singularity-terminator-test-XXXXXX");
    } catch (FileError e) {
        assert_not_reached();
    }
    string scope = Path.build_filename(dir, "app-test-demo-1.scope");
    DirUtils.create(scope, 0700);
    try {
        FileUtils.set_contents(Path.build_filename(scope, "cgroup.procs"), "101\n202\n\n");
    } catch (FileError e) {
        assert_not_reached();
    }
    var terminator = new ProcessTerminator(300, "/proc", dir);
    int[] members = terminator.scope_members("/app-test-demo-1.scope");
    assert(members.length == 2);
    assert(members[0] == 101 && members[1] == 202);
    assert(terminator.scope_members("/missing.scope").length == 0);
    FileUtils.remove(Path.build_filename(scope, "cgroup.procs"));
    DirUtils.remove(scope);
    DirUtils.remove(dir);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/terminator/protected", test_refuses_protected_pids);
    Test.add_func("/terminator/term-then-kill", test_term_then_kill_only_targets);
    Test.add_func("/terminator/reused-pid", test_reused_pid_is_not_signalled);
    Test.add_func("/terminator/scope-members", test_scope_members_from_cgroup_root);
    return Test.run();
}
