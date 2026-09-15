using GLib;
using Gee;

namespace Singularity {
    // One cached browse result. `item` is the wallpaper exactly as the crawl
    // merged it; `category` is the choice id it was crawled from. The browser
    // deliberately keeps that category in a side map rather than on
    // WallpaperItem (see card_matches()), so it travels alongside the item
    // here instead of inside it.
    public class WallpaperBrowseCacheEntry : Object {
        public WallpaperItem item;
        public string category;
        public WallpaperBrowseCacheEntry(WallpaperItem item, string category = "") {
            this.item = item;
            this.category = category;
        }
    }

    // On-disk cache of one category's browse crawl, one file per
    // provider+category.
    //
    // The browser crawls a single, user-picked category at a time and
    // caches that category's result on its own (see
    // WallpaperOcsBrowserPage.browse_category()) -- it no longer pulls
    // every category into one aggregate before the user has chosen
    // anything. The cache key is therefore PROVIDER + CATEGORY: picking a
    // different category is a different crawl, and the only client-side
    // filter left (free text) is applied within one category's cached
    // list. Providers that search server-side (Openverse, Unsplash) are
    // query- and page-addressed, are not part of this crawl, and already
    // have their own helper-side caching, so they are not cached here.
    // A provider whose dropdown collapses to a single choice (Bing's
    // combined view) is cached under that one category id, same as any
    // other category.
    //
    // The file is written by this shell and read back by it, but it is still
    // parsed defensively: a truncated write, a half-full disk or a hand-edited
    // file must degrade to "no cache" and a fresh crawl, never to a crash or a
    // half-populated grid.
    public class WallpaperBrowseCache : Object {
        public const int SCHEMA = 1;
        // Six hours. OCS listings accrete slowly (new uploads trickle in over
        // days) and the Bing archive gains at most one image per market per
        // day, so a full re-crawl on every page open buys almost nothing. Six
        // hours keeps the several page opens in a working session instant
        // while still picking up a day's new uploads a few times a day, and
        // bounds how long a same-day Bing image can be missing. Refresh
        // bypasses it entirely whenever the user wants fresher results now.
        public const int64 TTL_SECONDS = 6 * 3600;
        // A crawl in which some categories failed is still worth reusing for a
        // page open a minute later, but must not pin a degraded snapshot for
        // six hours while the failing network recovers.
        public const int64 PARTIAL_TTL_SECONDS = 30 * 60;

        public string provider = "";
        public int64 created = 0;
        // True when at least one category of the crawl failed, so the merged
        // list is known to be missing wallpapers it would otherwise hold.
        public bool partial = false;
        public ArrayList<WallpaperBrowseCacheEntry> entries = new ArrayList<WallpaperBrowseCacheEntry>();

        public static int64 now() { return new DateTime.now_utc().to_unix(); }

