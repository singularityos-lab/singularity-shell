using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class PhoneHome : Gtk.Window {
        private const int COLUMNS = 4;
        private const int WIDE_SLOT = 150;
        private const int WIDE_MIN_COLUMNS = 6;
        private const int WIDE_MAX_COLUMNS = 8;
        private const int SPACING = 8;
        private const int CELL_HEIGHT = 104;
        private const int ICON_SIZE = 64;
        private const int TOP_GAP = 16;
        private const int DOTS_HEIGHT = 28;
        private const double EDIT_SCALE = 0.84;
        private const double PAGE_COMMIT = 0.18;
        private const double SWIPE_SLOP = 12.0;
        private const int BAR_TRAVEL = 48;
        private const int EDGE_ZONE = 40;
        private const uint EDGE_DWELL_MS = 650;

        private unowned Gdk.Monitor _monitor;
        private AppLauncherGrid _grid;
        private ScrolledWindow _pager;
        private Box _dots;
        private Singularity.Animation.MotionBin _stage;
        private Singularity.Animation.MotionBin _bar;
        private int _width = 0;
        private int _height = 0;
        private int _page = 0;
        private bool _editing = false;
        private bool _wide = false;
        private bool _swiping = false;
        private double _swipe_origin = 0;
        private double _scroll_x = 0;
        private double _wheel_dx = 0;
        private int _edge_dir = 0;
        private uint _edge_source = 0;

        public bool editing { get { return _editing; } }

        public PhoneHome(Gtk.Application app, Gdk.Monitor monitor, bool wide = false) {
            Object(application: app);
            _monitor = monitor;
            _wide = wide;
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-phone-home");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("phone-home");

            _grid = new AppLauncherGrid(app, ICON_SIZE, COLUMNS, SPACING);
            _grid.reorder_enabled = false;
            _grid.clip_cells = false;
            _grid.label_lines = 1;
            _grid.halign = Align.START;
            _grid.valign = Align.START;
            _grid.margin_top = TOP_GAP;
            _grid.notify["page-count"].connect(() => refresh_pages());
            _grid.on_edit_requested = () => enter_edit();

            _pager = new ScrolledWindow();
            _pager.hscrollbar_policy = PolicyType.EXTERNAL;
            _pager.vscrollbar_policy = PolicyType.NEVER;
            _pager.kinetic_scrolling = false;
            _pager.vexpand = true;
            _pager.child = _grid;
            var viewport = _pager.child as Viewport;
            if (viewport != null) viewport.scroll_to_focus = false;
            _pager.add_css_class("phone-home-pages");
            var page_drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            page_drop.drop.connect((val, x, y) => {
                string? dragged = val.get_string();
                if (dragged == null || !_editing) return false;
                Graphene.Point p;
                if (!_pager.compute_point(_grid, Graphene.Point() { x = (float) x, y = (float) y }, out p)) return false;
                return _grid.drop_on_empty(dragged, p.x);
            });
            _pager.add_controller(page_drop);

            _dots = new Box(Orientation.HORIZONTAL, 6);
            _dots.add_css_class("singularity-carousel-dots");
            _dots.halign = Align.CENTER;
            _dots.height_request = DOTS_HEIGHT;
            _dots.valign = Align.CENTER;

            var column = new Box(Orientation.VERTICAL, 0);
            column.append(_pager);
            column.append(_dots);
            _stage = new Singularity.Animation.MotionBin(column);
            _stage.transform_input = true;

            var bar = new Box(Orientation.HORIZONTAL, 12);
            bar.add_css_class("phone-home-edit-bar");
            bar.halign = Align.CENTER;
            bar.valign = Align.END;
            bar.margin_bottom = 12;
            bar.append(edit_button("preferences-desktop-wallpaper-symbolic", _("Wallpaper"), () => {
                leave_edit();
                wallpaper_requested();
            }));
            bar.append(edit_button("view-grid-symbolic", _("Widgets"), () => {
                _grid.insert_page = _page;
                _grid.show_widget_picker(_bar);
            }));
            bar.append(edit_button("object-select-symbolic", _("Done"), () => leave_edit()));
            _bar = new Singularity.Animation.MotionBin(bar);
            _bar.halign = Align.CENTER;
            _bar.valign = Align.END;
            _bar.visible = false;

            var root = new Overlay();
            root.child = _stage;
            root.add_overlay(_bar);
            set_child(root);

            install_gestures(root);
            map.connect_after(() => Idle.add(() => {
                fit();
                return Source.REMOVE;
            }));
        }

        public signal void wallpaper_requested();

        public Gdk.Monitor monitor { get { return _monitor; } }

        public double scroll_x {
            get { return _scroll_x; }
            set {
                _scroll_x = value;
                _pager.hadjustment.value = value;
            }
        }

        private delegate void EditAction();

        private Button edit_button(string icon, string label, owned EditAction action) {
            var content = new Box(Orientation.HORIZONTAL, 8);
            content.append(new Image.from_icon_name(icon));
            content.append(new Label(label));
            var b = new Button();
            b.add_css_class("pill");
            b.child = content;
            b.clicked.connect(() => action());
            return b;
        }

        public override void size_allocate(int width, int height, int baseline) {
            base.size_allocate(width, height, baseline);
            if (width == _width && height == _height) return;
            _width = width;
            _height = height;
            Idle.add(() => {
                fit();
                return Source.REMOVE;
            });
        }

        private void fit() {
            if (_width <= 0 || _height <= 0) return;
            int columns = _wide ? (_width / WIDE_SLOT).clamp(WIDE_MIN_COLUMNS, WIDE_MAX_COLUMNS) : COLUMNS;
            int slot = _width / columns;
            int rows = int.max(1, (_height - TOP_GAP - DOTS_HEIGHT) / (CELL_HEIGHT + SPACING));
            _grid.margin_start = SPACING / 2;
            _grid.set_cell_metrics(slot, slot - SPACING, CELL_HEIGHT, SPACING, columns);
            _grid.page_rows = rows;
            _grid.set_columns_for_width(_width);
            _grid.populate();
            refresh_pages();
        }

        private void refresh_pages() {
            int pages = int.max(1, _grid.page_count);
            if (_width > 0) _grid.width_request = pages * _width;
            if (_page >= pages) _page = pages - 1;
            Widget? c = _dots.get_first_child();
            while (c != null) {
                var next = c.get_next_sibling();
                _dots.remove(c);
                c = next;
            }
            for (int i = 0; i < pages; i++) {
                var dot = new Button();
                dot.add_css_class("flat");
                dot.add_css_class("phone-home-dot-button");
                var mark = new Box(Orientation.HORIZONTAL, 0);
                mark.add_css_class("singularity-carousel-dot");
                if (i == _page) mark.add_css_class("active");
                mark.set_size_request(8, 8);
                mark.halign = Align.CENTER;
                mark.valign = Align.CENTER;
                dot.child = mark;
                int target = i;
                dot.clicked.connect(() => go_to_page(target));
                _dots.append(dot);
            }
            _dots.visible = pages > 1 || _editing;
        }

        private void mark_dots() {
            int i = 0;
            for (Widget? c = _dots.get_first_child(); c != null; c = c.get_next_sibling()) {
                var mark = ((Button) c).child;
                if (i == _page) mark.add_css_class("active");
                else mark.remove_css_class("active");
                i++;
            }
        }

        public void go_to_page(int page) {
            int pages = int.max(1, _grid.page_count);
            _page = page.clamp(0, pages - 1);
            mark_dots();
            _scroll_x = _pager.hadjustment.value;
            Singularity.Motion.spring_to(this, "scroll-x", _page * (double) _width, Singularity.Motion.Spring.SNAPPY);
        }

        private void settle_from(double travel) {
            int page = _page;
            if (travel > _width * PAGE_COMMIT) page++;
            else if (travel < -_width * PAGE_COMMIT) page--;
            go_to_page(page);
        }

        private bool over_item(Widget root, double x, double y) {
            Widget? hit = root.pick(x, y, PickFlags.DEFAULT);
            while (hit != null && hit != root) {
                if (hit.get_data<string>("grid-key") != null) return true;
                if (hit is Button) return true;
                hit = hit.get_parent();
            }
            return false;
        }

        private void install_gestures(Widget root) {
            var swipe = new GestureDrag();
            swipe.propagation_phase = PropagationPhase.CAPTURE;
            swipe.drag_begin.connect((x, y) => {
                _swiping = false;
                if (_editing && over_item(root, x, y)) swipe.set_state(EventSequenceState.DENIED);
            });
            swipe.drag_update.connect((dx, dy) => {
                if (!_swiping) {
                    if (Math.fabs(dx) < SWIPE_SLOP || Math.fabs(dx) < Math.fabs(dy)) return;
                    _swiping = true;
                    swipe.set_state(EventSequenceState.CLAIMED);
                    Singularity.Motion.cancel(this, "scroll-x");
                    _swipe_origin = _pager.hadjustment.value;
                }
                double scale = _editing ? EDIT_SCALE : 1.0;
                double max = (int.max(1, _grid.page_count) - 1) * (double) _width;
                scroll_x = (_swipe_origin - dx / scale).clamp(0, max);
            });
            swipe.drag_end.connect((dx, dy) => {
                if (!_swiping) return;
                _swiping = false;
                settle_from(-dx);
            });
            swipe.cancel.connect(() => {
                if (!_swiping) return;
                _swiping = false;
                go_to_page(_page);
            });
            root.add_controller(swipe);

            var wheel = new EventControllerScroll(EventControllerScrollFlags.BOTH_AXES);
            wheel.scroll_begin.connect(() => {
                Singularity.Motion.cancel(this, "scroll-x");
                _swipe_origin = _pager.hadjustment.value;
                _wheel_dx = 0;
            });
            wheel.scroll.connect((dx, dy) => {
                double delta = Math.fabs(dx) >= Math.fabs(dy) ? dx : dy;
                if (wheel.get_unit() == Gdk.ScrollUnit.WHEEL) {
                    if (delta != 0) go_to_page(_page + (delta > 0 ? 1 : -1));
                    return true;
                }
                double max = (int.max(1, _grid.page_count) - 1) * (double) _width;
                _wheel_dx += delta;
                scroll_x = (_swipe_origin + _wheel_dx).clamp(0, max);
                return true;
            });
            wheel.scroll_end.connect(() => {
                if (wheel.get_unit() == Gdk.ScrollUnit.WHEEL) return;
                settle_from(_wheel_dx);
                _wheel_dx = 0;
            });
            _grid.add_controller(wheel);

            var dnd = new DropControllerMotion();
            dnd.motion.connect((x, y) => edge_hover(x));
            dnd.leave.connect(() => stop_edge());
            root.add_controller(dnd);

            var hold = new GestureLongPress();
            hold.pressed.connect((x, y) => {
                if (_editing || over_item(root, x, y)) return;
                show_home_menu(root, x, y);
            });
            root.add_controller(hold);

            var context = new GestureClick();
            context.button = Gdk.BUTTON_SECONDARY;
            context.pressed.connect((n, x, y) => {
                if (_editing || over_item(root, x, y)) return;
                show_home_menu(root, x, y);
            });
            root.add_controller(context);

            var tap = new GestureClick();
            tap.released.connect((n, x, y) => {
                if (_editing && !over_item(root, x, y)) leave_edit();
            });
            root.add_controller(tap);
        }

        private void edge_hover(double x) {
            int dir = x < EDGE_ZONE ? -1 : (x > _width - EDGE_ZONE ? 1 : 0);
            if (dir == _edge_dir) return;
            stop_edge();
            if (dir == 0) return;
            _edge_dir = dir;
            _edge_source = Timeout.add(EDGE_DWELL_MS, () => {
                go_to_page(_page + _edge_dir);
                return Source.CONTINUE;
            });
        }

        private void stop_edge() {
            if (_edge_source != 0) Source.remove(_edge_source);
            _edge_source = 0;
            _edge_dir = 0;
        }

        private void show_home_menu(Widget parent, double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(parent);
            menu.set_pointing_to(Gdk.Rectangle() { x = (int) x, y = (int) y, width = 1, height = 1 });
            menu.add_item(_("Edit Home Screen"), "document-edit-symbolic", () => enter_edit());
            menu.popup();
        }

        public void enter_edit() {
            if (_editing) return;
            _editing = true;
            _grid.reorder_enabled = true;
            _grid.edit_mode = true;
            _stage.add_css_class("editing");
            _dots.visible = true;
            Singularity.Motion.spring_to(_stage, "scale", EDIT_SCALE, Singularity.Motion.Spring.SNAPPY);
            _bar.visible = true;
            _bar.opacity = 0.0;
            _bar.translate_y = BAR_TRAVEL;
            Singularity.Motion.spring_to(_bar, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
            Singularity.Motion.tween(_bar, "opacity", 1.0, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
        }

        public bool leave_edit() {
            if (!_editing) return false;
            _editing = false;
            _grid.reorder_enabled = false;
            _grid.edit_mode = false;
            stop_edge();
            _stage.remove_css_class("editing");
            Singularity.Motion.spring_to(_stage, "scale", 1.0, Singularity.Motion.Spring.SNAPPY);
            Singularity.Motion.spring_to(_bar, "translate-y", BAR_TRAVEL, Singularity.Motion.Spring.SNAPPY);
            var fade = Singularity.Motion.tween(_bar, "opacity", 0.0, Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                if (!_editing) _bar.visible = false;
            });
            refresh_pages();
            return true;
        }
    }
}
