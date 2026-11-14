using Gtk;

namespace Singularity {

    public class AegisIndicator : Gtk.Button {
        private static bool styled = false;
        private Image icon;
        private Label text;
        private weak Widget? bar;

        public AegisIndicator(Widget? bar) {
            Object();
            this.bar = bar;
            ensure_style();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("aegis-indicator");

            var box = new Box(Orientation.HORIZONTAL, 8);
            icon = new Image.from_icon_name("dialog-warning-symbolic");
            icon.pixel_size = 16;
            box.append(icon);
            text = new Label("");
            text.ellipsize = Pango.EllipsizeMode.END;
            text.max_width_chars = 52;
            text.add_css_class("aegis-indicator-text");
            box.append(text);
            set_child(box);

            var client = AegisClient.get_default();
            clicked.connect(() => client.open_requested());
            client.changed.connect(sync);
            sync();
        }

        private void sync() {
            var top = AegisClient.get_default().top;
            visible = top != null;
            if (bar != null) {
                if (top != null && top.danger) bar.add_css_class("aegis-active");
                else bar.remove_css_class("aegis-active");
            }
            if (top == null) return;
            var theme = IconTheme.get_for_display(get_display());
            icon.icon_name = theme.has_icon(top.icon_name) ? top.icon_name : "dialog-warning-symbolic";
            text.label = top.headline;
            tooltip_text = top.headline;
            update_property(Gtk.AccessibleProperty.LABEL, top.headline, -1);
        }

        private static void ensure_style() {
            if (styled) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            styled = true;
            var provider = new Gtk.CssProvider();
            provider.load_from_data(CSS.data);
            StyleContext.add_provider_for_display(display, provider, STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
        }

        private const string CSS = """
            .panel.aegis-active {
                background-color: #5a0d12;
                background-image: none;
                color: #ffffff;
                transition: background-color 400ms ease;
            }
            .panel.aegis-active image,
            .panel.aegis-active label { color: #ffffff; }
            .aegis-indicator { padding: 0 10px; }
            .aegis-indicator-text { font-weight: 700; }
        """;
    }
}
