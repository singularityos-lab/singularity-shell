using GLib;
using Gee;

namespace Singularity {

    public class ArtistPackInfo : GLib.Object {
        public string package { get; private set; }
        public string title { get; private set; }
        public string summary { get; private set; }
        public string version { get; private set; }
        public string source { get; private set; }
        public bool installed { get; set; }

        public ArtistPackInfo(string package, string title, string summary,
                               string version, string source, bool installed) {
            this.package = package;
            this.title = title;
            this.summary = summary;
            this.version = version;
            this.source = source;
            this.installed = installed;
        }
    }

    public errordomain ArtistPackError {
        BACKEND_MISSING,
        BACKEND_FAILED,
        INVALID_RESPONSE,
    }

    public class ArtistPackManager : GLib.Object {
        private const string PK_NAME = "org.freedesktop.PackageKit";
        private const string PK_PATH = "/org/freedesktop/PackageKit";
        private const string PK_TX = "org.freedesktop.PackageKit.Transaction";
        private const string PK_SERVICE_FILE = "/usr/share/dbus-1/system-services/org.freedesktop.PackageKit.service";
        private const uint64 FILTER_NOT_INSTALLED = 1 << 3;
        private const uint64 FLAG_ONLY_TRUSTED = 1 << 1;
        private const uint EXIT_SUCCESS = 1;

        private static ArtistPackManager? _instance = null;

        public string lists_dir { get; construct; }
        public string status_file { get; construct; }
        public string[] sources { get; construct; }

        public static ArtistPackManager get_default() {
            if (_instance == null) {
                string[] configured = {};
                var schema = SettingsSchemaSource.get_default() != null
                    ? SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true) : null;
                if (schema != null && schema.has_key("artist-pack-apt-sources")) {
                    configured = new GLib.Settings("dev.sinty.desktop").get_strv("artist-pack-apt-sources");
                }
                _instance = new ArtistPackManager("/var/lib/apt/lists", "/var/lib/dpkg/status", configured);
            }
            return _instance;
        }

        public ArtistPackManager(string lists_dir, string status_file, string[] sources) {
            GLib.Object(lists_dir: lists_dir, status_file: status_file, sources: sources);
        }

        public bool is_available() {
            return sources.length > 0
                && FileUtils.test(lists_dir, FileTest.IS_DIR)
                && FileUtils.test(status_file, FileTest.IS_REGULAR)
                && FileUtils.test(PK_SERVICE_FILE, FileTest.IS_REGULAR);
        }

        public static string list_prefix(string uri) {
            string rest = uri;
            int scheme = rest.index_of("://");
            if (scheme >= 0) rest = rest.substring(scheme + 3);
            int at = rest.index_of("@");
            int slash = rest.index_of("/");
            if (at >= 0 && (slash < 0 || at < slash)) rest = rest.substring(at + 1);
            var quoted = new StringBuilder();
            for (int i = 0; i < rest.length; i++) {
                char c = rest[i];
                if (c <= 0x20 || c >= 0x7f || "\\|{}[]<>\"^~_=!@#$%&*".index_of_char(c) >= 0) {
                    quoted.append_printf("%%%02x", (uint8) c);
                } else if (c == '/') {
                    quoted.append_c('_');
                } else {
                    quoted.append_c(c);
                }
            }
            return quoted.str;
        }

        private delegate void StanzaFunc(Gee.HashMap<string, string> fields);

        private static void each_stanza(string path, StanzaFunc func) {
            string contents;
            try {
                if (!FileUtils.get_contents(path, out contents)) return;
            } catch (FileError e) {
                return;
            }
            var fields = new Gee.HashMap<string, string>();
            foreach (unowned string line in contents.split("\n")) {
                if (line.strip() == "") {
                    if (fields.size > 0) func(fields);
                    fields = new Gee.HashMap<string, string>();
                    continue;
                }
                if (line[0] == ' ' || line[0] == '\t') continue;
                int colon = line.index_of(":");
                if (colon <= 0) continue;
                fields[line.substring(0, colon)] = line.substring(colon + 1).strip();
            }
            if (fields.size > 0) func(fields);
        }

        private Gee.HashSet<string> installed_packages() {
            var result = new Gee.HashSet<string>();
            each_stanza(status_file, (fields) => {
                if (fields.has_key("Package") && fields["Status"] == "install ok installed") result.add(fields["Package"]);
            });
            return result;
        }

