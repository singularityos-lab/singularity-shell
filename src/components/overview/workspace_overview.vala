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
        private uint _anim_out_timer = 0;
        private Singularity.Animation.TimedAnimation? _gesture_animation = null;
        private bool _gesture_active = false;
        private bool _gesture_opening = false;
        private AppSystem.Workspace? viewed_workspace = null;
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
            set_child(anim_box);
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

            // Window Stack (Middle area - Animated transition between spreads)
            window_stack = new Stack();
            window_stack.transition_type = StackTransitionType.SLIDE_LEFT_RIGHT;
            window_stack.transition_duration = 400;
            window_stack.vexpand = true;
            window_stack.hexpand = true;
            main_box.append(window_stack);

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
            var transition = StackTransitionType.CROSSFADE;

            if (viewed_index != -1) {
                transition = (new_index > viewed_index) ? StackTransitionType.SLIDE_LEFT : StackTransitionType.SLIDE_RIGHT;
            }

            this.viewed_workspace = ws;
            this.viewed_index = new_index;

            // Create and switch to new spread
            var spread = create_spread_widget(ws);
            string ws_id = "ws_%p".printf(ws.handle);
            stack_add_unique(spread, ws_id);
            window_stack.set_visible_child_full(ws_id, transition);

            // Clean up old spreads after a delay. Coalesce into a single timer
            // and keep whatever is CURRENTLY visible (not the spread captured
            // when this timer was scheduled): scrolling fast queued several
            // timers, and an older one removed the newest spread, blanking the
            // whole overview until you scrolled back and forth (#48).
            if (_spread_cleanup_id != 0) {
                GLib.Source.remove(_spread_cleanup_id);
                _spread_cleanup_id = 0;
            }
            _spread_cleanup_id = Timeout.add(600, () => {
                _spread_cleanup_id = 0;
                var keep = window_stack.get_visible_child();
                Widget? child = window_stack.get_first_child();
                while (child != null) {
                    Widget next = child.get_next_sibling();
                    if (child != keep) {
                        window_stack.remove(child);
                    }
                    child = next;
                }
                return Source.REMOVE;
            });

            // Update card selection visually
            Widget? card_child = ws_box.get_first_child();
            while (card_child != null) {
                if (card_child is WorkspaceCard) {
                    var card = (WorkspaceCard)card_child;
                    if (card.ws == ws) card.add_css_class("selected");
                    else card.remove_css_class("selected");
                }
                card_child = card_child.get_next_sibling();
            }
        }

        private bool _refresh_pending_overview = false;
        private int _spread_seq = 0;
        private uint _spread_cleanup_id = 0;

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
            window_stack.set_visible_child_full(ws_id, StackTransitionType.CROSSFADE);
            Timeout.add(600, () => {
                Widget? child = window_stack.get_first_child();
                while (child != null) {
                    Widget next = child.get_next_sibling();
                    if (child != spread) window_stack.remove(child);
                    child = next;
                }
                return Source.REMOVE;
            });
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
                ws_box.append(card);
                index++;
            }
            var ghost_card = new WorkspaceCard(null, index, true);
            ghost_card.set_size_request(160, 90);
            ws_box.append(ghost_card);

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

            int screen_w = get_width() > 100 ? get_width() : 1920;
            int screen_h = get_height() > 100 ? get_height() : 1080;
            // Try to get actual monitor dimensions if window size not yet available
            if (screen_w == 1920 || screen_h == 1080) {
                var surface = get_surface();
                if (surface != null) {
                    var display = Gdk.Display.get_default();
                    if (display != null) {
                        var monitor = display.get_monitor_at_surface(surface);
                        if (monitor != null) {
                            var geom = monitor.get_geometry();
                            if (geom.width > 100) screen_w = geom.width;
                            if (geom.height > 100) screen_h = geom.height;
                        }
                    }
                }
            }

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
            if (_gesture_animation != null) {
                _gesture_animation.reset();
                _gesture_animation = null;
            }
            _gesture_active = false;
            if (visible) {
                // Commit the workspace the user navigated to: closing the
                // overview should leave you on the selected workspace (#108).
                if (viewed_workspace != null) {
                    app_system.activate_workspace(viewed_workspace);
                }
                if (_anim_out_timer != 0) {
                    GLib.Source.remove(_anim_out_timer);
                    _anim_out_timer = 0;
                }
                anim_box.remove_css_class("animating-in");
                anim_box.add_css_class("animating-out");
                closing = true;
                hiding();
                _anim_out_timer = GLib.Timeout.add(180, () => {
                    _anim_out_timer = 0;
                    opacity = 0;
                    anim_box.remove_css_class("animating-out");
                    close_layer_window (this);
                    // Free all window preview textures - they'll be re-captured on next open
                    clear_overview_content();
                    hidden();
                    return GLib.Source.REMOVE;
                });
            } else {
                pick_monitor();
                refresh();
                if (_anim_out_timer != 0) {
                    GLib.Source.remove(_anim_out_timer);
                    _anim_out_timer = 0;
                    anim_box.remove_css_class("animating-out");
                }
                anim_box.remove_css_class("animating-out");
                anim_box.add_css_class("animating-in");
                opacity = 1;
                GLib.Timeout.add(220, () => {
                    anim_box.remove_css_class("animating-in");
                    return GLib.Source.REMOVE;
                });
                present();
                shown();
            }
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
            if (_gesture_animation != null) {
                _gesture_animation.reset();
                _gesture_animation = null;
            }
            if (_anim_out_timer != 0) {
                GLib.Source.remove(_anim_out_timer);
                _anim_out_timer = 0;
            }
            anim_box.remove_css_class("animating-in");
            anim_box.remove_css_class("animating-out");
            _gesture_active = true;
            _gesture_opening = opening;
            window_stack.opacity = 1;
            window_stack.margin_top = 0;
            if (opening) {
                pick_monitor();
                refresh();
                present();
                shown();
            } else {
                opacity = 1;
            }
        }

        public void update_gesture(double dy) {
            if (!_gesture_active) return;
            double distance = Math.fabs(dy);
            double progress = double.max(0, double.min(1, distance / 240.0));
            double value = _gesture_opening ? progress : 1.0 - progress;
            window_stack.opacity = value;
            window_stack.margin_top = (int)Math.round((1.0 - value) * 72.0);
        }

        public void end_gesture(bool committed) {
            if (!_gesture_active) return;
            _gesture_active = false;
            bool stay_open = _gesture_opening ? committed : !committed;
            double target = stay_open ? 1.0 : 0.0;
            if (!stay_open) {
                closing = true;
                hiding();
            }
            double current = window_stack.opacity;
            if (!Gtk.Settings.get_default().gtk_enable_animations
                    || Math.fabs(current - target) < 0.001) {
                window_stack.opacity = target;
                window_stack.margin_top = 0;
                if (!stay_open) {
                    close_layer_window (this);
                    clear_overview_content();
                    hidden();
                }
                return;
            }
            uint duration = (uint)double.max(80,
                180.0 * Math.fabs(target - current));
            var animation = new Singularity.Animation.TimedAnimation(
                this, current, target, duration,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
            _gesture_animation = animation;
            animation.tick.connect(() => {
                window_stack.opacity = animation.value;
                window_stack.margin_top = (int)Math.round((1.0 - animation.value) * 72.0);
            });
            animation.done.connect(() => {
                window_stack.opacity = target;
                window_stack.margin_top = 0;
                if (_gesture_animation == animation) _gesture_animation = null;
                if (!stay_open) {
                    close_layer_window (this);
                    clear_overview_content();
                    hidden();
                }
            });
            animation.play();
        }
    }

    internal class WindowPreview : Box {
        private AppSystem.Window win;
        private Picture preview_img;
        private Label title_label;
        private DragSource drag_source;
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
            append(overlay);

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
            click.released.connect(on_preview_clicked);
            add_controller(click);

            drag_source = new DragSource();
            drag_source.set_actions(Gdk.DragAction.MOVE);
            drag_source.prepare.connect(on_drag_prepare);
            drag_source.drag_begin.connect(on_drag_begin);
            add_controller(drag_source);
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
