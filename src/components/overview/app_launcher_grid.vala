using Gtk;
using GLib;

namespace Singularity {

    /**
     * Overview grid with mixed icons and widgets. Cells are app-icon-sized; items occupy
     * 1x1 (icons / folders) or arbitrary WxH (widgets, e.g. 2x1, 2x2, 4x2).
     * Layout flows row-major: each item is placed in the first slot wide
     * enough to fit, wrapping to the next row when needed.
     *
     * Item order lives in the AppSystem `app-grid-order` gsetting (with a
     * `widget:<instance_id>` prefix for widgets); widget sizes / configs
     * live in `overview-widgets`.
     */
    public class AppLauncherGrid : Box {
        /**
         * Filter the items that get placed in this grid. Used by the
         * menu-mode popup to render apps and widgets on separate
         * carousel pages: the popup is too narrow for widgets to
         * coexist with app icons in a single homogeneous grid.
         */
        public enum Kind {
            ALL,
            APPS_ONLY,
            WIDGETS_ONLY
        }

        public Kind kind_filter { get; set; default = Kind.ALL; }

        /**
         * When true the inner Gtk.Grid spans the full available
         * width (halign FILL + hexpand) and each placed item gets
         * hexpand so cells stretch to fill the row. Default is
         * false (Gtk.Grid is centered, cells fit their content) for
         * the overview pattern.
         */
        public bool fill_horizontally { get; set; default = false; }

        private Gtk.Grid grid;
        // Overlay wrapping the grid, used to float a translucent resize
        // preview frame above the cells without disturbing grid layout.
        private Gtk.Overlay _grid_overlay;
        private Gtk.Widget? _preview_frame = null;
        // Live references to the resize chrome so we can add/remove it in
        // place instead of repopulating the whole grid (which reloaded every
        // widget instance and reset the scroll position).
        private Gtk.Overlay? _resize_overlay = null;
        private GLib.GenericArray<Gtk.Widget> _resize_handles =
            new GLib.GenericArray<Gtk.Widget>();
        private AppSystem app_system;
        private Gtk.Application gtk_app;
        public int icon_size;
        private int columns;
        public int max_columns = 0;
        public int column_slot = 0;
        private int _last_avail = 0;
        // Fixed cell footprint - every item gets its size_request set to
        // (cell_w * w, cell_h * h) so column/row widths stay predictable
        // regardless of what's inside (icons, folders, widgets). Without
        // this, a wider widget or a slightly larger folder button would
        // blow up the cell for the whole column.
        public int cell_w;
        public int cell_h;

        // When non-null, the widget with this instance_id renders in
        // "resize mode" (edge/corner handles visible, dim outline).
        // Set from the context menu's "Resize" item; cleared on ESC or
        // when the user clicks outside.
        private string? _resize_mode_iid = null;

        // Key of the child currently highlighted as a drop target. We
        // avoid live-rebuilding the grid because Gtk.Grid's reorder isn't
        // animatable and a full repopulate looks jarring (everything
        // jumps). Instead we just put a CSS class on the target item.
        private string? _drop_target_key = null;

        // Folder overlays keyed by folder_id
        private HashTable<string, AppFolderOverlay> _folder_overlays =
            new HashTable<string, AppFolderOverlay>(str_hash, str_equal);

        public delegate void ToggleCallback();
        public ToggleCallback? on_app_launched;

        public AppLauncherGrid(Gtk.Application app, int icon_size = 96,
                                int columns = 6, int spacing = 30) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.gtk_app = app;
            this.icon_size = icon_size;
            this.columns = columns;
            app_system = AppSystem.get_default();

            // Single-cell footprint. Width hugs the icon; height includes
            // room for the label (~28px) and a small padding. Keep this
            // tight - anything taller bloats every row across the grid.
            cell_w = icon_size + 136;
            cell_h = icon_size + 136;

            grid = new Gtk.Grid();
            grid.row_spacing = spacing;
            grid.column_spacing = spacing;
            grid.halign = Align.CENTER;
            grid.valign = Align.START;
            grid.add_css_class("app-grid");
            grid.row_homogeneous = true;
            // When the host opts into fill_horizontally we re-align
            // the grid to FILL + hexpand so cells stretch across the
            // full scroll width instead of clustering in the middle.
            this.halign = Align.CENTER;
            notify["fill-horizontally"].connect(() => {
                grid.halign  = fill_horizontally ? Align.FILL : Align.CENTER;
                grid.hexpand = fill_horizontally;
                this.halign  = fill_horizontally ? Align.FILL : Align.CENTER;
            });
            grid.column_homogeneous = true;

            if (icon_size < 64) {
                add_css_class("menu-mode");
                grid.column_spacing = 8;
                grid.row_spacing = 8;
                cell_w = icon_size + 6;
                cell_h = icon_size + 26;
            }

            _grid_overlay = new Gtk.Overlay();
            _grid_overlay.halign = Align.CENTER;
            _grid_overlay.set_child(grid);
            append(_grid_overlay);

            app_system.apps_changed.connect(on_apps_changed);
            app_system.folders_changed.connect(on_apps_changed);

            // Listen to widget registry changes (in case a plugin or manifest
            // arrives after the overview is built).
            OverviewWidgetRegistry.get_default().changed.connect(on_apps_changed);
            if (SafeMode.get_default().allows(SafeFeature.CUSTOM_WIDGETS))
                OverviewWidgetRegistry.get_default().load_manifests();

