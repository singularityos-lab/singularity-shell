using Singularity;

private void continuous_use() {
    var reminder = new BreakReminder();
    int notices = 0;
    for (int seconds = 0; seconds <= 180; seconds += 15) {
        if (reminder.advance(seconds * 1000000L, true, 60)) notices++;
    }
    assert(notices == 3);
}

private void pauses() {
    var reminder = new BreakReminder();
    assert(!reminder.advance(0, true, 60));
    assert(!reminder.advance(30000000, true, 60));
    assert(!reminder.advance(45000000, false, 60));
    assert(!reminder.advance(60000000, true, 60));
    assert(!reminder.advance(90000000, true, 60));
    assert(reminder.advance(120000000, true, 60));
    reminder.reset();
    assert(!reminder.advance(130000000, true, 60));
    assert(!reminder.advance(160000000, true, 60));
    assert(!reminder.advance(3600000000, true, 60));
    assert(!reminder.advance(3615000000, true, 60));
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/breaks/continuous", continuous_use);
    Test.add_func("/breaks/pauses-locks-suspend-reset", pauses);
    return Test.run();
}
