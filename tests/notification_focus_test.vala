using GLib;
using Singularity;

private DateTime at(int day_of_month, int hour, int minute) {
    return new DateTime.local(2026, 9, day_of_month, hour, minute, 0);
}

private NotificationFacts facts(string app, string summary = "", uint8 urgency = 1) {
    var f = new NotificationFacts();
    f.app_key = app;
    f.summary = summary;
    f.urgency = urgency;
    return f;
}

private void test_schedule_same_day() {
    var s = new FocusSchedule(FocusSchedule.WEEKDAYS, 9 * 60, 17 * 60);
    assert(s.covers(at(28, 9, 0)));
    assert(s.covers(at(28, 16, 59)));
    assert(!s.covers(at(28, 17, 0)));
    assert(!s.covers(at(28, 8, 59)));
    assert(!s.covers(at(27, 10, 0)));
}

private void test_schedule_overnight() {
    var s = new FocusSchedule(1 << 0, 22 * 60, 7 * 60);
    assert(s.covers(at(28, 23, 30)));
    assert(s.covers(at(29, 6, 59)));
    assert(!s.covers(at(29, 7, 0)));
    assert(!s.covers(at(29, 23, 0)));
    assert(!s.covers(at(28, 6, 0)));
}

private void test_schedule_disabled() {
    var s = new FocusSchedule(FocusSchedule.ALL_DAYS, 0, 23 * 60 + 59, false);
    assert(!s.covers(at(28, 12, 0)));
}

private void test_evaluate_priority() {
    var set = FocusModeSet.defaults();
    var work = set.find("work");
    work.schedules.add(new FocusSchedule(FocusSchedule.ALL_DAYS, 9 * 60, 17 * 60));
    set.find("personal").while_fullscreen = true;

    var state = set.evaluate("", at(28, 10, 0), false, false);
    assert(state.active && state.mode.id == "work" && state.reason == FocusReason.SCHEDULE);

    state = set.evaluate("sleep", at(28, 10, 0), false, false);
    assert(state.mode.id == "sleep" && state.reason == FocusReason.MANUAL);

    state = set.evaluate("", at(28, 20, 0), true, false);
    assert(state.mode.id == "work" && state.reason == FocusReason.PRESENTING);

    state = set.evaluate("", at(28, 20, 0), false, true);
    assert(state.mode.id == "personal" && state.reason == FocusReason.FULLSCREEN);

    state = set.evaluate("", at(28, 20, 0), false, false);
    assert(!state.active && state.reason == FocusReason.NONE);

    state = set.evaluate("missing", at(28, 20, 0), false, false);
    assert(!state.active);
}

private void test_modes_roundtrip() {
    var set = FocusModeSet.defaults();
    var custom = new FocusMode(set.unique_id("Deep Work!"), "Deep Work!", "focus-custom-symbolic");
    custom.allowed_apps.add("dev-sinty-calendar");
    custom.allowed_people.add(new FocusPerson("Alice Rossi", { "alice@cloud.test" }));
    custom.schedules.add(new FocusSchedule(3, 8 * 60 + 30, 12 * 60));
    custom.while_fullscreen = true;
    set.modes.add(custom);
    assert(custom.id == "custom-deep-work");
    assert(set.unique_id("Deep Work") == "custom-deep-work-2");

    var back = FocusModeSet.from_data(set.to_data());
    assert(back.modes.size == 5);
    var m = back.find("custom-deep-work");
    assert(m != null && m.name == "Deep Work!" && m.while_fullscreen);
    assert(m.allowed_apps.size == 1 && m.allowed_apps[0] == "dev-sinty-calendar");
    assert(m.allowed_people.size == 1 && m.allowed_people[0].handles[0] == "alice@cloud.test");
    assert(m.schedules.size == 1 && m.schedules[0].start_minute == 510 && m.schedules[0].days == 3);
    assert(!back.find("do-not-disturb").allow_time_sensitive);
}

private void test_modes_corrupt_file() {
    var set = FocusModeSet.from_data("{not json");
    assert(set.find("do-not-disturb") != null && set.modes.size == 4);
    var only_custom = FocusModeSet.from_data("{\"modes\":[{\"id\":\"x\",\"name\":\"X\"}]}");
    assert(only_custom.find("do-not-disturb") != null && only_custom.find("x") != null);
}

private void test_decide_without_focus() {
    var policy = new AppNotificationPolicy();
    var d = NotificationRules.decide(policy, null, facts("chat"));
    assert(d.store && d.banner && d.sound && !d.silenced);
    policy.banners = false;
    policy.sounds = false;
    d = NotificationRules.decide(policy, null, facts("chat"));
    assert(d.store && !d.banner && !d.sound && !d.silenced);
}

private void test_decide_disallowed() {
    var policy = new AppNotificationPolicy();
    policy.allowed = false;
    var d = NotificationRules.decide(policy, null, facts("chat"));
    assert(!d.store && !d.banner && !d.sound);
    d = NotificationRules.decide(policy, null, facts("chat", "Battery low", 2));
    assert(d.store && d.banner);
}

