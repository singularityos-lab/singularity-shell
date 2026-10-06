using Gtk;
using Singularity.Widgets;

namespace Singularity {

    [CCode (cname = "pango_font_map_add_font_file")]
    private extern bool preview_font_map_add_font_file(Pango.FontMap map, string filename) throws GLib.Error;

    public class PreviewDialog : Singularity.Shell.ShellDialog {
        private const string FILES_ID = "dev.sinty.files";
        private const int STAGE_MAX_W = 880;
        private const int STAGE_MAX_H = 580;
        private const int STAGE_MIN_W = 480;
        private const int STAGE_MIN_H = 320;
        private const int DOC_W = 640;
        private const int DOC_H = 420;
        private const int CONTROLS_H = 54;
        private const int TEXT_LIMIT = 256 * 1024;
        private const int FOLDER_SCAN_LIMIT = 20000;
        private const string ATTRIBUTES = "standard::*,time::modified,access::can-read";

        private string[] uris = {};
        private int index = 0;
        private string origin = "";
        private File? file = null;
        private FileInfo? info = null;
        private string content_type = "application/octet-stream";
        private uint generation = 0;
        private Cancellable? cancellable = null;
        private int stage_w = 0;
        private int stage_h = 0;

        private Label title_label;
        private Button prev_button;
        private Button next_button;
        private Box stage;
        private Label facts_label;
        private Button copy_button;
        private Button reveal_button;
        private Button open_button;
        private Button open_menu_button;
        private AppInfo? default_app = null;
        private GLib.List<AppInfo> other_apps = new GLib.List<AppInfo>();

        private MediaView? media_view = null;
        private PreviewZoomImage? zoom_image = null;
        private LiveTextSession? live_text = null;
        private Poppler.Document? pdf_document = null;
        private int pdf_page = 0;
        private Picture? pdf_picture = null;
        private Label? pdf_counter = null;
        private uint copied_reset_id = 0;

        private static bool css_installed = false;

        public string? current_uri {
            get { return uris.length > 0 ? uris[index] : null; }
        }

        public PreviewDialog(Gtk.Application app) {
            Object(application: app, card: true);
        }

        construct {
            install_css();
            add_css_class("quicklook");
            set_default_size(1, 1);
            title = _("Quick Look");

            var titlebar = new CenterBox();
            titlebar.add_css_class("dialog-titlebar");
            var nav = new Box(Orientation.HORIZONTAL, 6);
            prev_button = new Button.from_icon_name("go-previous-symbolic");
            prev_button.tooltip_text = _("Previous File");
            prev_button.valign = Align.CENTER;
            prev_button.clicked.connect(() => step(-1));
            next_button = new Button.from_icon_name("go-next-symbolic");
            next_button.tooltip_text = _("Next File");
            next_button.valign = Align.CENTER;
            next_button.clicked.connect(() => step(1));
            nav.append(prev_button);
            nav.append(next_button);
            titlebar.start_widget = nav;
            title_label = new Label("");
            title_label.add_css_class("title");
            title_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            title_label.max_width_chars = 48;
            titlebar.center_widget = title_label;
            var close_button = new CloseButton();
            close_button.valign = Align.CENTER;
            close_button.clicked.connect(() => close_dialog());
            titlebar.end_widget = close_button;
            content_box.append(titlebar);

            stage = new Box(Orientation.VERTICAL, 0);
            stage.add_css_class("quicklook-stage");
            stage.overflow = Overflow.HIDDEN;
            stage.halign = Align.CENTER;
            stage.margin_start = 20;
            stage.margin_end = 20;
            stage.margin_top = 4;
            content_box.append(stage);

            var footer = new Box(Orientation.HORIZONTAL, 8);
            footer.margin_start = 20;
            footer.margin_end = 20;
            footer.margin_top = 16;
            footer.margin_bottom = 20;
            facts_label = new Label("");
            facts_label.add_css_class("quicklook-facts");
            facts_label.hexpand = true;
            facts_label.xalign = 0;
            facts_label.ellipsize = Pango.EllipsizeMode.END;
            footer.append(facts_label);
            copy_button = new Button.with_label(_("Copy"));
            copy_button.add_css_class("pill");
            copy_button.clicked.connect(copy_file);
            footer.append(copy_button);
            reveal_button = new Button.with_label(_("Show in Files"));
            reveal_button.add_css_class("pill");
            reveal_button.clicked.connect(reveal_file);
            footer.append(reveal_button);
            var open_group = new Box(Orientation.HORIZONTAL, 4);
            open_button = new Button.with_label(_("Open"));
            open_button.add_css_class("pill");
            open_button.add_css_class("suggested-action");
            open_button.clicked.connect(() => open_with(default_app));
            open_group.append(open_button);
            open_menu_button = new Button.from_icon_name("pan-down-symbolic");
            open_menu_button.tooltip_text = _("Open With Another App");
            open_menu_button.valign = Align.CENTER;
            open_menu_button.clicked.connect(show_open_menu);
            open_group.append(open_menu_button);
            footer.append(open_group);
            content_box.append(footer);

            var keys = new EventControllerKey();
            keys.set_propagation_phase(PropagationPhase.CAPTURE);
            keys.key_pressed.connect(on_key_pressed);
            ((Widget) this).add_controller(keys);
        }

