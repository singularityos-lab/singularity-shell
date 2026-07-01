using Gtk;
using GtkLayerShell;
using Gee;

namespace Singularity {

    public class Dock : Gtk.Window, Singularity.DebugInspectable {
        private Box dock_box;
        private Box main_container;
        private Box start_area;
        private Box end_area;
        private DockResourcesArea resources_area;
        private Box center_wrapper;
        private AppSystem app_system;
        private string visibility_mode;
        private string dock_style;
        private string dock_alignment;
        private bool panel_fusion;
        private Label clock_label;
        private uint _refresh_timeout_id = 0;
        private HashMap<string, Gtk.Widget> _item_cache = new HashMap<string, Gtk.Widget>();
        private int _cached_icon_size = -1;
        private bool _cached_extended = false;
        private bool _intro_played = false;
        private bool _hidden_for_fullscreen = false;
        private ulong _sig_clock = 0;
        private bool is_primary = true;
        private Gdk.Monitor? gdk_monitor = null;
        private Gee.List<Gdk.Monitor> secondary_monitors = new ArrayList<Gdk.Monitor>();
        private bool autohide = false;
        private bool intellihide = false;
        private bool _enabled = true;
        private bool _hovered = false;
        private bool _hidden = false;
        private bool _overview_active = false;
        private int64 _hover_start_us = 0;
        private const int64 HOVER_GRACE_US = 600000;
        private uint _slide_timer_id = 0;
        private uint _fade_timer_id = 0;
        private uint _leave_timeout_id = 0;
        private Gtk.Window? _reveal_barrier = null;
        private GtkLayerShell.Edge _reveal_barrier_edge = GtkLayerShell.Edge.BOTTOM;
        private int _last_dimension = 0;
        private int _current_margin = 0;
        private bool _menu_open = false;
        private Gee.ArrayList<Singularity.DockContextMenuProvider> _menu_providers =
            new Gee.ArrayList<Singularity.DockContextMenuProvider>();
        private Gee.ArrayList<Singularity.DockItemExtension> _item_extensions =
            new Gee.ArrayList<Singularity.DockItemExtension>();
        private HashMap<Singularity.DockItemExtension, ulong> _item_extension_handlers =
            new HashMap<Singularity.DockItemExtension, ulong>();
        private HashSet<string> _kept_expanded = new HashSet<string>();
        private int _expanded_count = 0;
        private Gtk.Popover? _preview_popover = null;
        private uint _preview_dismiss_id = 0;
        private uint _preview_show_id = 0;
        private bool _preview_open = false;
        private string? _preview_app_id = null;
        private bool _dock_pinned = false;
        private Singularity.DockDBusService? _dbus_service = null;
        private GLib.Settings _settings;
        private ulong _sig_config_changed = 0;
        private ulong _sig_apps_changed = 0;
        private ulong _sig_running_apps_changed = 0;
        private ulong _sig_app_focused = 0;
        private ulong _sig_window_focused = 0;
        private ulong _sig_pulse_app = 0;
        private ulong _sig_any_maximized = 0;
        private ulong _sig_window_output = 0;
        private ulong _sig_app_title_changed = 0;
        private ulong _sig_workspaces_changed = 0;
        private ulong _sig_any_fullscreen = 0;
        private ulong _sig_app_closed = 0;
        private Widget _corner_bl;
        private Widget _corner_br;


        public void set_secondary_monitors(Gee.List<Gdk.Monitor> monitors) {
            secondary_monitors = monitors;
            schedule_refresh();
        }

        public Gdk.Monitor? get_target_monitor() {
            return gdk_monitor;
        }

        public Dock(Gtk.Application app, bool is_primary = true, Gdk.Monitor? target_monitor = null) {
            Object(application: app);
            this.is_primary = is_primary;
            this.gdk_monitor = target_monitor;
            app_system = AppSystem.get_default();
            _settings = new GLib.Settings("dev.sinty.desktop");

            init_for_window(this);
            var _shell_mon = target_monitor ?? find_shell_monitor();
            if (_shell_mon != null) GtkLayerShell.set_monitor(this, _shell_mon);
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            // Manual exclusive zone: exclude the bottom shadow margin so windows
            // snap to the visual dock edge, not the shadow area.
            set_exclusive_zone(this, 0);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);

            add_css_class("singularity");
            add_css_class("singularity-shell");

            var dock_overlay = new Overlay();
            dock_overlay.overflow = Overflow.VISIBLE;
            set_child(dock_overlay);
            main_container = new Box(Orientation.HORIZONTAL, 0);
            main_container.add_css_class("dock-container");
            main_container.overflow = Overflow.VISIBLE;
            dock_overlay.set_child(main_container);

            _corner_bl = create_corner_hint("corner-hint-bl");
            _corner_bl.can_target = false;
            _corner_bl.halign = Align.START;
            _corner_bl.valign = Align.END;
            dock_overlay.add_overlay(_corner_bl);

            _corner_br = create_corner_hint("corner-hint-br");
            _corner_br.can_target = false;
            _corner_br.halign = Align.END;
            _corner_br.valign = Align.END;
            dock_overlay.add_overlay(_corner_br);

            // Hide the dock until the first refresh has populated it -
            // otherwise the user sees an empty rounded pill flash on screen
            // before icons appear (schedule_refresh runs after 150ms).
            // The intro animation is kicked off from refresh() the first
            // time it runs, so the slide-up + fade-in is in sync with the
            // moment the items actually exist.
            if (is_primary) main_container.opacity = 0;

            start_area = new Box(Orientation.HORIZONTAL, 5);
            start_area.add_css_class("dock-start-area");
            main_container.append(start_area);

            center_wrapper = new Box(Orientation.HORIZONTAL, 0);
            center_wrapper.hexpand = true;
            main_container.append(center_wrapper);

            dock_box = new Box(Orientation.HORIZONTAL, 5);
            dock_box.add_css_class("dock-box");
            dock_box.halign = Align.CENTER;
            center_wrapper.append(dock_box);

            // Resources (files / folders / links dropped on the
            // dock) are rendered as ordinary dock items inside dock_box via
            // refresh(); this helper holds their persistence + visuals.
            resources_area = new DockResourcesArea();
            resources_area.changed.connect(schedule_refresh);

            end_area = new Box(Orientation.HORIZONTAL, 5);
            end_area.add_css_class("dock-end-area");
            main_container.append(end_area);

            add_css_class("dock-window");

            _sig_config_changed = app_system.config_changed.connect((key) => {
                if (key == "pinned-apps" || key == "dock-extended-mode" || key == "dock-icon-size") {
                    schedule_refresh();
                    if (panel_fusion) update_fusion();
                }
                if (key == "dock-visibility-mode") update_visibility_mode();
                if (key == "dock-position") {
                    update_position();
                    // Item geometry depends on orientation (pill horizontal vs
                    // vertical, slide-direction, indicator strip side). Rebuild
                    // existing items so they switch with the dock layout.
                    force_rebuild();
                }
                if (key == "dock-style") { update_style(); update_fusion(); schedule_refresh(); }
                if (key == "dock-alignment") update_alignment();
                if (key == "panel-fusion") {
                    update_fusion();
                    ((Gtk.Widget) this).hide();
                    update_visibility_mode();
                    pulse_frame_clock();
                }
                if (key == "dock-gap") update_gap();
                if (key == "dock-autohide") {
                    autohide = _settings.get_boolean("dock-autohide");
                    update_autohide_state();
                }
                if (key == "dock-intellihide") {
                    intellihide = _settings.get_boolean("dock-intellihide");
                    update_autohide_state();
                }
                if (key == "dock-enabled") {
                    _enabled = _settings.get_boolean("dock-enabled");
                    if (!_enabled) {
                        ((Gtk.Widget) this).hide();
                        set_exclusive_zone(this, 0);
                        app_system.shell_dock_height = 0;
                        _set_reveal_barrier_active(false);
                    } else {
                        present();
                        update_settings();
                    }
                }
            });

            _sig_apps_changed = app_system.apps_changed.connect(schedule_refresh);
            _sig_running_apps_changed = app_system.running_apps_changed.connect(schedule_refresh);
            _sig_app_focused = app_system.app_focused.connect(update_active_app);
            _sig_window_focused = app_system.window_focused.connect((handle) => {
                update_active_window(handle);
                update_fullscreen_mode();
            });
            _sig_pulse_app = app_system.pulse_app_requested.connect(pulse_app_icon);

            _sig_any_maximized = app_system.any_maximized_changed.connect(() => {
                update_autohide_state();
            });
            _sig_window_output = app_system.window_output_changed.connect((handle) => {
                update_autohide_state();
            });

            var motion = new Gtk.EventControllerMotion();
            motion.enter.connect(() => {
                if (_leave_timeout_id != 0) {
                    GLib.Source.remove(_leave_timeout_id);
                    _leave_timeout_id = 0;
                }
                _hovered = true;
                _hover_start_us = GLib.get_monotonic_time();
                update_autohide_state();
            });
            motion.leave.connect(() => {
                if (_leave_timeout_id != 0) GLib.Source.remove(_leave_timeout_id);
                _leave_timeout_id = GLib.Timeout.add(300, () => {
                    _leave_timeout_id = 0;
                    if (GLib.get_monotonic_time() - _hover_start_us < HOVER_GRACE_US) {
                        _leave_timeout_id = GLib.Timeout.add((uint)((HOVER_GRACE_US - (GLib.get_monotonic_time() - _hover_start_us)) / 1000 + 50), () => {
                            _leave_timeout_id = 0;
                            _hovered = false;
                            update_autohide_state();
                            return GLib.Source.REMOVE;
                        });
                        return GLib.Source.REMOVE;
                    }
                    var surface = get_surface();
                    if (surface != null) {
                        var display = Gdk.Display.get_default();
                        var seat = display?.get_default_seat();
                        var pointer = seat?.get_pointer();
                        if (pointer != null) {
                            double cx, cy;
                            Gdk.ModifierType mod_type;
                            if (surface.get_device_position(pointer, out cx, out cy, out mod_type)) {
                                return GLib.Source.REMOVE;
                            }
                        }
                    }
                    _hovered = false;
                    update_autohide_state();
                    return GLib.Source.REMOVE;
                });
            });
            // Attach to the window widget so the hot-strip at the screen edge
            // (visible when dock is hidden) reliably fires enter/leave.
            ((Gtk.Widget) this).add_controller(motion);

            _sig_app_title_changed = app_system.app_title_changed.connect((win) => {
                Widget? child = dock_box.get_first_child();
                while (child != null) {
                    void* handle = child.get_data<void*>("win_handle");
                    if (handle == win.handle) {
                        var lbl = child.get_data<Label>("title_label");
                        if (lbl != null) lbl.label = win.title;
                        break;
                    }
                    child = child.get_next_sibling();
                }
            });

            _sig_workspaces_changed = app_system.workspaces_changed.connect(() => {
                schedule_refresh();
                update_autohide_state();
            });
            _sig_any_fullscreen = app_system.any_fullscreen_changed.connect(() => {
                update_fullscreen_mode();
            });
            _sig_app_closed = app_system.app_closed.connect((handle) => {
                update_fullscreen_mode();
                schedule_refresh();
            });

            update_settings();
            schedule_refresh();

            var plugin_ctx = Singularity.PluginManager.get_default().get_context();
            plugin_ctx.dock_context_menu_provider_added.connect((provider) => {
                _menu_providers.add(provider);
            });
            plugin_ctx.dock_context_menu_provider_removed.connect((provider) => {
                _menu_providers.remove(provider);
            });
            plugin_ctx.dock_item_extension_added.connect(register_item_extension);
            plugin_ctx.dock_item_extension_removed.connect(unregister_item_extension);

            // Load the kept-expanded set
            foreach (string s in _settings.get_strv("dock-pinned-suffixes")) {
                if (s != null && s.length > 0) _kept_expanded.add(s);
            }

            // Primary dock owns the DBus service so multi-monitor doesn't conflict
            if (is_primary) {
                _dbus_service = new Singularity.DockDBusService();
                plugin_ctx.add_dock_item_extension(_dbus_service);
                _dbus_service.own_bus();
            }
            update_clock();
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            setup_dnd();

            /* Request compositor-level background blur (frosted glass) */
        }

        private void update_settings() {
            _enabled = _settings.get_boolean("dock-enabled");
            autohide = _settings.get_boolean("dock-autohide");
            intellihide = _settings.get_boolean("dock-intellihide");
            update_style();
            update_visibility_mode();
            update_alignment();
            update_fusion();
            update_position();
            update_gap();
            update_autohide_state();
        }

