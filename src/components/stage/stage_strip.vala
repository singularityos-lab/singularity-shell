using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class StageStrip : Gtk.Window {
        public const int STRIP_WIDTH = 196;
        public const int PAD = 14;
        public const int SPACING = 14;
        public const int CURRENT_HEIGHT = 48;
        public const int TILE_WIDTH = STRIP_WIDTH - 2 * PAD;
        public const int PREVIEW_HEIGHT = 88;
        public const int ICONS_HEIGHT = 24;
        public const int TILE_HEIGHT = PREVIEW_HEIGHT + 6 + ICONS_HEIGHT;
        private const int MAX_STACK = 3;

        private unowned StageManager _manager;
        private string _connector;
        private Box _column;
        private Box _current;
        private Box _sets;
        private Box _new_set;
        private Gee.HashMap<string, Gee.ArrayList<Picture>> _pictures = new Gee.HashMap<string, Gee.ArrayList<Picture>>();
        private bool _dragging = false;
        private bool _origin_valid = false;
        private int _origin_x = 0;
        private int _origin_y = 0;

        public string connector { get { return _connector; } }

        private StageModel model {
            owned get {
                var m = _manager.model_for(_connector);
                return m != null ? m : new StageModel();
            }
        }

        public StageStrip(Gtk.Application app, StageManager manager, string connector) {
            Object(application: app);
            _manager = manager;
            _connector = connector;
            init_for_window(this);
            set_namespace(this, "singularity-stage");
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_exclusive_zone(this, STRIP_WIDTH);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            var own_monitor = _manager.monitor_for_connector(_connector);
            if (own_monitor != null) set_monitor(this, own_monitor);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("stage-strip-window");
            set_default_size(STRIP_WIDTH, -1);

            _column = new Box(Orientation.VERTICAL, SPACING);
            _column.margin_top = PAD;
            _column.margin_bottom = PAD;
            _column.margin_start = PAD;
            _column.margin_end = PAD;
            _column.width_request = TILE_WIDTH;

            _current = new Box(Orientation.HORIZONTAL, 6);
            _current.add_css_class("stage-current");
            _current.height_request = CURRENT_HEIGHT;
            _current.tooltip_text = _("Drop a window here to add it to the stage");
            add_drop(_current, () => model.active != null ? model.active.id : 0, false);
            _column.append(_current);

            _sets = new Box(Orientation.VERTICAL, SPACING);
            _column.append(_sets);

            _new_set = new Box(Orientation.VERTICAL, 4);
            _new_set.add_css_class("stage-new-set");
            _new_set.height_request = 64;
            _new_set.valign = Align.START;
            var add_icon = new Image.from_icon_name("list-add-symbolic");
            add_icon.pixel_size = 20;
            add_icon.vexpand = true;
            add_icon.valign = Align.END;
            _new_set.append(add_icon);
            var add_label = new Label(_("New Set"));
            add_label.vexpand = true;
            add_label.valign = Align.START;
            _new_set.append(add_label);
            _new_set.visible = false;
            add_drop(_new_set, () => 0, true);
            _column.append(_new_set);

            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.vscrollbar_policy = PolicyType.EXTERNAL;
            scroller.set_child(_column);
            set_child(scroller);

            _manager.thumbnail_changed.connect(on_thumbnail_changed);
            map.connect(() => {
                Timeout.add(Motion.Duration.LARGE.ms(), () => {
                    refresh_origin();
                    return Source.REMOVE;
                });
            });
            var monitors = Gdk.Display.get_default() != null ? Gdk.Display.get_default().get_monitors() : null;
            if (monitors != null) monitors.items_changed.connect(() => _origin_valid = false);
        }

        public Gdk.Rectangle? slot_rect(int index) {
            if (index < 0) return null;
            if (!_origin_valid) refresh_origin();
            double top = PAD + CURRENT_HEIGHT + SPACING;
            double step = TILE_HEIGHT + SPACING;
            var first = _sets.get_first_child();
            Graphene.Rect bounds = Graphene.Rect.zero();
            if (first != null && first.compute_bounds(this, out bounds)) {
                top = bounds.get_y();
                var second = first.get_next_sibling();
                Graphene.Rect next = Graphene.Rect.zero();
                if (second != null && second.compute_bounds(this, out next)) step = next.get_y() - bounds.get_y();
            } else if (_sets.compute_bounds(this, out bounds)) {
                top = bounds.get_y();
            }
            var rect = Gdk.Rectangle();
            rect.x = _origin_x + PAD;
            rect.y = _origin_y + (int) Math.round(top + index * step);
            rect.width = TILE_WIDTH;
            rect.height = PREVIEW_HEIGHT;
            return rect;
        }

        public void refresh_origin() {
            _origin_x = 0;
            _origin_y = 0;
            var monitor = _manager.monitor_for_connector(_connector);
            if (monitor == null) return;
            var geo = monitor.get_geometry();
            _origin_x = geo.x;
            _origin_y = geo.y;
            _origin_valid = true;
            int count = Singularity.wayland_get_layout_output_count();
            for (int i = 0; i < count; i++) {
                int wx, wy, ww, wh;
                if (!Singularity.wayland_get_layout_output_workarea(i, out wx, out wy, out ww, out wh)) continue;
                if (wx >= geo.x && wx < geo.x + geo.width) {
                    _origin_y = wy;
                    return;
                }
            }
        }

        public void rebuild(bool cascade, bool arrive = false) {
            _pictures.clear();
            fill_current();
            Widget? child;
            while ((child = _sets.get_first_child()) != null) _sets.remove(child);
            var widgets = new Widget[0];
            foreach (var s in model.inactive_sets()) {
                var tile = build_tile(s);
                _sets.append(tile);
                widgets += tile;
            }
            _new_set.visible = _dragging;
            if (cascade && widgets.length > 0) {
                Motion.cascade(widgets, Motion.Preset.FADE_SLIDE);
            } else if (arrive && widgets.length > 0) {
                Motion.reveal(widgets[0], Motion.Preset.SCALE_FADE);
            }
        }

        private void fill_current() {
            Widget? child;
            while ((child = _current.get_first_child()) != null) _current.remove(child);
            var active = model.active;
            int shown = 0;
            if (active != null) {
                foreach (var key in active.windows) {
                    var win = _manager.window_for(key);
                    if (win == null) continue;
                    if (shown++ >= 5) break;
                    _current.append(build_icon(key, win, 24));
                }
            }
            if (shown > 0 && shown <= 2) {
                var names = new Gee.ArrayList<string>();
                foreach (var key in active.windows) {
                    var win = _manager.window_for(key);
                    if (win == null) continue;
                    string name = app_name(win);
                    if (!names.contains(name)) names.add(name);
                }
                var label = new Label(string.joinv(", ", names.to_array()));
                label.ellipsize = Pango.EllipsizeMode.END;
                label.hexpand = true;
                label.xalign = 0;
                label.add_css_class("stage-current-label");
                _current.append(label);
            }
            if (shown == 0) {
                var empty = new Image.from_icon_name("view-stage-symbolic");
                empty.pixel_size = 16;
                empty.add_css_class("dim-label");
                _current.append(empty);
            }
        }

        private Widget build_tile(StageSet s) {
            var tile = new Box(Orientation.VERTICAL, 6);
            tile.add_css_class("stage-tile");
            tile.width_request = TILE_WIDTH;
            tile.height_request = TILE_HEIGHT;

            var stack = new Overlay();
            stack.add_css_class("stage-tile-preview");
            stack.height_request = PREVIEW_HEIGHT;
            stack.width_request = TILE_WIDTH;
            var base_box = new Box(Orientation.VERTICAL, 0);
            base_box.height_request = PREVIEW_HEIGHT;
            stack.set_child(base_box);

            int depth = int.min(s.windows.size, MAX_STACK);
            var names = new Gee.ArrayList<string>();
            for (int i = depth - 1; i >= 0; i--) {
                string key = s.windows[s.windows.size - 1 - i];
                var win = _manager.window_for(key);
                if (win == null) continue;
                var layer = build_layer(key, win, i);
                stack.add_overlay(layer);
            }
            foreach (var key in s.windows) {
                var win = _manager.window_for(key);
                if (win == null) continue;
                string name = app_name(win);
                if (!names.contains(name)) names.add(name);
            }

            var click = new GestureClick();
            uint id = s.id;
            click.released.connect(() => _manager.activate(id));
            stack.add_controller(click);
            stack.tooltip_text = string.joinv(", ", names.to_array());
            stack.cursor = new Gdk.Cursor.from_name("pointer", null);
            tile.append(stack);

            var icons = new Box(Orientation.HORIZONTAL, 4);
            icons.halign = Align.CENTER;
            icons.height_request = ICONS_HEIGHT;
            int shown = 0;
            foreach (var key in s.windows) {
                var win = _manager.window_for(key);
                if (win == null) continue;
                if (shown++ >= 5) break;
                icons.append(build_icon(key, win, 20));
            }
            tile.append(icons);

            add_drop(tile, () => id, false);
            var bin = new Singularity.Animation.MotionBin(tile);
            return bin;
        }

        private Widget build_layer(string key, AppSystem.Window win, int depth) {
            var frame = new Box(Orientation.VERTICAL, 0);
            frame.add_css_class("stage-thumb");
            frame.margin_start = 8 + depth * 12;
            frame.margin_end = 8 + depth * 12;
            frame.margin_top = 18 - depth * 9;
            frame.margin_bottom = depth * 9;
            frame.overflow = Overflow.HIDDEN;
            var texture = _manager.thumbnail_for(key);
            if (texture != null) {
                var picture = new Picture.for_paintable(texture);
                picture.content_fit = ContentFit.COVER;
                picture.can_shrink = true;
                picture.vexpand = true;
                frame.append(picture);
                remember(key, picture);
            } else {
                frame.add_css_class("stage-thumb-empty");
                var icon = new Image();
                icon.gicon = app_icon(win);
                icon.pixel_size = 48;
                icon.vexpand = true;
                icon.valign = Align.CENTER;
                frame.append(icon);
                var picture = new Picture();
                picture.content_fit = ContentFit.COVER;
                picture.can_shrink = true;
                picture.visible = false;
                picture.vexpand = true;
                frame.append(picture);
                remember(key, picture);
            }
            return frame;
        }

        private void remember(string key, Picture picture) {
            if (!_pictures.has_key(key)) _pictures[key] = new Gee.ArrayList<Picture>();
            _pictures[key].add(picture);
        }

        private void on_thumbnail_changed(string key) {
            if (!_pictures.has_key(key)) {
                var owner = model.set_for(key);
                if (owner != null && owner != model.active) rebuild(false);
                return;
            }
            var texture = _manager.thumbnail_for(key);
            foreach (var picture in _pictures[key]) {
                picture.paintable = texture;
                if (!picture.visible) {
                    picture.visible = true;
                    var sibling = picture.get_prev_sibling();
                    if (sibling != null) sibling.visible = false;
                    var frame = picture.get_parent();
                    if (frame != null) frame.remove_css_class("stage-thumb-empty");
                }
            }
        }

        private Widget build_icon(string key, AppSystem.Window win, int size) {
            var image = new Image();
            image.gicon = app_icon(win);
            image.pixel_size = size;
            image.add_css_class("stage-icon");
            image.tooltip_text = win.title;
            var drag = new DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            drag.prepare.connect((x, y) => new Gdk.ContentProvider.for_value(key));
            drag.drag_begin.connect((source) => {
                drag.set_icon(new WidgetPaintable(image), size / 2, size / 2);
                set_dragging(true);
            });
            drag.drag_end.connect(() => set_dragging(false));
            drag.drag_cancel.connect(() => {
                set_dragging(false);
                return false;
            });
            image.add_controller(drag);
            return image;
        }

        private void set_dragging(bool on) {
            if (_dragging == on) return;
            _dragging = on;
            if (on) {
                _new_set.visible = true;
                Motion.reveal(_new_set, Motion.Preset.FADE);
            } else {
                _new_set.visible = false;
            }
        }

        private delegate uint SetIdFunc();

        private void add_drop(Widget target, owned SetIdFunc set_id, bool new_set) {
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.enter.connect((x, y) => {
                target.add_css_class("stage-drop-hover");
                return Gdk.DragAction.MOVE;
            });
            drop.leave.connect(() => target.remove_css_class("stage-drop-hover"));
            drop.drop.connect((value, x, y) => {
                target.remove_css_class("stage-drop-hover");
                string? key = value.get_string();
                if (key == null) return false;
                uint id = new_set ? 0 : set_id();
                if (!new_set && id == 0) return false;
                if (_manager.monitor_of_window(key) != _connector) return false;
                Idle.add(() => {
                    _manager.move_window(key, id, _connector);
                    return Source.REMOVE;
                });
                return true;
            });
            target.add_controller(drop);
        }

        private static string app_name(AppSystem.Window win) {
            var info = AppSystem.get_default().resolve_app_for_id(win.app_id);
            if (info != null) return info.get_display_name();
            return win.title;
        }

        private static GLib.Icon app_icon(AppSystem.Window win) {
            if (win.gicon != null) return win.gicon;
            var info = AppSystem.get_default().resolve_app_for_id(win.app_id);
            if (info != null && info.get_icon() != null) return info.get_icon();
            return new ThemedIcon.with_default_fallbacks(win.icon_name != "" ? win.icon_name : "application-x-executable");
        }
    }
}
