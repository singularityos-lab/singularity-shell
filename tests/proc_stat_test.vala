void test_parse () {
    Singularity.ProcStat s;
    string line = "4242 (singularity-des (x)) S 1 4242 4242 0 -1 4194560 100 0 0 0 250 50 0 0 20 0 12 0 1000 123456789 5120 18446744073709551615 1 1 0 0 0 0 0 4096 0 0 0 0 17 3 0 0 0 0 0";
    assert (Singularity.ProcStats.parse (line, out s));
    assert (s.pid == 4242);
    assert (s.comm == "singularity-des (x)");
    assert (s.cpu_ticks == 300);
    assert (s.start_ticks == 1000);
    assert (s.rss_pages == 5120);
    assert (Math.fabs (Singularity.ProcStats.cpu_percent (s, 40.0, 100.0) - 10.0) < 0.001);
    assert (Singularity.ProcStats.cpu_percent (s, 5.0, 100.0) == 0.0);
    assert (!Singularity.ProcStats.parse ("garbage", out s));
    assert (!Singularity.ProcStats.parse ("12 (x) S 1 2", out s));
}

void test_live () {
    var list = Singularity.ProcStats.snapshot ();
    bool self = false;
    foreach (var p in list.data) if (p.pid == Posix.getpid ()) self = true;
    assert (self);
    assert (Singularity.ProcStats.uptime () > 0);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/proc-stat/parse", test_parse);
    Test.add_func ("/proc-stat/live", test_live);
    return Test.run ();
}