        public void show_files(string[] uris, int index, string origin) {
            bool was_visible = visible;
            this.uris = uris;
            this.index = index.clamp(0, uris.length - 1);
            this.origin = origin;
            if (!was_visible) {
                stage_w = 0;
                stage_h = 0;
            }
            load_current();
            present();
        }

        public override void close_dialog() {
            generation++;
            if (cancellable != null) cancellable.cancel();
            set_focus(null);
            clear_stage();
            base.close_dialog();
        }

        private bool on_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (get_focus() is Editable && keyval != Gdk.Key.Escape) return false;
            switch (keyval) {
                case Gdk.Key.space:
                case Gdk.Key.Escape:
                    close_dialog();
                    return true;
                case Gdk.Key.Left:
                case Gdk.Key.Up:
                    step(-1);
                    return true;
                case Gdk.Key.Right:
                case Gdk.Key.Down:
                    step(1);
                    return true;
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                    open_with(default_app);
                    return true;
                case Gdk.Key.Page_Up:
                    return show_pdf_page(pdf_page - 1);
                case Gdk.Key.Page_Down:
                    return show_pdf_page(pdf_page + 1);
                default:
                    return false;
            }
        }

        private void step(int delta) {
            int target = index + delta;
            if (target < 0 || target >= uris.length) return;
            index = target;
            load_current();
        }

        private void load_current() {
            generation++;
            uint gen = generation;
            if (cancellable != null) cancellable.cancel();
            cancellable = new Cancellable();
            clear_stage();
            file = File.new_for_uri(uris[index]);
            info = null;
            title_label.label = file.get_basename() ?? uris[index];
            facts_label.label = "";
            prev_button.visible = uris.length > 1;
            next_button.visible = uris.length > 1;
            prev_button.sensitive = index > 0;
            next_button.sensitive = index < uris.length - 1;
            reveal_button.visible = origin != FILES_ID && file.get_parent() != null;
            file.query_info_async.begin(ATTRIBUTES, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable, (obj, res) => {
                if (gen != generation) return;
                try {
                    info = file.query_info_async.end(res);
                } catch (Error e) {
                    show_missing(e.message);
                    return;
                }
                populate(gen);
            });
        }

        private void populate(uint gen) {
            title_label.label = info.get_display_name();
            content_type = info.get_content_type() ?? "application/octet-stream";
            string mime = ContentType.get_mime_type(content_type) ?? content_type;
            facts_label.label = summary();
            setup_open_with();

            if (info.get_file_type() == FileType.DIRECTORY) {
                show_folder(gen);
            } else if (mime.has_prefix("image/")) {
                show_image(gen, mime);
            } else if (mime.has_prefix("video/")) {
                show_media(gen, true);
            } else if (mime.has_prefix("audio/")) {
                show_media(gen, false);
            } else if (mime == "application/pdf" || mime == "application/x-pdf") {
                show_pdf(gen);
            } else if (is_font(mime)) {
                show_font();
            } else if (ContentType.is_a(content_type, "text/plain")) {
                show_text.begin(gen);
            } else {
                show_generic();
            }
        }

        private static bool is_font(string mime) {
            return mime.has_prefix("font/") || mime == "application/x-font-ttf"
                || mime == "application/x-font-otf" || mime == "application/vnd.ms-opentype"
                || mime == "application/x-font-type1";
        }

        private string summary() {
            if (info.get_file_type() == FileType.DIRECTORY) return _("Folder");
            return "%s, %s".printf(ContentType.get_description(content_type), format_size(info.get_size()));
        }