        private void update_gap() {
            int gap = _settings.get_int("dock-gap");
            string pos = _settings.get_string("dock-position");
            // Reset all margins
            main_container.margin_top = 0;
            main_container.margin_bottom = 0;
            main_container.margin_start = 0;
            main_container.margin_end = 0;
            set_margin(this, GtkLayerShell.Edge.BOTTOM, 0);
            set_margin(this, GtkLayerShell.Edge.LEFT, 0);
            set_margin(this, GtkLayerShell.Edge.RIGHT, 0);
            set_margin(this, GtkLayerShell.Edge.TOP, 0);
            if (dock_style == "panel") {
                _current_margin = 0;
                return;
            }
            if (pos == "left") {
                _current_margin = gap;
                set_margin(this, GtkLayerShell.Edge.LEFT, gap);
                main_container.margin_end = gap;
            } else if (pos == "right") {
                _current_margin = gap;
                set_margin(this, GtkLayerShell.Edge.RIGHT, gap);
                main_container.margin_start = gap;
            } else {
                _current_margin = gap;
                // The dock-box casts a 16px bottom shadow that lives in the
                // container's bottom margin. Pull the surface down by that
                // much so the shadow is not clipped at the surface edge,
                // while the dock stays at the same visual gap (#162).
                set_margin(this, GtkLayerShell.Edge.BOTTOM, int.max(0, gap - 21));
                main_container.margin_top = gap;
            }
        }

        private void update_position() {
            string pos = _settings.get_string("dock-position");

            set_anchor(this, GtkLayerShell.Edge.BOTTOM, false);
            set_anchor(this, GtkLayerShell.Edge.LEFT, false);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, false);
            set_anchor(this, GtkLayerShell.Edge.TOP, false);

            dock_box.orientation = Orientation.HORIZONTAL;
            main_container.orientation = Orientation.HORIZONTAL;

            // Always anchor along the perpendicular axis as well, even in
            // floating mode. With a single-edge anchor labwc keeps the
            // surface's top-left fixed across size changes, causing the
            // dock to visibly shift. Anchoring both perpendicular edges
            // makes the surface span the full screen dimension while the
            // content (dock_box) stays centered via halign - the visual
            // pill never moves, content scrolls inside it smoothly.

