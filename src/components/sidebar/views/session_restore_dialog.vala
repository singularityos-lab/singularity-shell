using Gtk;
using Gee;

namespace Singularity {

    /**
     * Login-time prompt: "Reopen your previous windows?" with a checklist of
     * the windows from the last session (icon + app name + monitor). The user
     * picks which to restore - nothing is reopened without confirmation.
     */
    public class SessionRestoreDialog : Singularity.Shell.ShellDialog {
        public delegate void RestoreCallback(Gee.ArrayList<SessionEntry> entries);

        private Singularity.Animation.TimedAnimation? _anim = null;

        public SessionRestoreDialog(
            Gtk.Application app,
            Gee.ArrayList<SessionEntry> entries,
            owned RestoreCallback on_restore
        ) {
            Object(application: app,
                   anchor_top: true, anchor_bottom: true,
                   anchor_left: true, anchor_right: true);
            add_css_class("session-restore-dialog");

            var card = new Box(Orientation.VERTICAL, 14);
            card.halign = Align.CENTER;
            card.valign = Align.CENTER;
            card.add_css_class("power-card");   // reuse the centered card styling
            card.margin_top = 28; card.margin_bottom = 28;
            card.margin_start = 40; card.margin_end = 40;
            card.width_request = 460;
            content_box.append(card);

            var icon = new Image.from_icon_name("view-restore-symbolic");
            icon.pixel_size = 48;
            card.append(icon);

            var title = new Label(_("Reopen your windows?"));
            title.add_css_class("title-1");
            card.append(title);

            var sub = new Label(_("Pick which windows from your last session to restore."));
            sub.add_css_class("dim-label");
            sub.add_css_class("body");
            sub.wrap = true; sub.justify = Justification.CENTER;
            card.append(sub);

            // Checklist (preferences-group look).
            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.max_content_height = 320;
            scroller.propagate_natural_height = true;
            var group = new Box(Orientation.VERTICAL, 2);
            group.add_css_class("session-restore-list");
            scroller.set_child(group);
            card.append(scroller);

            foreach (var e in entries) {
                group.append(make_row(e));
            }

            var btn_row = new Box(Orientation.HORIZONTAL, 12);
            btn_row.halign = Align.CENTER;
            btn_row.margin_top = 4;
            card.append(btn_row);

            var not_now = new Button.with_label(_("Not now"));
            not_now.add_css_class("pill");
            not_now.width_request = 132;
            not_now.clicked.connect(() => close_dialog());
            btn_row.append(not_now);

            var restore_btn = new Button.with_label(_("Reopen"));
            restore_btn.add_css_class("pill");
            restore_btn.add_css_class("suggested-action");
            restore_btn.width_request = 132;
            restore_btn.clicked.connect(() => {
                close_dialog();
                on_restore(entries);
            });
            btn_row.append(restore_btn);

            hide();
        }

        private Widget make_row(SessionEntry e) {
            var row = new Box(Orientation.HORIZONTAL, 10);
            row.add_css_class("session-restore-row");
            row.margin_top = 2; row.margin_bottom = 2;

            var img = new Image();
            img.pixel_size = 28;
            if (e.gicon != null) img.gicon = e.gicon;
            else img.icon_name = e.icon_name;
            row.append(img);

            var col = new Box(Orientation.VERTICAL, 0);
            col.hexpand = true;
            // Prefer the app's display name; when it is missing or just the raw app_id (e.g. a
            // toplevel the compositor labelled "Unknown-1"), fall back to the live window title
            // so the row is recognisable instead of showing a placeholder.
            string dn = e.name;
            if (dn == "" || dn == e.app_id) dn = (e.title != "" && !e.title.has_prefix("Unknown") ? e.title : e.app_id);
            var name = new Label(dn);
            name.halign = Align.START;
            name.add_css_class("body");
            col.append(name);
            string loc = (e.monitor != "" && !e.monitor.has_prefix("Unknown")) ? e.monitor : "screen";
            if (e.maximized) loc += " (maximized)";
            else if (e.w > 0) loc += " (%dx%d)".printf(e.w, e.h);
            var meta = new Label(loc);
            meta.halign = Align.START;
            meta.add_css_class("caption"); meta.add_css_class("dim-label");
            col.append(meta);
            row.append(col);

            var check = new CheckButton();
            check.active = true;
            check.valign = Align.CENTER;
            check.toggled.connect(() => { e.selected = check.active; });
            row.append(check);

            return row;
        }

        public override void open_dialog() {
            opacity = 0;
            if (_anim != null) _anim.skip();
            present();
            _anim = new Singularity.Animation.TimedAnimation(
                this, 0, 1, 160,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
            _anim.tick.connect(() => { opacity = _anim.value; });
            _anim.done.connect(() => { _anim = null; });
            _anim.play();
        }

        public override void close_dialog() {
            if (_anim != null) _anim.skip();
            _anim = new Singularity.Animation.TimedAnimation(
                this, 1, 0, 120,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC);
            _anim.tick.connect(() => { opacity = _anim.value; });
            _anim.done.connect(() => { _anim = null; hide(); });
            _anim.play();
        }
    }
}
