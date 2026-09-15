using Gtk;
using Gee;
using Singularity.Widgets;

namespace Singularity.Shell {
    // Presentation only: the installed helper owns all OCS and import policy.
    public class WallpaperOcsBrowserPage : SettingsPage {
        public signal void imported();
        private const string HELPER = "/usr/local/bin/ncz-wallpaper-ocs";
        // Bing lives behind its own helper because its commands and JSON
        // shapes are different (markets -> TSV, list -> bare array, no
        // schema/items wrapper). Calling it is the same SubprocessLauncher
        // shape as HELPER; only the argv and the parsers in WallpaperBing
        // differ. The helper's daily timer permanently accumulates unseen
        // images in bing.collection; browsing only reads that local archive.
        private const string BING_HELPER = "/usr/local/bin/ncz-wallpaper-bing";
        private const string OPENVERSE_HELPER = "/usr/local/bin/ncz-wallpaper-openverse";
        private const string UNSPLASH_HELPER = "/usr/local/bin/ncz-wallpaper-unsplash";
        private WallpaperProviderRegistry provider_registry = new WallpaperProviderRegistry();
        private ProviderCredentialGroup openverse_credentials;
        private ProviderCredentialGroup unsplash_credentials;
        private PreferencesGroup online_search_group;
        private EntryRow online_search;
        private Button previous_page;
        private Button next_page;
        private int photo_page = 1;
        private int photo_page_count = 1;
        private bool force_refresh = false;
        // The synthetic provider id used by the provider dropdown, the worker
        // branching, and the card layout. Same value as WallpaperBing.PROVIDER_ID
        // in core/ -- duplicated here so the browser can branch on it
        // without pulling in a core class field reference at the call site.
        private const string BING_PROVIDER_ID = "bing";
        // Bounded crawl: enough parallelism that a category with many pages
        // fills the grid quickly, but small enough it cannot fork dozens of
        // OCS processes against the helper at once. A crawl now covers a
        // single, user-picked category (see browse_category()), not every
        // category a provider exposes, so CRAWL_WORKERS is a ceiling on
        // in-flight requests for that one category rather than a fan-out
        // across many categories.
        private const int CRAWL_WORKERS = 4;
        // Safety cap on wallpapers merged for one category. A single OCS
        // category page tops out at the server's maximum 100 items/page (see
        // OcsWallpaperProvider); this cap guards against an unexpectedly
        // large category rather than truncating a normal one.
        private const int CRAWL_ITEM_CAP = 4000;
        private const int THUMBNAIL_FETCH_LANES = 8;
        // Building one WallpaperCard hierarchy (badge, action button, FlowBox
        // append) measured ~0.6ms/card on CIX Sky1 target hardware. Building
        // a full batch synchronously in load_cached()/revalidate_cached()
        // would block the main thread for its whole duration, so cards are
        // built in bounded batches one main-loop turn apart -- each batch
        // stays under a perceptible-freeze threshold and the grid visibly
        // fills in instead of the shell appearing to hang.
        private const int CARD_BUILD_BATCH_SIZE = 150;
        // One extra screenful keeps the next rows ready without decoding the
        // thousands of FlowBox children that have never approached view.
        private const int VIEWPORT_PREFETCH_MARGIN_PX = 400;
        // Keep several screenfuls behind/ahead as hysteresis so small scrolls
        // do not repeatedly discard and decode thumbnails at the load edge.
        private const int VIEWPORT_EVICT_MARGIN_PX = 1600;
        // Per-category subprocess timeout, matches the previous single-call
        // bound so a slow category can't drag a worker beyond the overall
        // window the user is willing to wait.
        private const int CRAWL_CATEGORY_TIMEOUT = 60;
        private string[] collection_roots;
        private WallpaperOcsImports imports = new WallpaperOcsImports();
        private ArrayList<WallpaperOcsChoice> providers = new ArrayList<WallpaperOcsChoice>();
        private ArrayList<WallpaperOcsChoice> categories = new ArrayList<WallpaperOcsChoice>();
        private ArrayList<OcsCard> cards = new ArrayList<OcsCard>();
        private HashSet<int> thumbnail_requested = new HashSet<int>();
        private HashSet<int> thumbnail_pending = new HashSet<int>();
        // Category is now the only filter axis (tag filtering removed), and
        // it drives WHAT gets loaded rather than filtering an already-loaded
        // aggregate -- see browse_category(). An empty id means "nothing
        // picked yet", not "show everything".
        private string active_category_id = "";
        private PreferencesGroup provider_group;
        private SelectionRow provider_row;
        private SelectionRow category_row;
        private EntryRow? search_row;
        private Button refresh;
        private Spinner spinner;
        private Label status;
        private FlowBox grid;
        private Soup.Session session = new Soup.Session();
        private WallpaperThumbnailCache thumbnail_cache = new WallpaperThumbnailCache();
        private Cancellable request = new Cancellable();
        private int generation = 0;
        private bool loading = false;
        private string category_index = "";

        private enum CacheLoadResult { NONE, FRESH, STALE }

        // One card per wallpapers item in the grid. The visible widget is
        // a WallpaperCard (reused from desktop_page.vala so the OCS/Bing
        // grid LOOKS identical to the main wallpaper picker). The action button
        // sits below the thumbnail; attribution and licence text use the card
        // badge. Status text
        // for long-running ops (Import / Pin) goes to the global status
        // label rather than a per-card inline message, since WallpaperCard
        // has no room for one.
        private class OcsCard : Object {
            public WallpaperItem item;
            public WallpaperCard card;
            public Button button;
            public bool matches = true;
        }

        // SettingsView caches pages and reuses this instance across every
        // visit (settings_view.vala: "Reuse cached pages - they self-update
        // via GSettings listeners"). imports.discover() only scans sidecars
        // that exist on disk AT THE TIME IT RUNS, so a one-time call in the
        // constructor goes stale the moment a collection is deleted+
        // re-imported from elsewhere (e.g. the Desktop settings page) while
        // this page sits cached: the in-memory "added" set still claims the
        // re-imported keys are present, so their cards render greyed out
        // ("Added", disabled) even though the files backing that claim are
        // long gone. Re-run discover() (and re-browse so the grid's cards are
        // rebuilt with fresh is_added() state baked into both their label and
        // sensitivity) every time this page becomes visible again, not just
        // once at construction.
        //
        // That re-browse is cache-aware: a crawl younger than
        // WallpaperBrowseCache.TTL_SECONDS repaints the grid from disk instead
        // of re-crawling the category over the network, which is what makes
        // a repeat visit instant. It deliberately does NOT set force_refresh:
        // returning to a page the user has already seen is not a request for
        // fresher data, it is a request to see the page again -- and, if a
        // category is already selected, a request to see it refreshed (see
        // browse_all()'s dispatch). The Refresh button is the explicit way
        // to bypass the cache.
        private bool mapped_once = false;

