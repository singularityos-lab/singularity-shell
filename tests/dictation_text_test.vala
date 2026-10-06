using GLib;
using Singularity.Dictation;

private void check(string raw, string language, bool punctuation, string before, string expected) {
    string got = DictationText.format(raw, language, punctuation, before);
    if (got != expected) {
        printerr("format(\"%s\", %s, %s, \"%s\")\n  got      \"%s\"\n  expected \"%s\"\n",
            raw, language, punctuation.to_string(), before, got.escape(), expected.escape());
    }
    assert(got == expected);
}

private void test_english_commands() {
    check("hello comma world period", "en", true, "", "Hello, world.");
    check("is it done question mark", "en", true, "", "Is it done?");
    check("wow exclamation mark", "en", true, "", "Wow!");
    check("note colon buy milk semicolon eggs", "en", true, "", "Note: buy milk; eggs");
    check("first line new line second line", "en", true, "", "First line\nSecond line");
    check("end new paragraph start", "en", true, "", "End\n\nStart");
    check("one full stop two", "en", true, "", "One. Two");
}

private void test_italian_commands() {
    check("ciao virgola mondo punto", "it", true, "", "Ciao, mondo.");
    check("come stai punto interrogativo", "it", true, "", "Come stai?");
    check("lista due punti pane punto e virgola latte", "it", true, "", "Lista: pane; latte");
    check("prima riga a capo seconda riga", "it", true, "", "Prima riga\nSeconda riga");
    check("fine nuovo paragrafo inizio", "it", true, "", "Fine\n\nInizio");
    check("che bello punto esclamativo", "it", true, "", "Che bello!");
}

private void test_engine_punctuation_merges_with_commands() {
    check("Hello, comma, world. Period.", "en", true, "", "Hello, world.");
    check("Ciao, virgola, mondo.", "it", true, "", "Ciao, mondo.");
    check("Hello there. New line. Bye.", "en", true, "", "Hello there.\nBye.");
}

private void test_auto_punctuation_off() {
    check("Hello, world. How are you?", "en", false, "", "Hello world How are you");
    check("hello comma world period", "en", false, "", "Hello, world.");
}

private void test_context_spacing_and_capitals() {
    check("world", "en", true, "Hello", " world");
    check("world", "en", true, "Hello ", "world");
    check("next one", "en", true, "Done.", " Next one");
    check("next one", "en", true, "Line\n", "Next one");
    check("comma", "en", true, "Hello", ",");
    check("and more", "en", true, "Hello,", " and more");
}

private void test_automatic_language_uses_both_sets() {
    check("hello comma world", "auto", true, "", "Hello, world");
    check("ciao virgola mondo", "auto", true, "", "Ciao, mondo");
}

private void test_normalize_word() {
    assert(DictationText.normalize_word("Comma,") == "comma");
    assert(DictationText.normalize_word("¿Qué?") == "qué");
    assert(DictationText.normalize_word("...") == "");
}

private void test_empty() {
    check("", "en", true, "Hello", "");
    check("   ", "en", true, "", "");
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/dictation/text/english", test_english_commands);
    Test.add_func("/dictation/text/italian", test_italian_commands);
    Test.add_func("/dictation/text/merge-engine-punctuation", test_engine_punctuation_merges_with_commands);
    Test.add_func("/dictation/text/punctuation-off", test_auto_punctuation_off);
    Test.add_func("/dictation/text/context", test_context_spacing_and_capitals);
    Test.add_func("/dictation/text/automatic-language", test_automatic_language_uses_both_sets);
    Test.add_func("/dictation/text/normalize", test_normalize_word);
    Test.add_func("/dictation/text/empty", test_empty);
    return Test.run();
}