        // Provider ids come from WallpaperProviderRegistry, but they are used
        // to build a filename, so they are checked rather than trusted.
        public static bool valid_provider(string provider) {
            if (provider == "" || provider.length > 32) return false;
            foreach (char c in provider.to_utf8())
                if (!(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-') return false;
            return true;
        }

        // Category ids come from the same OCS/Bing helper responses that
        // feed the category dropdown, not from the user directly, but they
        // also become part of a filename -- checked the same way as
        // valid_provider(), with underscores allowed since real OCS
        // category slugs use them.
        public static bool valid_category(string category) {
            if (category == "" || category.length > 64) return false;
            foreach (char c in category.to_utf8())
                if (!(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') &&
                    !(c >= '0' && c <= '9') && c != '-' && c != '_') return false;
            return true;
        }

        // XDG cache, namespaced under "singularity" the same way the shell's
        // config and data live under get_user_config_dir()/"singularity" and
        // get_user_data_dir()/"singularity". This is per-user browse state, not
        // the system-wide image archives the helpers own in
        // /var/cache/ncz-wallpapers.
        public static string directory() {
            return Path.build_filename(Environment.get_user_cache_dir(), "singularity", "wallpaper-browse");
        }

        // `category` is optional (defaults to "") to keep this callable the
        // same way it always was; passing one namespaces the cache file
        // under provider+category instead of provider alone -- see the
        // class comment above for why a crawl is scoped that way now.
        public static string path_for(string provider, string category = "") {
            string name = category != "" ? provider + "_" + category : provider;
            return Path.build_filename(directory(), name + ".json");
        }

        public bool fresh(int64 at) {
            // A cache stamped in the future is a clock change, not a fresh
            // crawl; treat it as stale so the worst case is one extra crawl.
            if (created > at) return false;
            return at - created < (partial ? PARTIAL_TTL_SECONDS : TTL_SECONDS);
        }

        public int64 age(int64 at) { return at > created ? at - created : 0; }

        public static string serialize(string provider, Gee.List<WallpaperBrowseCacheEntry> entries,
                bool partial, int64 created) {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("schema"); builder.add_int_value(SCHEMA);
            builder.set_member_name("provider"); builder.add_string_value(provider);
            builder.set_member_name("created"); builder.add_int_value(created);
            builder.set_member_name("partial"); builder.add_boolean_value(partial);
            builder.set_member_name("items");
            builder.begin_array();
            foreach (var entry in entries) {
                var item = entry.item;
                builder.begin_object();
                builder.set_member_name("provider"); builder.add_string_value(item.provider_id);
                builder.set_member_name("id"); builder.add_string_value(item.id);
                builder.set_member_name("category"); builder.add_string_value(entry.category);
                builder.set_member_name("name"); builder.add_string_value(item.name);
                builder.set_member_name("author"); builder.add_string_value(item.author);
                builder.set_member_name("license"); builder.add_string_value(item.license);
                builder.set_member_name("preview"); builder.add_string_value(item.preview);
                builder.set_member_name("url"); builder.add_string_value(item.full_res_url);
                builder.set_member_name("attribution"); builder.add_string_value(item.attribution);
                builder.set_member_name("page_url"); builder.add_string_value(item.page_url);
                builder.set_member_name("creator_url"); builder.add_string_value(item.creator_url);
                builder.set_member_name("license_url"); builder.add_string_value(item.license_url);
                builder.set_member_name("width"); builder.add_int_value(item.width);
                builder.set_member_name("height"); builder.add_int_value(item.height);
                builder.set_member_name("thumbnail_path"); builder.add_string_value(item.thumbnail_path);
                builder.set_member_name("market"); builder.add_string_value(item.market);
                builder.set_member_name("date"); builder.add_string_value(item.archive_date);
                builder.set_member_name("image_id"); builder.add_string_value(item.bing_image_id);
                builder.set_member_name("pinned"); builder.add_boolean_value(item.pinned);
                builder.set_member_name("tags");
                builder.begin_array();
                foreach (string tag in item.tags) builder.add_string_value(tag);
                builder.end_array();
                builder.end_object();
            }
            builder.end_array();
            builder.end_object();
            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            return generator.to_data(null);
        }

        private static int64 timestamp(Json.Object obj, string field) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.get_value_type() != typeof(int64) || node.get_int() < 0)
                throw new WallpaperOcsError.INVALID("Invalid cached browse field: " + field);
            return node.get_int();
        }

        private static bool flag(Json.Object obj, string field, bool required) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.is_null()) {
                if (!required) return false;
                throw new WallpaperOcsError.INVALID("Missing cached browse field: " + field);
            }
            if (node.get_value_type() != typeof(bool))
                throw new WallpaperOcsError.INVALID("Invalid cached browse field: " + field);
            return node.get_boolean();
        }