        public WallpaperOcsBrowserPage(SettingsView view, string[] roots) {
            base(_("Online Wallpapers"));
            collection_roots = roots;
            imports.discover(WallpaperCollections.parse(roots));
            session.timeout = 25;
            session.user_agent = "Singularity-Wallpaper-Browser/1";
            this.map.connect(() => {
                if (!mapped_once) { mapped_once = true; return; }
                imports.discover(WallpaperCollections.parse(collection_roots));
                browse_all.begin();
            });
            back_clicked.connect(() => view.navigate_to("desktop"));

            provider_group = new PreferencesGroup();
            provider_row = new SelectionRow.with_options(_("Online source"),
                new Gee.ArrayList<Singularity.Core.AppSettingOption>());
            provider_group.add_row(provider_row);
            add_group(provider_group);

            openverse_credentials = new ProviderCredentialGroup(_("Openverse account"), _("Your email address"), false,
                _("Optional per-user registration. Openverse sends a verification email; until verified, anonymous-tier limits apply. Credentials stay on this computer."));
            openverse_credentials.submitted.connect((value) => register_openverse.begin(value));
            add_group(openverse_credentials);
            unsplash_credentials = new ProviderCredentialGroup(_("Unsplash account"), _("Your Unsplash Access Key"), true,
                _("Optional personal key. Without one, Stock Photos still searches Openverse. The key stays on this computer."));
            unsplash_credentials.submitted.connect((value) => configure_unsplash.begin(value));
            add_group(unsplash_credentials);
            online_search_group = new PreferencesGroup();
            online_search = new EntryRow(_("Search Stock Photos"));
            online_search.text = "nature";
            // EntryRow has no built-in show_apply_button/apply pair; an
            // explicit suffix button plus Enter-to-search covers the same
            // interaction.
            var online_search_apply = new Button.from_icon_name("object-select-symbolic");
            online_search_apply.tooltip_text = _("Search");
            online_search_apply.valign = Align.CENTER;
            online_search_apply.add_css_class("flat");
            online_search_apply.clicked.connect(() => { photo_page = 1; browse_all.begin(); });
            online_search.add_suffix(online_search_apply);
            online_search.entry_activated.connect(() => { photo_page = 1; browse_all.begin(); });
            online_search_group.add_row(online_search);
            var pagination = new ActionRow(_("Search results"));
            previous_page = new Button.with_label(_("Previous"));
            next_page = new Button.with_label(_("Next"));
            previous_page.valign = next_page.valign = Align.CENTER;
            previous_page.clicked.connect(() => { photo_page--; browse_all.begin(); });
            next_page.clicked.connect(() => { photo_page++; browse_all.begin(); });
            pagination.add_suffix(previous_page);
            pagination.add_suffix(next_page);
            online_search_group.add_row(pagination);
            add_group(online_search_group);

            var search_group = new PreferencesGroup();
            search_row = new EntryRow(_("Filter loaded wallpapers"));
            search_row.entry_changed.connect(() => {
                if (!updating) filter_cards();
            });
            refresh = new Button.from_icon_name("view-refresh-symbolic");
            // force_refresh does two things: it bypasses the on-disk crawl
            // cache in browse_category(), and it sets NCZ_WALLPAPER_REFRESH
            // for the helper so its own cache is bypassed too. Refresh is
            // therefore the one path that is guaranteed to hit the network.
            refresh.tooltip_text = _("Refresh now (ignore cached results)");
            refresh.valign = Align.CENTER;
            refresh.clicked.connect(() => {
                force_refresh = true;
                browse_all.begin();
            });
            search_row.add_suffix(refresh);
            search_group.add_row(search_row);
            add_group(search_group);

            var category_group = new PreferencesGroup();
            category_row = new SelectionRow.with_options(_("Category"),
                new Gee.ArrayList<Singularity.Core.AppSettingOption>());
            category_group.add_row(category_row);
            add_group(category_group);

            var results_group = new PreferencesGroup();
            var progress_row = new PreferencesRow();
            progress_row.activatable = false;
            var progress = new Box(Orientation.HORIZONTAL, 8);
            progress.margin_start = progress.margin_end = 8;
            progress.margin_top = progress.margin_bottom = 6;
            spinner = new Spinner();
            spinner.valign = Align.CENTER;
            progress.append(spinner);
            status = new Label("");
            status.wrap = true;
            status.xalign = 0;
            status.hexpand = true;
            progress.append(status);
            progress_row.set_child(progress);
            results_group.add_row(progress_row);
            grid = new FlowBox();
            grid.add_css_class("wallpaper-gallery");
            grid.valign = Align.START;
            grid.halign = Align.FILL;
            grid.hexpand = true;
            grid.max_children_per_line = 2;
            grid.min_children_per_line = 2;
            grid.selection_mode = SelectionMode.NONE;
            // Let FlowBox remove non-matches from layout. Merely hiding the
            // card widget leaves its FlowBoxChild allocated and produces the
            // large empty slots seen with narrow filters such as "4K".
            grid.set_filter_func(filter_grid_child);
            grid.column_spacing = 14;
            grid.row_spacing = 14;
            grid.margin_top = grid.margin_bottom = 10;
            grid.margin_start = grid.margin_end = 10;
            scroller.vadjustment.value_changed.connect(queue_viewport_thumbnails);
            var grid_row = new PreferencesRow();
            grid_row.activatable = false;
            grid_row.set_child(grid);
            results_group.add_row(grid_row);
            add_group(results_group);

            provider_row.selected.connect((id) => {
                if (!updating) select_provider(id);
            });
            category_row.selected.connect((id) => {
                if (!updating) on_category_row_selected(id);
            });
            initialize.begin();
        }

        // SelectionRow's `selected` signal fires only from a user click on
        // an expanded option (set_options()/current_value assignment during
        // a programmatic rebuild never emit it), so this guard is stricter
        // than it needs to be today -- kept anyway, at zero behavioural
        // cost, as a belt-and-suspenders match for the previous
        // ComboRow-based code's guard against reacting to its own rebuilds.
        private bool updating = false;

