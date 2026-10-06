using Gtk;
using GLib;

namespace Singularity {

    public class SearchResultRow : ListBoxRow {
        public SearchResult result { get; construct; }
        private Revealer? _preview_revealer = null;
        private Box? _preview_content = null;
        private uint _hover_timer = 0;

        public signal void request_close();

        public SearchResultRow(SearchResult res) {
            Object(result: res);
            setup_ui();
        }

        private void setup_ui() {
            add_css_class("search-result-row");

            var rc = new GestureClick();
            rc.set_button(Gdk.BUTTON_SECONDARY);
            rc.pressed.connect((n, x, y) => show_context_menu(x, y));
            add_controller(rc);

            var outer = new Box(Orientation.VERTICAL, 0);
            set_child(outer);

            // Main row: icon + text
            var row_box = new Box(Orientation.HORIZONTAL, 12);
            row_box.margin_start = 12;
            row_box.margin_end = 12;
            row_box.margin_top = 8;
            row_box.margin_bottom = 8;
            outer.append(row_box);

            var icon_img = new Image();
            if (result.gicon != null) icon_img.set_from_gicon(result.gicon);
            else icon_img.set_from_icon_name(result.icon_name ?? "system-search-symbolic");
            icon_img.pixel_size = 40;
            icon_img.valign = Align.CENTER;
            row_box.append(icon_img);

            var text_box = new Box(Orientation.VERTICAL, 2);
            text_box.valign = Align.CENTER;
            text_box.hexpand = true;
            row_box.append(text_box);

            var title_label = new Label(result.title);
            title_label.add_css_class("search-result-title");
            title_label.halign = Align.START;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            text_box.append(title_label);

            if (result.description != null) {
                var desc_label = new Label(result.description);
                desc_label.add_css_class("search-result-description");
                desc_label.halign = Align.START;
                desc_label.ellipsize = Pango.EllipsizeMode.END;
                text_box.append(desc_label);
            }

            var preview = build_result_preview(result.preview, 40);
            if (preview != null) row_box.append(preview);
            var actions = build_result_actions(result, () => request_close());
            if (actions != null) row_box.append(actions);

            // Inline preview revealer (files only)
            if (result.provider.id == "files") {
                add_css_class("search-result-row-file");

                _preview_revealer = new Revealer();
                _preview_revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
                _preview_revealer.transition_duration = 180;
                _preview_revealer.reveal_child = false;

                _preview_content = new Box(Orientation.VERTICAL, 0);
                _preview_content.add_css_class("search-preview-inline");
                _preview_revealer.set_child(_preview_content);
                outer.append(_preview_revealer);

                var motion = new EventControllerMotion();
                motion.enter.connect(on_hover_enter);
                motion.leave.connect(on_hover_leave);
                add_controller(motion);
            }
        }

        public delegate void CloseRequest();

        public static Widget? build_result_preview(SearchResultPreview? preview, int size) {
            if (preview == null) return null;
            if (preview.large && preview.kind != SearchResultPreviewKind.TEXT) size = SearchResultPreview.LARGE_SIZE;
            Widget widget;
            switch (preview.kind) {
            case SearchResultPreviewKind.COLOR:
                var swatch = new Gtk.DrawingArea();
                var color = preview.color;
                swatch.set_draw_func((area, cr, w, h) => {
                    double r = 6;
                    cr.new_sub_path();
                    cr.arc(w - r, r, r, -Math.PI / 2, 0);
                    cr.arc(w - r, h - r, r, 0, Math.PI / 2);
                    cr.arc(r, h - r, r, Math.PI / 2, Math.PI);
                    cr.arc(r, r, r, Math.PI, 3 * Math.PI / 2);
                    cr.close_path();
                    Gdk.cairo_set_source_rgba(cr, color);
                    cr.fill_preserve();
                    cr.set_source_rgba(0, 0, 0, 0.18);
                    cr.set_line_width(1);
                    cr.stroke();
                });
                swatch.set_size_request(size, size);
                widget = swatch;
                break;
            case SearchResultPreviewKind.IMAGE:
                var picture = new Image.from_paintable(preview.paintable);
                picture.pixel_size = size;
                widget = picture;
                break;
            case SearchResultPreviewKind.ICON:
                var image = new Image.from_gicon(preview.icon);
                image.pixel_size = size;
                widget = image;
                break;
            default:
                var label = new Label(preview.text);
                label.add_css_class("monospace");
                label.ellipsize = Pango.EllipsizeMode.END;
                label.max_width_chars = 24;
                widget = label;
                break;
            }
            widget.add_css_class("search-result-preview");
            widget.valign = Align.CENTER;
            return widget;
        }

