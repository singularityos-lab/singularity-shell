using GLib;

namespace Singularity {

    public delegate uint SearchStartDelay(SearchProvider provider);

    public class SearchSession : GLib.Object {
        private const uint FRAME_MS = 16;

        public string text { get; construct; }
        public bool done { get; private set; default = false; }

        public signal void results_updated(List<SearchResult> results);
        public signal void finished();

        private Cancellable cancellable = new Cancellable();
        private List<SearchResult> merged = new List<SearchResult>();
        private SearchRound round;
        private bool dirty = false;
        private bool emitted_once = false;
        private uint flush_source = 0;
        private GenericArray<uint> start_sources = new GenericArray<uint>();

        public SearchSession(string text) {
            Object(text: text);
        }

        public bool cancelled {
            get { return cancellable.is_cancelled(); }
        }

        public void start(List<SearchProvider> providers, SearchStartDelay? delay = null) {
            var ordered = new GenericArray<SearchProvider>();
            foreach (var p in providers) ordered.add(p);
            round = new SearchRound((int) ordered.length);
            if (round.finished) {
                emit_now();
                finish();
                return;
            }
            uint turn = 0;
            for (uint i = 0; i < ordered.length; i++) {
                var provider = ordered[i];
                uint wait = delay != null ? delay(provider) : 0;
                if (i == 0 && wait == 0) {
                    run(provider);
                    continue;
                }
                uint slot = start_sources.length;
                start_sources.add(0);
                SourceFunc fire = () => {
                    start_sources[slot] = 0;
                    run(provider);
                    return Source.REMOVE;
                };
                if (wait > 0) {
                    start_sources[slot] = Timeout.add(wait, (owned) fire, Priority.DEFAULT_IDLE);
                } else {
                    turn++;
                    start_sources[slot] = Idle.add((owned) fire, Priority.DEFAULT_IDLE + (int) turn);
                }
            }
        }

        public void cancel() {
            if (cancellable.is_cancelled()) return;
            cancellable.cancel();
            foreach (var id in start_sources.data) {
                if (id != 0) Source.remove(id);
            }
            start_sources = new GenericArray<uint>();
            if (flush_source != 0) {
                Source.remove(flush_source);
                flush_source = 0;
            }
        }

        private void run(SearchProvider provider) {
            if (cancellable.is_cancelled()) return;
            provider.search.begin(text, cancellable, (obj, res) => {
                List<SearchResult>? found = null;
                try {
                    found = provider.search.end(res);
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED)) warning("Search provider %s error: %s", provider.name, e.message);
                }
                if (cancellable.is_cancelled()) return;
                bool any = found != null && found.length() > 0;
                if (any) merge(found);
                if (round.provider_done(any)) {
                    dirty = true;
                    schedule_flush();
                }
                if (round.finished) {
                    if (dirty || !emitted_once) emit_now();
                    finish();
                }
            });
        }

        private void merge(List<SearchResult> found) {
            var by_action = new HashTable<string, SearchResult>(str_hash, str_equal);
            foreach (var existing in merged) {
                if (existing.action_id != null) by_action[existing.action_id] = existing;
            }
            foreach (var r in found) {
                if (r.action_id != null) {
                    var existing = by_action[r.action_id];
                    if (existing != null) {
                        if (r.score > existing.score) existing.score = r.score;
                        continue;
                    }
                    by_action[r.action_id] = r;
                }
                merged.append(r);
            }
            merged.sort((a, b) => {
                if (a.score > b.score) return -1;
                if (a.score < b.score) return 1;
                return 0;
            });
            merged = group_by_provider(merged);
        }

        private void schedule_flush() {
            if (!emitted_once) {
                emit_now();
                return;
            }
            if (flush_source != 0) return;
            flush_source = Timeout.add(FRAME_MS, () => {
                flush_source = 0;
                if (dirty && !cancellable.is_cancelled()) emit_now();
                return Source.REMOVE;
            });
        }

        private void emit_now() {
            dirty = false;
            emitted_once = true;
            if (flush_source != 0) {
                Source.remove(flush_source);
                flush_source = 0;
            }
            results_updated(merged);
        }

        private void finish() {
            if (done) return;
            done = true;
            finished();
        }

        public static List<SearchResult> group_by_provider(List<SearchResult> sorted) {
            var order = new GenericArray<string>();
            var groups = new HashTable<string, GenericArray<SearchResult>>(str_hash, str_equal);
            foreach (var r in sorted) {
                string key = r.provider.id;
                var group = groups[key];
                if (group == null) {
                    group = new GenericArray<SearchResult>();
                    groups[key] = group;
                    order.add(key);
                }
                group.add(r);
            }
            var grouped = new List<SearchResult>();
            foreach (unowned string key in order.data) {
                foreach (var r in groups[key].data) grouped.append(r);
            }
            return grouped;
        }
    }
}
