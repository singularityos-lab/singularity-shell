using Singularity;

void test_new_windows_join_active() {
    var m = new StageModel();
    var a = m.add_window("a");
    var b = m.add_window("b");
    assert(a == b);
    assert(m.active == a);
    assert(m.set_count() == 1);
    assert(m.inactive_sets().size == 0);
}

void test_move_to_new_set_hides() {
    var m = new StageModel();
    m.add_window("a");
    m.add_window("b");
    var plan = m.move_window("b", 0);
    assert(plan.hide.size == 1 && plan.hide[0] == "b");
    assert(plan.show.size == 0);
    assert(m.set_count() == 2);
    assert(m.is_hidden("b"));
    assert(m.inactive_sets()[0].windows[0] == "b");
}

void test_activate_swaps_and_orders_mru() {
    var m = new StageModel();
    m.add_window("a");
    m.move_window(m.add_window("b").windows[1], 0);
    m.add_window("c");
    m.move_window("c", 0);
    var first = m.active.id;
    var sets = m.inactive_sets();
    assert(sets.size == 2);
    assert(sets[0].windows[0] == "c");
    var plan = m.activate(sets[1].id);
    assert(plan.show.size == 1 && plan.show[0] == "b");
    assert(plan.hide.size == 1 && plan.hide[0] == "a");
    assert(m.active.windows[0] == "b");
    assert(m.inactive_sets()[0].id == first);
    assert(m.inactive_sets()[1].windows[0] == "c");
    assert(!m.is_hidden("b"));
    assert(m.is_hidden("a"));
}

void test_user_minimized_stays_minimized() {
    var m = new StageModel();
    m.add_window("a");
    m.add_window("b");
    m.set_user_minimized("b", true);
    m.add_window("c");
    m.move_window("c", 0);
    var other = m.inactive_sets()[0].id;
    var plan = m.activate(other);
    assert(plan.hide.size == 1 && plan.hide[0] == "a");
    var back = m.inactive_sets()[0].id;
    plan = m.activate(back);
    assert(plan.show.size == 1 && plan.show[0] == "a");
    assert(m.is_user_minimized("b"));
}

void test_empty_sets_are_dropped() {
    var m = new StageModel();
    m.add_window("a");
    m.add_window("b");
    m.move_window("b", 0);
    m.remove_window("b");
    assert(m.inactive_sets().size == 0);
    m.remove_window("a");
    assert(m.active != null);
    assert(m.active.windows.size == 0);
    m.add_window("c");
    m.move_window("c", 0);
    var plan = m.activate(m.inactive_sets()[0].id);
    assert(plan.hide.size == 0);
    assert(m.inactive_sets().size == 0);
    assert(m.set_count() == 1);
}

void test_move_between_inactive_and_into_active() {
    var m = new StageModel();
    m.add_window("a");
    m.add_window("b");
    m.add_window("c");
    m.move_window("b", 0);
    m.move_window("c", 0);
    var set_c = m.set_for("c").id;
    var set_b = m.set_for("b").id;
    var plan = m.move_window("b", set_c);
    assert(plan.is_empty());
    assert(m.find_set(set_b) == null);
    assert(m.set_for("c").windows.size == 2);
    plan = m.move_window("c", m.active.id);
    assert(plan.show.size == 1 && plan.show[0] == "c");
    assert(m.set_for("c") == m.active);
}

void test_clear_restores_hidden() {
    var m = new StageModel();
    m.add_window("a");
    m.add_window("b");
    m.move_window("b", 0);
    var restore = m.clear();
    assert(restore.size == 1 && restore[0] == "b");
    assert(m.set_count() == 0);
    assert(!m.contains("a"));
}

void test_activate_unknown_is_noop() {
    var m = new StageModel();
    m.add_window("a");
    assert(m.activate(999).is_empty());
    assert(m.activate(m.active.id).is_empty());
    assert(m.move_window("zzz", 0).is_empty());
}

void test_restore_rebuilds_sets_and_active() {
    var m = new StageModel();
    m.restore_window("a", 40, false, false);
    m.restore_window("b", 41, true, true);
    m.restore_window("c", 42, true, true);
    m.restore_window("d", 41, true, false);
    var order = new Gee.ArrayList<uint>();
    order.add(42);
    order.add(41);
    var plan = m.restore_finish(40, order);
    assert(plan.is_empty());
    assert(m.active.id == 40);
    assert(m.inactive_sets().size == 2);
    assert(m.inactive_sets()[0].id == 42);
    assert(m.inactive_sets()[1].id == 41);
    assert(m.is_hidden("b"));
    assert(m.is_user_minimized("d"));
    var next = new StageModel();
    next.add_window("z");
    assert(next.active.id > 42);
}

void test_restore_never_leaves_active_hidden() {
    var m = new StageModel();
    m.restore_window("a", 50, true, true);
    m.restore_window("b", 51, false, false);
    var plan = m.restore_finish(50, null);
    assert(m.active.id == 50);
    assert(plan.show.size == 1 && plan.show[0] == "a");
    assert(plan.hide.size == 1 && plan.hide[0] == "b");
    assert(!m.is_hidden("a"));
    assert(m.is_hidden("b"));
}

void test_restore_without_state_picks_visible_set() {
    var m = new StageModel();
    m.restore_window("a", 60, true, true);
    m.restore_window("b", 61, false, false);
    m.restore_window("new", 0, false, false);
    var plan = m.restore_finish(0, null);
    assert(m.active.id == 61);
    assert(m.set_for("new") == m.active);
    assert(plan.is_empty());
    assert(m.inactive_sets().size == 1);
}

void test_adopt_merges_other_monitor() {
    var gone = new StageModel();
    gone.add_window("a");
    gone.add_window("b");
    gone.move_window("b", 0);
    var m = new StageModel();
    m.add_window("c");
    m.adopt(gone);
    assert(m.set_for("a") == m.active);
    assert(m.set_for("c") == m.active);
    assert(m.inactive_sets().size == 1);
    assert(m.is_hidden("b"));
    assert(gone.set_count() == 0);
    assert(!gone.contains("a"));
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/stage/new-windows-join-active", test_new_windows_join_active);
    Test.add_func("/stage/move-to-new-set-hides", test_move_to_new_set_hides);
    Test.add_func("/stage/activate-swaps-and-orders-mru", test_activate_swaps_and_orders_mru);
    Test.add_func("/stage/user-minimized-stays-minimized", test_user_minimized_stays_minimized);
    Test.add_func("/stage/empty-sets-are-dropped", test_empty_sets_are_dropped);
    Test.add_func("/stage/move-between-inactive-and-into-active", test_move_between_inactive_and_into_active);
    Test.add_func("/stage/clear-restores-hidden", test_clear_restores_hidden);
    Test.add_func("/stage/activate-unknown-is-noop", test_activate_unknown_is_noop);
    Test.add_func("/stage/restore-rebuilds-sets-and-active", test_restore_rebuilds_sets_and_active);
    Test.add_func("/stage/restore-never-leaves-active-hidden", test_restore_never_leaves_active_hidden);
    Test.add_func("/stage/restore-without-state-picks-visible-set", test_restore_without_state_picks_visible_set);
    Test.add_func("/stage/adopt-merges-other-monitor", test_adopt_merges_other_monitor);
    return Test.run();
}
