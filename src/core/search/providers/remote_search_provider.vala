using GLib;

namespace Singularity {

    public class RemoteSearchProviderInfo : Object {
        public string id;
        public string desktop_id;
        public string bus_name;
        public string object_path;
        public bool default_disabled;
        public string name;
        public GLib.Icon? app_icon;

        public static RemoteSearchProviderInfo? load(string path) {
            const string GROUP = "Search Provider";
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
                if (!kf.has_group(GROUP)) return null;
                int version = kf.has_key(GROUP, "Version") ? kf.get_integer(GROUP, "Version") : 1;
                if (version != 1) {
                    warning("Search provider %s: unsupported version %d", path, version);
                    return null;
                }
                var info = new RemoteSearchProviderInfo();
                info.desktop_id = kf.get_string(GROUP, "DesktopId");
                info.bus_name = kf.get_string(GROUP, "BusName");
                info.object_path = kf.get_string(GROUP, "ObjectPath");
                info.default_disabled = kf.has_key(GROUP, "DefaultDisabled")
                    && kf.get_boolean(GROUP, "DefaultDisabled");
                string base_name = Path.get_basename(path);
                info.id = base_name.substring(0, base_name.last_index_of("."));
                if (!Variant.is_object_path(info.object_path) || !GLib.DBus.is_name(info.bus_name)) {
                    warning("Search provider %s: invalid bus name or object path", path);
                    return null;
                }
                var app = AppSystem.get_default().get_app_info(info.desktop_id);
                if (app == null) {
                    debug("Search provider %s: app %s is not installed", path, info.desktop_id);
                    return null;
                }
                info.name = app.get_display_name();
                info.app_icon = app.get_icon();
                return info;
            } catch (Error e) {
                warning("Search provider %s: %s", path, e.message);
                return null;
            }
        }

