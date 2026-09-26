using GLib;
using Gee;

namespace Singularity {

    // Selects rotation timing and images; WallpaperManager applies the signal.
    public class WallpaperRotator : Object {
        private static WallpaperRotator? _instance = null;
        private const int FAVORITE_WEIGHT = 3;
        private const double ASPECT_TOLERANCE = 0.15;

        public signal void wallpaper_selected(string uri);

        public string? current_uri { get; set; default = null; }

        public int armed_interval_seconds { get; private set; default = 0; }

        private WallpaperRotationState state;
        private string[] collection_roots;
        private string config_dir;
        private uint tick_id = 0;
        private uint restart_id = 0;
        private FileMonitor? state_monitor = null;
        private GLib.Settings? selection_settings = null;
        private WallpaperFavorites? favorites = null;
        private int test_min_width = 1280;
        private int test_min_height = 720;
        private bool test_match_aspect = false;
        private bool test_favor_favorites = true;
        public double target_aspect_ratio { get; set; default = 0.0; }

        public static WallpaperRotator get_default() {
            if (_instance == null) {
                _instance = new WallpaperRotator(
                    WallpaperRotationState.default_config_dir(),
                    WallpaperCollections.default_search_roots());
                _instance.selection_settings = new GLib.Settings("dev.sinty.desktop");
                _instance.favorites = new WallpaperFavorites(_instance.selection_settings);
            }
            return _instance;
        }

        public WallpaperRotator(string config_dir, string[] collection_roots) {
            this.config_dir = config_dir;
            this.collection_roots = collection_roots;
            this.state = new WallpaperRotationState(config_dir);
        }

        public void configure_selection(int min_width, int min_height,
                                        bool match_aspect, bool favor_favorites,
                                        double target_aspect = 0.0,
                                        WallpaperFavorites? favorites = null) {
            test_min_width = min_width;
            test_min_height = min_height;
            test_match_aspect = match_aspect;
            test_favor_favorites = favor_favorites;
            target_aspect_ratio = target_aspect;
            this.favorites = favorites;
        }

        public void start() {
            watch_state_dir();
            reschedule();
        }

        public void stop() {
            cancel_tick();
            if (restart_id != 0) {
                Source.remove(restart_id);
                restart_id = 0;
            }
            if (state_monitor != null) {
                // The signal handler retains this object until the monitor is cancelled.
                state_monitor.cancel();
                state_monitor = null;
            }
        }

        private void cancel_tick() {
            if (tick_id != 0) {
                Source.remove(tick_id);
                tick_id = 0;
            }
            armed_interval_seconds = 0;
        }

        public void reschedule() {
            cancel_tick();
            if (!state.get_rotate_enabled()) return;
            int interval = state.get_rotate_interval_seconds();
            armed_interval_seconds = interval;
            tick_id = Timeout.add_seconds(interval, () => {
                tick_id = 0;
                armed_interval_seconds = 0;
                // Another process may disable rotation after this timer is armed.
                if (state.get_rotate_enabled()) rotate_async();
                reschedule();
                return Source.REMOVE;
            });
        }

        // Keep collection scanning off the compositor's main loop.
        public void rotate_async() {
            // Snapshot before entering the worker to avoid a concurrent property read.
            string? current = current_uri;
            new Thread<void>("wallpaper-rotate", () => {
                string? uri = choose_next_for(current);
                if (uri == null) return;
                Idle.add(() => {
                    current_uri = uri;
                    wallpaper_selected(uri);
                    return Source.REMOVE;
                });
            });
        }

        public void rotate_now() {
            string? uri = choose_next();
            if (uri == null) return;
            current_uri = uri;
            wallpaper_selected(uri);
        }

        public string? choose_next() {
            return choose_next_for(current_uri);
        }

        public string? choose_next_for(string? current) {
            var collections = WallpaperCollections.parse(collection_roots);
            if (collections.size == 0) return null;

            string selected_id = state.get_selected_collection("");
            string? scan_dir = null;
            foreach (var collection in collections) {
                if (collection.id == selected_id) { scan_dir = collection.dir; break; }
            }
            // Do not let the background timer rewrite a stale user selection.
            if (scan_dir == null) scan_dir = collections[0].dir;

            var all_dirs = new ArrayList<string>();
            foreach (var collection in collections) all_dirs.add(collection.dir);

            // Recency is gallery presentation state, not rotation weighting.
            var candidates = WallpaperGallery.scan(scan_dir, all_dirs.to_array(), {});
            if (candidates.size == 0) return null;

            int min_width = setting_int("wallpaper-rotation-min-width", test_min_width);
            int min_height = setting_int("wallpaper-rotation-min-height", test_min_height);
            bool match_aspect = setting_bool("wallpaper-rotation-match-aspect", test_match_aspect);
            bool favor_favorites = setting_bool("wallpaper-rotation-favor-favorites", test_favor_favorites);
            var regarded = regard(candidates, min_width, min_height,
                                  match_aspect, target_aspect_ratio);
            return pick_candidates(regarded, current, Random.next_int(),
                                   favor_favorites, favorites);
        }

