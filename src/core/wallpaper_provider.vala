using GLib;
using Gee;

namespace Singularity {
    public class WallpaperProviderResult : Object {
        public ArrayList<WallpaperItem> items = new ArrayList<WallpaperItem>();
        public int page_count = 1;
        public bool stale = false;
        public string warning = "";
    }

    public interface WallpaperProvider : Object {
        public abstract string id { get; }
        public abstract string display_name { owned get; }
        public abstract bool requires_credentials { get; }
        public abstract bool supports_search { get; }
        public abstract async ArrayList<WallpaperOcsChoice> choices(string category_index,
            Cancellable? cancel) throws Error;
        public abstract async WallpaperProviderResult browse(string choice_id, string query,
            int page, bool force_refresh, Cancellable? cancel) throws Error;
        public abstract async string import_item(WallpaperItem item, Cancellable? cancel) throws Error;
    }

    public abstract class WallpaperHelperProvider : Object {
        protected string helper;

        protected WallpaperHelperProvider(string helper) {
            this.helper = helper;
        }

        protected async string command(string[] argv, Cancellable? cancel, uint timeout,
            bool force_refresh = false, string? input = null) throws Error {
            var launcher = new SubprocessLauncher(SubprocessFlags.STDIN_PIPE |
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            if (force_refresh) launcher.setenv("NCZ_WALLPAPER_REFRESH", "1", true);
            launcher.set_child_setup(() => { Posix.setsid(); });
            var process = launcher.spawnv(argv);
            bool timed_out = false;
            uint timer = Timeout.add_seconds(timeout, () => {
                timed_out = true;
                stop_helper(process);
                return Source.REMOVE;
            });
            ulong cancel_handler = 0;
            if (cancel != null) {
                cancel_handler = cancel.cancelled.connect(() => stop_helper(process));
                if (cancel.is_cancelled()) stop_helper(process);
            }
            string output;
            string errors;
            try {
                yield process.communicate_utf8_async(input, null, out output, out errors);
            } catch (Error e) {
                stop_helper(process);
                yield process.wait_async(null);
                throw e;
            } finally {
                if (!timed_out) Source.remove(timer);
                if (cancel_handler != 0) cancel.disconnect(cancel_handler);
            }
            if (cancel != null) cancel.set_error_if_cancelled();
            if (timed_out) throw new IOError.TIMED_OUT("Wallpaper request timed out. Try again.");
            if (!process.get_successful()) {
                string detail = errors.strip();
                if (detail.length > 300) detail = detail.substring(0, 300).make_valid();
                throw new IOError.FAILED(detail != "" ? detail : "Wallpaper helper failed.");
            }
            return output;
        }

        private static void stop_helper(Subprocess process) {
            if (process.get_if_exited()) return;
            string? identifier = process.get_identifier();
            int pid = 0;
            if (identifier != null && int.try_parse(identifier, out pid) && pid > 1)
                Posix.kill((Posix.pid_t) (-pid), Posix.Signal.KILL);
            process.force_exit();
        }
    }

