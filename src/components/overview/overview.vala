using Gtk;
using GtkLayerShell;
using GLib;
using Gdk;
using Math;

namespace Singularity {

    public class Overview : Gtk.Window {
        private AppLauncherGrid launcher_grid;
        private ScrolledWindow scrolled_window;
        private Singularity.Widgets.SearchEntry search_entry;
        private AppSystem app_system;
        private SearchManager search_manager;
        private ListBox search_results_list;
        private Stack content_stack;
        private ScrolledWindow results_scrolled;
        private Gtk.Window? anchor_window;
        private Box main_box;
        private Singularity.Animation.MotionBin stage;
        private GLib.Settings desktop_settings;
        private Singularity.Animation.TimedAnimation? _stage_fade = null;
        private Singularity.Animation.SpringAnimation? _gesture_spring = null;
        private bool _closing = false;
        private uint _hide_guard = 0;
        private const double GESTURE_TRAVEL = 72.0;
        private bool _gesture_active = false;
        private bool _gesture_opening = false;

        public bool showing { get; private set; default = false; }

        // True when the keyboard focus is on something the user is typing
        // into (Entry, TextView, etc.) - used to suppress the
        // "redirect to search bar" behavior so notes / calculator widgets
        // stay usable while the overview is open.
        private bool is_editable_focused() {
            Gtk.Widget? f = get_focus();
            if (f == null) return false;
            if (f == search_entry || f.is_ancestor(search_entry)) return false;
            return (f is Gtk.Editable) || (f is Gtk.TextView);
        }
        private bool is_showing = false;
        private int64 last_toggle_time = 0;

        public signal void shown();
        public signal void hidden();
        public signal void hiding();

        public Overview(Gtk.Application app, Gtk.Window? anchor = null) {
            Object(application: app);
            anchor_window = anchor;
            app_system = AppSystem.get_default();
            search_manager = SearchManager.get_default();

            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);

            var key_controller = new EventControllerKey();
            key_controller.set_propagation_phase(PropagationPhase.CAPTURE);
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    toggle();
                    return true;
                }

                bool is_arrow = (keyval == Gdk.Key.Up   || keyval == Gdk.Key.Down ||
                                 keyval == Gdk.Key.Left || keyval == Gdk.Key.Right);

                // Arrow keys when search is empty, navigate the launcher grid.
                if (is_arrow && search_entry.text.strip() == "") {
                    if (search_entry.has_focus) {
                        launcher_grid.grab_focus();
                    }
                    return false;
                }

                // Up/Down while searching: navigate the results list.
                if ((keyval == Gdk.Key.Up || keyval == Gdk.Key.Down) &&
                    search_entry.text.strip() != "") {
                    var selected = search_results_list.get_selected_row();
                    if (selected == null) {
                        var first = search_results_list.get_row_at_index(0);
                        if (first != null) search_results_list.select_row(first);
                    } else {
                        int idx = selected.get_index();
                        if (keyval == Gdk.Key.Down) {
                            var next = search_results_list.get_row_at_index(idx + 1);
                            if (next != null) search_results_list.select_row(next);
                        } else if (idx > 0) {
                            var prev = search_results_list.get_row_at_index(idx - 1);
                            if (prev != null) search_results_list.select_row(prev);
                        }
                    }
                    return true;
                }