        // Reuses the OCS document/field guards so a malformed cache is
        // rejected by the same type checks that protect helper responses.
        public static WallpaperBrowseCache parse(string data, string provider) throws Error {
            var obj = WallpaperOcs.document(data);
            if (WallpaperOcs.text(obj, "provider") != provider)
                throw new WallpaperOcsError.INVALID("Cached browse result belongs to another provider");
            var cache = new WallpaperBrowseCache();
            cache.provider = provider;
            cache.created = timestamp(obj, "created");
            cache.partial = flag(obj, "partial", true);
            var seen = new HashSet<string>();
            foreach (var node in WallpaperOcs.array(obj, "items").get_elements()) {
                var record = WallpaperOcs.object_node(node);
                var item = new WallpaperItem();
                item.provider_id = WallpaperOcs.text(record, "provider");
                item.id = WallpaperOcs.text(record, "id");
                item.name = WallpaperOcs.text(record, "name", false);
                item.author = WallpaperOcs.text(record, "author", false);
                item.license = WallpaperOcs.text(record, "license", false);
                item.preview = WallpaperOcs.text(record, "preview", false);
                item.full_res_url = WallpaperOcs.text(record, "url", false);
                item.attribution = WallpaperOcs.text(record, "attribution", false);
                item.page_url = WallpaperOcs.text(record, "page_url", false);
                item.creator_url = WallpaperOcs.text(record, "creator_url", false);
                item.license_url = WallpaperOcs.text(record, "license_url", false);
                item.width = WallpaperOcs.optional_int(record, "width");
                item.height = WallpaperOcs.optional_int(record, "height");
                item.thumbnail_path = WallpaperOcs.text(record, "thumbnail_path", false);
                item.market = WallpaperOcs.text(record, "market", false);
                item.archive_date = WallpaperOcs.text(record, "date", false);
                item.bing_image_id = WallpaperOcs.text(record, "image_id", false);
                item.pinned = flag(record, "pinned", false);
                item.tags = WallpaperOcs.tag_array(record, "tags");
                if (seen.add(item.key))
                    cache.entries.add(new WallpaperBrowseCacheEntry(item,
                        WallpaperOcs.text(record, "category", false)));
            }
            return cache;
        }

        // Null means "crawl": no file, an unreadable or malformed file, or a
        // file older than its TTL. None of those are conditions the user needs
        // to see -- the crawl that follows is the normal path.
        public static WallpaperBrowseCache? read(string path, string provider, int64 at) {
            if (!valid_provider(provider)) return null;
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return null;
            try {
                string data;
                FileUtils.get_contents(path, out data);
                var cache = parse(data, provider);
                return cache.fresh(at) ? cache : null;
            } catch (Error e) {
                // Logged, not raised, and deliberately not a warning: the
                // caller crawls and the next crawl overwrites the bad file, so
                // this is a self-healing condition rather than a fault. (It
                // also keeps the GLib.Test harness, which makes warnings
                // fatal, able to exercise the corrupt-cache path.)
                message("Discarding unreadable wallpaper browse cache %s: %s", path, e.message);
                return null;
            }
        }

        // Best effort: a cache that cannot be written must never break
        // browsing, so failures are logged and reported through the return
        // value rather than raised at the call site.
        public static bool write(string path, string provider, Gee.List<WallpaperBrowseCacheEntry> entries,
                bool partial, int64 created) {
            if (!valid_provider(provider)) return false;
            string dir = Path.get_dirname(path);
            if (DirUtils.create_with_parents(dir, 0700) != 0) {
                warning("Could not create wallpaper browse cache directory %s", dir);
                return false;
            }
            try {
                FileUtils.set_contents(path, serialize(provider, entries, partial, created));
                return true;
            } catch (Error e) {
                warning("Could not write wallpaper browse cache %s: %s", path, e.message);
                return false;
            }
        }

        public static WallpaperBrowseCache? load(string provider, string category, int64 at) {
            if (!valid_provider(provider) || !valid_category(category)) return null;
            return read(path_for(provider, category), provider, at);
        }

        public static bool save(string provider, string category, Gee.List<WallpaperBrowseCacheEntry> entries,
                bool partial, int64 created) {
            if (!valid_provider(provider) || !valid_category(category)) return false;
            return write(path_for(provider, category), provider, entries, partial, created);
        }
    }
}
