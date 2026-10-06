using Gtk;
using GtkLayerShell;
using GLib;
using Math;

namespace Singularity {

    public class AppMenu : Gtk.Window {
        private AppMenuList app_list;
        private AppLauncherGrid? widgets_grid = null;
        private Singularity.Widgets.Carousel? carousel = null;
        private Singularity.Widgets.SearchEntry search_entry;
        private SearchManager search_manager;
        private ListBox search_results_list;
        private Stack content_stack;
        private ScrolledWindow? widgets_scrolled = null;
        private ScrolledWindow search_scrolled;
        private GLib.Settings settings;
        private Box main_box;
        private Singularity.Animation.TimedAnimation? menu_animation;
        private bool _is_open = false;
        private bool _gesture_active = false;
        private bool _gesture_opening = false;

        public signal void shown();
        public signal void hidden();

        public AppMenu(Gtk.Application app) {
            Object(application: app, decorated: false);
            search_manager = SearchManager.get_default();
            settings = new GLib.Settings("dev.sinty.desktop");

            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);

            // The window itself carries the visual style (rounded box with blur),
            // matching how Sidebar works - compositor handles alpha at corners correctly.
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("app-menu-window");

            // Menu-mode is meant to feel like a compact popup window
            // (think settings sidebar): roughly square, anchored to
            // the side where its launcher button lives. The 2-column
            // grid keeps the row count manageable; users with many
            // pinned apps scroll vertically.
            set_default_size(340, 620);

            // Close when clicking outside (window loses focus). The
            // developer "Keep Overview Open" toggle pins the menu in
            // place for screenshots / inspection.
            notify["is-active"].connect(() => {
                if (visible && !is_active
                    && !Singularity.DebugManager.get_default().overview_pinned)
                    toggle();
            });

            // Outer wrapper with a small margin so the inner card's
            // drop shadow has room to render outside the visible card
            // edge without being clipped.
            var outer = new Box(Orientation.VERTICAL, 0);
            outer.margin_top    = 12;
            outer.margin_bottom = 12;
            outer.margin_start  = 12;
            outer.margin_end    = 12;
            set_child(outer);

            main_box = new Box(Orientation.VERTICAL, 0);
            main_box.overflow = Overflow.HIDDEN;
            main_box.add_css_class("app-menu-card");
            main_box.hexpand = true;
            main_box.vexpand = true;
            outer.append(main_box);

            search_entry = new Singularity.Widgets.SearchEntry();
            search_entry.placeholder_text = _("Search...");
            search_entry.margin_top = 12;
            search_entry.margin_bottom = 8;
            search_entry.margin_start = 12;
            search_entry.margin_end = 12;
            search_entry.hexpand = true;
            search_entry.search_changed.connect(on_search_changed);
            main_box.append(search_entry);

            content_stack = new Stack();
            content_stack.transition_type = StackTransitionType.CROSSFADE;
            content_stack.vexpand = true;
            main_box.append(content_stack);

            // Two-page Carousel: apps on page 0, widgets on page 1
            // (only shown when there are any). Horizontal scroll /
            // swipe pages between them; dots underneath indicate count
            // and current position.
            carousel = new Singularity.Widgets.Carousel();
            carousel.transition_duration = 220;
            carousel.hexpand = true;
            carousel.vexpand = true;

            // Apps page: alphabetical address-book style list with sticky
            // letter sections, not reorderable.
            app_list = new AppMenuList(32);
            app_list.on_app_launched = () => { toggle(); };
            carousel.append_page(app_list);

            // Widgets page: separate grid with their natural footprint,
            // so widget content doesn't blow up the app cells.
            widgets_scrolled = new ScrolledWindow();
            widgets_scrolled.vexpand = true;
            widgets_scrolled.hscrollbar_policy = PolicyType.NEVER;
            widgets_grid = new AppLauncherGrid(app, 64, 2, 12);
            widgets_grid.kind_filter = AppLauncherGrid.Kind.WIDGETS_ONLY;
            widgets_grid.fill_horizontally = true;
            widgets_grid.on_app_launched = () => { toggle(); };
            widgets_scrolled.set_child(widgets_grid);
            carousel.append_page(widgets_scrolled);

            content_stack.add_named(carousel, "grid");

