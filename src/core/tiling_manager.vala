using Singularity;
using GLib;
using Gee;
using Gtk;
using GtkLayerShell;

namespace Singularity {

    private class ScrollingWorkarea : Object {
        public int x;
        public int y;
        public int width;
        public int height;

        public ScrollingWorkarea(int x, int y, int width, int height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }
    }

    private class ScrollingRect : Object {
        public int x;
        public int y;
        public int width;
        public int height;

        public ScrollingRect(int x, int y, int width, int height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }
    }

    private class ScrollingColumn : Object {
        public ArrayList<AppSystem.Window> windows =
            new ArrayList<AppSystem.Window>();
        public int width;

        public ScrollingColumn(int width) {
            this.width = width;
        }
    }

    private class ScrollingGroup : Object {
        public string key;
        public ScrollingWorkarea area;
        public ArrayList<ScrollingWorkarea> output_areas;
        public int reference_width;
        public Gdk.Monitor? monitor;
        public ArrayList<ScrollingColumn> columns =
            new ArrayList<ScrollingColumn>();
        public AppSystem.Window? focused;
        public AppSystem.Window? interaction_window;
        public ScrollingColumn? drag_column;
        public StackTarget? stack_target;
        public double offset = 0;
        public uint offset_animation_id = 0;
        public double offset_animation_start = 0;
        public double offset_animation_target = 0;
        public int64 offset_animation_started = 0;
        public bool initialized = false;
        public bool focus_reveal_pending = false;

        public ScrollingGroup(string key, ScrollingWorkarea area,
                              ArrayList<ScrollingWorkarea> output_areas,
                              int reference_width, Gdk.Monitor? monitor) {
            this.key = key;
            this.area = area;
            this.output_areas = output_areas;
            this.reference_width = reference_width;
            this.monitor = monitor;
        }
    }

    private class StackTarget : Object {
        public ScrollingColumn column;
        public int index;
        public int distance;

        public StackTarget(ScrollingColumn column, int index, int distance) {
            this.column = column;
            this.index = index;
            this.distance = distance;
        }
    }

    public class TilingManager : Object {
        private const int MIN_COLUMN_WIDTH = 240;
        private const int STACK_TARGET_SIZE = 30;
        private const int GESTURE_ADVANCE_DISTANCE = 48;
        private const double CLOSE_GESTURE_HINT_DISTANCE = 36;
        private const double CLOSE_GESTURE_THRESHOLD = 72;
        private const double CLOSE_GESTURE_ARM_DISTANCE = 40;
        private const double CLOSE_GESTURE_RESISTANCE = 0.28;
        private const uint OFFSET_SETTLE_DURATION = 180;
        private static TilingManager? instance;
        private AppSystem app_system;
        private GLib.Settings settings;
        private SafeMode safe_mode;
        private bool enabled = true;
        private bool shell_overview_active = false;
        private uint apply_timeout_id = 0;
        private HashMap<string, ScrollingGroup> scrolling_groups =
            new HashMap<string, ScrollingGroup>();
        private HashMap<AppSystem.Window, AppSystem.Window> insertion_anchors =
            new HashMap<AppSystem.Window, AppSystem.Window>();
        private HashSet<AppSystem.Window> startup_windows =
            new HashSet<AppSystem.Window>();
        private AppSystem.Window? last_scrolling_focus;
        private void* observed_focus_handle;
        private AppSystem.Window? pointer_focus_window;
        private bool pointer_focus_request_pending = false;
        private int pointer_focus_x;
        private int pointer_focus_y;
        private ScrollingGroup? gesture_group;
        private AppSystem.Window? gesture_start_window;
        private double gesture_start_offset = 0;
        private double gesture_last_dx = 0;
        private ScrollingGroup? close_gesture_group;
        private AppSystem.Window? close_gesture_window;
        private ScrollingRect? close_gesture_rect;
        private double close_gesture_last_dy = 0;
        private Gtk.Window? close_gesture_indicator;
        private Gtk.Widget? close_gesture_danger;
        private Gtk.Image? close_gesture_icon;
        private AppSystem.Window? organizer_hover_window;
        private AppSystem.Window? organizer_window;

        public signal void scrolling_position_changed(Gdk.Monitor? monitor,
            double position, double visible_fraction, bool active);
        public signal void scrolling_drag_changed(AppSystem.Window win,
            Gdk.Monitor? monitor, uint32 phase, int cursor_x, int cursor_y);

        public static TilingManager? get_default() {
            return instance;
        }

        public TilingManager(AppSystem app_system) {
            instance = this;
            this.app_system = app_system;
            safe_mode = SafeMode.get_default();
            settings = new GLib.Settings("dev.sinty.desktop");
            setup_close_gesture_indicator();
            enabled = settings.get_boolean("tiling-enabled")
                && safe_mode.allows(SafeFeature.TILING);
            if (scrolling_active()) {
                foreach (var win in app_system.get_windows())
                    startup_windows.add(win);
            }
            settings.changed["tiling-enabled"].connect(on_mode_changed);
            settings.changed["tiling-layout"].connect(on_mode_changed);
            settings.changed["tiling-column-width"].connect(() => {
                foreach (var group in scrolling_groups.values) {
                    foreach (var column in group.columns) column.width = 0;
                    group.initialized = false;
                }
                if (scrolling_active()) schedule_apply_layout();
            });
            settings.changed["tiling-gap"].connect(() => {
                foreach (var group in scrolling_groups.values)
                    group.initialized = false;
                if (scrolling_active()) schedule_apply_layout();
            });
            app_system.config_changed.connect((key) => {
                if (key == "dock-position" || key == "dock-enabled"
                        || key == "dock-autohide"
                        || key == "dock-intellihide"
                        || key == "dock-reservation") {
                    if (scrolling_active()) schedule_apply_layout();
                }
            });
            app_system.app_opened.connect(on_app_opened);
            app_system.app_closed.connect(on_app_closed);
            app_system.workspaces_changed.connect(on_workspaces_changed);
            app_system.window_focused.connect(on_window_focused);
            app_system.window_output_changed.connect(on_window_output_changed);
            app_system.any_maximized_changed.connect(on_window_state_changed);
            app_system.any_fullscreen_changed.connect(on_window_state_changed);
            Singularity.wayland_set_tiling_interaction_callback(
                on_tiling_interaction, this);
            Singularity.wayland_set_cursor_position_callback(
                on_cursor_position, this);
            if (safe_mode.allows(SafeFeature.TILING)) sync_compositor_mode();
            if (enabled) schedule_apply_layout();
        }

