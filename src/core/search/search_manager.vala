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
            if (desktop_settings.settings_schema.has_key("search-provider-overrides")) {
                desktop_settings.changed["search-provider-overrides"].connect(reload_remote_providers);
                desktop_settings.get_value("search-provider-overrides");
            }
            AppSystem.get_default().apps_changed.connect(schedule_remote_reload);
            load_remote_providers();
        }

        private GLib.Settings desktop_settings = new GLib.Settings("dev.sinty.desktop");
        private List<RemoteSearchProvider> remote_providers = new List<RemoteSearchProvider>();
        private uint _remote_reload = 0;

        public RemoteSearchProviderInfo[] get_remote_provider_infos() {
            return RemoteSearchProviderInfo.load_all();
        }

        public bool is_remote_provider_enabled(RemoteSearchProviderInfo info) {
            if (!desktop_settings.settings_schema.has_key("search-provider-overrides"))
                return !info.default_disabled;
            var iter = desktop_settings.get_value("search-provider-overrides").iterator();
            string id;
            bool enabled;
            while (iter.next("{sb}", out id, out enabled)) {
                if (id == info.id) return enabled;
            }
            return !info.default_disabled;
        }

        public void set_remote_provider_enabled(string id, bool enabled) {
            if (!desktop_settings.settings_schema.has_key("search-provider-overrides")) return;
            var builder = new VariantBuilder(new VariantType("a{sb}"));
            var iter = desktop_settings.get_value("search-provider-overrides").iterator();
            string key;
            bool value;
            while (iter.next("{sb}", out key, out value)) {
                if (key != id) builder.add("{sb}", key, value);
            }
            builder.add("{sb}", id, enabled);
            desktop_settings.set_value("search-provider-overrides", builder.end());
        }

        private void load_remote_providers() {
            foreach (var info in RemoteSearchProviderInfo.load_all()) {
                if (!is_remote_provider_enabled(info)) continue;
                var provider = new RemoteSearchProvider(info);
                remote_providers.append(provider);
                providers.append(provider);
            }
        }

        private void schedule_remote_reload() {
            if (_remote_reload != 0) return;
            _remote_reload = Timeout.add(500, () => {
                _remote_reload = 0;
                reload_remote_providers();
                return Source.REMOVE;
            });
        }

        private void reload_remote_providers() {
            foreach (var provider in remote_providers) providers.remove(provider);
            remote_providers = new List<RemoteSearchProvider>();
            load_remote_providers();
        }

        private static List<SearchResult> group_by_provider(List<SearchResult> sorted) {
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
            var cancellable = current_cancellable;
            search_started();

            var all_results = new List<SearchResult>();
            var round = new SearchRound((int)providers.length());

            if (round.finished) {
                results_updated(all_results);
                search_finished();
                return;
            }

            foreach (var provider in providers) {
                search_provider_async.begin(provider, text, cancellable, (obj, res) => {
                    var provider_results = search_provider_async.end(res);
                    if (cancellable.is_cancelled()) return;
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
                        all_results = group_by_provider(all_results);
                    }

                    if (round.provider_done(provider_results != null))
                        results_updated(all_results);
                    if (round.finished) search_finished();
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