        private void update_controls() {
            if (search_row != null) search_row.sensitive = !imports.busy;
            refresh.sensitive = !imports.busy && !loading;
            foreach (var card in cards)
                card.button.sensitive = !imports.busy && !imports.is_added(card.item.key);
            // Filter UI is filter UI, not destructive: a busy import does
            // not warrant disabling it, but a still-loading grid would
            // mean picking a category changes nothing visible yet, so the
            // category dropdown disables while loading.
            category_row.sensitive = !loading;
            previous_page.sensitive = !loading && !imports.busy && photo_page > 1;
            next_page.sensitive = !loading && !imports.busy && photo_page < photo_page_count;
            online_search.sensitive = !imports.busy && !loading;
            if (loading || imports.busy) spinner.start(); else spinner.stop();
        }

        private static void stop_helper(Subprocess process) {
            // Import invokes ImageMagick children. Stop the whole private process
            // group so a timeout cannot leave a writer running after Retry.
            string? identifier = process.get_identifier();
            int pid = 0;
            if (identifier != null && int.try_parse(identifier, out pid) && pid > 1)
                Posix.kill((Posix.pid_t) (-pid), Posix.Signal.KILL);
            process.force_exit();
        }

        private async string command(string[] argv, Cancellable? cancel, uint timeout, string? input = null) throws Error {
            var launcher = new SubprocessLauncher(SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
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
                // Drain and reap even after cancellation, then discard the result.
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
            if (timed_out) throw new IOError.TIMED_OUT(_("Wallpaper request timed out. Try again."));
            if (!process.get_successful()) {
                string detail = errors.strip();
                if (detail.length > 300) detail = detail.substring(0, 300).make_valid();
                throw new IOError.FAILED(detail != "" ? detail : _("Wallpaper helper failed."));
            }
            return output;
        }

        private async void initialize() {
            try {
                uint8[] contents;
                yield File.new_for_path("/usr/share/ncz-wallpapers/ocs-category-index.json").load_contents_async(null, out contents, null);
                category_index = (string) contents;
                WallpaperOcs.categories(category_index, "ocs");
            } catch (Error e) {
                category_index = "";
            }
            rebuild_provider_row("ocs");
            select_provider("ocs");
        }

        // A provider's display name is not always known at construction: Bing
        // only learns whether it is serving the de-duplicated combined view
        // once its helper has answered `markets`, and renames itself to
        // "Bing (Combined, All Markets)" when it is. So the row is rebuilt
        // from the registry's live names rather than snapshotted once, and
        // select_provider_choices() calls this again after a load.
        private void rebuild_provider_row(string current) {
            providers.clear();
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            foreach (var provider in provider_registry.get_active()) {
                providers.add(new WallpaperOcsChoice(provider.id, _(provider.display_name)));
                options.add(new Singularity.Core.AppSettingOption() {
                    id = provider.id, label = _(provider.display_name) });
            }
            updating = true;
            set_choices(provider_row, options, current);
            updating = false;
        }

        private async void credential_status() {
            try {
                string data = yield command({OPENVERSE_HELPER, "status"}, null, 15);
                var obj = WallpaperOcs.document(data, false);
                var registered = obj.get_member("registered");
                bool saved = registered != null && registered.get_value_type() == typeof(bool) && registered.get_boolean();
                openverse_credentials.set_state(saved ? _("Credentials saved. Verify your email using the Openverse link.")
                                            : _("Anonymous access is available without registration."), !saved);
            } catch (Error e) {
                openverse_credentials.set_state(e.message, true);
            }
            try {
                string data = yield command({UNSPLASH_HELPER, "status"}, null, 15);
                var obj = WallpaperOcs.document(data, false);
                var configured = obj.get_member("configured");
                bool saved = configured != null && configured.get_value_type() == typeof(bool) && configured.get_boolean();
                unsplash_credentials.set_state(saved ? _("Unsplash Access Key saved.")
                                                      : _("Add your Access Key to include Unsplash results."), !saved);
            } catch (Error e) {
                unsplash_credentials.set_state(_("Unsplash helper unavailable: %s").printf(e.message), true);
            }
        }

        private async void register_openverse(string email) {
            openverse_credentials.set_state(_("Registering with Openverse…"), false);
            try {
                string data = yield command({OPENVERSE_HELPER, "register"}, null, 90, email);
                var obj = WallpaperOcs.document(data, false);
                openverse_credentials.set_state(WallpaperOcs.text(obj, "message"), false);
            } catch (Error e) {
                openverse_credentials.set_state(e.message, true);
            }
        }

        private async void configure_unsplash(string key) {
            unsplash_credentials.set_state(_("Saving Unsplash Access Key…"), false);
            try {
                string data = yield command({UNSPLASH_HELPER, "configure"}, null, 30, key);
                var obj = WallpaperOcs.document(data, false);
                unsplash_credentials.set_state(WallpaperOcs.text(obj, "message"), false);
                photo_page = 1;
                browse_all.begin();
            } catch (Error e) {
                unsplash_credentials.set_state(e.message, true);
            }
        }

        private async void browse_stock(WallpaperProvider provider) {
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            loading = true;
            cards.clear();
            reset_thumbnail_loading();
            grid.remove_all();
            status.label = _("Searching Stock Photos…");
            update_controls();
            bool refresh_now = force_refresh;
            force_refresh = false;
            photo_page_count = 1;
            string result_status = "";
            try {
                var result = yield provider.browse("", online_search.text, photo_page, refresh_now, cancel);
                if (gen != generation) return;
                photo_page_count = result.page_count;
                foreach (var item in result.items) add_card(item);
                result_status = result.stale ? _("Showing cached %s results; refresh failed.").printf(provider.display_name)
                    : _("%s · page %d of %d · %d images").printf(provider.display_name, photo_page, photo_page_count, cards.size);
            } catch (Error e) {
                result_status = _("%s search failed: %s").printf(provider.display_name, e.message);
            }
            if (gen != generation) return;
            loading = false;
            filter_cards();
            status.label = result_status;
            queue_viewport_thumbnails();
            update_controls();
        }

        // Provider selected -> rebuild the category dropdown. Unlike the
        // previous aggregate-crawl behaviour, selecting a provider no longer
        // starts loading anything by itself: the category list is cheap
        // metadata, but the wallpapers inside a category are not, so the
        // grid stays empty until the user actually picks one (see
        // on_category_row_selected() / browse_category()). The one
        // exception is a provider whose dropdown collapses to a single
        // choice (Bing's de-duplicated combined view) -- there is nothing
        // to pick, so that one choice loads immediately, same as before.
        private void select_provider(string provider_id) {
            if (provider_id == "") return;
            force_refresh = false;
            var provider = provider_registry.lookup(provider_id);
            if (provider == null) return;
            bool photos = provider.supports_search;
            openverse_credentials.visible = provider_id == "openverse";
            unsplash_credentials.visible = provider_id == "unsplash";
            online_search_group.visible = photos;
            category_row.visible = !photos;
            active_category_id = "";
            if (photos) {
                photo_page = 1;
                categories.clear();
                if (provider.requires_credentials || provider_id == "openverse") credential_status.begin();
                browse_all.begin();
                return;
            }
            if (provider_id == BING_PROVIDER_ID) {
                select_provider_choices.begin(provider);
                return;
            }
            if (category_index == "") {
                generation++;
                request.cancel();
                cards.clear();
                reset_thumbnail_loading();
                grid.remove_all();
                loading = false;
                status.label = _("OCS category index is missing. Install the wallpaper helpers, then reopen this page.");
                update_controls();
                return;
            }
            select_provider_choices.begin(provider);
        }

        // Bing equivalent of the OCS provider/category-index load: one
        // synchronous `ncz-wallpaper-bing markets` call, TSV-parsed into the
        // same WallpaperOcsChoice list the category dropdown already knows how to
        // render. Errors are surfaced through `status` exactly like an OCS
        // category-index parse failure.
        private async void select_provider_choices(WallpaperProvider provider) {
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            loading = true;
            status.label = _("Loading %s choices…").printf(provider.display_name);
            update_controls();
            try {
                var loaded = yield provider.choices(category_index, cancel);
                if (gen != generation) return;
                // The provider may have renamed itself off the back of that
                // answer (Bing -> "Bing (Combined, All Markets)"), so the
                // "Online source" row is re-labelled before the grid fills.
                // Keeping the current selection is what makes this safe to do
                // mid-flight -- it rebuilds labels, never the selection.
                rebuild_provider_row(provider.id);
                categories = loaded;
                active_category_id = "";
                rebuild_category_row();
                cards.clear();
                reset_thumbnail_loading();
                grid.remove_all();
                loading = false;
                update_controls();
                if (!category_row.visible && categories.size == 1) {
                    // Nothing to pick (Bing's single combined choice, or any
                    // provider that happens to expose exactly one usable
                    // category) -- load it directly, same as before.
                    active_category_id = categories[0].id;
                    browse_category.begin(active_category_id);
                } else {
                    status.label = _("Select a category to browse.");
                }
            } catch (Error e) {
                if (gen != generation) return;
                loading = false;
                status.label = _("Could not load %s choices: %s").printf(provider.display_name, e.message);
                update_controls();
            }
        }

        private void rebuild_category_row() {
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            options.add(new Singularity.Core.AppSettingOption() { id = "", label = _("Select a category…") });
            foreach (var choice in categories) {
                options.add(new Singularity.Core.AppSettingOption() { id = choice.id, label = choice.name });
            }
            // A dropdown with one real choice offers nothing to pick. Bing's
            // de-duplicated combined view is a single choice by
            // construction and loads directly (see select_provider_choices).
            category_row.visible = categories.size > 1;
            bool was_updating = updating;
            updating = true;
            set_choices(category_row, options, active_category_id);
            updating = was_updating;
        }

        private void on_category_row_selected(string id) {
            active_category_id = id;
            if (id == "") {
                generation++;
                request.cancel();
                cards.clear();
                reset_thumbnail_loading();
                grid.remove_all();
                loading = false;
                status.label = _("Select a category to browse.");
                update_controls();
                return;
            }
            browse_category.begin(id);
        }

        // Top-level dispatcher: re-runs whichever view is currently active
        // (a stock-photo search, or the selected category), used by Refresh,
        // by re-entering the page (see the `map` handler in the
        // constructor), and by pagination. If nothing is selected yet there
        // is nothing to refresh, so this is a no-op -- the "load only when a
        // category is picked" behaviour lives in on_category_row_selected().
        private async void browse_all() {
            var selected_provider = provider_registry.lookup(provider_row.current_value);
            if (selected_provider != null && selected_provider.supports_search) {
                yield browse_stock(selected_provider);
                return;
            }
            if (provider_row.current_value == "") {
                loading = false;
                status.label = _("No usable wallpaper providers.");
                update_controls();
                return;
            }
            if (active_category_id == "") return;
            yield browse_category(active_category_id);
        }

        // Load (or refresh) exactly one category: the aggregate, load-every-
        // category-up-front crawl this used to run on every provider select
        // is gone. A crawl now touches only the category the user picked,
        // which is what keeps a provider with dozens of categories and
        // thousands of combined items from ever pulling more than one
        // category's worth of results at a time. Re-entering this method
        // for the SAME category (Refresh, or re-visiting the page) is the
        // "refresh the index" half of that -- it reuses the exact same
        // cache-then-revalidate-if-stale flow load_cached()/
        // revalidate_cached() already provided, just re-scoped from
        // "one file per provider" to "one file per provider+category" (see
        // WallpaperBrowseCache.path_for()).
        private async void browse_category(string category) {
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            if (provider_row.current_value == "") {
                loading = false;
                status.label = _("No usable wallpaper providers.");
                update_controls();
                return;
            }
            string provider = provider_row.current_value;
            var selected_provider = provider_registry.lookup(provider);
            var todo = new ArrayList<string>();
            todo.add(category);
            int total = 1;
            cards.clear();
            reset_thumbnail_loading();
            grid.remove_all();
            string category_name = category;
            foreach (var c in categories) if (c.id == category) { category_name = c.name; break; }
            // A crawl younger than its TTL is repainted from disk; the network
            // crawl below only runs when that cache is stale, absent, corrupt,
            // or explicitly bypassed by Refresh. The free-text filter is
            // applied client-side to this same loaded list, so a filter
            // change is a different VIEW, never a different crawl.
            if (!force_refresh) {
                var cache_result = yield load_cached(provider, category, gen, cancel);
                if (cache_result == CacheLoadResult.FRESH) return;
                if (cache_result == CacheLoadResult.STALE) {
                    revalidate_cached.begin(selected_provider, provider, category, todo, gen, cancel);
                    return;
                }
            }
            loading = true;
            status.label = _("Loading %s…").printf(category_name);
            update_controls();
            // Shared crawl state -- heap-allocated so the workers can read
            // it; counters + queue are protected by the mutexes inside it.
            var state = new CrawlState();
            state.generation = gen;
            state.provider = provider;
            state.backend = selected_provider;
            state.todo = todo;
            state.total = total;
            state.cancel = cancel;
            // Pool of workers. With a single category queued there is only
            // ever one unit of real work; the pool degrades to one active
            // worker automatically (the loop below still polls correctly).
            worker.begin(state);
            for (int i = 1; i < CRAWL_WORKERS && i < total; i++)
                worker.begin(state);
            // Poll completion at 100 ms intervals. A timeout must invoke the
            // async continuation; changing a flag cannot resume a bare yield.
            while (gen == generation && state.done_count < total && !cancel.is_cancelled()) {
                state.count_lock.lock();
                int snapshot;
                try { snapshot = state.item_count; } finally { state.count_lock.unlock(); }
                if (snapshot >= CRAWL_ITEM_CAP) {
                    // Workers check the same cap before adding cards or
                    // starting another category. Keep the request alive for
                    // thumbnails; closing/restarting still cancels both.
                    break;
                }
                SourceFunc resume = browse_category.callback;
                Timeout.add(100, () => {
                    if (resume != null) {
                        SourceFunc cb = (owned) resume;
                        resume = null;
                        cb();
                    }
                    return Source.REMOVE;
                });
                yield;
            }
            if (gen != generation) return;
            loading = false;
            force_refresh = false;
            filter_cards();
            if (state.errors.size > 0)
                status.label = _("%d wallpapers loaded · %s").printf(cards.size, string.joinv(" · ", state.errors.to_array()));
            update_controls();
            // Persist what the crawl actually merged, so the next visit can
            // skip it. A cancelled crawl is a partial view of the user's
            // intent, not a result, and is never written. A crawl that lost
            // categories to errors is written but marked partial, which gives
            // it a much shorter TTL than a clean one.
            if (!cancel.is_cancelled() && cards.size > 0)
                store_cache(provider, category, state.errors.size > 0);
            queue_viewport_thumbnails();
        }

        // Repaint from any valid on-disk snapshot. Freshness controls whether
        // browse_category() is finished or starts a silent background
        // revalidate; it never controls whether already persisted metadata
        // can be shown.
        private async CacheLoadResult load_cached(string provider, string category, int gen, Cancellable cancel) {
            int64 at = WallpaperBrowseCache.now();
            WallpaperBrowseCache? cached = null;
            string path = WallpaperBrowseCache.path_for(provider, category);
            if (FileUtils.test(path, FileTest.IS_REGULAR)) {
                try {
                    string data;
                    FileUtils.get_contents(path, out data);
                    cached = WallpaperBrowseCache.parse(data, provider);
                } catch (Error e) {
                    message("Discarding unreadable wallpaper browse cache %s: %s", path, e.message);
                }
            }
            if (cached == null || cached.entries.size == 0) return CacheLoadResult.NONE;
            yield populate_cards_batched(cached.entries, gen, cancel);
            // Superseded while this repaint was still batching in (provider
            // switch, Refresh): that newer call owns the page now, and
            // touching status/controls here would fight it.
            if (gen != generation || cancel.is_cancelled()) return CacheLoadResult.FRESH;
            loading = false;
            filter_cards();
            // filter_cards() has just written the shown/loaded counts; append
            // the provenance so a cached grid never silently poses as a fresh
            // crawl, and name the way out of it.
            status.label = _("%d wallpapers · %s · Refresh for new uploads").printf(
                cards.size, cache_age(cached.age(at)));
            update_controls();
            queue_viewport_thumbnails();
            return cached.fresh(at) ? CacheLoadResult.FRESH : CacheLoadResult.STALE;
        }

        // Build one WallpaperCard per entry in bounded batches, yielding to
        // the main loop between batches so a large category (see
        // CARD_BUILD_BATCH_SIZE) cannot hold the compositor unresponsive for
        // seconds at a time. Thumbnails are queued after every batch too, so
        // the initially visible rows start decoding as soon as they exist
        // instead of waiting for the whole list to finish building.
        private async void populate_cards_batched(ArrayList<WallpaperBrowseCacheEntry> entries,
                int gen, Cancellable cancel) {
            int processed = 0;
            foreach (var entry in entries) {
                if (gen != generation || cancel.is_cancelled()) return;
                add_card(entry.item);
                if (++processed % CARD_BUILD_BATCH_SIZE != 0) continue;
                queue_viewport_thumbnails();
                SourceFunc resume = populate_cards_batched.callback;
                Idle.add(() => {
                    if (resume != null) {
                        SourceFunc cb = (owned) resume;
                        resume = null;
                        cb();
                    }
                    return Source.REMOVE;
                });
                yield;
            }
        }

        // Crawl into a detached metadata list while the stale card hierarchy
        // remains mounted. Rebuilding the live grid happens synchronously in
        // one main-loop turn, so GTK cannot paint an empty intermediate view.
        private async void revalidate_cached(WallpaperProvider backend, string provider, string category,
                ArrayList<string> todo, int gen, Cancellable cancel) {
            if (todo.size == 0) return;
            var state = new CrawlState();
            state.background = true;
            state.generation = gen;
            state.provider = provider;
            state.backend = backend;
            state.todo = todo;
            state.total = todo.size;
            state.cancel = cancel;
            worker.begin(state);
            for (int i = 1; i < CRAWL_WORKERS && i < state.total; i++) worker.begin(state);
            while (gen == generation && state.done_count < state.total && !cancel.is_cancelled()) {
                SourceFunc resume = revalidate_cached.callback;
                Timeout.add(100, () => {
                    if (resume != null) {
                        SourceFunc cb = (owned) resume;
                        resume = null;
                        cb();
                    }
                    return Source.REMOVE;
                });
                yield;
            }
            if (gen != generation || cancel.is_cancelled()) return;
            if (state.results.size == 0) {
                warning("Background wallpaper cache revalidation for %s/%s produced no usable results", provider, category);
                return;
            }
            WallpaperBrowseCache.save(provider, category, state.results,
                state.errors.size > 0, WallpaperBrowseCache.now());
            cards.clear();
            reset_thumbnail_loading();
            grid.remove_all();
            // The first batch lands in this same synchronous continuation
            // (populate_cards_batched only yields after CARD_BUILD_BATCH_SIZE
            // cards), so the grid goes straight from the stale list to real
            // new content with no empty frame in between; only the remaining
            // batches spread across further main-loop turns.
            yield populate_cards_batched(state.results, gen, cancel);
            if (gen != generation || cancel.is_cancelled()) return;
            filter_cards();
            if (state.errors.size > 0)
                status.label = _("%d wallpapers loaded · %s").printf(
                    cards.size, string.joinv(" · ", state.errors.to_array()));
            update_controls();
            queue_viewport_thumbnails();
        }

        private void store_cache(string provider, string category, bool partial) {
            var snapshot = new ArrayList<WallpaperBrowseCacheEntry>();
            foreach (var card in cards)
                snapshot.add(new WallpaperBrowseCacheEntry(card.item, category));
            WallpaperBrowseCache.save(provider, category, snapshot, partial, WallpaperBrowseCache.now());
        }

        private static string cache_age(int64 seconds) {
            if (seconds < 120) return _("loaded just now");
            if (seconds < 7200) return _("loaded %d minutes ago").printf((int) (seconds / 60));
            return _("loaded %d hours ago").printf((int) (seconds / 3600));
        }

        // Shared, heap-allocated crawl state. Vala forbids ref/out parameters
        // on async methods, so the worker pool pulls counters and the
        // pending-queue through this object instead of by reference.
        // Multiple workers may touch it concurrently; the two mutexes in
        // CrawlState serialise the queue pull and the counters.
        private class CrawlState : Object {
            public ArrayList<string> errors = new ArrayList<string>();
            public ArrayList<WallpaperBrowseCacheEntry> results = new ArrayList<WallpaperBrowseCacheEntry>();
            public HashSet<string> seen_keys = new HashSet<string>();
            public HashSet<string> seen_ocs_ids = new HashSet<string>();
            public bool background;
            public int generation;
            public string provider;
            public WallpaperProvider backend;
            public ArrayList<string> todo = new ArrayList<string>();
            public int next_index;
            public int done_count;
            public int item_count;
            public int total;
            public Cancellable cancel;
            public Mutex todo_lock = new Mutex();
            public Mutex count_lock = new Mutex();
        }

        // One worker in the bounded crawl pool. Pulls ids off the shared
        // todo queue inside CrawlState, runs the per-category browse, and
        // merges results back into the same state. The per-category browse
        // itself runs one subprocess per call via the existing command()
        // helper, so no extra concurrency limiter is needed there.
        private async void worker(CrawlState state) {
            // Read everything through state.X; never capture local refs.
            while (state.generation == generation && !state.cancel.is_cancelled()) {
                int my_index = 0;
                state.todo_lock.lock();
                try {
                    if (state.next_index >= state.todo.size) {
                        return;
                    }
                    my_index = state.next_index++;
                } finally {
                    state.todo_lock.unlock();
                }
                // Pre-check the cap so we never even spawn the subprocess
                // for a category we are going to discard.
                state.count_lock.lock();
                bool cap_hit = false;
                try {
                    if (state.item_count >= CRAWL_ITEM_CAP) cap_hit = true;
                } finally {
                    state.count_lock.unlock();
                }
                if (cap_hit) {
                    state.count_lock.lock();
                    int d;
                    try { d = ++state.done_count; } finally { state.count_lock.unlock(); }
                    Idle.add(() => {
                        if (!state.background && state.generation == generation)
                            status.label = _("Loaded %d/%d · %d wallpapers (cap reached)").printf(d, state.total, state.item_count);
                        return Source.REMOVE;
                    });
                    return;
                }
                string category = state.todo[my_index];
                string? error = null;
                try {
                    var result = yield state.backend.browse(category, "", 1, force_refresh, state.cancel);
                    if (state.generation != generation || state.cancel.is_cancelled()) return;
                    var items = result.items;
                    if (result.warning != "") error = _(result.warning);
                    foreach (var item in items) {
                        if (state.background) {
                            bool duplicate = state.seen_keys.contains(item.key) ||
                                (WallpaperOcs.provider_id(item.provider_id) && state.seen_ocs_ids.contains(item.id));
                            if (duplicate) continue;
                        } else if (has_card(item)) continue;
                        // Re-check the cap under the lock so two workers
                        // can never both push past it on the last item.
                        state.count_lock.lock();
                        bool overflow = false;
                        try {
                            if (state.item_count >= CRAWL_ITEM_CAP) {
                                overflow = true;
                            } else {
                                state.item_count++;
                            }
                        } finally {
                            state.count_lock.unlock();
                        }
                        if (overflow) break;
                        if (state.background) {
                            state.seen_keys.add(item.key);
                            if (WallpaperOcs.provider_id(item.provider_id)) state.seen_ocs_ids.add(item.id);
                            state.results.add(new WallpaperBrowseCacheEntry(item, category));
                        } else {
                            add_card(item);
                        }
                    }
                } catch (Error e) {
                    if (e is GLib.IOError.CANCELLED) return;
                    error = e.message;
                }
                state.count_lock.lock();
                int d;
                int snap;
                if (error != null && !state.errors.contains(error)) state.errors.add(error);
                try { d = ++state.done_count; snap = state.item_count; } finally { state.count_lock.unlock(); }
                // Status updates live on the main thread. The captured
                // `d`/`snap`/`category`/`error` are local-scope value
                // captures -- safe to use in the Idle callback that fires
                // after this async function yields.
                Idle.add(() => {
                    if (state.generation != generation) return Source.REMOVE;
                    if (state.background) return Source.REMOVE;
                    if (error != null) {
                        // One bad category must not block the others; just
                        // surface it in the status line alongside the count.
                        status.label = _("Loaded %d/%d · %d wallpapers · %s failed: %s").printf(d, state.total, snap, category, error);
                    } else {
                        status.label = _("Loaded %d/%d · %d wallpapers so far").printf(d, state.total, snap);
                    }
                    return Source.REMOVE;
                });
            }
        }

        // Called under updating so a selection notification cannot start a
        // crawl against a partially replaced option list. SelectionRow
        // stores id/label pairs directly (current_value is the id), so
        // unlike the previous combo-row code there is no separate
        // position -> id array to maintain.
        private static void set_choices(SelectionRow row,
                Gee.ArrayList<Singularity.Core.AppSettingOption> options, string current) {
            row.set_options(options);
            row.current_value = current;
        }

        private void filter_cards() {
            string query = (search_row != null ? search_row.text : "").strip().casefold();
            int count = 0;
            foreach (var card in cards) {
                card.matches = card_matches(card.item, query);
                if (card.matches) count++;
            }
            grid.invalidate_filter();
            queue_viewport_thumbnails();
            if (!loading && !imports.busy) {
                if (cards.size == 0) status.label = _("No importable wallpapers for this category.");
                else if (count == 0) status.label = _("No matches among loaded wallpapers. Clear the filter or refresh.");
                else status.label = _("%d wallpapers shown · %d loaded").printf(count, cards.size);
            }
        }

        private bool filter_grid_child(FlowBoxChild child) {
            int index = child.get_index();
            return index >= 0 && index < cards.size &&
                   cards[index].card == child.child && cards[index].matches;
        }

        // Free-text match against name + author only. Category is no longer
        // a client-side filter over an aggregate list -- a crawl now covers
        // exactly one category, so every card already in `cards` belongs to
        // the one the user picked (see browse_category()).
        private bool card_matches(WallpaperItem item, string query) {
            if (query != "")
                return (item.name + " " + item.author).casefold().contains(query);
            return true;
        }


        // (Re)build a card for one wallpapers item. The visible chrome is a
        // WallpaperCard (visual parity with the main Desktop wallpaper
        // picker -- same 172x104 clipped rounded frame, same Picture with
        // ContentFit.COVER, same title overlay with object-select check,
        // same wallpaper-card / workspace-preview CSS classes). Action
        // button (Import / Pin) attaches through WallpaperCard.set_action_
        // button() so the visual chrome stays consistent with the local
        // picker's trash button. Attribution + licence live as a small
        // badge on the card via WallpaperCard.set_badge().
        private bool has_card(WallpaperItem item) {
            foreach (var existing in cards) {
                if (existing.item.key == item.key ||
                    (WallpaperOcs.provider_id(existing.item.provider_id) && WallpaperOcs.provider_id(item.provider_id) && existing.item.id == item.id)) return true;
            }
            return false;
        }

        private void add_card(WallpaperItem item) {
            if (has_card(item)) return;
            if (item.provider_id != "openverse" && item.provider_id != "unsplash") {
                item.name = WallpaperSidecar.plain_text(item.name);
                item.author = WallpaperSidecar.plain_text(item.author);
                item.license = WallpaperSidecar.plain_text(item.license);
            }
            var card = new OcsCard();
            card.item = item;
            // Use placeholder_only: the OCS browser drives its own async
            // thumbnail load (with generation/close guards) via load_one_
            // thumbnail() rather than letting WallpaperCard's built-in
            // worker handle it (which has no generation awareness).
            string card_title = item.name != "" ? item.name : (item.provider_id == BING_PROVIDER_ID ? _("Bing wallpaper") : _("Wallpaper"));
            card.card = new WallpaperCard.placeholder_only(item.key, card_title);
            // Attribution / licence badge. OCS shows uploader · provider;
            // Bing shows market · "Bing". Honour dim-label style so the
            // badge reads as supporting text, not primary title.
            string attribution;
            if (item.provider_id == BING_PROVIDER_ID)
                attribution = "%s · %s".printf(_("Bing"), item.market != "" ? item.market : item.provider_id);
            else
                attribution = "%s · %s".printf(item.author != "" ? item.author : _("Unknown uploader"),
                    item.provider_id == "openverse" ? _("Openverse") : item.provider_id == "unsplash" ? _("Unsplash") : _("OCS Network"));
            string license_text = item.license != "" ? item.license : _("No license stated");
            card.card.set_badge(attribution + "  ·  " + license_text);
            if (item.provider_id == "openverse" || item.provider_id == "unsplash") {
                var metadata = WallpaperAttribution() { title = "", author = item.attribution != "" ? item.attribution : item.author,
                    source = (item.provider_id == "unsplash" ? "Unsplash · " : "Openverse · ") + item.license,
                    page_url = item.page_url, license_url = item.license_url, valid = true };
                var credit = new Label(WallpaperSidecar.display_text(metadata));
                credit.use_markup = false;
                credit.wrap = true;
                credit.selectable = true;
                credit.max_width_chars = 28;
                card.card.append(credit);
                if (item.provider_id == "unsplash" && (item.creator_url.has_prefix("https://") || item.creator_url.has_prefix("http://")))
                    card.card.append(new LinkButton.with_label(item.creator_url, _("Photographer on Unsplash")));
                if (item.page_url.has_prefix("https://") || item.page_url.has_prefix("http://"))
                    card.card.append(new LinkButton.with_label(item.page_url, _("Original image / attribution")));
                if (item.license_url.has_prefix("https://") || item.license_url.has_prefix("http://"))
                    card.card.append(new LinkButton.with_label(item.license_url, item.license));
            }
            // Card click: WallpaperCard emits clicked() on the GestureClick
            // wired in build_card(); for OCS/Bing this is purely a visual
            // affordance; importing is the meaningful action for searchable
            // providers. Bing entries are already local. The checkmark stays
            // decorative.
            // Action button (Import / Added). Bing entries were added by the
            // scheduled accumulator already, so there is no per-card action.
            if (item.provider_id == BING_PROVIDER_ID) {
                card.button = new Button.with_label(_("Added"));
                card.button.sensitive = false;
            } else {
                card.button = new Button.with_label(imports.is_added(item.key) ? _("Added") : _("Import"));
                card.button.clicked.connect(() => { import_card.begin(card); });
            }
            card.card.append_action_button(card.button);
            grid.append(card.card);
            cards.add(card);
        }

        private void reset_thumbnail_loading() {
            thumbnail_requested.clear();
            thumbnail_pending.clear();
        }

        // Recompute after allocation: cache/crawl repaint leaves the scroll
        // value unchanged, while the newly appended FlowBox children do not
        // have meaningful bounds until GTK's next layout pass.
        private void queue_viewport_thumbnails() {
            int gen = generation;
            Idle.add(() => {
                if (gen != generation || request.is_cancelled()) return Source.REMOVE;
                double top = scroller.vadjustment.value;
                double bottom = top + scroller.vadjustment.page_size;
                bool queued = false;
                for (int i = 0; i < cards.size; i++) {
                    var child = grid.get_child_at_index(i);
                    if (child == null) continue;
                    if (!cards[i].matches) {
                        thumbnail_requested.remove(i);
                        thumbnail_pending.remove(i);
                        cards[i].card.set_paintable(null);
                        continue;
                    }
                    Graphene.Rect bounds;
                    if (!child.compute_bounds(content_box, out bounds)) continue;
                    double child_top = bounds.origin.y;
                    double child_bottom = child_top + bounds.size.height;
                    bool near = child_bottom >= top - VIEWPORT_PREFETCH_MARGIN_PX &&
                        child_top <= bottom + VIEWPORT_PREFETCH_MARGIN_PX;
                    bool far = child_bottom < top - VIEWPORT_EVICT_MARGIN_PX ||
                        child_top > bottom + VIEWPORT_EVICT_MARGIN_PX;
                    if (near && thumbnail_requested.add(i)) {
                        thumbnail_pending.add(i);
                        queued = true;
                    } else if (far && thumbnail_requested.remove(i)) {
                        thumbnail_pending.remove(i);
                        cards[i].card.set_paintable(null);
                    }
                }
                if (queued)
                    for (int lane = 0; lane < THUMBNAIL_FETCH_LANES; lane++)
                        thumbnails.begin(lane, gen, request);
                return Source.REMOVE;
            });
        }

        // Async thumbnail loader, fanned out for newly visible cards.
        // Two source paths:
        //   * Bing items: thumbnail_path is a local file (helper pre-
        //     downloaded the 400x240 JPEG before the `list` response was
        //     built). Read the bytes, then decode via MemoryInputStream so
        //     the loader does not block on the open InputStream (passing
        //     an already-open stream to from_stream_at_scale_async can
        //     deadlock on the read loop -- the loader assumes it owns the
        //     stream and reads it synchronously until EOF).
        //   * OCS items: item.preview is a remote URL, fetched via Soup.
        //   * Either path failure just leaves the placeholder visible;
        //     a missing preview must not prevent browsing or importing.
        //
        // Each thumbnail write is marshalled onto the main thread via
        // Idle.add() so the Picture widget's set_paintable is always
        // called from the UI thread (GTK4 widget APIs are not safe to
        // call from arbitrary worker contexts).
        private async void thumbnails(int start, int gen, Cancellable cancel) {
            for (int i = start; i < cards.size && gen == generation && !cancel.is_cancelled(); i += THUMBNAIL_FETCH_LANES) {
                if (!thumbnail_pending.remove(i)) continue;
                var card = cards[i];
                Gdk.Pixbuf? pixbuf = null;
                if (card.item.thumbnail_path != "") {
                    // Bing local-file path.
                    try {
                        var file = File.new_for_path(card.item.thumbnail_path);
                        if (!file.query_exists()) {
                            show_thumb_unavailable(card);
                            continue;
                        }
                        var stream = yield file.read_async(Priority.DEFAULT, cancel);
                        // Drain to a ByteArray so we own the bytes: the
                        // loader does not have to fight an open file
                        // descriptor for sync reads.
                        var bytes = new ByteArray();
                        try {
                            while (true) {
                                var part = yield stream.read_bytes_async(65536, Priority.DEFAULT, cancel);
                                if (part.get_size() == 0) break;
                                if (bytes.len + part.get_size() > 4 * 1024 * 1024) {
                                    throw new IOError.FAILED("Thumbnail exceeds size limit");
                                }
                                bytes.append(part.get_data());
                            }
                        } finally {
                            // Vala forbids `yield` inside finally, so the
                            // close is a plain call: a non-cancellable
                            // close on a Cancellable-bound stream is
                            // acceptable here -- we're throwing it away.
                            try { stream.close(); } catch (Error e) {}
                        }
                        if (cancel.is_cancelled()) continue;
                        var input = new MemoryInputStream.from_bytes(ByteArray.free_to_bytes((owned) bytes));
                        pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(input, 344, 208, true, cancel);
                    } catch (Error e) {
                        if (!(e is GLib.IOError.CANCELLED)) show_thumb_unavailable(card);
                        continue;
                    }
                } else {
                    // OCS Soup path.
                    string url = card.item.preview;
                    if (!url.has_prefix("https://") && !url.has_prefix("http://")) continue;
                    var cached = thumbnail_cache.get(url);
                    if (cached != null) {
                        try {
                            var input = new MemoryInputStream.from_bytes(cached);
                            pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(input, 344, 208, true, cancel);
                        } catch (Error e) {
                            if (!(e is GLib.IOError.CANCELLED)) show_thumb_unavailable(card);
                            continue;
                        }
                        if (cancel.is_cancelled()) continue;
                    } else {
                        var message = new Soup.Message("GET", url);
                        if (message == null) continue;
                        InputStream? stream = null;
                        bool skip_card = false;
                        try {
                            stream = yield session.send_async(message, Priority.DEFAULT, cancel);
                            if (cancel.is_cancelled()) { skip_card = true; }
                            else if (message.status_code != 200) { skip_card = true; }
                            else {
                                var bytes = new ByteArray();
                                while (true) {
                                    var part = yield stream.read_bytes_async(65536, Priority.DEFAULT, cancel);
                                    if (part.get_size() == 0) break;
                                    if (bytes.len + part.get_size() > 4 * 1024 * 1024) {
                                        throw new IOError.FAILED("Thumbnail exceeds size limit");
                                    }
                                    bytes.append(part.get_data());
                                }
                                var fetched = ByteArray.free_to_bytes((owned) bytes);
                                thumbnail_cache.put(url, fetched);
                                var input = new MemoryInputStream.from_bytes(fetched);
                                pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(input, 344, 208, true, cancel);
                            }
                        } catch (Error e) {
                            if (!(e is GLib.IOError.CANCELLED)) show_thumb_unavailable(card);
                            skip_card = true;
                        } finally {
                            // Synchronous close() (not close_async()) because
                            // Vala forbids yield inside finally. Soup response
                            // streams are safe to close synchronously.
                            if (stream != null) {
                                try { stream.close(); } catch (Error e) {}
                            }
                        }
                        if (skip_card) continue;
                    }
                }
                if (pixbuf == null) continue;
                if (gen != generation || cancel.is_cancelled()) continue;
                // Marshal the paintable assignment onto the main thread so
                // Picture.set_paintable is always called from a UI context.
                // The local var capture is safe: pixbuf is a fresh heap
                // object and `card` is a strong ref into the cards[] list.
                Gdk.Pixbuf captured_pb = pixbuf;
                OcsCard captured_card = card;
                int captured_index = i;
                Idle.add(() => {
                    if (gen == generation && thumbnail_requested.contains(captured_index) && captured_card.card != null)
                        captured_card.card.set_paintable(Gdk.Texture.for_pixbuf(captured_pb));
                    return GLib.Source.REMOVE;
                });
            }
        }

        // Surface a "preview unavailable" tooltip on the card without
        // touching the picture's paintable (the placeholder stays
        // visible). Marshalled to the main thread so it can run from any
        // async context safely.
        private void show_thumb_unavailable(OcsCard card) {
            Idle.add(() => {
                if (generation >= 0 && card.card != null) {
                    // Tooltip on the WallpaperCard itself rather than on
                    // an internal Picture -- the picture is private.
                    card.card.tooltip_text = _("Preview unavailable");
                }
                return GLib.Source.REMOVE;
            });
        }

        private async void import_card(OcsCard card) {
            if (!imports.begin(card.item.key)) return;
            card.button.label = _("Importing…");
            status.label = _("Downloading and preparing wallpaper pack…");
            update_controls();
            try {
                var provider = provider_registry.lookup(card.item.provider_id == "pling" || card.item.provider_id == "kde-look" || card.item.provider_id == "gnome-look" ? "ocs" : card.item.provider_id);
                if (provider == null) throw new IOError.NOT_SUPPORTED("Wallpaper provider is not active.");
                string data = yield provider.import_item(card.item, null);
                imports.complete(card.item.key, data, collection_roots);
                card.button.label = _("Added");
                status.label = _("Theme pack updated. Choose it in Wallpaper Source.");
                imported();
            } catch (Error e) {
                imports.fail(card.item.key);
                card.button.label = _("Retry import");
                status.label = _("Import failed: %s").printf(e.message);
            }
            update_controls();
        }
    }
}
