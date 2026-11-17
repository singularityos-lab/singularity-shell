using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class OnScreenKeyboard : Gtk.Window {
        private const uint SHIFT = 1;
        private const uint CTRL = 2;
        private const uint ALT = 4;
        private const uint SUPER = 8;

        private struct Key {
            uint code;
            string? label;
            string? icon;
            double width;
            uint modifier;
        }

        private const Key[] ROW_NUMBERS = {
            { 1, "Esc", null, 1.2, 0 }, { 41, null, null, 1, 0 }, { 2, null, null, 1, 0 },
            { 3, null, null, 1, 0 }, { 4, null, null, 1, 0 }, { 5, null, null, 1, 0 },
            { 6, null, null, 1, 0 }, { 7, null, null, 1, 0 }, { 8, null, null, 1, 0 },
            { 9, null, null, 1, 0 }, { 10, null, null, 1, 0 }, { 11, null, null, 1, 0 },
            { 12, null, null, 1, 0 }, { 13, null, null, 1, 0 },
            { 14, null, "edit-clear-symbolic", 1.8, 0 }
        };
        private const Key[] ROW_TOP = {
            { 15, "Tab", null, 1.5, 0 }, { 16, null, null, 1, 0 }, { 17, null, null, 1, 0 },
            { 18, null, null, 1, 0 }, { 19, null, null, 1, 0 }, { 20, null, null, 1, 0 },
            { 21, null, null, 1, 0 }, { 22, null, null, 1, 0 }, { 23, null, null, 1, 0 },
            { 24, null, null, 1, 0 }, { 25, null, null, 1, 0 }, { 26, null, null, 1, 0 },
            { 27, null, null, 1, 0 }, { 43, null, null, 1.5, 0 }
        };
        private const Key[] ROW_HOME = {
            { 58, "Caps", null, 1.8, 0 }, { 30, null, null, 1, 0 }, { 31, null, null, 1, 0 },
            { 32, null, null, 1, 0 }, { 33, null, null, 1, 0 }, { 34, null, null, 1, 0 },
            { 35, null, null, 1, 0 }, { 36, null, null, 1, 0 }, { 37, null, null, 1, 0 },
            { 38, null, null, 1, 0 }, { 39, null, null, 1, 0 }, { 40, null, null, 1, 0 },
            { 28, "Enter", null, 2.2, 0 }
        };
        private const Key[] ROW_BOTTOM = {
            { 42, "Shift", null, 2.3, SHIFT }, { 44, null, null, 1, 0 }, { 45, null, null, 1, 0 },
            { 46, null, null, 1, 0 }, { 47, null, null, 1, 0 }, { 48, null, null, 1, 0 },
            { 49, null, null, 1, 0 }, { 50, null, null, 1, 0 }, { 51, null, null, 1, 0 },
            { 52, null, null, 1, 0 }, { 53, null, null, 1, 0 }, { 54, "Shift", null, 2.3, SHIFT }
        };
        private const Key[] ROW_SPACE = {
            { 29, "Ctrl", null, 1.4, CTRL }, { 125, "Super", null, 1.4, SUPER },
            { 56, "Alt", null, 1.4, ALT }, { 57, "", null, 6.4, 0 },
            { 105, null, "pan-start-symbolic", 1, 0 }, { 108, null, "pan-down-symbolic", 1, 0 },
            { 103, null, "pan-up-symbolic", 1, 0 }, { 106, null, "pan-end-symbolic", 1, 0 },
            { 0, null, "input-keyboard-symbolic", 1.2, 0 }
        };

        private uint latched = 0;
        private uint locked = 0;
        private bool caps = false;
        private uint last_modifier = 0;
        private int64 last_modifier_time = 0;
        private Gee.ArrayList<Button> modifier_buttons = new Gee.ArrayList<Button>();
        private Gee.ArrayList<Button> character_buttons = new Gee.ArrayList<Button>();
        private GLib.Settings settings;
        private Box suggestion_bar;
        private Popover? accent_popover = null;
        private Box rows_box;
        private Box preview_row;
        private Label preview_before;
        private Label preview_after;
        private Gee.ArrayList<Gee.ArrayList<Button>> key_rows = new Gee.ArrayList<Gee.ArrayList<Button>>();
        private Button? highlighted = null;
        private const double REMOTE_SCALE = 1.5;

        public bool remote { get; private set; default = false; }
        public signal void remote_done(bool accepted);

        public OnScreenKeyboard(Gtk.Application app) {
            Object(application: app);
            settings = new GLib.Settings("dev.sinty.desktop");

            init_for_window(this);
            set_namespace(this, "singularity-osk");
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            auto_exclusive_zone_enable(this);

            add_css_class("singularity");
            add_css_class("osk-window");

            var rows = new Box(Orientation.VERTICAL, 6);
            rows.add_css_class("osk");
            rows.halign = Align.CENTER;
            rows_box = rows;
            preview_row = new Box(Orientation.HORIZONTAL, 0);
            preview_row.add_css_class("osk-preview");
            preview_row.visible = false;
            preview_before = new Label("");
            preview_before.ellipsize = Pango.EllipsizeMode.START;
            preview_before.hexpand = true;
            preview_before.xalign = 1;
            var caret = new Box(Orientation.HORIZONTAL, 0);
            caret.add_css_class("osk-caret");
            caret.valign = Align.CENTER;
            preview_after = new Label("");
            preview_after.ellipsize = Pango.EllipsizeMode.END;
            preview_after.hexpand = true;
            preview_after.xalign = 0;
            preview_row.append(preview_before);
            preview_row.append(caret);
            preview_row.append(preview_after);
            rows.append(preview_row);
            suggestion_bar = new Box(Orientation.HORIZONTAL, 6);
            suggestion_bar.add_css_class("osk-suggestions");
            suggestion_bar.halign = Align.CENTER;
            rows.append(suggestion_bar);
            rows.append(build_row(ROW_NUMBERS));
            rows.append(build_row(ROW_TOP));
            rows.append(build_row(ROW_HOME));
            rows.append(build_row(ROW_BOTTOM));
            rows.append(build_row(ROW_SPACE));
            set_child(rows);

            settings.changed["xkb-layout"].connect(apply_layout);
            settings.changed["xkb-variant"].connect(apply_layout);
            apply_layout();

            var ime = InputMethodService.get_default();
            ime.suggestions_changed.connect(show_suggestions);
            show_suggestions("", {});
        }

        private void show_suggestions(string word, string[] suggestions) {
            Widget? child = suggestion_bar.get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                suggestion_bar.remove(child);
                child = next;
            }
            var ime = InputMethodService.get_default();
            var code = ime.code_for_field();
            if (code != null) {
                var use = new Button.with_label(InputMethodService.code_label(code));
                use.add_css_class("osk-suggestion");
                use.add_css_class("osk-code");
                use.focus_on_click = false;
                use.can_focus = false;
                use.clicked.connect(() => ime.insert_code());
                suggestion_bar.append(use);
            }
            if (!settings.get_boolean("spell-suggestions")) return;
            if (word != "") {
                var keep = new Button.with_label("\u201c%s\u201d".printf(word));
                keep.add_css_class("osk-suggestion");
                keep.focus_on_click = false;
                keep.can_focus = false;
                keep.clicked.connect(() => ime.keep_word());
                suggestion_bar.append(keep);
            }
            foreach (string suggestion in suggestions) {
                var button = new Button.with_label(suggestion);
                button.add_css_class("osk-suggestion");
                button.focus_on_click = false;
                button.can_focus = false;
                button.clicked.connect(() => ime.apply_suggestion(suggestion));
                suggestion_bar.append(button);
            }
        }

        private void attach_accent_hold(Button button) {
            var hold = new GestureLongPress();
            hold.propagation_phase = PropagationPhase.CAPTURE;
            hold.pressed.connect(() => {
                var ime = InputMethodService.get_default();
                string label = button.label ?? "";
                if (label.char_count() != 1 || !ime.accent_context()) return;
                string[] variants = AccentTable.variants(label.get_char());
                if (variants.length == 0) return;
                hold.set_state(EventSequenceState.CLAIMED);
                show_accents(button, variants);
            });
            button.add_controller(hold);
        }

        private void close_accents() {
            if (accent_popover != null) accent_popover.popdown();
        }

        private void show_accents(Button anchor, string[] variants) {
            close_accents();
            var popover = new Popover();
            popover.autohide = false;
            accent_popover = popover;
            popover.add_css_class("osk-accents");
            popover.has_arrow = false;
            popover.position = PositionType.TOP;
            var grid = new FlowBox();
            grid.selection_mode = SelectionMode.NONE;
            grid.max_children_per_line = 10;
            grid.min_children_per_line = uint.min(variants.length, 10);
            grid.homogeneous = true;
            foreach (string variant in variants) {
                var choice = new Button.with_label(variant);
                choice.add_css_class("osk-key");
                choice.focus_on_click = false;
                choice.can_focus = false;
                choice.set_size_request(48, 48);
                choice.clicked.connect(() => {
                    InputMethodService.get_default().commit_text(variant);
                    popover.popdown();
                    latched = 0;
                    refresh();
                });
                grid.append(choice);
            }
            popover.child = grid;
            popover.set_parent(anchor);
            popover.closed.connect(() => {
                if (accent_popover == popover) accent_popover = null;
                Idle.add(() => {
                    popover.unparent();
                    return Source.REMOVE;
                });
            });
            popover.popup();
        }

        private Box build_row(Key[] keys) {
            var row = new Box(Orientation.HORIZONTAL, 6);
            row.halign = Align.CENTER;
            var buttons = new Gee.ArrayList<Button>();
            key_rows.add(buttons);
            foreach (var key in keys) {
                var button = new Button();
                button.add_css_class("osk-key");
                button.focus_on_click = false;
                button.can_focus = false;
                button.set_size_request((int) (54 * key.width), 48);
                button.set_data<uint>("code", key.code);
                button.set_data<uint>("width", (uint) Math.round(key.width * 10));
                buttons.add(button);
                if (key.icon != null) {
                    button.icon_name = key.icon;
                    button.add_css_class("osk-key-special");
                } else if (key.label != null) {
                    button.label = key.label;
                    button.add_css_class("osk-key-special");
                } else {
                    character_buttons.add(button);
                    attach_accent_hold(button);
                }
                uint code = key.code;
                uint modifier = key.modifier;
                if (modifier != 0) {
                    button.set_data<uint>("modifier", modifier);
                    modifier_buttons.add(button);
                    button.clicked.connect(() => toggle_modifier(modifier));
                } else if (code == 0) {
                    button.clicked.connect(() => {
                        if (remote) remote_done(false);
                        else settings.set_boolean("screen-keyboard-enabled", false);
                    });
                } else if (code == 28) {
                    button.clicked.connect(() => {
                        if (remote) remote_done(true);
                        else press(code);
                    });
                } else if (code == 58) {
                    button.clicked.connect(() => {
                        caps = !caps;
                        if (caps) button.add_css_class("locked");
                        else button.remove_css_class("locked");
                        refresh();
                    });
                } else {
                    button.clicked.connect(() => press(code));
                }
                row.append(button);
            }
            return row;
        }

        private void apply_layout() {
            Singularity.osk_set_layout(settings.get_string("xkb-layout"), settings.get_string("xkb-variant"));
            refresh();
        }

        private void toggle_modifier(uint modifier) {
            int64 now = GLib.get_monotonic_time();
            bool double_tap = last_modifier == modifier && now - last_modifier_time < 400000;
            last_modifier = modifier;
            last_modifier_time = now;
            if ((locked & modifier) != 0) {
                locked &= ~modifier;
                latched &= ~modifier;
            } else if (double_tap) {
                locked |= modifier;
                latched &= ~modifier;
            } else if ((latched & modifier) != 0) {
                latched &= ~modifier;
            } else {
                latched |= modifier;
            }
            refresh();
        }

        private bool is_letter(uint code) {
            string? plain = Singularity.osk_label(code, false);
            return plain != null && plain.up() != plain;
        }

        private void press(uint code) {
            close_accents();
            var ime = InputMethodService.get_default();
            if (code == 57 && ime.osk_space()) return;
            if (code == 14 && ime.osk_backspace()) return;
            if (code != 57 && code != 14) ime.osk_other_key();
            uint active = latched | locked;
            if (caps && is_letter(code)) active ^= SHIFT;
            Singularity.osk_press(code, active);
            latched = 0;
            refresh();
        }

        private void refresh() {
            uint active = latched | locked;
            foreach (var button in modifier_buttons) {
                uint modifier = button.get_data<uint>("modifier");
                if ((active & modifier) != 0) button.add_css_class("active");
                else button.remove_css_class("active");
                if ((locked & modifier) != 0) button.add_css_class("locked");
                else button.remove_css_class("locked");
            }
            bool shifted = (active & SHIFT) != 0;
            foreach (var button in character_buttons) {
                uint code = button.get_data<uint>("code");
                button.label = Singularity.osk_label(code, shifted != (caps && is_letter(code))) ?? "";
            }
        }
    
        private static bool remote_hidden(uint code) {
            return code == 1 || code == 15 || code == 103 || code == 105 || code == 106 || code == 108;
        }

        public void start_remote(string text, int cursor) {
            remote = true;
            rows_box.add_css_class("remote");
            preview_row.visible = true;
            resize_keys();
            set_preview(text, cursor);
            if (highlighted == null) highlight(find_key(16));
        }

        public void stop_remote() {
            remote = false;
            rows_box.remove_css_class("remote");
            preview_row.visible = false;
            highlight(null);
            resize_keys();
        }

        private void resize_keys() {
            double scale = remote ? REMOTE_SCALE : 1.0;
            foreach (var buttons in key_rows) {
                foreach (var button in buttons) {
                    button.visible = !(remote && remote_hidden(button.get_data<uint>("code")));
                    button.set_size_request((int) (5.4 * button.get_data<uint>("width") * scale), (int) (48 * scale));
                }
            }
        }

        public void set_preview(string text, int cursor) {
            int count = text.char_count();
            int at = cursor.clamp(0, count);
            int split = text.index_of_nth_char(at);
            preview_before.label = text.substring(0, split);
            preview_after.label = text.substring(split);
        }

        private Button? find_key(uint code) {
            foreach (var buttons in key_rows) {
                foreach (var button in buttons) {
                    if (button.get_data<uint>("code") == code) return button;
                }
            }
            return null;
        }

        private void highlight(Button? button) {
            if (highlighted != null) highlighted.remove_css_class("remote-focus");
            highlighted = button;
            if (highlighted != null) highlighted.add_css_class("remote-focus");
        }

        private double center_x(Button button) {
            Graphene.Rect bounds;
            if (!button.compute_bounds(rows_box, out bounds)) return 0;
            return bounds.origin.x + bounds.size.width / 2;
        }

        private int row_of(Button button) {
            for (int i = 0; i < key_rows.size; i++) {
                if (key_rows[i].contains(button)) return i;
            }
            return -1;
        }

        private Gee.ArrayList<Button> visible_keys(int row) {
            var list = new Gee.ArrayList<Button>();
            foreach (var button in key_rows[row]) {
                if (button.visible) list.add(button);
            }
            return list;
        }

        public void navigate(string direction) {
            if (!remote) return;
            if (highlighted == null) {
                highlight(find_key(16));
                return;
            }
            int row = row_of(highlighted);
            if (row < 0) return;
            if (direction == "left" || direction == "right") {
                var keys = visible_keys(row);
                int index = keys.index_of(highlighted) + (direction == "left" ? -1 : 1);
                if (index >= 0 && index < keys.size) highlight(keys[index]);
                return;
            }
            int target = row + (direction == "up" ? -1 : 1);
            if (target < 0 || target >= key_rows.size) return;
            double x = center_x(highlighted);
            Button? best = null;
            double best_distance = double.MAX;
            foreach (var button in visible_keys(target)) {
                double distance = (center_x(button) - x).abs();
                if (distance < best_distance) {
                    best_distance = distance;
                    best = button;
                }
            }
            if (best != null) highlight(best);
        }

        public void activate_highlighted() {
            if (remote && highlighted != null) highlighted.clicked();
        }
    }
}
