using Gtk;
using Gee;

namespace Singularity.Shell {
    // Presentation only: the installed helper owns all OCS and import policy.
    public class WallpaperOcsBrowser : Gtk.Window {
        public signal void imported();
        public signal void dismissed();
        private const string HELPER = "/usr/local/bin/ncz-wallpaper-ocs";
        private string[] collection_roots;
        private WallpaperOcsImports imports = new WallpaperOcsImports();
        private ArrayList<WallpaperOcsChoice> providers = new ArrayList<WallpaperOcsChoice>();
        private ArrayList<WallpaperOcsChoice> categories = new ArrayList<WallpaperOcsChoice>();
        private ArrayList<OcsCard> cards = new ArrayList<OcsCard>();
        private DropDown provider_box;
        private DropDown category_box;
        private Gtk.SearchEntry search;
        private FlowBox grid;
        private Label status;
        private Spinner spinner;
        private Button refresh;
        private Button more;
        private Button close_button;
        private Box controls;
        private Soup.Session session = new Soup.Session();
        private Cancellable request = new Cancellable();
        private int generation = 0;
        private int pages = 1;
        private bool loading = false;
        private bool updating = false;
        private bool closed = false;
        private string category_index = "";

        private class OcsCard : Object {
            public WallpaperOcsItem item;
            public FlowBoxChild child;
            public Picture picture;
            public Button button;
            public Label message;
            public Spinner spinner;
        }

        public WallpaperOcsBrowser(Gtk.Application app, string[] roots) {
            Object(application: app, title: _("Online Wallpapers"), default_width: 820, default_height: 680);
            collection_roots = roots;
            imports.discover(WallpaperCollections.parse(roots));
            session.timeout = 25;
            session.user_agent = "Singularity-Wallpaper-Browser/1";
            var content = new Box(Orientation.VERTICAL, 12);
            content.margin_start = content.margin_end = 20;
            content.margin_top = content.margin_bottom = 16;
            set_child(content);
            var header = new Box(Orientation.HORIZONTAL, 12);
            var title_label = new Label(_("Online Wallpapers"));
            title_label.add_css_class("title-2");
            title_label.hexpand = true;
            title_label.xalign = 0;
            header.append(title_label);
            close_button = new Button.with_label(_("Close"));
            close_button.clicked.connect(() => close());
            header.append(close_button);
            content.append(header);
            var description = new Label(_("Import wallpapers from OCS uploaders. Added packs appear in Wallpaper Source."));
            description.wrap = true;
            description.xalign = 0;
            content.append(description);
            controls = new Box(Orientation.HORIZONTAL, 12);
            provider_box = new DropDown(null, null);
            category_box = new DropDown(null, null);
            category_box.enable_search = true;
            category_box.hexpand = true;
            controls.append(new Label(_("Provider")));
            controls.append(provider_box);
            controls.append(new Label(_("Category")));
            controls.append(category_box);
            content.append(controls);
            var tools = new Box(Orientation.HORIZONTAL, 8);
            search = new Gtk.SearchEntry();
            search.placeholder_text = _("Filter loaded wallpapers");
            search.hexpand = true;
            tools.append(search);
            refresh = new Button.with_label(_("Refresh / Retry"));
            refresh.clicked.connect(() => {
                if (category_index == "") initialize.begin();
                else browse.begin();
            });
            tools.append(refresh);
            content.append(tools);
            var progress = new Box(Orientation.HORIZONTAL, 8);
            spinner = new Spinner();
            progress.append(spinner);
            status = new Label("");
            status.wrap = true;
            status.xalign = 0;
            status.hexpand = true;
            progress.append(status);
            content.append(progress);
            var scroll = new ScrolledWindow();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            grid = new FlowBox();
            grid.selection_mode = SelectionMode.NONE;
            grid.min_children_per_line = 1;
            grid.max_children_per_line = 3;
            grid.column_spacing = grid.row_spacing = 12;
            grid.valign = Align.START;
            scroll.set_child(grid);
            content.append(scroll);
            more = new Button.with_label(_("Load more"));
            more.halign = Align.CENTER;
            more.clicked.connect(() => { if (pages < 5) { pages++; browse.begin(); } });
            content.append(more);
            provider_box.notify["selected"].connect(() => { if (!updating) select_provider(); });
            category_box.notify["selected"].connect(() => { if (!updating) { pages = 1; browse.begin(); } });
            search.search_changed.connect(filter_cards);
            close_request.connect(() => {
                if (imports.busy) {
                    status.label = _("Import in progress. You can close this window when it finishes.");
                    return true;
                }
                closed = true;
                generation++;
                request.cancel();
                session.abort();
                dismissed();
                return false;
            });
            var keys = new EventControllerKey();
            keys.key_pressed.connect((key, code, modifiers) => {
                if (key == Gdk.Key.Escape) { close(); return true; }
                return false;
            });
            ((Gtk.Widget) this).add_controller(keys);
            initialize.begin();
        }

