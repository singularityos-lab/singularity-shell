using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class ClipboardPopup : Gtk.Window {
        private const int CARD_WIDTH = 360;
        private Box stage;
        private Singularity.Animation.MotionBin card_bin;
        private Box card;
        private Singularity.Widgets.SearchEntry search;
        private ListBox list;
        private Stack body;
        private Singularity.Widgets.StatusPage empty;
        private Button clear_btn;
        private double pointer_x = -1;
        private double pointer_y = -1;
        private uint _place_id = 0;
        private bool _closing = false;

        public ClipboardPopup(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-clipboard");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("clipboard-popup-window");

            stage = new Box(Orientation.VERTICAL, 0);
            stage.hexpand = true;
            stage.vexpand = true;
            set_child(stage);

            card = new Box(Orientation.VERTICAL, 8);
            card.add_css_class("clipboard-popup");
            card.width_request = CARD_WIDTH;

            var header = new Box(Orientation.HORIZONTAL, 8);
            var title = new Label(_("Clipboard"));
            title.add_css_class("clipboard-popup-title");
            title.hexpand = true;
            title.halign = Align.START;
            header.append(title);
            clear_btn = new Button.with_label(_("Clear All"));
            clear_btn.tooltip_text = _("Remove everything except pinned items");
            clear_btn.clicked.connect(() => ClipboardHistory.get_default().model.clear());
            header.append(clear_btn);
            card.append(header);

            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search Clipboard");
            search.search_changed.connect(rebuild);
            search.entry.activate.connect(() => {
                var row = list.get_selected_row() ?? list.get_row_at_index(0);
                if (row != null) pick_row(row);
            });
            card.append(search);

            list = new ListBox();
            list.selection_mode = SelectionMode.SINGLE;
            list.add_css_class("clipboard-list");
            list.row_activated.connect((row) => pick_row(row));
            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.propagate_natural_height = true;
            scroller.max_content_height = 420;
            scroller.set_child(list);

            empty = new Singularity.Widgets.StatusPage();
            empty.compact = true;
            empty.icon_name = "clipboard";

            body = new Stack();
            body.vhomogeneous = false;
            body.add_named(scroller, "list");
            body.add_named(empty, "empty");
            card.append(body);

            var hint = new Label(_("Enter pastes, Delete removes, Esc closes"));
            hint.add_css_class("dim-label");
            hint.add_css_class("caption");
            card.append(hint);

            card_bin = new Singularity.Animation.MotionBin(card);
            card_bin.halign = Align.START;
            card_bin.valign = Align.START;
            stage.append(card_bin);

            var motion = new EventControllerMotion();
            motion.enter.connect((x, y) => {
                if (pointer_x < 0) note_pointer(x, y);
            });
            motion.motion.connect((x, y) => {
                if (pointer_x < 0) note_pointer(x, y);
            });
            ((Widget) this).add_controller(motion);

            var outside = new GestureClick();
            outside.released.connect((n, x, y) => {
                var target = stage.pick(x, y, PickFlags.DEFAULT);
                if (target != null && target != stage) return;
                close_popup();
            });
            stage.add_controller(outside);

            var keys = new EventControllerKey();
            keys.set_propagation_phase(PropagationPhase.CAPTURE);
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape) {
                    close_popup();
                    return true;
                }
                if (keyval == Gdk.Key.Down || keyval == Gdk.Key.Up) {
                    move_selection(keyval == Gdk.Key.Down ? 1 : -1);
                    return true;
                }
                if (keyval == Gdk.Key.Delete && search.text == "") {
                    var row = list.get_selected_row();
                    if (row != null) ClipboardHistory.get_default().model.remove(row.get_data<uint>("entry-id"));
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller(keys);

            CursorPositionRequest.get_default().received.connect((x, y) => {
                if (!visible) return;
                int ox = 0;
                int oy = 0;
                var surface = get_surface();
                var display = Gdk.Display.get_default();
                if (surface != null && display != null) {
                    var monitor = display.get_monitor_at_surface(surface);
                    if (monitor != null) {
                        ox = monitor.geometry.x;
                        oy = monitor.geometry.y;
                    }
                }
                note_pointer(x - ox, y - oy);
            });
            ClipboardHistory.get_default().model.changed.connect(() => {
                if (visible) rebuild();
            });
            this.visible = false;
        }

        private void note_pointer(double x, double y) {
            pointer_x = x;
            pointer_y = y;
            place_card();
        }

        private void place_card() {
            int w = get_width();
            int h = get_height();
            if (w <= 0 || h <= 0) return;
            int card_w, card_h, nat;
            card_bin.measure(Orientation.HORIZONTAL, -1, out card_w, out nat, null, null);
            card_w = int.max(card_w, CARD_WIDTH);
            card_bin.measure(Orientation.VERTICAL, card_w, out card_h, out nat, null, null);
            card_h = int.max(card_h, nat);
            double x = pointer_x >= 0 ? pointer_x : (w - card_w) / 2.0;
            double y = pointer_y >= 0 ? pointer_y : (h - card_h) / 3.0;
            x = double.max(12, double.min(x, w - card_w - 12));
            y = double.max(12, double.min(y, h - card_h - 12));
            card_bin.margin_start = (int) x;
            card_bin.margin_top = (int) y;
        }

        private void move_selection(int delta) {
            var row = list.get_selected_row();
            int index = row != null ? row.get_index() + delta : 0;
            var next = list.get_row_at_index(int.max(0, index));
            if (next != null) {
                list.select_row(next);
                next.grab_focus();
            }
        }

        private void rebuild() {
            var history = ClipboardHistory.get_default();
            Widget? child;
            while ((child = list.get_first_child()) != null) list.remove(child);
            clear_btn.sensitive = history.model.entries.size > 0;
            clear_btn.visible = history.enabled;
            if (!history.enabled) {
                empty.title = _("Clipboard History Is Off");
                empty.description = _("Turn it on to keep what you copy and paste it again later.");
                var on = new Button.with_label(_("Turn On"));
                on.add_css_class("pill");
                on.add_css_class("suggested-action");
                on.halign = Align.CENTER;
                on.clicked.connect(() => {
                    if (history.settings != null) history.settings.set_boolean("history-enabled", true);
                    rebuild();
                });
                empty.child = on;
                body.visible_child_name = "empty";
                return;
            }
            var items = history.model.ordered(search.text);
            if (items.size == 0) {
                bool searching = search.text.strip() != "";
                empty.title = searching ? _("No Matches") : _("Nothing Copied Yet");
                empty.description = searching ? _("Try other words.") : _("Text and images you copy show up here. Passwords are never kept.");
                empty.child = null;
                body.visible_child_name = "empty";
                return;
            }
            body.visible_child_name = "list";
            foreach (var entry in items) list.append(build_row(entry));
            var first = list.get_row_at_index(0);
            if (first != null) list.select_row(first);
        }

        private ListBoxRow build_row(ClipboardEntry entry) {
            var row = new ListBoxRow();
            row.add_css_class("clipboard-row");
            row.set_data<uint>("entry-id", entry.id);
            var box = new Box(Orientation.HORIZONTAL, 8);
            box.margin_top = 6;
            box.margin_bottom = 6;
            box.margin_start = 8;
            box.margin_end = 4;
            if (entry.is_image) {
                try {
                    var tex = Gdk.Texture.from_bytes(entry.data);
                    var pic = new Image.from_paintable(tex);
                    pic.pixel_size = 72;
                    pic.hexpand = true;
                    pic.halign = Align.START;
                    pic.add_css_class("clipboard-image");
                    pic.tooltip_text = _("Image, %d by %d").printf(tex.width, tex.height);
                    box.append(pic);
                } catch (Error e) {
                    var lbl = new Label(_("Image"));
                    lbl.hexpand = true;
                    lbl.halign = Align.START;
                    box.append(lbl);
                }
            } else {
                var lbl = new Label(entry.preview(160));
                lbl.hexpand = true;
                lbl.halign = Align.START;
                lbl.xalign = 0;
                lbl.wrap = true;
                lbl.wrap_mode = Pango.WrapMode.WORD_CHAR;
                lbl.lines = 3;
                lbl.ellipsize = Pango.EllipsizeMode.END;
                lbl.max_width_chars = 34;
                lbl.width_chars = 26;
                box.append(lbl);
            }
            var model = ClipboardHistory.get_default().model;
            uint id = entry.id;
            var pin = new ToggleButton();
            pin.icon_name = "view-pin-symbolic";
            pin.add_css_class("flat");
            pin.add_css_class("circular");
            pin.valign = Align.CENTER;
            pin.active = entry.pinned;
            pin.tooltip_text = entry.pinned ? _("Unpin") : _("Pin");
            pin.toggled.connect(() => model.set_pinned(id, pin.active));
            box.append(pin);
            var del = new Button.from_icon_name("user-trash-symbolic");
            del.add_css_class("flat");
            del.add_css_class("circular");
            del.valign = Align.CENTER;
            del.tooltip_text = _("Remove");
            del.clicked.connect(() => model.remove(id));
            box.append(del);
            row.set_child(box);
            return row;
        }

        private void pick_row(ListBoxRow row) {
            var history = ClipboardHistory.get_default();
            var entry = history.model.find(row.get_data<uint>("entry-id"));
            if (entry == null) return;
            history.copy(entry);
            bool paste = history.paste_on_select;
            close_popup();
            if (paste) {
                Timeout.add(180, () => {
                    history.paste_into_focused();
                    return Source.REMOVE;
                });
            }
        }

        public void toggle() {
            if (visible && !_closing) {
                close_popup();
                return;
            }
            _closing = false;
            pointer_x = -1;
            pointer_y = -1;
            search.text = "";
            rebuild();
            present();
            CursorPositionRequest.get_default().request();
            search.grab_focus();
            Singularity.Motion.reveal(card, Singularity.Motion.Preset.SCALE_FADE);
            if (_place_id != 0) Source.remove(_place_id);
            _place_id = Timeout.add(60, () => {
                _place_id = 0;
                place_card();
                return Source.REMOVE;
            });
        }

        public void close_popup() {
            if (!visible || _closing) return;
            _closing = true;
            var anim = Singularity.Motion.conceal(card, Singularity.Motion.Preset.SCALE_FADE);
            anim.done.connect(() => {
                _closing = false;
                this.visible = false;
            });
        }
    }
}