    public class OcsWallpaperProvider : WallpaperHelperProvider, WallpaperProvider {
        // OCS answers `pagesize` items per request and its own default is 10,
        // not the ~50 the aggregate crawl was written against. A single
        // 10-item page per category is a fraction of what a category holds
        // (pling 300 reports totalitems=1971), so the crawl was returning
        // roughly 400 wallpapers where the browser's crawl safety cap was
        // meant to be the binding limit. Ask for the server's maximum page
        // size: still ONE request per category, so the request
        // count and the per-category timeout budget are unchanged. The
        // server rejects anything above 100 with statuscode 400, and the
        // helper clamps to that.
        //
        // REQUIRES a helper that understands --page-size (cix-installer
        // "fix(wallpaper): let OCS browse ask for a real page size"). An
        // older /usr/local/bin/ncz-wallpaper-ocs exits with an argparse
        // "unrecognized arguments" error, which surfaces per category in the
        // browser's status line -- loudly, not as a silent short result. The
        // two ship together from one image build (cix-installer
        // post-install/45-wallpaper-rotator.sh installs the helper), so keep
        // them in step rather than feature-probing on every category.
        private const string OCS_PAGE_SIZE = "100";
        public string id { get { return "ocs"; } }
        public string display_name { owned get { return "OCS Network"; } }
        public bool requires_credentials { get { return false; } }
        public bool supports_search { get { return false; } }
        public OcsWallpaperProvider() { base("/usr/local/bin/ncz-wallpaper-ocs"); }
        public async ArrayList<WallpaperOcsChoice> choices(string index, Cancellable? cancel) throws Error {
            return WallpaperOcs.categories(index, id);
        }
        public async WallpaperProviderResult browse(string category, string query, int page,
                bool refresh, Cancellable? cancel) throws Error {
            string[] identity = category.split(":");
            if (identity.length != 2 || !WallpaperOcs.provider_id(identity[0]) ||
                !WallpaperOcs.numeric_id(identity[1]))
                throw new WallpaperOcsError.INVALID("Invalid aggregate OCS category identity");
            string network = identity[0];
            string network_category = identity[1];
            string data = yield command({helper, "browse", network, network_category,
                "--pages", "1", "--page-size", OCS_PAGE_SIZE}, cancel, 60, refresh);
            var result = new WallpaperProviderResult();
            result.items = WallpaperOcs.items(data, network, network_category);
            var response = WallpaperOcs.document(data);
            var failed = response.get_member("failed_networks");
            if (failed != null && failed.get_node_type() == Json.NodeType.ARRAY && failed.get_array().get_length() > 0)
                result.warning = "Some OCS networks could not be reached.";
            var stale = response.get_member("stale");
            result.stale = stale != null && stale.get_value_type() == typeof(bool) && stale.get_boolean();
            if (result.stale) result.warning = "Using cached OCS results after refresh failure.";
            return result;
        }
        public async string import_item(WallpaperItem item, Cancellable? cancel) throws Error {
            return yield command({helper, "import", item.provider_id, item.id}, cancel, 600);
        }
    }

    public class BingWallpaperProvider : WallpaperHelperProvider, WallpaperProvider {
        // Set by choices() from the helper's own answer, never re-derived
        // from the config file -- see WallpaperBing.CONSOLIDATED_ID. False
        // until the first choices() call, so the name starts as plain "Bing"
        // and the browser refreshes the label once the helper has replied.
        private bool combined = false;
        public string id { get { return WallpaperBing.PROVIDER_ID; } }
        // Matches the collection label the cix-installer rotator writes for
        // the same de-duplicated view ("Bing (Combined, All Markets)"), so
        // the online browser and the wallpaper theme picker name one thing
        // one way.
        public string display_name {
            owned get { return combined ? "Bing (Combined, All Markets)" : "Bing"; }
        }
        public bool requires_credentials { get { return false; } }
        public bool supports_search { get { return false; } }
        public BingWallpaperProvider() { base("/usr/local/bin/ncz-wallpaper-bing"); }
        public async ArrayList<WallpaperOcsChoice> choices(string index, Cancellable? cancel) throws Error {
            var loaded = WallpaperBing.markets(yield command({helper, "markets"}, cancel, 30));
            // The helper is SUPPOSED to always advertise the combined view
            // now (it always fetches every market; see configured_markets()
            // in 45-wallpaper-rotator.sh), so this should unconditionally be
            // the ONLY browsing axis -- per-market browsing is no longer
            // reachable through the picker, because the picker no longer
            // restricts which markets are fetched at all. What the picker
            // sets today (the Bing Preferred Region SelectionRow in
            // desktop_page.vala) is a PREFERRED region for dedup
            // tie-breaking, not a fetch filter, so it should have no
            // bearing on what choices() returns here.
            var only = WallpaperBing.combined_view(loaded);
            combined = only != null;
            // "Should" above is load-bearing: this is only true once the
            // deployed ncz-wallpaper-bing binary matches the 2026-09-13
            // contract change (see the CONSOLIDATED_ID comment in
            // wallpaper_ocs.vala). A helper that predates that change still
            // gates the combined view on the bing-markets file literally
            // holding "all", and the Preferred Region picker now routinely
            // writes a single specific market code -- so combined coming
            // back false here on a host where every market was expected is
            // the signature of that version skew, not a bug in this file.
            // Surface it instead of silently returning a narrowed per-
            // market list that looks like "Bing is broken".
            if (!combined) {
                warning("wallpaper_provider: ncz-wallpaper-bing did not advertise the consolidated view " +
                    "(got %d raw market choices) -- if the bing-markets file does not hold \"all\", this " +
                    "usually means the deployed helper predates the 2026-09-13 always-combine contract " +
                    "change; see CONSOLIDATED_ID in wallpaper_ocs.vala", loaded.size);
            }
            return only ?? loaded;
        }
        public async WallpaperProviderResult browse(string market, string query, int page,
                bool refresh, Cancellable? cancel) throws Error {
            var result = new WallpaperProviderResult();
            string selector = market == WallpaperBing.CONSOLIDATED_ID ? "--consolidated" : market;
            result.items = WallpaperBing.items(yield command({helper, "list", selector}, cancel, 60, refresh));
            return result;
        }
        public async string import_item(WallpaperItem item, Cancellable? cancel) throws Error {
            throw new IOError.NOT_SUPPORTED("Bing wallpapers are already installed locally.");
        }
    }