        private void update_controls() {
            controls.sensitive = !imports.busy && category_index != "";
            search.sensitive = !imports.busy;
            refresh.sensitive = !imports.busy && !loading;
            more.sensitive = !imports.busy && !loading && cards.size > 0 && pages < 5;
            close_button.sensitive = !imports.busy;
            foreach (var card in cards)
                card.button.sensitive = !imports.busy && !imports.is_added(card.item.key);
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

        private async string command(string[] argv, Cancellable? cancel, uint timeout) throws Error {
            var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
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
                yield process.communicate_utf8_async(null, null, out output, out errors);
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
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            loading = true;
            status.label = _("Loading wallpaper providers…");
            update_controls();
            try {
                string data = yield command({HELPER, "providers"}, cancel, 30);
                var choices = WallpaperOcs.providers(data);
                uint8[] contents;
                yield File.new_for_path("/usr/share/ncz-wallpapers/ocs-category-index.json").load_contents_async(cancel, out contents, null);
                string index = (string) contents;
                if (gen != generation || closed) return;
                if (choices.size == 0) throw new IOError.FAILED(_("No wallpaper providers available."));
                // Validate before retaining the index so Retry can reload bad data.
                foreach (var choice in choices) WallpaperOcs.categories(index, choice.id);
                providers = choices;
                category_index = index;
                // Gtk.StringList expects a null-terminated strv. Gee.to_array()
                // carries a length instead; append avoids reading past that array.
                var names = new Gtk.StringList(null);
                uint initial = 0;
                for (int i = 0; i < providers.size; i++) {
                    names.append(providers[i].name);
                    if (providers[i].id == "pling") initial = (uint) i;
                }
                updating = true;
                provider_box.model = names;
                provider_box.selected = initial;
                updating = false;
                loading = false;
                select_provider();
            } catch (Error e) {
                if (gen != generation || closed) return;
                loading = false;
                status.label = _("Could not load wallpaper providers: %s").printf(e.message);
                update_controls();
            }
        }

        private void select_provider() {
            if (provider_box.selected >= providers.size) return;
            try {
                categories = WallpaperOcs.categories(category_index, providers[(int) provider_box.selected].id);
                // Gtk.StringList expects a null-terminated strv. Gee.to_array()
                // carries a length instead; append avoids reading past that array.
                var names = new Gtk.StringList(null);
                uint initial = 0;
                for (int i = 0; i < categories.size; i++) {
                    names.append(categories[i].name);
                    if (categories[i].id == "300") initial = (uint) i;
                }
                updating = true;
                category_box.model = names;
                category_box.selected = categories.size > 0 ? initial : Gtk.INVALID_LIST_POSITION;
                updating = false;
                pages = 1;
                browse.begin();
            } catch (Error e) { status.label = e.message; }
        }

        private async void browse() {
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            grid.remove_all();
            cards.clear();
            if (provider_box.selected >= providers.size || category_box.selected >= categories.size) {
                loading = false;
                status.label = _("No usable wallpaper categories for this provider.");
                update_controls();
                return;
            }
            string provider = providers[(int) provider_box.selected].id;
            string category = categories[(int) category_box.selected].id;
            loading = true;
            status.label = _("Loading wallpapers…");
            update_controls();
            try {
                string data = yield command({HELPER, "browse", provider, category, "--pages", pages.to_string()}, cancel, 240);
                var items = WallpaperOcs.items(data, provider, category);
                if (gen != generation || closed) return;
                foreach (var item in items) add_card(item);
                loading = false;
                filter_cards();
                update_controls();
                // Three bounded streaming requests, never one worker per tile.
                for (int i = 0; i < 3; i++) thumbnails.begin(i, gen, cancel);
            } catch (Error e) {
                if (gen != generation || closed) return;
                loading = false;
                status.label = _("Could not load wallpapers: %s").printf(e.message);
                update_controls();
            }
        }

        private void filter_cards() {
            string query = search.text.strip().casefold();
            int count = 0;
            foreach (var card in cards) {
                bool matches = query == "" || (card.item.name + " " + card.item.author).casefold().contains(query);
                card.child.visible = matches;
                if (matches) count++;
            }
            if (!loading && !imports.busy) {
                if (cards.size == 0) status.label = _("No importable wallpapers in this category.");
                else if (count == 0) status.label = _("No matches among loaded wallpapers. Clear the filter or load more.");
                else status.label = _("%d wallpapers shown · %d loaded").printf(count, cards.size);
            }
        }

        private void add_card(WallpaperOcsItem item) {
            var card = new OcsCard();
            card.item = item;
            card.child = new FlowBoxChild();
            var box = new Box(Orientation.VERTICAL, 6);
            box.set_size_request(220, -1);
            box.margin_start = box.margin_end = 8;
            box.margin_top = box.margin_bottom = 8;
            box.add_css_class("card");
            card.picture = new Picture();
            card.picture.set_size_request(220, 130);
            card.picture.content_fit = ContentFit.COVER;
            card.picture.can_shrink = true;
            var overlay = new Overlay();
            var placeholder = new Image.from_icon_name("image-x-generic-symbolic");
            placeholder.pixel_size = 48;
            overlay.set_child(placeholder);
            overlay.add_overlay(card.picture);
            overlay.set_size_request(220, 130);
            box.append(overlay);
            var name = new Label(item.name);
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 26;
            name.tooltip_text = item.name;
            name.add_css_class("heading");
            box.append(name);
            string attribution = "%s · %s".printf(item.author != "" ? item.author : _("Unknown uploader"), item.provider);
            var credit = new Label(attribution);
            credit.xalign = 0;
            credit.ellipsize = Pango.EllipsizeMode.END;
            credit.max_width_chars = 26;
            credit.tooltip_text = attribution;
            box.append(credit);
            var license = new Label(item.license != "" ? item.license : _("No license stated"));
            license.xalign = 0;
            license.ellipsize = Pango.EllipsizeMode.END;
            license.max_width_chars = 26;
            license.tooltip_text = license.label;
            license.add_css_class("dim-label");
            box.append(license);
            card.message = new Label("");
            card.message.wrap = true;
            card.message.max_width_chars = 26;
            card.message.xalign = 0;
            box.append(card.message);
            var action = new Box(Orientation.HORIZONTAL, 8);
            card.spinner = new Spinner();
            action.append(card.spinner);
            card.button = new Button.with_label(imports.is_added(item.key) ? _("Added") : _("Import"));
            card.button.hexpand = true;
            card.button.clicked.connect(() => import_card.begin(card));
            action.append(card.button);
            box.append(action);
            card.child.set_child(box);
            grid.append(card.child);
            cards.add(card);
        }

        private async void thumbnails(int start, int gen, Cancellable cancel) {
            for (int i = start; i < cards.size && gen == generation && !closed; i += 3) {
                var card = cards[i];
                string url = card.item.preview;
                if (!url.has_prefix("https://") && !url.has_prefix("http://")) continue;
                try {
                    var message = new Soup.Message("GET", url);
                    if (message == null) continue;
                    var stream = yield session.send_async(message, Priority.DEFAULT, cancel);
                    if (message.status_code != 200) { yield stream.close_async(Priority.DEFAULT, null); continue; }
                    var bytes = new ByteArray();
                    while (true) {
                        var part = yield stream.read_bytes_async(65536, Priority.DEFAULT, cancel);
                        if (part.get_size() == 0) break;
                        if (bytes.len + part.get_size() > 4 * 1024 * 1024) {
                            yield stream.close_async(Priority.DEFAULT, null);
                            throw new IOError.FAILED("Thumbnail exceeds size limit");
                        }
                        bytes.append(part.get_data());
                    }
                    yield stream.close_async(Priority.DEFAULT, null);
                    var input = new MemoryInputStream.from_bytes(ByteArray.free_to_bytes((owned) bytes));
                    var pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(input, 440, 260, true, cancel);
                    if (gen == generation && !closed) card.picture.paintable = Gdk.Texture.for_pixbuf(pixbuf);
                } catch (Error e) {
                    // A missing preview must not prevent browsing or importing.
                    if (gen == generation && !closed) card.picture.tooltip_text = _("Preview unavailable");
                }
            }
        }

        private async void import_card(OcsCard card) {
            if (!imports.begin(card.item.key)) return;
            card.spinner.start();
            card.button.label = _("Importing…");
            card.message.label = "";
            status.label = _("Downloading and preparing wallpaper pack…");
            update_controls();
            try {
                string data = yield command({HELPER, "import", card.item.provider, card.item.id}, null, 600);
                imports.complete(card.item.key, data, collection_roots);
                card.button.label = _("Added");
                card.message.label = _("Available in Wallpaper Source");
                status.label = _("Pack added. Choose it in Wallpaper Source.");
                imported();
            } catch (Error e) {
                imports.fail(card.item.key);
                card.button.label = _("Retry import");
                card.message.label = _("Could not import: %s").printf(e.message);
                status.label = _("Import failed. You can retry.");
            }
            card.spinner.stop();
            update_controls();
        }
    }
}