        private void setup_close_gesture_indicator() {
            close_gesture_indicator = new Gtk.Window();
            GtkLayerShell.init_for_window(close_gesture_indicator);
            GtkLayerShell.set_layer(close_gesture_indicator, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_anchor(close_gesture_indicator, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(close_gesture_indicator, GtkLayerShell.Edge.BOTTOM, true);
            GtkLayerShell.set_anchor(close_gesture_indicator, GtkLayerShell.Edge.LEFT, true);
            GtkLayerShell.set_anchor(close_gesture_indicator, GtkLayerShell.Edge.RIGHT, true);
            GtkLayerShell.set_exclusive_zone(close_gesture_indicator, -1);
            GtkLayerShell.set_keyboard_mode(close_gesture_indicator, GtkLayerShell.KeyboardMode.NONE);
            var overlay = new Gtk.Overlay();
            close_gesture_danger = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            close_gesture_danger.add_css_class("tiling-close-danger");
            close_gesture_danger.opacity = 0;
            overlay.set_child(close_gesture_danger);
            close_gesture_icon = new Gtk.Image.from_icon_name("user-trash-symbolic");
            close_gesture_icon.pixel_size = 42;
            close_gesture_icon.add_css_class("accent");
            close_gesture_icon.halign = Gtk.Align.CENTER;
            close_gesture_icon.valign = Gtk.Align.CENTER;
            close_gesture_icon.opacity = 0;
            overlay.add_overlay(close_gesture_icon);
            close_gesture_indicator.set_child(overlay);
            close_gesture_indicator.add_css_class("singularity");
            close_gesture_indicator.add_css_class("tiling-close-indicator");
            var provider = new Gtk.CssProvider();
            provider.load_from_string("""
.tiling-close-danger {
    background-color: alpha(@destructive_color, 0.16);
}
.tiling-close-indicator {
    background-color: transparent;
}
.tiling-close-indicator image.armed {
    color: @destructive_color;
}
""");
            var display = Gdk.Display.get_default();
            if (display != null) {
                Gtk.StyleContext.add_provider_for_display(display, provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_USER + 2);
            }
            close_gesture_indicator.visible = false;
        }

        private bool scrolling_active() {
            return enabled && settings.get_string("tiling-layout") == "scrolling";
        }

        private int scroll_gap() {
            return settings.get_int("tiling-gap").clamp(0, 64);
        }

        private void sync_compositor_mode() {
            if (!safe_mode.allows(SafeFeature.TILING)) return;
            Singularity.wayland_set_scrolling_mode(scrolling_active() ? 1u : 0u);
        }

        private void on_mode_changed() {
            enabled = settings.get_boolean("tiling-enabled")
                && safe_mode.allows(SafeFeature.TILING);
            // Persist configuration changes in recovery mode, but do not send
            // any tiling protocol requests while the feature is blocked.
            if (!safe_mode.allows(SafeFeature.TILING)) return;
            bool is_scrolling = scrolling_active();
            sync_compositor_mode();
            hide_drop_preview();
            if (!is_scrolling) {
                insertion_anchors.clear();
                last_scrolling_focus = null;
                if (scrolling_groups.size > 0) release_scrolling_windows();
            }
            if (enabled) schedule_apply_layout();
        }

        public void set_shell_overview_active(bool active) {
            if (shell_overview_active == active) return;
            shell_overview_active = active;
            if (!active && scrolling_active()) schedule_apply_layout();
        }

        public void refresh_scrolling_position() {
            bool emitted = false;
            foreach (var group in scrolling_groups.values) {
                emit_position(group);
                emitted = true;
            }
            if (!emitted) {
                if (scrolling_active()) schedule_apply_layout();
                else scrolling_position_changed(null, 0, 1, false);
            }
        }

        public void workarea_changed() {
            if (scrolling_active()) schedule_apply_layout();
        }

        private void schedule_apply_layout() {
            if (apply_timeout_id != 0) GLib.Source.remove(apply_timeout_id);
            apply_timeout_id = GLib.Timeout.add(70, () => {
                apply_timeout_id = 0;
                apply_layout();
                return Source.REMOVE;
            }, GLib.Priority.DEFAULT_IDLE);
        }

        private void on_app_opened(void* handle, string app_id) {
            if (scrolling_active() && last_scrolling_focus != null) {
                var win = app_system.get_window_by_handle(handle);
                if (win != null && win != last_scrolling_focus)
                    insertion_anchors[win] = last_scrolling_focus;
            }
            if (enabled) schedule_apply_layout();
        }

        private void on_app_closed(void* handle) {
            AppSystem.Window? closed = null;
            foreach (var win in insertion_anchors.keys) {
                if (win.handle == handle) {
                    closed = win;
                    break;
                }
            }
            if (closed != null) insertion_anchors.unset(closed);
            if (enabled) schedule_apply_layout();
        }

        private void on_workspaces_changed() {
            if (enabled) schedule_apply_layout();
        }

        private void on_window_focused(void* handle) {
            pointer_focus_window = null;
            bool focus_event_changed = handle != observed_focus_handle;
            observed_focus_handle = handle;
            if (enabled && handle != null) {
                var win = app_system.get_window_by_handle(handle);
                var group = win != null ? group_for_window(win) : null;
                if (win != null && group != null) {
                    if (focus_event_changed)
                        group.focus_reveal_pending = true;
                    last_scrolling_focus = win;
                    if (scrolling_active()) {
                        if (!pointer_focus_request_pending) {
                            pointer_focus_request_pending =
                                Singularity.wayland_request_cursor_position();
                        }
                        if (pointer_focus_request_pending) return;
                    }
                }
                schedule_apply_layout();
            }
        }

        private static void on_cursor_position(int cursor_x, int cursor_y,
                void* data) {
            var self = (TilingManager)data;
            self.pointer_focus_request_pending = false;
            self.update_pointer_focus(cursor_x, cursor_y);
            if (self.enabled) self.schedule_apply_layout();
        }

        private void update_pointer_focus(int cursor_x, int cursor_y) {
            pointer_focus_window = null;
            if (!scrolling_active() || observed_focus_handle == null) return;
            var win = app_system.get_window_by_handle(observed_focus_handle);
            if (win == null) return;
            var group = group_for_window(win);
            if (group == null) return;
            var rect = rect_for_window(group, win);
            if (rect == null
                    || cursor_x < rect.x
                    || cursor_x >= rect.x + rect.width
                    || cursor_y < rect.y
                    || cursor_y >= rect.y + rect.height) return;
            pointer_focus_window = win;
            pointer_focus_x = cursor_x;
            pointer_focus_y = cursor_y;
        }

        private void on_window_output_changed(void* handle) {
            if (scrolling_active()) return;
            if (enabled) schedule_apply_layout();
        }

        private void on_window_state_changed() {
            if (enabled) schedule_apply_layout();
        }

        private void snap(AppSystem.Window win, uint snap_type) {
            if (win.scrolling_tiled) {
                Singularity.wayland_set_tiled(win.handle, 0);
                win.scrolling_tiled = false;
            }
            win.scrolling_floating = false;
            Singularity.wayland_snap_view(win.handle, snap_type);
            win.snap_type = snap_type;
        }

        private ArrayList<AppSystem.Window> get_tileable_windows() {
            var tileable = new ArrayList<AppSystem.Window>();
            foreach (var win in app_system.get_active_workspace_windows()) {
                if (win.app_id == null || win.app_id == "unknown-wayland-surface")
                    continue;
                if (win.app_id.has_prefix("chrome-")
                        || win.app_id.contains(".flextop.chrome-"))
                    continue;
                if (!Singularity.wayland_window_is_tileable(win.handle))
                    continue;
                if (scrolling_active() && win.scrolling_floating) continue;
                tileable.add(win);
            }
            return tileable;
        }

        private void hide_drop_preview() {
            if (!safe_mode.allows(SafeFeature.TILING)) return;
            Singularity.wayland_set_tiling_drop_preview(0, 0, 0, 0, 0);
        }

        private void cancel_offset_animation(ScrollingGroup group) {
            if (group.offset_animation_id == 0) return;
            GLib.Source.remove(group.offset_animation_id);
            group.offset_animation_id = 0;
        }

        private bool animate_offset(ScrollingGroup group, double target) {
            target = clamp_offset(group, target);
            if (Math.fabs(target - group.offset) < 0.5) {
                group.offset = target;
                return false;
            }
            cancel_offset_animation(group);
            group.offset_animation_start = group.offset;
            group.offset_animation_target = target;
            group.offset_animation_started = GLib.get_monotonic_time();
            group.offset_animation_id = GLib.Timeout.add(16, () => {
                double elapsed = (GLib.get_monotonic_time()
                    - group.offset_animation_started) / 1000.0;
                double progress = double.min(1,
                    elapsed / OFFSET_SETTLE_DURATION);
                double eased = 1 - Math.pow(1 - progress, 3);
                group.offset = group.offset_animation_start
                    + (group.offset_animation_target
                        - group.offset_animation_start) * eased;
                layout_group(group);
                if (progress >= 1) {
                    group.offset_animation_id = 0;
                    return GLib.Source.REMOVE;
                }
                return GLib.Source.CONTINUE;
            });
            return true;
        }

        private void release_scrolling_windows() {
            hide_drop_preview();
            foreach (var group in scrolling_groups.values)
                cancel_offset_animation(group);
            foreach (var win in app_system.get_windows()) {
                if (win.scrolling_tiled) {
                    Singularity.wayland_set_tiled(win.handle, 0);
                    win.scrolling_tiled = false;
                }
                win.scrolling_floating = false;
            }
            scrolling_groups.clear();
            gesture_group = null;
            scrolling_position_changed(null, 0, 1, false);
        }

        private void release_untileable_scrolling_windows(
                ArrayList<AppSystem.Window> tileable) {
            var tileable_set = new HashSet<AppSystem.Window>();
            foreach (var win in tileable) tileable_set.add(win);
            foreach (var win in app_system.get_active_workspace_windows()) {
                if (!win.scrolling_tiled || tileable_set.contains(win))
                    continue;
                Singularity.wayland_set_tiled(win.handle, 0);
                win.scrolling_tiled = false;
            }
        }

        private void apply_grid_layout(ArrayList<AppSystem.Window> tileable) {
            int count = tileable.size;
            if (count == 0) return;
            for (int i = 0; i < count; i++) {
                snap(tileable[i], TilingLayout.snap_for(count, i));
            }
        }

        private void adjust_workarea_for_dock(Gdk.Monitor? monitor,
                                              ref int x, ref int y,
                                              ref int width, ref int height) {
            int dock = app_system.shell_dock_height;
            if (dock <= 0 || monitor == null) return;
            var geometry = monitor.get_geometry();
            string position = settings.get_string("dock-position");
            if (position == "bottom"
                    && y + height >= geometry.y + geometry.height) {
                height -= dock;
            } else if (position == "left" && x <= geometry.x) {
                x += dock;
                width -= dock;
            } else if (position == "right"
                    && x + width >= geometry.x + geometry.width) {
                width -= dock;
            }
        }

        private bool get_layout_workarea(
                                         ArrayList<ScrollingWorkarea> output_areas,
                                         out int x, out int y,
                                         out int width, out int height) {
            if (Singularity.wayland_get_layout_workarea(
                    out x, out y, out width, out height)) {
                int count = Singularity.wayland_get_layout_output_count();
                for (int i = 0; i < count; i++) {
                    int ox, oy, ow, oh;
                    if (Singularity.wayland_get_layout_output_workarea(i,
                            out ox, out oy, out ow, out oh))
                        output_areas.add(new ScrollingWorkarea(
                            ox, oy, ow, oh));
                }
                if (output_areas.size == 0)
                    output_areas.add(new ScrollingWorkarea(
                        x, y, width, height));
                return true;
            }

            x = y = width = height = 0;
            var display = Gdk.Display.get_default();
            if (display == null) return false;
            var monitors = display.get_monitors();
            bool found = false;
            int right = 0;
            int bottom = 0;
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = monitors.get_item(i) as Gdk.Monitor;
                if (monitor == null) continue;
                var geometry = monitor.get_geometry();
                int mx = geometry.x;
                int my = geometry.y;
                int mw = geometry.width;
                int mh = geometry.height;
                adjust_workarea_for_dock(monitor,
                    ref mx, ref my, ref mw, ref mh);
                output_areas.add(new ScrollingWorkarea(mx, my, mw, mh));
                if (!found) {
                    x = mx;
                    right = mx + mw;
                    y = my;
                    bottom = my + mh;
                    found = true;
                    continue;
                }
                x = int.min(x, mx);
                right = int.max(right, mx + mw);
                y = int.min(y, my);
                bottom = int.max(bottom, my + mh);
            }
            width = right - x;
            height = bottom - y;
            return found && width > 0 && height > 0;
        }

        private int reference_monitor_width() {
            var monitor = Panel.find_primary_monitor();
            return monitor != null
                ? monitor.get_geometry().width : MIN_COLUMN_WIDTH;
        }

        private int default_column_width(ScrollingGroup group) {
            int available = int.max(1, group.reference_width);
            int width = group.reference_width
                * settings.get_int("tiling-column-width") / 100;
            return int.min(available, int.max(MIN_COLUMN_WIDTH, width));
        }

        private int initial_column_width(ScrollingGroup group,
                                         AppSystem.Window win) {
            int fallback = default_column_width(group);
            if (!win.scrolling_tiled && !startup_windows.contains(win))
                return fallback;
            int x, y, width, height, maximized, fullscreen;
            string? connector;
            if (!Singularity.wayland_get_window_geometry(win.handle,
                    out x, out y, out width, out height,
                    out maximized, out fullscreen, out connector))
                return fallback;
            startup_windows.remove(win);
            if (width <= 0 || height <= 0 || maximized != 0 || fullscreen != 0
                    || x + width <= group.area.x
                    || x >= group.area.x + group.area.width
                    || y + height <= group.area.y
                    || y >= group.area.y + group.area.height)
                return fallback;
            int available = int.max(MIN_COLUMN_WIDTH, group.reference_width);
            return int.min(available, int.max(MIN_COLUMN_WIDTH, width));
        }

        private int width_for(ScrollingGroup group, ScrollingColumn column) {
            if (column.width <= 0) column.width = default_column_width(group);
            int available = int.max(MIN_COLUMN_WIDTH, group.reference_width);
            return int.min(available, int.max(MIN_COLUMN_WIDTH, column.width));
        }

        private ScrollingColumn? column_for_window(ScrollingGroup group,
                                                    AppSystem.Window win) {
            foreach (var column in group.columns) {
                if (column.windows.contains(win)) return column;
            }
            return null;
        }

        private double logical_x(ScrollingGroup group,
                                 ScrollingColumn target) {
            double x = 0;
            foreach (var column in group.columns) {
                if (column == target) return x;
                x += width_for(group, column) + scroll_gap();
            }
            return x;
        }

        private double content_width(ScrollingGroup group) {
            double width = 0;
            for (int i = 0; i < group.columns.size; i++) {
                width += width_for(group, group.columns[i]);
                if (i + 1 < group.columns.size) width += scroll_gap();
            }
            return width;
        }

        private double viewport_width(ScrollingGroup group) {
            return int.max(1, group.area.width);
        }

        private ScrollingWorkarea? output_area_for_monitor(
                ScrollingGroup group, Gdk.Monitor? monitor) {
            if (monitor == null) return null;
            var geometry = monitor.get_geometry();
            ScrollingWorkarea? target = null;
            int64 best_overlap = 0;
            foreach (var area in group.output_areas) {
                int overlap_width = int.max(0,
                    int.min(area.x + area.width,
                        geometry.x + geometry.width)
                    - int.max(area.x, geometry.x));
                int overlap_height = int.max(0,
                    int.min(area.y + area.height,
                        geometry.y + geometry.height)
                    - int.max(area.y, geometry.y));
                int64 overlap = (int64)overlap_width * overlap_height;
                if (overlap > best_overlap) {
                    target = area;
                    best_overlap = overlap;
                }
            }
            return target;
        }

        private Gdk.Monitor? monitor_for_output_area(
                ScrollingGroup group, ScrollingWorkarea area) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            Gdk.Monitor? target = null;
            int64 best_overlap = 0;
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = monitors.get_item(i) as Gdk.Monitor;
                if (monitor == null) continue;
                if (output_area_for_monitor(group, monitor) != area) continue;
                var geometry = monitor.get_geometry();
                int overlap_width = int.max(0,
                    int.min(area.x + area.width,
                        geometry.x + geometry.width)
                    - int.max(area.x, geometry.x));
                int overlap_height = int.max(0,
                    int.min(area.y + area.height,
                        geometry.y + geometry.height)
                    - int.max(area.y, geometry.y));
                int64 overlap = (int64)overlap_width * overlap_height;
                if (overlap > best_overlap) {
                    target = monitor;
                    best_overlap = overlap;
                }
            }
            return target;
        }

