using Gtk;

namespace Singularity.Shell {

    /**
     * Display scale picker: a few sensible sizes for the selected monitor,
     * the one matching its pixel density marked as recommended, the
     * resulting workspace size and a live preview of how big things will
     * look compared to now. A custom slider covers any other value.
     */
    public class ScaleChooser : Box {
        private const double[] CANDIDATES = { 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0 };

        public signal void changed(double scale);

        private Label value_label;
        private Label looks_like;
        private FlowBox presets;
        private ToggleButton custom_button;
        private Revealer custom_revealer;
        private Scale custom_scale;
        private DrawingArea preview;
        private ToggleButton[] preset_buttons = {};
        private double[] preset_values = {};
        private int px_w = 0;
        private int px_h = 0;
        private double applied = 1.0;
        private double current = 1.0;
        private bool syncing = false;

        public ScaleChooser() {
            Object(orientation: Orientation.VERTICAL, spacing: 10);
            add_css_class("scale-chooser");
            margin_top = 12;
            margin_bottom = 12;
            margin_start = 12;
            margin_end = 12;

            var header = new Box(Orientation.HORIZONTAL, 8);
            var titles = new Box(Orientation.VERTICAL, 2);
            titles.hexpand = true;
            var title = new Label(_("Scale"));
            title.add_css_class("title");
            title.halign = Align.START;
            looks_like = new Label("");
            looks_like.add_css_class("dim-label");
            looks_like.add_css_class("caption");
            looks_like.halign = Align.START;
            titles.append(title);
            titles.append(looks_like);
            value_label = new Label("");
            value_label.add_css_class("scale-chooser-value");
            value_label.valign = Align.CENTER;
            header.append(titles);
            header.append(value_label);
            append(header);

            presets = new FlowBox();
            presets.selection_mode = SelectionMode.NONE;
            presets.max_children_per_line = 5;
            presets.min_children_per_line = 3;
            presets.column_spacing = 6;
            presets.row_spacing = 6;
            presets.homogeneous = true;
            append(presets);

            custom_scale = new Scale.with_range(Orientation.HORIZONTAL, 1.0, 3.0, 0.05);
            custom_scale.draw_value = false;
            custom_scale.hexpand = true;
            foreach (double value in CANDIDATES) {
                custom_scale.add_mark(value, PositionType.BOTTOM, null);
            }
            custom_scale.value_changed.connect(() => {
                if (syncing) return;
                select(Math.round(custom_scale.get_value() * 20) / 20);
            });
            custom_revealer = new Revealer();
            custom_revealer.child = custom_scale;
            append(custom_revealer);

            preview = new DrawingArea();
            preview.content_height = 96;
            preview.hexpand = true;
            preview.add_css_class("scale-chooser-preview");
            preview.set_draw_func(draw_preview);
            append(preview);
        }

        public void set_monitor(int width, int height, int phys_w_mm, int phys_h_mm,
                                double applied_scale, double scale) {
            px_w = width;
            px_h = height;
            applied = applied_scale > 0 ? applied_scale : 1.0;
            double recommended = Singularity.DisplayManager.dpi_default_scale(phys_w_mm, phys_h_mm, width, height);
            syncing = true;
            rebuild_presets(recommended);
            syncing = false;
            set_scale(scale);
        }

        public void set_scale(double scale) {
            current = scale;
            syncing = true;
            bool matched = false;
            for (int i = 0; i < preset_buttons.length; i++) {
                bool active = (preset_values[i] - scale).abs() < 0.001;
                preset_buttons[i].active = active;
                matched = matched || active;
            }
            custom_button.active = !matched;
            custom_revealer.reveal_child = !matched;
            custom_scale.set_value(scale);
            syncing = false;
            update_labels();
        }

        private void rebuild_presets(double recommended) {
            Widget? child = presets.get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                presets.remove(child);
                child = next;
            }
            preset_buttons = {};
            preset_values = {};
            ToggleButton? group = null;
            foreach (double value in CANDIDATES) {
                bool usable = px_w <= 0 || (px_w / value >= 1024 && px_h / value >= 600);
                if (value > 1.0 && !usable && value != recommended) continue;
                var button = new ToggleButton.with_label("%d%%".printf((int) Math.round(value * 100)));
                button.add_css_class("scale-chooser-preset");
                if ((value - recommended).abs() < 0.001) {
                    button.add_css_class("recommended");
                    button.tooltip_text = _("Recommended for this display");
                }
                if (group == null) group = button;
                else button.group = group;
                double chosen = value;
                button.toggled.connect(() => {
                    if (!syncing && button.active) select(chosen);
                });
                presets.append(button);
                preset_buttons += button;
                preset_values += value;
            }
            custom_button = new ToggleButton.with_label(_("Custom"));
            custom_button.add_css_class("scale-chooser-preset");
            custom_button.group = group;
            custom_button.toggled.connect(() => {
                if (syncing || !custom_button.active) return;
                custom_revealer.reveal_child = true;
            });
            presets.append(custom_button);
        }

        private void select(double scale) {
            if ((scale - current).abs() < 0.001) return;
            current = scale;
            syncing = true;
            custom_scale.set_value(scale);
            syncing = false;
            update_labels();
            changed(scale);
        }

        private void update_labels() {
            value_label.label = "%d%%".printf((int) Math.round(current * 100));
            if (px_w > 0) {
                looks_like.label = _("Looks like %d × %d").printf((int) Math.round(px_w / current),
                    (int) Math.round(px_h / current));
            }
            preview.content_height = (int) (172 * current / applied).clamp(110, 360);
            preview.queue_draw();
        }

        private void draw_preview(DrawingArea area, Cairo.Context cr, int width, int height) {
            Gdk.RGBA fg = area.get_color();
            double ratio = current / applied;

            double window_w = 300 * ratio;
            double window_h = 150 * ratio;
            double x = 12;
            double y = 10;
            rounded(cr, x, y, window_w, window_h, 10 * ratio);
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.07);
            cr.fill();
            rounded(cr, x, y, window_w, 30 * ratio, 10 * ratio);
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.08);
            cr.fill();

            var layout = Pango.cairo_create_layout(cr);
            var font = area.get_pango_context().get_font_description().copy();
            font.set_absolute_size(11 * ratio * Pango.SCALE);
            font.set_weight(Pango.Weight.BOLD);
            layout.set_font_description(font);
            layout.set_text(_("Documents"), -1);
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.9);
            cr.move_to(x + 14 * ratio, y + 8 * ratio);
            Pango.cairo_show_layout(cr, layout);

            font.set_weight(Pango.Weight.NORMAL);
            layout.set_font_description(font);
            layout.set_width((int) ((window_w - 28 * ratio) * Pango.SCALE));
            layout.set_text(_("Text and controls use this size. Pick the one that reads comfortably from where you sit."), -1);
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.75);
            cr.move_to(x + 14 * ratio, y + 42 * ratio);
            Pango.cairo_show_layout(cr, layout);

            var accent = Gdk.RGBA();
            accent.parse(Singularity.Style.StyleManager.get_default().accent_hex);
            rounded(cr, x + 14 * ratio, y + 104 * ratio, 90 * ratio, 28 * ratio, 14 * ratio);
            cr.set_source_rgba(accent.red, accent.green, accent.blue, 1);
            cr.fill();
        }

        private static void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }
    }
}