        public static RemoteSearchProviderInfo[] load_all() {
            RemoteSearchProviderInfo[] all = {};
            foreach (string path in Runtime.find_data_files("singularity/search-providers", ".ini")) {
                var info = load(path);
                if (info != null) all += info;
            }
            return all;
        }
    }

    public class RemoteSearchProvider : GLib.Object, SearchProvider {
        private const string IFACE = "dev.sinty.SearchProvider1";
        private const int QUERY_TIMEOUT_MS = 2500;
        private const int MAX_RESULTS = 5;

        public RemoteSearchProviderInfo info { get; construct; }
        public string id { get { return info.id; } }
        public string name { get { return info.name; } }

        private string[] _previous_terms = {};
        private string[] _previous_ids = {};

        public RemoteSearchProvider(RemoteSearchProviderInfo info) {
            Object(info: info);
        }

        public async List<SearchResult> search(string query, Cancellable? cancellable) throws Error {
            var results = new List<SearchResult>();
            string[] terms = split_terms(query);
            if (terms.length == 0) return results;

            var bus = yield GLib.Bus.get(BusType.SESSION, cancellable);
            Variant reply;
            if (_previous_ids.length > 0 && refines(terms)) {
                reply = yield bus.call(info.bus_name, info.object_path, IFACE, "GetSubsearchResultSet",
                    new Variant.tuple({ new Variant.strv(_previous_ids), new Variant.strv(terms) }), new VariantType("(as)"),
                    DBusCallFlags.NONE, QUERY_TIMEOUT_MS, cancellable);
            } else {
                reply = yield bus.call(info.bus_name, info.object_path, IFACE, "GetInitialResultSet",
                    new Variant.tuple({ new Variant.strv(terms) }), new VariantType("(as)"),
                    DBusCallFlags.NONE, QUERY_TIMEOUT_MS, cancellable);
            }
            string[] ids = reply.get_child_value(0).dup_strv();
            _previous_terms = terms;
            _previous_ids = ids;
            if (ids.length == 0) return results;

            string[] wanted = ids.length > MAX_RESULTS ? ids[0:MAX_RESULTS] : ids;
            var metas_reply = yield bus.call(info.bus_name, info.object_path, IFACE, "GetResultMetas",
                new Variant.tuple({ new Variant.strv(wanted) }), new VariantType("(aa{sv})"),
                DBusCallFlags.NONE, QUERY_TIMEOUT_MS, cancellable);
            var metas = metas_reply.get_child_value(0);
            for (int i = 0; i < (int) metas.n_children(); i++) {
                var result = build_result(metas.get_child_value(i), terms, i);
                if (result != null) results.append(result);
            }
            return results;
        }

        private bool refines(string[] terms) {
            if (terms.length < _previous_terms.length) return false;
            for (int i = 0; i < _previous_terms.length; i++) {
                if (!terms[i].has_prefix(_previous_terms[i])) return false;
            }
            return true;
        }

        private static string[] split_terms(string query) {
            string[] terms = {};
            foreach (string t in query.strip().split_set(" \t\n")) {
                if (t != "") terms += t;
            }
            return terms;
        }

        private SearchResult? build_result(Variant meta, string[] terms, int index) {
            var dict = new VariantDict(meta);
            string? result_id = null;
            string? title = null;
            if (!dict.lookup("id", "s", out result_id) || !dict.lookup("name", "s", out title)) return null;
            string? description = null;
            dict.lookup("description", "s", out description);

            GLib.Icon? icon = null;
            var icon_value = dict.lookup_value("icon", null);
            if (icon_value != null) icon = GLib.Icon.deserialize(icon_value);
            if (icon == null) icon = info.app_icon;

            var result = new RemoteSearchResult(this, result_id, title, description, icon, terms);
            double score;
            result.score = dict.lookup("score", "d", out score) ? score : 30.0 - index;
            bool keeps_open = false;
            if (dict.lookup("keeps-open", "b", out keeps_open)) result.keeps_open = keeps_open;
            result.preview = build_preview(dict);

            var actions = dict.lookup_value("actions", new VariantType("a(sss)"));
            if (actions != null) {
                for (int i = 0; i < (int) actions.n_children(); i++) {
                    string action_id, label, icon_name;
                    actions.get_child(i, "(sss)", out action_id, out label, out icon_name);
                    result.add_action(new RemoteSearchAction(this, result_id, action_id, label,
                        icon_name != "" ? icon_name : null, terms));
                }
            }
            return result;
        }

        private static SearchResultPreview? build_preview(VariantDict dict) {
            var preview = build_preview_kind(dict);
            bool large = false;
            if (preview != null && dict.lookup("preview-large", "b", out large)) preview.large = large;
            return preview;
        }

        private static SearchResultPreview? build_preview_kind(VariantDict dict) {
            string? color = null;
            if (dict.lookup("preview-color", "s", out color)) {
                var preview = SearchResultPreview.for_color(color);
                if (preview != null) return preview;
            }
            var icon_value = dict.lookup_value("preview-icon", null);
            if (icon_value != null) {
                var icon = GLib.Icon.deserialize(icon_value);
                if (icon != null) return SearchResultPreview.for_icon(icon);
            }
            string? image = null;
            if (dict.lookup("preview-image", "s", out image)) {
                var file = image.has_prefix("/") ? File.new_for_path(image) : File.new_for_uri(image);
                try {
                    return SearchResultPreview.for_paintable(Gdk.Texture.from_file(file));
                } catch (Error e) {
                    debug("Search preview %s: %s", image, e.message);
                }
            }
            string? text = null;
            if (dict.lookup("preview-text", "s", out text)) return SearchResultPreview.for_text(text);
            return null;
        }

        internal async void call_activation(string method, Variant parameters) {
            try {
                var bus = yield GLib.Bus.get(BusType.SESSION);
                var reply = yield bus.call(info.bus_name, info.object_path, IFACE, method, parameters,
                    new VariantType("(a{sv})"), DBusCallFlags.NONE, 10000, null);
                apply_reply(reply.get_child_value(0));
            } catch (Error e) {
                warning("Search provider %s: %s failed: %s", info.id, method, e.message);
            }
        }

        public void launch_search(owned string[] terms) {
            GLib.Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    var bus = GLib.Bus.get.end(res);
                    bus.call.begin(info.bus_name, info.object_path, IFACE, "LaunchSearch",
                        new Variant.tuple({ new Variant.strv(terms), new Variant.uint32(event_time()) }),
                        null, DBusCallFlags.NONE, 5000, null);
                } catch (Error e) {
                    warning("Search provider %s: LaunchSearch failed: %s", info.id, e.message);
                }
            });
        }

        internal static uint32 event_time() {
            return (uint32) (get_monotonic_time() / 1000);
        }

        private static void apply_reply(Variant reply) {
            var dict = new VariantDict(reply);
            string? text = null;
            if (!dict.lookup("copy-text", "s", out text)) return;
            bool sensitive;
            if (!dict.lookup("copy-sensitive", "b", out sensitive)) sensitive = false;
            uint32 clear_after;
            if (!dict.lookup("copy-clear-after", "u", out clear_after)) clear_after = 0;
            SearchClipboard.copy(text, sensitive, clear_after);
        }
    }

    public class RemoteSearchResult : SearchResult {
        private string _result_id;
        private string[] _terms;

        public RemoteSearchResult(RemoteSearchProvider provider, string result_id, string title,
                                  string? description, GLib.Icon? icon, string[] terms) {
            Object(provider: provider, title: title, description: description, gicon: icon);
            _result_id = result_id;
            _terms = terms;
        }

        public override void activate() {
            base.activate();
            var remote = (RemoteSearchProvider) provider;
            remote.call_activation.begin("ActivateResult",
                new Variant.tuple({ new Variant.string(_result_id), new Variant.strv(_terms),
                    new Variant.uint32(RemoteSearchProvider.event_time()) }));
        }
    }

    public class RemoteSearchAction : SearchAction {
        private RemoteSearchProvider _provider;
        private string _result_id;
        private string[] _terms;

        public RemoteSearchAction(RemoteSearchProvider provider, string result_id, string action_id,
                                  string label, string? icon_name, string[] terms) {
            Object(id: action_id, label: label, icon_name: icon_name);
            _provider = provider;
            _result_id = result_id;
            _terms = terms;
        }

        public override void activate() {
            base.activate();
            _provider.call_activation.begin("ActivateAction",
                new Variant.tuple({ new Variant.string(_result_id), new Variant.string(id),
                    new Variant.strv(_terms), new Variant.uint32(RemoteSearchProvider.event_time()) }));
        }
    }

    public class SearchClipboard : Object {
        public static void copy(string text, bool sensitive, uint clear_after) {
            var display = Gdk.Display.get_default();
            if (display == null) return;
            var clipboard = display.get_clipboard();
            Gdk.ContentProvider provider;
            if (sensitive) {
                provider = new Gdk.ContentProvider.union({
                    new Gdk.ContentProvider.for_value(text),
                    new Gdk.ContentProvider.for_bytes("x-kde-passwordManagerHint",
                        new Bytes("secret".data))
                });
            } else {
                provider = new Gdk.ContentProvider.for_value(text);
            }
            clipboard.set_content(provider);
            if (clear_after == 0) return;
            Timeout.add_seconds(clear_after, () => {
                if (clipboard.get_content() == provider) clipboard.set_content(null);
                return Source.REMOVE;
            });
        }
    }
}
