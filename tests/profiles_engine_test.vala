using Singularity.Profiles;
using Singularity.ProfilesService;

void check(bool cond, string what) {
    if (!cond) {
        stderr.printf("FAIL: %s\n", what);
        Process.exit(1);
    }
}

void settle() {
    var ctx = MainContext.default();
    for (int i = 0; i < 200; i++) {
        while (ctx.pending()) ctx.iteration(false);
        Thread.usleep(1000);
    }
}

class Store : Object {
    public Gee.HashMap<string, string> values = new Gee.HashMap<string, string>();
    public int writes = 0;
}

Area make_area(string id, Store store, string[] keys) {
    var area = new Area(id, id, "");
    foreach (string k in keys) area.add(new Option(k, k, OptionKind.STRUCTURED));
    area.handlers((key) => store.values[key], (key, json) => {
        store.values[key] = json;
        store.writes++;
    });
    return area;
}

int main(string[] args) {
    string root = DirUtils.make_tmp("profiles-engine-XXXXXX");
    string config = Path.build_filename(root, "config");
    string state_dir = Path.build_filename(root, "state");
    DirUtils.create_with_parents(config, 0700);
    FileUtils.set_contents(Path.build_filename(config, "focus-modes.json"),
        "{\"version\":1,\"modes\":[{\"id\":\"do-not-disturb\",\"name\":\"Do Not Disturb\"},{\"id\":\"custom-reading\",\"name\":\"Reading\",\"apps\":[\"books\"],\"while-fullscreen\":true}]}");

    var engine = new Engine(config, state_dir);
    check(engine.set.find("work") != null && engine.set.find("evening") != null, "defaults are present");
    var reading = engine.set.find("custom-reading");
    check(reading != null, "Focus mode migrated to a profile");
    check(reading.get_value(Areas.NOTIFICATIONS, "rules").contains("books"), "allowed apps kept");
    check(reading.rules.size == 1 && reading.rules[0].conditions[0].kind == ConditionKind.FULLSCREEN, "Focus trigger kept");

    var facts = new Store();
    facts.values["wifi"] = string_value("");
    facts.values["fullscreen"] = "false";
    var state = make_area(Areas.STATE, facts, { "wifi", "fullscreen" });
    foreach (var o in state.info.options) o.read_only = true;
    engine.add_area(new AreaHandle.local(state));

    var look = new Store();
    look.values["dark-mode"] = "false";
    look.values["accent"] = string_value("blue");
    engine.add_area(new AreaHandle.local(make_area(Areas.APPEARANCE, look, { "dark-mode", "accent" })));

    var sound = new Store();
    sound.values["volume"] = "60";
    engine.add_area(new AreaHandle.local(make_area(Areas.AUDIO, sound, { "volume" })));

    var office = new Profile("custom-office", "Office", "x");
    office.set_value(Areas.APPEARANCE, "accent", string_value("green"));
    office.set_value(Areas.AUDIO, "volume", "20");
    var r = new Rule();
    var c = new Condition(ConditionKind.WIFI);
    c.match = "Office";
    r.conditions.add(c);
    office.rules.add(r);
    try {
        engine.save_profile(office);
    } catch (Error e) {
        check(false, e.message);
    }
    settle();
    check(engine.active_id == "", "nothing active yet");

    facts.values["wifi"] = string_value("Office");
    state.notify_changed({ "wifi" });
    settle();
    check(engine.active_id == "custom-office" && engine.reason == "rule", "wifi rule activates the profile");
    check(look.values["accent"] == string_value("green") && sound.values["volume"] == "20", "values applied");
    check(look.values["dark-mode"] == "false", "keys left at Don't Change stay");

    sound.values["volume"] = "35";
    facts.values["wifi"] = string_value("Home");
    state.notify_changed({ "wifi" });
    settle();
    check(engine.active_id == "", "profile ends when the rule stops");
    check(look.values["accent"] == string_value("blue"), "accent restored");
    check(sound.values["volume"] == "35", "a value the user changed by hand is kept");

    engine.activate("evening");
    settle();
    check(engine.active_id == "evening" && engine.reason == "manual", "manual activation");
    check(look.values["dark-mode"] == "true", "evening turns dark mode on");
    engine.activate("custom-office");
    settle();
    check(look.values["dark-mode"] == "false", "switching restores what the old profile changed");
    check(look.values["accent"] == string_value("green"), "and applies the new one");
    engine.deactivate();
    settle();
    check(engine.active_id == "" && look.values["accent"] == string_value("blue"), "manual off restores");

    facts.values["wifi"] = string_value("Office");
    state.notify_changed({ "wifi" });
    settle();
    check(engine.active_id == "custom-office", "rule active again");
    engine.deactivate();
    settle();
    check(engine.active_id == "", "turning off an automatic profile");
    state.notify_changed({ "wifi" });
    settle();
    check(engine.active_id == "", "stays off while its rule still holds");
    facts.values["wifi"] = string_value("Home");
    state.notify_changed({ "wifi" });
    settle();
    facts.values["wifi"] = string_value("Office");
    state.notify_changed({ "wifi" });
    settle();
    check(engine.active_id == "custom-office", "comes back the next time the rule starts");

    var reload = new Engine(config, state_dir);
    check(reload.active_id == "custom-office", "session survives a restart");
    check(reload.set.find("custom-office") != null, "saved profiles survive a restart");

    try {
        engine.delete_profile("evening");
        check(false, "built-in profiles cannot be removed");
    } catch (Error e) {
    }

    print("profiles-engine: ok\n");
    return 0;
}
