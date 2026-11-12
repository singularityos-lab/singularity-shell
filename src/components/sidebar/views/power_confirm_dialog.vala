using Gtk;

namespace Singularity {

    // A centered ShellDialog that asks for confirmation before a destructive session action.
    // Usage: new PowerConfirmDialog(app, "Power Off", "power-off-symbolic",
    //            "Your device will shut down.", "Power Off", () => { ... }).open_dialog();
    public class PowerConfirmDialog : Singularity.Shell.ShellDialog {
        public delegate void ConfirmCallback();

        private Singularity.Animation.TimedAnimation? _anim = null;

        public PowerConfirmDialog(
            Gtk.Application app,
            string title,
            string icon_name,
            string description,
            string confirm_label,
            owned ConfirmCallback on_confirm,
            bool destructive = true
        ) {
            Object(
                application: app,
                anchor_top:    true,
                anchor_bottom: true,
                anchor_left:   true,
                anchor_right:  true
            );
            add_css_class("power-confirm-dialog");

            var box = new Box(Orientation.VERTICAL, 14);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            box.add_css_class("power-card");
            box.margin_top    = 28;
            box.margin_bottom = 28;
            box.margin_start  = 40;
            box.margin_end    = 40;
            content_box.append(box);

            var icon = new Image.from_icon_name(icon_name);
            icon.pixel_size = 56;
            box.append(icon);

            var title_label = new Label(title);
            title_label.add_css_class("title-1");
            box.append(title_label);

            var desc_label = new Label(description);
            desc_label.add_css_class("dim-label");
            desc_label.add_css_class("body");
            desc_label.wrap = true;
            desc_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            desc_label.max_width_chars = 48;
            desc_label.justify = Justification.CENTER;
            box.append(desc_label);

            var btn_row = new Box(Orientation.HORIZONTAL, 12);
            btn_row.halign = Align.CENTER;
            btn_row.margin_top = 4;
            box.append(btn_row);

            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.add_css_class("pill");
            cancel_btn.width_request = 128;
            cancel_btn.clicked.connect(() => close_dialog());
            btn_row.append(cancel_btn);

            var confirm_btn = new Button.with_label(confirm_label);
            confirm_btn.add_css_class("pill");
            confirm_btn.add_css_class(destructive ? "destructive-action" : "suggested-action");
            confirm_btn.width_request = 128;
            confirm_btn.clicked.connect(() => {
                close_dialog();
                on_confirm();
            });
            btn_row.append(confirm_btn);

            hide();
        }

        public override void open_dialog() {
            opacity = 0;
            if (_anim != null) _anim.skip();
            present();
            _anim = new Singularity.Animation.TimedAnimation(
                this, 0, 1, 160,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC
            );
            _anim.tick.connect(() => { opacity = _anim.value; });
            _anim.done.connect(() => { _anim = null; });
            _anim.play();
        }

        public override void close_dialog() {
            if (_anim != null) _anim.skip();
            _anim = new Singularity.Animation.TimedAnimation(
                this, 1, 0, 120,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC
            );
            _anim.tick.connect(() => { opacity = _anim.value; });
            _anim.done.connect(() => {
                _anim = null;
                hide();
            });
            _anim.play();
        }
    }
}