        private void offset_limits(ScrollingGroup group,
                                   out double minimum, out double maximum) {
            if (group.columns.size == 0) {
                minimum = maximum = 0;
                return;
            }
            ScrollingWorkarea? left_area = null;
            ScrollingWorkarea? right_area = null;
            foreach (var area in group.output_areas) {
                if (left_area == null || area.x < left_area.x)
                    left_area = area;
                if (right_area == null
                        || area.x + area.width
                            > right_area.x + right_area.width)
                    right_area = area;
            }
            if (left_area == null || right_area == null) {
                minimum = maximum = 0;
                return;
            }
            var first = group.columns[0];
            var last = group.columns[group.columns.size - 1];
            double first_limit = group.area.x
                + width_for(group, first) / 2.0
                - (right_area.x + right_area.width / 2.0);
            double last_limit = group.area.x + logical_x(group, last)
                + width_for(group, last) / 2.0
                - (left_area.x + left_area.width / 2.0);
            minimum = double.min(0, double.min(first_limit, last_limit));
            maximum = double.max(0, double.max(first_limit, last_limit));
        }

        private double clamp_offset(ScrollingGroup group, double offset) {
            double minimum, maximum;
            offset_limits(group, out minimum, out maximum);
            return double.max(minimum, double.min(maximum, offset));
        }