            // Container-level drop: dragged item is reordered relative to
            // whatever child is under the pointer.
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.motion.connect((x, y) => {
                update_drop_indicator(x, y);
                return Gdk.DragAction.MOVE;
            });
            drop.leave.connect(() => clear_drop_indicator());
            drop.drop.connect((val, x, y) => {
                clear_drop_indicator();
                string? item = val.get_string();
                if (item == null) return false;
                string it = item;
                double dx = x, dy = y;
                GLib.Idle.add(() => { commit_drop(it, dx, dy); return GLib.Source.REMOVE; });
                return true;
            });
            grid.add_controller(drop);

            // Click on the grid background -> exit resize mode, but ONLY if
            // the click landed outside the widget currently being resized.
            // Otherwise dragging an edge handle (which presses inside the
            // widget) would immediately tear down the resize chrome.
            var bg_click = new GestureClick();
            bg_click.button = Gdk.BUTTON_PRIMARY;
            bg_click.set_propagation_phase(PropagationPhase.BUBBLE);
            bg_click.pressed.connect((n, x, y) => {
                if (_resize_mode_iid == null) return;
                var hit = grid.pick(x, y, Gtk.PickFlags.DEFAULT);
                if (hit != null) {
                    // If the click landed inside the resize-active widget,
                    // do nothing - let the handle gestures take over.
                    Gtk.Widget? w = hit;
                    while (w != null && w != grid) {
                        string? key = w.get_data<string>("grid-key");
                        if (key != null && key == "widget:" + _resize_mode_iid)
                            return;
                        w = w.get_parent();
                    }
                }
                clear_resize_chrome();
            });
            grid.add_controller(bg_click);

