using GLib;
using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class ScreenshotThumbnail : Gtk.Window {
        private static ScreenshotThumbnail? _instance = null;
        private Gtk.Picture _picture;
        private Gtk.Label _status;
        private Gtk.Box _actions;
        private string _path = "";
        private uint _timeout_id = 0;
        private bool _hovered = false;
        private bool _menu_open = false;

        public signal void action_requested(string path, string action);

        public static ScreenshotThumbnail get_default(Gtk.Application app) {
            if (_instance == null) _instance = new ScreenshotThumbnail(app);
            return _instance;
        }

        private ScreenshotThumbnail(Gtk.Application app) {
            Object(application: app);
            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_namespace(this, "singularity-screenshot-thumbnail");
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.BOTTOM, 24);
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.RIGHT, 24);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("screenshot-thumbnail");

            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            card.add_css_class("dialog-card");
            card.add_css_class("screenshot-thumbnail-card");

            _picture = new Gtk.Picture();
            _picture.content_fit = Gtk.ContentFit.CONTAIN;
            _picture.can_shrink = true;
            _picture.halign = Gtk.Align.CENTER;
            _picture.add_css_class("screenshot-thumbnail-image");
            _picture.tooltip_text = _("Mark Up");
            _picture.cursor = new Gdk.Cursor.from_name("pointer", null);
            var click = new Gtk.GestureClick();
            click.released.connect(() => run("markup"));
            _picture.add_controller(click);

            var close_btn = new Gtk.Button.from_icon_name("window-close-symbolic");
            close_btn.add_css_class("flat");
            close_btn.add_css_class("singularity-hover-btn");
            close_btn.halign = Gtk.Align.END;
            close_btn.valign = Gtk.Align.START;
            close_btn.margin_top = 6;
            close_btn.margin_end = 6;
            close_btn.tooltip_text = _("Close");
            close_btn.update_property(Gtk.AccessibleProperty.LABEL, _("Close"), -1);
            close_btn.clicked.connect(dismiss);

            var overlay = new Gtk.Overlay();
            overlay.child = _picture;
            overlay.add_overlay(close_btn);
            overlay.add_css_class("singularity-hover-on-content");
            card.append(overlay);

            _status = new Gtk.Label("");
            _status.add_css_class("caption");
            _status.add_css_class("dim-label");
            _status.ellipsize = Pango.EllipsizeMode.END;
            _status.xalign = 0;
            _status.margin_start = 4;
            card.append(_status);

            _actions = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
            _actions.halign = Gtk.Align.CENTER;
            add_action("singularity-markup-symbolic", _("Mark Up"), "markup");
            var note_btn = add_action("document-send-symbolic", _("Add to a Note"), "");
            note_btn.visible = Singularity.Notes.NotePicker.available();
            note_btn.clicked.connect(() => {
                _menu_open = true;
                Singularity.Notes.NotePicker.popup(note_btn, (id) => add_to_note(id), () => {
                    _menu_open = false;
                    arm_timeout(4);
                });
            });
            add_action("edit-copy-symbolic", _("Copy"), "copy");
            add_action("singularity-share-symbolic", _("Share"), "share");
            add_action("folder-open-symbolic", _("Show in Files"), "show");
            add_action("user-trash-symbolic", _("Move to Trash"), "trash");
            card.append(_actions);

            var motion = new Gtk.EventControllerMotion();
            motion.enter.connect(() => _hovered = true);
            motion.leave.connect(() => {
                _hovered = false;
                arm_timeout(4);
            });
            card.add_controller(motion);

            set_child(card);
        }

        private Gtk.Button add_action(string icon, string label, string action) {
            var btn = new Gtk.Button.from_icon_name(icon);
            btn.add_css_class("flat");
            btn.tooltip_text = label;
            btn.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            if (action != "") btn.clicked.connect(() => run(action));
            _actions.append(btn);
            return btn;
        }

        public void show_for(string path, string message, Gdk.Monitor? monitor) {
            _path = path;
            _status.label = message;
            try {
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 256, 160, true);
                _picture.paintable = Gdk.Texture.for_pixbuf(pixbuf);
            } catch (Error e) {
                warning("[ScreenshotThumbnail] preview failed: %s", e.message);
                _picture.paintable = null;
            }
            if (monitor != null) GtkLayerShell.set_monitor(this, monitor);
            present();
            arm_timeout(8);
        }

        private void arm_timeout(uint seconds) {
            if (_timeout_id != 0) Source.remove(_timeout_id);
            _timeout_id = Timeout.add_seconds(seconds, () => {
                _timeout_id = 0;
                if (_hovered || _menu_open) {
                    arm_timeout(2);
                    return Source.REMOVE;
                }
                dismiss();
                return Source.REMOVE;
            });
        }

        private void run(string action) {
            string path = _path;
            dismiss();
            action_requested(path, action);
        }

        private void add_to_note(string? note_id) {
            string name = Singularity.Notes.NotePicker.attachment_name("screenshot", "png");
            Singularity.Notes.NotePicker.add_file.begin(note_id, _("Screenshot"), File.new_for_path(_path), name, "![%s]({link})\n".printf(_("Screenshot")), (obj, res) => {
                try {
                    var note = Singularity.Notes.NotePicker.add_file.end(res);
                    _status.label = note.created ? _("Added to a new note") : _("Added to %s").printf(note.title);
                } catch (Error e) {
                    _status.label = e.message;
                    warning("[ScreenshotThumbnail] add to note failed: %s", e.message);
                }
                arm_timeout(3);
            });
        }

        public void dismiss() {
            if (_timeout_id != 0) {
                Source.remove(_timeout_id);
                _timeout_id = 0;
            }
            _hovered = false;
            _menu_open = false;
            set_visible(false);
        }
    }
}