            // Search
            search_scrolled = new ScrolledWindow();
            search_scrolled.vexpand = true;
            search_scrolled.hscrollbar_policy = PolicyType.NEVER;
            search_results_list = new ListBox();
            search_results_list.add_css_class("search-results-list");
            search_scrolled.set_child(search_results_list);
            content_stack.add_named(search_scrolled, "search");

            search_results_list.row_activated.connect((row) => {
                var res_row = row as SearchResultRow;
                if (res_row != null) {
                    res_row.result.activate();
                    if (!res_row.result.keeps_open) toggle();
                }
            });

            search_manager.results_updated.connect(update_search_results);

            var key_controller = new EventControllerKey();
            key_controller.set_propagation_phase(PropagationPhase.CAPTURE);
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    toggle();
                    return true;
                }
                if ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) &&
                    content_stack.visible_child_name == "search") {
                    var row = search_results_list.get_selected_row();
                    if (row == null) row = search_results_list.get_row_at_index(0);
                    var res_row = row as SearchResultRow;
                    if (res_row != null) {
                        res_row.result.activate();
                        if (!res_row.result.keeps_open) toggle();
                    }
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key_controller);

            close_layer_window (this);
        }

        private void apply_monitor_sizing() {
            Gdk.Monitor? mon = GtkLayerShell.get_monitor(this);
            if (mon == null) {
                var dsp = Gdk.Display.get_default();
                if (dsp != null && dsp.get_monitors().get_n_items() > 0)
                    mon = dsp.get_monitors().get_item(0) as Gdk.Monitor;
            }
            if (mon == null) return;
            Gdk.Rectangle geo = mon.get_geometry();

            int target_w = int.min(340, geo.width - 24);
            main_box.set_size_request(target_w, -1);

            int max_h = geo.height - 120;
            if (max_h < 240) max_h = int.max(200, geo.height - 24);
            app_list.set_max_height(max_h);
            if (widgets_scrolled != null) {
                widgets_scrolled.propagate_natural_height = true;
                widgets_scrolled.max_content_height = max_h;
            }
            if (search_scrolled != null) {
                search_scrolled.propagate_natural_height = true;
                search_scrolled.max_content_height = max_h;
            }
        }

        private void update_anchor() {
            string pos    = settings.get_string("dock-position");
            string style  = settings.get_string("dock-style");
            string align  = settings.get_string("dock-alignment");
            bool fusion   = settings.get_boolean("panel-fusion");

            set_anchor(this, GtkLayerShell.Edge.BOTTOM, false);
            set_anchor(this, GtkLayerShell.Edge.TOP, false);
            set_anchor(this, GtkLayerShell.Edge.LEFT, false);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, false);

            // The menu always drops DOWN from the top of the screen
            // when the launcher button lives in the topbar or in the
            // fused panel (both are at the top). When the dock is at
            // the bottom and runs separately, the menu rises above it.
            bool launcher_at_top = fusion || pos == "top";
            if (launcher_at_top) {
                set_anchor(this, GtkLayerShell.Edge.TOP, true);
                set_margin(this, GtkLayerShell.Edge.TOP, 8);
            } else {
                set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
                set_margin(this, GtkLayerShell.Edge.BOTTOM, 8);
            }

            // Horizontal: stick to the side where the launcher button
            // sits, so the menu pops out under that button instead of
            // floating somewhere disconnected.
            //   - panel-fusion: the apps button is always at the start
            //     of the panel (left edge).
            //   - panel + start/end alignment: anchor matches.
            //   - panel + center: compositor centers.
            //   - floating: compositor centers.
            if (fusion) {
                set_anchor(this, GtkLayerShell.Edge.LEFT, true);
                set_margin(this, GtkLayerShell.Edge.LEFT, 8);
            } else if (style == "panel") {
                if (align == "end") {
                    set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
                    set_margin(this, GtkLayerShell.Edge.RIGHT, 8);
                } else if (align != "center") {
                    set_anchor(this, GtkLayerShell.Edge.LEFT, true);
                    set_margin(this, GtkLayerShell.Edge.LEFT, 8);
                }
            }
        }

        private void on_search_changed(Singularity.Widgets.SearchEntry entry) {
            string query = entry.text.strip();
            if (query == "") {
                content_stack.visible_child_name = "grid";
            } else {
                content_stack.visible_child_name = "search";
                search_manager.query.begin(query);
            }
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
            var first = search_results_list.get_row_at_index(0);
            if (first != null) search_results_list.select_row(first);
        }

        public void toggle() {
            if (_is_open && Singularity.DebugManager.get_default().overview_pinned)
                return;
            if (_is_open) {
                search_entry.opacity = 1;
                content_stack.opacity = 1;
                _is_open = false;
                if (menu_animation != null) menu_animation.skip();
                menu_animation = new Singularity.Animation.TimedAnimation(
                    this, opacity, 0, 140,
                    Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC
                );
                menu_animation.tick.connect(() => { opacity = menu_animation.value; });
                menu_animation.done.connect(() => {
                    if (_is_open) return;
                    close_layer_window (this);
                    if (widgets_grid != null) widgets_grid.depopulate();
                    hidden();
                });
                menu_animation.play();
            } else {
                search_entry.opacity = 1;
                content_stack.opacity = 1;
                _is_open = true;
                update_anchor();
                apply_monitor_sizing();
                search_entry.text = "";
                content_stack.visible_child_name = "grid";
                if (!visible) {
                    opacity = 0;
                    present();
                }
                app_list.populate();
                if (widgets_grid != null) widgets_grid.populate();
                if (carousel != null) carousel.scroll_to_index(0, false);
                if (menu_animation != null) menu_animation.skip();
                menu_animation = new Singularity.Animation.TimedAnimation(
                    this, opacity, 1, 190,
                    Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC
                );
                menu_animation.tick.connect(() => { opacity = menu_animation.value; });
                menu_animation.play();
                search_entry.grab_focus();
                shown();
            }
        }

        public void begin_gesture(bool opening) {
            if (!opening && !_is_open) return;
            if (!opening && Singularity.DebugManager.get_default().overview_pinned) return;
            if (opening) {
                if (!_is_open) toggle();
                if (!_is_open) return;
            }
            if (menu_animation != null) {
                menu_animation.reset();
                menu_animation = null;
            }
            _gesture_active = true;
            _gesture_opening = opening;
            opacity = 1;
            search_entry.opacity = 1;
            content_stack.opacity = 1;
            content_stack.margin_top = opening ? 72 : 0;
        }

        public void update_gesture(double dy) {
            if (!_gesture_active) return;
            double distance = Math.fabs(dy);
            double progress = double.max(0, double.min(1, distance / 240.0));
            double value = _gesture_opening ? progress : 1.0 - progress;
            search_entry.opacity = value;
            content_stack.opacity = value;
            content_stack.margin_top = (int)Math.round((1.0 - value) * 72.0);
        }

        public void end_gesture(bool committed) {
            if (!_gesture_active) return;
            _gesture_active = false;
            bool stay_open = _gesture_opening ? committed : !committed;
            _is_open = stay_open;
            double target = stay_open ? 1.0 : 0.0;
            double current = content_stack.opacity;
            if (!Gtk.Settings.get_default().gtk_enable_animations
                    || Math.fabs(current - target) < 0.001) {
                search_entry.opacity = target;
                content_stack.opacity = target;
                content_stack.margin_top = 0;
                if (stay_open) search_entry.grab_focus();
                else {
                    close_layer_window (this);
                    if (widgets_grid != null) widgets_grid.depopulate();
                    hidden();
                }
                return;
            }
            uint duration = (uint)double.max(80,
                180.0 * Math.fabs(target - current));
            var animation = new Singularity.Animation.TimedAnimation(
                this, current, target, duration,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
            menu_animation = animation;
            animation.tick.connect(() => {
                search_entry.opacity = animation.value;
                content_stack.opacity = animation.value;
                content_stack.margin_top = (int)Math.round((1.0 - animation.value) * 72.0);
            });
            animation.done.connect(() => {
                search_entry.opacity = target;
                content_stack.opacity = target;
                content_stack.margin_top = 0;
                if (menu_animation == animation) menu_animation = null;
                if (stay_open) search_entry.grab_focus();
                else {
                    close_layer_window (this);
                    if (widgets_grid != null) widgets_grid.depopulate();
                    hidden();
                }
            });
            animation.play();
        }
    }
}
