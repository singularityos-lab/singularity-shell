using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class Sidebar : Gtk.Window {
        private Stack main_stack;
        private SystemView system_view;
        private Box? calendar_view = null;
        private NotificationsPage? notifications_view = null;
        private SettingsView settings_view;
        private GLib.Settings desktop_settings;
        private ScrolledWindow sidebar_scroll;
        private Box main_box;
        private ulong _background_effect_handler = 0;
        private ulong _blur_strength_handler = 0;
        public delegate void FilePickerCallback(File file);
        private uint _file_picker_token = 0;

        public Sidebar(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, false); // Dynamic height
            set_margin(this, GtkLayerShell.Edge.TOP, 0);
            set_margin(this, GtkLayerShell.Edge.BOTTOM, 10);
            set_margin(this, GtkLayerShell.Edge.RIGHT, 0);
            // Fixed width for the whole sidebar, every page identical. Sized so
            // the Desktop page fits exactly two wallpaper columns (2x172 card +
            // gaps + paddings); narrower stacked them one per row with space wasted.
            set_default_size(SidebarWidth.CARD, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            desktop_settings = new GLib.Settings("dev.sinty.desktop");
            add_css_class("singularity");
            add_css_class("singularity-shell");
            // The window surface stays transparent so the visible card's
            // shadow can render outside the bg edges. The card itself is
            // the inner main_box with the .sidebar class.
            add_css_class("sidebar-window");
            main_box = new Box(Orientation.VERTICAL, 0);
            main_box.add_css_class("sidebar");
            main_box.width_request = SidebarWidth.CARD;
            // Reserve space around the card for the drop shadow.
            main_box.margin_top    = 20;
            main_box.margin_bottom = 20;
            main_box.margin_start  = 20;
            main_box.margin_end    = 20 + EDGE_GAP;
            _content_bin = new Singularity.Animation.MotionBin(main_box);
            _content_bin.notify["translate-x"].connect(() => {
                int shift = (int) Math.round(_content_bin.translate_x);
                if (shift != _blur_shift) update_background_effect();
            });
            set_child(_content_bin);
            var shade_drag = new GestureDrag();
            var shade_travel = Singularity.Animation.AnchoredDrag.attach(shade_drag);
            shade_drag.propagation_phase = PropagationPhase.CAPTURE;
            shade_drag.drag_begin.connect((x, y) => shade_drag_begin(shade_drag, x, y));
            shade_drag.drag_update.connect(() => shade_drag_update(shade_drag, shade_travel.travel_x, shade_travel.travel_y));
            shade_drag.drag_end.connect(() => shade_drag_end(shade_travel.travel_y));
            shade_drag.cancel.connect(() => shade_drag_end(0.0));
            _content_bin.add_controller(shade_drag);

            var sidebar_scroll = new ScrolledWindow();
            this.sidebar_scroll = sidebar_scroll;
            sidebar_scroll.hscrollbar_policy = PolicyType.NEVER;
            sidebar_scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            sidebar_scroll.propagate_natural_height = true;
            // Cap height so the sidebar never overlaps the topbar, dock, or screen edges.
            // update_max_height() is called from the shell after panel/dock heights are known.
            int max_h = 600;
            var display = Gdk.Display.get_default();
            if (display != null) {
                var monitor = display.get_monitors().get_item(0) as Gdk.Monitor;
                if (monitor != null) max_h = int.max(400, monitor.geometry.height - 180);
            }
            sidebar_scroll.max_content_height = max_h;

            main_stack = new Stack();
            main_stack.vhomogeneous = false; // Size according to visible child
            main_stack.hhomogeneous = false;
            main_stack.transition_type = StackTransitionType.SLIDE_LEFT_RIGHT;

            sidebar_scroll.set_child(main_stack);
            _wait_bar = new SidebarWaitBar();
            _wait_bar.notify["visible"].connect(() => apply_max_height());
            var column = new Box(Orientation.VERTICAL, 0);
            column.append(_wait_bar);
            column.append(sidebar_scroll);
            _shade_handle = new Box(Orientation.HORIZONTAL, 0);
            _shade_handle.add_css_class("phone-shade-handle");
            _shade_handle.halign = Align.FILL;
            _shade_handle.visible = false;
            var pill = new Box(Orientation.HORIZONTAL, 0);
            pill.add_css_class("phone-nav-pill");
            pill.halign = Align.CENTER;
            pill.valign = Align.CENTER;
            pill.hexpand = true;
            _shade_handle.append(pill);
            column.append(_shade_handle);
            main_box.append(new SidebarWidth(column));

            _background_effect_handler = desktop_settings.changed["background-effect"].connect(
                update_background_effect);
            _blur_strength_handler = desktop_settings.changed["blur-strength"].connect(
                update_background_effect);
            map.connect_after(update_background_effect);

            system_view = new SystemView();
            system_view.toggle_settings.connect(() => {
                toggle_settings();
            });
            system_view.hide_sidebar.connect(() => {
                close_layer_window (this);
            });
            system_view.open_settings_page.connect((page) => {
                open_page(page);
            });
            system_view.open_detail_page.connect(open_tile_detail);
            // settings_view initialized on demand
            main_stack.add_named(system_view, "system");
            // settings_view added on demand

            desktop_settings.changed["settings-in-window"].connect(() => update_vertical_anchor());
            desktop_settings.changed["panel-fusion"].connect(() => update_vertical_anchor());
            desktop_settings.changed["dock-position"].connect(() => update_vertical_anchor());
            main_stack.notify["visible-child-name"].connect(() => update_vertical_anchor());
            update_vertical_anchor();
            apply_form();
            Singularity.FormFactor.get_default().changed.connect(() => apply_form());
            Singularity.FormFactor.get_default().outputs_changed.connect(() => apply_form());

            close_layer_window (this);

            // Close on Escape key
            var key_controller = new Gtk.EventControllerKey();
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    if (!Singularity.DebugManager.get_default().sidebar_pinned) {
                        desktop_settings.set_boolean("bar-layout-edit-mode", false);
                        close_layer_window (this);
                    }
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key_controller);

            watch_polkit_agent.begin();

            // Close when focus leaves the sidebar (click outside).
            // The check is deferred by one event-loop cycle so that popovers and
            // drop-down popups that are children of this window (SelectionRow,
            // Switch popups, etc.) can settle without triggering a spurious close.
            notify["is-active"].connect(() => {
                if (!is_active && visible && _can_close_on_focus_loss) {
                    GLib.Idle.add(() => {
                        if (!is_active && visible && _can_close_on_focus_loss
                            && !desktop_settings.get_boolean("bar-layout-edit-mode")
                            && !Singularity.DebugManager.get_default().sidebar_pinned
                            && !hold_for_shell_dialog()) {
                            animated_close();
                        }
                        return GLib.Source.REMOVE;
                    });
                }
            });
        }

        private async void watch_polkit_agent() {
            try {
                _polkit_agent = yield new DBusProxy.for_bus(BusType.SESSION, DBusProxyFlags.DO_NOT_AUTO_START,
                    null, "dev.sinty.PolkitAgent", "/dev/sinty/PolkitAgent/Authentication",
                    "dev.sinty.PolkitAgent.Authentication");
                Variant? current = _polkit_agent.get_cached_property("Authenticating");
                _polkit_busy = current != null && current.get_boolean();
                _polkit_agent.g_signal.connect((sender, name, parameters) => {
                    if (name == "AuthenticatingChanged") set_polkit_busy(parameters.get_child_value(0).get_boolean());
                });
                _polkit_agent.notify["g-name-owner"].connect(() => {
                    if (_polkit_agent.g_name_owner == null) set_polkit_busy(false);
                });
            } catch (GLib.Error e) {
                warning("Cannot watch the authentication agent: %s", e.message);
            }
        }

        private void set_polkit_busy(bool busy) {
            _polkit_busy = busy;
            if (busy || !_focus_held) return;
            Timeout.add(250, () => {
                regain_focus();
                return GLib.Source.REMOVE;
            });
        }

        private bool hold_for_shell_dialog() {
            if (_polkit_busy) {
                _focus_held = true;
                return true;
            }
            Gtk.Window? dialog = null;
            foreach (unowned Gtk.Window window in application.get_windows()) {
                if (window == this || !window.visible) continue;
                if (!(window is Singularity.Widgets.AppDialog) && !(window is Singularity.Shell.ShellDialog)) continue;
                if (GtkLayerShell.is_layer_window(window)
                    && GtkLayerShell.get_keyboard_mode(window) == GtkLayerShell.KeyboardMode.EXCLUSIVE) continue;
                dialog = window;
                break;
            }
            if (dialog == null) return false;
            _focus_held = true;
            ulong handler = 0;
            handler = dialog.notify["visible"].connect(() => {
                if (dialog.visible) return;
                dialog.disconnect(handler);
                regain_focus();
            });
            return true;
        }

        private void regain_focus() {
            if (!_focus_held) return;
            _focus_held = false;
            if (!visible || is_active || _polkit_busy) {
                _focus_held = visible && _polkit_busy;
                return;
            }
            _can_close_on_focus_loss = false;
            close_layer_window (this);
            present();
            Timeout.add(400, () => {
                _can_close_on_focus_loss = true;
                return GLib.Source.REMOVE;
            });
        }

        private void update_background_effect() {
            var mode = Singularity.Style.BackgroundEffect.read(desktop_settings);
            if (get_mapped()) {
                Graphene.Rect bounds;
                if (main_box.compute_bounds(this, out bounds)) {
                    _blur_shift = (int) Math.round(_content_bin.translate_x);
                    Singularity.Style.BackgroundEffect.apply_shapes(this,
                        new Gtk.Widget[] { main_box }, mode);
                    var surface = get_surface();
                    if (surface != null) {
                        var region = new Cairo.Region.rectangle(Cairo.RectangleInt() {
                            x = (int) bounds.origin.x, y = (int) bounds.origin.y,
                            width = (int) bounds.size.width, height = (int) bounds.size.height
                        });
                        surface.set_input_region(region);
                    }
                    return;
                }
            }
            Singularity.Style.BackgroundEffect.apply(this, mode);
        }

        public override void size_allocate(int width, int height, int baseline) {
            base.size_allocate(width, height, baseline);
            update_background_effect();
        }

        protected override void dispose() {
            if (_background_effect_handler != 0) {
                desktop_settings.disconnect(_background_effect_handler);
                _background_effect_handler = 0;
            }
            if (_blur_strength_handler != 0) {
                desktop_settings.disconnect(_blur_strength_handler);
                _blur_strength_handler = 0;
            }
            base.dispose();
        }

        private bool _phone = false;
        private bool _pull = false;
        private const int SHADE_MARGIN = 8;
        private const int SHADE_INSET = 26;
        private const double SHADE_DROP = 48.0;

        private string slide_property() {
            return _pull ? "translate-y" : "translate-x";
        }

        private double slide_distance() {
            return _pull ? -SHADE_DROP : SLIDE_DISTANCE;
        }

        private Gdk.Monitor? _target_monitor = null;

        public void set_target_monitor(Gdk.Monitor? monitor) {
            if (monitor == _target_monitor) return;
            _target_monitor = monitor;
            if (monitor != null) GtkLayerShell.set_monitor(this, monitor);
            apply_form();
        }

        private Gdk.Monitor? form_monitor() {
            return _target_monitor ?? Singularity.FormFactor.main_monitor();
        }

        private Gdk.Monitor? _geometry_monitor = null;
        private ulong _geometry_id = 0;

        private void watch_geometry(Gdk.Monitor? monitor) {
            if (monitor == _geometry_monitor) return;
            if (_geometry_monitor != null && _geometry_id != 0) _geometry_monitor.disconnect(_geometry_id);
            _geometry_monitor = monitor;
            _geometry_id = monitor != null ? monitor.notify["geometry"].connect(() => apply_form()) : 0;
        }

        private void apply_form() {
            var monitor = form_monitor();
            watch_geometry(monitor);
            var kind = Singularity.FormFactor.at(monitor);
            _phone = kind == Singularity.FormFactorKind.PHONE || kind == Singularity.FormFactorKind.WATCH;
            _pull = kind.is_touch_first();
            system_view.set_form(kind);
            set_anchor(this, GtkLayerShell.Edge.LEFT, _phone);
            set_exclusive_zone(this, _phone ? -1 : 0);
            int margin = _phone ? 0 : 20;
            main_box.margin_top = _phone ? SHADE_MARGIN : 20;
            main_box.margin_bottom = margin;
            main_box.margin_start = margin;
            main_box.margin_end = _phone ? 0 : 20 + EDGE_GAP;
            main_box.vexpand = _phone;
            sidebar_scroll.vexpand = _phone;
            _shade_handle.visible = _pull;
            set_css_class(main_box, "phone-shade", _phone);
            int width = -1;
            if (_phone && monitor != null) {
                width = monitor.geometry.width;
                int top = AppSystem.get_default().shell_panel_height;
                sidebar_scroll.max_content_height = monitor.geometry.height - top - SHADE_MARGIN;
            }
            SidebarWidth.override_width = width > 0 ? width - SHADE_INSET : -1;
            main_box.width_request = width > 0 ? width : SidebarWidth.CARD;
            set_default_size(width > 0 ? width : SidebarWidth.CARD, -1);
            update_vertical_anchor();
            main_box.queue_resize();
        }

        private static void set_css_class(Gtk.Widget widget, string name, bool on) {
            if (on) widget.add_css_class(name);
            else widget.remove_css_class(name);
        }

        private void animated_close() {
            if (!visible) return;
            _is_closing = true;
            if (!Singularity.Motion.reduced()) {
                Singularity.Motion.spring_to(_content_bin, slide_property(), slide_distance(),
                    Singularity.Motion.Spring.GENTLE);
            }
            var fade = Singularity.Motion.tween(_content_bin, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                if (_is_closing) finish_close();
            });
        }

        private void finish_close() {
            Singularity.Motion.cancel(_content_bin, "translate-x");
            Singularity.Motion.cancel(_content_bin, "translate-y");
            Singularity.Motion.cancel(_content_bin, "opacity");
            _is_closing = false;
            _can_close_on_focus_loss = false;
            _content_bin.reset_transform();
            _content_bin.opacity = 1.0;
            close_layer_window (this);
        }

        private void animated_open(string page_name) {
            bool entering = !visible || _is_closing;
            _is_closing = false;
            main_stack.visible_child_name = page_name;
            _can_close_on_focus_loss = false;
            if (!visible) {
                _content_bin.opacity = 0.0;
                double start = Singularity.Motion.reduced() ? 0.0 : slide_distance();
                if (_pull) _content_bin.translate_y = start;
                else _content_bin.translate_x = start;
            }
            present();
            if (entering) {
                if (Singularity.Motion.reduced()) {
                    Singularity.Motion.cancel(_content_bin, slide_property());
                    _content_bin.translate_x = 0.0;
                    _content_bin.translate_y = 0.0;
                } else {
                    Singularity.Motion.spring_to(_content_bin, slide_property(), 0.0,
                        _pull ? Singularity.Motion.Spring.SNAPPY : Singularity.Motion.Spring.GENTLE);
                }
                Singularity.Motion.tween(_content_bin, "opacity", 1.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
            }
            Timeout.add(400, () => { _can_close_on_focus_loss = true; return false; });
        }

        private void ensure_calendar_view() {
            if (calendar_view != null) return;
            ((SingularityApp)application).ensure_online_calendars();
            var calendar_page = new CalendarPage();
            calendar_page.back_clicked.connect(() => {
                toggle_calendar();
            });
            calendar_view = calendar_page;
            main_stack.add_named(calendar_view, "calendar");
        }

        private void open_tile_detail(string title, Widget content) {
            var previous = main_stack.get_child_by_name("tile-detail");
            if (previous != null) main_stack.remove(previous);
            var page = new SettingsPage(title);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => {
                main_stack.visible_child_name = "system";
            });
            page.add_widget(content);
            main_stack.add_named(page, "tile-detail");
            animated_open("tile-detail");
        }

        private void ensure_notifications_view() {
            if (notifications_view != null) return;
            var notifications_page = new NotificationsPage();
            notifications_page.back_btn.visible = true;
            notifications_page.back_clicked.connect(() => {
                toggle_notifications();
            });
            notifications_view = notifications_page;
            main_stack.add_named(notifications_view, "notifications");
        }

        private const double SLIDE_DISTANCE = 96.0;
        private const int EDGE_GAP = 40;
        private const double PULL_SLOP = 6.0;
        private const double PULL_COMMIT = 0.3;
        private const double SHADE_GRAB_ZONE = 64.0;
        private const double FLICK_VELOCITY = 700.0;
        private bool _shade_tracking = false;
        private bool _shade_pulling = false;
        private bool _shade_armed = false;
        private Box _shade_handle;
        private double _shade_last_dy = 0.0;
        private int64 _shade_last_time = 0;
        private double _shade_velocity = 0.0;

        private double shade_height() {
            int h = main_box.get_height();
            return h > 0 ? h + SHADE_MARGIN : 640.0;
        }

        private void shade_drag_begin(GestureDrag drag, double x, double y) {
            _shade_armed = false;
            if (!_pull || _is_closing) {
                drag.set_state(EventSequenceState.DENIED);
                return;
            }
            Graphene.Point local;
            var start = Graphene.Point() { x = (float) x, y = (float) y };
            if (!_content_bin.compute_point(main_box, start, out local)
                || local.y < main_box.get_height() - SHADE_GRAB_ZONE) {
                drag.set_state(EventSequenceState.DENIED);
                return;
            }
            _shade_armed = true;
            _shade_last_dy = 0.0;
            _shade_last_time = get_monotonic_time();
            _shade_velocity = 0.0;
        }

        private void shade_drag_update(GestureDrag drag, double dx, double dy) {
            if (!_shade_armed || _is_closing) return;
            if (!_shade_tracking) {
                if (Math.fabs(dy) < PULL_SLOP || dy > 0 || Math.fabs(dx) > Math.fabs(dy)) return;
                _shade_tracking = true;
                drag.set_state(EventSequenceState.CLAIMED);
                Singularity.Motion.cancel(_content_bin, "translate-y");
            }
            int64 now = get_monotonic_time();
            double elapsed = (now - _shade_last_time) / 1000000.0;
            if (elapsed > 0.0) _shade_velocity = (dy - _shade_last_dy) / elapsed;
            _shade_last_dy = dy;
            _shade_last_time = now;
            _content_bin.translate_y = double.min(0.0, dy);
        }

        private void shade_drag_end(double dy) {
            _shade_armed = false;
            if (!_shade_tracking) return;
            _shade_tracking = false;
            bool flicked = _shade_velocity < -FLICK_VELOCITY && dy < -PULL_SLOP;
            if (flicked || -dy > shade_height() * PULL_COMMIT) gesture_close();
            else Singularity.Motion.spring_to(_content_bin, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        private void gesture_close() {
            _is_closing = true;
            var slide = Singularity.Motion.tween(_content_bin, "translate-y", -shade_height(),
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            slide.done.connect(() => {
                if (_is_closing) finish_close();
            });
        }

        public bool pull_begin() {
            if (!_pull) return false;
            if (visible && !_is_closing) return false;
            Singularity.Motion.cancel(_content_bin, "translate-y");
            Singularity.Motion.cancel(_content_bin, "opacity");
            _is_closing = false;
            _shade_pulling = true;
            main_stack.visible_child_name = "system";
            _can_close_on_focus_loss = false;
            _content_bin.opacity = 1.0;
            _content_bin.translate_y = -shade_height();
            present();
            return true;
        }

        public void pull_update(double dy) {
            if (!_shade_pulling) return;
            double h = shade_height();
            _content_bin.translate_y = double.max(-h, double.min(0.0, dy - h));
        }

        public void pull_end(double dy) {
            if (!_shade_pulling) return;
            _shade_pulling = false;
            if (dy > shade_height() * PULL_COMMIT) {
                Singularity.Motion.spring_to(_content_bin, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
                Timeout.add(400, () => { _can_close_on_focus_loss = true; return false; });
            } else {
                gesture_close();
            }
        }

        private Singularity.Animation.MotionBin _content_bin;
        private int _blur_shift = 0;
        private bool _can_close_on_focus_loss = false;
        private bool _is_closing = false;
        private bool _focus_held = false;
        private DBusProxy? _polkit_agent = null;
        private bool _polkit_busy = false;

        public void toggle() {
            if (visible && !_is_closing) {
                animated_close();
            } else {
                animated_open("system");
            }
        }

        public void dismiss() {
            if (visible && !_is_closing) animated_close();
        }

        public void toggle_system() {
            if (visible && !_is_closing && main_stack.visible_child_name == "system") {
                animated_close();
            } else {
                animated_open("system");
            }
        }

        public void toggle_calendar() {
            ensure_calendar_view();
            if (visible && !_is_closing && main_stack.visible_child_name == "calendar") {
                animated_close();
            } else {
                animated_open("calendar");
            }
        }

        public void toggle_notifications() {
            ensure_notifications_view();
            if (visible && !_is_closing && main_stack.visible_child_name == "notifications") {
                animated_close();
            } else {
                animated_open("notifications");
            }
        }

        private void update_vertical_anchor() {
            if (_phone) {
                int top = AppSystem.get_default().shell_panel_height;
                GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
                GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, top);
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.BOTTOM, 0);
                return;
            }
            bool in_window = desktop_settings.get_boolean("settings-in-window");
            string child = main_stack.visible_child_name;

            // Anchor to bottom (full height) only for file picker
            bool needs_full_height = (child == "file_picker");

            // In window-mode, never use full height for "system" (quick settings)
            if (in_window && child == "system") {
                needs_full_height = false;
            }

            // When the dock is in panel/fusion mode at the bottom, the
            // sidebar's trigger icons live at the bottom of the screen - so
            // make the sidebar emerge from there too. Otherwise anchor it
            // to the top (the historical layout).
            bool dock_at_bottom =
                desktop_settings.get_boolean("panel-fusion") &&
                desktop_settings.get_string("dock-position") == "bottom";

            if (dock_at_bottom && !needs_full_height) {
                GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, false);
                GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
                // Leave clearance above the dock so it doesn't overlap visually.
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.BOTTOM, 10);
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, 0);
            } else {
                GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
                GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, needs_full_height);
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, 0);
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.BOTTOM, 10);
            }

            // If window-mode is enabled, never show settings pages in the sidebar.
            if (in_window && child == "settings") {
                main_stack.visible_child_name = "system";
            }
        }

        private SidebarWaitBar? _wait_bar = null;
        private int _base_max_height = 0;

        private void apply_max_height() {
            if (_base_max_height <= 0) _base_max_height = sidebar_scroll.max_content_height;
            int bar = _wait_bar != null && _wait_bar.visible ? 56 : 0;
            sidebar_scroll.max_content_height = int.max(300, _base_max_height - bar);
        }

        internal void capture_wait_state(SidebarWaitTicket ticket) {
            ticket.main_page = main_stack.visible_child_name ?? "system";
            ticket.settings_page = settings_view != null ? settings_view.current_page_name : "";
            ticket.scroll = sidebar_scroll.vadjustment.value;
        }

        internal void restore_wait_state(SidebarWaitTicket ticket) {
            if (ticket.main_page == "settings" && settings_view != null) settings_view.show_page_name(ticket.settings_page);
            if (!visible || _is_closing || main_stack.visible_child_name != ticket.main_page) {
                animated_open(ticket.main_page != "" ? ticket.main_page : "system");
            } else {
                present();
            }
            double value = ticket.scroll;
            Timeout.add(200, () => {
                sidebar_scroll.vadjustment.value = value;
                return GLib.Source.REMOVE;
            });
        }

        public SettingsView get_settings_view() {
            ensure_settings_view();
            return settings_view;
        }

        public void reveal_setting(SettingsEntry entry, bool activate) {
            open_page(entry.page_name);
            settings_view.reveal(entry, activate);
        }

        private void ensure_settings_view() {
            if (settings_view == null) {
                settings_view = new SettingsView((SingularityApp)application);
                settings_view.back_to_system.connect(() => {
                    main_stack.visible_child_name = "system";
                });
                main_stack.add_named(settings_view, "settings");
            }
        }

        public void toggle_settings() {
            if (desktop_settings.get_boolean("settings-in-window")) {
                var app = (SingularityApp) application;
                app.open_settings_page("desktop");
                main_stack.visible_child_name = "system";
                present();
                return;
            }
            ensure_settings_view();
            if (visible && main_stack.visible_child_name == "settings") {
                main_stack.visible_child_name = "system";
            } else {
                settings_view.go_home();
                main_stack.visible_child_name = "settings";
                present();
                settings_view.focus_search();
            }
        }

        public void open_page(string page_name) {
            if (desktop_settings.get_boolean("settings-in-window")) {
                var app = (SingularityApp) application;
                app.open_settings_page(page_name);
                animated_open("system");
                return;
            }
            ensure_settings_view();
            settings_view.navigate_to(page_name);
            animated_open("settings");
        }

        public void reveal_setting_title(string page_name, string title) {
            ensure_settings_view();
            settings_view.reveal_title(page_name, title);
            animated_open("settings");
        }

        public void open_app_details(AppInfo info) {
            ensure_settings_view();
            settings_view.open_app_details(info);
            animated_open("settings");
        }

        // Pick a file through the XDG Desktop Portal FileChooser instead of an
        // in-shell browser. `patterns` are globs (e.g. "*.ics") for the filter.
        public void open_file_picker(string? filter_name, string[]? patterns, owned FilePickerCallback callback) {
            open_file_picker_async.begin(filter_name, patterns, (owned) callback);
        }

        private async void open_file_picker_async(string? filter_name, owned string[]? patterns,
                                                  owned FilePickerCallback callback) {
            SidebarWaitTicket? ticket = null;
            try {
                var bus = yield Bus.get(BusType.SESSION);
                string unique = bus.get_unique_name();
                string sender = unique.has_prefix(":")
                    ? unique.substring(1).replace(".", "_")
                    : unique.replace(".", "_");
                string token = "singularity_files_%u".printf(_file_picker_token++);
                string handle = "/org/freedesktop/portal/desktop/request/%s/%s".printf(sender, token);

                string? uri = null;
                SourceFunc resume = open_file_picker_async.callback;
                uint sub = bus.signal_subscribe(
                    "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
                    "Response", handle, null, DBusSignalFlags.NONE,
                    (conn, snd, path, iface, sig, parameters) => {
                        uint32 response;
                        Variant results;
                        parameters.get("(u@a{sv})", out response, out results);
                        if (response == 0) {
                            Variant? uris = results.lookup_value("uris", new VariantType("as"));
                            if (uris != null && uris.n_children() > 0)
                                uri = uris.get_child_value(0).get_string();
                        }
                        if (resume != null) { SourceFunc cb = (owned) resume; resume = null; cb(); }
                    });

                ticket = SidebarWait.get_default().begin(this, _("Waiting for Files"), "folder-symbolic", () => {
                    bus.call.begin("org.freedesktop.portal.Desktop", handle, "org.freedesktop.portal.Request", "Close",
                        null, null, DBusCallFlags.NONE, -1, null);
                    uri = null;
                    if (resume != null) { SourceFunc cb = (owned) resume; resume = null; cb(); }
                });
                var options = new VariantBuilder(new VariantType("a{sv}"));
                options.add("{sv}", "handle_token", new Variant.string(token));
                options.add("{sv}", "modal", new Variant.boolean(true));
                if (patterns != null && patterns.length > 0) {
                    var globs = new VariantBuilder(new VariantType("a(us)"));
                    foreach (string p in patterns) globs.add("(us)", (uint32) 0, p);
                    var one = new Variant("(s@a(us))", filter_name ?? "Files", globs.end());
                    var filters = new VariantBuilder(new VariantType("a(sa(us))"));
                    filters.add_value(one);
                    options.add("{sv}", "filters", filters.end());
                }
                yield bus.call(
                    "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.FileChooser", "OpenFile",
                    new Variant("(ssa{sv})", "", "Select File", options),
                    new VariantType("(o)"), DBusCallFlags.NONE, -1, null);
                if (resume != null) yield;
                bus.signal_unsubscribe(sub);
                ticket.end();
                if (uri != null) callback(File.new_for_uri(uri));
            } catch (Error e) {
                if (ticket != null) ticket.end_quietly();
                warning("open_file_picker: %s", e.message);
            }
        }

        // Called by the shell once panel/dock heights are known so the sidebar
        // never overflows onto or below the dock.
        public void update_max_height(int panel_height, int dock_height) {
            var display = Gdk.Display.get_default();
            if (display != null) {
                var monitor = display.get_monitors().get_item(0) as Gdk.Monitor;
                if (monitor != null) {
                    // top_margin(10) + panel + bottom_margin(10) + dock + buffer(20)
                    int reserved = 10 + panel_height + 10 + dock_height + 20;
                    _base_max_height = int.max(400, monitor.geometry.height - reserved);
                    apply_max_height();
                }
            }
        }
    }
}
