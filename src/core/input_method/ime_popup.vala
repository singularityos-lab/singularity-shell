namespace Singularity.InputMethods {

    public class ImePopup : Object {
        public const int HIT_NONE = -1;
        public const int HIT_PREVIOUS = -2;
        public const int HIT_NEXT = -3;
        public const int HIT_DICTATION = -4;

        private const double PAD = 6;
        private const double GAP = 4;
        private const int ACCENTS_PER_ROW = 10;

        private struct Area {
            public double x;
            public double y;
            public double w;
            public double h;
            public int action;
        }

        public bool visible { get; private set; default = false; }

        private Area[] areas = {};

        private struct Palette {
            public double bg_r;
            public double bg_g;
            public double bg_b;
            public double fg;
            public double border;
            public Gdk.RGBA accent;
            public Gdk.RGBA accent_fg;
        }

        private Palette palette() {
            var style = Singularity.Style.StyleManager.get_default();
            var p = Palette();
            bool dark = style.dark;
            p.bg_r = dark ? 0.13 : 0.98;
            p.bg_g = dark ? 0.13 : 0.98;
            p.bg_b = dark ? 0.14 : 0.98;
            p.fg = dark ? 1.0 : 0.1;
            p.border = dark ? 0.12 : 0.14;
            p.accent = Gdk.RGBA();
            p.accent.parse(style.accent_hex);
            p.accent_fg = Gdk.RGBA();
            p.accent_fg.parse(style.accent_fg_hex);
            return p;
        }

        private static string font_family() {
            var settings = Gtk.Settings.get_default();
            if (settings != null && settings.gtk_font_name != null) {
                var desc = Pango.FontDescription.from_string(settings.gtk_font_name);
                if (desc.get_family() != null) return desc.get_family();
            }
            return "Sans";
        }

        private static Pango.FontDescription font(double size, bool bold = false) {
            var desc = Pango.FontDescription.from_string("%s %.1f".printf(font_family(), size));
            if (bold) desc.set_weight(Pango.Weight.SEMIBOLD);
            return desc;
        }

        private int output_scale() {
            int scale = 1;
            var display = Gdk.Display.get_default();
            if (display == null) return scale;
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = (Gdk.Monitor) monitors.get_item(i);
                scale = int.max(scale, (int) Math.ceil(monitor.scale));
            }
            return scale;
        }

        private static void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min(r, double.min(w, h) / 2);
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }

        private static Pango.Layout measure_layout(Pango.FontDescription desc) {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 1, 1);
            var cr = new Cairo.Context(surface);
            var layout = Pango.cairo_create_layout(cr);
            layout.set_font_description(desc);
            return layout;
        }

        private static void text_size(Pango.Layout layout, string text, out int w, out int h) {
            layout.set_text(text, -1);
            layout.get_pixel_size(out w, out h);
        }

        private void begin_frame(double width, double height, out Cairo.ImageSurface surface,
                                 out Cairo.Context cr, out int scale, Palette p) {
            scale = output_scale();
            int pixel_w = (int) Math.ceil(width) * scale;
            int pixel_h = (int) Math.ceil(height) * scale;
            surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, pixel_w, pixel_h);
            cr = new Cairo.Context(surface);
            cr.scale(scale, scale);
            rounded(cr, 0.5, 0.5, Math.ceil(width) - 1, Math.ceil(height) - 1, 12);
            cr.set_source_rgba(p.bg_r, p.bg_g, p.bg_b, 0.97);
            cr.fill_preserve();
            cr.set_source_rgba(p.fg, p.fg, p.fg, p.border);
            cr.set_line_width(1);
            cr.stroke();
        }

        private void present(Cairo.ImageSurface surface, int scale) {
            surface.flush();
            unowned uchar[] data = surface.get_data();
            Singularity.ime_popup_show((uint8[]) data, surface.get_width(), surface.get_height(),
                surface.get_stride(), scale);
            visible = true;
        }

        public void hide() {
            areas = {};
            if (visible) Singularity.ime_popup_hide();
            visible = false;
        }

        public int hit(double x, double y) {
            foreach (var area in areas) {
                if (x >= area.x && x < area.x + area.w && y >= area.y && y < area.y + area.h) return area.action;
            }
            return HIT_NONE;
        }

        public void show_chips(string[] items, bool accents, int selected) {
            if (items.length == 0) {
                hide();
                return;
            }
            var p = palette();
            double chip_pad_x = accents ? 8 : 12;
            double chip_height = accents ? 40 : 30;
            var desc = font(accents ? 15 : 11);
            var layout = measure_layout(desc);
            Area[] next = {};
            double x = PAD;
            double y = PAD;
            double width = 0;
            for (int i = 0; i < items.length; i++) {
                if (accents && i > 0 && i % ACCENTS_PER_ROW == 0) {
                    x = PAD;
                    y += chip_height + GAP;
                }
                int tw, th;
                text_size(layout, items[i], out tw, out th);
                double w = double.max(tw + chip_pad_x * 2, accents ? 34 : 0);
                next += Area() { x = x, y = y, w = w, h = chip_height, action = i };
                x += w + GAP;
                width = double.max(width, x - GAP + PAD);
            }
            double height = y + chip_height + PAD;
            Cairo.ImageSurface surface;
            Cairo.Context cr;
            int scale;
            begin_frame(width, height, out surface, out cr, out scale, p);
            var draw = Pango.cairo_create_layout(cr);
            draw.set_font_description(desc);
            var number = Pango.cairo_create_layout(cr);
            number.set_font_description(font(7));
            for (int i = 0; i < items.length; i++) {
                var a = next[i];
                bool chosen = i == selected;
                if (chosen) {
                    rounded(cr, a.x, a.y, a.w, a.h, 8);
                    cr.set_source_rgba(p.accent.red, p.accent.green, p.accent.blue, 0.9);
                    cr.fill();
                }
                int tw, th;
                draw.set_text(items[i], -1);
                draw.get_pixel_size(out tw, out th);
                cr.move_to(a.x + (a.w - tw) / 2, a.y + (a.h - th) / 2 - (accents ? 4 : 0));
                set_text_color(cr, p, chosen, 0.95);
                Pango.cairo_show_layout(cr, draw);
                if (accents && i < 9) {
                    int nw, nh;
                    number.set_text((i + 1).to_string(), -1);
                    number.get_pixel_size(out nw, out nh);
                    cr.move_to(a.x + (a.w - nw) / 2, a.y + a.h - nh - 2);
                    set_text_color(cr, p, chosen, 0.55);
                    Pango.cairo_show_layout(cr, number);
                }
            }
            areas = next;
            present(surface, scale);
        }

        private static void set_text_color(Cairo.Context cr, Palette p, bool on_accent, double alpha) {
            if (on_accent) cr.set_source_rgba(p.accent_fg.red, p.accent_fg.green, p.accent_fg.blue, alpha);
            else cr.set_source_rgba(p.fg, p.fg, p.fg, alpha);
        }

        public void show_candidates(Candidates list, string preedit) {
            if (list.empty) {
                hide();
                return;
            }
            var p = palette();
            var item_font = font(13);
            var label_font = font(8, true);
            var aux_font = font(10);
            var layout = measure_layout(item_font);
            var label_layout = measure_layout(label_font);
            var aux_layout = measure_layout(aux_font);
            string header = list.auxiliary != "" ? list.auxiliary : preedit;
            double y = PAD;
            double width = 0;
            if (header != "") {
                int aw, ah;
                text_size(aux_layout, header, out aw, out ah);
                width = aw + 12 + PAD * 2;
                y += ah + 4;
            }
            const double ROW = 32;
            Area[] next = {};
            double x = PAD;
            double[] label_widths = {};
            for (int i = 0; i < list.items.length; i++) {
                int tw, th, lw, lh;
                text_size(layout, list.items[i], out tw, out th);
                text_size(label_layout, list.labels[i], out lw, out lh);
                label_widths += lw;
                double w = 10 + lw + 6 + tw + 10;
                if (list.vertical) {
                    next += Area() { x = PAD, y = y, w = w, h = ROW, action = i };
                    y += ROW + 2;
                    width = double.max(width, w + PAD * 2);
                } else {
                    next += Area() { x = x, y = y, w = w, h = ROW, action = i };
                    x += w + GAP;
                }
            }
            if (list.vertical) {
                for (int i = 0; i < next.length; i++) next[i].w = width - PAD * 2;
                y -= 2;
            }
            double arrows_x = list.vertical ? PAD : x;
            double arrows_y = list.vertical ? y + 2 : y;
            if (list.has_previous || list.has_next) {
                next += Area() { x = arrows_x, y = arrows_y, w = 26, h = ROW, action = HIT_PREVIOUS };
                next += Area() { x = arrows_x + 28, y = arrows_y, w = 26, h = ROW, action = HIT_NEXT };
                if (list.vertical) y += ROW + 2;
                else x += 56;
            }
            if (!list.vertical) {
                width = double.max(width, x - GAP + PAD);
                y += ROW;
            }
            double height = y + PAD;
            Cairo.ImageSurface surface;
            Cairo.Context cr;
            int scale;
            begin_frame(width, height, out surface, out cr, out scale, p);
            if (header != "") {
                var aux = Pango.cairo_create_layout(cr);
                aux.set_font_description(aux_font);
                aux.set_text(header, -1);
                cr.move_to(PAD + 6, PAD);
                cr.set_source_rgba(p.fg, p.fg, p.fg, 0.7);
                Pango.cairo_show_layout(cr, aux);
            }
            var item_layout = Pango.cairo_create_layout(cr);
            item_layout.set_font_description(item_font);
            var badge = Pango.cairo_create_layout(cr);
            badge.set_font_description(label_font);
            for (int i = 0; i < list.items.length; i++) {
                var a = next[i];
                bool chosen = i == list.selected;
                if (chosen) {
                    rounded(cr, a.x, a.y, a.w, a.h, 8);
                    cr.set_source_rgba(p.accent.red, p.accent.green, p.accent.blue, 0.9);
                    cr.fill();
                }
                int lw, lh, tw, th;
                badge.set_text(list.labels[i], -1);
                badge.get_pixel_size(out lw, out lh);
                item_layout.set_text(list.items[i], -1);
                item_layout.get_pixel_size(out tw, out th);
                cr.move_to(a.x + 10, a.y + (a.h - lh) / 2);
                set_text_color(cr, p, chosen, 0.6);
                Pango.cairo_show_layout(cr, badge);
                cr.move_to(a.x + 10 + label_widths[i] + 6, a.y + (a.h - th) / 2);
                set_text_color(cr, p, chosen, 0.95);
                Pango.cairo_show_layout(cr, item_layout);
            }
            if (list.has_previous || list.has_next) {
                draw_chevron(cr, p, next[next.length - 2], true, list.has_previous);
                draw_chevron(cr, p, next[next.length - 1], false, list.has_next);
            }
            areas = next;
            present(surface, scale);
        }

        private static void draw_chevron(Cairo.Context cr, Palette p, Area a, bool left, bool enabled) {
            double cx = a.x + a.w / 2;
            double cy = a.y + a.h / 2;
            double d = left ? 3 : -3;
            cr.move_to(cx + d, cy - 6);
            cr.line_to(cx - d, cy);
            cr.line_to(cx + d, cy + 6);
            cr.set_line_width(2);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            cr.set_line_join(Cairo.LineJoin.ROUND);
            cr.set_source_rgba(p.fg, p.fg, p.fg, enabled ? 0.8 : 0.25);
            cr.stroke();
        }

        public void show_dictation(double[] levels, double phase, string text, bool placeholder) {
            var p = palette();
            var desc = font(12);
            var layout = measure_layout(desc);
            layout.set_width(360 * Pango.SCALE);
            layout.set_ellipsize(Pango.EllipsizeMode.START);
            int tw, th;
            text_size(layout, text, out tw, out th);
            const double ICON = 32;
            double bars_w = levels.length * 5;
            double width = PAD + ICON + 10 + bars_w + 12 + tw + 14;
            double height = double.max(ICON, th) + PAD * 2;
            Cairo.ImageSurface surface;
            Cairo.Context cr;
            int scale;
            begin_frame(width, height, out surface, out cr, out scale, p);
            double cx = PAD + ICON / 2;
            double cy = height / 2;
            double ring = Singularity.Motion.Curve.ENTER.ease(phase);
            if (!Singularity.Motion.reduced()) {
                cr.arc(cx, cy, ICON / 2 * (0.7 + 0.3 * ring), 0, 2 * Math.PI);
                cr.set_source_rgba(p.accent.red, p.accent.green, p.accent.blue, 0.35 * (1 - ring));
                cr.fill();
            }
            cr.arc(cx, cy, ICON / 2 * 0.7, 0, 2 * Math.PI);
            cr.set_source_rgba(p.accent.red, p.accent.green, p.accent.blue, 1);
            cr.fill();
            cr.set_source_rgba(p.accent_fg.red, p.accent_fg.green, p.accent_fg.blue, 1);
            rounded(cr, cx - 3, cy - 7, 6, 10, 3);
            cr.fill();
            cr.set_line_width(1.6);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            cr.arc(cx, cy - 1, 5.5, 0, Math.PI);
            cr.stroke();
            cr.move_to(cx, cy + 4.5);
            cr.line_to(cx, cy + 7);
            cr.stroke();
            double bx = PAD + ICON + 10;
            for (int i = 0; i < levels.length; i++) {
                double h = 4 + levels[i] * (height - PAD * 2 - 8);
                rounded(cr, bx + i * 5, cy - h / 2, 3, h, 1.5);
                cr.set_source_rgba(p.accent.red, p.accent.green, p.accent.blue, 0.85);
                cr.fill();
            }
            var draw = Pango.cairo_create_layout(cr);
            draw.set_font_description(desc);
            draw.set_width(360 * Pango.SCALE);
            draw.set_ellipsize(Pango.EllipsizeMode.START);
            draw.set_text(text, -1);
            cr.move_to(bx + bars_w + 12, (height - th) / 2);
            cr.set_source_rgba(p.fg, p.fg, p.fg, placeholder ? 0.6 : 0.95);
            Pango.cairo_show_layout(cr, draw);
            areas = { Area() { x = 0, y = 0, w = width, h = height, action = HIT_DICTATION } };
            present(surface, scale);
        }
    }
}
