using GLib;
using Gee;
using Json;

namespace Singularity {

    /**
     * One curated Artist Pack, available or already installed, from one of
     * the apt sources configured in dev.sinty.desktop's
     * artist-pack-apt-sources.
     */
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

    /**
     * Browses and installs curated Artist Packs (ncz-wallpapers-* debs).
     *
     * Shells out to two distro-provided scripts at FIXED, root-owned
     * absolute paths, never resolved through PATH (see INSTALL_HELPER).
     * is_available() gates the complete contract (both helpers, pkexec, the
     * polkit action) so an inventory-only deployment never shows an Install
     * button that can't work.
     *
     * Which apt source(s) count as an Artist Pack source is the distro's
     * call, read by the inventory script from `artist-pack-apt-sources` -
     * this class never reads or filters on that value itself.
     *
     * install_async() passes the inventory step's `source` straight through
     * to the privileged helper rather than having the helper re-derive
     * trust by re-reading GSettings as root: a pkexec-elevated process
     * doesn't share the desktop user's dconf session, so the helper instead
     * re-validates the argv-supplied source against apt's own root-owned
     * configuration and the package's live candidate.
     */
    public class ArtistPackManager : GLib.Object {
        private static ArtistPackManager? _instance = null;

        /**
         * Fixed, absolute, root-owned helper paths - deliberately NOT
         * resolved via Environment.find_program_in_path(). INSTALL_HELPER
         * is handed to pkexec as the PROGRAM to run as root; a PATH lookup
         * would let anything earlier on the desktop process's PATH (e.g.
         * ~/.local/bin) shadow it and get elevated - a local privilege
         * escalation.
         */
        private const string INVENTORY_HELPER = "/usr/local/bin/singularity-artist-pack-inventory";
        private const string INSTALL_HELPER = "/usr/local/bin/singularity-artist-pack-install";
        private const string INSTALL_POLICY = "/usr/share/polkit-1/actions/dev.sinty.desktop.artist-pack-install.policy";

        public static ArtistPackManager get_default() {
            if (_instance == null) _instance = new ArtistPackManager();
            return _instance;
        }

        private ArtistPackManager() { }

        /** pkexec's own fixed locations - also resolved without PATH, same reason as INSTALL_HELPER. */
        private const string[] PKEXEC_PATHS = { "/usr/bin/pkexec", "/bin/pkexec" };

        /** True when `path` names an existing, executable regular file. */
        private static bool is_executable_file(string path) {
            return FileUtils.test(path, FileTest.IS_REGULAR)
                && FileUtils.test(path, FileTest.IS_EXECUTABLE);
        }

        private static string? find_pkexec() {
            foreach (unowned string candidate in PKEXEC_PATHS) {
                if (is_executable_file(candidate)) return candidate;
            }
            return null;
        }

        /** True only when the distro provides the complete backend contract. */
        public bool is_available() {
            return is_executable_file(INVENTORY_HELPER)
                && is_executable_file(INSTALL_HELPER)
                && FileUtils.test(INSTALL_POLICY, FileTest.IS_REGULAR)
                && find_pkexec() != null;
        }

        /**
         * Queries the configured apt source(s) for available Artist Packs.
         *
         * Returns an empty list (not an error) when the backend is absent,
         * so a caller that already checked is_available() doesn't need a
         * second error path. A real backend failure (non-zero exit, bad
         * JSON) still throws.
         */
        public async Gee.ArrayList<ArtistPackInfo> fetch_inventory_async(Cancellable? cancellable = null) throws Error {
            var results = new Gee.ArrayList<ArtistPackInfo>();
            if (!is_executable_file(INVENTORY_HELPER)) return results;

            var proc = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                                       INVENTORY_HELPER);
            string stdout_data;
            string stderr_data;
            yield proc.communicate_utf8_async(null, cancellable, out stdout_data, out stderr_data);
            if (!proc.get_successful()) {
                throw new ArtistPackError.BACKEND_FAILED(
                    "%s exited with an error: %s".printf(INVENTORY_HELPER, (stderr_data ?? "").strip()));
            }
            if (stdout_data == null || stdout_data.strip().length == 0) return results;

            var parser = new Json.Parser();
            try {
                parser.load_from_data(stdout_data);
            } catch (Error e) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "%s produced invalid JSON: %s".printf(INVENTORY_HELPER, e.message));
            }
            var root_node = parser.get_root();
            if (root_node == null || root_node.get_node_type() != Json.NodeType.ARRAY) {
                throw new ArtistPackError.INVALID_RESPONSE("%s did not return a JSON array".printf(INVENTORY_HELPER));
            }

            var array = root_node.get_array();
            for (uint i = 0; i < array.get_length(); i++) {
                var obj = array.get_object_element(i);
                if (obj == null || !obj.has_member("package")) continue;
                results.add(new ArtistPackInfo(
                    obj.get_string_member("package"),
                    obj.has_member("title") ? obj.get_string_member("title") : obj.get_string_member("package"),
                    obj.has_member("summary") ? obj.get_string_member("summary") : "",
                    obj.has_member("version") ? obj.get_string_member("version") : "",
                    obj.has_member("source") ? obj.get_string_member("source") : "",
                    obj.has_member("installed") && obj.get_boolean_member("installed")
                ));
            }
            return results;
        }

        /**
         * Installs one Artist Pack via pkexec + the distro's install helper.
         *
         * `source` must be the exact value fetch_inventory_async() reported
         * for this package - it's passed through as argv and independently
         * re-validated by the privileged helper, which does not trust it.
         * The package-name check here is defense in depth only; the helper
         * re-validates both name and source before touching apt regardless.
         */
        public async void install_async(string package, string source, Cancellable? cancellable = null) throws Error {
            if (!Regex.match_simple("^ncz-wallpapers-[a-z0-9][a-z0-9-]*$", package)) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: not an Artist Pack package name".printf(package));
            }
            if (source.strip().length == 0) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: no source URI given".printf(package));
            }
            if (!is_executable_file(INSTALL_HELPER)) {
                throw new ArtistPackError.BACKEND_MISSING("%s is not installed".printf(INSTALL_HELPER));
            }
            string? pkexec = find_pkexec();
            if (pkexec == null) {
                throw new ArtistPackError.BACKEND_MISSING("pkexec is not available");
            }

            var proc = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                                       pkexec, INSTALL_HELPER, package, source);
            string stdout_data;
            string stderr_data;
            yield proc.communicate_utf8_async(null, cancellable, out stdout_data, out stderr_data);
            if (!proc.get_successful()) {
                throw new ArtistPackError.BACKEND_FAILED(
                    "install of %s failed: %s".printf(package, (stderr_data ?? "").strip()));
            }
        }
    }
}
