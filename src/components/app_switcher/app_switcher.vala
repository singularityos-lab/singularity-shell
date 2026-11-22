using Gtk;
using GtkLayerShell;

namespace Singularity {

    private class SwitcherGridItem : Box {
        public const int HEIGHT = 160;
        public const int MAX_WIDTH = 284;
        private const int MIN_WIDTH = 120;
        private const int WAITING_WIDTH = 240;

        private AppSystem.Window win;
        private Box thumb_box;
        private Picture preview_img;
        private Image fallback_icon;
        private bool is_destroyed = false;
        private void* _capture_token = null;

        public SwitcherGridItem(AppSystem.Window win, bool selected) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.win = win;

            add_css_class("app-switcher-item");
            add_css_class("preview");
            if (selected) add_css_class("selected");
            valign = Align.CENTER;

            this.destroy.connect(on_destroy);
            setup_ui();
        }

        private void on_destroy() {
            is_destroyed = true;
            if (_capture_token != null) {
                void* tok = _capture_token;
                _capture_token = null;
                Singularity.wayland_cancel_capture(tok);
            }
        }

        private void setup_ui() {
            thumb_box = new Box(Orientation.VERTICAL, 0);
            thumb_box.set_size_request(WAITING_WIDTH, HEIGHT);
            thumb_box.overflow = Overflow.HIDDEN;
            thumb_box.add_css_class("switcher-thumbnail-box");

            var overlay = new Overlay();
            overlay.vexpand = true;

            preview_img = new Picture();
            preview_img.content_fit = ContentFit.CONTAIN;
            preview_img.can_shrink = true;
            preview_img.add_css_class("window-preview-thumbnail");
            var sized = new Box(Orientation.VERTICAL, 0);
            overlay.set_child(sized);
            overlay.add_overlay(preview_img);

            fallback_icon = new Image();
            fallback_icon.pixel_size = 64;
            AppSwitcher.apply_window_icon(fallback_icon, win);
            fallback_icon.halign = Align.CENTER;
            fallback_icon.valign = Align.CENTER;
            fallback_icon.margin_bottom = 24;
            overlay.add_overlay(fallback_icon);

            var title_bar = new Box(Orientation.HORIZONTAL, 6);
            title_bar.add_css_class("window-preview-titlebar");
            title_bar.halign = Align.CENTER;
            title_bar.valign = Align.END;
            title_bar.margin_start = 8;
            title_bar.margin_end = 8;

            var icon = new Image();
            icon.pixel_size = 24;
            AppSwitcher.apply_window_icon(icon, win);
            icon.add_css_class("window-preview-icon");
            title_bar.append(icon);

            var label = new Label(sanitize_utf8(win.title ?? win.app_id ?? ""));
            label.add_css_class("window-preview-label");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 22;
            title_bar.append(label);
            overlay.add_overlay(title_bar);

            thumb_box.append(overlay);
            append(thumb_box);

            capture_preview();
        }

        private void capture_preview() {
            if (win.handle == null) return;

            _capture_token = Singularity.wayland_capture_preview_cancellable(win.handle, (w, h, s, data) => {
                _capture_token = null;
                if (is_destroyed || data == null || w <= 0 || h <= 0 || s <= 0) return;

                unowned uint8[] buf = (uint8[])data;
                buf.length = h * s;
                try {
                    var texture = new Gdk.MemoryTexture(w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, new Bytes(buf), s);
                    thumb_box.set_size_request((HEIGHT * w / h).clamp(MIN_WIDTH, MAX_WIDTH), HEIGHT);
                    preview_img.set_paintable(texture);
                    fallback_icon.visible = false;
                } catch (Error e) {
                }
            });
        }