            // ESC -> exit resize mode.
            var key = new EventControllerKey();
            key.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape && _resize_mode_iid != null) {
                    clear_resize_chrome();
                    return true;
                }
                return false;
            });
            add_controller(key);
        }

        public void set_columns_for_width(int avail) {
            if (avail <= 0) return;
            _last_avail = avail;
            int sp = (int) grid.column_spacing;
            int slot = column_slot > 0 ? column_slot : (cell_w + sp);
            int t = avail / slot;
            if (t < 2) t = 2;
            if (max_columns > 0 && t > max_columns) t = max_columns;
            if (t != columns) {
                columns = t;
                if (get_mapped()) populate();
            }
        }

        private bool _needs_repopulate = true;
        private bool _in_populate = false;

        // Deferred widget instantiation (created in idle after the grid shows).
        private class PendingWidget : Object {
            public Gtk.Overlay? wrapper;
            public OverviewWidgetProvider provider;
            public string iid;
            public int w;
            public int h;
            public Variant? cfg;
        }
        private Gee.ArrayList<PendingWidget> _pending_widgets = new Gee.ArrayList<PendingWidget>();
        private uint _pending_source = 0;

        private void on_apps_changed() {
            if (_in_populate) return;
            _needs_repopulate = true;
            if (get_mapped()) populate();
        }

        public bool is_populated() {
            return !_needs_repopulate && grid.get_first_child() != null;
        }


        // Incremental build state.
        private string[] _build_keys = {};
        private int _build_index = 0;
        private bool[] _occ = new bool[0];
        private int _occ_rows = 0;
        private uint _build_source = 0;

        public void populate(bool animate = false) {
            close_folder_overlays();

            // Cancel any in-flight build + lazy widget jobs from a prior pass.
            if (_build_source != 0) { GLib.Source.remove(_build_source); _build_source = 0; }
            if (_pending_source != 0) { GLib.Source.remove(_pending_source); _pending_source = 0; }
            _pending_widgets.clear();
            Widget? c = grid.get_first_child();
            while (c != null) { Widget nc = c.get_next_sibling(); grid.remove(c); c = nc; }
            _needs_repopulate = false;

            // Reset incremental state and build in batches so a large grid
            // doesn't freeze the first frame.
            _build_keys = app_system.get_ordered_grid_items();
            if (kind_filter != Kind.ALL) {
                var filtered = new string[0];
                foreach (var k in _build_keys) {
                    bool is_widget = k.has_prefix("widget:");
                    if (kind_filter == Kind.APPS_ONLY    && !is_widget) filtered += k;
                    if (kind_filter == Kind.WIDGETS_ONLY &&  is_widget) filtered += k;
                }
                _build_keys = filtered;
            }
            _build_index = 0;
            _occ = new bool[0];
            _occ_rows = 0;
            // Build the first batch synchronously (instant content), the rest
            // across idle ticks.
            build_batch(12);
            start_widget_jobs();
            if (_build_index < _build_keys.length)
                _build_source = GLib.Idle.add(() => {
                    build_batch(16);
                    start_widget_jobs();
                    if (_build_index >= _build_keys.length) {
                        _build_source = 0;
                        return GLib.Source.REMOVE;
                    }
                    return GLib.Source.CONTINUE;
                }, GLib.Priority.DEFAULT_IDLE);
        }

        private class FixedCell : Gtk.Widget {
            private Gtk.Widget? _child;
            private int _fw;
            private int _fh;
            public FixedCell(Gtk.Widget child, int fw, int fh) {
                _fw = fw; _fh = fh;
                _child = child;
                _child.set_parent(this);
                set_overflow(Gtk.Overflow.HIDDEN);
            }
            public override void measure(Gtk.Orientation orientation, int for_size,
                                         out int minimum, out int natural,
                                         out int minimum_baseline, out int natural_baseline) {
                natural = (orientation == Gtk.Orientation.HORIZONTAL) ? _fw : _fh;
                minimum = natural;
                minimum_baseline = -1;
                natural_baseline = -1;
            }
            public override void size_allocate(int width, int height, int baseline) {
                if (_child != null) _child.allocate(width, height, baseline, null);
            }
            public override void dispose() {
                if (_child != null) { _child.unparent(); _child = null; }
                base.dispose();
            }
        }

        // Place up to `count` of the remaining ordered items into the grid.
        private void build_batch(int count) {
            int done = 0;
            int spacing_col = (int) grid.column_spacing;
            int spacing_row = (int) grid.row_spacing;
            while (_build_index < _build_keys.length && done < count) {
                string key = _build_keys[_build_index++];
                int w = 1, h = 1;
                Widget? child = build_item(key, out w, out h);
                if (child == null) continue;
                if (w > columns) w = columns;

                int row = 0, col = 0;
                bool placed = false;
                while (!placed) {
                    if (row + h > _occ_rows) {
                        int new_rows = row + h + 4;
                        bool[] ng = new bool[new_rows * columns];
                        for (int i = 0; i < _occ_rows * columns; i++) ng[i] = _occ[i];
                        _occ = ng;
                        _occ_rows = new_rows;
                    }
                    for (col = 0; col + w <= columns; col++) {
                        bool free = true;
                        for (int dr = 0; dr < h && free; dr++)
                            for (int dc = 0; dc < w && free; dc++)
                                if (_occ[(row + dr) * columns + (col + dc)]) free = false;
                        if (free) { placed = true; break; }
                    }
                    if (!placed) row++;
                }
                for (int dr = 0; dr < h; dr++)
                    for (int dc = 0; dc < w; dc++)
                        _occ[(row + dr) * columns + (col + dc)] = true;

                child.set_data<string>("grid-key", key);
                int fw = cell_w * w + spacing_col * (w - 1);
                int fh = cell_h * h + spacing_row * (h - 1);
                var capped = new FixedCell(child, fw, fh);
                capped.set_data<string>("grid-key", key);
                child = capped;
                child.width_request  = fw;
                child.height_request = fh;
                if (fill_horizontally) child.hexpand = true;
                grid.attach(child, col, row, w, h);
                done++;
            }
        }

        private void start_widget_jobs() {
            if (_pending_source == 0 && _pending_widgets.size > 0)
                _pending_source = GLib.Idle.add(process_next_widget, GLib.Priority.DEFAULT_IDLE);
        }

        private bool process_next_widget() {
            if (_pending_widgets.size == 0) { _pending_source = 0; return GLib.Source.REMOVE; }
            var job = _pending_widgets.remove_at(0);
            if (job.wrapper != null && job.provider != null) {
                var content = job.provider.create_instance(job.iid, WidgetSize(job.w, job.h), job.cfg);
                if (content != null) {
                    content.hexpand = true;
                    content.vexpand = true;
                    job.wrapper.set_child(content);
                }
            }
            if (_pending_widgets.size == 0) { _pending_source = 0; return GLib.Source.REMOVE; }
            return GLib.Source.CONTINUE;
        }

        /**
         * Dismiss any open folder overlay without tearing down the grid.
         *
         * A folder overlay is its own toplevel layer-shell window, so hiding
         * the launcher that spawned it leaves it on screen. Closing the
         * overlays is cheap; dropping the grid contents is not, which is why
         * depopulate() stays on its idle timer and this can be called
         * immediately on close.
         */
        public void close_folder_overlays() {
            // force_close(), not close_overlay(): close_overlay() fades via
            // add_tick_callback(), the exact mechanism force_close() exists
            // to avoid (#51) -- if the clock stalls, destroy() never runs and
            // the overlay is stuck for good.
            //
            // Snapshot the table before closing anything: AppFolderOverlay's
            // closed() signal fires synchronously and its handler removes
            // the entry from _folder_overlays, so calling force_close()
            // while still inside a foreach over that same table mutates it
            // mid-iteration.
            var overlays = _folder_overlays.get_values();
            _folder_overlays.remove_all();
            foreach (var ov in overlays) {
                ov.force_close();
            }
        }

        public void depopulate() {
            close_folder_overlays();
            Widget? c = grid.get_first_child();
            while (c != null) { Widget nc = c.get_next_sibling(); grid.remove(c); c = nc; }
        }

        private Widget? build_item(string key, out int w, out int h) {
            w = 1; h = 1;
            if (key.has_prefix("widget:")) {
                string iid = key.substring(7);
                var inst = app_system.get_overview_widget(iid);
                if (inst == null) return null;
                w = int.max(1, inst.w);
                h = int.max(1, inst.h);
                var provider = OverviewWidgetRegistry.get_default().find(inst.provider_id);
                if (provider == null) {
                    // Provider not loaded (module missing / plugin disabled).
                    return build_widget_placeholder(iid, inst);
                }
                Variant? cfg = null;
                if (inst.config_json != "") {
                    try { cfg = Variant.parse(null, inst.config_json); }
                    catch (Error e) { cfg = null; }
                }
                // Lazy: build the chrome with an empty placeholder now (fast),
                // and create the real widget instance in an idle pass after the
                // grid is on screen. Widget instances do blocking work (pixbuf
                // decode, DBus, /proc) that was stalling the overview open.
                var placeholder = new Gtk.Box(Orientation.VERTICAL, 0);
                placeholder.add_css_class("overview-widget-loading");
                var wrapper = wrap_widget(iid, inst, provider, placeholder);
                var job = new PendingWidget();
                job.wrapper = wrapper as Gtk.Overlay;
                job.provider = provider;
                job.iid = iid;
                job.w = w; job.h = h; job.cfg = cfg;
                _pending_widgets.add(job);
                return wrapper;
            }
            if (key.has_prefix("folder:")) {
                string fid = key.substring(7);
                if (app_system.get_folder(fid) == null) return null;
                var fb = create_folder_button(fid);
                return cell_wrap(fb);
            }
            // App
            var app = app_system.get_app_info(key);
            if (app == null || !app.should_show()) return null;
            return cell_wrap(create_app_button(app, key));
        }

        /** Wrap a 1x1 widget so it occupies a deterministic cell size. */
        private Widget cell_wrap(Widget child) {
            child.halign = Align.CENTER;
            child.valign = Align.CENTER;
            return child;
        }

        // Widget chrome
        private Widget wrap_widget(string iid, AppSystem.OverviewWidgetInstance inst,
                                    OverviewWidgetProvider provider, Widget content) {
            // The chrome wraps the widget in a Gtk.Overlay so we can layer a
            // hover-revealed drag handle on top of it. The widget itself
            // (e.g. MediaPlayerCard) consumes pointer events for its own
            // controls - without the handle there's no surface left to grab.
            var overlay = new Gtk.Overlay();
            overlay.add_css_class("overview-widget");

            content.hexpand = true;
            content.vexpand = true;
            overlay.set_child(content);

            // Drag handle: a small pill at the top-centre, visible only on
            // hover. Drag this to move the widget around the grid.
            var handle = new Gtk.Image.from_icon_name("view-more-horizontal-symbolic");
            handle.pixel_size = 18;
            handle.halign = Align.CENTER;
            handle.valign = Align.START;
            handle.margin_top = 4;
            handle.add_css_class("overview-widget-handle");
            handle.set_cursor(new Gdk.Cursor.from_name("grab", null));
            handle.opacity = 0.0;
            overlay.add_overlay(handle);

            var hover = new EventControllerMotion();
            hover.enter.connect((x, y) => { handle.opacity = 1.0; });
            hover.leave.connect(()     => { handle.opacity = 0.0; });
            overlay.add_controller(hover);

            // Right-click anywhere on the widget -> context menu.
            var rc = new GestureClick();
            rc.button = Gdk.BUTTON_SECONDARY;
            rc.pressed.connect((n, x, y) => {
                show_widget_context_menu(overlay, iid, inst, provider, x, y);
            });
            overlay.add_controller(rc);

            // Drag source: lives on the handle (NOT on the whole widget) so
            // the widget's own clickable controls keep working normally.
            var drag = new DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            string captured = "widget:" + iid;
            drag.prepare.connect((x, y) => new Gdk.ContentProvider.for_value(captured));
            drag.drag_begin.connect((d) => {
                // Take a live snapshot of the actual widget so the drag
                // icon mirrors what the user is grabbing, not a placeholder.
                var paintable = paintable_for(overlay);
                if (paintable != null) {
                    int hot_x = (int) paintable.get_intrinsic_width()  / 2;
                    int hot_y = (int) paintable.get_intrinsic_height() / 2;
                    drag.set_icon(paintable, hot_x, hot_y);
                }
                overlay.add_css_class("dragging");
            });
            drag.drag_end.connect((d, action, delete_data) => {
                overlay.remove_css_class("dragging");
            });
            handle.add_controller(drag);

            // Accept drops anywhere on the widget so dragged items can land
            // at its grid position, interspersed among the icons.
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            string self_key = "widget:" + iid;
            drop.drop.connect((val, x, y) => {
                string? dragged = val.get_string();
                if (dragged == null || dragged == self_key) return false;
                string d = dragged;
                string a = self_key;
                GLib.Idle.add(() => { reorder_relative_to(d, a); return GLib.Source.REMOVE; });
                return true;
            });
            overlay.add_controller(drop);

            // Resize chrome: dim outline + edge / corner handles. Only
            // attached when this widget is in resize mode.
            if (_resize_mode_iid == iid)
                attach_resize_chrome(overlay, iid, inst, provider);

            return overlay;
        }

        // Resize mode
        private void attach_resize_chrome(Gtk.Overlay overlay, string iid,
                AppSystem.OverviewWidgetInstance inst,
                OverviewWidgetProvider provider) {
            overlay.add_css_class("overview-widget-resize-active");
            _resize_overlay = overlay;

            // Three handles: right edge (width), bottom edge (height),
            // bottom-right corner (both). Each is a tiny pill the user
            // drags. On release, the new (w,h) is snapped to the
            // closest supported size.
            attach_handle(overlay, iid, inst, provider, "right",
                          Align.END, Align.CENTER, true,  false);
            attach_handle(overlay, iid, inst, provider, "bottom",
                          Align.CENTER, Align.END, false, true);
            attach_handle(overlay, iid, inst, provider, "corner",
                          Align.END, Align.END, true,  true);
        }

        // Remove the resize chrome (outline + handles) from whatever widget is
        // currently in resize mode, in place. Replaces the old populate()-based
        // exit so widgets don't reload and the scroll position is kept.
        private void clear_resize_chrome() {
            clear_preview_frame();
            if (_resize_overlay != null) {
                _resize_overlay.remove_css_class("overview-widget-resize-active");
                for (int i = 0; i < _resize_handles.length; i++)
                    _resize_overlay.remove_overlay(_resize_handles[i]);
            }
            _resize_handles = new GLib.GenericArray<Gtk.Widget>();
            _resize_overlay = null;
            _resize_mode_iid = null;
        }

        private void attach_handle(Gtk.Overlay overlay, string iid,
                AppSystem.OverviewWidgetInstance inst,
                OverviewWidgetProvider provider, string css_role,
                Gtk.Align halign, Gtk.Align valign,
                bool affects_w, bool affects_h) {
            var handle = new Gtk.Box(Orientation.HORIZONTAL, 0);
            handle.add_css_class("overview-resize-handle");
            handle.add_css_class("overview-resize-handle-" + css_role);
            handle.halign = halign;
            handle.valign = valign;
            handle.set_size_request(affects_w && affects_h ? 18 : (affects_w ? 8 : 24),
                                     affects_w && affects_h ? 18 : (affects_h ? 8 : 24));
            handle.set_cursor(new Gdk.Cursor.from_name(
                affects_w && affects_h ? "nwse-resize"
                                       : (affects_w ? "ew-resize" : "ns-resize"),
                null));
            overlay.add_overlay(handle);
            _resize_handles.add(handle);

            int start_w = inst.w;
            int start_h = inst.h;
            int candidate_w = start_w;
            int candidate_h = start_h;

            var drag = new Gtk.GestureDrag();
            drag.drag_begin.connect((sx, sy) => {
                candidate_w = start_w;
                candidate_h = start_h;
                show_preview_frame(overlay, candidate_w, candidate_h);
            });
            // Live feedback is a translucent ghost frame floated over the grid
            // (show_preview_frame). We deliberately do NOT touch the child's
            // width_request / height_request mid-drag: with a homogeneous
            // Gtk.Grid that reflows every cell and jumps the whole layout.
            // The real reflow happens once, on release, via relayout().
            drag.drag_update.connect((dx, dy) => {
                int col_px = cell_w + (int) grid.column_spacing;
                int row_px = cell_h + (int) grid.row_spacing;
                int nw = start_w + (affects_w ? (int) Math.round(dx / col_px) : 0);
                int nh = start_h + (affects_h ? (int) Math.round(dy / row_px) : 0);
                var snap = snap_size(provider, nw, nh);
                candidate_w = snap.w;
                candidate_h = snap.h;
                show_preview_frame(overlay, candidate_w, candidate_h);
            });
            drag.drag_end.connect((dx, dy) => {
                bool changed = (candidate_w != start_w || candidate_h != start_h);
                if (changed)
                    app_system.resize_overview_widget(iid, candidate_w, candidate_h);
                clear_resize_chrome();
                // Reposition existing children for the new footprint without
                // recreating widget instances or resetting the scroll.
                if (changed) relayout();
            });
            handle.add_controller(drag);
        }

        // Live resize preview
        // A translucent frame floated over the grid showing the target
        // footprint while dragging a handle. Positioned by margins relative to
        // the resizing widget's top-left, sized to the candidate WxH. This
        // never touches grid layout, so there's no cascade / jump.
        private void show_preview_frame(Gtk.Widget anchor, int w, int h) {
            if (_preview_frame == null) {
                var f = new Gtk.Box(Orientation.HORIZONTAL, 0);
                f.add_css_class("overview-resize-preview");
                f.halign = Align.START;
                f.valign = Align.START;
                f.can_target = false;
                _preview_frame = f;
                _grid_overlay.add_overlay(f);
            }
            Graphene.Rect bounds;
            if (!anchor.compute_bounds(_grid_overlay, out bounds)) return;
            int spacing_col = (int) grid.column_spacing;
            int spacing_row = (int) grid.row_spacing;
            _preview_frame.margin_start = (int) bounds.origin.x;
            _preview_frame.margin_top   = (int) bounds.origin.y;
            _preview_frame.width_request  = cell_w * w + spacing_col * (w - 1);
            _preview_frame.height_request = cell_h * h + spacing_row * (h - 1);
        }

        private void clear_preview_frame() {
            if (_preview_frame != null) {
                _grid_overlay.remove_overlay(_preview_frame);
                _preview_frame = null;
            }
        }

        // Re-pack existing grid children for their current sizes WITHOUT
        // tearing them down (so widget instances keep their state and don't
        // flash) and WITHOUT bouncing the scroll position. Used after a resize.
        private void relayout() {
            // Map existing children by their grid-key; this keeps the live
            // widget objects alive across the re-attach.
            var by_key = new HashTable<string, Widget>(str_hash, str_equal);
            Widget? c = grid.get_first_child();
            while (c != null) {
                Widget nc = c.get_next_sibling();
                string? k = c.get_data<string>("grid-key");
                if (k != null) by_key.insert(k, c);
                c = nc;
            }

            var adj = find_vadjustment();
            double saved_scroll = adj != null ? adj.value : 0;

            _occ = new bool[0];
            _occ_rows = 0;
            int spacing_col = (int) grid.column_spacing;
            int spacing_row = (int) grid.row_spacing;

            foreach (var key in app_system.get_ordered_grid_items()) {
                Widget? child = by_key.lookup(key);
                if (child == null) continue;

                int w = 1, h = 1;
                if (key.has_prefix("widget:")) {
                    var inst = app_system.get_overview_widget(key.substring(7));
                    if (inst != null) { w = int.max(1, inst.w); h = int.max(1, inst.h); }
                }
                if (w > columns) w = columns;

                int row = 0, col = 0;
                bool placed = false;
                while (!placed) {
                    if (row + h > _occ_rows) {
                        int new_rows = row + h + 4;
                        bool[] ng = new bool[new_rows * columns];
                        for (int i = 0; i < _occ_rows * columns; i++) ng[i] = _occ[i];
                        _occ = ng;
                        _occ_rows = new_rows;
                    }
                    for (col = 0; col + w <= columns; col++) {
                        bool free = true;
                        for (int dr = 0; dr < h && free; dr++)
                            for (int dc = 0; dc < w && free; dc++)
                                if (_occ[(row + dr) * columns + (col + dc)]) free = false;
                        if (free) { placed = true; break; }
                    }
                    if (!placed) row++;
                }
                for (int dr = 0; dr < h; dr++)
                    for (int dc = 0; dc < w; dc++)
                        _occ[(row + dr) * columns + (col + dc)] = true;

                child.width_request  = cell_w * w + spacing_col * (w - 1);
                child.height_request = cell_h * h + spacing_row * (h - 1);
                // Move within the grid: remove + re-attach. `child` holds a ref
                // for the duration so the widget object survives the detach.
                grid.remove(child);
                grid.attach(child, col, row, w, h);
            }

            if (adj != null) adj.value = saved_scroll;
        }

        // Walk up to the enclosing ScrolledWindow's vertical adjustment so we
        // can preserve scroll across a relayout.
        private Gtk.Adjustment? find_vadjustment() {
            Widget? w = get_parent();
            while (w != null) {
                if (w is Gtk.ScrolledWindow)
                    return ((Gtk.ScrolledWindow) w).get_vadjustment();
                w = w.get_parent();
            }
            return null;
        }

        // Snapshot a widget into a Gdk.Paintable so it can be used as a
        // DnD icon. Returns null if the widget isn't realised yet (the
        // caller falls back to GTK's default).
        private Gdk.Paintable? paintable_for(Gtk.Widget w) {
            int width = w.get_width();
            int height = w.get_height();
            if (width <= 0 || height <= 0) return null;
            var snapshot = new Gtk.Snapshot();
            w.snapshot(snapshot);
            var node = snapshot.to_node();
            if (node == null) return null;
            return new SnapshotPaintable(node, width, height);
        }

        // Pick the supported size closest to (target_w, target_h). If the
        // provider declares fixed sizes we never escape that set.
        private WidgetSize snap_size(OverviewWidgetProvider provider,
                                       int target_w, int target_h) {
            target_w = int.max(1, int.min(columns, target_w));
            target_h = int.max(1, target_h);
            WidgetSize best = provider.supported_sizes[0];
            int best_dist = int.MAX;
            foreach (var s in provider.supported_sizes) {
                int dw = s.w - target_w; int dh = s.h - target_h;
                int dist = dw * dw + dh * dh;
                if (dist < best_dist) { best_dist = dist; best = s; }
            }
            return best;
        }

        // Move `item` next to `anchor_key`. Dragging forward (item currently
        // before the anchor) drops it after the anchor; dragging backward drops
        // it before, which matches what the cursor position implies.
        private void reorder_relative_to(string item, string anchor_key) {
            var current = app_system.get_ordered_grid_items();
            int from = -1, to = -1;
            for (int i = 0; i < current.length; i++) {
                if (current[i] == item) from = i;
                if (current[i] == anchor_key) to = i;
            }
            bool after = (from >= 0 && to >= 0 && from < to);
            string[] final_order = {};
            bool inserted = false;
            foreach (var o in current) {
                if (o == item) continue;
                if (!after && o == anchor_key) { final_order += item; inserted = true; }
                final_order += o;
                if (after && o == anchor_key) { final_order += item; inserted = true; }
            }
            if (!inserted) final_order += item;
            app_system.set_grid_order_quiet(final_order);
            relayout();
        }

        private Widget build_widget_placeholder(string iid,
                AppSystem.OverviewWidgetInstance inst) {
            var box = new Gtk.Box(Orientation.VERTICAL, 6);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            box.add_css_class("overview-widget");
            box.add_css_class("overview-widget-missing");
            var icon = new Image.from_icon_name("dialog-warning-symbolic");
            icon.pixel_size = 32;
            box.append(icon);
            var lbl = new Label(_("Widget unavailable"));
            lbl.add_css_class("dim-label");
            box.append(lbl);
            var sub = new Label(inst.provider_id);
            sub.add_css_class("caption");
            box.append(sub);

            var rc = new GestureClick();
            rc.button = Gdk.BUTTON_SECONDARY;
            rc.pressed.connect((n, x, y) => {
                var menu = new Singularity.Widgets.ContextMenu(box);
                Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
                menu.set_pointing_to(rect);
                menu.add_item("Remove from overview", "edit-delete-symbolic", () => {
                    app_system.remove_overview_widget(iid);
                });
                menu.popup();
            });
            box.add_controller(rc);
            return box;
        }

        private void show_widget_context_menu(Widget parent, string iid,
                AppSystem.OverviewWidgetInstance inst,
                OverviewWidgetProvider provider, double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(parent);
            Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
            menu.set_pointing_to(rect);

            // Single "Resize" entry that toggles edge-handle mode - more
            // more intuitive than enumerating every possible size.
            menu.add_item("Resize", "view-fullscreen-symbolic", () => {
                // Attach the resize chrome to the existing widget overlay in
                // place. Repopulating here reloaded every widget instance and
                // bounced the scroll position to the top.
                clear_resize_chrome();
                _resize_mode_iid = iid;
                if (parent is Gtk.Overlay)
                    attach_resize_chrome((Gtk.Overlay) parent, iid, inst, provider);
            });
            menu.add_separator();
            menu.add_item("Remove from overview", "edit-delete-symbolic", () => {
                app_system.remove_overview_widget(iid);
            });
            menu.popup();
        }

        // Folder / app buttons (unchanged behaviour)
        private AppFolderButton create_folder_button(string folder_id) {
            var fb = new AppFolderButton(folder_id, icon_size, cell_w, cell_h);

            fb.clicked.connect((fid) => {
                var ov = _folder_overlays.lookup(fid);
                if (ov == null) {
                    ov = new AppFolderOverlay(gtk_app, fid);
                    ov.on_app_launched = () => { if (on_app_launched != null) on_app_launched(); };
                    // The overlay destroys itself on close, so drop it from the
                    // cache (otherwise it can't be reopened) and hand keyboard
                    // focus back to the grid so Esc closes the drawer next.
                    ov.closed.connect(() => {
                        _folder_overlays.remove(fid);
                        grab_focus();
                    });
                    _folder_overlays.insert(fid, ov);
                }
                ov.open_overlay();
            });

            fb.drop_app.connect((fid, app_id) => {
                if (app_id.has_prefix("folder:")) return;
                if (app_id.has_prefix("widget:")) return;
                app_system.add_app_to_folder(fid, app_id);
            });
            return fb;
        }

        private Button create_app_button(AppInfo app, string app_id) {
            var btn = new Button();
            btn.add_css_class("app-grid-item");
            btn.has_frame = false;
            btn.hexpand = true;
            btn.vexpand = true;
            btn.halign = Align.FILL;
            btn.valign = Align.FILL;
            btn.set_size_request(cell_w, cell_h);

            var box = new Box(Orientation.VERTICAL, icon_size < 64 ? 6 : 12);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;

            var icon = app.get_icon();
            var img = new Image();
            img.pixel_size = icon_size;
            img.halign = Align.CENTER;
            img.valign = Align.CENTER;

            if (icon is ThemedIcon) {
                var theme = IconTheme.get_for_display(Gdk.Display.get_default());
                bool set = false;
                foreach (var name in ((ThemedIcon) icon).get_names()) {
                    if (theme.has_icon(name)) { img.icon_name = name; set = true; break; }
                }
                if (!set) img.icon_name = "application-x-executable";
            } else if (icon != null) {
                img.set_from_gicon(icon);
            } else {
                img.icon_name = "application-x-executable";
            }

            box.append(img);

            var label = new Label(app.get_name());
            label.max_width_chars = 14;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.wrap = true;
            label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            label.lines = 2;
            label.justify = Justification.CENTER;
            label.xalign = 0.5f;
            box.append(label);

            btn.set_child(box);

            btn.clicked.connect(() => {
                AppSystem.launch_app(app);
                if (on_app_launched != null) on_app_launched();
            });

            var right_click = new GestureClick();
            right_click.button = Gdk.BUTTON_SECONDARY;
            unowned Button btn_weak = btn;
            unowned GestureClick rc_weak = right_click;
            right_click.pressed.connect((n, x, y) => {
                var state = rc_weak.get_current_event_state();
                bool alt = (state & Gdk.ModifierType.ALT_MASK) != 0;
                rc_weak.set_state(EventSequenceState.CLAIMED);
                show_app_context_menu(btn_weak, app, x, y, alt);
            });
            btn.add_controller(right_click);

            // Drag source
            var drag = new DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            string captured_id = app_id.dup();
            unowned DragSource drag_weak = drag;
            drag.prepare.connect((x, y) => new Gdk.ContentProvider.for_value(captured_id));
            drag.drag_begin.connect((d) => {
                // Snapshot the actual button so the drag icon shows the
                // exact thing the user is dragging (icon + label).
                var snap = paintable_for(btn_weak);
                if (snap != null) {
                    int hx = (int) snap.get_intrinsic_width()  / 2;
                    int hy = (int) snap.get_intrinsic_height() / 2;
                    drag_weak.set_icon(snap, hx, hy);
                }
                btn_weak.add_css_class("dragging");
            });
            drag.drag_end.connect((d, action, delete_data) => {
                btn_weak.remove_css_class("dragging");
            });
            btn.add_controller(drag);

            // Drop on app:
            //   - app on app           -> create folder
            //   - widget/folder on app -> reorder, place dragged before this app
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            string captured_app_id = app_id.dup();
            drop.drop.connect((val, x, y) => {
                string? dragged = val.get_string();
                if (dragged == null || dragged == captured_app_id) return false;
                if (dragged.has_prefix("widget:") || dragged.has_prefix("folder:")) {
                    reorder_relative_to(dragged, captured_app_id);
                    return true;
                }
                string folder_name = generate_folder_name(dragged, captured_app_id);
                app_system.create_folder(folder_name, captured_app_id, dragged);
                return true;
            });
            drop.enter.connect((x, y) => {
                btn_weak.add_css_class("drop-target-hover");
                return Gdk.DragAction.MOVE;
            });
            drop.leave.connect(() => btn_weak.remove_css_class("drop-target-hover"));
            btn.add_controller(drop);

            return btn;
        }

        // Drop reorder
        private void commit_drop(string item, double x, double y) {
            // Find the child under the pointer.
            string? target_key = null;
            Widget? c = grid.get_first_child();
            while (c != null) {
                Graphene.Rect b;
                if (c.compute_bounds(grid, out b)) {
                    if (x >= b.origin.x && x <= b.origin.x + b.size.width &&
                        y >= b.origin.y && y <= b.origin.y + b.size.height) {
                        target_key = key_for_widget(c);
                        break;
                    }
                }
                c = c.get_next_sibling();
            }
            if (target_key != null && target_key != item) {
                reorder_relative_to(item, target_key);
                return;
            }
            var current = app_system.get_ordered_grid_items();
            string[] final_order = {};
            foreach (var o in current) if (o != item) final_order += o;
            final_order += item;
            app_system.set_grid_order_quiet(final_order);
            relayout();
        }

        // Inverse lookup: read the data attached when we attached the child.
        private string? key_for_widget(Widget w) {
            return w.get_data<string>("grid-key");
        }

        // Highlight the child under the pointer with a CSS marker so the
        // user sees where the dragged item will land - no live reorder,
        // no churn. The actual reorder happens on drop.
        private void update_drop_indicator(double x, double y) {
            string? target_key = null;
            Widget? target_widget = null;
            Widget? c = grid.get_first_child();
            while (c != null) {
                Graphene.Rect b;
                if (c.compute_bounds(grid, out b)) {
                    if (x >= b.origin.x && x <= b.origin.x + b.size.width &&
                        y >= b.origin.y && y <= b.origin.y + b.size.height) {
                        target_key = key_for_widget(c);
                        target_widget = c;
                        break;
                    }
                }
                c = c.get_next_sibling();
            }
            if (target_key == _drop_target_key) return;

            clear_drop_indicator();
            if (target_widget != null && target_key != null) {
                target_widget.add_css_class("drop-target-here");
                _drop_target_key = target_key;
            }
        }

        private void clear_drop_indicator() {
            if (_drop_target_key == null) return;
            Widget? c = grid.get_first_child();
            while (c != null) {
                if (key_for_widget(c) == _drop_target_key) {
                    c.remove_css_class("drop-target-here");
                    break;
                }
                c = c.get_next_sibling();
            }
            _drop_target_key = null;
        }

        // Folder name helper
        private string generate_folder_name(string app_id1, string app_id2) {
            var app1 = app_system.get_app_info(app_id1) as DesktopAppInfo;
            if (app1 != null) {
                string? cats = app1.get_categories();
                if (cats != null) {
                    string[] parts = cats.split(";");
                    foreach (var cat in parts) {
                        if (cat != "GNOME" && cat != "GTK" && cat != "Application" && cat.length > 2)
                            return cat;
                    }
                }
            }
            return "Folder";
        }

        // App context menu
        private void show_app_context_menu(Widget parent, AppInfo app,
                double x, double y, bool alt_pressed) {
            string? app_id = app.get_id();
            var menu = new Singularity.Widgets.ContextMenu(parent);
            Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
            menu.set_pointing_to(rect);

            menu.add_item("Open", "system-run-symbolic", () => {
                AppSystem.launch_app(app);
                if (on_app_launched != null) on_app_launched();
            });

            menu.add_item("Add to Desktop", "user-desktop-symbolic", () => {
                AppSystem.add_app_to_desktop(app);
            });

            menu.add_separator();

            if (alt_pressed) {
                var desktop_app = app as DesktopAppInfo;
                if (desktop_app != null) {
                    string? path = desktop_app.get_filename();
                    if (path != null) {
                        menu.add_item("Go to Desktop Entry", "folder-open-symbolic", () => {
                            try {
                                var file = File.new_for_path(path);
                                var parent_dir = file.get_parent();
                                if (parent_dir != null) {
                                    string cmd = AppSystem.resolve_companion_bin("singularity-files")
                                        + " " + GLib.Shell.quote(parent_dir.get_path());
                                    Process.spawn_command_line_async(cmd);
                                }
                            } catch (Error e) { warning("Failed to open desktop entry location: %s", e.message); }
                        });
                        menu.add_separator();
                    }
                }
            }

            if (app_id != null) {
                string captured_id = app_id.dup();
                if (app_system.is_pinned(captured_id)) {
                    menu.add_item("Unpin from Dock", "list-remove-symbolic", () => {
                        app_system.unpin_app(captured_id);
                    });
                } else {
                    menu.add_item("Pin to Dock", "starred-symbolic", () => {
                        app_system.pin_app(captured_id);
                    });
                }
            }

            menu.popup();
        }

        // Widget picker (called from overview "+" button)
        public void show_widget_picker(Widget parent, double x = -1, double y = -1) {
            var menu = new Singularity.Widgets.ContextMenu(parent);
            if (x >= 0 && y >= 0) {
                Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
                menu.set_pointing_to(rect);
            }
            var providers = OverviewWidgetRegistry.get_default().list();
            if (providers.length == 0) {
                menu.add_item("No widgets available", "dialog-information-symbolic", () => {});
            } else {
                foreach (var p in providers) {
                    var first = p.supported_sizes[0];
                    string label = "%s (%dx%d)".printf(p.display_name, first.w, first.h);
                    string pid = p.id;
                    int w = first.w, h = first.h;
                    menu.add_item(label, p.icon_name, () => {
                        app_system.add_overview_widget(pid, w, h);
                    });
                }
            }
            menu.popup();
        }
    }

    // Minimal Gdk.Paintable implementation that draws a captured render
    // node - used as a DnD drag icon so the user sees the actual widget
    // they're dragging instead of a generic placeholder.
    private class SnapshotPaintable : Object, Gdk.Paintable {
        private Gsk.RenderNode node;
        private int w;
        private int h;
        public SnapshotPaintable(Gsk.RenderNode node, int w, int h) {
            this.node = node; this.w = w; this.h = h;
        }
        public override void snapshot(Gdk.Snapshot snap, double width, double height) {
            ((Gtk.Snapshot) snap).append_node(node);
        }
        public override int get_intrinsic_width()  { return w; }
        public override int get_intrinsic_height() { return h; }
        public override Gdk.PaintableFlags get_flags() { return 0; }
    }
}
