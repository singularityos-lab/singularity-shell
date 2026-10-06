using Gtk;
using GtkLayerShell;
using GLib;
using Gdk;
using Math;

namespace Singularity {

    public class WorkspaceOverview : Gtk.Window {
        private AppSystem app_system;
        private Box ws_box;
        private Stack window_stack;
        private Picture background_picture;
        private Box ws_strip_container;
        private Gtk.Widget anim_box;
        private Singularity.Animation.MotionBin stage;
        private Singularity.Animation.MotionBin spread_bin;
        private Singularity.Animation.PageTransition page_transition;
        private Singularity.Animation.TimedAnimation? _stage_fade = null;
        private Singularity.Animation.SpringAnimation? _gesture_spring = null;
        private const double GESTURE_TRAVEL = 72.0;
        private const double CARD_HOVER_SCALE = 1.02;
        private const double CARD_SELECTED_SCALE = 1.04;
        private const string CARD_HOVER_KEY = "workspace-card-hovered";
        private bool _gesture_active = false;
        private bool _gesture_opening = false;
        private AppSystem.Workspace? viewed_workspace = null;
        private GLib.Settings gesture_settings = new GLib.Settings("dev.sinty.desktop");
        private int _gesture_start_index = -1;
        private int _gesture_peek_min = 0;
        private int _gesture_peek_max = 0;
        private double _gesture_dx = 0;
        private int64[] _gesture_times = {};
        private double[] _gesture_xs = {};
        private int viewed_index = -1;
        private Gdk.Monitor? pinned_monitor = null;

        public bool closing { get; private set; default = false; }

        public signal void shown();
        public signal void hidden();
        public signal void hiding();

        public WorkspaceOverview(Gtk.Application app, Gdk.Monitor? monitor = null) {
            Object(application: app);
            app_system = AppSystem.get_default();
            pinned_monitor = monitor;
            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);

