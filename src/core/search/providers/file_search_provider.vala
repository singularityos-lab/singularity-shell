using GLib;
using Tracker;
using Gee;

namespace Singularity {

    public class FileSearchProvider : GLib.Object, SearchProvider {
        public string id { get { return "files"; } }
        public string name { get { return "Files"; } }
        private Sparql.Connection connection = null;

        public FileSearchProvider() {
            Object();
            init_tracker.begin();
        }

        private async void init_tracker() {
            try {
                connection = yield Sparql.Connection.bus_new_async(
                    "org.freedesktop.Tracker3.Miner.Files",
                    null, null
                );
            } catch (Error e) {
                warning("Failed to connect to Tracker: %s. File search might be disabled.", e.message);
            }
        }

        public async GLib.List<SearchResult> search(string query, Cancellable? cancellable) throws Error {
            var results = new GLib.List<SearchResult>();
            if (connection == null || query.length < 3) return results;

            string sparql = """
                SELECT DISTINCT ?file ?name ?modified
                WHERE {
                    ?file a nfo:FileDataObject ;
                          nfo:fileName ?name ;
                          nfo:fileLastModified ?modified .
                    FILTER (fn:contains(fn:lower-case(?name), fn:lower-case('%s')))
                }
                ORDER BY DESC(?modified)
                LIMIT 15
            """.printf(query.replace("'", "\\'"));

            try {
                var cursor = yield connection.query_async(sparql, cancellable);
                var seen_uris = new HashSet<string>();

                while (yield cursor.next_async(cancellable)) {
                    string uri = cursor.get_string(0);
                    if (seen_uris.contains(uri)) continue;
                    seen_uris.add(uri);

                    string filename = cursor.get_string(1);

                    var file = File.new_for_uri(uri);
                    try {
                        var info = yield file.query_info_async(
                            FileAttribute.STANDARD_ICON + "," + FileAttribute.STANDARD_CONTENT_TYPE,
                            FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable
                        );

                        var home = GLib.Environment.get_home_dir();
                        string clean_path = file.get_path() ?? uri;
                        if (clean_path.has_prefix(home)) {
                            clean_path = "~" + clean_path.substring(home.length);
                        }

                        var res = new SearchResult(
                            this,
                            filename,
                            clean_path,
                            null,
                            info.get_icon(),
                            uri
                        );
                        res.score = 50.0;
                        res.mime_type = info.get_content_type();

                        res.activated.connect(() => {
                            Singularity.Widgets.FileOpener.open(File.new_for_uri(uri), null);
                        });

                        results.append(res);
                    } catch (Error e) {
                        // Skip files that cannot be queried
                    }
                }
            } catch (Error e) {
                if (!(e is IOError.CANCELLED)) {
                    warning("Tracker query error: %s", e.message);
                }
            }

            return results;
        }
    }
}