        public static Widget? build_result_actions(SearchResult result, owned CloseRequest close) {
            var actions = result.get_actions();
            if (actions.length == 0) return null;
            var box = new Box(Orientation.HORIZONTAL, 4);
            box.add_css_class("search-result-actions");
            box.valign = Align.CENTER;
            int shown = 0;
            foreach (var action in actions) {
                if (shown++ >= 3) break;
                var button = new Button();
                button.add_css_class("flat");
                button.add_css_class("search-result-action");
                if (action.icon_name != null) {
                    button.icon_name = action.icon_name;
                    button.tooltip_text = action.label;
                } else {
                    button.label = action.label;
                }
                button.update_property(Gtk.AccessibleProperty.LABEL, action.label, -1);
                var captured = action;
                button.clicked.connect(() => {
                    captured.activate();
                    if (!captured.keeps_open) close();
                });
                box.append(button);
            }
            return box;
        }

        public void show_preview_keyboard() {
            if (_preview_revealer == null) return;
            if (_hover_timer != 0) {
                GLib.Source.remove(_hover_timer);
                _hover_timer = 0;
            }
            show_preview();
        }

        public void hide_preview_keyboard() {
            if (_preview_revealer != null) {
                _preview_revealer.reveal_child = false;
            }
        }

        private void on_hover_enter(double x, double y) {
            if (_hover_timer != 0) return;
            _hover_timer = GLib.Timeout.add(200, () => {
                _hover_timer = 0;
                show_preview();
                return GLib.Source.REMOVE;
            });
        }

        private void on_hover_leave() {
            if (_hover_timer != 0) {
                GLib.Source.remove(_hover_timer);
                _hover_timer = 0;
            }
            if (_preview_revealer != null) {
                _preview_revealer.reveal_child = false;
            }
        }

        private void show_preview() {
            if (_preview_revealer == null || _preview_content == null) return;
            if (result.action_id == null) return;

            string mime = result.mime_type ?? "";
            string uri = result.action_id;

            if (mime.has_prefix("image/")) {
                load_image_preview(uri);
            } else if (mime.has_prefix("text/")) {
                load_text_preview.begin(uri);
            } else {
                // Generic: icon + description
                var icon = new Image();
                if (result.gicon != null) icon.set_from_gicon(result.gicon);
                else icon.set_from_icon_name("text-x-generic");
                icon.pixel_size = 64;
                icon.halign = Align.CENTER;
                icon.margin_top = 8;
                icon.margin_bottom = 4;

                var lbl = new Label(result.description ?? result.title);
                lbl.halign = Align.CENTER;
                lbl.wrap = true;
                lbl.add_css_class("search-result-description");

                clear_preview_content();
                _preview_content.append(icon);
                _preview_content.append(lbl);

                add_css_class("search-result-has-preview");
                _preview_revealer.reveal_child = true;
            }
        }

        private void load_image_preview(string uri) {
            var file = GLib.File.new_for_uri(uri);
            string? path = file.get_path();
            if (path == null) return;

            try {
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 600, 220, true);
                var texture = Gdk.Texture.for_pixbuf(pixbuf);

                var pic = new Picture();
                pic.set_paintable(texture);
                pic.content_fit = ContentFit.CONTAIN;
                pic.height_request = 220;
                pic.can_shrink = true;
                pic.hexpand = true;

                clear_preview_content();
                _preview_content.append(pic);

                add_css_class("search-result-has-preview");
                _preview_revealer.reveal_child = true;
            } catch (Error e) {
                // silently skip
            }
        }

