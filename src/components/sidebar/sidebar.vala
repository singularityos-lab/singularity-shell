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
            set_margin(this, GtkLayerShell.Edge.RIGHT, 40);
            // Fixed width for the whole sidebar, every page identical. Sized so
            // the Desktop page fits exactly two wallpaper columns (2x172 card +
            // gaps + paddings); narrower stacked them one per row with space wasted.
            set_default_size(440, -1);
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
            // Pin the inner width so the sidebar stays this size on every page
            // instead of resizing to each page's natural width.
            main_box.width_request = 416;
            // Reserve space around the card for the drop shadow.
            main_box.margin_top    = 20;
            main_box.margin_bottom = 20;
            main_box.margin_start  = 20;
            main_box.margin_end    = 20;
            set_child(main_box);

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
            main_stack.transition_type = StackTransitionType.SLIDE_LEFT_RIGHT;

            sidebar_scroll.set_child(main_stack);
            main_box.append(sidebar_scroll);

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
            // settings_view initialized on demand
            main_stack.add_named(system_view, "system");
            // settings_view added on demand

            desktop_settings.changed["settings-in-window"].connect(() => update_vertical_anchor());
            desktop_settings.changed["panel-fusion"].connect(() => update_vertical_anchor());
            desktop_settings.changed["dock-position"].connect(() => update_vertical_anchor());
            main_stack.notify["visible-child-name"].connect(() => update_vertical_anchor());
            update_vertical_anchor();

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

            // Close when focus leaves the sidebar (click outside).
            // The check is deferred by one event-loop cycle so that popovers and
            // drop-down popups that are children of this window (SelectionRow,
            // Switch popups, etc.) can settle without triggering a spurious close.
            notify["is-active"].connect(() => {
                if (!is_active && visible && _can_close_on_focus_loss) {
                    GLib.Idle.add(() => {
                        if (!is_active && visible && _can_close_on_focus_loss
                            && !desktop_settings.get_boolean("bar-layout-edit-mode")
                            && !Singularity.DebugManager.get_default().sidebar_pinned) {
                            animated_close();
                        }
                        return GLib.Source.REMOVE;
                    });
                }
            });
        }

        private void update_background_effect() {
            var mode = Singularity.Style.BackgroundEffect.read(desktop_settings);
            if (get_mapped()) {
                Graphene.Rect bounds;
                if (main_box.compute_bounds(this, out bounds)) {
                    Singularity.Style.BackgroundEffect.apply(this, mode,
                        (int) bounds.origin.x, (int) bounds.origin.y,
                        (int) bounds.size.width, (int) bounds.size.height);
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

        private void animated_close() {
            if (!visible) return;
            _is_closing = true;
            if (!Gtk.Settings.get_default().gtk_enable_animations) {
                slide_animation = null;
                _is_closing = false;
                _can_close_on_focus_loss = false;
                opacity = 1;
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.RIGHT, 40);
                close_layer_window (this);
                return;
            }
            // Null before skip so old done handler sees slide_animation != old_anim
            var old = slide_animation;
            slide_animation = null;
            if (old != null) old.skip();
            var anim = new Singularity.Animation.TimedAnimation(
                this, 1, 0, 140,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC
            );
            slide_animation = anim;
            anim.tick.connect(() => {
                opacity = anim.value;
                int current_margin = (int)(-50 + (40 - (-50)) * anim.value);
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.RIGHT, current_margin);
            });
            anim.done.connect(() => {
                if (slide_animation == anim) {
                    slide_animation = null;
                    _is_closing = false;
                    _can_close_on_focus_loss = false;
                    close_layer_window (this);
                }
            });
            anim.play();
        }

        private void animated_open(string page_name) {
            _is_closing = false;
            main_stack.visible_child_name = page_name;
            _can_close_on_focus_loss = false;
            if (!Gtk.Settings.get_default().gtk_enable_animations) {
                slide_animation = null;
                opacity = 1;
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.RIGHT, 40);
                present();
                Timeout.add(400, () => { _can_close_on_focus_loss = true; return false; });
                return;
            }
            var old = slide_animation;
            slide_animation = null;
            if (old != null) old.skip();
            opacity = 0;
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.RIGHT, -50);
            var anim = new Singularity.Animation.TimedAnimation(
                this, 0, 1, 150,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC
            );
            slide_animation = anim;
            anim.tick.connect(() => {
                opacity = anim.value;
                int current_margin = (int)(-50 + (40 - (-50)) * anim.value);
                GtkLayerShell.set_margin(this, GtkLayerShell.Edge.RIGHT, current_margin);
            });
            anim.play();
            present();
            Timeout.add(400, () => { _can_close_on_focus_loss = true; return false; });
        }

        private void ensure_calendar_view() {
            if (calendar_view != null) return;
            ((SingularityApp)application).ensure_goa_calendar();
            var calendar_page = new CalendarPage();
            calendar_page.back_clicked.connect(() => {
                toggle_calendar();
            });
            calendar_view = calendar_page;
            main_stack.add_named(calendar_view, "calendar");
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

        private Singularity.Animation.TimedAnimation? slide_animation;
        private bool _can_close_on_focus_loss = false;
        private bool _is_closing = false;

        public void toggle() {
            if (visible && !_is_closing) {
                animated_close();
            } else {
                animated_open("system");
            }
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

        private async void open_file_picker_async(string? filter_name, string[]? patterns,
                                                  owned FilePickerCallback callback) {
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
                yield;
                bus.signal_unsubscribe(sub);
                if (uri != null) callback(File.new_for_uri(uri));
            } catch (Error e) {
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
                    sidebar_scroll.max_content_height = int.max(400, monitor.geometry.height - reserved);
                }
            }
        }
    }
}