        private ScrollingRect? current_rect_for_window(
                AppSystem.Window win) {
            int x, y, width, height, maximized, fullscreen;
            string? connector;
            if (!Singularity.wayland_get_window_geometry(win.handle,
                    out x, out y, out width, out height,
                    out maximized, out fullscreen, out connector)
                    || width < 1 || height < 1)
                return null;
            return new ScrollingRect(x, y, width, height);
        }

        private ScrollingRect? offset_rect(ScrollingGroup group,
                                           AppSystem.Window win,
                                           bool use_current_geometry) {
            var rect = use_current_geometry
                ? current_rect_for_window(win) : null;
            return rect ?? rect_for_window(group, win);
        }

        private ScrollingWorkarea? area_for_rect(ScrollingGroup group,
                                                 ScrollingRect rect,
                                                 int cursor_x,
                                                 int cursor_y) {
            if (cursor_x != int.MIN && cursor_y != int.MIN) {
                foreach (var area in group.output_areas) {
                    if (cursor_x >= area.x
                            && cursor_x < area.x + area.width
                            && cursor_y >= area.y
                            && cursor_y < area.y + area.height)
                        return area;
                }
            }
            ScrollingWorkarea? target = null;
            int best_overlap = -1;
            double best_distance = double.MAX;
            double center = rect.x + rect.width / 2.0;
            foreach (var area in group.output_areas) {
                int overlap = int.max(0,
                    int.min(rect.x + rect.width, area.x + area.width)
                    - int.max(rect.x, area.x));
                double distance = Math.fabs(center
                    - (area.x + area.width / 2.0));
                if (overlap > best_overlap
                        || (overlap == best_overlap
                            && distance < best_distance)) {
                    target = area;
                    best_overlap = overlap;
                    best_distance = distance;
                }
            }
            return target;
        }

        private double visible_offset(ScrollingGroup group,
                                      AppSystem.Window win,
                                      int cursor_x = int.MIN,
                                      int cursor_y = int.MIN,
                                      bool use_current_geometry = false) {
            var rect = offset_rect(group, win, use_current_geometry);
            if (rect == null) return group.offset;
            var target = area_for_rect(group, rect, cursor_x, cursor_y);
            if (target == null) return group.offset;
            if (rect.x >= target.x
                    && rect.x + rect.width <= target.x + target.width)
                return group.offset;
            return group.offset + rect.x + rect.width / 2.0
                - (target.x + target.width / 2.0);
        }

        private double reveal_offset(ScrollingGroup group,
                                     AppSystem.Window win,
                                     int cursor_x = int.MIN,
                                     int cursor_y = int.MIN,
                                     bool use_current_geometry = false) {
            var rect = offset_rect(group, win, use_current_geometry);
            if (rect == null) return group.offset;
            var target = area_for_rect(group, rect, cursor_x, cursor_y);
            if (target == null) return group.offset;
            if (rect.width >= target.width || rect.x < target.x)
                return group.offset + rect.x - target.x;
            if (rect.x + rect.width > target.x + target.width)
                return group.offset + rect.x + rect.width
                    - (target.x + target.width);
            return group.offset;
        }

        private double snap_offset(ScrollingGroup group,
                                   AppSystem.Window win) {
            return group.output_areas.size > 1
                ? reveal_offset(group, win) : visible_offset(group, win);
        }

        private void scroll_drag_viewport(ScrollingGroup group,
                                          int cursor_x) {
            int edge_size = int.min(180, group.area.width / 5);
            int left_edge = group.area.x + edge_size;
            int right_edge = group.area.x + group.area.width - edge_size;
            double delta = 0;
            if (cursor_x < left_edge) {
                double progress = double.min(1,
                    (double)(left_edge - cursor_x) / edge_size);
                delta = -24.0 * progress;
            } else if (cursor_x > right_edge) {
                double progress = double.min(1,
                    (double)(cursor_x - right_edge) / edge_size);
                delta = 24.0 * progress;
            }
            if (Math.fabs(delta) > 0.01)
                group.offset = clamp_offset(group, group.offset + delta);
        }

        private void emit_position(ScrollingGroup group) {
            double content = content_width(group);
            bool active = group.columns.size > 0 && scrolling_active();
            bool emitted = false;
            foreach (var area in group.output_areas) {
                var monitor = monitor_for_output_area(group, area);
                if (monitor == null) continue;
                double viewport = int.max(1, area.width);
                double range = double.max(0, content - viewport);
                double start = group.offset + area.x - group.area.x;
                double position = range > 0.5 ? start / range : 0.5;
                position = double.max(0, double.min(1, position));
                double fraction = content > 0
                    ? double.min(1, viewport / content) : 1;
                scrolling_position_changed(monitor, position, fraction,
                    active);
                emitted = true;
            }
            if (emitted) return;

            double minimum, maximum;
            offset_limits(group, out minimum, out maximum);
            double range = maximum - minimum;
            double position = range > 0.5
                ? (group.offset - minimum) / range : 0.5;
            position = double.max(0, double.min(1, position));
            double fraction = content > 0
                ? double.min(1, viewport_width(group) / content) : 1;
            scrolling_position_changed(group.monitor, position, fraction,
                active);
        }

