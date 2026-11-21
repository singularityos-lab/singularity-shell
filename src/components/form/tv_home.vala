using Gtk;
using GtkLayerShell;

namespace Singularity {

    internal class TvTints {
        private static CssProvider? _provider = null;
        private static StringBuilder? _css = null;
        private static GenericSet<string>? _known = null;
        private static uint _reload = 0;

        public static string class_for(GLib.Icon? icon) {
            var c = Gdk.RGBA();
            if (icon == null || !Singularity.Style.IconColor.sample(icon, out c)) {
                c = Gdk.RGBA() { red = 0.45f, green = 0.48f, blue = 0.52f, alpha = 1 };
            }
            double h, s, v;
            Singularity.ColorUtil.rgb_to_hsv(c.red, c.green, c.blue, out h, out s, out v);
            bool gray = s < 0.18;
            string top = Singularity.ColorUtil.hsv_to_hex(h, gray ? s.clamp(0, 0.08) : s.clamp(0.4, 0.62), gray ? 0.44 : 0.6);
            string bottom = Singularity.ColorUtil.hsv_to_hex(h, gray ? s.clamp(0, 0.1) : s.clamp(0.5, 0.78), gray ? 0.22 : 0.27);
            string name = "tv-tint-%s-%s".printf(top.substring(1), bottom.substring(1));
            if (_known == null) {
                _known = new GenericSet<string>(str_hash, str_equal);
                _css = new StringBuilder();
            }
            if (_known.contains(name)) return name;
            _known.add(name);
            _css.append(".tv-app-art.%s { background-image: linear-gradient(160deg, %s, %s); }\n".printf(name, top, bottom));
            schedule();
            return name;
        }

        private static void schedule() {
            if (_reload != 0) return;
            _reload = Idle.add(() => {
                _reload = 0;
                var display = Gdk.Display.get_default();
                if (display == null) return Source.REMOVE;
                if (_provider == null) {
                    _provider = new CssProvider();
                    StyleContext.add_provider_for_display(display, _provider, STYLE_PROVIDER_PRIORITY_USER + 1);
                }
                _provider.load_from_string(_css.str);
                return Source.REMOVE;
            });
        }
    }

    internal class TvHero : Box {
        private const int HEIGHT = 360;
        private const uint ROTATE_SECONDS = 12;

        public signal void watch(Streaming.Title title);
        public signal void details(Streaming.Title title);

        private Picture _picture;
        private Label _badge;
        private Label _title;
        private Label _overview;
        private Button _watch;
        private Button _details;
        private Box _actions;
        private Box _dots;
        private GenericArray<Streaming.Title> _titles = new GenericArray<Streaming.Title>();
        private HashTable<string, Gdk.Texture> _art = new HashTable<string, Gdk.Texture>(str_hash, str_equal);
        private Cancellable? _loading = null;
        private int _index = 0;
        private uint _rotate = 0;
        private int _art_width;
        private int _art_height;

        public TvHero(int width, int scale) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("tv-hero");
            overflow = Overflow.HIDDEN;
            _art_width = width * scale;
            _art_height = HEIGHT * scale;
            hexpand = true;

            var stage = new Overlay();
            stage.vexpand = true;
            _picture = new Picture();
            _picture.content_fit = ContentFit.COVER;
            _picture.can_shrink = true;
            _picture.add_css_class("tv-hero-art");
            var frame = new Box(Orientation.VERTICAL, 0);
            frame.height_request = HEIGHT;
            frame.hexpand = true;
            stage.child = frame;
            stage.add_overlay(_picture);

            var scrim = new Box(Orientation.VERTICAL, 0);
            scrim.add_css_class("tv-hero-scrim");
            scrim.can_target = false;
            stage.add_overlay(scrim);

