using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class WifiPasswordDialog : Singularity.Shell.ShellDialog {
        private Entry password_entry;
        private Label error_label;
        public string? password { get; private set; default = null; }
        public signal void response(bool accepted);

        public WifiPasswordDialog(string ssid) {
            Object(
                application:   (Gtk.Application) GLib.Application.get_default(),
                anchor_top:    true,
                anchor_bottom: true,
                anchor_left:   true,
                anchor_right:  true
            );

            add_css_class("wifi-password-dialog");

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var icon = new Image.from_icon_name("network-wireless");
            icon.pixel_size = 48;
            box.append(icon);

            var title_label = new Label(_("Connect to <b>%s</b>").printf(GLib.Markup.escape_text(ssid)));
            title_label.use_markup = true;
            title_label.justify = Justification.CENTER;
            title_label.wrap = true;
            box.append(title_label);

            var entry_box = new Box(Orientation.HORIZONTAL, 6);
            password_entry = new Entry();
            password_entry.placeholder_text = _("Password");
            password_entry.visibility = false;
            password_entry.hexpand = true;
            password_entry.activates_default = true;
            entry_box.append(password_entry);
            var visibility_btn = new Button.from_icon_name("view-reveal-symbolic");
            visibility_btn.has_frame = false;
            visibility_btn.tooltip_text = _("Show password");
            visibility_btn.clicked.connect(() => {
                password_entry.visibility = !password_entry.visibility;
                visibility_btn.icon_name = password_entry.visibility
                    ? "view-conceal-symbolic"
                    : "view-reveal-symbolic";
            });
            entry_box.append(visibility_btn);
            box.append(entry_box);

            error_label = new Label("");
            error_label.add_css_class("error-label");
            error_label.wrap = true;
            error_label.visible = false;
            box.append(error_label);

            var btn_box = new Box(Orientation.HORIZONTAL, 12);
            btn_box.halign = Align.END;

            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("pill");
            cancel_btn.clicked.connect(() => {
                password = null;
                response(false);
                close_dialog();
            });
            btn_box.append(cancel_btn);

            var connect_btn = new Button.with_label(_("Connect"));
            connect_btn.add_css_class("pill");
            connect_btn.add_css_class("suggested-action");
            connect_btn.clicked.connect(() => {
                password = password_entry.text;
                response(true);
                close_dialog();
            });
            btn_box.append(connect_btn);
            box.append(btn_box);

            set_default_widget(connect_btn);
            content_box.append(box);
        }

        public void show_error(string msg) {
            error_label.label = msg;
            error_label.visible = true;
            present();
        }
    }
}