        private ScrollingRect rect_for(ScrollingGroup group,
                                       ScrollingColumn column,
                                       int row) {
            return rect_for_count(group, column, row,
                int.max(1, column.windows.size));
        }

        private ScrollingRect rect_for_count(ScrollingGroup group,
                                             ScrollingColumn column,
                                             int row, int count) {
            int x = group.area.x
                + (int)Math.round(logical_x(group, column) - group.offset);
            int column_width = width_for(group, column);
            double weighted_y = 0;
            double weighted_bottom = 0;
            int total_overlap = 0;
            foreach (var area in group.output_areas) {
                int overlap = int.max(0,
                    int.min(x + column_width, area.x + area.width)
                    - int.max(x, area.x));
                if (overlap == 0) continue;
                weighted_y += area.y * overlap;
                weighted_bottom += (area.y + area.height) * overlap;
                total_overlap += overlap;
            }
            int area_y = group.area.y;
            int area_height = group.area.height;
            if (total_overlap > 0) {
                area_y = (int)Math.round(weighted_y / total_overlap);
                int area_bottom = (int)Math.round(
                    weighted_bottom / total_overlap);
                area_height = int.max(1, area_bottom - area_y);
            }
            int total_height = int.max(count,
                area_height - (count - 1) * scroll_gap());
            int base_height = total_height / count;
            int remainder = total_height % count;
            int gap = scroll_gap();
            int y = area_y;
            for (int i = 0; i < row; i++) {
                y += base_height + (i < remainder ? 1 : 0) + gap;
            }
            int height = base_height + (row < remainder ? 1 : 0);
            return new ScrollingRect(x, y, column_width, height);
        }

        private ScrollingRect? rect_for_window(ScrollingGroup group,
                                               AppSystem.Window win) {
            var column = column_for_window(group, win);
            if (column == null) return null;
            int row = column.windows.index_of(win);
            return row >= 0 ? rect_for(group, column, row) : null;
        }

        private void layout_group(ScrollingGroup group,
                                  AppSystem.Window? skip = null) {
            foreach (var column in group.columns) {
                for (int row = 0; row < column.windows.size; row++) {
                    var win = column.windows[row];
                    if (win == skip) continue;
                    var rect = rect_for(group, column, row);
                    if (!win.scrolling_tiled) {
                        Singularity.wayland_set_tiled(win.handle, 1);
                        win.scrolling_tiled = true;
                    }
                    Singularity.wayland_set_geometry(win.handle,
                        rect.x, rect.y, rect.width, rect.height);
                    win.snap_type = TilingLayout.SNAP_NONE;
                }
            }
            emit_position(group);
        }

        private void show_drop_preview(ScrollingGroup group,
                                       AppSystem.Window win) {
            var rect = rect_for_window(group, win);
            if (rect == null) {
                hide_drop_preview();
                return;
            }
            Singularity.wayland_set_tiling_drop_preview(rect.x, rect.y,
                rect.width, rect.height, 1);
        }

        private void show_stack_preview(ScrollingGroup group,
                                        StackTarget target) {
            var rect = rect_for_count(group, target.column, target.index,
                target.column.windows.size + 1);
            Singularity.wayland_set_tiling_drop_preview(rect.x, rect.y,
                rect.width, rect.height, 1);
        }

        private void remove_empty_columns(ScrollingGroup group) {
            var empty = new ArrayList<ScrollingColumn>();
            foreach (var column in group.columns) {
                if (column.windows.size == 0) empty.add(column);
            }
            foreach (var column in empty) group.columns.remove(column);
        }

        private void sync_group(ScrollingGroup group,
                                ArrayList<AppSystem.Window> candidates) {
            AppSystem.Window? anchor = null;
            if (group.focused != null && candidates.contains(group.focused))
                anchor = group.focused;
            if (anchor == null) {
                foreach (var column in group.columns) {
                    foreach (var win in column.windows) {
                        if (!candidates.contains(win)) continue;
                        anchor = win;
                        break;
                    }
                    if (anchor != null) break;
                }
            }
            ScrollingRect? anchor_rect = anchor != null
                ? rect_for_window(group, anchor) : null;
            var stale = new ArrayList<AppSystem.Window>();
            foreach (var column in group.columns) {
                foreach (var win in column.windows) {
                    if (!candidates.contains(win)) stale.add(win);
                }
            }
            foreach (var win in stale) {
                var column = column_for_window(group, win);
                if (column != null) column.windows.remove(win);
                insertion_anchors.unset(win);
                if (group.focused == win) group.focused = null;
                if (group.interaction_window == win)
                    group.interaction_window = null;
                if (last_scrolling_focus == win) last_scrolling_focus = null;
            }
            remove_empty_columns(group);
            foreach (var win in candidates) {
                if (column_for_window(group, win) != null) continue;
                var column = new ScrollingColumn(
                    initial_column_width(group, win));
                column.windows.add(win);
                var insertion_anchor = insertion_anchors.get(win);
                var anchor_column = insertion_anchor != null
                    ? column_for_window(group, insertion_anchor) : null;
                if (anchor_column == null) {
                    group.columns.add(column);
                } else {
                    group.columns.insert(group.columns.index_of(anchor_column) + 1,
                        column);
                }
                insertion_anchors.unset(win);
            }
            if (anchor != null && anchor_rect != null) {
                var anchor_column = column_for_window(group, anchor);
                if (anchor_column != null) {
                    group.offset = group.area.x
                        + logical_x(group, anchor_column) - anchor_rect.x;
                }
            }
        }

        private AppSystem.Window? focused_in_group(ScrollingGroup group) {
            void* focused = app_system.get_focused_window_handle();
            foreach (var column in group.columns) {
                foreach (var win in column.windows) {
                    if (win.handle == focused) return win;
                }
            }
            return null;
        }