            var text = new Box(Orientation.VERTICAL, 0);
            text.add_css_class("tv-hero-text");
            text.halign = Align.START;
            text.valign = Align.CENTER;
            _badge = new Label(_("Featured"));
            _badge.add_css_class("tv-hero-badge");
            _badge.halign = Align.START;
            text.append(_badge);
            _title = new Label("");
            _title.add_css_class("tv-hero-title");
            _title.xalign = 0;
            _title.wrap = true;
            _title.lines = 2;
            _title.ellipsize = Pango.EllipsizeMode.END;
            _title.max_width_chars = 30;
            text.append(_title);
            _overview = new Label("");
            _overview.add_css_class("tv-hero-overview");
            _overview.xalign = 0;
            _overview.wrap = true;
            _overview.wrap_mode = Pango.WrapMode.WORD_CHAR;
            _overview.lines = 2;
            _overview.ellipsize = Pango.EllipsizeMode.END;
            _overview.max_width_chars = 46;
            _overview.width_chars = 46;
            text.append(_overview);
            _actions = new Box(Orientation.HORIZONTAL, 20);
            _actions.add_css_class("tv-hero-actions");
            _watch = action_button("media-playback-start-symbolic", _("Watch"), "tv-hero-watch");
            _watch.clicked.connect(() => {
                var t = current();
                if (t != null) watch(t);
            });
            _details = action_button("dialog-information-symbolic", _("Details"), "tv-hero-details");
            _details.clicked.connect(() => {
                var t = current();
                if (t != null) details(t);
            });
            _actions.append(_watch);
            _actions.append(_details);
            text.append(_actions);
            stage.add_overlay(text);

