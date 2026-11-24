using Gtk;
using GLib;
using GtkLayerShell;

namespace Singularity {

    public class AppFolderOverlay : Gtk.Window {
        private AppSystem app_system;
        private string folder_id;
        private FlowBox grid;
        private Entry name_entry;
        private Box root_box;
        private Box card;
        private uint _close_timer = 0;
        private ulong _folders_signal_id = 0;
        private GLib.Settings desktop_settings;
        private ulong _background_effect_handler = 0;
        private ulong _blur_strength_handler = 0;

        public delegate void LaunchCallback();
        public LaunchCallback? on_app_launched;
        public signal void closed();

        public AppFolderOverlay(Gtk.Application app, string folder_id) {
            Object(application: app);
            this.folder_id = folder_id;
            app_system = AppSystem.get_default();
            desktop_settings = new GLib.Settings("dev.sinty.desktop");

            // Full-screen overlay (dims background)
            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            GtkLayerShell.set_exclusive_zone(this, -1);
            decorated = false;
            add_css_class("folder-overlay-window");
            add_css_class("folder-overlay-dimmer");
            add_css_class("singularity");

            // Dim background - close only when the press lands outside the card.
            // We must not CLAIM presses on the card (that would kill the app
            // buttons' own click gestures), so instead we hit-test here (#51).
            var bg_click = new GestureClick();
            bg_click.pressed.connect((n, x, y) => {
                var picked = this.pick(x, y, Gtk.PickFlags.DEFAULT);
                for (var w = picked; w != null; w = w.get_parent()) {
                    if (w == card) return;
                }
                close_overlay();
            });
            ((Widget)this).add_controller(bg_click);

            // Dropping an app onto the dim area (outside the card) takes it out
            // of the folder. The overlay is fullscreen, so there is no other
            // reachable drop target to drag an app out to (#51).
            var bg_drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            bg_drop.drop.connect((val, x, y) => {
                string? aid = val.get_string();
                if (aid == null || aid.has_prefix("folder:")) return false;
                app_system.remove_app_from_folder(folder_id, aid);
                populate();
                return true;
            });
            ((Widget)this).add_controller(bg_drop);

            root_box = new Box(Orientation.VERTICAL, 0);
            root_box.halign = Align.CENTER;
            root_box.valign = Align.CENTER;
            set_child(root_box);

            // Card
            card = new Box(Orientation.VERTICAL, 16);
            card.add_css_class("folder-overlay-card");
            root_box.append(card);

            _background_effect_handler = desktop_settings.changed["background-effect"].connect(
                update_background_effect);
            _blur_strength_handler = desktop_settings.changed["blur-strength"].connect(
                update_background_effect);
            map.connect_after(update_background_effect);

            // Folder name (editable)
            var folder = app_system.get_folder(folder_id);
            name_entry = new Entry();
            name_entry.text = folder != null ? folder.name : "Folder";
            name_entry.has_frame = false;
            name_entry.xalign = 0.5f;
            name_entry.add_css_class("folder-name-entry");
            name_entry.activate.connect(() => commit_rename());
            name_entry.changed.connect(() => commit_rename_debounced());
            card.append(name_entry);

            // App grid inside folder
            grid = new FlowBox();
            grid.max_children_per_line = 4;
            grid.column_spacing = 20;
            grid.row_spacing = 20;
            grid.selection_mode = SelectionMode.NONE;
            grid.halign = Align.CENTER;
            grid.add_css_class("folder-inner-grid");
            card.append(grid);

            populate();

            // Drop target: accept apps dragged into the folder
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.drop.connect((val, x, y) => {
                string? app_id = val.get_string();
                if (app_id == null || app_id.has_prefix("folder:")) return false;
                app_system.add_app_to_folder(folder_id, app_id);
                populate();
                return true;
            });
            grid.add_controller(drop);

            // ESC closes ONLY the overlay, stops propagation to prevent overview close
            var key = new EventControllerKey();
            key.set_propagation_phase(PropagationPhase.CAPTURE);
            key.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    close_overlay();
                    return true; // consumed - does NOT propagate to overview
                }
                return false;
            });
            ((Widget)this).add_controller(key);

            _folders_signal_id = app_system.folders_changed.connect(() => { populate(); });
            // Signal disconnected in close_overlay() when this window is destroyed
        }

        private uint _rename_timer = 0;

        private void update_background_effect() {
            var mode = Singularity.Style.BackgroundEffect.read(desktop_settings);
            if (get_mapped()) {
                Graphene.Rect bounds;
                if (card.compute_bounds(this, out bounds)) {
                    Singularity.Style.BackgroundEffect.apply_shapes(this,
                        new Gtk.Widget[] { card }, mode);
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

        private void commit_rename_debounced() {
            if (_rename_timer != 0) { GLib.Source.remove(_rename_timer); _rename_timer = 0; }
            _rename_timer = GLib.Timeout.add(600, () => {
                _rename_timer = 0;
                commit_rename();
                return GLib.Source.REMOVE;
            });
        }

        private void commit_rename() {
            string new_name = name_entry.text.strip();
            if (new_name.length == 0) return;
            var folder = app_system.get_folder(folder_id);
            if (folder == null || folder.name == new_name) return;
            app_system.rename_folder(folder_id, new_name);
        }

        public void populate() {
            grid.remove_all();
            var folder = app_system.get_folder(folder_id);
            if (folder == null) { close_overlay(); return; }
            foreach (var app_id in folder.app_ids) {
                var app = app_system.get_app_info(app_id);
                if (app == null) continue;
                var btn = create_app_button(app, app_id);
                grid.append(btn);
            }
        }

        private Button create_app_button(AppInfo app, string app_id) {
            var btn = new Button();
            btn.add_css_class("app-grid-item");
            btn.add_css_class("folder-inner-item");
            btn.has_frame = false;

            var box = new Box(Orientation.VERTICAL, 8);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;

            var icon = app.get_icon();
            var img = new Image();
            img.pixel_size = 72;
            if (icon is ThemedIcon) {
                var theme = IconTheme.get_for_display(Gdk.Display.get_default());
                bool set = false;
                foreach (var name in ((ThemedIcon)icon).get_names()) {
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
            label.max_width_chars = 10;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0.5f;
            box.append(label);

            btn.set_child(box);
            btn.clicked.connect(() => {
                // Close the overview, then close this folder synchronously (the
                // animated close stalls once the launched app takes focus and
                // the overlay stops getting frames), then launch (#51).
                if (on_app_launched != null) on_app_launched();
                force_close();
                AppSystem.launch_app(app);
            });

            // Right-click: remove from folder
            var rc = new GestureClick();
            rc.button = Gdk.BUTTON_SECONDARY;
            rc.pressed.connect((n, x, y) => {
                rc.set_state(EventSequenceState.CLAIMED);
                var menu = new Singularity.Widgets.ContextMenu(btn);
                Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
                menu.set_pointing_to(rect);
                string captured_app_id = app_id.dup();
                string captured_folder_id = folder_id.dup();
                menu.add_item("Remove from Folder", "folder-symbolic", () => {
                    app_system.remove_app_from_folder(captured_folder_id, captured_app_id);
                });
                menu.add_item("Open", "system-run-symbolic", () => {
                    if (on_app_launched != null) on_app_launched();
                    force_close();
                    AppSystem.launch_app(app);
                });
                menu.popup();
            });
            btn.add_controller(rc);

            // Drag source: drag app out of folder
            var drag = new DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            string captured_id = app_id.dup();
            string captured_folder_id = folder_id.dup();
            drag.prepare.connect((x, y) => new Gdk.ContentProvider.for_value(captured_id));
            drag.drag_begin.connect((d) => {
                var gicon = app.get_icon();
                if (gicon is ThemedIcon) {
                    var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
                    foreach (var name in ((ThemedIcon)gicon).get_names()) {
                        var p = theme.lookup_icon(name, null, 48, 1, TextDirection.NONE, 0);
                        if (p != null) { drag.set_icon(p, 24, 24); break; }
                    }
                }
            });
            drag.drag_end.connect((d, action, delete_data) => {
                if (delete_data) {
                    app_system.remove_app_from_folder(captured_folder_id, captured_id);
                }
            });
            btn.add_controller(drag);

            return btn;
        }

        public void open_overlay() {
            if (_close_timer != 0) { GLib.Source.remove(_close_timer); _close_timer = 0; }
            populate();
            opacity = 0;
            visible = true;
            present();
            update_background_effect();
            // Remove auto-focus from entry (GTK4 focuses first focusable widget on present)
            set_focus(null);
            name_entry.focusable = false;
            name_entry.select_region(0, 0);
            GLib.Idle.add(() => {
                name_entry.focusable = true;
                name_entry.select_region(0, 0);
                return GLib.Source.REMOVE;
            });
            // Fade in animation
            var anim = new Singularity.Animation.TimedAnimation(
                (Widget)this, 0, 1, 180,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC
            );
            anim.tick.connect(() => { opacity = anim.value; });
            anim.play();
        }

        // Tear down immediately, without the fade animation. Used when an app
        // is launched: the animated close depends on frame-clock ticks that
        // stop once the launched window takes focus, leaving the overlay stuck
        // on screen (#51).
        public void force_close() {
            if (_rename_timer != 0) { GLib.Source.remove(_rename_timer); _rename_timer = 0; }
            if (_close_timer != 0) { GLib.Source.remove(_close_timer); _close_timer = 0; }
            commit_rename();
            if (_folders_signal_id != 0) {
                app_system.disconnect(_folders_signal_id);
                _folders_signal_id = 0;
            }
            close_layer_window(this);
            closed();
            destroy();
        }

        public void close_overlay() {
            if (_rename_timer != 0) { GLib.Source.remove(_rename_timer); _rename_timer = 0; }
            commit_rename();
            if (_folders_signal_id != 0) {
                app_system.disconnect(_folders_signal_id);
                _folders_signal_id = 0;
            }
            // Fade out, then destroy the window to release all resources
            var anim = new Singularity.Animation.TimedAnimation(
                (Widget)this, 1, 0, 140,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC
            );
            anim.tick.connect(() => { opacity = anim.value; });
            anim.done.connect(() => { visible = false; closed(); destroy(); });
            anim.play();
        }
    }
}
