using GLib;
using Gtk;
using Json;

namespace Singularity {

    public class SearchManager : GLib.Object {
        private static SearchManager? _instance = null;
        private List<SearchProvider> providers;
        private FileSearchProvider? file_provider = null;
        private SearchSession? legacy_session = null;
        private const uint REMOTE_DELAY_MS = 120;
        private const uint SCRIPT_DELAY_MS = 60;

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
            providers.append(new SettingsSearchProvider());
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

        public SearchSession start(string text) {
            var session = new SearchSession(text);
            session.start(providers, start_delay);
            return session;
        }

        private static uint start_delay(SearchProvider provider) {
            if (provider is RemoteSearchProvider) return REMOTE_DELAY_MS;
            if (provider is ScriptSearchProvider) return SCRIPT_DELAY_MS;
            return 0;
        }

        public async void query(string text) {
            if (legacy_session != null) legacy_session.cancel();
            var session = new SearchSession(text);
            legacy_session = session;
            search_started();
            session.results_updated.connect((results) => results_updated(results));
            session.finished.connect(() => search_finished());
            session.start(providers, start_delay);
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