private void test_decide_focus_exceptions() {
    var mode = new FocusMode("work", "Work", "focus-work-symbolic");
    mode.allowed_apps.add("calendar");
    mode.allowed_people.add(new FocusPerson("Alice Rossi"));
    var policy = new AppNotificationPolicy();

    var d = NotificationRules.decide(policy, mode, facts("chat", "Bob"));
    assert(d.silenced && d.store && !d.banner && !d.sound);

    d = NotificationRules.decide(policy, mode, facts("calendar", "Standup"));
    assert(!d.silenced && d.banner);

    d = NotificationRules.decide(policy, mode, facts("chat", "Message from alice rossi"));
    assert(!d.silenced && d.banner);

    d = NotificationRules.decide(policy, mode, facts("chat", "Anything", 2));
    assert(!d.silenced && d.banner);

    policy.priority = AppNotificationPolicy.PRIORITY_TIME_SENSITIVE;
    d = NotificationRules.decide(policy, mode, facts("chat", "Bob"));
    assert(!d.silenced && d.time_sensitive);
    mode.allow_time_sensitive = false;
    d = NotificationRules.decide(policy, mode, facts("chat", "Bob"));
    assert(d.silenced);
}

private void test_decide_transient() {
    var policy = new AppNotificationPolicy();
    var f = facts("chat");
    f.transient = true;
    var d = NotificationRules.decide(policy, null, f);
    assert(!d.store && d.banner);
    var mode = new FocusMode("dnd", "DND", "x");
    d = NotificationRules.decide(policy, mode, f);
    assert(d.store && d.silenced);
}

private void test_app_key() {
    assert(NotificationRules.app_key_for("Telegram Desktop", null) == "telegram-desktop");
    assert(NotificationRules.app_key_for("x", "dev.sinty.Calendar.desktop") == "dev-sinty-calendar");
    assert(NotificationRules.app_key_for("  ", "") == "unknown");
}

private Singularity.Notification sample(uint id, int64 ts) {
    var n = new Singularity.Notification.with_time(id, "Chat", "Hello %u".printf(id), "Body \"quoted\"\nline", "/icons/%u.png".printf(id),
        { "default", "Open", "inline-reply", "Reply" }, ts);
    n.app_key = "chat";
    n.silenced = id % 2 == 0;
    n.lock_screen = AppNotificationPolicy.LOCK_SHOW;
    return n;
}

private void test_history_roundtrip() {
    var items = new Gee.ArrayList<Singularity.Notification>();
    items.add(sample(7, 1000));
    items.add(sample(4, 900));
    string data = NotificationHistoryFile.serialize(items, 42);
    assert(NotificationHistoryFile.read_next_id(data) == 42);
    var back = NotificationHistoryFile.deserialize(data);
    assert(back.size == 2);
    assert(back[0].id == 7 && back[0].summary == "Hello 7" && back[0].body == "Body \"quoted\"\nline");
    assert(back[0].restored && !back[0].has_inline_reply && back[0].actions.length == 0);
    assert(back[1].silenced && back[1].lock_screen == AppNotificationPolicy.LOCK_SHOW);
    assert(items[0].has_inline_reply);
}

private void test_history_prune() {
    int64 now = (int64) 30 * 86400 * 1000000;
    var items = new Gee.ArrayList<Singularity.Notification>();
    items.add(sample(3, now - 1000000));
    items.add(sample(2, now - (int64) 2 * 86400 * 1000000));
    items.add(sample(1, now - (int64) 9 * 86400 * 1000000));
    assert(NotificationHistoryFile.prune(items, 7, now, 200).size == 2);
    assert(NotificationHistoryFile.prune(items, 1, now, 200).size == 1);
    assert(NotificationHistoryFile.prune(items, 0, now, 200).size == 3);
    assert(NotificationHistoryFile.prune(items, 30, now, 2).size == 2);
}

private void test_history_file() {
    string dir = "";
    try {
        dir = DirUtils.make_tmp("notif-history-XXXXXX");
    } catch (FileError e) {
        error("setup: %s", e.message);
    }
    var file = new NotificationHistoryFile(Path.build_filename(dir, "sub", "history.json"));
    assert(file.load().size == 0);
    var items = new Gee.ArrayList<Singularity.Notification>();
    items.add(sample(11, 5));
    file.save(items);
    var loaded = file.load();
    assert(loaded.size == 1 && loaded[0].id == 11);
    try {
        FileUtils.set_contents(file.path, "garbage");
    } catch (Error e) {
        error("setup: %s", e.message);
    }
    Test.expect_message(null, LogLevelFlags.LEVEL_WARNING, "*unreadable file*");
    assert(file.load().size == 0);
    Test.assert_expected_messages();
}

public static int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/focus/schedule-same-day", test_schedule_same_day);
    Test.add_func("/focus/schedule-overnight", test_schedule_overnight);
    Test.add_func("/focus/schedule-disabled", test_schedule_disabled);
    Test.add_func("/focus/evaluate", test_evaluate_priority);
    Test.add_func("/focus/roundtrip", test_modes_roundtrip);
    Test.add_func("/focus/corrupt", test_modes_corrupt_file);
    Test.add_func("/rules/no-focus", test_decide_without_focus);
    Test.add_func("/rules/disallowed", test_decide_disallowed);
    Test.add_func("/rules/focus-exceptions", test_decide_focus_exceptions);
    Test.add_func("/rules/transient", test_decide_transient);
    Test.add_func("/rules/app-key", test_app_key);
    Test.add_func("/history/roundtrip", test_history_roundtrip);
    Test.add_func("/history/prune", test_history_prune);
    Test.add_func("/history/file", test_history_file);
    return Test.run();
}
