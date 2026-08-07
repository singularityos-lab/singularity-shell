using GLib;
using Gtk;
using Json;

namespace Singularity {

    public class SearchManager : GLib.Object {
        private static SearchManager? _instance = null;
        private List<SearchProvider> providers;
        private FileSearchProvider? file_provider = null;
        private Cancellable? current_cancellable = null;

        public signal void results_updated(List<SearchResult> results);
        public signal void search_started();
        public signal void search_finished();

        public static SearchManager get_default() {
            if (_instance == null) {
                _instance = new SearchManager();
            }
            return _instance;
        }

        private SearchManager() {
            providers = new List<SearchProvider>();
            load_providers();
            // Pick up any providers already registered (e.g. by plugins
            // activated before SearchManager was first instantiated), and
            // listen for future ones.
            var reg = SearchProviderRegistry.get_default();
            foreach (var p in reg.list()) providers.append(p);
            reg.added.connect((p) => providers.append(p));
            reg.removed.connect((p) => providers.remove(p));
        }

        private void load_providers() {
            providers.append(new AppSearchProvider());
            providers.append(new MathSearchProvider());
            // Create the file provider eagerly so its Tracker connection is
            // established at startup rather than on the first search keystroke.
            file_provider = new FileSearchProvider();
            providers.append(file_provider);
            load_script_providers();
        }

        private void load_script_providers() {
            string config_dir = GLib.Path.build_filename(Environment.get_user_config_dir(), "singularity", "search-providers");
            Dir? dir = null;
            try {
                dir = Dir.open(config_dir, 0);
            } catch (Error e) {
                try { DirUtils.create_with_parents(config_dir, 0755); } catch (Error e2) {}
                return;
            }

            string? name;
            while ((name = dir.read_name()) != null) {
                string path = GLib.Path.build_filename(config_dir, name);
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) {
                    providers.append(new ScriptSearchProvider(name, path));
                }
            }
        }

        public async void query(string text) {
            if (current_cancellable != null) {
                current_cancellable.cancel();
            }
            current_cancellable = new Cancellable();
            search_started();

            var all_results = new List<SearchResult>();
            int pending = (int)providers.length();

            if (pending == 0) {
                results_updated(all_results);
                search_finished();
                return;
            }

            foreach (var provider in providers) {
                search_provider_async.begin(provider, text, current_cancellable, (obj, res) => {
                    var provider_results = search_provider_async.end(res);
                    if (provider_results != null) {
                        foreach (var r in provider_results) {
                            bool duplicate = false;
                            if (r.action_id != null) {
                                foreach (var existing in all_results) {
                                    if (existing.action_id == r.action_id) {
                                        duplicate = true;
                                        // Keep the one with higher score
                                        if (r.score > existing.score) {
                                            existing.score = r.score;
                                        }
                                        break;
                                    }
                                }
                            }

                            if (!duplicate) {
                                all_results.append(r);
                            }
                        }

                        all_results.sort((a, b) => {
                            if (a.score > b.score) return -1;
                            if (a.score < b.score) return 1;
                            return 0;
                        });
                        results_updated(all_results);
                    }

                    pending--;
                    if (pending == 0) search_finished();
                });
            }
        }

        private async List<SearchResult>? search_provider_async(SearchProvider provider, string query, Cancellable cancellable) {
            try {
                return yield provider.search(query, cancellable);
            } catch (Error e) {
                if (!(e is IOError.CANCELLED)) {
                    warning("Search provider %s error: %s", provider.name, e.message);
                }
                return null;
            }
        }
    }

    public class ScriptSearchProvider : GLib.Object, SearchProvider {
        private string _id;
        private string _name;
        public string id { get { return _id; } }
        public string name { get { return _name; } }
        private string script_path;

        public ScriptSearchProvider(string name, string path) {
            this._id = name;
            this._name = name;
            this.script_path = path;
        }

        public async List<SearchResult> search(string query, Cancellable? cancellable) throws Error {
            var results = new List<SearchResult>();

            try {
                var launcher = new Subprocess(
                    SubprocessFlags.STDOUT_PIPE,
                    script_path, query
                );

                string stdout_data;
                yield launcher.communicate_utf8_async(null, cancellable, out stdout_data, null);
                if (stdout_data == null || stdout_data.strip().length == 0) return results;

                var parser = new Json.Parser();
                parser.load_from_data(stdout_data);
                var root_node = parser.get_root();
                if (root_node == null || root_node.get_node_type() != Json.NodeType.ARRAY) return results;

                var array = root_node.get_array();
                for (int i = 0; i < array.get_length(); i++) {
                    var obj = array.get_object_element(i);
                    var res = new SearchResult(
                        this,
                        obj.get_string_member("title"),
                        obj.has_member("description") ? obj.get_string_member("description") : null,
                        obj.has_member("icon") ? obj.get_string_member("icon") : null,
                        null,
                        obj.has_member("action") ? obj.get_string_member("action") : null
                    );

                    if (obj.has_member("score")) res.score = obj.get_double_member("score");

                    string? action = res.action_id;
                    if (action != null && action.has_prefix("cmd:")) {
                        res.activated.connect(() => {
                            try { Process.spawn_command_line_async(action.substring(4)); } catch (Error e) {}
                        });
                    }

                    results.append(res);
                }
            } catch (Error e) {
                if (!(e is IOError.CANCELLED)) {
                    warning("Script %s returned invalid JSON or failed: %s", name, e.message);
                }
            }

            return results;
        }
    }
}