                if ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) &&
                    search_entry.text.strip() != "") {
                    var row = search_results_list.get_selected_row();
                    if (row == null) row = search_results_list.get_row_at_index(0);
                    var res_row = row as SearchResultRow;
                    if (res_row != null) {
                        res_row.result.activate();
                        if (!res_row.result.keeps_open) toggle();
                    }
                    return true;
                }

                // Printable characters (non-nav), redirect to search entry -
                // BUT only when the focus is on a non-editable widget. If
                // the user is typing inside an overview widget (notes
                // textview, calculator input, etc.) we must NOT steal
                // their keystrokes.
                unichar unicode = Gdk.keyval_to_unicode(keyval);
                if (unicode != 0 &&
                    keyval != Gdk.Key.Return &&
                    keyval != Gdk.Key.KP_Enter &&
                    keyval != Gdk.Key.Tab &&
                    !is_arrow &&
                    !is_editable_focused()) {
                    if (!search_entry.has_focus) {
                        search_entry.grab_focus();
                    }
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key_controller);

            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("overview-window");

            main_box = new Box(Orientation.VERTICAL, 0);
            main_box.add_css_class("overview-box");
            main_box.vexpand = true;
            main_box.hexpand = true;
            stage = new Singularity.Animation.MotionBin(main_box);
            set_child(stage);
            desktop_settings = new GLib.Settings("dev.sinty.desktop");

            search_entry = new Singularity.Widgets.SearchEntry();
            search_entry.placeholder_text = _("Type to search");
            search_entry.width_request = 400;
            search_entry.halign = Align.CENTER;
            search_entry.hexpand = false;
            search_entry.margin_top = 48;
            search_entry.margin_bottom = 12;
            search_entry.search_changed.connect(on_search_changed);
            main_box.append(search_entry);

            content_stack = new Stack();
            content_stack.transition_type = StackTransitionType.CROSSFADE;
            content_stack.hexpand = true;
            content_stack.vexpand = true;
            main_box.append(content_stack);

            // App Grid View
            scrolled_window = new ScrolledWindow();
            scrolled_window.hscrollbar_policy = PolicyType.NEVER;
            scrolled_window.vscrollbar_policy = PolicyType.AUTOMATIC;
            scrolled_window.overlay_scrolling = false;
            content_stack.add_named(scrolled_window, "grid");

            var grid_container = new Box(Orientation.VERTICAL, 0);
            grid_container.margin_top = 40;
            grid_container.margin_bottom = 100;
            grid_container.margin_start = 12;
            grid_container.margin_end = 12;
            scrolled_window.set_child(grid_container);

            launcher_grid = new AppLauncherGrid(app, 64, 8, 16);
            launcher_grid.column_slot = 232;
            launcher_grid.on_app_launched = () => { toggle(); };
            grid_container.append(launcher_grid);

            // Right-click on empty grid area -> Add widget…
            var grid_rc = new GestureClick();
            grid_rc.button = Gdk.BUTTON_SECONDARY;
            grid_rc.pressed.connect((n, x, y) => {
                // Only popup if no child consumed the event (i.e. right-click
                // on background). The app/widget right-clicks claim the
                // sequence, so we get here only on empty area.
                launcher_grid.show_widget_picker(launcher_grid, x, y);
            });
            launcher_grid.add_controller(grid_rc);

            // Search Results View
            var search_view_box = new Box(Orientation.VERTICAL, 0);
            search_view_box.vexpand = true;
            content_stack.add_named(search_view_box, "search");

            results_scrolled = new ScrolledWindow();
            results_scrolled.hscrollbar_policy = PolicyType.NEVER;
            results_scrolled.vscrollbar_policy = PolicyType.AUTOMATIC;
            results_scrolled.width_request = 640;
            results_scrolled.hexpand = true;
            results_scrolled.vexpand = true;
            results_scrolled.halign = Align.CENTER;
            search_view_box.append(results_scrolled);

            var list_container = new Box(Orientation.VERTICAL, 0);
            list_container.margin_top = 20;
            list_container.margin_bottom = 100;
            results_scrolled.set_child(list_container);

            search_results_list = new ListBox();
            search_results_list.add_css_class("search-results-list");
            search_results_list.selection_mode = SelectionMode.SINGLE;
            list_container.append(search_results_list);

            search_results_list.row_selected.connect((row) => {
                // Hide preview on previously selected row
                Widget? child = search_results_list.get_first_child();
                while (child != null) {
                    var r = child as SearchResultRow;
                    if (r != null && r != row) r.hide_preview_keyboard();
                    child = child.get_next_sibling();
                }
                // Show preview on newly selected row
                var res_row = row as SearchResultRow;
                if (res_row != null) res_row.show_preview_keyboard();
            });

            search_results_list.row_activated.connect((row) => {
                var res_row = row as SearchResultRow;
                if (res_row != null) {
                    res_row.result.activate();
                    if (!res_row.result.keeps_open) toggle();
                }
            });

            search_manager.results_updated.connect(update_search_results);
        }

        private void update_search_results(List<SearchResult> results) {
            Widget? child = search_results_list.get_first_child();
            while (child != null) {
                search_results_list.remove(child);
                child = search_results_list.get_first_child();
            }

            foreach (var res in results) {
                var row = new SearchResultRow(res);
                row.request_close.connect(() => toggle());
                search_results_list.append(row);
            }

            // Category separator headers between different providers
            search_results_list.set_header_func((row, before) => {
                var res_row = row as SearchResultRow;
                if (res_row == null) return;
                bool needs_header = false;
                if (before == null) {
                    needs_header = true;
                } else {
                    var before_row = before as SearchResultRow;
                    if (before_row != null &&
                        before_row.result.provider.id != res_row.result.provider.id) {
                        needs_header = true;
                    }
                }
                if (needs_header) {
                    var lbl = new Label(res_row.result.provider.name.up());
                    lbl.add_css_class("search-category-header");
                    lbl.halign = Align.START;
                    row.set_header(lbl);
                } else {
                    row.set_header(null);
                }
            });

            var first = search_results_list.get_row_at_index(0);
            if (first != null) {
                search_results_list.select_row(first);
            }
        }

        private uint _search_debounce = 0;

        private void on_search_changed(Singularity.Widgets.SearchEntry entry) {
            string query = entry.text.strip();
            if (_search_debounce != 0) { GLib.Source.remove(_search_debounce); _search_debounce = 0; }
            if (query == "") {
                content_stack.visible_child_name = "grid";
                return;
            }
            content_stack.visible_child_name = "search";
            // Debounce so we don't fire a query (and spin up providers) on
            // every keystroke.
            _search_debounce = GLib.Timeout.add(160, () => {
                _search_debounce = 0;
                search_manager.query.begin(query);
                return GLib.Source.REMOVE;
            });
        }

        public void toggle() {
            int64 now = GLib.get_monotonic_time();
            if (now - last_toggle_time < 150000) return;
            last_toggle_time = now;
            _gesture_active = false;
            // Dev aid: keep the overview open for screenshots. The toggle to
            // close is suppressed while pinned (turn it off in Developer
            // settings to dismiss).
            if (is_showing && Singularity.DebugManager.get_default().overview_pinned)
                return;
            if (is_showing) {
                is_showing = false;
                showing = false;
                set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
                hiding();
                // A folder overlay is a separate toplevel layer window, so it
                // does not go away with the launcher. Dismiss it here, next to
                // hiding(), so the overlay and the launcher leave together
                // instead of the overlay fading alone over the desktop.
                launcher_grid.close_folder_overlays();
                begin_hide();
                animate_stage(false);
            } else {
                bool reopening = _closing;
                cancel_hide();
                stop_gesture_spring();
                stage.translate_y = 0;
                if (!reopening) {
                    stage.opacity = 0.0;
                    stage.scale = Singularity.Motion.ENTER_SCALE;
                }
                is_showing = true;
                showing = true;
                search_entry.text = "";
                content_stack.visible_child_name = "grid";
                set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
                // Pin overview to same monitor as panel (anchor_window)
                if (anchor_window != null) {
                    var surface = anchor_window.get_surface();
                    if (surface != null) {
                        var monitor = surface.get_display().get_monitor_at_surface(surface);
                        if (monitor != null) set_monitor(this, monitor);
                    }
                    int panel_h = anchor_window.get_height();
                    if (panel_h > 0) {
                        search_entry.margin_top = panel_h + 12;
                    }
                }
                update_grid_columns();

                set_layer(this, GtkLayerShell.Layer.TOP);
                present();
                // Populate AFTER present so the empty overview (background +
                // search bar) paints immediately; the grid then streams in
                // incrementally instead of blocking the first frame.
                GLib.Idle.add(() => {
                    if (!is_showing) return GLib.Source.REMOVE;
                    if (!launcher_grid.is_populated()) launcher_grid.populate(true);
                    return GLib.Source.REMOVE;
                });
                if (!reopening) launcher_grid.play_reveal();
                animate_stage(true);
                // Focus search entry so the user can type immediately;
                // arrow keys still navigate the grid (see key_pressed handler).
                search_entry.grab_focus();
                shown();
            }
        }

        public void prebuild() {
            if (is_showing) return;
            update_grid_columns();
            if (!launcher_grid.is_populated()) launcher_grid.populate();
        }

        private void update_grid_columns() {
            Gdk.Monitor? grid_mon = GtkLayerShell.get_monitor(this);
            if (grid_mon == null) {
                var d = Gdk.Display.get_default();
                if (d != null && d.get_monitors().get_n_items() > 0)
                    grid_mon = d.get_monitors().get_item(0) as Gdk.Monitor;
            }
            if (grid_mon == null) return;
            Gdk.Rectangle gg = grid_mon.get_geometry();
            int avail = gg.width - 48;
            string dock_pos = desktop_settings.get_string("dock-position");
            if ((dock_pos == "left" || dock_pos == "right")
                    && !desktop_settings.get_boolean("dock-autohide")) {
                int isz = desktop_settings.get_int("dock-icon-size");
                if (isz <= 0) isz = 48;
                avail -= isz + desktop_settings.get_int("dock-gap") + 28;
            }
            launcher_grid.set_columns_for_width(avail);
            launcher_grid.viewport_hint = gg.height;
        }

        private void animate_stage(bool entering) {
            var duration = Singularity.Motion.Duration.LARGE;
            uint ms = entering ? duration.ms() : duration.exit_ms();
            var curve = entering ? Singularity.Motion.Curve.ENTER : Singularity.Motion.Curve.EXIT;
            double scale = entering ? 1.0 : Singularity.Motion.EXIT_SCALE;
            Singularity.Motion.tween(stage, "scale", scale, ms, curve);
            var fade = Singularity.Motion.tween(stage, "opacity", entering ? 1.0 : 0.0, ms, curve);
            _stage_fade = fade;
            fade.done.connect(() => {
                if (_stage_fade != fade) return;
                _stage_fade = null;
                if (!entering) finish_hide();
            });
        }

        private void stop_gesture_spring() {
            if (_gesture_spring == null) return;
            var spring = _gesture_spring;
            _gesture_spring = null;
            spring.reset();
        }

        private void begin_hide() {
            _closing = true;
            if (_hide_guard != 0) GLib.Source.remove(_hide_guard);
            uint watchdog = Singularity.Motion.get_default().scale(
                Singularity.Motion.Duration.SCENE.ms()) + 500;
            _hide_guard = GLib.Timeout.add(watchdog, () => {
                _hide_guard = 0;
                finish_hide();
                return GLib.Source.REMOVE;
            });
        }

        private void cancel_hide() {
            _closing = false;
            if (_hide_guard != 0) {
                GLib.Source.remove(_hide_guard);
                _hide_guard = 0;
            }
        }

        private void finish_hide() {
            if (!_closing) return;
            cancel_hide();
            _stage_fade = null;
            Singularity.Motion.cancel(stage, "opacity");
            Singularity.Motion.cancel(stage, "scale");
            stop_gesture_spring();
            stage.opacity = 0.0;
            stage.reset_transform();
            launcher_grid.close_folder_overlays();
            close_layer_window (this);
            PreviewCache.get_default().clear();
            hidden();
            Singularity.trim_heap();
        }

        public void begin_gesture(bool opening) {
            if (!opening && !is_showing) return;
            if (!opening && Singularity.DebugManager.get_default().overview_pinned) return;
            if (opening) {
                if (!is_showing) toggle();
                if (!is_showing) return;
            }
            cancel_hide();
            _stage_fade = null;
            Singularity.Motion.cancel(stage, "opacity");
            Singularity.Motion.cancel(stage, "scale");
            stop_gesture_spring();
            _gesture_active = true;
            _gesture_opening = opening;
            double start = opening ? 0.0 : 1.0;
            stage.scale = 1.0;
            stage.opacity = start;
            stage.translate_y = (1.0 - start) * GESTURE_TRAVEL;
            var spring = new Singularity.Animation.SpringAnimation(
                stage, start, start, Singularity.Motion.Spring.GENTLE);
            spring.reduced_mode = Singularity.Animation.ReducedMode.FULL;
            spring.set_sink((value) => stage.translate_y = (1.0 - value) * GESTURE_TRAVEL);
            _gesture_spring = spring;
        }

        public void update_gesture(double dy) {
            if (!_gesture_active || _gesture_spring == null) return;
            double distance = Math.fabs(dy);
            double progress = double.max(0, double.min(1, distance / 240.0));
            double value = _gesture_opening ? progress : 1.0 - progress;
            _gesture_spring.track(value);
            stage.translate_y = (1.0 - value) * GESTURE_TRAVEL;
            stage.opacity = value;
        }

        public void end_gesture(bool committed) {
            if (!_gesture_active) return;
            _gesture_active = false;
            bool stay_open = _gesture_opening ? committed : !committed;
            if (stay_open) {
                is_showing = true;
                showing = true;
                set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
                search_entry.grab_focus();
            } else {
                is_showing = false;
                showing = false;
                set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
                hiding();
                launcher_grid.close_folder_overlays();
                begin_hide();
            }
            double target = stay_open ? 1.0 : 0.0;
            if (_gesture_spring != null) _gesture_spring.release(target);
            var duration = Singularity.Motion.Duration.MEDIUM;
            var fade = Singularity.Motion.tween(stage, "opacity", target,
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

    internal class WorkspaceCard : Gtk.Box {
        public Singularity.AppSystem.Workspace? ws { get; construct; }
        public bool is_ghost { get; construct; }
        public int index { get; construct; }
        private AppSystem app_system;
        private Picture background_picture;
        private Overlay overlay;
        private ScrolledWindow clipper;
        private Box content_container;
        private GLib.List<void*> _capture_tokens = new GLib.List<void*>();

        public WorkspaceCard(Singularity.AppSystem.Workspace? ws, int index, bool is_ghost = false) {
            Object(ws: ws, index: index, is_ghost: is_ghost);
            this.app_system = AppSystem.get_default();
            this.destroy.connect(on_wsc_destroy);
            setup_ui();
        }

        private void on_wsc_destroy() {
            cancel_captures();
        }

        private void cancel_captures() {
            var tokens = (owned)_capture_tokens;
            _capture_tokens = new GLib.List<void*>();
            foreach (void* token in tokens) {
                Singularity.wayland_cancel_capture(token);
            }
        }

        private void setup_ui() {
            add_css_class("workspace-preview");

            if (this.is_ghost) {
                add_css_class("ghost-workspace");
            } else {
                if (this.ws != null && this.ws.active) add_css_class("active");
            }

            this.overflow = Overflow.VISIBLE;
            valign = Align.CENTER;
            hexpand = true;
            vexpand = true;

            clipper = new ScrolledWindow();
            clipper.hscrollbar_policy = PolicyType.NEVER;
            clipper.vscrollbar_policy = PolicyType.NEVER;
            clipper.has_frame = false;
            clipper.hexpand = true;
            clipper.vexpand = true;
            clipper.add_css_class("workspace-clipper");
            append(clipper);

            overlay = new Overlay();
            clipper.set_child(overlay);

            background_picture = new Picture();
            background_picture.add_css_class("workspace-background");
            background_picture.content_fit = ContentFit.COVER;
            background_picture.can_shrink = true;
            overlay.set_child(background_picture);
            update_background();

            content_container = new Box(Orientation.VERTICAL, 0);
            content_container.add_css_class("workspace-preview-content");
            content_container.hexpand = true;
            content_container.vexpand = true;
            content_container.halign = Align.FILL;
            content_container.valign = Align.FILL;
            overlay.add_overlay(content_container);

            if (!this.is_ghost) {
                var label_box = new Box(Orientation.HORIZONTAL, 0);
                label_box.add_css_class("workspace-card-label-box");
                label_box.halign = Align.START;
                label_box.valign = Align.START;
                label_box.margin_start = 8;
                label_box.margin_top = 6;

                var card_label = new Label(this.ws != null ? this.ws.name : index.to_string());
                card_label.add_css_class("workspace-card-label");
                label_box.append(card_label);
                overlay.add_overlay(label_box);
            }

            if (this.is_ghost) {
                var plus_img = new Image.from_icon_name("list-add-symbolic");
                plus_img.pixel_size = 32;
                plus_img.halign = Align.CENTER;
                plus_img.valign = Align.CENTER;
                plus_img.hexpand = true;
                plus_img.vexpand = true;
                content_container.append(plus_img);
                background_picture.visible = false;
            } else if (!this.is_ghost) {
                update_icons();
            }

            var click_controller = new GestureClick();
            click_controller.released.connect(on_card_clicked);
            add_controller(click_controller);
            var drop_target = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop_target.enter.connect(on_drag_enter);
            drop_target.leave.connect(on_drag_leave);
            drop_target.drop.connect(on_drop);
            add_controller(drop_target);
        }

        private void update_icons() {
            if (content_container == null) return;
            Widget child = content_container.get_first_child();
            while (child != null) {
                content_container.remove(child);
                child = content_container.get_first_child();
            }

            if (this.ws == null) return;

            var layout = new Fixed();
            content_container.append(layout);

            int win_count = (int)this.ws.windows.length();
            if (win_count == 0) return;

            int cols = (int)Math.ceil(Math.sqrt(win_count));
            int rows = (int)Math.ceil((double)win_count / cols);

            int card_w = get_width() > 0 ? get_width() : 160;
            int card_h = get_height() > 0 ? get_height() : 90;
            int padding = 4;

            int win_w = (card_w - (cols + 1) * padding) / cols;
            int win_h = (card_h - (rows + 1) * padding) / rows;

            int i = 0;
            foreach (var win in this.ws.windows) {
                if (i >= 12) break;
                int r = i / cols;
                int c = i % cols;

                var win_box = new Box(Orientation.VERTICAL, 0);
                win_box.add_css_class("workspace-window-preview");
                win_box.set_size_request(win_w, win_h);

                var overlay = new Overlay();
                win_box.append(overlay);

                var preview_img = new Picture();
                preview_img.content_fit = ContentFit.COVER;
                overlay.set_child(preview_img);

                var icon_img = new Image();
                if (win.gicon != null) icon_img.set_from_gicon(win.gicon);
                else icon_img.set_from_icon_name(win.icon_name);
                icon_img.pixel_size = (int)fmin(24, win_h / 2);
                icon_img.halign = Align.CENTER;
                icon_img.valign = Align.CENTER;
                overlay.add_overlay(icon_img);

                Singularity.PreviewCache.get_default().request(win.handle, win_w, win_h, (texture) => {
                    if (texture == null) return;
                    preview_img.set_paintable(texture);
                    icon_img.opacity = 0.5;
                });

                layout.put(win_box, c * (win_w + padding) + padding, r * (win_h + padding) + padding);
                i++;
            }
        }

        public void update_background() {
            var manager = WallpaperManager.get_default();
            if (manager.preview_texture != null) {
                background_picture.set_paintable(manager.preview_texture);
            }
        }

        private void on_card_clicked(int n_press, double x, double y) {
            var root = get_root();
            if (root is Singularity.WorkspaceOverview) {
                var ws_ov = (Singularity.WorkspaceOverview)root;
                if (this.ws != null) {
                    if (n_press == 1) {
                        ws_ov.set_viewed_workspace(this.ws);
                    } else if (n_press >= 2) {
                        app_system.activate_workspace(this.ws);
                        ws_ov.toggle();
                    }
                } else if (this.is_ghost) {
                    AppSystem.activate_next_created_workspace = true;
                    app_system.create_workspace("%d".printf(this.index));
                }
            } else {
                if (this.ws != null) {
                    app_system.activate_workspace(this.ws);
                } else if (this.is_ghost) {
                    AppSystem.activate_next_created_workspace = true;
                    app_system.create_workspace("%d".printf(this.index));
                }
                if (root is Singularity.Overview) {
                    ((Singularity.Overview)root).toggle();
                }
            }
        }

        private Gdk.DragAction on_drag_enter(double x, double y) {
            add_css_class("drag-over");
            return Gdk.DragAction.MOVE;
        }

        private void on_drag_leave() {
            remove_css_class("drag-over");
        }

        private bool on_drop(GLib.Value value, double x, double y) {
            remove_css_class("drag-over");
            string text = (string)value;
            ulong handle_val = ulong.parse(text);
            void* handle = (void*)handle_val;
            Singularity.AppSystem.Window? target_win = app_system.get_window_by_handle(handle);
            if (target_win != null) {
                if (this.ws != null) {
                    app_system.move_window_to_workspace(target_win, this.ws);
                } else if (this.is_ghost) {
                    AppSystem.window_to_move_to_new_workspace = target_win;
                    AppSystem.activate_next_created_workspace = true;
                    app_system.create_workspace("%d".printf(this.index + 1));
                }
            }
            return true;
        }
    }
}