    public class StockWallpaperProvider : WallpaperHelperProvider, WallpaperProvider {
        private string provider_id;
        public string id { get { return provider_id; } }
        public string display_name { owned get { return provider_id == "openverse" ? "Openverse" : "Unsplash"; } }
        public bool requires_credentials { get { return provider_id == "unsplash"; } }
        public bool supports_search { get { return true; } }
        public StockWallpaperProvider(string id, string helper_path) {
            base(helper_path);
            provider_id = id;
        }
        public async ArrayList<WallpaperOcsChoice> choices(string index, Cancellable? cancel) throws Error {
            return new ArrayList<WallpaperOcsChoice>();
        }
        public async WallpaperProviderResult browse(string choice, string query, int page,
                bool refresh, Cancellable? cancel) throws Error {
            string[] argv = {helper, "search", query, "--page", page.to_string()};
            if (refresh) argv += "--refresh";
            string data = yield command(argv, cancel, 90);
            var response = WallpaperOcs.document(data);
            var result = new WallpaperProviderResult();
            result.items = WallpaperOpenverse.items(data, provider_id);
            var pages = response.get_member("page_count");
            if (pages == null || pages.get_value_type() != typeof(int64))
                throw new WallpaperOcsError.INVALID("Invalid stock photo page count");
            result.page_count = (int) pages.get_int();
            var stale = response.get_member("stale");
            result.stale = stale != null && stale.get_value_type() == typeof(bool) && stale.get_boolean();
            return result;
        }
        public async string import_item(WallpaperItem item, Cancellable? cancel) throws Error {
            return yield command({helper, "import", item.id}, cancel, 600);
        }
    }

    public class WallpaperProviderRegistry : Object {
        // Release registration policy. Re-enable a provider by adding its id here.
        public const string[] ACTIVE_PROVIDER_IDS = { "ocs", "bing" };
        private ArrayList<WallpaperProvider> active = new ArrayList<WallpaperProvider>();
        private ArrayList<WallpaperProvider> available = new ArrayList<WallpaperProvider>();

        public WallpaperProviderRegistry() {
            available.add(new OcsWallpaperProvider());
            available.add(new BingWallpaperProvider());
            available.add(new StockWallpaperProvider("openverse", "/usr/local/bin/ncz-wallpaper-openverse"));
            available.add(new StockWallpaperProvider("unsplash", "/usr/local/bin/ncz-wallpaper-unsplash"));
            foreach (string id in ACTIVE_PROVIDER_IDS) {
                var provider = find_available(id);
                if (provider != null) active.add(provider);
            }
        }
        public Gee.List<WallpaperProvider> get_active() { return active; }
        public Gee.List<WallpaperProvider> get_available() { return available; }
        public WallpaperProvider? lookup(string id) {
            foreach (var provider in active) if (provider.id == id) return provider;
            return null;
        }
        private WallpaperProvider? find_available(string id) {
            foreach (var provider in available) if (provider.id == id) return provider;
            return null;
        }
    }
}
