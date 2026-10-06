using Singularity;

private void test_empty_round_clears() {
    var round = new SearchRound(3);
    assert(!round.provider_done(false));
    assert(!round.provider_done(false));
    assert(round.provider_done(false));
    assert(round.finished);
}

private void test_results_emit_each_time() {
    var round = new SearchRound(3);
    assert(!round.provider_done(false));
    assert(round.provider_done(true));
    assert(!round.provider_done(false));
    assert(round.finished);
}

private void test_every_result_set_emits() {
    var round = new SearchRound(2);
    assert(round.provider_done(true));
    assert(round.provider_done(true));
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/search-round/empty-clears", test_empty_round_clears);
    Test.add_func("/search-round/results-emit", test_results_emit_each_time);
    Test.add_func("/search-round/every-set-emits", test_every_result_set_emits);
    return Test.run();
}