        private int setting_int(string key, int fallback) {
            if (selection_settings == null || !selection_settings.settings_schema.has_key(key)) return fallback;
            return selection_settings.get_int(key);
        }

        private bool setting_bool(string key, bool fallback) {
            if (selection_settings == null || !selection_settings.settings_schema.has_key(key)) return fallback;
            return selection_settings.get_boolean(key);
        }

        internal static ArrayList<WallpaperCandidate> regard(
                Gee.List<WallpaperCandidate> candidates, int min_width, int min_height,
                bool match_aspect, double target_aspect) {
            var sized = new ArrayList<WallpaperCandidate>();
            foreach (var candidate in candidates) {
                if (candidate.width >= min_width && candidate.height >= min_height)
                    sized.add(candidate);
            }
            if (sized.size == 0 && candidates.size > 0) {
                debug("wallpaper rotator: minimum resolution excluded every candidate; using unfiltered collection");
                foreach (var candidate in candidates) sized.add(candidate);
            }
            if (!match_aspect || target_aspect <= 0.0) return sized;

            var matched = new ArrayList<WallpaperCandidate>();
            foreach (var candidate in sized) {
                if (candidate.width <= 0 || candidate.height <= 0) continue;
                double aspect = (double) candidate.width / (double) candidate.height;
                if (Math.fabs(aspect - target_aspect) / target_aspect <= ASPECT_TOLERANCE)
                    matched.add(candidate);
            }
            if (matched.size == 0) {
                debug("wallpaper rotator: aspect preference matched no candidates; using resolution-filtered collection");
                return sized;
            }
            return matched;
        }

        internal static string? pick_candidates(Gee.List<WallpaperCandidate> candidates,
                                                string? current_uri, uint32 roll,
                                                bool favor_favorites,
                                                WallpaperFavorites? favorites) {
            var choices = new ArrayList<WallpaperCandidate>();
            foreach (var candidate in candidates) {
                if (candidates.size == 1 || candidate.uri != current_uri) choices.add(candidate);
            }
            if (choices.size == 0) return candidates.size > 0 ? candidates[0].uri : null;

            int total_weight = 0;
            foreach (var candidate in choices) {
                string? path = File.new_for_uri(candidate.uri).get_path();
                bool favorite = favor_favorites && favorites != null && path != null
                    && favorites.is_favorite(path);
                total_weight += favorite ? FAVORITE_WEIGHT : 1;
            }
            int selected = (int) (roll % total_weight);
            foreach (var candidate in choices) {
                string? path = File.new_for_uri(candidate.uri).get_path();
                bool favorite = favor_favorites && favorites != null && path != null
                    && favorites.is_favorite(path);
                int weight = favorite ? FAVORITE_WEIGHT : 1;
                if (selected < weight) return candidate.uri;
                selected -= weight;
            }
            return choices[0].uri;
        }

        public static string? pick(Gee.List<string> uris, string? current_uri, uint32 roll) {
            if (uris.size == 0) return null;
            if (uris.size == 1) return uris[0];

            var choices = new ArrayList<string>();
            foreach (string uri in uris) {
                if (uri != current_uri) choices.add(uri);
            }
            // A collection may contain duplicate URIs for the current image.
            if (choices.size == 0) return uris[0];
            return choices[(int) (roll % choices.size)];
        }

        // State may be written outside the settings page, so watch the directory.
        private void watch_state_dir() {
            if (state_monitor != null) return;
            DirUtils.create_with_parents(config_dir, 0700);
            try {
                var dir = File.new_for_path(config_dir);
                state_monitor = dir.monitor_directory(FileMonitorFlags.NONE, null);
            } catch (Error e) {
                // The timer still re-reads state if monitoring is unavailable.
                warning("wallpaper rotator: cannot watch %s: %s", config_dir, e.message);
                return;
            }
            state_monitor.changed.connect((file, other, event) => {
                // Atomic replacement emits multiple events; coalesce them.
                if (restart_id != 0) return;
                restart_id = Timeout.add(250, () => {
                    restart_id = 0;
                    reschedule();
                    return Source.REMOVE;
                });
            });
        }
    }
}