        private Gee.ArrayList<string> index_files(string uri, string suite) {
            var files = new Gee.ArrayList<string>();
            string base_uri = uri.has_suffix("/") ? uri : uri + "/";
            string prefix = suite.has_suffix("/")
                ? list_prefix(base_uri + suite)
                : list_prefix(base_uri + "dists/" + suite + "/");
            try {
                var dir = Dir.open(lists_dir);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_prefix(prefix) && name.has_suffix("_Packages")) files.add(Path.build_filename(lists_dir, name));
                }
            } catch (FileError e) {
            }
            files.sort();
            return files;
        }

        public Gee.ArrayList<ArtistPackInfo> read_inventory() {
            var results = new Gee.ArrayList<ArtistPackInfo>();
            var installed = installed_packages();
            var seen = new Gee.HashSet<string>();
            foreach (string line in sources) {
                string[] parts = Regex.split_simple("\\s+", line.strip());
                if (parts.length < 3 || parts[0] != "deb") continue;
                int at = 1;
                if (parts[at].has_prefix("[")) {
                    while (at < parts.length && !parts[at].has_suffix("]")) at++;
                    at++;
                }
                if (at + 1 >= parts.length) continue;
                string uri = parts[at];
                string suite = parts[at + 1];
                foreach (string file in index_files(uri, suite)) {
                    each_stanza(file, (fields) => {
                        if (!fields.has_key("Package")) return;
                        string package = fields["Package"];
                        if (!seen.add(package)) return;
                        string summary = fields.has_key("Description") ? fields["Description"]
                            : fields.has_key("Description-en") ? fields["Description-en"] : "";
                        results.add(new ArtistPackInfo(package, package, summary,
                            fields.has_key("Version") ? fields["Version"] : "", uri, installed.contains(package)));
                    });
                }
            }
            return results;
        }

        public async Gee.ArrayList<ArtistPackInfo> fetch_inventory_async(Cancellable? cancellable = null) throws Error {
            return read_inventory();
        }

        private async Gee.ArrayList<string> transaction(DBusConnection bus, string method, Variant parameters,
                                                        Cancellable? cancellable) throws Error {
            var reply = yield bus.call(PK_NAME, PK_PATH, PK_NAME, "CreateTransaction", null,
                new VariantType("(o)"), DBusCallFlags.NONE, 10000, cancellable);
            string path = reply.get_child_value(0).get_string();
            var ids = new Gee.ArrayList<string>();
            string? failure = null;
            uint exit_code = 0;
            bool finished = false;
            bool waiting = false;
            SourceFunc resume = transaction.callback;
            uint sub = bus.signal_subscribe(PK_NAME, PK_TX, null, path, null, DBusSignalFlags.NONE,
                (conn, sender, object_path, iface, signal_name, args) => {
                    switch (signal_name) {
                        case "Package":
                            ids.add(args.get_child_value(1).get_string());
                            break;
                        case "ErrorCode":
                            failure = args.get_child_value(1).get_string();
                            break;
                        case "Finished":
                            exit_code = args.get_child_value(0).get_uint32();
                            finished = true;
                            if (waiting) {
                                waiting = false;
                                Idle.add((owned) resume);
                            }
                            break;
                    }
                });
            try {
                yield bus.call(PK_NAME, path, PK_TX, method, parameters, null,
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, cancellable);
                if (!finished) {
                    waiting = true;
                    yield;
                }
            } finally {
                bus.signal_unsubscribe(sub);
            }
            if (exit_code != EXIT_SUCCESS) {
                throw new ArtistPackError.BACKEND_FAILED(failure ?? "PackageKit could not finish %s".printf(method));
            }
            return ids;
        }

        public async void install_async(string package, string source, Cancellable? cancellable = null) throws Error {
            if (!Regex.match_simple("^[a-z0-9][a-z0-9.+-]*$", package)) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: not a valid package name".printf(package));
            }
            ArtistPackInfo? wanted = null;
            foreach (var info in read_inventory()) {
                if (info.package == package && info.source == source) wanted = info;
            }
            if (wanted == null) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: it is not published by %s".printf(package, source));
            }
            var bus = yield Bus.get(BusType.SYSTEM, cancellable);
            var found = yield transaction(bus, "Resolve",
                new Variant.tuple({ new Variant.uint64(FILTER_NOT_INSTALLED), new Variant.strv({ package }) }), cancellable);
            string? id = null;
            foreach (string candidate in found) {
                string[] fields = candidate.split(";");
                if (fields.length >= 2 && fields[0] == package && fields[1] == wanted.version) id = candidate;
            }
            if (id == null) {
                throw new ArtistPackError.BACKEND_FAILED(
                    "%s %s from %s is not the version the package manager offers".printf(package, wanted.version, source));
            }
            yield transaction(bus, "InstallPackages",
                new Variant.tuple({ new Variant.uint64(FLAG_ONLY_TRUSTED), new Variant.strv({ id }) }), cancellable);
            wanted.installed = true;
        }
    }
}