            if (pos == "left") {
                set_anchor(this, GtkLayerShell.Edge.LEFT, true);
                set_anchor(this, GtkLayerShell.Edge.TOP, true);
                set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
                dock_box.orientation = Orientation.VERTICAL;
                main_container.orientation = Orientation.VERTICAL;
            } else if (pos == "right") {
                set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
                set_anchor(this, GtkLayerShell.Edge.TOP, true);
                set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
                dock_box.orientation = Orientation.VERTICAL;
                main_container.orientation = Orientation.VERTICAL;
            } else {
                set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
                set_anchor(this, GtkLayerShell.Edge.LEFT, true);
                set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            }
        }

        private void update_style() {
            dock_style = _settings.get_string("dock-style");

            if (dock_style == "panel") {
                add_css_class("dock-panel-mode");
                remove_css_class("dock-floating-mode");
                set_margin(this, GtkLayerShell.Edge.BOTTOM, 0);
                set_margin(this, GtkLayerShell.Edge.LEFT, 0);
                set_margin(this, GtkLayerShell.Edge.RIGHT, 0);
            } else {
                add_css_class("dock-floating-mode");
                remove_css_class("dock-panel-mode");
            }
            // In both modes the surface spans the full perpendicular axis
            // (set in update_position()) and center_wrapper expands to fill,
            // so dock_box stays centered via halign. Setting hexpand=false
            // in floating mode left dock_box packed to the start edge - the
            // famous "dock stuck on the left" bug.
            center_wrapper.hexpand = true;
            update_position();
            update_gap();
            this.set_size_request(-1, -1);
            this.queue_resize();
        }

        private void update_alignment() {
            dock_alignment = _settings.get_string("dock-alignment");

            if (dock_alignment == "start") {
                dock_box.halign = Align.START;
                center_wrapper.halign = Align.START;
            } else if (dock_alignment == "end") {
                dock_box.halign = Align.END;
                center_wrapper.halign = Align.END;
            } else {
                dock_box.halign = Align.CENTER;
                center_wrapper.halign = Align.CENTER;
            }
        }

        // When a media/suffix widget expands, freeze the dock_box leading edge
        // so the hovered icon stays put instead of the whole centered dock
        // sliding sideways (issue #113). Only the bottom dock recenters along
        // the horizontal axis via halign; side docks are left untouched.
        private void pin_expansion() {
            _expanded_count++;
            if (_dock_pinned || is_dock_vertical() || dock_alignment != "center") return;
            Gtk.Allocation alloc;
            dock_box.get_allocation(out alloc);
            if (alloc.x <= 0) return;
            dock_box.margin_start = alloc.x;
            dock_box.halign = Align.START;
            _dock_pinned = true;
        }

        private void unpin_expansion() {
            if (_expanded_count > 0) _expanded_count--;
            if (_expanded_count > 0 || !_dock_pinned) return;
            dock_box.margin_start = 0;
            dock_box.halign = Align.CENTER;
            _dock_pinned = false;
        }

        private void update_fusion() {
            panel_fusion = _settings.get_boolean("panel-fusion");

            Widget? child = start_area.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                start_area.remove(child);
                child = next;
            }
            child = end_area.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                end_area.remove(child);
                child = next;
            }

            if (panel_fusion) {
                var start_btn = new Button();
                start_btn.add_css_class("dock-item");
                start_btn.add_css_class("start-button");

                var logo = new Image.from_icon_name("view-app-grid-symbolic");
                var icon_theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
                if (icon_theme.has_icon("emblem-singularity")) {
                    logo.icon_name = "emblem-singularity";
                }

                int icon_size = _settings.get_int("dock-icon-size");
                logo.pixel_size = icon_size;
                start_btn.set_child(logo);

                start_btn.clicked.connect(() => {
                    activities_clicked();
                });
                start_area.append(start_btn);

                int sys_icon_size = icon_size > 22 ? 22 : icon_size;

                var sys_box = new Box(Orientation.HORIZONTAL, 4);
                sys_box.add_css_class("dock-system-box");

                var network = SystemMonitor.get_default().network;
                var net_icon = new Image.from_icon_name(network.wifi_icon);
                net_icon.pixel_size = sys_icon_size;
                sys_box.append(net_icon);

                var audio = SystemMonitor.get_default().audio;
                var audio_icon = new Image.from_icon_name(audio.icon_name);
                audio_icon.pixel_size = sys_icon_size;
                sys_box.append(audio_icon);

                var power = SystemMonitor.get_default().power;
                var bat_icon = new Image.from_icon_name(power.icon_name);
                bat_icon.pixel_size = sys_icon_size;
                sys_box.append(bat_icon);

                network.state_changed.connect(() => { net_icon.icon_name = network.wifi_icon; });
                audio.state_changed.connect(() => { audio_icon.icon_name = audio.icon_name; });
                power.state_changed.connect(() => { bat_icon.icon_name = power.icon_name; });

                end_area.append(sys_box);

                var clock_box = new Box(Orientation.HORIZONTAL, 4);
                clock_box.add_css_class("dock-clock-box");
                clock_label = new Label("00:00");
                clock_label.add_css_class("dock-clock");
                clock_box.append(clock_label);
                end_area.append(clock_box);

                var gesture = new GestureClick();
                gesture.released.connect(() => {
                    system_clicked();
                });
                sys_box.add_controller(gesture);
            }
        }

        public signal void activities_clicked();
        public signal void workspace_clicked();
        public signal void system_clicked();
        public signal void dock_visibility_changed(bool hidden);

        private void update_autohide_state() {
            if (!_enabled) return;
            if (visibility_mode == "overview-only" && !_overview_active) return;
            if (_last_dimension <= 10) return;

            bool should_hide = false;
            if (autohide) {
                should_hide = true;
            } else if (intellihide) {
                should_hide = is_any_window_maximized_on_my_monitor();
            }

            if (_hovered || _overview_active || _menu_open || _preview_open) {
                should_hide = false;
            }

            if (should_hide != _hidden) {
                _hidden = should_hide;
                animate_dock(_hidden);
                dock_visibility_changed(_hidden);
            } else if (!_hidden) {
                // If not hidden, ensure exclusive zone is correct (it might have been 0)
                if (!autohide && !(intellihide && is_any_window_maximized_on_my_monitor())) {
                    set_exclusive_zone(this, int.max(0, _last_dimension - SHADOW_BOTTOM_PX));
                } else {
                    set_exclusive_zone(this, 0);
                }
            }

            _set_reveal_barrier_active(_hidden);
        }

        public string[] debug_list_vars() {
            var edge = _dock_edge();
            int gls_margin = GtkLayerShell.get_margin(this, edge);
            int excl = GtkLayerShell.get_exclusive_zone(this);
            string layer = GtkLayerShell.get_layer(this).to_string();
            string box_size = (dock_box != null)
                ? "%dx%d".printf(dock_box.get_width(), dock_box.get_height()) : "null";
            string box_mapped = (dock_box != null) ? dock_box.get_mapped().to_string() : "null";
            double fps = 0;
            var clock = get_frame_clock();
            if (clock != null) fps = clock.get_fps();
            return {
                "bool:hidden=%s".printf(_hidden.to_string()),
                "bool:hovered=%s".printf(_hovered.to_string()),
                "bool:overview_active=%s".printf(_overview_active.to_string()),
                "bool:menu_open=%s".printf(_menu_open.to_string()),
                "bool:hidden_for_fullscreen=%s".printf(_hidden_for_fullscreen.to_string()),
                "bool:autohide=%s".printf(autohide.to_string()),
                "bool:intellihide=%s".printf(intellihide.to_string()),
                "int:current_margin=%d".printf(_current_margin),
                "int:last_dimension=%d".printf(_last_dimension),
                "str:visibility_mode=%s".printf(visibility_mode),
                "str:win_mapped=%s".printf(get_mapped().to_string()),
                "str:win_visible=%s".printf(get_visible().to_string()),
                "str:win_size=%dx%d".printf(get_width(), get_height()),
                "str:gls_margin=%d".printf(gls_margin),
                "str:excl_zone=%d".printf(excl),
                "str:layer=%s".printf(layer),
                "str:box_mapped=%s".printf(box_mapped),
                "str:box_size=%s".printf(box_size),
                "str:fps=%.1f".printf(fps)
            };
        }

        public void debug_set_var(string name, string value) {
            bool b = (value == "true" || value == "1");
            int iv = int.parse(value);
            switch (name) {
                case "hidden":                _hidden = b; update_autohide_state(); break;
                case "hovered":               _hovered = b; update_autohide_state(); break;
                case "overview_active":       _overview_active = b; update_autohide_state(); break;
                case "menu_open":             _menu_open = b; update_autohide_state(); break;
                case "hidden_for_fullscreen": _hidden_for_fullscreen = b; break;
                case "autohide":              autohide = b; update_autohide_state(); break;
                case "intellihide":           intellihide = b; update_autohide_state(); break;
                case "current_margin":
                    _current_margin = iv;
                    set_margin(this, _dock_edge(), iv);
                    queue_draw();
                    break;
                case "visibility_mode":       visibility_mode = value; update_visibility_mode(); break;
            }
        }

        public string[] debug_actions() {
            return { "force_show", "update_autohide_state", "present_redraw", "remap", "queue_resize" };
        }

        public void debug_run_action(string name) {
            switch (name) {
                case "force_show":
                    _hidden = false;
                    _hovered = false;
                    int gap = _settings.get_int("dock-gap");
                    _current_margin = gap;
                    present();
                    set_margin(this, _dock_edge(), gap);
                    set_exclusive_zone(this, int.max(0, _last_dimension - SHADOW_BOTTOM_PX));
                    queue_resize();
                    queue_draw();
                    break;
                case "update_autohide_state":
                    update_autohide_state();
                    break;
                case "present_redraw":
                    present();
                    queue_draw();
                    break;
                case "remap":
                    hide();
                    present();
                    queue_draw();
                    break;
                case "queue_resize":
                    queue_resize();
                    queue_draw();
                    break;
            }
        }

        private GtkLayerShell.Edge _dock_edge() {
            string pos = _settings.get_string("dock-position");
            if (pos == "left") return GtkLayerShell.Edge.LEFT;
            if (pos == "right") return GtkLayerShell.Edge.RIGHT;
            return GtkLayerShell.Edge.BOTTOM;
        }

        private bool is_any_window_maximized_on_my_monitor() {
            var display = Gdk.Display.get_default();
            var monitor = this.get_target_monitor() ?? find_shell_monitor();
            if (monitor == null && display != null && display.get_monitors().get_n_items() > 0)
                monitor = display.get_monitors().get_item(0) as Gdk.Monitor;
            bool single = (display == null) || (display.get_monitors().get_n_items() <= 1);
            string? target_conn = (monitor != null) ? monitor.get_connector() : null;
            Gdk.Monitor? primary = (display != null)
                ? display.get_monitors().get_item(0) as Gdk.Monitor : null;
            bool target_is_primary = (primary != null && monitor != null)
                && (primary == monitor || (target_conn != null && primary.get_connector() == target_conn));

            // Only windows on the active workspace AND on this dock's monitor
            // count: a maximized window on another workspace or another monitor
            // must not hide this dock.
            foreach (var win in app_system.get_active_workspace_windows()) {
                if (!win.is_maximized || win.is_minimized) continue;
                if (single || monitor == null) return true;
                var wmon = Singularity.wayland_get_window_monitor(win.handle);
                if (wmon == null) { if (target_is_primary) return true; continue; }
                if (wmon == monitor) return true;
                if (target_conn != null && wmon.get_connector() == target_conn) return true;
            }
            return false;
        }

        private void pulse_frame_clock() {
            var fc = get_frame_clock();
            if (fc == null) return;
            fc.begin_updating();
            GLib.Timeout.add(350, () => {
                var f = get_frame_clock();
                if (f != null) f.end_updating();
                return GLib.Source.REMOVE;
            });
        }

        private void animate_dock(bool hide) {
            if (_slide_timer_id != 0) {
                GLib.Source.remove(_slide_timer_id);
                _slide_timer_id = 0;
            }
            if (_fade_timer_id != 0) {
                GLib.Source.remove(_fade_timer_id);
                _fade_timer_id = 0;
            }

            int gap = _settings.get_int("dock-gap");
            GtkLayerShell.Edge edge = _dock_edge();
            int off = -(_last_dimension - 4);

            if (hide) {
                dock_box.remove_css_class("dock-reveal-offset");
                set_exclusive_zone(this, 0);
                if (edge == GtkLayerShell.Edge.BOTTOM) {
                    dock_box.add_css_class("dock-hiding");
                    _fade_timer_id = GLib.Timeout.add(260, () => {
                        _current_margin = off;
                        set_margin(this, edge, off);
                        _fade_timer_id = 0;
                        return GLib.Source.REMOVE;
                    });
                } else {
                    start_slide(edge, _current_margin, off);
                }
            } else {
                dock_box.remove_css_class("dock-hiding");
                // Revealing means we are not fullscreen-hidden; make sure the
                // surface is back on the OVERLAY layer. After leaving a
                // fullscreen video the dock could be left on BACKGROUND and
                // would otherwise slide in underneath a maximized window (#110).
                if (!_hidden_for_fullscreen) {
                    set_layer(this, GtkLayerShell.Layer.OVERLAY);
                }
                // Only the always-visible dock reserves work area. Autohide and
                // intellihide overlap windows instead, otherwise restoring a
                // minimized window makes it shrink to dodge a dock that is about
                // to hide, and the shrink persists (issue #79).
                bool reserve = !autohide && !intellihide;
                set_exclusive_zone(this, reserve ? int.max(0, _last_dimension - SHADOW_BOTTOM_PX) : 0);
                // Returning on-screen needs a fresh buffer; the idle frame clock
                // won't render one, so an unmap->map cycle at the visible margin
                // forces it (otherwise the surface comes back blank).
                // For the bottom dock, pull the surface down so the dock-box
                // bottom shadow (16px, reserved in the container margin) is not
                // clipped at the surface edge, keeping the dock near the edge.
                int rest_margin = (edge == GtkLayerShell.Edge.BOTTOM)
                    ? int.max(0, gap - 21) : gap;
                _current_margin = rest_margin;
                set_margin(this, edge, rest_margin);
                // Slide the content up from below: offset it down (no transition,
                // clipped out of the surface), remap, then drop the offset so the
                // CSS transform transition animates it into view. The frame clock
                // is live right after the remap (and we pulse it), so the content
                // transform is presented reliably without moving the surface.
                dock_box.add_css_class("dock-reveal-offset");
                ((Gtk.Widget) this).hide();
                present();
                start_content_slide();
            }
            pulse_frame_clock();
        }

        private void start_content_slide() {
            // Drop the offset a couple of frames after the remap so the transform
            // transition has an applied start state to animate from.
            _fade_timer_id = GLib.Timeout.add(32, () => {
                dock_box.remove_css_class("dock-reveal-offset");
                _fade_timer_id = 0;
                return GLib.Source.REMOVE;
            });
        }

        private void start_slide(GtkLayerShell.Edge edge, int start, int target) {
            _current_margin = start;
            set_margin(this, edge, start);
            int span = target - start;
            if (span == 0) return;
            int64 t0 = GLib.get_monotonic_time();
            int64 duration_us = 200000;
            _slide_timer_id = GLib.Timeout.add(16, () => {
                double t = (double)(GLib.get_monotonic_time() - t0) / (double)duration_us;
                if (t >= 1.0) {
                    _current_margin = target;
                    set_margin(this, edge, target);
                    _slide_timer_id = 0;
                    return GLib.Source.REMOVE;
                }
                double e = t * t * t;
                _current_margin = (int)(start + span * e);
                set_margin(this, edge, _current_margin);
                return GLib.Source.CONTINUE;
            });
        }

        // A dedicated thin layer-shell surface pinned to the dock's edge. A
        // slid-off dock receives no pointer events on this compositor, so this
        // always-on-screen strip is what catches the cursor to reveal the dock.
        private void _set_reveal_barrier_active(bool active) {
            if (!active) {
                if (_reveal_barrier != null) _reveal_barrier.set_visible(false);
                return;
            }
            var edge = _dock_edge();
            if (_reveal_barrier != null && _reveal_barrier_edge != edge) {
                _reveal_barrier.destroy();
                _reveal_barrier = null;
            }
            if (_reveal_barrier == null) {
                _reveal_barrier_edge = edge;
                var bar = new Gtk.Window();
                bar.application = this.application;
                bar.add_css_class("dock-reveal-barrier");
                GtkLayerShell.init_for_window(bar);
                var mon = get_target_monitor() ?? find_shell_monitor();
                if (mon != null) GtkLayerShell.set_monitor(bar, mon);
                GtkLayerShell.set_layer(bar, GtkLayerShell.Layer.TOP);
                GtkLayerShell.set_namespace(bar, "singularity-dock-reveal");
                GtkLayerShell.set_exclusive_zone(bar, 0);
                var content = new Box(Orientation.HORIZONTAL, 0);
                if (edge == GtkLayerShell.Edge.BOTTOM) {
                    GtkLayerShell.set_anchor(bar, GtkLayerShell.Edge.BOTTOM, true);
                    GtkLayerShell.set_anchor(bar, GtkLayerShell.Edge.LEFT, true);
                    GtkLayerShell.set_anchor(bar, GtkLayerShell.Edge.RIGHT, true);
                    content.set_size_request(-1, 2);
                } else {
                    GtkLayerShell.set_anchor(bar, edge, true);
                    GtkLayerShell.set_anchor(bar, GtkLayerShell.Edge.TOP, true);
                    GtkLayerShell.set_anchor(bar, GtkLayerShell.Edge.BOTTOM, true);
                    content.set_size_request(2, -1);
                }
                bar.set_child(content);
                var motion = new Gtk.EventControllerMotion();
                motion.enter.connect(() => {
                    if (_leave_timeout_id != 0) {
                        GLib.Source.remove(_leave_timeout_id);
                        _leave_timeout_id = 0;
                    }
                    _hovered = true;
                    _hover_start_us = GLib.get_monotonic_time();
                    update_autohide_state();
                });
                ((Gtk.Widget) bar).add_controller(motion);
                _reveal_barrier = bar;
            }
            _reveal_barrier.present();
        }

        private void update_visibility_mode() {
            if (!_enabled) {
                ((Gtk.Widget) this).hide();
                set_exclusive_zone(this, 0);
                app_system.shell_dock_height = 0;
                _set_reveal_barrier_active(false);
                return;
            }
            visibility_mode = _settings.get_string("dock-visibility-mode");

            if (panel_fusion) {
                visibility_mode = "always";
            }

            if (visibility_mode == "always") {
                present();
                // Re-trigger size_allocate to restore the correct exclusive zone
                queue_resize();
            } else if (visibility_mode == "overview-only") {
                hide();
                set_exclusive_zone(this, 0);
            }
            update_autohide_state();
        }

        // A window is fullscreen on THIS dock's monitor. Using the global
        // focused-fullscreen check made every monitor's dock hide when a video
        // went fullscreen on one monitor (#99/#100).
        private bool is_any_window_fullscreen_on_my_monitor() {
            var display = Gdk.Display.get_default();
            var monitor = this.get_target_monitor() ?? find_shell_monitor();
            if (monitor == null && display != null && display.get_monitors().get_n_items() > 0)
                monitor = display.get_monitors().get_item(0) as Gdk.Monitor;
            bool single = (display == null) || (display.get_monitors().get_n_items() <= 1);
            string? target_conn = (monitor != null) ? monitor.get_connector() : null;
            Gdk.Monitor? primary = (display != null)
                ? display.get_monitors().get_item(0) as Gdk.Monitor : null;
            bool target_is_primary = (primary != null && monitor != null)
                && (primary == monitor || (target_conn != null && primary.get_connector() == target_conn));
            foreach (var win in app_system.get_windows()) {
                if (!win.is_fullscreen || win.is_minimized) continue;
                if (single || monitor == null) return true;
                var wmon = Singularity.wayland_get_window_monitor(win.handle);
                if (wmon == null) { if (target_is_primary) return true; continue; }
                if (wmon == monitor) return true;
                if (target_conn != null && wmon.get_connector() == target_conn) return true;
            }
            return false;
        }

        private void update_fullscreen_mode() {
            bool fs = is_any_window_fullscreen_on_my_monitor();
            if (fs == _hidden_for_fullscreen) return;
            _hidden_for_fullscreen = fs;
            if (fs) {
                set_exclusive_zone(this, 0);
                set_layer(this, GtkLayerShell.Layer.BACKGROUND);
            } else {
                set_layer(this, GtkLayerShell.Layer.OVERLAY);
                // A layer change on an idle, occluded surface (e.g. a maximized
                // window covering it) is not composited until a frame is
                // committed, so closing a focused fullscreen window left the
                // dock buried. Remap to force a fresh buffer and present.
                ((Gtk.Widget) this).hide();
                present();
                update_visibility_mode();
                pulse_frame_clock();
            }
        }

        public void set_overview_mode(bool visible) {
            _overview_active = visible;
            if (visible) {
                dock_box.add_css_class("transparent");
            } else {
                dock_box.remove_css_class("transparent");
            }

            if (visibility_mode == "overview-only") {
                if (visible) present();
                else hide();
            }
            update_autohide_state();
        }

        private bool update_clock() {
            if (clock_label != null) {
                var now = new DateTime.now_local();
                clock_label.label = now.format(_("%H:%M"));
            }
            return true;
        }

        private void update_active_app(string? app_id) {
            Widget? child = dock_box.get_first_child();
            while (child != null) {
                // Dock items are wrapper Boxes that stash dock_button in data;
                // workspace/window buttons are direct Buttons.
                Gtk.Button? btn = child as Gtk.Button;
                string? btn_id = null;
                if (btn != null) {
                    btn_id = btn.get_data<string>("app_id");
                } else if (child is Gtk.Box) {
                    btn = (child as Gtk.Box).get_data<Gtk.Button>("dock_button");
                    btn_id = child.get_data<string>("app_id");
                }
                if (btn != null && btn_id != null) {
                    bool match = app_id != null && dock_matches(btn_id, app_id);
                    if (match) {
                        btn.add_css_class("active");
                        (child as Gtk.Box)?.add_css_class("active-wrapper");
                    } else {
                        btn.remove_css_class("active");
                        (child as Gtk.Box)?.remove_css_class("active-wrapper");
                    }
                }
                child = child.get_next_sibling();
            }
        }

        // Trigger the dock-pulse animation on the icon matching app_id.

        public void pulse_app_icon(string app_id) {
            Widget? child = dock_box.get_first_child();
            while (child != null) {
                string? wrapper_id = child.get_data<string>("app_id");
                if (wrapper_id != null && dock_matches(wrapper_id, app_id)) {
                    var wrapper = child as Gtk.Box;
                    if (wrapper != null) {
                        unowned Gtk.Box wrapper_weak = wrapper;
                        wrapper_weak.remove_css_class("launching");
                        GLib.Idle.add(() => {
                            if (wrapper_weak.get_parent() == null) return GLib.Source.REMOVE;
                            wrapper_weak.add_css_class("launching");
                            GLib.Timeout.add(750, () => {
                                wrapper_weak.remove_css_class("launching");
                                return GLib.Source.REMOVE;
                            });
                            return GLib.Source.REMOVE;
                        });
                    }
                    break;
                }
                child = child.get_next_sibling();
            }
        }

        private void update_active_window(void* handle) {
            Widget? child = dock_box.get_first_child();
            while (child != null) {
                void* btn_win_handle = child.get_data<void*>("win_handle");
                if (btn_win_handle != null) {
                    if (btn_win_handle == handle) child.add_css_class("active");
                    else child.remove_css_class("active");
                }
                child = child.get_next_sibling();
            }
        }

        private void schedule_refresh() {
            if (_refresh_timeout_id != 0) GLib.Source.remove(_refresh_timeout_id);
            _refresh_timeout_id = GLib.Timeout.add(150, () => {
                _refresh_timeout_id = 0;
                refresh();
                return GLib.Source.REMOVE;
            }, GLib.Priority.DEFAULT_IDLE);
        }

        private void force_rebuild() {
            _item_cache.clear();
            Widget? child = dock_box.get_first_child();
            while (child != null) {
                Widget next = child.get_next_sibling();
                dock_box.remove(child);
                child = next;
            }
            schedule_refresh();
        }

        private void register_item_extension(Singularity.DockItemExtension ext) {
            if (_item_extensions.contains(ext)) return;
            _item_extensions.add(ext);
            ulong h = ext.changed.connect((app_id) => {
                Widget? child = dock_box.get_first_child();
                while (child != null) {
                    string? wid = child.get_data<string>("app_id");
                    if (wid != null && (app_id == "" || dock_matches(wid, app_id))) {
                        var info = child.get_data<GLib.AppInfo?>("app_info_ref");
                        int sz = child.get_data<int>("icon_size");
                        apply_extensions_to_item(child, wid, info, sz > 0 ? sz : _settings.get_int("dock-icon-size"));
                    }
                    child = child.get_next_sibling();
                }
            });
            _item_extension_handlers[ext] = h;
            // Apply on existing items immediately.
            Widget? child = dock_box.get_first_child();
            while (child != null) {
                string? wid = child.get_data<string>("app_id");
                if (wid != null) {
                    var info = child.get_data<GLib.AppInfo?>("app_info_ref");
                    int sz = child.get_data<int>("icon_size");
                    apply_extensions_to_item(child, wid, info, sz > 0 ? sz : _settings.get_int("dock-icon-size"));
                }
                child = child.get_next_sibling();
            }
        }

        private void unregister_item_extension(Singularity.DockItemExtension ext) {
            if (!_item_extensions.contains(ext)) return;
            if (_item_extension_handlers.has_key(ext)) {
                GLib.SignalHandler.disconnect(ext, _item_extension_handlers[ext]);
                _item_extension_handlers.unset(ext);
            }
            _item_extensions.remove(ext);
            Widget? child = dock_box.get_first_child();
            while (child != null) {
                string? wid = child.get_data<string>("app_id");
                if (wid != null) {
                    var info = child.get_data<GLib.AppInfo?>("app_info_ref");
                    int sz = child.get_data<int>("icon_size");
                    apply_extensions_to_item(child, wid, info, sz > 0 ? sz : _settings.get_int("dock-icon-size"));
                }
                child = child.get_next_sibling();
            }
        }

        /**
         * (Re)build the icon and suffix-area of a dock item based on currently
         * registered DockItemExtensions and any DBus-pushed widgets. Idempotent.
         */
        private void apply_extensions_to_item(Gtk.Widget wrapper, string app_id, GLib.AppInfo? app_info, int icon_size) {
            var btn = wrapper.get_data<Button>("dock_button");
            var item_overlay = wrapper.get_data<Overlay>("item_overlay");
            var suffix_box = wrapper.get_data<Gtk.Box>("suffix_box");
            var suffix_revealer = wrapper.get_data<Gtk.Revealer>("suffix_revealer");
            if (btn == null || item_overlay == null || suffix_box == null || suffix_revealer == null) return;

            // Clear current overlay badges
            Widget? overlay_child = item_overlay.get_first_child();
            while (overlay_child != null) {
                Widget next = overlay_child.get_next_sibling();
                if (overlay_child != btn) item_overlay.remove_overlay(overlay_child);
                overlay_child = next;
            }
            // Clear suffix area
            Widget? sc = suffix_box.get_first_child();
            while (sc != null) {
                Widget snext = sc.get_next_sibling();
                suffix_box.remove(sc);
                sc = snext;
            }

            // Pick first matching extension for icon override and collect
            // all suffix widgets + icon overlays.
            Gdk.Paintable? icon_override = null;
            bool has_suffix = false;
            var icon_overlays = new Gee.ArrayList<Gtk.Widget>();
            foreach (var ext in _item_extensions) {
                if (!ext.matches(app_id)) continue;
                if (icon_override == null) icon_override = ext.get_icon_override(app_id);
                var w = ext.create_suffix_widget(app_id);
                if (w != null) {
                    if (is_dock_vertical()) flip_suffix_to_vertical(w);
                    suffix_box.append(w);
                    has_suffix = true;
                }
                var ov = ext.create_icon_overlay(app_id);
                if (ov != null) icon_overlays.add(ov);
            }

            if (icon_override != null) {
                // Use Gtk.Image (not Picture) so the paintable is rendered at
                // exactly icon_size - Picture's natural size = the texture's
                // natural size, which would blow up the dock.
                var cover = new Image.from_paintable(icon_override);
                cover.pixel_size = icon_size;
                cover.halign = Align.CENTER;
                cover.valign = Align.CENTER;
                cover.add_css_class("dock-mpris-icon-cover");
                cover.overflow = Overflow.HIDDEN;
                btn.set_child(cover);

                var app_badge = new Image();
                app_badge.pixel_size = 18;
                app_badge.halign = Align.END;
                app_badge.valign = Align.END;
                app_badge.can_target = false;
                app_badge.add_css_class("dock-mpris-app-badge");
                load_app_icon(app_badge, app_id, app_info);
                item_overlay.add_overlay(app_badge);
            } else {
                var img = new Image();
                img.pixel_size = icon_size;
                img.halign = Align.CENTER;
                img.valign = Align.CENTER;
                load_app_icon(img, app_id, app_info);
                btn.set_child(img);
            }

            // Icon overlays from plugins - small badges positioned at the
            // bottom-centre of the icon. Used by launcher-entry-dock for
            // unread counts so they don't take horizontal pill space.
            foreach (var ov in icon_overlays) {
                ov.halign = Align.CENTER;
                ov.valign = Align.END;
                ov.can_target = false;
                ov.add_css_class("dock-icon-badge");
                item_overlay.add_overlay(ov);
            }

            // Pill styling only when there's a suffix widget to show.
            var pill = wrapper.get_data<Gtk.Box>("pill");
            if (pill != null) {
                if (has_suffix) pill.add_css_class("has-suffix");
                else pill.remove_css_class("has-suffix");
                if (!has_suffix) pill.remove_css_class("expanded");
            }

            if (has_suffix && _kept_expanded.contains(app_id)) {
                if (pill != null) pill.add_css_class("expanded");
                suffix_revealer.reveal_child = true;
            } else if (!has_suffix) {
                suffix_revealer.reveal_child = false;
            }
        }

        public bool has_extension_for_app(string app_id) {
            foreach (var ext in _item_extensions) {
                if (ext.matches(app_id)) return true;
            }
            return false;
        }

        public void toggle_keep_expanded(string app_id) {
            if (_kept_expanded.contains(app_id)) _kept_expanded.remove(app_id);
            else _kept_expanded.add(app_id);
            string[] arr = {};
            foreach (string s in _kept_expanded) arr += s;
            _settings.set_strv("dock-pinned-suffixes", arr);
            // Refresh affected items
            Widget? child = dock_box.get_first_child();
            while (child != null) {
                string? wid = child.get_data<string>("app_id");
                if (wid != null && dock_matches(wid, app_id)) {
                    var info = child.get_data<GLib.AppInfo?>("app_info_ref");
                    int sz = child.get_data<int>("icon_size");
                    apply_extensions_to_item(child, wid, info, sz > 0 ? sz : _settings.get_int("dock-icon-size"));
                }
                child = child.get_next_sibling();
            }
        }

        private void refresh() {
            dismiss_window_previews();
            int icon_size = _settings.get_int("dock-icon-size");
            bool extended = _settings.get_boolean("dock-extended-mode") && (dock_style == "panel");

            // Full cache reset when structure-affecting _settings change
            if (icon_size != _cached_icon_size || extended != _cached_extended) {
                _cached_icon_size = icon_size;
                _cached_extended = extended;
                _item_cache.clear();
                Widget? c = dock_box.get_first_child();
                while (c != null) {
                    Widget nc = c.get_next_sibling();
                    dock_box.remove(c);
                    c = nc;
                }
                _expanded_count = 0;
                if (_dock_pinned) {
                    dock_box.margin_start = 0;
                    dock_box.halign = Align.CENTER;
                    _dock_pinned = false;
                }
            }

            string[] pinned = app_system.pinned_apps;

            // Build desired ordered item keys
            var desired_keys = new ArrayList<string>();
            // In fusion mode the activities button is rendered in start_area
            // by update_fusion(), so do NOT also add it to dock_box (would
            // duplicate). In non-fusion modes the activities button isn't
            // shown in the dock at all - the overview is reachable via
            // keyboard shortcut.
            desired_keys.add("__ws__");

            if (extended) {
                if (is_primary) {
                    foreach (var desktop_id in pinned) {
                        if (!app_system.is_app_running(desktop_id) && app_system.get_app_info(desktop_id) != null)
                            desired_keys.add("ext:" + desktop_id);
                    }
                }
                var windows = app_system.get_active_workspace_windows();
                if (is_primary && windows.length() > 0 && pinned.length > 0)
                    desired_keys.add("sep");
                foreach (var win in windows) {
                    if (!is_primary && gdk_monitor != null) {
                        var wmon = Singularity.wayland_get_window_monitor(win.handle);
                        if (wmon != gdk_monitor) continue;
                    }
                    desired_keys.add("win:" + win_handle_key(win));
                }
            } else {
                if (is_primary) {
                    // Unified pinned + resource section, interleaved per
                    // dock-order so apps and dropped resources can be
                    // reordered relative to each other.
                    foreach (var k in unified_pinned_order(pinned))
                        desired_keys.add(k);
                }
                var running = app_system.get_running_apps();
                // Cache monitor-visibility per app (avoids repeated wayland_get_window_monitor calls)
                var monitor_cache = new HashMap<string, bool>();
                foreach (var _aid in running)
                    monitor_cache[_aid] = is_primary
                        ? app_visible_on_primary(_aid, secondary_monitors)
                        : app_has_window_on_monitor(_aid);
                bool has_running = false;
                foreach (var app_id in running) {
                    if (is_primary) {
                        if (!app_system.is_pinned(app_id) && !is_covered_by_pinned(app_id, pinned)
                            && monitor_cache[app_id])
                            has_running = true;
                    } else {
                        if (monitor_cache[app_id])
                            has_running = true;
                    }
                }
                if (is_primary && has_running)
                    desired_keys.add("sep");
                foreach (var app_id in running) {
                    if (is_primary) {
                        if (!app_system.is_pinned(app_id) && !is_covered_by_pinned(app_id, pinned)
                            && monitor_cache[app_id])
                            desired_keys.add("run:" + app_id);
                    } else {
                        if (monitor_cache[app_id])
                            desired_keys.add("run:" + app_id);
                    }
                }
            }

            // Remove stale cached items
            var desired_set = new HashSet<string>();
            foreach (var k in desired_keys) desired_set.add(k);
            var stale = new ArrayList<string>();
            foreach (var k in _item_cache.keys)
                if (!desired_set.contains(k)) stale.add(k);
            foreach (var k in stale) {
                dock_box.remove(_item_cache[k]);
                _item_cache.unset(k);
            }

            // Create and append missing items
            foreach (var key in desired_keys) {
                if (!_item_cache.has_key(key)) {
                    var widget = create_item_for_key(key, pinned, icon_size);
                    if (widget != null) {
                        _item_cache[key] = widget;
                        dock_box.append(widget);
                    }
                }
            }

            // Reorder to match desired sequence
            Gtk.Widget? prev = null;
            foreach (var key in desired_keys) {
                if (_item_cache.has_key(key)) {
                    dock_box.reorder_child_after(_item_cache[key], prev);
                    prev = _item_cache[key];
                }
            }

            // Update win_count indicator dots in-place for standard mode items
            if (!extended) {
                foreach (var key in desired_keys) {
                    if (key.has_prefix("pin:") || key.has_prefix("run:")) {
                        string app_id = key.substring(4);
                        int win_count = count_app_windows(app_id);
                        if (_item_cache.has_key(key))
                            update_dock_item_indicators(_item_cache[key], win_count);
                    }
                }
            }

            update_active_app(app_system.get_focused_app_id());
            this.queue_resize();

            // First populated refresh: now that items exist, reveal the dock
            // with the slide-up bounce. We defer one frame so GTK has laid
            // out the new children before the animation starts.
            if (!_intro_played && is_primary) {
                _intro_played = true;
                GLib.Idle.add(() => {
                    main_container.opacity = 1.0;
                    main_container.add_css_class("dock-intro");
                    GLib.Timeout.add(620, () => {
                        main_container.remove_css_class("dock-intro");
                        return GLib.Source.REMOVE;
                    });
                    return GLib.Source.REMOVE;
                });
            }
        }

        private static string win_handle_key(Singularity.AppSystem.Window win) {
            return "%lu".printf((ulong) win.handle);
        }

        private void update_dock_item_indicators(Gtk.Widget wrapper, int win_count) {
            var indicator_row = wrapper.get_data<Gtk.Box>("indicator_row");
            if (indicator_row == null) return;
            Widget? dot = indicator_row.get_first_child();
            while (dot != null) {
                Widget nd = dot.get_next_sibling();
                indicator_row.remove(dot);
                dot = nd;
            }
            int dot_count = win_count > 0 ? int.min(win_count, 3) : 0;
            for (int i = 0; i < dot_count; i++) {
                var d = new Box(Orientation.HORIZONTAL, 0);
                d.add_css_class("dock-indicator-dot");
                d.valign = Align.CENTER;
                indicator_row.append(d);
            }
        }

        private void cancel_preview_dismiss() {
            if (_preview_dismiss_id != 0) {
                GLib.Source.remove(_preview_dismiss_id);
                _preview_dismiss_id = 0;
            }
        }

        private void schedule_preview_dismiss() {
            cancel_preview_dismiss();
            _preview_dismiss_id = GLib.Timeout.add(120, () => {
                _preview_dismiss_id = 0;
                dismiss_window_previews();
                return GLib.Source.REMOVE;
            });
        }

        private void cancel_preview_show() {
            if (_preview_show_id != 0) {
                GLib.Source.remove(_preview_show_id);
                _preview_show_id = 0;
            }
        }

        private void arm_preview_show(Gtk.Widget anchor, string app_id) {
            if (!_settings.get_boolean("dock-window-previews")) return;
            if (_preview_open && _preview_app_id != app_id) {
                dismiss_window_previews();
            } else if (_preview_open || _preview_show_id != 0) {
                return;
            }
            _preview_show_id = GLib.Timeout.add(350, () => {
                _preview_show_id = 0;
                show_window_previews(anchor, app_id);
                return GLib.Source.REMOVE;
            });
        }

        private void dismiss_window_previews() {
            cancel_preview_dismiss();
            cancel_preview_show();
            _preview_app_id = null;
            if (_preview_popover != null) {
                var pop = _preview_popover;
                _preview_popover = null;
                var rev = pop.get_child() as Gtk.Revealer;
                if (rev != null && rev.reveal_child) {
                    rev.reveal_child = false;
                    GLib.Timeout.add(rev.transition_duration, () => {
                        pop.popdown();
                        pop.unparent();
                        return GLib.Source.REMOVE;
                    });
                } else {
                    pop.popdown();
                    pop.unparent();
                }
            }
            if (_preview_open) {
                _preview_open = false;
                update_autohide_state();
            }
        }

        private Gtk.Widget build_preview_tile(AppSystem.Window win) {
            void* h = win.handle;
            var overlay = new Gtk.Overlay();
            overlay.add_css_class("dock-window-preview");
            overlay.set_size_request(160, 100);

            var pic = new Gtk.Picture();
            pic.content_fit = Gtk.ContentFit.CONTAIN;
            overlay.set_child(pic);

            if (h != null) {
                PreviewCache.get_default().request(h, 160, 100, (tex) => {
                    if (tex == null) return;
                    var pb = Gdk.pixbuf_get_from_texture(tex);
                    if (pb == null) { pic.paintable = tex; return; }
                    double sc = double.min(160.0 / pb.width, 100.0 / pb.height);
                    if (sc > 1.0) sc = 1.0;
                    int nw = int.max(1, (int)(pb.width * sc));
                    int nh = int.max(1, (int)(pb.height * sc));
                    var sp = pb.scale_simple(nw, nh, Gdk.InterpType.BILINEAR);
                    pic.paintable = (sp != null) ? Gdk.Texture.for_pixbuf(sp) : tex;
                });
            }

            var title = new Gtk.Label(win.title != null && win.title != "" ? win.title : win.app_id);
            title.add_css_class("dock-window-preview-title");
            title.ellipsize = Pango.EllipsizeMode.END;
            title.halign = Align.START;
            title.valign = Align.END;
            title.max_width_chars = 18;
            overlay.add_overlay(title);

            var close = new Singularity.Widgets.CircularButton("window-close-symbolic", _("Close"), 12);
            close.halign = Align.END;
            close.valign = Align.START;
            close.margin_top = 4;
            close.margin_end = 4;
            close.clicked.connect(() => {
                if (h != null) Singularity.close_window(h);
                GLib.Idle.add(() => {
                    dismiss_window_previews();
                    return GLib.Source.REMOVE;
                });
            });
            overlay.add_overlay(close);

            var click = new Gtk.GestureClick();
            click.pressed.connect(() => {
                if (h != null) Singularity.wayland_activate_window(h);
                dismiss_window_previews();
            });
            pic.add_controller(click);

            return overlay;
        }

        private void show_window_previews(Gtk.Widget anchor, string app_id) {
            if (_menu_open) return;
            var wins = new Gee.ArrayList<AppSystem.Window>();
            foreach (var win in app_system.get_windows()) {
                if (win.app_id != null && dock_matches(app_id, win.app_id)) wins.add(win);
            }
            if (wins.size < 2) return;

            dismiss_window_previews();

            var pop = new Gtk.Popover();
            pop.autohide = false;
            pop.has_arrow = false;
            pop.add_css_class("dock-window-previews");
            var edge = _dock_edge();
            pop.position = (edge == GtkLayerShell.Edge.LEFT) ? Gtk.PositionType.RIGHT
                : (edge == GtkLayerShell.Edge.RIGHT) ? Gtk.PositionType.LEFT
                : Gtk.PositionType.TOP;

            var row = new Gtk.Box(Orientation.HORIZONTAL, 8);
            row.add_css_class("dock-window-previews-row");
            foreach (var win in wins) row.append(build_preview_tile(win));

            var revealer = new Gtk.Revealer();
            revealer.transition_duration = 160;
            revealer.transition_type = (edge == GtkLayerShell.Edge.LEFT) ? Gtk.RevealerTransitionType.SLIDE_RIGHT
                : (edge == GtkLayerShell.Edge.RIGHT) ? Gtk.RevealerTransitionType.SLIDE_LEFT
                : (edge == GtkLayerShell.Edge.TOP) ? Gtk.RevealerTransitionType.SLIDE_DOWN
                : Gtk.RevealerTransitionType.SLIDE_UP;
            revealer.reveal_child = false;
            revealer.set_child(row);
            pop.set_child(revealer);

            var pm = new Gtk.EventControllerMotion();
            pm.enter.connect((x, y) => cancel_preview_dismiss());
            pm.leave.connect(() => schedule_preview_dismiss());
            ((Gtk.Widget) pop).add_controller(pm);

            pop.set_parent(anchor);
            _preview_popover = pop;
            _preview_open = true;
            _preview_app_id = app_id;
            update_autohide_state();
            pop.popup();
            GLib.Idle.add(() => {
                if (_preview_popover == pop) revealer.reveal_child = true;
                return GLib.Source.REMOVE;
            });
        }

        /** True when the dock is on the left or right edge (vertical layout). */
        private bool is_dock_vertical() {
            return dock_box.orientation == Orientation.VERTICAL;
        }

        // Plugin suffix widgets are authored as horizontal Gtk.Box rows
        // (icon, icon, icon). When the dock flips to vertical we recursively
        // re-orient any contained Gtk.Box so the row stacks top-to-bottom
        // instead of left-to-right. The plugin ABI stays unchanged.
        private void flip_suffix_to_vertical(Gtk.Widget w) {
            var b = w as Gtk.Box;
            if (b != null) b.orientation = Orientation.VERTICAL;
            for (var c = w.get_first_child(); c != null; c = c.get_next_sibling())
                flip_suffix_to_vertical(c);
        }

        /**
         * Build the outer geometry of a "shell" item. The pill axis follows
         * the dock axis so the suffix expands ALONG the dock (rightward on
         * bottom, downward on left/right) - items stay in their column /
         * row without forcing the dock perpendicular dimension to grow.
         */
        private void build_shell_geometry(out Gtk.Box wrapper, out Gtk.Box pill, int icon_size) {
            bool vertical = is_dock_vertical();
            wrapper = new Gtk.Box(Orientation.VERTICAL, 0);
            wrapper.add_css_class("dock-item-wrapper");

            pill = new Gtk.Box(vertical ? Orientation.VERTICAL : Orientation.HORIZONTAL, 0);
            pill.add_css_class("dock-item-pill");
            pill.halign = Align.CENTER;
            wrapper.append(pill);

            var indicator_row = new Gtk.Box(Orientation.HORIZONTAL, 3);
            indicator_row.halign = Align.CENTER;
            indicator_row.add_css_class("dock-indicator-row");
            wrapper.append(indicator_row);
        }

        private Gtk.Widget? create_item_for_key(string key, string[] pinned, int icon_size) {
            if (key == "__activities__") {
                Gtk.Box wrapper, pill;
                build_shell_geometry(out wrapper, out pill, icon_size);
                var btn = new Button();
                btn.add_css_class("dock-item");
                btn.add_css_class("start-button");
                btn.has_frame = false;
                btn.set_size_request(icon_size + 4, icon_size + 4);
                var icon_theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
                var logo = new Image.from_icon_name(
                    icon_theme.has_icon("emblem-singularity")
                        ? "emblem-singularity"
                        : "view-app-grid-symbolic");
                logo.pixel_size = icon_size;
                btn.set_child(logo);
                btn.clicked.connect(() => { activities_clicked(); });
                pill.append(btn);
                return wrapper;
            }
            if (key == "__ws__") {
                Gtk.Box wrapper, pill;
                build_shell_geometry(out wrapper, out pill, icon_size);
                var btn = new Button();
                btn.add_css_class("dock-item");
                btn.add_css_class("workspace-button");
                btn.has_frame = false;
                btn.set_size_request(icon_size + 4, icon_size + 4);
                var ws_icon = new Image.from_icon_name("dev.sinty.workspaces");
                ws_icon.pixel_size = icon_size;
                btn.set_child(ws_icon);
                var sc_ws = SystemMonitor.get_default().shortcuts;
                btn.tooltip_text = format_dock_tooltip(_("Workspaces"), sc_ws, "toggle_workspace_overview");
                sc_ws.shortcut_changed.connect((action, accel) => {
                    if (action == "toggle_workspace_overview")
                        btn.tooltip_text = format_dock_tooltip(_("Workspaces"), sc_ws, "toggle_workspace_overview");
                });
                btn.clicked.connect(() => { workspace_clicked(); });
                pill.append(btn);
                return wrapper;
            }
            if (key == "sep" || key == "ressep") {
                var sep = new Box(Orientation.VERTICAL, 0);
                sep.add_css_class("dock-separator");
                return sep;
            }
            if (key.has_prefix("res:")) {
                string uri = key.substring(4);
                return create_resource_item(uri, icon_size);
            }
            if (key.has_prefix("pin:")) {
                string app_id = key.substring(4);
                var app_info = app_system.get_app_info(app_id);
                int win_count = count_app_windows(app_id);
                return create_dock_item(app_id, app_info, win_count, true, icon_size);
            }
            if (key.has_prefix("run:")) {
                string app_id = key.substring(4);
                var app_info = app_system.resolve_app_for_id(app_id);
                int win_count = count_app_windows(app_id);
                return create_dock_item(app_id, app_info, win_count, false, icon_size);
            }
            if (key.has_prefix("ext:")) {
                string app_id = key.substring(4);
                var app_info = app_system.get_app_info(app_id);
                if (app_info != null) return create_app_button(app_info, icon_size, true);
                return null;
            }
            if (key.has_prefix("win:")) {
                ulong h = ulong.parse(key.substring(4));
                foreach (var win in app_system.get_active_workspace_windows())
                    if ((ulong) win.handle == h) return create_window_button(win, icon_size);
                return null;
            }
            return null;
        }

        // --- dock item with running indicator and context menu ---

        private static string strip_desktop(string id) {
            string s = id.down();
            if (s.has_suffix(".desktop")) return s[0:s.length - 8];
            return s;
        }

        // Safe single-char replacement (avoids string.replace() crash on this GLib version)

        private static string replace_char(string s, char from, char to) {
            var sb = new StringBuilder();
            for (int i = 0; i < s.length; i++) {
                sb.append_c(s[i] == from ? to : s[i]);
            }
            return sb.str;
        }

        // Normalized match: handles org.X.app <-> x-app.desktop, StartupWMClass, etc.

        private bool dock_matches(string? id_a, string? id_b) {
            if (id_a == null || id_b == null || id_a.length < 2 || id_b.length < 2) return false;
            // Basic sanity: reject strings with non-printable chars (garbage memory)
            for (int i = 0; i < int.min(id_a.length, 64); i++)
                if (id_a[i] < 0x20) return false;
            for (int i = 0; i < int.min(id_b.length, 64); i++)
                if (id_b[i] < 0x20) return false;
            if (id_a == id_b) return true;
            string a = strip_desktop(id_a);
            string b = strip_desktop(id_b);
            if (a == b) return true;
            if (a.has_suffix("." + b) || b.has_suffix("." + a)) return true;
            string an = replace_char(replace_char(a, '-', '.'), '_', '.');
            string bn = replace_char(replace_char(b, '-', '.'), '_', '.');
            if (an == bn) return true;
            if (an.has_suffix("." + bn) || bn.has_suffix("." + an)) return true;
            // StartupWMClass - the standard desktop-entry way
            var dinfo_a = app_system.resolve_app_for_id(id_a) as GLib.DesktopAppInfo;
            if (dinfo_a != null) {
                string? wm = dinfo_a.get_startup_wm_class();
                if (wm != null && wm.down() == b) return true;
            }
            var dinfo_b = app_system.resolve_app_for_id(id_b) as GLib.DesktopAppInfo;
            if (dinfo_b != null) {
                string? wm = dinfo_b.get_startup_wm_class();
                if (wm != null && wm.down() == a) return true;
            }
            return false;
        }

        private int count_app_windows(string app_id) {
            int n = 0;
            foreach (var win in app_system.get_windows()) {
                if (win.app_id != null && dock_matches(app_id, win.app_id)) n++;
            }
            if (n == 0) {
                foreach (var running_id in app_system.get_running_apps()) {
                    if (dock_matches(app_id, running_id)) return 1;
                }
            }
            return n;
        }

        // Returns the handle of the first window matching app_id, null if none

        private void* get_window_handle_for_app(string app_id) {
            foreach (var win in app_system.get_windows()) {
                if (dock_matches(win.app_id, app_id)) return win.handle;
            }
            return null;
        }

        // True if running_id is already represented by any pinned app

        private bool is_covered_by_pinned(string running_id, string[] pinned) {
            foreach (var pinned_id in pinned) {
                if (dock_matches(pinned_id, running_id)) return true;
            }
            return false;
        }

        // First running window matching app_id, so the dock can reuse the icon
        // and title already resolved on the Window object (the same data the
        // alt-tab switcher uses), instead of resolving only from the desktop
        // entry and missing it for apps like Minecraft or Bitwig (#159, #161).
        private AppSystem.Window? find_window_for(string app_id) {
            foreach (var win in app_system.get_windows()) {
                if (win.app_id == app_id || dock_matches(app_id, win.app_id)) return win;
            }
            return null;
        }

        private void load_app_icon(Gtk.Image img, string app_id, GLib.AppInfo? app_info,
                                   AppSystem.Window? win = null) {
            var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
            if (app_info != null) {
                var icon = app_info.get_icon();
                if (icon is ThemedIcon) {
                    foreach (var name in ((ThemedIcon)icon).get_names()) {
                        if (theme.has_icon(name)) { img.icon_name = name; return; }
                    }
                } else if (icon != null) {
                    img.set_from_gicon(icon); return;
                }
            }
            string lower = strip_desktop(app_id);
            if (theme.has_icon(lower)) { img.icon_name = lower; return; }
            // Running window: reuse the icon the switcher already resolved,
            // including the window's own gicon and its title for the XWayland
            // _NET_WM_ICON lookup, before falling back to the generic gear.
            if (win != null) {
                if (win.gicon != null) { img.set_from_gicon(win.gicon); return; }
                string[] cands = {};
                if (win.icon_name != null && win.icon_name != "") cands += win.icon_name;
                if (win.app_id != null && win.app_id != "") {
                    cands += win.app_id;
                    cands += win.app_id.down();
                    int dot = win.app_id.last_index_of(".");
                    if (dot >= 0 && dot + 1 < win.app_id.length)
                        cands += win.app_id.substring(dot + 1).down();
                }
                foreach (string c in cands)
                    if (theme.has_icon(c)) { img.icon_name = c; return; }
                var wtex = Singularity.xwayland_icon(win.app_id, win.title);
                if (wtex != null) { img.set_from_paintable(wtex); return; }
            }
            // XWayland apps (games, Wine, Discord) carry their icon in
            // _NET_WM_ICON; use it before the generic placeholder (#93).
            var tex = Singularity.xwayland_icon(app_id, null);
            if (tex != null) { img.set_from_paintable(tex); return; }
            img.icon_name = "application-x-executable";
        }

        private void show_app_context_menu(Widget parent, string app_id, GLib.AppInfo? app_info,
                                            int win_count, bool is_pinned_app, bool shift_held = false) {
            bool is_running = win_count > 0;
            string display_name = app_info != null ? app_info.get_display_name() : app_id;
            var menu = new Singularity.Widgets.ContextMenu(parent);
            menu.position = Gtk.PositionType.TOP;
            menu.notify["visible"].connect(() => {
                if (!menu.visible) {
                    _menu_open = false;
                    update_autohide_state();
                }
            });
            _menu_open = true;
            update_autohide_state();

            // "Keep expanded" toggle for items with a suffix widget extension active
            if (has_extension_for_app(app_id)) {
                bool kept = _kept_expanded.contains(app_id);
                menu.add_item(kept ? "Auto-hide widget" : "Keep widget expanded",
                              kept ? "view-restore-symbolic" : "view-fullscreen-symbolic", () => {
                    toggle_keep_expanded(app_id);
                });
                menu.add_separator();
            }

            // Plugin-provided context menu items
            var request = new Singularity.DockContextMenuRequest(
                app_id, display_name, is_running, is_pinned_app, win_count);
            bool plugin_added = false;
            foreach (var provider in _menu_providers) {
                if (provider.populate_context_menu(menu, request))
                    plugin_added = true;
            }
            if (plugin_added) menu.add_separator();

            if (!is_running) {
                menu.add_item("Open", "system-run-symbolic", () => {
                    if (app_info != null) AppSystem.launch_app(app_info);
                });
            } else {
                menu.add_item("New Window", "window-new-symbolic", () => {
                    if (app_info == null) return;
                    if (!launch_new_window_action(app_info))
                        AppSystem.launch_app(app_info);
                });
                var dai = app_info as DesktopAppInfo;
                if (dai != null) {
                    string[] actions = dai.list_actions();
                    foreach (string action_id in actions) {
                        string captured_id = action_id.dup();
                        string action_name = dai.get_action_name(captured_id);
                        if (action_name.down().contains("new window")) continue;
                        menu.add_item(action_name, "go-next-symbolic", () => {
                            dai.launch_action(captured_id, Gdk.Display.get_default().get_app_launch_context());
                        });
                    }
                }
            }

            menu.add_separator();

            if (is_pinned_app) {
                menu.add_item("Remove from Dock", "list-remove-symbolic", () => {
                    app_system.unpin_app(app_id);
                });
            } else if (is_running) {
                menu.add_item("Keep in Dock", "starred-symbolic", () => {
                    app_system.pin_app(app_id);
                });
            }

            if (is_running) {
                menu.add_separator();
                menu.add_item("Quit", "application-exit-symbolic", () => {
                    // Close this app's own windows, not whatever is focused.
                    foreach (var win in app_system.get_windows()) {
                        if (dock_matches(win.app_id, app_id))
                            Singularity.close_window(win.handle);
                    }
                });
                // Shift-held variant: expose a destructive "Force Kill" entry
                // at the bottom. Red styling makes the intent clear. We send
                // SIGKILL to all processes whose argv[0] basename matches the
                // app id - pkill is a portable way to do that without needing
                // a per-window PID lookup we don't have on wayland.
                if (shift_held) {
                    menu.add_separator();
                    string kill_target = compute_kill_target(app_id, app_info);
                    menu.add_item("Force Kill", "process-stop-symbolic", () => {
                        force_kill_app(app_id, kill_target);
                    }, "destructive-action");
                }
            }
            menu.popup();
        }

        private bool launch_new_window_action(GLib.AppInfo app_info) {
            var dai = app_info as DesktopAppInfo;
            if (dai == null) return false;
            foreach (string aid in dai.list_actions()) {
                string an = dai.get_action_name(aid).down();
                if (an.contains("new window") || aid.down().contains("new-window")) {
                    dai.launch_action(aid, Gdk.Display.get_default().get_app_launch_context());
                    return true;
                }
            }
            return false;
        }

        /**
         * Best-effort process name to pass to `pkill -KILL -f`. We try, in
         * order: the app's Exec basename, the StartupWMClass, the desktop
         * id basename. The user explicitly triggered Force Kill via Shift -
         * a false positive here is on them.
         */
        private string compute_kill_target(string app_id, GLib.AppInfo? app_info) {
            var dai = app_info as DesktopAppInfo;
            if (dai != null) {
                string? wm = dai.get_startup_wm_class();
                if (wm != null && wm.length > 0) return wm;
                string? exec = dai.get_executable();
                if (exec != null && exec.length > 0) {
                    int slash = exec.last_index_of_char('/');
                    return slash >= 0 ? exec.substring(slash + 1) : exec;
                }
            }
            string id = app_id;
            if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
            int dot = id.last_index_of_char('.');
            return dot >= 0 ? id.substring(dot + 1) : id;
        }

        private void force_kill_app(string app_id, string kill_target) {
            warning("dock force_kill_app: app_id='%s' target='%s'", app_id, kill_target);
            // Try graceful close first on all known windows of this app,
            // then SIGKILL anything that survived after a beat.
            foreach (var win in app_system.get_windows()) {
                if (dock_matches(win.app_id, app_id))
                    Singularity.close_window(win.handle);
            }
            GLib.Timeout.add(800, () => {
                _force_kill_now(kill_target);
                // Also try the bare app_id basename in case the .desktop
                // didn't expose StartupWMClass/Exec accurately.
                string id_short = app_id;
                if (id_short.has_suffix(".desktop"))
                    id_short = id_short.substring(0, id_short.length - 8);
                int dot = id_short.last_index_of_char('.');
                if (dot >= 0) id_short = id_short.substring(dot + 1);
                if (id_short != kill_target) _force_kill_now(id_short);
                return GLib.Source.REMOVE;
            });
        }

        private void _force_kill_now(string target) {
            // Use `pkill -9 -f` which matches the whole command line. We
            // run via /bin/sh -c so we still work even on minimal PATH.
            string cmd = "/bin/sh -c " + GLib.Shell.quote(
                "pkill -9 -f " + GLib.Shell.quote(target) +
                " || killall -9 " + GLib.Shell.quote(target) +
                " || true");
            try {
                int exit = -1;
                GLib.Process.spawn_command_line_sync(cmd, null, null, out exit);
                warning("dock force_kill: '%s' exit=%d", target, exit);
            } catch (Error e) {
                warning("dock force_kill spawn failed: %s", e.message);
            }
        }

        // A dropped resource rendered as a dock item - identical pill
        // geometry, hover and click behaviour to an app icon (no special
        // bounce / styling), just a different icon and click action.
        private Gtk.Widget create_resource_item(string uri, int icon_size) {
            Gtk.Box wrapper, pill;
            build_shell_geometry(out wrapper, out pill, icon_size);
            wrapper.set_data<string>("res_uri", uri);

            var btn = new Button();
            btn.add_css_class("dock-item");
            btn.has_frame = false;
            btn.set_size_request(icon_size + 4, icon_size + 4);
            btn.tooltip_text = resources_area.tooltip_for(uri);

            var visual = resources_area.make_visual(uri, icon_size);
            visual.halign = Align.CENTER;
            visual.valign = Align.CENTER;
            btn.set_child(visual);

            btn.clicked.connect(() => resources_area.activate(uri, btn));

            var rc = new GestureClick();
            rc.button = Gdk.BUTTON_SECONDARY;
            unowned Button btn_weak = btn;
            rc.pressed.connect((n, x, y) => {
                resources_area.show_menu(uri, btn_weak, x, y);
            });
            btn.add_controller(rc);

            // Drag source to reorder among resources / apps.
            var drag = new DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            string captured = "res:" + uri;
            unowned Button vis_weak = btn;
            drag.prepare.connect((x, y) => new Gdk.ContentProvider.for_value(captured));
            drag.drag_begin.connect((d) => {
                var snap = snapshot_paintable(vis_weak);
                if (snap != null)
                    drag.set_icon(snap, vis_weak.get_width() / 2, vis_weak.get_height() / 2);
            });
            btn.add_controller(drag);

            pill.append(btn);
            return wrapper;
        }

        private Gtk.Box create_dock_item(string app_id, GLib.AppInfo? app_info, int win_count, bool is_pinned_app, int icon_size) {
            bool is_running = win_count > 0;
            AppSystem.Window? rep_win = is_running ? find_window_for(app_id) : null;
            string display_name = app_info != null
                ? app_info.get_display_name()
                : (rep_win != null && rep_win.title != null && rep_win.title != "" ? rep_win.title : app_id);

            // Pill axis follows the dock axis: horizontal on bottom dock
            // (icon | suffix), vertical on left/right dock (icon stacked
            // above the suffix). The wrapper stays VERTICAL in both cases
            // because the running-indicator dots always go below the pill.
            bool vertical = is_dock_vertical();
            var wrapper = new Gtk.Box(Orientation.VERTICAL, 0);
            wrapper.set_data("app_id", app_id.dup());
            wrapper.add_css_class("dock-item-wrapper");

            var pill = new Gtk.Box(vertical ? Orientation.VERTICAL : Orientation.HORIZONTAL, 0);
            pill.add_css_class("dock-item-pill");
            pill.halign = Align.CENTER;
            wrapper.append(pill);
            wrapper.set_data("pill", pill);

            var btn = new Button();
            btn.add_css_class("dock-item");
            btn.has_frame = false;
            btn.set_data("app_id", app_id.dup());
            btn.set_size_request(icon_size + 4, icon_size + 4);
            btn.tooltip_text = display_name;

            var img = new Image();
            img.pixel_size = icon_size;
            img.halign = Align.CENTER;
            img.valign = Align.CENTER;
            load_app_icon(img, app_id, app_info, rep_win);
            btn.set_child(img);

            var item_overlay = new Overlay();
            item_overlay.set_child(btn);
            pill.append(item_overlay);

            wrapper.set_data("dock_button", btn);
            wrapper.set_data("item_overlay", item_overlay);
            wrapper.set_data("app_info_ref", app_info);
            wrapper.set_data<int>("icon_size", icon_size);

            // Suffix revealer - slide direction matches the pill axis:
            // bottom dock -> slide-right, side dock -> slide-down.
            var suffix_revealer = new Gtk.Revealer();
            suffix_revealer.transition_type = vertical
                ? Gtk.RevealerTransitionType.SLIDE_DOWN
                : Gtk.RevealerTransitionType.SLIDE_RIGHT;
            suffix_revealer.transition_duration = 200;
            suffix_revealer.reveal_child = false;
            var suffix_box = new Gtk.Box(
                vertical ? Orientation.VERTICAL : Orientation.HORIZONTAL, 4);
            suffix_box.add_css_class("dock-suffix-area");
            suffix_box.halign = vertical ? Align.CENTER : Align.START;
            suffix_box.valign = vertical ? Align.START  : Align.CENTER;
            suffix_revealer.set_child(suffix_box);
            pill.append(suffix_revealer);
            wrapper.set_data("suffix_revealer", suffix_revealer);
            wrapper.set_data("suffix_box", suffix_box);

            // Indicator dots beneath the pill - wrapper is VERTICAL even
            // when the dock is on the side.
            var indicator_row = new Box(Orientation.HORIZONTAL, 3);
            indicator_row.halign = Align.CENTER;
            indicator_row.add_css_class("dock-indicator-row");
            int dot_count = is_running ? int.min(win_count, 3) : 0;
            for (int i = 0; i < dot_count; i++) {
                var dot = new Box(Orientation.HORIZONTAL, 0);
                dot.add_css_class("dock-indicator-dot");
                indicator_row.append(dot);
            }
            wrapper.append(indicator_row);

            // Hover handled on the pill so the dot row never expands the suffix.
            var hover = new Gtk.EventControllerMotion();
            unowned Gtk.Box pill_weak = pill;
            unowned Gtk.Revealer rev_weak = suffix_revealer;
            hover.enter.connect(() => {
                if (suffix_box.get_first_child() != null && !rev_weak.reveal_child) {
                    pin_expansion();
                    pill_weak.add_css_class("expanded");
                    rev_weak.reveal_child = true;
                }
                cancel_preview_dismiss();
                arm_preview_show(pill_weak, app_id);
            });
            hover.motion.connect((x, y) => {
                cancel_preview_dismiss();
                arm_preview_show(pill_weak, app_id);
            });
            hover.leave.connect(() => {
                if (!_kept_expanded.contains(app_id) && rev_weak.reveal_child) {
                    pill_weak.remove_css_class("expanded");
                    rev_weak.reveal_child = false;
                    unpin_expansion();
                }
                cancel_preview_show();
                if (_preview_popover != null) schedule_preview_dismiss();
            });
            pill.add_controller(hover);

            // No surface-recenter workaround needed: the dock window is
            // anchored on all perpendicular edges, so growing/shrinking the
            // pill only re-layouts dock_box (halign=CENTER) within the
            // stable full-width surface.

            // Apply current extension state
            apply_extensions_to_item(wrapper, app_id, app_info, icon_size);

            // Click: minimize if app is active/focused, raise if running, launch if not
            unowned Gtk.Box wrapper_weak = wrapper;
            unowned Button btn_weak = btn;
            btn.clicked.connect(() => {
                var app_wins = new Gee.ArrayList<AppSystem.Window>();
                foreach (var w in app_system.get_windows())
                    if (w.app_id != null && dock_matches(app_id, w.app_id)) app_wins.add(w);

                if (app_wins.size > 1) {
                    var focused = app_system.get_focused_window_handle();
                    int cur = -1;
                    for (int i = 0; i < app_wins.size; i++)
                        if (app_wins[i].handle == focused) { cur = i; break; }
                    Singularity.wayland_activate_window(app_wins[(cur + 1) % app_wins.size].handle);
                    return;
                }

                void* handle = get_window_handle_for_app(app_id);
                if (handle != null) {
                    var focused = app_system.get_focused_window_handle();
                    var win = app_system.get_window_by_handle(handle);
                    bool minimized = win != null && win.is_minimized;
                    if (focused == handle && !minimized) {
                        Singularity.minimize_window(handle);
                    } else {
                        Singularity.wayland_activate_window(handle);
                    }
                } else if (app_info != null) {
                    AppSystem.launch_app(app_info);
                    wrapper_weak.add_css_class("launching");
                    GLib.Timeout.add(750, () => {
                        if (wrapper_weak.get_parent() != null)
                            wrapper_weak.remove_css_class("launching");
                        return GLib.Source.REMOVE;
                    });
                }
            });

            // Right-click context menu - recompute win_count live.
            // Holding Shift while right-clicking exposes destructive actions
            // (Force Kill) - the gesture's current_event_state lets us peek
            // at the modifier without a separate controller.
            var right_click = new GestureClick();
            right_click.button = Gdk.BUTTON_SECONDARY;
            unowned GestureClick rc_weak = right_click;
            right_click.pressed.connect((n, x, y) => {
                dismiss_window_previews();
                int current_win_count = count_app_windows(app_id);
                bool shift = (rc_weak.get_current_event_state() & Gdk.ModifierType.SHIFT_MASK) != 0;
                show_app_context_menu(btn_weak, app_id, app_info, current_win_count, is_pinned_app, shift);
            });
            btn.add_controller(right_click);

            // Drag source for reordering pinned apps
            var drag_source = new DragSource();
            drag_source.set_actions(Gdk.DragAction.MOVE);
            unowned DragSource ds_weak = drag_source;
            drag_source.prepare.connect((x, y) => {
                return new Gdk.ContentProvider.for_value(app_id);
            });
            unowned Button icon_btn_weak = btn;
            drag_source.drag_begin.connect((drag) => {
                // Drag the actual icon (a snapshot of the dock button), not
                // the GTK default which renders the string value as text.
                var snap = snapshot_paintable(icon_btn_weak);
                if (snap != null) {
                    ds_weak.set_icon(snap, icon_btn_weak.get_width() / 2,
                                     icon_btn_weak.get_height() / 2);
                } else if (app_info != null) {
                    var icon = app_info.get_icon();
                    if (icon is ThemedIcon) {
                        var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
                        var names = ((ThemedIcon)icon).get_names();
                        if (names.length > 0) {
                            var paintable = theme.lookup_icon(names[0], null, icon_size, 1, TextDirection.NONE, 0);
                            if (paintable != null) ds_weak.set_icon(paintable, 0, 0);
                        }
                    }
                }
            });
            wrapper.add_controller(drag_source);
            wrapper.set_data("indicator_row", indicator_row);

            return wrapper;
        }

        private Button create_window_button(Singularity.AppSystem.Window win, int icon_size) {
            var btn = new Button();
            btn.add_css_class("dock-item");
            btn.add_css_class("dock-item-extended");
            btn.has_frame = false;
            btn.set_data("win_handle", win.handle);
            btn.set_data("app_id", win.app_id);

            var box = new Box(Orientation.HORIZONTAL, 8);
            box.valign = Align.CENTER;

            // Resolve the AppInfo for the window's app_id so we can fall back
            // to its themed icon + display name when the Wayland surface
            // didn't expose a usable gicon (Chromium apps) or when title still
            // holds the raw app_id (e.g. "dev.sinty.leafs" before the window
            // sets its title).
            var app_info = app_system.get_app_info(win.app_id);

            var img = new Image();
            img.pixel_size = icon_size;
            if (win.gicon != null) {
                img.set_from_gicon(win.gicon);
            } else if (app_info != null) {
                load_app_icon(img, win.app_id, app_info);
            } else if (win.icon_name != null && win.icon_name.length > 0) {
                img.set_from_icon_name(win.icon_name);
            } else {
                img.icon_name = "application-x-executable";
            }
            box.append(img);

            string title = win.title;
            bool title_is_raw_id =
                title == null || title.length == 0 ||
                title == win.app_id ||
                title.down() == win.app_id.down() ||
                title.has_prefix("dev.sinty.") ||
                (title.contains(".") && !title.contains(" "));
            if (title_is_raw_id && app_info != null)
                title = app_info.get_display_name();
            if (title == null || title.length == 0)
                title = win.app_id;

            var lbl = new Label(title);
            lbl.add_css_class("dock-item-title");
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.max_width_chars = 15;
            btn.set_data("title_label", lbl);
            box.append(lbl);

            btn.set_child(box);
            btn.add_css_class("running");

            btn.clicked.connect(() => {
                Singularity.wayland_activate_window(win.handle);
            });
            return btn;
        }

        private Button create_app_button(GLib.AppInfo app_info, int icon_size, bool is_quick_launch) {
            var btn = new Button();
            btn.add_css_class("dock-item");
            if (is_quick_launch) {
                btn.add_css_class("dock-item-quick-launch");
            }
            btn.has_frame = false;
            btn.set_data("app_id", app_info.get_id());
            btn.set_size_request(icon_size + 4, icon_size + 4);

            var icon = app_info.get_icon();
            var img = new Image();
            img.pixel_size = icon_size;

            if (icon is ThemedIcon) {
                var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
                bool set = false;
                foreach (var name in ((ThemedIcon) icon).get_names()) {
                    if (theme.has_icon(name)) {
                        img.icon_name = name;
                        set = true;
                        break;
                    }
                }
                if (!set) img.icon_name = "application-x-executable";
            } else if (icon != null) {
                img.set_from_gicon(icon);
            } else {
                img.icon_name = "application-x-executable";
            }

            btn.set_child(img);
            if (!is_quick_launch && app_system.is_app_running(app_info.get_id())) {
                btn.add_css_class("running");
            }

            var drag_source = new DragSource();
            drag_source.set_actions(Gdk.DragAction.MOVE);
            unowned DragSource ds2_weak = drag_source;
            drag_source.prepare.connect((x, y) => {
                return new Gdk.ContentProvider.for_value(app_info.get_id());
            });
            drag_source.drag_begin.connect((drag) => {
                var drag_icon = app_info.get_icon();
                if (drag_icon != null && drag_icon is ThemedIcon) {
                    var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
                    var names = ((ThemedIcon)drag_icon).get_names();
                    if (names.length > 0) {
                        var paintable = theme.lookup_icon(names[0], null, icon_size, 1, TextDirection.NONE, 0);
                        if (paintable != null) ds2_weak.set_icon(paintable, 0, 0);
                    }
                }
            });
            btn.add_controller(drag_source);

            btn.clicked.connect(() => {
                AppSystem.launch_app(app_info);
            });
            return btn;
        }

        private Widget? placeholder = null;

        // Interleaved pinned-apps + resources, ordered by `dock-order`.
        // Items missing from dock-order fall back to the end, in their own
        // settings' order (so newly pinned apps / freshly dropped resources
        // still appear). Returns keys like "pin:<id>" / "res:<uri>".
        private Gee.ArrayList<string> unified_pinned_order(string[] pinned) {
            var result = new Gee.ArrayList<string>();
            var seen = new Gee.HashSet<string>();

            // Membership sets.
            var pin_set = new Gee.HashSet<string>();
            foreach (var p in pinned) pin_set.add("pin:" + p);
            var res_set = new Gee.HashSet<string>();
            foreach (var u in resources_area.uris()) res_set.add("res:" + u);

            // 1) Honour saved order for items that still exist.
            foreach (var k in _settings.get_strv("dock-order")) {
                if (seen.contains(k)) continue;
                if ((k.has_prefix("pin:") && pin_set.contains(k)) ||
                    (k.has_prefix("res:") && res_set.contains(k))) {
                    result.add(k);
                    seen.add(k);
                }
            }
            // 2) Append pinned apps not yet placed (newly pinned).
            foreach (var p in pinned) {
                string k = "pin:" + p;
                if (!seen.contains(k)) { result.add(k); seen.add(k); }
            }
            // 3) Append resources not yet placed (freshly dropped).
            foreach (var u in resources_area.uris()) {
                string k = "res:" + u;
                if (!seen.contains(k)) { result.add(k); seen.add(k); }
            }
            return result;
        }

        // Persist a reordering: place `key` at `index` within the unified
        // pinned+resource sequence, then write dock-order.
        private void reorder_unified(string key, int index) {
            var cur = unified_pinned_order(app_system.pinned_apps);
            cur.remove(key);
            index = int.max(0, int.min(index, cur.size));
            cur.insert(index, key);
            string[] arr = {};
            foreach (var k in cur) arr += k;
            _settings.set_strv("dock-order", arr);
            schedule_refresh();
        }

        // Count pinned/resource items (pin:/res:) before the placeholder.
        private int unified_index_at_placeholder() {
            int idx = 0;
            Widget? child = dock_box.get_first_child();
            while (child != null && child != placeholder) {
                if (child.get_data<string>("res_uri") != null ||
                    child.get_data<string>("app_id") != null) {
                    // Only count items that belong to the pinned section.
                    idx++;
                }
                child = child.get_next_sibling();
            }
            // Subtract the workspace button (always first, has neither
            // res_uri nor app_id -> not counted) - nothing to subtract.
            return idx;
        }

        private void setup_dnd() {
            var drop_target = new DropTarget(typeof(string), Gdk.DragAction.COPY | Gdk.DragAction.MOVE);
            var drop_motion = new DropControllerMotion();

            drop_motion.enter.connect((x, y) => {
                if (placeholder == null) {
                    int i_size = _settings.get_int("dock-icon-size");
                    placeholder = new Button();
                    placeholder.add_css_class("dock-item");
                    placeholder.add_css_class("placeholder");
                    placeholder.set_size_request(i_size + 4, i_size + 4);
                    placeholder.opacity = 0.5;
                    dock_box.append(placeholder);
                }
            });

            drop_motion.motion.connect((x, y) => {
                if (placeholder == null) return;
                Widget? insert_after = null;
                Widget? child = dock_box.get_first_child();
                while (child != null) {
                    if (child == placeholder) { child = child.get_next_sibling(); continue; }
                    Graphene.Rect bounds;
                    if (child.compute_bounds(dock_box, out bounds)) {
                        double mid = bounds.origin.x + bounds.size.width / 2;
                        if (x > mid) insert_after = child;
                        else break;
                    }
                    child = child.get_next_sibling();
                }
                dock_box.reorder_child_after(placeholder, insert_after);
            });

            drop_motion.leave.connect(() => {
                if (placeholder != null) {
                    dock_box.remove(placeholder);
                    placeholder = null;
                }
            });

            drop_target.drop.connect((value, x, y) => {
                string app_id = (string)value;
                int uni_index = unified_index_at_placeholder();

                // Reordering an existing resource item.
                if (app_id.has_prefix("res:")) {
                    if (placeholder != null) {
                        dock_box.remove(placeholder);
                        placeholder = null;
                    }
                    reorder_unified(app_id, uni_index);
                    return true;
                }

                // A dropped string that looks like a file/URL is a NEW
                // RESOURCE - add it, then position it where it was dropped.
                string first = app_id.strip().split("\n")[0].strip();
                if (first.has_prefix("file://") || first.has_prefix("http://") ||
                    first.has_prefix("https://") || first.has_prefix("/")) {
                    if (placeholder != null) {
                        dock_box.remove(placeholder);
                        placeholder = null;
                    }
                    string uri = first.has_prefix("/")
                        ? GLib.File.new_for_path(first).get_uri()
                        : first;
                    resources_area.add_uri(uri);
                    reorder_unified("res:" + uri, uni_index);
                    return true;
                }

                // Otherwise it's an app. Pin it if needed, then place it at
                // the drop position within the unified pinned+resource order.
                if (placeholder != null) {
                    dock_box.remove(placeholder);
                    placeholder = null;
                }
                if (!app_system.is_pinned(app_id))
                    app_system.insert_pinned_app(app_id, 0);
                reorder_unified("pin:" + app_id, uni_index);
                return true;
            });

            dock_box.add_controller(drop_target);
            dock_box.add_controller(drop_motion);

            setup_resource_dnd();
        }

        // Accept files / folders / links dropped onto the dock from any app.
        private void setup_resource_dnd() {
            // GdkFileList covers files dragged from file managers; the URI /
            // string types cover links dragged from browsers and editors.
            var rt = new DropTarget(typeof(Gdk.FileList), Gdk.DragAction.COPY);
            rt.set_gtypes(new GLib.Type[] {
                typeof(Gdk.FileList), typeof(GLib.File), typeof(string)
            });
            rt.drop.connect((value, x, y) => {
                bool handled = false;
                if (value.holds(typeof(Gdk.FileList))) {
                    var fl = (Gdk.FileList) value.get_boxed();
                    foreach (unowned GLib.File f in fl.get_files()) {
                        resources_area.add_uri(f.get_uri());
                        handled = true;
                    }
                } else if (value.holds(typeof(GLib.File))) {
                    var f = (GLib.File) value.get_object();
                    if (f != null) { resources_area.add_uri(f.get_uri()); handled = true; }
                } else if (value.holds(typeof(string))) {
                    string s = value.get_string().strip();
                    // A dropped string may be a URL or one-or-more URIs/paths.
                    foreach (var tok in s.split("\n")) {
                        string t = tok.strip();
                        if (t == "") continue;
                        if (t.has_prefix("http://") || t.has_prefix("https://")) {
                            resources_area.add_uri(t); handled = true;
                        } else if (t.has_prefix("file://")) {
                            resources_area.add_uri(t); handled = true;
                        } else if (t.has_prefix("/")) {
                            resources_area.add_uri(GLib.File.new_for_path(t).get_uri());
                            handled = true;
                        }
                    }
                }
                return handled;
            });
            // Add to the whole dock surface so users can drop anywhere on it.
            main_container.add_controller(rt);
        }

        protected override void dispose() {
            var as = app_system;
            if (_sig_config_changed != 0)       { GLib.SignalHandler.disconnect(as, _sig_config_changed); _sig_config_changed = 0; }
            if (_sig_apps_changed != 0)          { GLib.SignalHandler.disconnect(as, _sig_apps_changed); _sig_apps_changed = 0; }
            if (_sig_running_apps_changed != 0)  { GLib.SignalHandler.disconnect(as, _sig_running_apps_changed); _sig_running_apps_changed = 0; }
            if (_sig_app_focused != 0)           { GLib.SignalHandler.disconnect(as, _sig_app_focused); _sig_app_focused = 0; }
            if (_sig_window_focused != 0)        { GLib.SignalHandler.disconnect(as, _sig_window_focused); _sig_window_focused = 0; }
            if (_sig_pulse_app != 0)             { GLib.SignalHandler.disconnect(as, _sig_pulse_app); _sig_pulse_app = 0; }
            if (_sig_any_maximized != 0)         { GLib.SignalHandler.disconnect(as, _sig_any_maximized); _sig_any_maximized = 0; }
            if (_sig_window_output != 0)         { GLib.SignalHandler.disconnect(as, _sig_window_output); _sig_window_output = 0; }
            if (_sig_app_title_changed != 0)     { GLib.SignalHandler.disconnect(as, _sig_app_title_changed); _sig_app_title_changed = 0; }
            if (_sig_workspaces_changed != 0)    { GLib.SignalHandler.disconnect(as, _sig_workspaces_changed); _sig_workspaces_changed = 0; }
            if (_sig_any_fullscreen != 0)        { GLib.SignalHandler.disconnect(as, _sig_any_fullscreen); _sig_any_fullscreen = 0; }
            if (_sig_app_closed != 0)            { GLib.SignalHandler.disconnect(as, _sig_app_closed); _sig_app_closed = 0; }
            if (_sig_clock != 0) {
                GLib.SignalHandler.disconnect(SharedClock.get_default(), _sig_clock);
                _sig_clock = 0;
            }
            if (_refresh_timeout_id != 0) {
                GLib.Source.remove(_refresh_timeout_id);
                _refresh_timeout_id = 0;
            }
            if (_slide_timer_id != 0) {
                GLib.Source.remove(_slide_timer_id);
                _slide_timer_id = 0;
            }
            if (_fade_timer_id != 0) {
                GLib.Source.remove(_fade_timer_id);
                _fade_timer_id = 0;
            }
            if (_leave_timeout_id != 0) {
                GLib.Source.remove(_leave_timeout_id);
                _leave_timeout_id = 0;
            }
            if (_reveal_barrier != null) {
                _reveal_barrier.destroy();
                _reveal_barrier = null;
            }
            base.dispose();
        }

        private string format_dock_tooltip(string label, ShortcutManager shortcuts, string action_name) {
            foreach (var sc in shortcuts.shortcuts) {
                if (sc.action_name == action_name && sc.accelerator != "") {
                    return "%s  %s".printf(label, format_accel(sc.accelerator));
                }
            }
            return label;
        }

        private string format_accel(string accel) {
            var s = accel;
            s = s.replace("<Super>", "Super+");
            s = s.replace("<Shift>", "Shift+");
            s = s.replace("<Control>", "Ctrl+");
            s = s.replace("<Alt>", "Alt+");
            s = s.replace("<Primary>", "Ctrl+");
            var plus = s.last_index_of("+");
            if (plus >= 0) {
                var key = s.substring(plus + 1);
                var prefix = s.substring(0, plus + 1);
                if (key.length == 1)
                    s = prefix + key.up();
                else if (key.length > 1)
                    s = prefix + key[0].toupper().to_string() + key.substring(1);
            }
            return s;
        }

        private bool app_has_window_on_monitor(string app_id) {
            if (gdk_monitor == null) return true;
            foreach (var win in app_system.get_windows()) {
                if (win.app_id == app_id) {
                    var wmon = Singularity.wayland_get_window_monitor(win.handle);
                    if (wmon == gdk_monitor) return true;
                }
            }
            return false;
        }

        // For the primary dock in multi-monitor mode: returns true if app has
        // at least one window NOT on a known secondary dock monitor.

        private bool app_visible_on_primary(string app_id, Gee.List<Gdk.Monitor> secondary_monitors) {
            if (secondary_monitors.is_empty) return true;
            foreach (var win in app_system.get_windows()) {
                if (win.app_id != app_id) continue;
                var wmon = Singularity.wayland_get_window_monitor(win.handle);
                if (wmon == null) return true; // unknown, show on primary
                bool is_on_secondary = false;
                foreach (var smon in secondary_monitors) {
                    if (smon == wmon) { is_on_secondary = true; break; }
                }
                if (!is_on_secondary) return true;
            }
            return false;
        }

        private static Gdk.Monitor? find_shell_monitor() {
            var s = new GLib.Settings("dev.sinty.desktop");
            string connector = s.get_string("shell-monitor");
            if (connector == "") return null;
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var mon = (Gdk.Monitor)monitors.get_item(i);
                if (mon.get_connector() == connector) return mon;
            }
            return null;
        }

        // Override size_allocate to set exclusive zone = height - shadow margin,
        // so windows snap to the visual dock top, not the shadow's bottom edge.
        private const int SHADOW_BOTTOM_PX = 4;

        public override void size_allocate(int width, int height, int baseline) {
            base.size_allocate(width, height, baseline);

            string pos = _settings.get_string("dock-position");
            int dimension = (pos == "left" || pos == "right") ? width : height;

            if (dimension > 10) {
                if (_last_dimension != dimension) {
                    _last_dimension = dimension;
                    update_autohide_state();
                }
            }

            if (_hidden) {
                // Margin is owned by animate_dock's slide; only manage the zone.
                GtkLayerShell.set_exclusive_zone(this, 0);
                app_system.shell_dock_height = 0;
            } else {
                if (!autohide && !intellihide) {
                    int zone = int.max(0, dimension - SHADOW_BOTTOM_PX);
                    GtkLayerShell.set_exclusive_zone(this, zone);
                    app_system.shell_dock_height = zone;
                } else {
                    GtkLayerShell.set_exclusive_zone(this, 0);
                    app_system.shell_dock_height = 0;
                }
            }
        }

        private Widget create_corner_hint(string corner_class) {
            var overlay = new Overlay();
            overlay.add_css_class("corner-hint");
            overlay.add_css_class(corner_class);

            var glow = new Box(Orientation.HORIZONTAL, 0);
            glow.add_css_class("corner-hint-glow");
            overlay.set_child(glow);

            var badge = new Box(Orientation.HORIZONTAL, 0);
            badge.add_css_class("corner-hint-badge");
            badge.halign = corner_class.has_suffix("br") ? Align.END : Align.START;
            badge.valign = Align.END;
            badge.margin_bottom = 12;
            if (badge.halign == Align.START) badge.margin_start = 12;
            else badge.margin_end = 12;
            badge.homogeneous = true;
            var icon = new Image.from_icon_name("view-app-grid-symbolic");
            icon.pixel_size = 18;
            icon.halign = Align.CENTER;
            icon.valign = Align.CENTER;
            badge.append(icon);
            overlay.add_overlay(badge);
            overlay.set_data<Image>("corner-icon", icon);
            return overlay;
        }

        private static string icon_for_corner_action(string? action) {
            switch (action) {
                case "workspaces": return "dev.sinty.workspaces";
                case "overview":   return "view-app-grid-symbolic";
                case "settings":   return "emblem-system-symbolic";
                default:           return "go-next-symbolic";
            }
        }

        public void set_corner_active(int corner, bool active, string? action = null) {
            Widget? w = null;
            if (corner == 2) w = _corner_bl;
            else if (corner == 3) w = _corner_br;
            if (w == null) return;
            var icon = w.get_data<Image>("corner-icon");
            if (icon != null && action != null) icon.icon_name = icon_for_corner_action(action);
            if (active) w.add_css_class("visible");
            else w.remove_css_class("visible");
        }

        // Snapshot a widget into a paintable for use as a DnD drag icon.
        private Gdk.Paintable? snapshot_paintable(Gtk.Widget w) {
            int width = w.get_width();
            int height = w.get_height();
            if (width <= 0 || height <= 0) return null;
            var snapshot = new Gtk.Snapshot();
            w.snapshot(snapshot);
            var node = snapshot.to_node();
            if (node == null) return null;
            return new DockSnapshotPaintable(node, width, height);
        }
    }

    // Paintable that renders a captured render node - drag icon for dock items.
    private class DockSnapshotPaintable : Object, Gdk.Paintable {
        private Gsk.RenderNode node;
        private int w;
        private int h;
        public DockSnapshotPaintable(Gsk.RenderNode node, int w, int h) {
            this.node = node; this.w = w; this.h = h;
        }
        public void snapshot(Gdk.Snapshot snap, double width, double height) {
            ((Gtk.Snapshot) snap).append_node(node);
        }
        public Gdk.PaintableFlags get_flags() { return 0; }
        public int get_intrinsic_width()  { return w; }
        public int get_intrinsic_height() { return h; }
    }
}