        private void apply_scrolling_layout(
                ArrayList<AppSystem.Window> tileable) {
            int x, y, width, height;
            var output_areas = new ArrayList<ScrollingWorkarea>();
            if (!get_layout_workarea(output_areas,
                    out x, out y, out width, out height))
                return;
            string key = "layout";
            ScrollingGroup? group = scrolling_groups[key];
            int reference_width = reference_monitor_width();
            if (group == null) {
                group = new ScrollingGroup(key,
                    new ScrollingWorkarea(x, y, width, height),
                    output_areas, reference_width, null);
                scrolling_groups[key] = group;
            } else {
                group.area = new ScrollingWorkarea(x, y, width, height);
                group.output_areas = output_areas;
                group.reference_width = reference_width;
            }
            var candidates = new ArrayList<AppSystem.Window>();
            foreach (var win in tileable) {
                if (win.is_fullscreen || win.is_minimized) continue;
                candidates.add(win);
            }

            var stale_keys = new ArrayList<string>();
            foreach (var entry in scrolling_groups.entries) {
                if (entry.key != key) {
                    cancel_offset_animation(entry.value);
                    scrolling_position_changed(entry.value.monitor, 0, 1, false);
                    stale_keys.add(entry.key);
                }
            }
            foreach (var stale_key in stale_keys)
                scrolling_groups.unset(stale_key);

            sync_group(group, candidates);
            if (group.columns.size == 0) {
                emit_position(group);
                return;
            }
            if (group == gesture_group) {
                cancel_offset_animation(group);
                group.offset = clamp_offset(group, group.offset);
                layout_group(group);
                return;
            }
            if (group.interaction_window != null
                    && column_for_window(group,
                        group.interaction_window) != null) {
                cancel_offset_animation(group);
                group.offset = clamp_offset(group, group.offset);
                layout_group(group, group.interaction_window);
                return;
            }
            var focused = focused_in_group(group);
            bool focus_changed = focused != null
                && (focused != group.focused || group.focus_reveal_pending);
            if (focused != null) {
                group.focused = focused;
                group.focus_reveal_pending = false;
                last_scrolling_focus = focused;
            }
            if (group.focused == null
                    || column_for_window(group, group.focused) == null)
                group.focused = group.columns[0].windows[0];
            if (!group.initialized || focus_changed) {
                var current_rect = current_rect_for_window(group.focused);
                var current_column = column_for_window(group, group.focused);
                if (focus_changed && current_rect != null
                        && current_column != null) {
                    group.offset = group.area.x
                        + logical_x(group, current_column) - current_rect.x;
                }
                int cursor_x = int.MIN;
                int cursor_y = int.MIN;
                if (pointer_focus_window == group.focused) {
                    cursor_x = pointer_focus_x;
                    cursor_y = pointer_focus_y;
                }
                double target = reveal_offset(group, group.focused,
                    cursor_x, cursor_y, true);
                pointer_focus_window = null;
                bool animate = group.initialized
                    && animate_offset(group, target);
                group.initialized = true;
                if (animate) return;
                group.offset = target;
            } else {
                group.offset = clamp_offset(group, group.offset);
            }
            layout_group(group);
        }

        private ScrollingGroup? group_for_window(AppSystem.Window win) {
            foreach (var group in scrolling_groups.values) {
                if (column_for_window(group, win) != null) return group;
            }
            return null;
        }

        private ScrollingGroup? focused_group() {
            void* focused = app_system.get_focused_window_handle();
            if (focused == null) return null;
            var win = app_system.get_window_by_handle(focused);
            return win != null ? group_for_window(win) : null;
        }

        public bool move_focused_slot(int direction) {
            if (!scrolling_active()) return false;
            apply_layout();
            var group = focused_group();
            if (group == null) return true;
            var win = focused_in_group(group);
            if (win == null) return true;
            var column = column_for_window(group, win);
            if (column == null) return true;
            int index = group.columns.index_of(column);
            int target = int.max(0, int.min(group.columns.size - 1,
                index + direction));
            if (target == index) return true;
            group.columns.remove_at(index);
            group.columns.insert(target, column);
            group.focused = win;
            if (animate_offset(group, snap_offset(group, win))) return true;
            layout_group(group);
            return true;
        }

        public void set_slot_organizer_hover(AppSystem.Window win,
                                              bool hovering) {
            if (!scrolling_active()) return;
            if (hovering) {
                organizer_hover_window = win;
            } else if (organizer_hover_window == win) {
                organizer_hover_window = null;
            }
        }

        public bool begin_slot_organizer(AppSystem.Window win) {
            if (!scrolling_active() || group_for_window(win) == null)
                return false;
            organizer_hover_window = win;
            organizer_window = win;
            return true;
        }

        public AppSystem.Window[] slot_organizer_windows(AppSystem.Window win) {
            AppSystem.Window[] result = {};
            var group = group_for_window(win);
            if (group == null) return result;
            foreach (var column in group.columns) {
                foreach (var item in column.windows) result += item;
            }
            return result;
        }

        public void move_slot_organizer_window(AppSystem.Window win,
                                                int target) {
            if (organizer_window != win) return;
            var group = group_for_window(win);
            if (group == null) return;
            var column = column_for_window(group, win);
            if (column == null) return;
            int index = group.columns.index_of(column);
            target = int.max(0, int.min(group.columns.size - 1, target));
            if (index == target) return;
            group.columns.remove_at(index);
            group.columns.insert(target, column);
            layout_group(group, win);
        }

        private ScrollingGroup? gesture_group_fallback() {
            var group = focused_group();
            if (group != null) return group;
            foreach (var candidate in scrolling_groups.values) {
                if (candidate.columns.size > 0) return candidate;
            }
            return null;
        }

        private ScrollingColumn? nearest_column(ScrollingGroup group) {
            if (group.columns.size == 0) return null;
            double viewport_center = group.offset + viewport_width(group) / 2.0;
            ScrollingColumn nearest = group.columns[0];
            double best = double.MAX;
            foreach (var column in group.columns) {
                double center = logical_x(group, column)
                    + width_for(group, column) / 2.0;
                double distance = Math.fabs(center - viewport_center);
                if (distance < best) {
                    best = distance;
                    nearest = column;
                }
            }
            return nearest;
        }

        private ScrollingColumn? nearest_column_on_output(
                ScrollingGroup group, ScrollingWorkarea area) {
            if (group.columns.size == 0) return null;
            double output_center = area.x + area.width / 2.0;
            ScrollingColumn nearest = group.columns[0];
            double best = double.MAX;
            foreach (var column in group.columns) {
                double center = group.area.x + logical_x(group, column)
                    + width_for(group, column) / 2.0 - group.offset;
                double distance = Math.fabs(center - output_center);
                if (distance < best) {
                    best = distance;
                    nearest = column;
                }
            }
            return nearest;
        }

        public bool scroll_on_monitor(Gdk.Monitor? monitor, int direction) {
            if (!scrolling_active() || direction == 0) return false;
            apply_layout();
            var group = gesture_group_fallback();
            if (group == null) return false;
            var area = output_area_for_monitor(group, monitor);
            if (area == null) return false;
            var current = nearest_column_on_output(group, area);
            if (current == null) return false;
            int index = group.columns.index_of(current);
            int target_index = int.max(0, int.min(group.columns.size - 1,
                index + (direction > 0 ? 1 : -1)));
            if (target_index == index) return true;
            var target = group.columns[target_index];
            var win = target.windows[0];
            group.focused = win;
            last_scrolling_focus = win;
            double target_offset = group.area.x + logical_x(group, target)
                + width_for(group, target) / 2.0
                - (area.x + area.width / 2.0);
            Singularity.wayland_activate_window(win.handle);
            if (animate_offset(group, target_offset)) return true;
            group.offset = clamp_offset(group, target_offset);
            layout_group(group);
            return true;
        }

        private AppSystem.Window? nearest_window(ScrollingGroup group) {
            var nearest = nearest_column(group);
            if (nearest == null) return null;
            if (group.focused != null && nearest.windows.contains(group.focused))
                return group.focused;
            return nearest.windows[0];
        }

