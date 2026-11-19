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
        private const int COMPACT_COLUMNS = 20;
        private const int COMPACT_KEY_HEIGHT = 46;
        private const string[] SYMBOLS_ROW_ONE = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" };
        private const string[] SYMBOLS_ROW_TWO = { "@", "#", "€", "_", "&", "-", "+", "(", ")", "/" };
        private const string[] SYMBOLS_ROW_THREE = { "*", "\"", "'", ":", ";", "!", "?" };
        private const string[] MORE_ROW_ONE = { "~", "`", "|", "•", "√", "π", "÷", "×", "§", "∆" };
        private const string[] MORE_ROW_TWO = { "£", "$", "¥", "^", "°", "=", "{", "}", "\\", "%" };
        private const string[] MORE_ROW_THREE = { "©", "®", "™", "[", "]", "<", ">" };
        private const uint[] COMPACT_TOP = { 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 };
        private const uint[] COMPACT_HOME = { 30, 31, 32, 33, 34, 35, 36, 37, 38 };
        private const uint[] COMPACT_BOTTOM = { 44, 45, 46, 47, 48, 49, 50 };

        private Stack? pages = null;
        private const double SWIPE_DISMISS_DISTANCE = 56;

        private const uint FOCUS_HIDE_DELAY_MS = 150;

        public bool follows_focus { get; set; default = false; }
        private ulong focus_handler = 0;
        private uint focus_hide_timeout = 0;
        private bool focus_was_wanted = false;
        private bool local_text_focused = false;
        private ulong window_added_handler = 0;

        public bool remote { get; private set; default = false; }
        public signal void remote_done(bool accepted);

        public OnScreenKeyboard(Gtk.Application app) {
            Object(application: app);
            settings = new GLib.Settings("dev.sinty.desktop");

            init_for_window(this);
            set_namespace(this, "singularity-osk");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
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
            if (compact_screen()) {
                rows.halign = Align.FILL;
                var header = new CenterBox();
                var hide = new Button.from_icon_name("go-down-symbolic");
                hide.add_css_class("osk-suggestion");
                hide.focus_on_click = false;
                hide.can_focus = false;
                hide.clicked.connect(dismiss);
                header.start_widget = hide;
                header.center_widget = suggestion_bar;
                rows.append(header);
                rows.append(build_compact_pages());
                attach_swipe_dismiss(rows);
            } else {
                rows.append(suggestion_bar);
                rows.append(build_row(ROW_NUMBERS));
                rows.append(build_row(ROW_TOP));
                rows.append(build_row(ROW_HOME));
                rows.append(build_row(ROW_BOTTOM));
                rows.append(build_row(ROW_SPACE));
            }
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

        public void follow_input_focus(bool follow) {
            var ime = InputMethodService.get_default();
            follows_focus = follow;
            cancel_focus_hide();
            if (!follow) {
                if (focus_handler != 0) SignalHandler.disconnect(ime, focus_handler);
                focus_handler = 0;
                if (window_added_handler != 0) SignalHandler.disconnect(application, window_added_handler);
                window_added_handler = 0;
                return;
            }
            if (focus_handler == 0) focus_handler = ime.notify["active"].connect(sync_input_focus);
            if (window_added_handler == 0 && application != null) {
                window_added_handler = application.window_added.connect(track_local_window);
                foreach (var window in application.get_windows()) track_local_window(window);
            }
            focus_was_wanted = false;
            sync_local_focus();
        }

        private void track_local_window(Gtk.Window window) {
            if (window == this || window.get_data<bool>("osk-tracked")) return;
            window.set_data<bool>("osk-tracked", true);
            window.notify["focus-widget"].connect(sync_local_focus);
            window.notify["is-active"].connect(sync_local_focus);
            window.notify["visible"].connect(sync_local_focus);
        }

        private void sync_local_focus() {
            if (!follows_focus || application == null) return;
            bool focused = false;
            foreach (var window in application.get_windows()) {
                if (window == this || !window.visible || !window.is_active) continue;
                if (takes_text(window.get_focus())) focused = true;
            }
            local_text_focused = focused;
            sync_input_focus();
        }

        private static bool takes_text(Widget? widget) {
            if (widget is Gtk.Text) return ((Gtk.Text) widget).editable;
            if (widget is Gtk.TextView) return ((Gtk.TextView) widget).editable;
            return false;
        }

        private bool input_wanted() {
            return InputMethodService.get_default().active || local_text_focused;
        }

        private void sync_input_focus() {
            cancel_focus_hide();
            bool wanted = input_wanted();
            bool focused = wanted && !focus_was_wanted;
            focus_was_wanted = wanted;
            if (wanted) {
                if (focused) raise_to_top();
                return;
            }
            focus_hide_timeout = Timeout.add(FOCUS_HIDE_DELAY_MS, () => {
                focus_hide_timeout = 0;
                if (!input_wanted()) set_visible(false);
                return Source.REMOVE;
            });
        }

        private void raise_to_top() {
            if (visible) set_visible(false);
            present();
        }

        private void cancel_focus_hide() {
            if (focus_hide_timeout == 0) return;
            Source.remove(focus_hide_timeout);
            focus_hide_timeout = 0;
        }

        public override void dispose() {
            follow_input_focus(false);
            base.dispose();
        }

        public void dismiss() {
            close_accents();
            if (remote) remote_done(false);
            else if (follows_focus) set_visible(false);
            else settings.set_boolean("screen-keyboard-enabled", false);
        }

        private void attach_swipe_dismiss(Widget area) {
            var drag = new GestureDrag();
            drag.propagation_phase = PropagationPhase.CAPTURE;
            drag.drag_update.connect((dx, dy) => {
                if (dy > SWIPE_DISMISS_DISTANCE && dy > dx.abs() * 2) {
                    drag.set_state(EventSequenceState.CLAIMED);
                    dismiss();
                }
            });
            area.add_controller(drag);
        }

        private static bool compact_screen() {
            var monitors = Gdk.Display.get_default().get_monitors();
            if (monitors.get_n_items() == 0) return false;
            var monitor = (Gdk.Monitor) monitors.get_item(0);
            var area = monitor.geometry;
            return area.width < 640 || area.height > area.width;
        }

        private Grid compact_grid() {
            var grid = new Grid();
            grid.column_homogeneous = true;
            grid.column_spacing = 5;
            grid.row_spacing = 8;
            grid.hexpand = true;
            return grid;
        }

        private Button compact_key(Grid grid, int column, int row, int span) {
            var button = new Button();
            button.add_css_class("osk-key");
            button.focus_on_click = false;
            button.can_focus = false;
            button.hexpand = true;
            button.set_size_request(-1, COMPACT_KEY_HEIGHT);
            grid.attach(button, column, row, span, 1);
            return button;
        }

        private void compact_letter(Grid grid, int column, int row, uint code) {
            var button = compact_key(grid, column, row, 2);
            button.set_data<uint>("code", code);
            character_buttons.add(button);
            attach_accent_hold(button);
            button.clicked.connect(() => press(code));
        }

        private Button compact_special(Grid grid, int column, int row, int span, string? label, string? icon) {
            var button = compact_key(grid, column, row, span);
            button.add_css_class("osk-key-special");
            if (icon != null) button.icon_name = icon;
            else button.label = label;
            return button;
        }

        private void compact_symbols(Grid grid, int column, int row, string[] symbols) {
            for (int i = 0; i < symbols.length; i++) {
                string symbol = symbols[i];
                var button = compact_key(grid, column + i * 2, row, 2);
                button.label = symbol;
                button.clicked.connect(() => type_text(symbol));
            }
        }

        private void compact_bottom_row(Grid grid, int row, string switch_label, string target) {
            compact_special(grid, 0, row, 3, switch_label, null).clicked.connect(() => pages.visible_child_name = target);
            var comma = compact_key(grid, 3, row, 2);
            comma.label = ",";
            comma.clicked.connect(() => type_text(","));
            var space = compact_key(grid, 5, row, 10);
            space.clicked.connect(() => press(57));
            var period = compact_key(grid, 15, row, 2);
            period.label = ".";
            period.clicked.connect(() => type_text("."));
            var enter = compact_special(grid, 17, row, 3, "Enter", null);
            enter.add_css_class("suggested-action");
            enter.clicked.connect(() => press(28));
        }

        private void compact_backspace(Grid grid, int row) {
            compact_special(grid, 17, row, 3, null, "edit-clear-symbolic").clicked.connect(() => press(14));
        }

        private Grid build_compact_letters() {
            var grid = compact_grid();
            for (int i = 0; i < COMPACT_TOP.length; i++) compact_letter(grid, i * 2, 0, COMPACT_TOP[i]);
            for (int i = 0; i < COMPACT_HOME.length; i++) compact_letter(grid, 1 + i * 2, 1, COMPACT_HOME[i]);
            var shift = compact_special(grid, 0, 2, 3, null, "go-up-symbolic");
            shift.set_data<uint>("modifier", SHIFT);
            modifier_buttons.add(shift);
            shift.clicked.connect(() => toggle_modifier(SHIFT));
            for (int i = 0; i < COMPACT_BOTTOM.length; i++) compact_letter(grid, 3 + i * 2, 2, COMPACT_BOTTOM[i]);
            compact_backspace(grid, 2);
            compact_bottom_row(grid, 3, "?123", "symbols");
            return grid;
        }

        private Grid build_compact_symbols(string[] one, string[] two, string[] three, string switch_label, string switch_target) {
            var grid = compact_grid();
            compact_symbols(grid, 0, 0, one);
            compact_symbols(grid, 0, 1, two);
            compact_special(grid, 0, 2, 3, switch_label, null).clicked.connect(() => pages.visible_child_name = switch_target);
            compact_symbols(grid, 3, 2, three);
            compact_backspace(grid, 2);
            compact_bottom_row(grid, 3, "ABC", "letters");
            return grid;
        }

        private Widget build_compact_pages() {
            rows_box.add_css_class("compact");
            pages = new Stack();
            pages.hhomogeneous = true;
            pages.vhomogeneous = true;
            pages.add_named(build_compact_letters(), "letters");
            pages.add_named(build_compact_symbols(SYMBOLS_ROW_ONE, SYMBOLS_ROW_TWO, SYMBOLS_ROW_THREE, "=\\<", "more"), "symbols");
            pages.add_named(build_compact_symbols(MORE_ROW_ONE, MORE_ROW_TWO, MORE_ROW_THREE, "?123", "symbols"), "more");
            pages.visible_child_name = "letters";
            return pages;
        }

        private void type_text(string text) {
            close_accents();
            var ime = InputMethodService.get_default();
            ime.osk_other_key();
            if (!ime.commit_text(text)) Singularity.osk_press_keysym(Gdk.unicode_to_keyval(text.get_char()), 0);
            latched = 0;
            refresh();
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
                    button.clicked.connect(dismiss);
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