        private string sanitize_utf8(string? s) {
            if (s == null || s == "") return "";
            if (s.validate()) return s;
            return s.make_valid();
        }
    }

    public class AppSwitcher : Singularity.Shell.ShellDialog {
        private Box outer_box;
        private const int MAX_COLUMNS = 5;
        private const int GRID_GAP = 12;
        private const int GRID_INSET = 8;

        private FlowBox items_box;
        private Box grid_box;
        private Gee.ArrayList<Widget> items = new Gee.ArrayList<Widget>();
        private int grid_width = 800;
        private int grid_height = 500;
        private ScrolledWindow scroll;
        private List<AppSystem.Window> windows;
        private int selected_index = 0;
        private GLib.Settings settings;
        private bool _list_mode = true;
        private uint _tap_check_id = 0;

        public AppSwitcher(Gtk.Application app) {
            Object(
                application: app,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );

            settings = new GLib.Settings("dev.sinty.desktop");
            _list_mode = settings.get_string("switcher-style") != "grid";
            settings.changed["switcher-style"].connect(() => {
                _list_mode = settings.get_string("switcher-style") != "grid";
                configure_layout();
                rebuild_ui();
            });

            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);

            default_width = 800;
            default_height = 500;

            add_css_class("app-switcher-window");

            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                double ox, oy;
                outer_box.translate_coordinates(this, 0, 0, out ox, out oy);
                int ow = outer_box.get_allocated_width();
                int oh = outer_box.get_allocated_height();
                if (x < ox || x > ox + ow || y < oy || y > oy + oh) dismiss();
            });
            ((Gtk.Widget)this).add_controller(click);

            var key_ctrl = new EventControllerKey();
            key_ctrl.key_pressed.connect(on_key_pressed);
            key_ctrl.key_released.connect(on_key_released);
            ((Gtk.Widget)this).add_controller(key_ctrl);

            outer_box = new Box(Orientation.VERTICAL, 0);
            outer_box.add_css_class("power-card");
            outer_box.add_css_class("app-switcher-card");
            outer_box.halign = Align.CENTER;
            outer_box.valign = Align.CENTER;
            outer_box.margin_top = 28;
            outer_box.margin_bottom = 28;
            outer_box.margin_start = 40;
            outer_box.margin_end = 40;

            scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_width = false;
            scroll.propagate_natural_height = false;
            scroll.min_content_height = 0;
            scroll.min_content_width = 0;
            scroll.max_content_height = 500;
            scroll.max_content_width = 900;

            items_box = new FlowBox();
            items_box.selection_mode = SelectionMode.NONE;
            items_box.homogeneous = true;
            items_box.row_spacing = 0;
            items_box.column_spacing = 0;
            items_box.add_css_class("app-switcher-items");
            items_box.margin_top = 8;
            items_box.margin_bottom = 8;
            items_box.margin_start = 8;
            items_box.margin_end = 8;
            grid_box = new Box(Orientation.VERTICAL, GRID_GAP);
            grid_box.margin_top = GRID_INSET;
            grid_box.margin_bottom = GRID_INSET;
            grid_box.margin_start = GRID_INSET;
            grid_box.margin_end = GRID_INSET;
            configure_layout();
            outer_box.append(scroll);
            content_box.append(outer_box);
            hide();
        }

        private bool on_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
            switch (keyval) {
                case Gdk.Key.Tab:
                case Gdk.Key.ISO_Left_Tab:
                    if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) cycle(-1);
                    else cycle(1);
                    return true;
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                    activate_selected();
                    return true;
                case Gdk.Key.Escape:
                    dismiss();
                    return true;
            }
            return false;
        }

        private void on_key_released(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (keyval == Gdk.Key.Alt_L || keyval == Gdk.Key.Alt_R ||
                keyval == Gdk.Key.Meta_L || keyval == Gdk.Key.Meta_R) {
                // Always activate on Alt release - the DBus round-trip overhead
                // (~100-150 ms) means time-based thresholds cause premature dismissals.
                activate_selected();
            }
        }

        // A quick Alt-Tab tap can release Alt before this layer-shell surface
        // acquires keyboard focus (the DBus round-trip costs ~100-150 ms), so
        // on_key_released never fires and the switcher stays up (issue #114).
        // Once focused, the compositor reports the currently-held modifiers, so
        // shortly after presenting we check: if Alt is no longer down, the user
        // tapped - activate the selection and dismiss.
        private void schedule_tap_check() {
            cancel_tap_check();
            _tap_check_id = GLib.Timeout.add(220, () => {
                _tap_check_id = 0;
                if (!visible) return GLib.Source.REMOVE;
                var seat = get_display().get_default_seat();
                var kbd = seat != null ? seat.get_keyboard() : null;
                if (kbd != null && (kbd.get_modifier_state() & Gdk.ModifierType.ALT_MASK) == 0)
                    activate_selected();
                return GLib.Source.REMOVE;
            });
        }

        private void cancel_tap_check() {
            if (_tap_check_id != 0) {
                GLib.Source.remove(_tap_check_id);
                _tap_check_id = 0;
            }
        }

        private void refresh_window_list() {
            windows = AppSystem.get_default().get_mru_windows();
            if (windows.length() == 0)
                windows = AppSystem.get_default().get_windows();
        }

        private void rebuild_ui() {
            clear_items();
            if (windows.length() == 0) return;
            int columns = grid_columns();
            Box? row = null;
            int i = 0;
            foreach (var win in windows) {
                if (win == null) { i++; continue; }
                int idx = i;
                Widget item;
                if (_list_mode) {
                    item = build_list_item(win, idx == selected_index);
                    var child = new FlowBoxChild();
                    child.set_child(item);
                    items_box.append(child);
                } else {
                    item = build_grid_item(win, idx == selected_index);
                    if (row == null || items.size % columns == 0) {
                        row = new Box(Orientation.HORIZONTAL, GRID_GAP);
                        row.halign = Align.CENTER;
                        grid_box.append(row);
                    }
                    row.append(item);
                }
                var c = new GestureClick();
                c.pressed.connect((n, x, y) => { selected_index = idx; activate_selected(); });
                item.add_controller(c);
                items.add(item);
                i++;
            }
            update_viewport_size();
        }

        private void clear_items() {
            items.clear();
            while (items_box.get_first_child() != null)
                items_box.remove(items_box.get_first_child());
            while (grid_box.get_first_child() != null)
                grid_box.remove(grid_box.get_first_child());
        }

        private int grid_columns() {
            int slot = SwitcherGridItem.MAX_WIDTH + GRID_GAP;
            return ((grid_width - 2 * GRID_INSET + GRID_GAP) / slot).clamp(1, MAX_COLUMNS);
        }

        private void configure_layout() {
            items_box.min_children_per_line = 1;
            items_box.max_children_per_line = 1;
            scroll.propagate_natural_width = !_list_mode;
            scroll.max_content_width = _list_mode ? default_width : grid_width;
            scroll.max_content_height = _list_mode ? default_height : grid_height;
            scroll.set_child(_list_mode ? (Widget) items_box : (Widget) grid_box);
        }

        private void update_viewport_size() {
            int count = (int)windows.length();
            if (_list_mode) {
                scroll.set_size_request(360, int.min(500, count * 48 + 16));
            } else {
                int columns = grid_columns();
                int rows = (count + columns - 1) / columns;
                int height = rows * SwitcherGridItem.HEIGHT + (rows - 1) * GRID_GAP + 2 * GRID_INSET;
                scroll.set_size_request(-1, int.min(grid_height, height));
            }
        }

        private Box build_list_item(AppSystem.Window win, bool selected) {
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.add_css_class("app-switcher-item");
            if (selected) box.add_css_class("selected");
            box.margin_top = 2;
            box.margin_bottom = 2;
            box.margin_start = 6;
            box.margin_end = 6;
            box.width_request = 300;

            var icon = make_icon(win, 32);
            box.append(icon);

            var label = new Label(sanitize_utf8(win.title ?? win.app_id ?? ""));
            label.halign = Align.START;
            label.hexpand = true;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 40;
            box.append(label);

            return box;
        }

        private SwitcherGridItem build_grid_item(AppSystem.Window win, bool selected) {
            return new SwitcherGridItem(win, selected);
        }

        private Image make_icon(AppSystem.Window win, int size) {
            var icon = new Image();
            icon.pixel_size = size;
            apply_window_icon(icon, win);
            return icon;
        }

        // Resolve an icon for a window: app icon first, then the window's app_id
        // (and common variants) looked up in the icon theme, so windows whose
        // .desktop icon is not themed still show a real icon instead of the
        // generic placeholder. Wayland toplevels do not expose their own icon.
        internal static void apply_window_icon(Image icon, AppSystem.Window win) {
            if (win.gicon != null) { icon.set_from_gicon(win.gicon); return; }
            var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
            // Try themed names: the window icon_name, then the app_id and its
            // common variants. Only use a name the theme actually has, so we
            // do not set a bogus name (e.g. "Minecraft 26.1.2") that renders
            // as a broken icon and blocks the fallbacks below.
            string[] cands = {};
            if (win.icon_name != null && win.icon_name != "") cands += win.icon_name;
            string aid = win.app_id;
            if (aid != null && aid != "") {
                cands += aid;
                cands += aid.down();
                int dot = aid.last_index_of(".");
                if (dot >= 0 && dot + 1 < aid.length) cands += aid.substring(dot + 1).down();
            }
            foreach (string c in cands)
                if (theme.has_icon(c)) { icon.icon_name = c; return; }
            // XWayland apps (games, Wine, Discord) carry their icon in
            // _NET_WM_ICON; use it before the generic placeholder (#93).
            var tex = Singularity.xwayland_icon(win.app_id, win.title);
            if (tex != null) { icon.set_from_paintable(tex); return; }
            icon.icon_name = "application-x-executable";
        }

        private string sanitize_utf8(string? s) {
            if (s == null || s == "") return "";
            if (s.validate()) return s;
            return s.make_valid();
        }

        private void cycle(int direction) {
            if (windows.length() == 0) return;
            int old = selected_index;
            selected_index = ((selected_index + direction) + (int)windows.length()) % (int)windows.length();
            update_selection(old, selected_index);
        }

        private void update_selection(int old_idx, int new_idx) {
            if (old_idx < items.size) items[old_idx].remove_css_class("selected");
            if (new_idx < items.size) {
                items[new_idx].add_css_class("selected");
                scroll_selected_into_view(items[new_idx]);
            }
        }

        private void scroll_selected_into_view(Gtk.Widget item) {
            Gtk.Widget content = _list_mode ? (Gtk.Widget) items_box : (Gtk.Widget) grid_box;
            Graphene.Rect bounds;
            if (!item.compute_bounds(content, out bounds)) return;
            int inset = GRID_INSET;
            scroll_axis_into_view(scroll.hadjustment, (int) bounds.origin.x, (int) bounds.size.width + 2 * inset);
            scroll_axis_into_view(scroll.vadjustment, (int) bounds.origin.y, (int) bounds.size.height + 2 * inset);
        }

        private void scroll_axis_into_view(Gtk.Adjustment adj, int item_start, int item_size) {
            int item_end = item_start + item_size;
            int viewport_size = (int)adj.page_size;
            if (item_start < (int)adj.value) {
                adj.value = item_start;
            } else if (item_end > (int)adj.value + viewport_size) {
                adj.value = item_end - viewport_size;
            }
        }

        private void activate_selected() {
            if (windows.length() == 0) { dismiss(); return; }
            var win = windows.nth_data(selected_index);
            if (win == null) { dismiss(); return; }
            if (win.handle != null)
                Singularity.wayland_activate_window(win.handle);
            dismiss();
        }

        private void dismiss() {
            cancel_tap_check();
            // Remove grid items first so SwitcherGridItem.on_destroy() cancels
            // any in-flight captures before the window is hidden.
            clear_items();
            hide();
        }

        public void show_and_cycle_next() {
            refresh_window_list();
            if (windows.length() == 0) return;
            if (!visible) {
                anchor_to_focused_monitor();
                selected_index = (int)windows.length() > 1 ? 1 : 0;
                rebuild_ui();
                opacity = 1;
                present();
                schedule_tap_check();
            } else {
                cancel_tap_check();
                cycle(1);
            }
        }

        public void show_and_cycle_prev() {
            refresh_window_list();
            if (windows.length() == 0) return;
            if (!visible) {
                anchor_to_focused_monitor();
                selected_index = (int)windows.length() - 1;
                rebuild_ui();
                opacity = 1;
                present();
                schedule_tap_check();
            } else {
                cancel_tap_check();
                cycle(-1);
            }
        }

        private void anchor_to_focused_monitor() {
            Gdk.Monitor? target_mon = null;
            var focused = AppSystem.get_default().get_focused_window_handle();
            if (focused != null) {
                target_mon = Singularity.wayland_get_window_monitor(focused);
            }
            if (target_mon == null) {
                target_mon = Singularity.Panel.find_primary_monitor();
            }
            if (target_mon != null) {
                GtkLayerShell.set_monitor(this, target_mon);
                var geom = target_mon.get_geometry();
                int max_w = int.max(320, (int)(geom.width * 0.70));
                int max_h = int.max(180, (int)(geom.height * 0.60));
                default_width = int.min(800, max_w);
                default_height = int.min(500, max_h);
                grid_width = int.max(320, (int)(geom.width * 0.9) - 80);
                grid_height = int.max(180, (int)(geom.height * 0.8));
                configure_layout();
            }
        }
    }
}