        public bool handle_scrolling_gesture(uint32 phase, double dx,
                                             bool cancelled) {
            if (!scrolling_active() || shell_overview_active) return false;
            if (phase == 0) {
                apply_layout();
                gesture_group = focused_group();
                if (gesture_group == null) return false;
                cancel_offset_animation(gesture_group);
                gesture_start_offset = gesture_group.offset;
                gesture_start_window = focused_in_group(gesture_group);
                gesture_last_dx = 0;
                return true;
            }
            if (gesture_group == null) return false;
            var group = gesture_group;
            if (phase == 1) {
                gesture_last_dx = dx;
                group.offset = clamp_offset(group, gesture_start_offset - dx);
                layout_group(group);
                return true;
            }
            if (phase == 2) {
                AppSystem.Window? target = gesture_start_window;
                double target_offset = gesture_start_offset;
                if (cancelled) {
                    target_offset = gesture_start_offset;
                } else {
                    var nearest = nearest_column(group);
                    var start_column = gesture_start_window != null
                        ? column_for_window(group, gesture_start_window) : null;
                    if (nearest != null && start_column != null
                            && Math.fabs(gesture_last_dx)
                                >= GESTURE_ADVANCE_DISTANCE) {
                        int nearest_index = group.columns.index_of(nearest);
                        int start_index = group.columns.index_of(start_column);
                        int target_index = nearest_index;
                        if (gesture_last_dx < 0)
                            target_index = int.max(target_index,
                                int.min(group.columns.size - 1,
                                    start_index + 1));
                        else
                            target_index = int.min(target_index,
                                int.max(0, start_index - 1));
                        var target_column = group.columns[target_index];
                        target = target_column.windows.contains(
                            gesture_start_window)
                            ? gesture_start_window : target_column.windows[0];
                    } else if (nearest != null
                            && gesture_start_window == null) {
                        target = nearest.windows[0];
                    }
                    if (target != null) {
                        group.focused = target;
                        target_offset = snap_offset(group, target);
                    }
                }
                gesture_group = null;
                gesture_start_window = null;
                gesture_last_dx = 0;
                if (!cancelled && target != null)
                    Singularity.wayland_activate_window(target.handle);
                if (animate_offset(group, target_offset)) return true;
                layout_group(group);
                return true;
            }
            return true;
        }

        public bool handle_close_gesture(uint32 phase, double dy,
                                         bool cancelled, bool committed) {
            if (!scrolling_active() || shell_overview_active) return false;
            if (phase == 0) {
                apply_layout();
                close_gesture_group = gesture_group_fallback();
                if (close_gesture_group == null) return false;
                close_gesture_window = focused_in_group(close_gesture_group);
                if (close_gesture_window == null
                        && close_gesture_group.focused != null)
                    close_gesture_window = close_gesture_group.focused;
                if (close_gesture_window == null)
                    close_gesture_window = nearest_window(close_gesture_group);
                if (close_gesture_window == null) {
                    close_gesture_group = null;
                    return false;
                }
                close_gesture_rect = rect_for_window(close_gesture_group,
                    close_gesture_window);
                close_gesture_last_dy = 0;
                if (close_gesture_rect == null) {
                    close_gesture_group = null;
                    close_gesture_window = null;
                    return false;
                }
                if (close_gesture_indicator != null) {
                    if (close_gesture_danger != null)
                        close_gesture_danger.opacity = 0;
                    if (close_gesture_icon != null) {
                        close_gesture_icon.opacity = 0;
                        close_gesture_icon.remove_css_class("armed");
                    }
                    close_gesture_indicator.visible = false;
                }
                return true;
            }
            if (close_gesture_group == null || close_gesture_window == null
                    || close_gesture_rect == null) return false;
            var group = close_gesture_group;
            var win = close_gesture_window;
            var rect = close_gesture_rect;
            if (phase == 1) {
                close_gesture_last_dy = dy;
                double distance = double.max(0, dy);
                double hint_progress = double.min(1.0, double.max(0.0,
                    (distance - CLOSE_GESTURE_HINT_DISTANCE)
                        / (CLOSE_GESTURE_THRESHOLD
                            - CLOSE_GESTURE_HINT_DISTANCE)));
                double warning_progress = double.min(1.0, double.max(0.0,
                    (distance - CLOSE_GESTURE_THRESHOLD)
                        / CLOSE_GESTURE_ARM_DISTANCE));
                double resisted_distance = distance;
                if (distance > CLOSE_GESTURE_THRESHOLD) {
                    resisted_distance = CLOSE_GESTURE_THRESHOLD
                        + (distance - CLOSE_GESTURE_THRESHOLD)
                            * CLOSE_GESTURE_RESISTANCE;
                }
                if (close_gesture_icon != null) {
                    close_gesture_icon.opacity = hint_progress;
                    if (warning_progress >= 1.0)
                        close_gesture_icon.add_css_class("armed");
                    else
                        close_gesture_icon.remove_css_class("armed");
                }
                if (close_gesture_danger != null)
                    close_gesture_danger.opacity = warning_progress * 0.7;
                if (close_gesture_indicator != null) {
                    if (hint_progress > 0) {
                        if (!close_gesture_indicator.visible)
                            close_gesture_indicator.present();
                    } else {
                        close_gesture_indicator.visible = false;
                    }
                }
                Singularity.wayland_set_geometry(win.handle, rect.x,
                    rect.y + (int)Math.round(resisted_distance), rect.width,
                    rect.height);
                Singularity.wayland_set_close_gesture_progress(win.handle,
                    warning_progress);
                return true;
            }
            if (phase == 2) {
                bool close = !cancelled && committed
                    && close_gesture_last_dy >= CLOSE_GESTURE_THRESHOLD
                        + CLOSE_GESTURE_ARM_DISTANCE;
                close_gesture_group = null;
                close_gesture_window = null;
                close_gesture_rect = null;
                close_gesture_last_dy = 0;
                if (close_gesture_indicator != null)
                    close_gesture_indicator.visible = false;
                Singularity.wayland_set_close_gesture_progress(win.handle, 0);
                if (close) {
                    Singularity.close_window(win.handle);
                    schedule_apply_layout();
                } else {
                    layout_group(group);
                }
                return true;
            }
            return true;
        }

        private static void on_tiling_interaction(void* handle, uint32 phase,
                uint32 kind, int x, int y, int width, int height,
                int cursor_x, int cursor_y, uint32 edges,
                int float_candidate, void* data) {
            var self = (TilingManager)data;
            self.handle_tiling_interaction(handle, phase, kind,
                x, y, width, height, cursor_x, cursor_y, edges,
                float_candidate != 0);
        }

        private void prepare_drag(ScrollingGroup group,
                                  AppSystem.Window win) {
            group.stack_target = null;
            var source = column_for_window(group, win);
            if (source == null) return;
            if (source.windows.size == 1) {
                group.drag_column = source;
                return;
            }
            int source_index = group.columns.index_of(source);
            source.windows.remove(win);
            var column = new ScrollingColumn(width_for(group, source));
            column.windows.add(win);
            group.columns.insert(source_index + 1, column);
            group.drag_column = column;
        }

        private StackTarget? stack_target_at(ScrollingGroup group,
                                             AppSystem.Window win,
                                             int cursor_x, int cursor_y) {
            StackTarget? best = null;
            foreach (var column in group.columns) {
                for (int row = 0; row < column.windows.size; row++) {
                    var other = column.windows[row];
                    if (other == win) continue;
                    var rect = rect_for(group, column, row);
                    if (cursor_x < rect.x || cursor_x >= rect.x + rect.width)
                        continue;
                    int target_size = int.max(STACK_TARGET_SIZE,
                        rect.height * 2 / 5);
                    int top_distance = cursor_y - rect.y;
                    if (top_distance >= 0 && top_distance <= target_size
                            && (best == null || top_distance < best.distance))
                        best = new StackTarget(column, row, top_distance);
                    int bottom_distance = rect.y + rect.height - cursor_y;
                    if (bottom_distance >= 0 && bottom_distance <= target_size
                            && (best == null || bottom_distance < best.distance))
                        best = new StackTarget(column, row + 1,
                            bottom_distance);
                }
            }
            return best;
        }