            var key_controller = new EventControllerKey();
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    toggle();
                    return true;
                }
                // Tab / Right / Down, next workspace (immediate, no hover delay)
                if (keyval == Gdk.Key.Tab || keyval == Gdk.Key.Right || keyval == Gdk.Key.Down) {
                    cycle_viewed_workspace(1);
                    return true;
                }
                // Shift+Tab / Left / Up, previous workspace
                if (keyval == Gdk.Key.ISO_Left_Tab || keyval == Gdk.Key.Left || keyval == Gdk.Key.Up) {
                    cycle_viewed_workspace(-1);
                    return true;
                }
                // Enter, activate the currently previewed workspace and close overview
                if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                    activate_viewed_workspace();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key_controller);

            var scroll_controller = new EventControllerScroll(EventControllerScrollFlags.VERTICAL | EventControllerScrollFlags.DISCRETE);
            double scroll_accum = 0.0;
            scroll_controller.scroll.connect((dx, dy) => {
                scroll_accum += dy;
                if (scroll_accum <= -1.0) {
                    cycle_viewed_workspace(-1);
                    scroll_accum = 0.0;
                } else if (scroll_accum >= 1.0) {
                    cycle_viewed_workspace(1);
                    scroll_accum = 0.0;
                }
                return true;
            });
            ((Gtk.Widget)this).add_controller(scroll_controller);

            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("overview-window");

            anim_box = new Overlay();
            anim_box.add_css_class("workspace-overview-box");
            stage = new Singularity.Animation.MotionBin(anim_box);
            set_child(stage);
            var overlay = (Overlay)anim_box;

            // Wallpaper Background
            background_picture = new Picture();
            background_picture.content_fit = ContentFit.COVER;
            background_picture.add_css_class("overview-background-wallpaper");
            overlay.set_child(background_picture);

            var main_box = new Box(Orientation.VERTICAL, 0);
            main_box.add_css_class("overview-content-box");
            main_box.vexpand = true;
            main_box.hexpand = true;
            overlay.add_overlay(main_box);

            // Workspace Strip (Top area)
            ws_strip_container = new Box(Orientation.VERTICAL, 0);
            ws_strip_container.add_css_class("workspace-strip-container");
            ws_strip_container.vexpand = false;
            ws_strip_container.set_size_request(-1, 162);
            main_box.append(ws_strip_container);

            var ws_scroll = new ScrolledWindow();
            ws_scroll.margin_top = 32;
            ws_scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            ws_scroll.vscrollbar_policy = PolicyType.NEVER;
            ws_scroll.hexpand = true;
            ws_scroll.vexpand = false;
            ws_strip_container.append(ws_scroll);

            ws_box = new Box(Orientation.HORIZONTAL, 12);
            ws_box.halign = Align.CENTER;
            ws_box.valign = Align.CENTER;
            ws_box.hexpand = true;
            ws_box.vexpand = false;
            ws_box.margin_start = 48;
            ws_box.margin_end = 48;
            ws_scroll.set_child(ws_box);

            window_stack = new Stack();
            window_stack.vexpand = true;
            window_stack.hexpand = true;
            page_transition = Singularity.Animation.PageTransition.attach(window_stack);
            spread_bin = new Singularity.Animation.MotionBin(window_stack);
            spread_bin.vexpand = true;
            spread_bin.hexpand = true;
            main_box.append(spread_bin);

            app_system.workspaces_changed.connect(schedule_refresh_overview);

            var wp_manager = WallpaperManager.get_default();
            wp_manager.wallpaper_changed.connect(update_wallpaper);
            update_wallpaper();

            close_layer_window (this);
        }

        private void update_wallpaper() {
            var manager = WallpaperManager.get_default();
            if (manager.medium_texture != null) {
                background_picture.set_paintable(manager.medium_texture);
            }
        }

        private void stack_add_unique(Widget w, string name) {
            var existing = window_stack.get_child_by_name(name);
            if (existing != null) window_stack.remove(existing);
            window_stack.add_named(w, name);
        }

        private void cycle_viewed_workspace(int direction) {
            var workspaces = app_system.get_workspaces_for_monitor(target_monitor);
            if (workspaces.length() == 0) return;

            int current = (viewed_workspace != null) ? workspaces.index(viewed_workspace) : 0;
            int count = (int)workspaces.length();
            int next = ((current + direction) % count + count) % count;
            var ws = workspaces.nth_data(next);
            if (ws != null) set_viewed_workspace(ws);
        }

        private void activate_viewed_workspace() {
            if (viewed_workspace != null) {
                app_system.activate_workspace(viewed_workspace);
            }
            toggle();
        }

        public void set_viewed_workspace(AppSystem.Workspace ws) {
            if (this.viewed_workspace == ws) return;

            var workspaces = app_system.get_workspaces_for_monitor(target_monitor);
            int new_index = workspaces.index(ws);

            if (viewed_index != -1) {
                if (new_index > viewed_index) page_transition.forward();
                else page_transition.back();
            }

            this.viewed_workspace = ws;
            this.viewed_index = new_index;

            var spread = create_spread_widget(ws);
            string ws_id = "ws_%p".printf(ws.handle);
            stack_add_unique(spread, ws_id);
            window_stack.set_visible_child(spread);
            remove_hidden_spreads();
            update_card_selection(true);
        }

        private void remove_hidden_spreads() {
            var keep = window_stack.get_visible_child();
            Widget? child = window_stack.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                if (child != keep) window_stack.remove(child);
                child = next;
            }
        }

        private void update_card_selection(bool animate) {
            Widget? holder = ws_box.get_first_child();
            while (holder != null) {
                var bin = holder as Singularity.Animation.MotionBin;
                var card = bin != null ? bin.child as WorkspaceCard : null;
                if (card != null && card.ws != null) {
                    if (card.ws == viewed_workspace) card.add_css_class("selected");
                    else card.remove_css_class("selected");
                }
                if (bin != null) settle_card(bin, animate);
                holder = holder.get_next_sibling();
            }
        }

        private Singularity.Animation.MotionBin hold_card(WorkspaceCard card) {
            var bin = new Singularity.Animation.MotionBin(card);
            var hover = new EventControllerMotion();
            hover.enter.connect(() => {
                bin.set_data<bool>(CARD_HOVER_KEY, true);
                settle_card(bin, true);
            });
            hover.leave.connect(() => {
                bin.set_data<bool>(CARD_HOVER_KEY, false);
                settle_card(bin, true);
            });
            bin.add_controller(hover);
            return bin;
        }

        private void settle_card(Singularity.Animation.MotionBin bin, bool animate) {
            var card = bin.child as WorkspaceCard;
            if (card == null) return;
            double target = 1.0;
            if (!Singularity.Motion.reduced()) {
                if (card.has_css_class("selected")) target = CARD_SELECTED_SCALE;
                else if (bin.get_data<bool>(CARD_HOVER_KEY)) target = CARD_HOVER_SCALE;
            }
            if (animate && bin.get_mapped()) {
                Singularity.Motion.spring_to(bin, "scale", target, Singularity.Motion.Spring.SNAPPY);
            } else {
                Singularity.Motion.cancel(bin, "scale");
                bin.scale = target;
            }
        }

        private bool _refresh_pending_overview = false;
        private int _spread_seq = 0;

        private void schedule_refresh_overview() {
            // Never refresh when hidden - avoids constant SHM buffer allocation in background
            if (!visible) return;
            if (_refresh_pending_overview) return;
            _refresh_pending_overview = true;
            GLib.Idle.add(() => {
                _refresh_pending_overview = false;
                if (visible) {
                    // Full refresh while visible: rebuild the strip mini-previews
                    // and the viewed spread so a moved window shows everywhere.
                    rebuild_strip();
                    refresh_viewed_spread();
                }
                return GLib.Source.REMOVE;
            });
        }

        // Rebuild the window spread of the currently-viewed workspace so a window
        // moved to/from it (drag or SendToDesktop) shows up without reopening.
        private void refresh_viewed_spread() {
            if (viewed_workspace == null) return;
            var spread = create_spread_widget(viewed_workspace);
            string ws_id = "ws_refresh_%d".printf(_spread_seq++);
            window_stack.add_named(spread, ws_id);
            page_transition.enabled = false;
            window_stack.set_visible_child(spread);
            page_transition.enabled = true;
            remove_hidden_spreads();
            spread.opacity = 0.0;
            Singularity.Motion.tween(spread, "opacity", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
        }

        // Rebuilds only the workspace strip (WorkspaceCards). Does NOT touch the spread.
        // Called when workspace count changes or on explicit open.

        private void rebuild_strip() {
            Widget? child = ws_box.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                ws_box.remove(child);
                child = next;
            }

            var workspaces = app_system.get_workspaces_for_monitor(target_monitor);
            int index = 1;
            AppSystem.Workspace? active_ws = null;

            foreach (var ws in workspaces) {
                if (ws.active) active_ws = ws;
                var card = new WorkspaceCard(ws, index, false);
                card.set_size_request(160, 90);
                if (viewed_workspace != null && ws == viewed_workspace) {
                    card.add_css_class("selected");
                } else if (viewed_workspace == null && ws.active) {
                    card.add_css_class("selected");
                }
                var holder = hold_card(card);
                ws_box.append(holder);
                settle_card(holder, false);
                index++;
            }
            var ghost_card = new WorkspaceCard(null, index, true);
            ghost_card.set_size_request(160, 90);
            ws_box.append(hold_card(ghost_card));

            if (viewed_workspace == null || active_ws != null) {
                if (viewed_workspace == null || (active_ws != null && viewed_workspace.active)) {
                    viewed_workspace = active_ws;
                    viewed_index = workspaces.index(active_ws);
                }
            }
        }

        // Full refresh: rebuilds strip + spread. Called ONLY on explicit open (toggle).

        private void refresh() {
            rebuild_strip();
            refresh_spread();
        }

        private void refresh_spread() {
            if (viewed_workspace == null) return;

            // Current visible spread might need an internal refresh (windows changed)
            var current_spread = window_stack.get_visible_child() as Fixed;
            if (current_spread == null) {
                current_spread = create_spread_widget(viewed_workspace);
                string ws_id = "ws_%p".printf(viewed_workspace.handle);
                stack_add_unique(current_spread, ws_id);
                window_stack.set_visible_child(current_spread);
            } else {
                populate_spread_grid(current_spread, viewed_workspace);
            }
        }

        private Fixed create_spread_widget(AppSystem.Workspace ws) {
            var grid = new Fixed();
            grid.halign = Align.FILL;
            grid.valign = Align.FILL;
            grid.hexpand = true;
            grid.vexpand = true;
            populate_spread_grid(grid, ws);
            return grid;
        }

        private void populate_spread_grid(Fixed grid, AppSystem.Workspace ws) {
            Widget? child = grid.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                grid.remove(child);
                child = next;
            }

            unowned List<AppSystem.Window> windows = ws.windows;
            if (windows.length() == 0) return;

            int count = (int)windows.length();
            int cols = (int)Math.ceil(Math.sqrt(count));
            int rows = (int)Math.ceil((double)count / cols);

            int screen_w, screen_h;
            screen_size(out screen_w, out screen_h);

            int area_w = (int)(screen_w * 0.9);
            int top_reserved = 178 + 20;
            int bottom_reserved = 100;
            int available_h = screen_h - top_reserved - bottom_reserved;
            int area_h = (int)(available_h * 0.9);

            int cell_w = area_w / cols;
            int cell_h = area_h / rows;

            int i = 0;
            foreach (var win in windows) {
                int r = i / cols;
                int c = i % cols;

                var preview = new WindowPreview(win);
                int pw = cell_w - 40;
                int ph = cell_h - 40;
                preview.set_size_request(pw, ph);

                int x = (screen_w - area_w) / 2 + c * cell_w + 20;
                int y = (available_h - area_h) / 2 + r * cell_h + 20;

                grid.put(preview, x, y);
                i++;
            }
        }

        private Gdk.Monitor? target_monitor = null;

        private void screen_size(out int screen_w, out int screen_h) {
            Gdk.Monitor? monitor = target_monitor ?? GtkLayerShell.get_monitor(this);
            var display = Gdk.Display.get_default();
            if (monitor == null && display != null) {
                var surface = get_surface();
                if (surface != null) monitor = display.get_monitor_at_surface(surface);
                if (monitor == null && display.get_monitors().get_n_items() > 0)
                    monitor = display.get_monitors().get_item(0) as Gdk.Monitor;
            }
            if (monitor != null) {
                var geom = monitor.get_geometry();
                if (geom.width > 100 && geom.height > 100) {
                    screen_w = geom.width;
                    screen_h = geom.height;
                    return;
                }
            }
            screen_w = get_width() > 100 ? get_width() : 1920;
            screen_h = get_height() > 100 ? get_height() : 1080;
        }

        private void pick_monitor() {
            closing = false;
            target_monitor = pinned_monitor;
            if (target_monitor == null && app_system.workspaces_per_monitor())
                target_monitor = app_system.get_active_monitor();
            GtkLayerShell.set_monitor(this, target_monitor);
        }

        public void toggle() {
            if (visible && Singularity.DebugManager.get_default().workspaces_pinned)
                return; // dev aid: keep workspaces open for screenshots
            stop_gesture_spring();
            _gesture_active = false;
            if (visible) {
                if (closing) return;
                // Commit the workspace the user navigated to: closing the
                // overview should leave you on the selected workspace (#108).
                if (viewed_workspace != null) {
                    app_system.activate_workspace(viewed_workspace);
                }
                closing = true;
                hiding();
                animate_stage(false);
            } else {
                    pick_monitor();
                refresh();
                reset_spread_motion();
                stage.opacity = 0.0;
                stage.scale = Singularity.Motion.ENTER_SCALE;
                opacity = 1;
                present();
                update_card_selection(false);
                animate_stage(true);
                shown();
            }
        }

        private void animate_stage(bool entering) {
            var duration = Singularity.Motion.Duration.LARGE;
            uint ms = entering ? duration.ms() : duration.exit_ms();
            var curve = entering ? Singularity.Motion.Curve.ENTER : Singularity.Motion.Curve.EXIT;
            if (Singularity.Motion.reduced()) {
                Singularity.Motion.cancel(stage, "scale");
                stage.scale = 1.0;
            } else {
                Singularity.Motion.tween(stage, "scale", entering ? 1.0 : Singularity.Motion.EXIT_SCALE, ms, curve);
            }
            var fade = Singularity.Motion.tween(stage, "opacity", entering ? 1.0 : 0.0, ms, curve);
            _stage_fade = fade;
            fade.done.connect(() => {
                if (_stage_fade != fade) return;
                _stage_fade = null;
                if (!entering) finish_hide();
            });
        }

        private void finish_hide() {
            if (!closing || !visible) return;
            _stage_fade = null;
            Singularity.Motion.cancel(stage, "opacity");
            Singularity.Motion.cancel(stage, "scale");
            stage.opacity = 0.0;
            stage.reset_transform();
            reset_spread_motion();
            close_layer_window (this);
            // Free all window preview textures - they'll be re-captured on next open
            clear_overview_content();
            hidden();
        }

        private void stop_gesture_spring() {
            if (_gesture_spring == null) return;
            var spring = _gesture_spring;
            _gesture_spring = null;
            spring.reset();
        }

        private void reset_spread_motion() {
            stop_gesture_spring();
            Singularity.Motion.cancel(spread_bin, "opacity");
            spread_bin.opacity = 1.0;
            spread_bin.reset_transform();
        }

        private void clear_overview_content() {
            Widget? child = window_stack.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                window_stack.remove(child);
                child = next;
            }
            PreviewCache.get_default().clear();
            viewed_workspace = null;
            viewed_index = -1;
        }

        public void begin_gesture(bool opening) {
            if ((opening && visible) || (!opening && !visible)) return;
            closing = false;
            _stage_fade = null;
            Singularity.Motion.cancel(stage, "opacity");
            Singularity.Motion.cancel(stage, "scale");
            stage.opacity = 1.0;
            stage.reset_transform();
            reset_spread_motion();
            _gesture_active = true;
            _gesture_opening = opening;
            double start = opening ? 0.0 : 1.0;
            spread_bin.opacity = start;
            spread_bin.translate_y = (1.0 - start) * GESTURE_TRAVEL;
            var spring = new Singularity.Animation.SpringAnimation(
                spread_bin, start, start, Singularity.Motion.Spring.GENTLE);
            spring.reduced_mode = Singularity.Animation.ReducedMode.FULL;
            spring.set_sink((value) => spread_bin.translate_y = (1.0 - value) * GESTURE_TRAVEL);
            _gesture_spring = spring;
            opacity = 1;
            if (opening) {
                pick_monitor();
                refresh();
                present();
                update_card_selection(false);
                shown();
            }
            var workspaces = app_system.get_workspaces_for_monitor(target_monitor);
            _gesture_start_index = viewed_workspace != null ? workspaces.index(viewed_workspace) : -1;
            if (_gesture_start_index < 0) {
                for (int i = 0; i < (int) workspaces.length(); i++) {
                    if (workspaces.nth_data(i).active) _gesture_start_index = i;
                }
            }
            _gesture_peek_min = _gesture_peek_max = int.max(0, _gesture_start_index);
            _gesture_dx = 0;
            _gesture_times = {};
            _gesture_xs = {};
        }

        private bool two_dimensional() {
            return gesture_settings.get_boolean("gesture-two-dimensional");
        }

        private double gesture_position() {
            return int.max(0, _gesture_start_index) - _gesture_dx / 400.0;
        }

        private void follow_horizontal(double dx) {
            if (!two_dimensional() || _gesture_start_index < 0) return;
            _gesture_dx = dx;
            _gesture_times += GLib.get_monotonic_time();
            _gesture_xs += dx;
            var workspaces = app_system.get_workspaces_for_monitor(target_monitor);
            int count = (int) workspaces.length();
            if (count < 2) return;
            int index = ((int) Math.round(gesture_position())).clamp(0, count - 1);
            _gesture_peek_min = int.min(_gesture_peek_min, index);
            _gesture_peek_max = int.max(_gesture_peek_max, index);
            var ws = workspaces.nth_data(index);
            if (ws != null && ws != viewed_workspace) set_viewed_workspace(ws);
        }

        private double horizontal_velocity() {
            int n = _gesture_times.length;
            if (n < 2) return 0;
            int64 now = _gesture_times[n - 1];
            int first = n - 1;
            while (first > 0 && now - _gesture_times[first - 1] <= 150000) first--;
            if (first == n - 1) return 0;
            double ms = (now - _gesture_times[first]) / 1000.0;
            if (ms <= 0) return 0;
            return (_gesture_xs[n - 1] - _gesture_xs[first]) / ms;
        }

        private AppSystem.Workspace? gesture_target() {
            if (!two_dimensional() || _gesture_start_index < 0) return viewed_workspace;
            var workspaces = app_system.get_workspaces_for_monitor(target_monitor);
            int count = (int) workspaces.length();
            if (count < 2) return viewed_workspace;
            double position = gesture_position();
            double velocity = horizontal_velocity();
            int target;
            if (velocity <= -0.6) target = (int) Math.floor(position) + 1;
            else if (velocity >= 0.6) target = (int) Math.ceil(position) - 1;
            else target = (int) Math.round(position);
            target = target.clamp(_gesture_peek_min - 1, _gesture_peek_max + 1).clamp(0, count - 1);
            return workspaces.nth_data(target);
        }

        public void update_gesture(double dy, double dx = 0) {
            if (!_gesture_active) return;
            follow_horizontal(dx);
            double distance = Math.fabs(dy);
            double progress = double.max(0, double.min(1, distance / 240.0));
            double value = _gesture_opening ? progress : 1.0 - progress;
            if (_gesture_spring != null) _gesture_spring.track(value);
            spread_bin.translate_y = (1.0 - value) * GESTURE_TRAVEL;
            spread_bin.opacity = value;
        }

        public void end_gesture(bool committed) {
            if (!_gesture_active) return;
            _gesture_active = false;
            bool stay_open = _gesture_opening ? committed : !committed;
            double target = stay_open ? 1.0 : 0.0;
            var chosen = gesture_target();
            if (chosen != null && chosen != viewed_workspace && stay_open) set_viewed_workspace(chosen);
            if (!stay_open) {
                if (chosen != null && !chosen.active) app_system.activate_workspace(chosen);
                closing = true;
                hiding();
            }
            if (_gesture_spring != null) {
                if (Singularity.Motion.reduced()) {
                    stop_gesture_spring();
                    spread_bin.translate_y = (1.0 - target) * GESTURE_TRAVEL;
                } else {
                    _gesture_spring.release(target);
                }
            }
            var duration = Singularity.Motion.Duration.MEDIUM;
            var fade = Singularity.Motion.tween(spread_bin, "opacity", target,
                stay_open ? duration.ms() : duration.exit_ms(),
                stay_open ? Singularity.Motion.Curve.ENTER : Singularity.Motion.Curve.EXIT);
            _stage_fade = fade;
            fade.done.connect(() => {
                if (_stage_fade != fade) return;
                _stage_fade = null;
                if (!stay_open) finish_hide();
            });
        }
    }

    internal class WindowPreview : Box {
        private AppSystem.Window win;
        private Picture preview_img;
        private Label title_label;
        private DragSource drag_source;
        private Singularity.Animation.MotionBin lift;
        private bool is_destroyed = false;
        private ulong _title_signal_id = 0;
        private void* _capture_token = null;

        public WindowPreview(AppSystem.Window win) {
            Object(orientation: Orientation.VERTICAL, spacing: 8);
            this.win = win;
            this.destroy.connect(on_destroy);
            setup_ui();
        }

        private void on_destroy() {
            is_destroyed = true;
            if (_title_signal_id != 0) {
                win.disconnect(_title_signal_id);
                _title_signal_id = 0;
            }
            if (_capture_token != null) {
                void* tok = _capture_token;
                _capture_token = null;
                Singularity.wayland_cancel_capture(tok);
            }
        }

        private void setup_ui() {
            add_css_class("window-preview-item");

            var overlay = new Overlay();
            lift = new Singularity.Animation.MotionBin(overlay);
            append(lift);

            var hover = new EventControllerMotion();
            hover.enter.connect(() => settle_hover(true));
            hover.leave.connect(() => settle_hover(false));
            add_controller(hover);

            preview_img = new Picture();
            preview_img.content_fit = ContentFit.CONTAIN;
            preview_img.add_css_class("window-preview-thumbnail");
            overlay.set_child(preview_img);

            // Title bar at the bottom
            var title_bar = new Box(Orientation.HORIZONTAL, 6);
            title_bar.add_css_class("window-preview-titlebar");
            title_bar.valign = Align.END;
            title_bar.halign = Align.CENTER;
            title_bar.margin_bottom = 12;
            title_bar.margin_start = 12;
            title_bar.margin_end = 12;
            overlay.add_overlay(title_bar);

            var icon_img = new Image();
            if (win.gicon != null) icon_img.set_from_gicon(win.gicon);
            else icon_img.set_from_icon_name(win.icon_name);
            icon_img.pixel_size = 24;
            icon_img.add_css_class("window-preview-icon");
            title_bar.append(icon_img);

            title_label = new Label(win.title != null ? win.title : win.app_id);
            title_label.add_css_class("window-preview-label");
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.halign = Align.START;
            title_label.hexpand = true;
            title_bar.append(title_label);

            _title_signal_id = win.notify["title"].connect(on_title_changed);

            if (win.handle != null) {
                Singularity.PreviewCache.get_default().request(win.handle, 480, 320, (texture) => {
                    if (is_destroyed || texture == null) return;
                    preview_img.set_paintable(texture);
                });
            }

            var click = new GestureClick();
            click.button = 0;
            click.released.connect((n, x, y) => {
                if (click.get_current_button() == Gdk.BUTTON_MIDDLE) {
                    close_preview();
                    return;
                }
                if (click.get_current_button() != Gdk.BUTTON_PRIMARY) return;
                on_preview_clicked(n, x, y);
            });
            add_controller(click);

            drag_source = new DragSource();
            drag_source.set_actions(Gdk.DragAction.MOVE);
            drag_source.prepare.connect(on_drag_prepare);
            drag_source.drag_begin.connect(on_drag_begin);
            add_controller(drag_source);
        }

        private void settle_hover(bool hovered) {
            if (!sensitive) return;
            double target = hovered && !Singularity.Motion.reduced() ? 1.02 : 1.0;
            Singularity.Motion.spring_to(lift, "scale", target, Singularity.Motion.Spring.SNAPPY);
        }

        private void close_preview() {
            if (win.handle == null) return;
            sensitive = false;
            var duration = Singularity.Motion.Duration.SMALL;
            if (!Singularity.Motion.reduced()) {
                Singularity.Motion.tween(lift, "scale", 0.94, duration.ms(), Singularity.Motion.Curve.EXIT);
            }
            Singularity.Motion.tween(lift, "opacity", 0.35, duration.ms(), Singularity.Motion.Curve.EXIT);
            Singularity.close_window(win.handle);
        }

        private void on_preview_clicked(int n_press, double x, double y) {
            var root = get_root() as WorkspaceOverview;
            if (root != null) root.toggle();
            Singularity.wayland_activate_window(win.handle);
        }

        private void on_title_changed() {
            if (is_destroyed) return;
            title_label.label = win.title != null ? win.title : win.app_id;
        }

        private Gdk.ContentProvider? on_drag_prepare(double x, double y) {
            ulong handle_val = (ulong)win.handle;
            return new ContentProvider.for_value(handle_val.to_string());
        }

        private void on_drag_begin(Gdk.Drag drag) {
            if (preview_img.paintable != null) {
                var paintable = preview_img.paintable;
                int pw = (int)paintable.get_intrinsic_width();
                int ph = (int)paintable.get_intrinsic_height();
                if (pw <= 0 || ph <= 0) {
                    drag_source.set_icon(paintable, 0, 0);
                    return;
                }
                double scale = double.min(128.0 / pw, 128.0 / ph);
                if (scale >= 1.0) {
                    drag_source.set_icon(paintable, pw / 2, ph / 2);
                    return;
                }
                int sw = (int)(pw * scale);
                int sh = (int)(ph * scale);
                var renderer = get_native().get_renderer();
                if (renderer == null) return;
                var snapshot = new Gtk.Snapshot();
                snapshot.append_scaled_texture((Gdk.Texture)paintable, Gsk.ScalingFilter.LINEAR, { { 0, 0 }, { sw, sh } });
                var root_node = snapshot.to_node();
                if (root_node == null) return;
                try {
                    var tex = renderer.render_texture(root_node, { { 0, 0 }, { sw, sh } });
                    drag_source.set_icon(tex, sw / 2, sh / 2);
                } catch (Error e) {
                    drag_source.set_icon(paintable, pw / 2, ph / 2);
                }
            }
        }
    }
}
