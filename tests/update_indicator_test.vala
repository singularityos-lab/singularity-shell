void main() {
    string public_label = Singularity.UpdateIndicator.format_version(
        "v999", "Sinty OS Event Horizon", "26", "26A011");
    assert(public_label == "Sinty OS Event Horizon 26 (Build 26A011)");
    assert(!public_label.contains("v999"));

    string partial_public_label = Singularity.UpdateIndicator.format_version(
        "v999", "", "", "26A011");
    assert(partial_public_label == "Build 26A011");
    assert(!partial_public_label.contains("v999"));

    string legacy_label = Singularity.UpdateIndicator.format_version(
        "v999", "", "", "");
    assert(legacy_label == "v999");

    assert(Singularity.UpdateIndicator.poll_interval(false, "idle") == 1);
    assert(Singularity.UpdateIndicator.poll_interval(true, "downloading") == 1);
    assert(Singularity.UpdateIndicator.poll_interval(true, "idle") == 5);

    assert(Singularity.UpdateIndicator.format_error("") ==
        "Update failed. Click to try again.");
    assert(Singularity.UpdateIndicator.format_error("staging failed") ==
        "Update failed: staging failed. Click to try again.");

    assert(Singularity.UpdateIndicator.valid_consent_token(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    assert(!Singularity.UpdateIndicator.valid_consent_token(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF"));
    assert(!Singularity.UpdateIndicator.valid_consent_token("short"));

    assert(live_class_of("{}") == "");
    assert(live_class_of("{\"live\":{\"class\":\"reload\",\"eligible\":true}}") == "reload");
    assert(live_class_of("{\"live\":{\"class\":\"relogin\",\"eligible\":true}}") == "relogin");
    assert(live_class_of("{\"live\":{\"class\":\"silent\",\"eligible\":true}}") == "silent");
    assert(live_class_of("{\"live\":{\"class\":\"reload\",\"eligible\":false}}") == "");
    assert(live_class_of("{\"live\":{\"class\":\"reboot\",\"eligible\":true}}") == "");
    assert(live_class_of("{\"live\":\"reload\"}") == "");

    assert(Singularity.UpdateIndicator.ready_tooltip("", "26") ==
        "Update ready: restart to apply 26");
    assert(Singularity.UpdateIndicator.ready_tooltip("reload", "26") ==
        "Update ready: apply 26 now");
    assert(Singularity.UpdateIndicator.ready_tooltip("relogin", "26") ==
        "Update ready: log out and back in to apply 26");
}

string live_class_of(string json) {
    var parser = new Json.Parser();
    try {
        parser.load_from_data(json);
    } catch (Error e) {
        assert_not_reached();
    }
    return Singularity.UpdateIndicator.parse_live_class(parser.get_root().get_object());
}