        private void clear_stage() {
            var focused = get_focus();
            if (focused != null && focused.is_ancestor(stage)) set_focus(null);
            if (media_view != null) media_view.playback.stop();
            if (zoom_image != null) zoom_image.stop();
            zoom_image = null;
            live_text = null;
            pdf_document = null;
            pdf_picture = null;
            pdf_counter = null;
            stage.remove_css_class("bare");
            Widget? child = stage.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                stage.remove(child);
                child = next;
            }
        }

        private void set_stage_child(Widget child, bool bare = false) {
            Widget? old = stage.get_first_child();
            while (old != null) {
                var next = old.get_next_sibling();
                stage.remove(old);
                old = next;
            }
            if (bare) stage.add_css_class("bare"); else stage.remove_css_class("bare");
            child.hexpand = true;
            child.vexpand = true;
            stage.append(child);
        }

        private void stage_limits(out int max_w, out int max_h) {
            max_w = STAGE_MAX_W;
            max_h = STAGE_MAX_H;
            var display = get_display();
            Gdk.Monitor? monitor = null;
            var surface = get_surface();
            if (surface != null) monitor = display.get_monitor_at_surface(surface);
            if (monitor == null && display.get_monitors().get_n_items() > 0) {
                monitor = (Gdk.Monitor) display.get_monitors().get_item(0);
            }
            if (monitor != null) {
                var geometry = monitor.geometry;
                max_w = int.min(max_w, geometry.width - 160);
                max_h = int.min(max_h, geometry.height - 220);
            }
            max_w = int.max(max_w, STAGE_MIN_W);
            max_h = int.max(max_h, STAGE_MIN_H);
        }

        private void fit_stage(double width, double height, int extra_h = 0) {
            int max_w, max_h;
            stage_limits(out max_w, out max_h);
            double avail_h = max_h - extra_h;
            double scale = double.min(1.0, double.min(max_w / width, avail_h / height));
            set_stage_size((int) Math.round(width * scale), (int) Math.round(height * scale) + extra_h);
        }

        private void set_stage_size(int width, int height) {
            int max_w, max_h;
            stage_limits(out max_w, out max_h);
            int w = width.clamp(STAGE_MIN_W, max_w);
            int h = height.clamp(STAGE_MIN_H, max_h);
            stage_w = int.max(stage_w, w);
            stage_h = int.max(stage_h, h);
            stage.set_size_request(stage_w, stage_h);
        }

        private void show_missing(string message) {
            set_stage_size(DOC_W, DOC_H);
            var page = new Box(Orientation.VERTICAL, 12);
            page.valign = Align.CENTER;
            page.halign = Align.CENTER;
            var icon = new Image.from_icon_name("dialog-warning");
            icon.pixel_size = 96;
            page.append(icon);
            var label = new Label(_("This file cannot be previewed"));
            label.add_css_class("title-3");
            page.append(label);
            var detail = new Label(message);
            detail.add_css_class("dim-label");
            detail.wrap = true;
            detail.max_width_chars = 48;
            detail.justify = Justification.CENTER;
            page.append(detail);
            set_stage_child(page);
            open_button.sensitive = false;
            open_menu_button.visible = false;
        }

        private void show_image(uint gen, string mime) {
            string? path = file.get_path();
            int width = 0;
            int height = 0;
            if (path != null) Gdk.Pixbuf.get_file_info(path, out width, out height);
            if (width > 0 && height > 0) fit_stage(width, height); else set_stage_size(DOC_W, DOC_H);

            var viewer = new PreviewZoomImage();
            zoom_image = viewer;
            var overlay = new Overlay();
            overlay.child = viewer;
            var fit_button = new Button.from_icon_name("zoom-original-symbolic");
            fit_button.tooltip_text = _("Actual Size");
            fit_button.add_css_class("flat");
            fit_button.add_css_class("singularity-hover-btn");
            fit_button.halign = Align.END;
            fit_button.valign = Align.START;
            fit_button.margin_top = 10;
            fit_button.margin_end = 10;
            fit_button.clicked.connect(() => viewer.toggle_actual_size());
            viewer.zoom_changed.connect(() => {
                fit_button.icon_name = viewer.actual_size ? "zoom-fit-best-symbolic" : "zoom-original-symbolic";
                fit_button.tooltip_text = viewer.actual_size ? _("Fit to Window") : _("Actual Size");
            });
            overlay.add_overlay(fit_button);
            var session = new LiveTextSession();
            live_text = session;
            session.view.set_geometry_func((out ox, out oy, out scale) => viewer.image_geometry(out ox, out oy, out scale));
            viewer.view_changed.connect(() => session.view.queue_draw());
            session.copied.connect(() => show_text_copied());
            overlay.add_overlay(session.view);
            session.toggle.add_css_class("singularity-hover-btn");
            session.toggle.halign = Align.END;
            session.toggle.valign = Align.START;
            session.toggle.margin_top = 10;
            session.toggle.margin_end = 48;
            session.toggle.visible = false;
            overlay.add_overlay(session.toggle);
            session.bar.valign = Align.END;
            session.bar.margin_bottom = 12;
            session.bar.margin_start = 12;
            session.bar.margin_end = 12;
            overlay.add_overlay(session.bar);
            overlay.add_css_class("singularity-hover-on-content");
            set_stage_child(overlay);

            bool animated = mime == "image/gif" || mime == "image/webp";
            var target = file;
            new Thread<void>("preview-image", () => {
                Gdk.Texture? texture = null;
                Gdk.PixbufAnimation? animation = null;
                try {
                    if (animated && path != null) {
                        var anim = new Gdk.PixbufAnimation.from_file(path);
                        if (anim.is_static_image()) {
                            texture = PreviewZoomImage.texture_for(anim.get_static_image());
                        } else {
                            animation = anim;
                        }
                    }
                    if (texture == null && animation == null) texture = Gdk.Texture.from_file(target);
                } catch (Error e) {
                    texture = null;
                }
                Idle.add(() => {
                    if (gen != generation) return Source.REMOVE;
                    if (animation != null) {
                        viewer.set_animation(animation);
                    } else if (texture != null) {
                        viewer.set_texture(texture);
                        session.set_texture(texture);
                        session.toggle.visible = true;
                    } else {
                        show_generic();
                        return Source.REMOVE;
                    }
                    if (width <= 0) fit_stage(viewer.image_width, viewer.image_height);
                    fit_button.visible = viewer.image_width > stage_w || viewer.image_height > stage_h;
                    return Source.REMOVE;
                });
            });
        }

        private void show_media(uint gen, bool video) {
            if (media_view == null) {
                media_view = new MediaView();
                media_view.playback.failed.connect((message) => {
                    if (media_view.get_parent() != stage) return;
                    media_view.playback.stop();
                    show_generic();
                    facts_label.label = _("%s, cannot be played: %s").printf(summary(), message);
                });
            }
            media_view.fallback_icon = info.get_icon();
            media_view.margin_bottom = 8;
            if (video) {
                fit_stage(1280, 720, CONTROLS_H);
            } else {
                set_stage_size(STAGE_MIN_W, 380);
            }
            set_stage_child(media_view, true);
            var playback = media_view.playback;
            playback.muted = video;
            playback.loop = video;
            playback.open(file.get_uri(), video);
            ulong handler = 0;
            handler = playback.video.first_frame.connect(() => {
                playback.video.disconnect(handler);
                if (gen != generation) return;
                int w = playback.video.get_intrinsic_width();
                int h = playback.video.get_intrinsic_height();
                if (w > 0 && h > 0) fit_stage(w, h, CONTROLS_H);
            });
        }

        private void show_pdf(uint gen) {
            set_stage_size(STAGE_MIN_W, STAGE_MAX_H);
            var overlay = new Overlay();
            var picture = new Picture();
            picture.content_fit = ContentFit.CONTAIN;
            picture.can_shrink = true;
            picture.margin_top = 12;
            picture.margin_bottom = 12;
            picture.margin_start = 12;
            picture.margin_end = 12;
            picture.add_css_class("quicklook-page");
            overlay.child = picture;
            var pager = new Box(Orientation.HORIZONTAL, 4);
            pager.add_css_class("quicklook-pager");
            pager.halign = Align.CENTER;
            pager.valign = Align.END;
            pager.margin_bottom = 20;
            var back = new Button.from_icon_name("go-previous-symbolic");
            back.add_css_class("flat");
            back.add_css_class("singularity-hover-btn");
            back.tooltip_text = _("Previous Page");
            back.clicked.connect(() => show_pdf_page(pdf_page - 1));
            var counter = new Label("");
            counter.add_css_class("quicklook-pager-label");
            var forward = new Button.from_icon_name("go-next-symbolic");
            forward.add_css_class("flat");
            forward.add_css_class("singularity-hover-btn");
            forward.tooltip_text = _("Next Page");
            forward.clicked.connect(() => show_pdf_page(pdf_page + 1));
            pager.append(back);
            pager.append(counter);
            pager.append(forward);
            pager.visible = false;
            overlay.add_overlay(pager);
            overlay.add_css_class("singularity-hover-on-content");
            set_stage_child(overlay);
            pdf_picture = picture;
            pdf_counter = counter;

            var target = file;
            var cancel = cancellable;
            new Thread<void>("preview-pdf", () => {
                Poppler.Document? document = null;
                try {
                    document = new Poppler.Document.from_gfile(target, null, cancel);
                } catch (Error e) {
                    document = null;
                }
                Idle.add(() => {
                    if (gen != generation) return Source.REMOVE;
                    if (document == null || document.get_n_pages() < 1) {
                        show_generic();
                        return Source.REMOVE;
                    }
                    pdf_document = document;
                    double pw, ph;
                    document.get_page(0).get_size(out pw, out ph);
                    fit_stage(pw * 1.5, ph * 1.5);
                    pager.visible = document.get_n_pages() > 1;
                    show_pdf_page(0);
                    return Source.REMOVE;
                });
            });
        }

        private bool show_pdf_page(int page_index) {
            if (pdf_document == null || pdf_picture == null) return false;
            int pages = pdf_document.get_n_pages();
            if (page_index < 0 || page_index >= pages) return true;
            pdf_page = page_index;
            pdf_counter.label = _("%d of %d").printf(page_index + 1, pages);
            var page = pdf_document.get_page(page_index);
            double pw, ph;
            page.get_size(out pw, out ph);
            if (pw <= 0 || ph <= 0) return true;
            int scale_factor = int.max(1, get_scale_factor());
            double scale = double.min((stage_w - 24.0) / pw, (stage_h - 24.0) / ph) * scale_factor;
            int w = int.max(1, (int) Math.round(pw * scale));
            int h = int.max(1, (int) Math.round(ph * scale));
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context(surface);
            cr.set_source_rgb(1, 1, 1);
            cr.paint();
            cr.scale(scale, scale);
            page.render(cr);
            surface.flush();
            unowned uint8[] data = surface.get_data();
            data.length = surface.get_stride() * h;
            var bytes = new Bytes(data);
            pdf_picture.paintable = new Gdk.MemoryTexture(w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride());
            return true;
        }

        private async void show_text(uint gen) {
            set_stage_size(DOC_W, DOC_H);
            var buffer = new ByteArray();
            bool truncated = false;
            try {
                var stream = yield file.read_async(Priority.DEFAULT, cancellable);
                while (buffer.len <= TEXT_LIMIT) {
                    var chunk = yield stream.read_bytes_async(64 * 1024, Priority.DEFAULT, cancellable);
                    if (chunk.get_size() == 0) break;
                    buffer.append(chunk.get_data());
                }
                yield stream.close_async(Priority.DEFAULT, null);
            } catch (Error e) {
                if (gen == generation) show_generic();
                return;
            }
            if (gen != generation) return;
            if (buffer.len > TEXT_LIMIT) {
                truncated = true;
                buffer.set_size(TEXT_LIMIT);
            }
            if (Posix.memchr(buffer.data, 0, buffer.len) != null) {
                show_generic();
                return;
            }
            buffer.append({ 0 });
            string text = ((string) buffer.data).make_valid();
            if (truncated) {
                int cut = text.last_index_of_char('\n');
                if (cut > 0) text = text.substring(0, cut + 1);
                facts_label.label = _("%s, showing the first %s").printf(summary(), format_size(TEXT_LIMIT));
            }

            var source_buffer = new GtkSource.Buffer(null);
            var language = GtkSource.LanguageManager.get_default().guess_language(file.get_basename(), content_type);
            if (language != null) source_buffer.language = language;
            source_buffer.highlight_syntax = language != null;
            bool dark = Gtk.Settings.get_default().gtk_application_prefer_dark_theme;
            var schemes = GtkSource.StyleSchemeManager.get_default();
            var scheme = dark ? (schemes.get_scheme("classic-dark") ?? schemes.get_scheme("oblivion"))
                              : schemes.get_scheme("classic");
            if (scheme != null) source_buffer.style_scheme = scheme;
            source_buffer.text = text;
            var view = new GtkSource.View.with_buffer(source_buffer);
            view.editable = false;
            view.cursor_visible = false;
            view.monospace = true;
            view.show_line_numbers = true;
            view.wrap_mode = WrapMode.NONE;
            view.top_margin = 12;
            view.bottom_margin = 12;
            view.left_margin = 8;
            view.right_margin = 12;
            view.add_css_class("quicklook-text");
            var scroll = new ScrolledWindow();
            scroll.child = view;
            set_stage_child(scroll);
        }

        [CCode (has_target = false)]
        private delegate void* FontConfigCreate();
        [CCode (has_target = false)]
        private delegate void FontConfigDestroy(void* config);
        [CCode (has_target = false)]
        private delegate void FontMapSetConfig(Pango.FontMap map, void* config);

        private static Pango.FontMap isolated_font_map() {
            Pango.FontMap map = Pango.CairoFontMap.new();
            var self = Module.open(null, ModuleFlags.LAZY);
            void* create = null;
            void* destroy = null;
            void* set_config = null;
            if (self == null || !self.symbol("FcConfigCreate", out create)
                    || !self.symbol("FcConfigDestroy", out destroy)
                    || !self.symbol("pango_fc_font_map_set_config", out set_config)) {
                return map;
            }
            void* config = ((FontConfigCreate) create)();
            ((FontMapSetConfig) set_config)(map, config);
            ((FontConfigDestroy) destroy)(config);
            return map;
        }

        private void show_font() {
            set_stage_size(DOC_W, DOC_H);
            string? path = file.get_path();
            Pango.FontMap map = isolated_font_map();
            Pango.FontDescription? face = null;
            if (path != null) {
                try {
                    if (preview_font_map_add_font_file(map, path)) {
                        (unowned Pango.FontFamily)[] families;
                        map.list_families(out families);
                        foreach (unowned var family in families) {
                            (unowned Pango.FontFace)[] faces;
                            family.list_faces(out faces);
                            if (faces.length > 0) {
                                face = faces[0].describe();
                                break;
                            }
                        }
                    }
                } catch (Error e) {
                    face = null;
                }
            }
            if (face == null || face.get_family() == null) {
                show_generic();
                return;
            }
            var page = new Box(Orientation.VERTICAL, 16);
            page.valign = Align.CENTER;
            page.margin_start = 32;
            page.margin_end = 32;
            page.append(font_label("Aa", face, 96, map));
            var pangram = font_label(_("The quick brown fox jumps over the lazy dog."), face, 24, map);
            pangram.wrap = true;
            pangram.justify = Justification.CENTER;
            page.append(pangram);
            var glyphs = font_label("ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 !?&@", face, 15, map);
            glyphs.add_css_class("dim-label");
            glyphs.justify = Justification.CENTER;
            page.append(glyphs);
            var name = new Label(face.to_string());
            name.add_css_class("quicklook-facts");
            page.append(name);
            set_stage_child(page);
        }

        private static Label font_label(string text, Pango.FontDescription face, int size, Pango.FontMap map) {
            var label = new Label(text);
            label.set_font_map(map);
            var description = face.copy();
            description.set_size(size * Pango.SCALE);
            var attrs = new Pango.AttrList();
            attrs.insert(new Pango.AttrFontDesc(description));
            label.attributes = attrs;
            return label;
        }

        private void show_folder(uint gen) {
            set_stage_size(DOC_W, DOC_H);
            var page = new Box(Orientation.VERTICAL, 10);
            page.valign = Align.CENTER;
            page.halign = Align.CENTER;
            var icon = new Image.from_gicon(info.get_icon());
            icon.pixel_size = 96;
            page.append(icon);
            var count = new Label(_("Counting items"));
            count.add_css_class("quicklook-item-count");
            page.append(count);
            var size = new Label("");
            size.add_css_class("dim-label");
            page.append(size);
            var children = new Box(Orientation.HORIZONTAL, 12);
            children.halign = Align.CENTER;
            children.margin_top = 14;
            page.append(children);
            set_stage_child(page);

            var target = file;
            var cancel = cancellable;
            target.enumerate_children_async.begin("standard::display-name,standard::icon,standard::is-hidden",
                    FileQueryInfoFlags.NONE, Priority.DEFAULT, cancel, (obj, res) => {
                try {
                    var enumerator = target.enumerate_children_async.end(res);
                    enumerator.next_files_async.begin(200, Priority.DEFAULT, cancel, (o, r) => {
                        if (gen != generation) return;
                        try {
                            var visible_children = new GenericArray<FileInfo>();
                            foreach (var child in enumerator.next_files_async.end(r)) {
                                if (!child.get_is_hidden()) visible_children.add(child);
                            }
                            visible_children.sort((a, b) => a.get_display_name().collate(b.get_display_name()));
                            for (int i = 0; i < int.min(6, visible_children.length); i++) {
                                children.append(folder_child(visible_children[i]));
                            }
                        } catch (Error e) { }
                    });
                } catch (Error e) { }
            });

            new Thread<void>("preview-folder", () => {
                int64 total = 0;
                int direct = 0;
                bool capped = false;
                scan_folder(target, cancel, ref total, ref direct, ref capped, true);
                Idle.add(() => {
                    if (gen != generation) return Source.REMOVE;
                    count.label = ngettext("%d item", "%d items", direct).printf(direct);
                    size.label = capped ? _("More than %s").printf(format_size(total)) : format_size(total);
                    facts_label.label = "%s, %s".printf(count.label, size.label);
                    return Source.REMOVE;
                });
            });
        }

        private static void scan_folder(File folder, Cancellable? cancel, ref int64 total, ref int direct,
                                        ref bool capped, bool top) {
            try {
                var enumerator = folder.enumerate_children("standard::name,standard::type,standard::size",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancel);
                FileInfo? child;
                int seen = 0;
                while ((child = enumerator.next_file(cancel)) != null) {
                    if (top) direct++;
                    if (capped) continue;
                    if (++seen > FOLDER_SCAN_LIMIT) {
                        capped = true;
                        continue;
                    }
                    if (child.get_file_type() == FileType.DIRECTORY) {
                        scan_folder(folder.get_child(child.get_name()), cancel, ref total, ref direct, ref capped, false);
                    } else {
                        total += child.get_size();
                    }
                }
            } catch (Error e) { }
        }

        private static Widget folder_child(FileInfo child) {
            var box = new Box(Orientation.VERTICAL, 6);
            box.width_request = 72;
            var image = new Image.from_gicon(child.get_icon());
            image.pixel_size = 48;
            box.append(image);
            var name = new Label(child.get_display_name());
            name.add_css_class("quicklook-child-name");
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.max_width_chars = 10;
            box.append(name);
            return box;
        }

        private void show_generic() {
            set_stage_size(DOC_W, DOC_H);
            var page = new Box(Orientation.VERTICAL, 18);
            page.valign = Align.CENTER;
            page.halign = Align.CENTER;
            var icon = new Image.from_gicon(info.get_icon());
            icon.pixel_size = 128;
            page.append(icon);
            var grid = new Grid();
            grid.row_spacing = 6;
            grid.column_spacing = 16;
            grid.halign = Align.CENTER;
            int row = 0;
            add_fact(grid, ref row, _("Type"), ContentType.get_description(content_type));
            add_fact(grid, ref row, _("Size"), format_size(info.get_size()));
            var modified = info.get_modification_date_time();
            if (modified != null) add_fact(grid, ref row, _("Modified"), modified.to_local().format("%x %H:%M"));
            var parent = file.get_parent();
            if (parent != null) add_fact(grid, ref row, _("Location"), display_location(parent));
            page.append(grid);
            set_stage_child(page);
        }

        private static void add_fact(Grid grid, ref int row, string key, string value) {
            var key_label = new Label(key);
            key_label.add_css_class("quicklook-fact-key");
            key_label.xalign = 1;
            var value_label = new Label(value);
            value_label.xalign = 0;
            value_label.selectable = true;
            value_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            value_label.max_width_chars = 40;
            grid.attach(key_label, 0, row);
            grid.attach(value_label, 1, row);
            row++;
        }

        private static string display_location(File folder) {
            string? path = folder.get_path();
            if (path == null) return folder.get_parse_name();
            string home = Environment.get_home_dir();
            if (path == home) return "~";
            if (path.has_prefix(home + "/")) return "~" + path.substring(home.length);
            return path;
        }

        private void setup_open_with() {
            default_app = AppInfo.get_default_for_type(content_type, false);
            other_apps = new GLib.List<AppInfo>();
            foreach (var app in AppInfo.get_all_for_type(content_type)) {
                if (default_app != null && app.equal(default_app)) continue;
                if (!app.should_show()) continue;
                other_apps.append(app);
            }
            if (default_app != null) {
                open_button.label = _("Open With %s").printf(default_app.get_display_name());
                open_button.sensitive = true;
            } else {
                open_button.label = _("Open");
                open_button.sensitive = false;
            }
            open_menu_button.visible = other_apps.length() > 0;
        }

        private void show_open_menu() {
            var menu = new ContextMenu(open_menu_button);
            foreach (var app in other_apps) {
                var target = app;
                menu.add_item_gicon(app.get_display_name(), app.get_icon(), () => open_with(target));
            }
            menu.closed.connect(() => Idle.add(() => {
                menu.unparent();
                return Source.REMOVE;
            }));
            menu.popup();
        }

        private void open_with(AppInfo? app) {
            if (app == null || file == null) return;
            if (!ParentalEnforcer.get_default().allows(app)) return;
            var files = new GLib.List<File>();
            files.append(file);
            try {
                app.launch(files, get_display().get_app_launch_context());
                close_dialog();
            } catch (Error e) {
                warning("Preview: failed to open %s: %s", file.get_uri(), e.message);
            }
        }

        private void reveal_file() {
            if (file == null) return;
            var target = file;
            var uris = new VariantBuilder(new VariantType("as"));
            uris.add("s", target.get_uri());
            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    var bus = Bus.get.end(res);
                    bus.call.begin("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                        "org.freedesktop.FileManager1", "ShowItems", new Variant("(ass)", uris, ""),
                        null, DBusCallFlags.NONE, 5000, null, (o, r) => {
                            try {
                                bus.call.end(r);
                            } catch (Error e) {
                                open_parent(target);
                            }
                        });
                } catch (Error e) {
                    open_parent(target);
                }
            });
            close_dialog();
        }

        private void open_parent(File target) {
            var parent = target.get_parent();
            if (parent == null) return;
            try {
                AppInfo.launch_default_for_uri(parent.get_uri(), get_display().get_app_launch_context());
            } catch (Error e) {
                warning("Preview: failed to show %s: %s", target.get_uri(), e.message);
            }
        }

        private void copy_file() {
            if (file == null) return;
            string uri = file.get_uri();
            var list = new Gdk.FileList.from_array({ file });
            var provider = new Gdk.ContentProvider.union({
                new Gdk.ContentProvider.for_value(list),
                new Gdk.ContentProvider.for_bytes("text/uri-list", new Bytes((uri + "\r\n").data)),
                new Gdk.ContentProvider.for_bytes("x-special/gnome-copied-files", new Bytes(("copy\n" + uri).data)),
                new Gdk.ContentProvider.for_bytes("text/plain;charset=utf-8", new Bytes((file.get_path() ?? uri).data))
            });
            get_clipboard().set_content(provider);
            copy_button.label = _("Copied");
            if (copied_reset_id != 0) Source.remove(copied_reset_id);
            copied_reset_id = Timeout.add(1500, () => {
                copy_button.label = _("Copy");
                copied_reset_id = 0;
                return Source.REMOVE;
            });
        }

        private void show_text_copied() {
            copy_button.label = _("Text Copied");
            if (copied_reset_id != 0) Source.remove(copied_reset_id);
            copied_reset_id = Timeout.add(1500, () => {
                copy_button.label = _("Copy");
                copied_reset_id = 0;
                return Source.REMOVE;
            });
        }

        private static void install_css() {
            if (css_installed) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            css_installed = true;
            var provider = new CssProvider();
            provider.load_from_string("""
                .quicklook .quicklook-stage {
                    border-radius: 12px;
                    background-color: alpha(@text_color, 0.05);
                }
                .quicklook .quicklook-stage.bare {
                    background-color: transparent;
                }
                .quicklook .quicklook-facts {
                    font-size: 13px;
                    opacity: 0.65;
                }
                .quicklook .quicklook-fact-key {
                    opacity: 0.6;
                }
                .quicklook .quicklook-item-count {
                    font-size: 20px;
                    font-weight: 600;
                }
                .quicklook .quicklook-child-name {
                    font-size: 11px;
                }
                .quicklook .quicklook-pager {
                    padding: 4px;
                    border-radius: 999px;
                    background-color: alpha(black, 0.55);
                    border: 1px solid alpha(white, 0.18);
                }
                .quicklook .quicklook-pager-label {
                    color: white;
                    font-size: 12px;
                    font-feature-settings: "tnum";
                    margin: 0 6px;
                }
                .quicklook textview.quicklook-text {
                    font-size: 12px;
                }
                .quicklook textview.quicklook-text,
                .quicklook textview.quicklook-text > text,
                .quicklook textview.quicklook-text gutter,
                .quicklook textview.quicklook-text border {
                    background-color: transparent;
                }
                .quicklook textview.quicklook-text gutter {
                    color: alpha(@text_color, 0.35);
                }
            """);
            StyleContext.add_provider_for_display(display, provider, STYLE_PROVIDER_PRIORITY_USER + 10);
        }
    }

    public class PreviewZoomImage : Widget {
        private const double MAX_ZOOM = 8.0;

        public signal void zoom_changed();
        public signal void view_changed();

        public int image_width { get; private set; default = 0; }
        public int image_height { get; private set; default = 0; }

        public bool actual_size {
            get { return zoom > 0 && Math.fabs(zoom - 1.0) < 0.001; }
        }

        private Gdk.Paintable? paintable = null;
        private Gdk.PixbufAnimationIter? frames = null;
        private uint frame_id = 0;
        private double zoom = 0;
        private double center_x = 0.5;
        private double center_y = 0.5;
        private double pointer_x = -1;
        private double pointer_y = -1;
        private double pinch_start = 1.0;
        private double drag_start_x = 0.5;
        private double drag_start_y = 0.5;

        construct {
            overflow = Overflow.HIDDEN;
            hexpand = true;
            vexpand = true;

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                pointer_x = x;
                pointer_y = y;
            });
            add_controller(motion);

            var scroll = new EventControllerScroll(EventControllerScrollFlags.VERTICAL);
            scroll.scroll.connect((dx, dy) => {
                if (paintable == null) return false;
                zoom_at(current_scale() * Math.pow(1.15, -dy), pointer_x, pointer_y);
                return true;
            });
            add_controller(scroll);

            var pinch = new GestureZoom();
            pinch.begin.connect(() => pinch_start = current_scale());
            pinch.scale_changed.connect((scale) => {
                double x, y;
                if (!pinch.get_bounding_box_center(out x, out y)) {
                    x = get_width() / 2.0;
                    y = get_height() / 2.0;
                }
                zoom_at(pinch_start * scale, x, y);
            });
            add_controller(pinch);

            var drag = new GestureDrag();
            drag.drag_begin.connect(() => {
                drag_start_x = center_x;
                drag_start_y = center_y;
            });
            drag.drag_update.connect((ox, oy) => {
                double s = current_scale();
                if (image_width == 0) return;
                center_x = drag_start_x - ox / (image_width * s);
                center_y = drag_start_y - oy / (image_height * s);
                view_changed();
                queue_draw();
            });
            add_controller(drag);

            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                if (n == 2) toggle_actual_size();
            });
            add_controller(click);
        }

        public static Gdk.Texture texture_for(Gdk.Pixbuf pixbuf) {
            var format = pixbuf.has_alpha ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
            return new Gdk.MemoryTexture(pixbuf.width, pixbuf.height, format, pixbuf.read_pixel_bytes(), pixbuf.rowstride);
        }

        public void set_texture(Gdk.Texture texture) {
            stop();
            paintable = texture;
            image_width = texture.get_width();
            image_height = texture.get_height();
            reset();
        }

        public void set_animation(Gdk.PixbufAnimation animation) {
            stop();
            frames = animation.get_iter(null);
            image_width = animation.get_width();
            image_height = animation.get_height();
            paintable = texture_for(frames.get_pixbuf());
            reset();
            schedule_frame();
        }

        public void stop() {
            if (frame_id != 0) Source.remove(frame_id);
            frame_id = 0;
            frames = null;
        }

        public void toggle_actual_size() {
            zoom = actual_size ? 0 : 1.0;
            center_x = 0.5;
            center_y = 0.5;
            zoom_changed();
            view_changed();
            queue_draw();
        }

        public bool image_geometry(out double left, out double top, out double scale) {
            scale = current_scale();
            origin(scale, out left, out top);
            return image_width > 0;
        }

        private void schedule_frame() {
            if (frames == null) return;
            int delay = frames.get_delay_time();
            if (delay < 0) return;
            frame_id = Timeout.add(int.max(20, delay), () => {
                frame_id = 0;
                if (frames == null) return Source.REMOVE;
                frames.advance(null);
                paintable = texture_for(frames.get_pixbuf());
                queue_draw();
                schedule_frame();
                return Source.REMOVE;
            });
        }

        private void reset() {
            zoom = 0;
            center_x = 0.5;
            center_y = 0.5;
            zoom_changed();
            queue_draw();
        }

        public override void unmap() {
            stop();
            base.unmap();
        }

        private double fit_scale() {
            if (image_width == 0 || image_height == 0 || get_width() == 0) return 1.0;
            return double.min(1.0, double.min((double) get_width() / image_width, (double) get_height() / image_height));
        }

        private double current_scale() {
            return zoom > 0 ? zoom : fit_scale();
        }

        private void zoom_at(double scale, double x, double y) {
            if (image_width == 0) return;
            double fit = fit_scale();
            double target = scale.clamp(fit, MAX_ZOOM);
            if (x < 0 || y < 0) {
                x = get_width() / 2.0;
                y = get_height() / 2.0;
            }
            double old = current_scale();
            double left, top;
            origin(old, out left, out top);
            double ix = (x - left) / (image_width * old);
            double iy = (y - top) / (image_height * old);
            zoom = Math.fabs(target - fit) < 0.0001 ? 0 : target;
            double new_left = x - ix * image_width * target;
            double new_top = y - iy * image_height * target;
            center_x = (get_width() / 2.0 - new_left) / (image_width * target);
            center_y = (get_height() / 2.0 - new_top) / (image_height * target);
            zoom_changed();
            view_changed();
            queue_draw();
        }

        private void origin(double scale, out double left, out double top) {
            double w = image_width * scale;
            double h = image_height * scale;
            double width = get_width();
            double height = get_height();
            if (w <= width) {
                left = (width - w) / 2;
                center_x = 0.5;
            } else {
                left = (width / 2 - center_x * w).clamp(width - w, 0);
                center_x = (width / 2 - left) / w;
            }
            if (h <= height) {
                top = (height - h) / 2;
                center_y = 0.5;
            } else {
                top = (height / 2 - center_y * h).clamp(height - h, 0);
                center_y = (height / 2 - top) / h;
            }
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (paintable == null || image_width == 0) return;
            double scale = current_scale();
            double left, top;
            origin(scale, out left, out top);
            double w = image_width * scale;
            double h = image_height * scale;
            var bounds = Graphene.Rect();
            bounds.init((float) left, (float) top, (float) w, (float) h);
            var texture = paintable as Gdk.Texture;
            if (texture != null) {
                var filter = scale >= 2.0 ? Gsk.ScalingFilter.NEAREST : Gsk.ScalingFilter.TRILINEAR;
                snapshot.append_scaled_texture(texture, filter, bounds);
            } else {
                snapshot.save();
                snapshot.translate({ (float) left, (float) top });
                paintable.snapshot(snapshot, w, h);
                snapshot.restore();
            }
        }
    }
}
