void main() {
    var sinty = Singularity.OsIdentity.from_values(
        "Sinty OS", "Sinty OS Event Horizon 26", "26", "26A011");
    assert(sinty.name == "Sinty OS");
    assert(sinty.version_id == "26");
    assert(sinty.build_id == "26A011");
    assert(sinty.menu_label() == "Sinty OS Event Horizon 26 (Build 26A011)");

    var numeric_build = Singularity.OsIdentity.from_values(
        "Example Linux", "Example Linux 42", "42", "42");
    assert(numeric_build.menu_label() == "Example Linux 42 (Build 42)");

    var generic = Singularity.OsIdentity.from_values(
        null, "Fedora Linux 42", null, null);
    assert(generic.name == "Fedora Linux 42");
    assert(generic.menu_label() == "Fedora Linux 42");

    var no_pretty_name = Singularity.OsIdentity.from_values(
        "Debian GNU/Linux", null, "13", null);
    assert(no_pretty_name.pretty_name == "Debian GNU/Linux 13");

    var missing = Singularity.OsIdentity.from_values(null, null, null, null);
    assert(missing.name == "Linux");
    assert(missing.menu_label() == "Linux");

    var current = Singularity.OsIdentity.load();
    assert(current.name != "");
    assert(current.pretty_name != "");
}
