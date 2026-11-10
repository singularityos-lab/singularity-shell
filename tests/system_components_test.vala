uint8[] blob (string[] parts) {
    var b = new ByteArray ();
    foreach (string p in parts) {
        b.append (p.data);
        b.append ({ 0, 0x90, 0xff, 0 });
    }
    return b.steal ();
}

void test_versions () {
    assert (Singularity.SystemComponents.embedded_version (blob ({ "Usage: %s", "5.6", "1.52.1", "0.7" }), false) == "1.52.1");
    assert (Singularity.SystemComponents.embedded_version (blob ({ "help", "5.79" }), true) == "5.79");
    assert (Singularity.SystemComponents.embedded_version (blob ({ "1.4", "2.1" }), true) == null);
    assert (Singularity.SystemComponents.embedded_version (blob ({ "1.4" }), false) == null);
    assert (Singularity.SystemComponents.embedded_version (blob ({ "1.2.3.4", "a.b.c", "12345.1.1" }), false) == null);
}

void test_labwc () {
    var lits = Singularity.SystemComponents.literals (blob ({ "libxcb.so.1", "librsvg-2.so.2", "libwlroots-0.19.so", "labwc" }));
    string d = Singularity.SystemComponents.labwc_features (lits, false);
    assert (d == "labwc (+xwayland -nls +rsvg -libsfdo) wlroots-0.19");
    assert (Singularity.SystemComponents.labwc_features (Singularity.SystemComponents.literals (blob ({ "libsfdo-basedir.so.0" })), true)
        == "labwc (-xwayland +nls -rsvg +libsfdo)");
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/components/versions", test_versions);
    Test.add_func ("/components/labwc", test_labwc);
    return Test.run ();
}