        private async void load_text_preview(string uri) {
            var file = GLib.File.new_for_uri(uri);
            try {
                var stream = yield file.read_async(GLib.Priority.DEFAULT, null);
                var data_stream = new GLib.DataInputStream(stream);
                uint8[] buf = new uint8[600];
                size_t bytes_read;
                yield stream.read_all_async(buf, GLib.Priority.DEFAULT, null, out bytes_read);

                if (bytes_read == 0) return;

                buf.length = (int)bytes_read;
                string text = ((string)buf).substring(0, (long)bytes_read);
                if (!text.validate()) text = "[Binary content]";

                var lbl = new Label(text);
                lbl.add_css_class("search-preview-text");
                lbl.halign = Align.START;
                lbl.valign = Align.START;
                lbl.wrap = true;
                lbl.wrap_mode = Pango.WrapMode.CHAR;
                lbl.selectable = false;

                clear_preview_content();
                _preview_content.append(lbl);

                add_css_class("search-result-has-preview");
                _preview_revealer.reveal_child = true;
            } catch (Error e) {
                // silently skip
            }
        }

        private void clear_preview_content() {
            if (_preview_content == null) return;
            Widget? child = _preview_content.get_first_child();
            while (child != null) {
                _preview_content.remove(child);
                child = _preview_content.get_first_child();
            }
        }

        private void show_context_menu(double x, double y) {
            if (result.provider.id == "apps") {
                show_app_context_menu(x, y);
            } else if (result.provider.id == "files") {
                show_file_context_menu(x, y);
            }
        }

        private void show_app_context_menu(double x, double y) {
            if (result.action_id == null) return;
            var app = AppSystem.get_default().get_app_info(result.action_id);
            if (app == null) return;
            string? app_id = app.get_id();

            var menu = new Singularity.Widgets.ContextMenu(this);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            menu.set_pointing_to(rect);

            menu.add_item("Open", "system-run-symbolic", () => {
                AppSystem.launch_app(app);
                request_close();
            });
            menu.add_item("Add to Desktop", "user-desktop-symbolic", () => {
                AppSystem.add_app_to_desktop(app);
            });
            menu.add_separator();
            if (app_id != null) {
                string captured_id = app_id.dup();
                var app_system = AppSystem.get_default();
                if (app_system.is_pinned(captured_id)) {
                    menu.add_item("Unpin from Dock", "list-remove-symbolic", () => {
                        app_system.unpin_app(captured_id);
                    });
                } else {
                    menu.add_item("Pin to Dock", "starred-symbolic", () => {
                        app_system.pin_app(captured_id);
                    });
                }
            }
            menu.popup();
        }

        private void show_file_context_menu(double x, double y) {
            if (result.action_id == null) return;
            string uri = result.action_id;

            var menu = new Singularity.Widgets.ContextMenu(this);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            menu.set_pointing_to(rect);

            menu.add_item("Open", "system-run-symbolic", () => {
                result.activate();
                request_close();
            });
            menu.add_item("Open Containing Folder", "folder-open-symbolic", () => {
                var file = GLib.File.new_for_uri(uri);
                var parent_dir = file.get_parent();
                if (parent_dir != null) {
                    try {
                        string cmd = AppSystem.resolve_companion_bin("singularity-files")
                            + " " + GLib.Shell.quote(parent_dir.get_path());
                        Process.spawn_command_line_async(cmd);
                        request_close();
                    } catch (Error e) {
                        warning("Failed to open containing folder: %s", e.message);
                    }
                }
            });
            menu.popup();
        }

        protected override void dispose() {
            if (_hover_timer != 0) {
                GLib.Source.remove(_hover_timer);
                _hover_timer = 0;
            }
            base.dispose();
        }
    }
}