        private bool cursor_over_other_column(ScrollingGroup group,
                                              AppSystem.Window win,
                                              int cursor_x) {
            foreach (var column in group.columns) {
                bool only_dragged = column.windows.size == 1
                    && column.windows[0] == win;
                if (only_dragged) continue;
                var rect = rect_for(group, column, 0);
                if (cursor_x >= rect.x && cursor_x < rect.x + rect.width)
                    return true;
            }
            return false;
        }

        private void move_to_stack(ScrollingGroup group,
                                   AppSystem.Window win,
                                   StackTarget target) {
            var source = column_for_window(group, win);
            if (source == null) return;
            var target_rect = rect_for(group, target.column, 0);
            int target_x = target_rect.x;
            int old_index = source.windows.index_of(win);
            int target_index = target.index;
            if (source == target.column && old_index < target_index)
                target_index--;
            target_index = int.max(0,
                int.min(target_index, target.column.windows.size));
            if (source == target.column && old_index == target_index) return;
            source.windows.remove(win);
            if (source.windows.size == 0) group.columns.remove(source);
            target_index = int.min(target_index, target.column.windows.size);
            target.column.windows.insert(target_index, win);
            group.offset = group.area.x
                + logical_x(group, target.column) - target_x;
            group.drag_column = target.column;
        }

        private ScrollingColumn ensure_independent_column(
                ScrollingGroup group, AppSystem.Window win,
                double dragged_center) {
            var source = column_for_window(group, win);
            if (source == null) {
                var fallback = new ScrollingColumn(default_column_width(group));
                fallback.windows.add(win);
                group.columns.add(fallback);
                return fallback;
            }
            if (source.windows.size == 1) return source;

            int width = width_for(group, source);
            source.windows.remove(win);
            var column = new ScrollingColumn(width);
            column.windows.add(win);
            int target_index = 0;
            foreach (var other in group.columns) {
                double center = group.area.x
                    + logical_x(group, other) - group.offset
                    + width_for(group, other) / 2.0;
                if (dragged_center < center) break;
                target_index++;
            }
            group.columns.insert(target_index, column);
            group.drag_column = column;
            return column;
        }

        private void reorder_drag_column(ScrollingGroup group,
                                         ScrollingColumn column,
                                         double dragged_center) {
            int old_index = group.columns.index_of(column);
            if (old_index < 0) return;
            group.columns.remove_at(old_index);
            int target_index = 0;
            double logical = 0;
            foreach (var other in group.columns) {
                double center = group.area.x + logical
                    - group.offset + width_for(group, other) / 2.0;
                if (dragged_center < center) break;
                target_index++;
                logical += width_for(group, other) + scroll_gap();
            }
            group.columns.insert(target_index, column);
        }

        private void update_drag(ScrollingGroup group,
                                 AppSystem.Window win,
                                 int x, int width,
                                 int cursor_x, int cursor_y,
                                 bool float_candidate) {
            if (float_candidate) {
                hide_drop_preview();
                layout_group(group, win);
                return;
            }
            scroll_drag_viewport(group, cursor_x);
            var target = stack_target_at(group, win, cursor_x, cursor_y);
            if (target != null) {
                group.stack_target = target;
                layout_group(group, win);
                show_stack_preview(group, target);
                return;
            }
            group.stack_target = null;
            if (cursor_over_other_column(group, win, cursor_x)) {
                hide_drop_preview();
                layout_group(group, win);
                return;
            }
            double dragged_center = x + width / 2.0;
            var column = ensure_independent_column(group, win,
                dragged_center);
            reorder_drag_column(group, column, dragged_center);
            group.drag_column = column;
            group.offset = clamp_offset(group, group.offset);
            layout_group(group, win);
            show_drop_preview(group, win);
        }

        private void detach_floating(ScrollingGroup group,
                                     AppSystem.Window win) {
            var column = column_for_window(group, win);
            if (column != null) column.windows.remove(win);
            remove_empty_columns(group);
            win.scrolling_tiled = false;
            win.scrolling_floating = true;
            Singularity.wayland_detach_tiled(win.handle);
            if (group.columns.size == 0) {
                group.focused = null;
                scrolling_position_changed(group.monitor, 0, 1, false);
                return;
            }
            group.offset = clamp_offset(group, group.offset);
            group.focused = nearest_window(group);
            layout_group(group);
        }

        private void handle_tiling_interaction(void* handle, uint32 phase,
                uint32 kind, int x, int y, int width, int height,
                int cursor_x, int cursor_y, uint32 edges,
                bool float_candidate) {
            if (!scrolling_active() || shell_overview_active) return;
            var win = app_system.get_window_by_handle(handle);
            if (win == null) return;
            var group = group_for_window(win);
            if (group == null) {
                apply_layout();
                group = group_for_window(win);
                if (group == null) return;
            }
            if (phase == 0) {
                cancel_offset_animation(group);
                group.interaction_window = win;
                group.focused = win;
                if (kind == 0) {
                    prepare_drag(group, win);
                    group.offset = clamp_offset(group, group.offset);
                    layout_group(group, win);
                    show_drop_preview(group, win);
                    scrolling_drag_changed(win, group.monitor, phase,
                        cursor_x, cursor_y);
                }
                return;
            }
            if (kind == 1) {
                var column = column_for_window(group, win);
                if (column == null) return;
                column.width = int.min(
                    int.max(MIN_COLUMN_WIDTH, group.reference_width),
                    int.max(MIN_COLUMN_WIDTH, width));
                double logical = logical_x(group, column);
                group.offset = group.area.x + logical - x;
                group.offset = clamp_offset(group, group.offset);
                layout_group(group, phase == 1 ? win : null);
                if (phase == 2) group.interaction_window = null;
                return;
            }

            if (kind == 0)
                scrolling_drag_changed(win, group.monitor, phase,
                    cursor_x, cursor_y);

            if (phase == 1 && organizer_window != win
                    && organizer_hover_window != win)
                update_drag(group, win, x, width, cursor_x, cursor_y,
                    float_candidate);
            if (phase != 2) return;

            hide_drop_preview();
            bool organized = organizer_window == win;
            if (organizer_hover_window == win) organizer_hover_window = null;
            if (organized) organizer_window = null;
            var stack_target = group.stack_target;
            group.interaction_window = null;
            group.drag_column = null;
            group.stack_target = null;
            if (organized) {
                group.focused = win;
                if (animate_offset(group, snap_offset(group, win)))
                    return;
                layout_group(group);
            } else if (float_candidate) {
                detach_floating(group, win);
            } else {
                if (stack_target != null)
                    move_to_stack(group, win, stack_target);
                group.focused = win;
                if (animate_offset(group, snap_offset(group, win)))
                    return;
                layout_group(group);
            }
        }

        public void apply_layout() {
            if (!safe_mode.allows(SafeFeature.TILING)) return;
            if (scrolling_active() && shell_overview_active) return;
            var tileable = get_tileable_windows();
            if (scrolling_active()) {
                release_untileable_scrolling_windows(tileable);
                apply_scrolling_layout(tileable);
            } else {
                release_scrolling_windows();
                if (enabled) apply_grid_layout(tileable);
            }
        }
    }
}