            _dots = new Box(Orientation.HORIZONTAL, 10);
            _dots.add_css_class("tv-hero-dots");
            _dots.halign = Align.END;
            _dots.valign = Align.END;
            _dots.can_target = false;
            stage.add_overlay(_dots);
            append(stage);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (_titles.length < 2) return false;
                if (keyval == Gdk.Key.Left && _watch.has_focus) {
                    show_index(_index - 1);
                    return true;
                }
                if (keyval == Gdk.Key.Right && _details.has_focus) {
                    show_index(_index + 1);
                    return true;
                }
                return false;
            });
            add_controller(keys);
            map.connect(() => start_rotation());
            unmap.connect(() => stop_rotation());
        }

        private static Button action_button(string icon, string label, string css) {
            var box = new Box(Orientation.HORIZONTAL, 12);
            var image = new Image.from_icon_name(icon);
            image.pixel_size = 22;
            box.append(image);
            box.append(new Label(label));
            var button = new Button();
            button.child = box;
            button.add_css_class(css);
            button.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            return button;
        }

        public Streaming.Title? current() {
            return _index < _titles.length ? _titles[_index] : null;
        }

        public bool has_titles {
            get { return _titles.length > 0; }
        }

        public bool focus_primary() {
            return _actions.visible && _watch.grab_focus();
        }

        public void show_titles(GenericArray<Streaming.Title> titles) {
            _titles = titles;
            if (_loading != null) _loading.cancel();
            _loading = new Cancellable();
            var keep = new HashTable<string, Gdk.Texture>(str_hash, str_equal);
            foreach (var t in titles) {
                if (t.backdrop_uri == null) continue;
                var tex = _art.lookup(t.backdrop_uri);
                if (tex != null) keep.insert(t.backdrop_uri, tex);
            }
            _art = keep;
            _index = 0;
            remove_css_class("empty");
            _badge.visible = true;
            _actions.visible = true;
            _overview.lines = 2;
            rebuild_dots();
            render();
            load_art.begin(_loading);
        }

        public void show_message(string title, string message) {
            _titles = new GenericArray<Streaming.Title>();
            if (_loading != null) _loading.cancel();
            add_css_class("empty");
            _picture.paintable = null;
            _badge.visible = false;
            _actions.visible = false;
            _overview.lines = 3;
            _title.label = title;
            _overview.label = message;
            rebuild_dots();
        }

        private async void load_art(Cancellable cancellable) {
            var catalog = Streaming.Catalog.get_default();
            for (int i = 0; i < _titles.length; i++) {
                var t = _titles[(_index + i) % _titles.length];
                if (t.backdrop_uri == null || _art.contains(t.backdrop_uri)) continue;
                var tex = yield catalog.image(t.backdrop_uri, _art_width, _art_height, cancellable);
                if (cancellable.is_cancelled()) return;
                if (tex == null) continue;
                _art.insert(t.backdrop_uri, tex);
                if (current() == t) _picture.paintable = tex;
            }
        }

        private void show_index(int index) {
            if (_titles.length == 0) return;
            _index = (index + _titles.length) % _titles.length;
            render();
            restart_rotation();
        }

        private void render() {
            var t = current();
            if (t == null) return;
            _title.label = t.name;
            _overview.label = t.overview;
            _picture.paintable = t.backdrop_uri != null ? _art.lookup(t.backdrop_uri) : null;
            _picture.alternative_text = t.name;
            int i = 0;
            for (var dot = _dots.get_first_child(); dot != null; dot = dot.get_next_sibling()) {
                if (i++ == _index) dot.add_css_class("active");
                else dot.remove_css_class("active");
            }
        }

        private void rebuild_dots() {
            Widget? w;
            while ((w = _dots.get_first_child()) != null) _dots.remove(w);
            _dots.visible = _titles.length > 1;
            for (int i = 0; i < _titles.length; i++) {
                var dot = new Box(Orientation.HORIZONTAL, 0);
                dot.add_css_class("tv-hero-dot");
                dot.valign = Align.CENTER;
                _dots.append(dot);
            }
        }

        private void start_rotation() {
            if (_rotate != 0) return;
            _rotate = Timeout.add_seconds(ROTATE_SECONDS, () => {
                if (_titles.length > 1 && !has_focus_within()) show_index(_index + 1);
                return Source.CONTINUE;
            });
        }

        private void stop_rotation() {
            if (_rotate == 0) return;
            Source.remove(_rotate);
            _rotate = 0;
        }

        private void restart_rotation() {
            if (_rotate == 0) return;
            stop_rotation();
            start_rotation();
        }

        private bool has_focus_within() {
            var root = get_root() as Gtk.Window;
            var focus = root != null ? root.get_focus() : null;
            return focus != null && focus.is_ancestor(this);
        }

        public override void dispose() {
            stop_rotation();
            if (_loading != null) _loading.cancel();
            base.dispose();
        }
    }

    internal class TvWatchCard : Button {
        public const int WIDTH = 400;
        public const int HEIGHT = 162;
        public const int LOGO = 24;

        public Streaming.WatchEntry entry { get; construct; }

        private Picture _art;
        private Image _logo;
        private int _scale;

        public TvWatchCard(Streaming.WatchEntry entry, int scale) {
            Object(entry: entry);
            _scale = scale;
            add_css_class("tv-watch-card");
            focusable = true;
            update_property(Gtk.AccessibleProperty.LABEL, entry.title.name, -1);
            var stage = new Overlay();
            stage.add_css_class("tv-watch-stage");
            stage.overflow = Overflow.HIDDEN;
            var frame = new Box(Orientation.VERTICAL, 0);
            frame.set_size_request(WIDTH, HEIGHT);
            stage.child = frame;
            _art = new Picture();
            _art.content_fit = ContentFit.COVER;
            _art.can_shrink = true;
            stage.add_overlay(_art);
            var scrim = new Box(Orientation.VERTICAL, 0);
            scrim.add_css_class("tv-watch-scrim");
            stage.add_overlay(scrim);
            var name = new Label(entry.title.name);
            name.add_css_class("tv-watch-title");
            name.halign = Align.START;
            name.valign = Align.CENTER;
            name.xalign = 0;
            name.wrap = true;
            name.lines = 2;
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 12;
            stage.add_overlay(name);
            var offer = entry.offer();
            var service = new Box(Orientation.HORIZONTAL, 8);
            service.add_css_class("tv-watch-service");
            service.halign = Align.END;
            service.valign = Align.START;
            _logo = new Image();
            _logo.add_css_class("tv-watch-service-logo");
            _logo.pixel_size = LOGO;
            _logo.overflow = Overflow.HIDDEN;
            _logo.visible = false;
            service.append(_logo);
            var service_name = new Label(offer != null ? offer.platform.name : "");
            service_name.add_css_class("tv-watch-service-name");
            service.append(service_name);
            service.visible = offer != null;
            stage.add_overlay(service);
            child = stage;
            load.begin();
        }

        private async void load() {
            var catalog = Streaming.Catalog.get_default();
            if (entry.title.backdrop_uri != null) {
                var tex = yield catalog.image(entry.title.backdrop_uri, WIDTH * _scale, HEIGHT * _scale);
                if (tex != null) _art.paintable = tex;
            }
            var offer = entry.offer();
            if (offer != null && offer.logo_uri != null) {
                var tex = yield catalog.image(offer.logo_uri, LOGO * _scale, LOGO * _scale);
                if (tex != null) {
                    _logo.paintable = tex;
                    _logo.visible = true;
                }
            }
        }
    }

    internal class TvTitleSheet : Box {
        public signal void open_offer(Streaming.Title title, Streaming.Offer offer);
        public signal void closed();

        private Picture _art;
        private Label _title;
        private Label _meta;
        private Label _overview;
        private Label _where;
        private Box _offers;
        private Streaming.Title? _shown = null;
        private int _art_width;
        private int _art_height;
        private int _scale;

        public TvTitleSheet(int width, int height, int scale) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("tv-sheet");
            visible = false;
            _art_width = width * scale;
            _art_height = height * scale;
            _scale = scale;
            var stage = new Overlay();
            stage.vexpand = true;
            _art = new Picture();
            _art.content_fit = ContentFit.COVER;
            _art.can_shrink = true;
            stage.child = _art;
            var scrim = new Box(Orientation.VERTICAL, 0);
            scrim.add_css_class("tv-sheet-scrim");
            stage.add_overlay(scrim);
            var text = new Box(Orientation.VERTICAL, 0);
            text.add_css_class("tv-sheet-text");
            text.halign = Align.START;
            text.valign = Align.CENTER;
            _title = new Label("");
            _title.add_css_class("tv-hero-title");
            _title.xalign = 0;
            _title.wrap = true;
            _title.max_width_chars = 28;
            text.append(_title);
            _meta = new Label("");
            _meta.add_css_class("tv-sheet-meta");
            _meta.xalign = 0;
            text.append(_meta);
            _overview = new Label("");
            _overview.add_css_class("tv-hero-overview");
            _overview.xalign = 0;
            _overview.wrap = true;
            _overview.wrap_mode = Pango.WrapMode.WORD_CHAR;
            _overview.max_width_chars = 60;
            _overview.width_chars = 60;
            text.append(_overview);
            _where = new Label(_("Available on"));
            _where.add_css_class("tv-home-section");
            _where.xalign = 0;
            text.append(_where);
            _offers = new Box(Orientation.HORIZONTAL, 20);
            text.append(_offers);
            stage.add_overlay(text);
            append(stage);
        }

        public void show_title(Streaming.Title title) {
            _shown = title;
            _title.label = title.name;
            string kind = title.kind == Streaming.TitleKind.SERIES ? _("Series") : _("Film");
            _meta.label = title.year > 0 ? "%d · %s".printf(title.year, kind) : kind;
            _overview.label = title.overview;
            _art.paintable = null;
            Widget? w;
            while ((w = _offers.get_first_child()) != null) _offers.remove(w);
            foreach (var offer in title.offers) _offers.append(offer_button(title, offer));
            if (title.offers.length == 0) _where.label = _("Not available on your streaming apps in this region");
            else _where.label = _("Available on");
            visible = true;
            var first = _offers.get_first_child();
            if (first != null) first.grab_focus();
            load_art.begin(title);
        }

        private async void load_art(Streaming.Title title) {
            if (title.backdrop_uri == null) return;
            var tex = yield Streaming.Catalog.get_default().image(title.backdrop_uri, _art_width, _art_height);
            if (tex != null && _shown == title) _art.paintable = tex;
        }

        private Button offer_button(Streaming.Title title, Streaming.Offer offer) {
            var box = new Box(Orientation.HORIZONTAL, 14);
            var logo = new Image();
            logo.add_css_class("tv-watch-logo");
            logo.pixel_size = TvWatchCard.LOGO;
            logo.overflow = Overflow.HIDDEN;
            box.append(logo);
            var text = new Box(Orientation.VERTICAL, 2);
            text.valign = Align.CENTER;
            var name = new Label(offer.platform.name);
            name.add_css_class("tv-sheet-offer-name");
            name.xalign = 0;
            text.append(name);
            var hint = new Label(offer.platform.installed ? _("Open") : _("Get in Store"));
            hint.add_css_class("tv-sheet-offer-hint");
            hint.xalign = 0;
            text.append(hint);
            box.append(text);
            var button = new Button();
            button.child = box;
            button.add_css_class("tv-sheet-offer");
            button.update_property(Gtk.AccessibleProperty.LABEL, offer.platform.name, -1);
            button.clicked.connect(() => open_offer(title, offer));
            if (offer.logo_uri != null) {
                Streaming.Catalog.get_default().image.begin(offer.logo_uri, TvWatchCard.LOGO * _scale, TvWatchCard.LOGO * _scale, null, (obj, res) => {
                    var tex = Streaming.Catalog.get_default().image.end(res);
                    if (tex != null) logo.paintable = tex;
                });
            }
            return button;
        }

        public void dismiss() {
            if (!visible) return;
            visible = false;
            _shown = null;
            closed();
        }
    }

    public class TvHome : Gtk.Window {
        private const int APP_SLOTS = 6;
        private const int TILE_WIDTH = 222;
        private const int TILE_HEIGHT = 126;
        private const int FOLDER_WIDTH = 150;
        private const int TILE_ICON = 72;
        private const int GUTTER = 88;
        private const string FOLDER = "::apps";
        private const string[] TV_CATEGORIES = {
            "AudioVideo", "Audio", "Video", "Music", "TV", "Player", "Game", "WebBrowser", "Photography", "PackageManager",
            "Maps", "Calculator", "Documentation", "News", "Feed", "Viewer", "Weather", "Clock", "Education"
        };
        private const string[] EDITOR_CATEGORIES = { "AudioVideoEditing", "Sequencer", "Mixer" };
        private const string FORM_FACTORS_KEY = "X-Sinty-FormFactors";

        private FlowBox _apps;
        private Box _watching;
        private Label _watching_title;
        private ScrolledWindow _watching_scroll;
        private TvHero _hero;
        private TvTitleSheet _sheet;
        private Box _page;
        private Label _greeting;
        private Label _clock;
        private Widget? _sheet_return = null;
        private unowned Gdk.Monitor _monitor;
        private TvSettings? _settings_screen = null;
        private TvAppsFolder? _folder = null;
        private ulong _sig_clock = 0;
        private ulong _sig_apps = 0;
        private ulong _sig_pinned = 0;
        private ulong _sig_featured = 0;
        private ulong _sig_history = 0;
        private ulong _sig_state = 0;
        private bool _owns_keyboard = false;
        private int64 _released_at = 0;

        public TvHome(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            _monitor = monitor;
            set_namespace(this, "singularity-tv-home");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("tv-home");
            notify["focus-visible"].connect(() => {
                if (!focus_visible) focus_visible = true;
            });

            _page = new Box(Orientation.VERTICAL, 0);
            _page.add_css_class("tv-home-main");
            var head = new Box(Orientation.HORIZONTAL, 0);
            head.add_css_class("tv-home-head");
            head.margin_start = GUTTER;
            head.margin_end = GUTTER;
            _greeting = new Label(greeting());
            _greeting.add_css_class("tv-home-title");
            _greeting.hexpand = true;
            _greeting.xalign = 0;
            _clock = new Label("");
            _clock.add_css_class("tv-home-clock");
            var gear_icon = new Image.from_icon_name(TvSettings.SETTINGS_ICON);
            gear_icon.pixel_size = 48;
            var gear = new Button();
            gear.child = gear_icon;
            gear.add_css_class("tv-home-gear");
            gear.tooltip_text = _("Settings");
            gear.update_property(Gtk.AccessibleProperty.LABEL, _("Settings"), -1);
            gear.valign = Align.CENTER;
            gear.clicked.connect(() => open_settings());
            head.append(_greeting);
            head.append(_clock);
            head.append(gear);
            _page.append(head);

            var body = new Box(Orientation.VERTICAL, 0);
            body.valign = Align.START;
            var area = monitor.geometry;
            _hero = new TvHero(area.width - 2 * GUTTER, monitor.scale_factor);
            _hero.margin_start = GUTTER;
            _hero.margin_end = GUTTER;
            _hero.watch.connect((t) => open_title(t, null));
            _hero.details.connect((t) => show_details(t));
            body.append(_hero);

            body.append(section_label(_("Apps")));
            _apps = new FlowBox();
            _apps.add_css_class("tv-app-row");
            _apps.selection_mode = SelectionMode.NONE;
            _apps.homogeneous = false;
            _apps.min_children_per_line = APP_SLOTS + 1;
            _apps.max_children_per_line = APP_SLOTS + 1;
            _apps.column_spacing = 24;
            _apps.activate_on_single_click = true;
            _apps.halign = Align.START;
            _apps.margin_start = GUTTER - 8;
            _apps.margin_end = GUTTER - 8;
            _apps.child_activated.connect((child) => activate_tile(child));
            _apps.keynav_failed.connect((direction) => direction == DirectionType.LEFT || direction == DirectionType.RIGHT);
            var rows = new EventControllerKey();
            rows.propagation_phase = PropagationPhase.CAPTURE;
            rows.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Up) return _hero.focus_primary();
                if (keyval != Gdk.Key.Down || !_watching_scroll.visible) return false;
                var card = nearest(_watching);
                return card != null && card.grab_focus();
            });
            _apps.add_controller(rows);
            body.append(_apps);

            _watching_title = section_label(_("Continue watching"));
            body.append(_watching_title);
            _watching = new Box(Orientation.HORIZONTAL, 32);
            _watching.add_css_class("tv-watch-row");
            _watching.margin_start = GUTTER;
            _watching.margin_end = GUTTER;
            _watching_scroll = new ScrolledWindow();
            _watching_scroll.hscrollbar_policy = PolicyType.EXTERNAL;
            _watching_scroll.vscrollbar_policy = PolicyType.NEVER;
            _watching_scroll.propagate_natural_height = true;
            _watching_scroll.child = _watching;
            var edges = new EventControllerKey();
            edges.key_pressed.connect((keyval, code, state) => {
                var focus = get_focus();
                if (keyval == Gdk.Key.Left) return focus != null && focus == _watching.get_first_child();
                if (keyval == Gdk.Key.Right) return focus != null && focus == _watching.get_last_child();
                if (keyval == Gdk.Key.Up) {
                    var tile = nearest(_apps);
                    return tile != null && tile.grab_focus();
                }
                return false;
            });
            _watching_scroll.add_controller(edges);
            body.append(_watching_scroll);

            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vscrollbar_policy = PolicyType.EXTERNAL;
            scroll.vexpand = true;
            scroll.child = body;
            _page.append(scroll);

            _sheet = new TvTitleSheet(area.width, area.height, monitor.scale_factor);
            _sheet.open_offer.connect((t, o) => open_title(t, o));
            _sheet.closed.connect(() => {
                _page.visible = true;
                if (_sheet_return != null && _sheet_return.get_mapped()) _sheet_return.grab_focus();
                else focus_first();
                _sheet_return = null;
            });
            var root = new Overlay();
            root.child = _page;
            root.add_overlay(_sheet);
            set_child(root);

            var keys = new EventControllerKey();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect((keyval, code, state) => {
                if (!_sheet.visible) return false;
                if (keyval != Gdk.Key.Escape && keyval != Gdk.Key.BackSpace) return false;
                _sheet.dismiss();
                return true;
            });
            ((Widget) this).add_controller(keys);

            notify["focus-widget"].connect(() => {
                var focus = get_focus();
                if (focus == null || !focus.is_ancestor(body)) return;
                if (!focus.is_ancestor(_hero) && !focus.is_ancestor(_apps)) return;
                Idle.add(() => {
                    scroll.vadjustment.value = 0;
                    return Source.REMOVE;
                });
            });

            var app_system = AppSystem.get_default();
            _sig_apps = app_system.apps_changed.connect(() => fill_apps());
            _sig_pinned = app_system.config_changed.connect((key) => {
                if (key == "pinned-apps") fill_apps();
            });
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            var catalog = Streaming.Catalog.get_default();
            _sig_featured = catalog.featured_changed.connect(() => fill_hero());
            _sig_state = catalog.notify["state"].connect(() => fill_hero());
            _sig_history = catalog.history_changed.connect(() => fill_watching());
            update_clock();
            fill_apps();
            fill_hero();
            fill_watching();
            catalog.refresh();
        }

        public override void dispose() {
            var app_system = AppSystem.get_default();
            var catalog = Streaming.Catalog.get_default();
            if (_sig_apps != 0) { app_system.disconnect(_sig_apps); _sig_apps = 0; }
            if (_sig_pinned != 0) { app_system.disconnect(_sig_pinned); _sig_pinned = 0; }
            if (_sig_clock != 0) { SharedClock.get_default().disconnect(_sig_clock); _sig_clock = 0; }
            if (_sig_featured != 0) { catalog.disconnect(_sig_featured); _sig_featured = 0; }
            if (_sig_state != 0) { catalog.disconnect(_sig_state); _sig_state = 0; }
            if (_sig_history != 0) { catalog.disconnect(_sig_history); _sig_history = 0; }
            if (_settings_screen != null) { _settings_screen.destroy(); _settings_screen = null; }
            if (_folder != null) { _folder.destroy(); _folder = null; }
            base.dispose();
        }

        public void open_settings() {
            var shell = application as SingularityApp;
            if (shell == null) return;
            if (_settings_screen == null) {
                _settings_screen = new TvSettings(shell, _monitor);
                _settings_screen.dismissed.connect(() => focus_first());
            }
            _settings_screen.open();
        }

        public void open_folder() {
            var app = application;
            if (app == null) return;
            if (_folder == null) {
                _folder = new TvAppsFolder(app, _monitor);
                _folder.dismissed.connect(() => {
                    var last = _apps.get_last_child() as FlowBoxChild;
                    if (last != null) last.grab_focus();
                });
            }
            _folder.open();
        }

        public void play_enter() {
            Widget[] tiles = {};
            for (var c = _apps.get_first_child(); c != null; c = c.get_next_sibling()) {
                var bin = tile_motion(c);
                if (bin != null) tiles += bin;
            }
            Singularity.Motion.cascade(tiles, Singularity.Motion.Preset.SCALE_FADE);
        }

        private static string greeting() {
            int h = new DateTime.now_local().get_hour();
            if (h < 12) return _("Good morning");
            if (h < 18) return _("Good afternoon");
            return _("Good evening");
        }

        private Label section_label(string text) {
            var l = new Label(text);
            l.add_css_class("tv-home-section");
            l.xalign = 0;
            l.margin_start = GUTTER;
            l.margin_end = GUTTER;
            return l;
        }

        internal static FlowBox new_row() {
            var row = new FlowBox();
            row.add_css_class("tv-home-row");
            row.add_css_class("tv-app-row");
            row.selection_mode = SelectionMode.NONE;
            row.homogeneous = true;
            row.min_children_per_line = 3;
            row.max_children_per_line = 6;
            row.column_spacing = 32;
            row.row_spacing = 24;
            row.activate_on_single_click = true;
            return row;
        }

        public bool recently_released() {
            return GLib.get_monotonic_time() - _released_at < 5 * TimeSpan.SECOND;
        }

        private void release_keyboard() {
            _released_at = GLib.get_monotonic_time();
            own_keyboard(false);
        }

        private void activate_tile(FlowBoxChild child) {
            var action = child.get_data<string>("tv-action");
            if (action == FOLDER) {
                open_folder();
                return;
            }
            if (action == null) return;
            var info = new GLib.DesktopAppInfo(action);
            if (info == null) return;
            release_keyboard();
            AppSystem.launch_app(info);
        }

        private void open_title(Streaming.Title title, Streaming.Offer? chosen) {
            var offer = chosen ?? title.best_offer();
            if (offer == null) {
                show_details(title);
                return;
            }
            var link = Singularity.AppLinks.resolve(offer.platform.app_id, offer.link());
            if (link == null) {
                show_details(title);
                return;
            }
            if (!link.in_store) Streaming.Catalog.get_default().record(title, offer.platform);
            _sheet.dismiss();
            release_keyboard();
            AppSystem.launch_app(link.app, link.files());
        }

        private void show_details(Streaming.Title title) {
            _sheet_return = get_focus();
            _page.visible = false;
            _sheet.show_title(title);
        }

        private static Singularity.Animation.MotionBin? tile_motion(Widget child) {
            var flow_child = child as FlowBoxChild;
            return flow_child != null ? flow_child.child as Singularity.Animation.MotionBin : null;
        }

        internal static FlowBoxChild tile(GLib.Icon? icon, string icon_name, string label, bool folder = false) {
            var box = new Box(Orientation.VERTICAL, 12);
            box.add_css_class("tv-app-tile");
            var art = new Box(Orientation.VERTICAL, 6);
            art.add_css_class("tv-app-art");
            art.set_size_request(folder ? FOLDER_WIDTH : TILE_WIDTH, TILE_HEIGHT);
            art.halign = Align.CENTER;
            var image = new Image();
            if (icon != null) image.gicon = icon;
            else image.icon_name = icon_name;
            image.pixel_size = folder ? 40 : TILE_ICON;
            image.vexpand = true;
            image.valign = Align.CENTER;
            art.append(image);
            var name = new Label(label);
            name.add_css_class("tv-tile-label");
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 18;
            if (folder) {
                art.add_css_class("folder");
                image.vexpand = false;
                image.valign = Align.END;
                image.margin_top = 22;
                name.add_css_class("tv-folder-label");
                art.append(name);
            } else {
                art.add_css_class(TvTints.class_for(icon ?? new ThemedIcon(icon_name)));
            }
            box.append(art);
            if (!folder) box.append(name);
            var motion = new Singularity.Animation.MotionBin(box);
            var child = new FlowBoxChild();
            child.child = motion;
            child.focusable = true;
            child.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            return child;
        }

        private void fill_apps() {
            Widget? w;
            while ((w = _apps.get_first_child()) != null) _apps.remove(w);
            var settings = new GLib.Settings("dev.sinty.desktop");
            var shown = new GenericSet<string>(str_hash, str_equal);
            var picks = new GLib.List<GLib.DesktopAppInfo>();
            foreach (string id in settings.get_strv("pinned-apps")) {
                var info = new GLib.DesktopAppInfo(id);
                if (info == null || !info.should_show() || !pinned_for_tv(info)) continue;
                shown.add(id);
                picks.append(info);
            }
            var rest = new GLib.List<GLib.DesktopAppInfo>();
            foreach (var app in GLib.AppInfo.get_all()) {
                var info = app as GLib.DesktopAppInfo;
                if (info == null || info.get_id() == null || shown.contains(info.get_id())) continue;
                if (!info.should_show() || !for_tv(info)) continue;
                rest.append(info);
            }
            rest.sort((a, b) => a.get_display_name().collate(b.get_display_name()));
            foreach (var info in rest) picks.append(info);
            int n = 0;
            foreach (var info in picks) {
                if (n++ >= APP_SLOTS) break;
                var child = tile(info.get_icon(), "application-x-executable", info.get_display_name());
                child.set_data<string>("tv-action", info.get_id());
                _apps.append(child);
            }
            var folder = tile(new ThemedIcon("view-app-grid-symbolic"), "view-app-grid-symbolic", _("All Apps"), true);
            folder.set_data<string>("tv-action", FOLDER);
            _apps.append(folder);
        }

        private static bool pinned_for_tv(GLib.DesktopAppInfo info) {
            if (!info.has_key(FORM_FACTORS_KEY)) return true;
            return for_tv(info);
        }

        private static bool for_tv(GLib.DesktopAppInfo info) {
            if (info.has_key(FORM_FACTORS_KEY)) {
                foreach (string id in info.get_string(FORM_FACTORS_KEY).split(";")) {
                    if (id.strip().down() == "tv") return true;
                }
                return false;
            }
            string? cats = info.get_categories();
            if (cats == null) return false;
            bool media = false;
            foreach (string c in cats.split(";")) {
                if (c in EDITOR_CATEGORIES) return false;
                if (c in TV_CATEGORIES) media = true;
            }
            return media;
        }

        private void fill_hero() {
            var catalog = Streaming.Catalog.get_default();
            if (catalog.featured.length > 0) {
                if (!_hero.has_titles || _hero.current() == null || !same_titles(catalog.featured)) _hero.show_titles(catalog.featured);
                return;
            }
            switch (catalog.state) {
                case Streaming.CatalogState.OFFLINE:
                    _hero.show_message(_("Films and series are not available right now"),
                        _("Check your internet connection. Your apps are still here."));
                    break;
                default:
                    _hero.show_message("", "");
                    break;
            }
        }

        private bool same_titles(GenericArray<Streaming.Title> titles) {
            var current = _hero.current();
            return current != null && titles.length > 0 && titles[0] == current;
        }

        private Widget? nearest(Widget row) {
            var focus = get_focus();
            if (focus == null) return row.get_first_child();
            Graphene.Rect from;
            if (!focus.compute_bounds(this, out from)) return row.get_first_child();
            float x = from.get_x() + from.get_width() / 2;
            Widget? best = null;
            float best_distance = float.MAX;
            for (var c = row.get_first_child(); c != null; c = c.get_next_sibling()) {
                Graphene.Rect b;
                if (!c.compute_bounds(this, out b)) continue;
                float d = Math.fabsf(b.get_x() + b.get_width() / 2 - x);
                if (d < best_distance) {
                    best_distance = d;
                    best = c;
                }
            }
            return best;
        }

        private void fill_watching() {
            Widget? w;
            while ((w = _watching.get_first_child()) != null) _watching.remove(w);
            int n = 0;
            foreach (var entry in Streaming.Catalog.get_default().history) {
                var card = new TvWatchCard(entry, _monitor.scale_factor);
                card.clicked.connect(() => {
                    var offer = card.entry.offer();
                    open_title(card.entry.title, offer);
                });
                _watching.append(card);
                n++;
            }
            _watching_title.visible = n > 0;
            _watching_scroll.visible = n > 0;
        }

        private void update_clock() {
            var now = new DateTime.now_local();
            _clock.label = now.format("%H:%M");
            _greeting.label = greeting();
        }

        public void focus_first() {
            var first = _apps.get_child_at_index(0);
            if (first != null) first.grab_focus();
            focus_visible = true;
        }

        public void own_keyboard(bool own) {
            if (_owns_keyboard == own) return;
            _owns_keyboard = own;
            set_keyboard_mode(this, own ? GtkLayerShell.KeyboardMode.EXCLUSIVE : GtkLayerShell.KeyboardMode.ON_DEMAND);
        }
    }
}
