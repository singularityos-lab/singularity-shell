using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class DesktopIcons : Gtk.Window {
        private GLib.Settings settings;
        private Fixed icon_container;
        private FileMonitor? monitor;
        private string desktop_path;
        private HashTable<string, IconPosition?> icon_positions;
        private string positions_file;
        private HashTable<string, Gdk.Pixbuf> _icon_pixbuf_cache;
        private Queue<string> _icon_pixbuf_cache_order = new Queue<string>();
        private bool _loading = false;
        private const int ICON_SIZE = 48;
        private const int ICON_WIDTH = 90;
        private const int ICON_HEIGHT = 100;
        private const int GRID_SIZE = 100;
        private const int ORIGIN_X = 24;
        private const int ORIGIN_Y = 24;
        private Widget? placeholder = null;
        private int placeholder_x = 0;
        private int placeholder_y = 0;
        private class IconPosition {
            public int x;
            public int y;

            public IconPosition(int x, int y) {
                this.x = x;
                this.y = y;
            }
        }

        public DesktopIcons(Gtk.Application app, Gdk.Monitor? monitor = null) {
            Object(application: app);
            settings = new GLib.Settings("dev.sinty.desktop");
            desktop_path = Environment.get_home_dir() + "/Desktop";
            positions_file = Environment.get_home_dir() + "/.config/singularity/desktop-icons.txt";
            icon_positions = new HashTable<string, IconPosition?>(str_hash, str_equal);
            _icon_pixbuf_cache = new HashTable<string, Gdk.Pixbuf>(str_hash, str_equal);
            init_for_window(this);
            // Pin to a specific monitor (the primary). Without this the layer
            // surface follows the focused output, so the icons jump to another
            // monitor when it turns on and vanish when it turns off (#105/#56).
            if (monitor != null) set_monitor(this, monitor);
            set_layer(this, GtkLayerShell.Layer.BACKGROUND);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            add_css_class("desktop-icons");
            add_css_class("singularity");
            add_css_class("singularity-shell");
            icon_container = new Fixed();
            icon_container.hexpand = true;
            icon_container.vexpand = true;
            set_child(icon_container);
            var bg_right_click = new GestureClick();
            bg_right_click.button = Gdk.BUTTON_SECONDARY;
            bg_right_click.pressed.connect((n_press, x, y) => {
                show_background_menu(x, y);
            });
            icon_container.add_controller(bg_right_click);
            setup_drop_target();
            load_positions();
            load_desktop_icons();
            setup_file_monitor();
            settings.changed["show-desktop-icons"].connect(() => {
                visible = settings.get_boolean("show-desktop-icons");
            });
            visible = settings.get_boolean("show-desktop-icons");
        }

        protected override void dispose() {
            if (monitor != null) {
                monitor.cancel();
                monitor = null;
            }
            _icon_pixbuf_cache.remove_all();
            base.dispose();
        }

        private void setup_drop_target() {
            var drop_target = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            var drop_motion = new DropControllerMotion();
            drop_motion.enter.connect((x, y) => {
                if (placeholder == null) {
                    placeholder = new Box(Orientation.VERTICAL, 0);
                    placeholder.add_css_class("desktop-icon-placeholder");
                    placeholder.set_size_request(ICON_WIDTH, ICON_HEIGHT);
                    placeholder.opacity = 0.5;
                }
            });
            drop_motion.motion.connect((x, y) => {
                if (placeholder == null) return;
                int snap_x = snap_axis(x, ORIGIN_X);
                int snap_y = snap_axis(y, ORIGIN_Y);
                if (snap_x != placeholder_x || snap_y != placeholder_y) {
                    placeholder_x = snap_x;
                    placeholder_y = snap_y;
                    shift_icon_at_position(snap_x, snap_y);
                    if (placeholder.parent == null) {
                        icon_container.put(placeholder, snap_x, snap_y);
                    } else {
                        icon_container.move(placeholder, snap_x, snap_y);
                    }
                }
            });
            drop_motion.leave.connect(() => {
                if (placeholder != null && placeholder.parent != null) {
                    icon_container.remove(placeholder);
                }
                placeholder = null;
                placeholder_x = 0;
                placeholder_y = 0;
            });
            drop_target.drop.connect((value, x, y) => {
                string filename = value.get_string();
                int snap_x = snap_axis(x, ORIGIN_X);
                int snap_y = snap_axis(y, ORIGIN_Y);
                if (placeholder != null && placeholder.parent != null) {
                    icon_container.remove(placeholder);
                }
                placeholder = null;
                placeholder_x = 0;
                placeholder_y = 0;
                // Never stack on an existing icon: if the target cell is taken
                // by a different icon, slide to the nearest free cell.
                find_free_cell(ref snap_x, ref snap_y, filename);
                Widget? child = icon_container.get_first_child();
                while (child != null) {
                    var box = child as Box;
                    if (box != null && box.get_data<string>("filename") == filename) {
                        icon_container.move(child, snap_x, snap_y);
                        icon_positions.insert(filename, new IconPosition(snap_x, snap_y));
                        save_positions();
                        return true;
                    }
                    child = child.get_next_sibling();
                }
                return false;
            });
            icon_container.add_controller(drop_target);
            icon_container.add_controller(drop_motion);
        }

        // Single grid lattice shared by drag-drop and auto-placement so the
        // two never land on mismatched baselines (issue #41).
        private int snap_axis(double v, int origin) {
            return GridLayout.snap(v, origin, GRID_SIZE);
        }

        private int bottom_limit() {
            int h = icon_container.get_height();
            if (h <= 0) h = 900;
            return h - ICON_HEIGHT;
        }

        private bool cell_taken(int sx, int sy, string? exclude) {
            bool taken = false;
            icon_positions.foreach((name, pos) => {
                if (pos == null) return;
                if (exclude != null && name == exclude) return;
                if (pos.x == sx && pos.y == sy) taken = true;
            });
            return taken;
        }

        private void find_free_cell(ref int sx, ref int sy, string? exclude) {
            GridLayout.find_free_cell(ref sx, ref sy, ORIGIN_Y, GRID_SIZE, bottom_limit(),
                (x, y) => cell_taken(x, y, exclude));
        }

        private void shift_icon_at_position(int x, int y) {
            Widget? child = icon_container.get_first_child();
            while (child != null) {
                if (child == placeholder) {
                    child = child.get_next_sibling();
                    continue;
                }
                Graphene.Point pos;
                if (child.compute_point(icon_container, Graphene.Point.zero(), out pos)) {
                    int cx = (int)pos.x;
                    int cy = (int)pos.y;
                    if (cx / GRID_SIZE == x / GRID_SIZE && cy / GRID_SIZE == y / GRID_SIZE) {
                        int new_x = x;
                        int new_y = y + GRID_SIZE;
                        if (new_y > 800) {
                            new_y = 24;
                            new_x = x + GRID_SIZE;
                        }
                        icon_container.move(child, new_x, new_y);
                        var box = child as Box;
                        if (box != null) {
                            string? fn = box.get_data<string>("filename");
                            if (fn != null) {
                                icon_positions.insert(fn, new IconPosition(new_x, new_y));
                            }
                        }
                        return;
                    }
                }
                child = child.get_next_sibling();
            }
        }

        private void load_positions() {
            try {
                var file = File.new_for_path(positions_file);
                if (file.query_exists()) {
                    var stream = new DataInputStream(file.read());
                    string? line;
                    while ((line = stream.read_line()) != null) {
                        var parts = line.split(":");
                        if (parts.length == 2) {
                            var coords = parts[1].split(",");
                            if (coords.length == 2) {
                                int px = int.parse(coords[0]);
                                int py = int.parse(coords[1]);
                                icon_positions.insert(parts[0], new IconPosition(px, py));
                            }
                        }
                    }
                }
            } catch (Error e) {}
        }

        private void save_positions() {
            try {
                var dir = File.new_for_path(positions_file).get_parent();
                if (!dir.query_exists()) {
                    dir.make_directory_with_parents();
                }
                var file = File.new_for_path(positions_file);
                var stream = new DataOutputStream(file.replace(null, false, FileCreateFlags.NONE));
                icon_positions.foreach((name, pos) => {
                    if (pos != null) {
                        try {
                            stream.put_string("%s:%d,%d\n".printf(name, pos.x, pos.y));
                        } catch (Error e) {}
                    }
                });
                stream.close();
            } catch (Error e) {
                warning("Failed to save icon positions: %s", e.message);
            }
        }

        private void setup_file_monitor() {
            try {
                var desktop = File.new_for_path(desktop_path);
                if (!desktop.query_exists()) {
                    desktop.make_directory_with_parents();
                }
                monitor = desktop.monitor_directory(FileMonitorFlags.NONE);
                monitor.changed.connect((file, other, event) => {
                    if (_loading) return;
                    string? name = file.get_basename();
                    if (name == null || name.has_prefix(".")) return;
                    switch (event) {
                        case FileMonitorEvent.DELETED:
                        case FileMonitorEvent.MOVED_OUT:
                            remove_single_icon(name);
                            break;
                        case FileMonitorEvent.CREATED:
                        case FileMonitorEvent.MOVED_IN:
                        case FileMonitorEvent.CHANGES_DONE_HINT:
                        case FileMonitorEvent.ATTRIBUTE_CHANGED:
                            update_single_icon(name);
                            break;
                        default:
                            // CHANGED (mid-write) is coalesced into CHANGES_DONE_HINT;
                            // ignore it so we do not re-decode on every write chunk.
                            break;
                    }
                });
            } catch (Error e) {
                warning("Failed to setup file monitor: %s", e.message);
            }
        }

        private void load_desktop_icons() {
            Widget? child = icon_container.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                icon_container.remove(child);
                child = next;
            }
            try {
                var desktop = File.new_for_path(desktop_path);
                if (!desktop.query_exists()) return;
                var enumerator = desktop.enumerate_children("standard::*,time::modified", FileQueryInfoFlags.NONE);
                // Rebuild placement from scratch onto the shared lattice so any
                // saved off-grid or overlapping positions are resolved.
                var old_positions = icon_positions;
                icon_positions = new HashTable<string, IconPosition?>(str_hash, str_equal);
                var entries = new GLib.List<FileInfo>();
                FileInfo? info;
                while ((info = enumerator.next_file()) != null) {
                    string name = info.get_display_name();
                    if (name.has_prefix(".")) continue;
                    entries.append(info);
                }
                entries.sort((a, b) => GLib.strcmp(a.get_display_name(), b.get_display_name()));
                foreach (var fi in entries) {
                    string name = fi.get_display_name();
                    var file = desktop.get_child(name);
                    int x, y;
                    IconPosition? saved_pos = old_positions.lookup(name);
                    if (saved_pos != null) {
                        x = snap_axis(saved_pos.x, ORIGIN_X);
                        y = snap_axis(saved_pos.y, ORIGIN_Y);
                    } else {
                        x = ORIGIN_X;
                        y = ORIGIN_Y;
                    }
                    find_free_cell(ref x, ref y, null);
                    icon_positions.insert(name, new IconPosition(x, y));
                    add_icon(file, fi, x, y);
                }
                save_positions();
            } catch (Error e) {
                warning("Failed to load desktop icons: %s", e.message);
            }
        }

        private Widget? find_icon_item(string name) {
            for (Widget? c = icon_container.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (c.get_data<string>("filename") == name) return c;
            }
            return null;
        }

        private void remove_single_icon(string name) {
            var item = find_icon_item(name);
            if (item != null) icon_container.remove(item);
            icon_positions.remove(name);
            save_positions();
        }

        // Add or refresh exactly one icon on a file-monitor event, leaving the
        // other icons untouched (the full load_desktop_icons rebuild tears down
        // and re-decodes every icon on each event, which is the hot path).
        private void update_single_icon(string name) {
            if (name.has_prefix(".")) return;
            try {
                var desktop = File.new_for_path(desktop_path);
                var file = desktop.get_child(name);
                if (!file.query_exists()) { remove_single_icon(name); return; }
                var info = file.query_info("standard::*,time::modified", FileQueryInfoFlags.NONE);
                var existing = find_icon_item(name);
                if (existing != null) icon_container.remove(existing);
                int x, y;
                IconPosition? saved_pos = icon_positions.lookup(name);
                if (saved_pos != null) {
                    x = snap_axis(saved_pos.x, ORIGIN_X);
                    y = snap_axis(saved_pos.y, ORIGIN_Y);
                } else {
                    x = ORIGIN_X;
                    y = ORIGIN_Y;
                    find_free_cell(ref x, ref y, null);
                    icon_positions.insert(name, new IconPosition(x, y));
                    save_positions();
                }
                add_icon(file, info, x, y);
            } catch (Error e) {
                warning("Failed to update desktop icon %s: %s", name, e.message);
            }
        }

        private void add_icon(File file, FileInfo info, int x, int y) {
            var item = new Box(Orientation.VERTICAL, 4);
            item.add_css_class("desktop-icon");
            item.halign = Align.CENTER;
            item.set_size_request(ICON_WIDTH, ICON_HEIGHT);
            item.set_data<string>("filename", info.get_display_name());
            var icon_widget = new Image();
            icon_widget.pixel_size = ICON_SIZE;
            string content_type = info.get_content_type() ?? "";
            string? path = file.get_path();
            if (content_type == "application/x-desktop" && path != null
                && set_icon_from_desktop_entry(icon_widget, path)) {
            } else if (content_type.has_prefix("image/") && path != null) {
                uint64 mtime = info.get_attribute_uint64("time::modified");
                string cache_key = path + ":" + mtime.to_string();
                Gdk.Pixbuf? cached = _icon_pixbuf_cache.lookup(cache_key);
                if (cached == null) {
                    try {
                        cached = new Gdk.Pixbuf.from_file_at_scale(path, ICON_SIZE, ICON_SIZE, true);
                        _icon_pixbuf_cache.insert(cache_key, cached);
                        _icon_pixbuf_cache_order.push_tail(cache_key);
                        trim_icon_pixbuf_cache();
                    } catch (Error e) {
                        set_icon_from_info(icon_widget, info);
                    }
                }
                if (cached != null) {
                    icon_widget.set_from_paintable(Gdk.Texture.for_pixbuf(cached));
                }
            } else {
                set_icon_from_info(icon_widget, info);
            }
            item.append(icon_widget);
            string label_text = info.get_display_name();
            if (content_type == "application/x-desktop" && path != null) {
                var entry = new GLib.DesktopAppInfo.from_filename(path);
                if (entry != null) {
                    string? dn = entry.get_display_name();
                    if (dn != null && dn != "") label_text = dn;
                }
            }
            var label = new Label(label_text);
            label.max_width_chars = 12;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.wrap = true;
            label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            label.lines = 2;
            label.halign = Align.CENTER;
            label.justify = Justification.CENTER;
            label.xalign = 0.5f;
            label.add_css_class("desktop-icon-label");
            item.append(label);
            var drag_source = new DragSource();
            drag_source.set_actions(Gdk.DragAction.MOVE);
            string filename = info.get_display_name();
            drag_source.prepare.connect((px, py) => {
                return new Gdk.ContentProvider.for_value(filename);
            });
            drag_source.drag_begin.connect((drag) => {
                var snapshot = new Gtk.Snapshot();
                item.snapshot(snapshot);
                var paintable = snapshot.to_paintable(null);
                drag_source.set_icon(paintable, ICON_WIDTH / 2, ICON_HEIGHT / 2);
                item.opacity = 0.3;
            });
            drag_source.drag_end.connect((drag, delete_data) => {
                item.opacity = 1.0;
            });
            item.add_controller(drag_source);
            var click = new GestureClick();
            click.button = Gdk.BUTTON_PRIMARY;
            click.released.connect((n_press, cx, cy) => {
                if (n_press == 2) {
                    open_file(file, info);
                }
            });
            item.add_controller(click);
            var right_click = new GestureClick();
            right_click.button = Gdk.BUTTON_SECONDARY;
            right_click.pressed.connect((n_press, cx, cy) => {
                right_click.set_state(Gtk.EventSequenceState.CLAIMED);
                show_context_menu(item, file, info);
            });
            item.add_controller(right_click);
            var key_controller = new EventControllerKey();
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.space) {
                    try {
                        var app = (SingularityApp)application;
                        app.preview_manager.show_preview(file.get_uri());
                        return true;
                    } catch (Error e) {
                        warning("Failed to trigger preview: %s", e.message);
                    }
                }
                return false;
            });
            item.add_controller(key_controller);
            item.focusable = true;
            icon_container.put(item, x, y);
        }

        private void trim_icon_pixbuf_cache() {
            while (_icon_pixbuf_cache_order.get_length() > 128) {
                string? old_key = _icon_pixbuf_cache_order.pop_head();
                if (old_key != null) _icon_pixbuf_cache.remove(old_key);
            }
        }

        private bool set_icon_from_desktop_entry(Image icon_widget, string path) {
            var entry = new GLib.DesktopAppInfo.from_filename(path);
            if (entry == null) return false;
            var gicon = entry.get_icon();
            if (gicon == null) return false;
            if (gicon is ThemedIcon) {
                var display = Gdk.Display.get_default();
                var theme = (display != null) ? Gtk.IconTheme.get_for_display(display) : null;
                foreach (var name in ((ThemedIcon) gicon).get_names()) {
                    if (theme != null && theme.has_icon(name)) {
                        icon_widget.icon_name = name;
                        return true;
                    }
                }
                return false;
            }
            icon_widget.set_from_gicon(gicon);
            return true;
        }

        private void set_icon_from_info(Image icon_widget, FileInfo info) {
            var gicon = info.get_icon();

            // Avoid blank/missing placeholders: if the themed icon can't be resolved, use a generic fallback.
            if (gicon is ThemedIcon) {
                var display = Gdk.Display.get_default();
                var theme = (display != null) ? Gtk.IconTheme.get_for_display(display) : null;
                foreach (var name in ((ThemedIcon) gicon).get_names()) {
                    if (theme != null && theme.has_icon(name)) {
                        icon_widget.icon_name = name;
                        return;
                    }
                }

                if (info.get_file_type() == FileType.DIRECTORY) icon_widget.icon_name = "folder-symbolic";
                else icon_widget.icon_name = "text-x-generic-symbolic";
                return;
            }

            if (gicon != null) {
                icon_widget.set_from_gicon(gicon);
            } else {
                icon_widget.icon_name = "text-x-generic-symbolic";
            }
        }

        private void open_file(File file, FileInfo info) {
            try {
                if (info.get_file_type() == FileType.DIRECTORY) {
                    AppInfo.launch_default_for_uri(file.get_uri(), Gdk.Display.get_default().get_app_launch_context());
                } else {
                    string name = info.get_display_name();
                    if (name.has_suffix(".desktop")) {
                        var app = new DesktopAppInfo.from_filename(file.get_path());
                        if (app != null) {
                            app.launch(null, Gdk.Display.get_default().get_app_launch_context());
                            return;
                        }
                    }
                    AppInfo.launch_default_for_uri(file.get_uri(), Gdk.Display.get_default().get_app_launch_context());
                }
            } catch (Error e) {
                warning("Failed to open file: %s", e.message);
            }
        }

        private void launch_with(AppInfo app, File file) {
            try {
                var uris = new List<string>();
                uris.append(file.get_uri());
                app.launch_uris(uris, Gdk.Display.get_default().get_app_launch_context());
            } catch (Error e) {
                warning("Failed to open with %s: %s", app.get_name(), e.message);
            }
        }

        private void show_context_menu(Widget widget, File file, FileInfo info) {
            var menu = new Singularity.Widgets.ContextMenu(widget);
            menu.add_item("Open", "document-open-symbolic", () => {
                open_file(file, info);
            });
            string content_type = info.get_content_type() ?? "";
            if (info.get_file_type() != FileType.DIRECTORY && content_type != "") {
                var handlers = AppInfo.get_recommended_for_type(content_type);
                if (handlers == null || handlers.length() == 0)
                    handlers = AppInfo.get_all_for_type(content_type);
                if (handlers != null && handlers.length() > 0) {
                    var submenu = menu.add_submenu("Open With", "document-open-symbolic");
                    foreach (var ai in handlers) {
                        var app = ai;
                        submenu.add_item_gicon(app.get_name(), app.get_icon(), () => {
                            launch_with(app, file);
                        });
                    }
                }
            }
            if (content_type.has_prefix("image/")) {
                menu.add_item("Set as Wallpaper", "preferences-desktop-wallpaper-symbolic", () => {
                    settings.set_string("background-picture-uri", file.get_uri());
                });
            }
            menu.add_separator();
            menu.add_item("Sort by Name", "view-sort-ascending-symbolic", () => {
                sort_icons_by_name();
            });
            menu.add_item("Sort by Type", "view-list-symbolic", () => {
                sort_icons_by_type();
            });
            menu.add_item("Arrange to Grid", "view-grid-symbolic", () => {
                arrange_icons_to_grid();
            });
            menu.add_separator();
            menu.add_item("Move to Trash", "user-trash-symbolic", () => {
                try {
                    file.trash();
                } catch (Error e) {
                    warning("Failed to trash, deleting instead: %s", e.message);
                    try {
                        file.delete();
                    } catch (Error e2) {
                        warning("Failed to delete: %s", e2.message);
                        return;
                    }
                }
                icon_positions.remove(info.get_display_name());
                save_positions();
                icon_container.remove(widget);
            });
            menu.popup();
        }

        private void show_background_menu(double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(icon_container);
            Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
            menu.set_pointing_to(rect);
            menu.add_item("Change Background", "preferences-desktop-wallpaper-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("background");
            });
            menu.add_item("Settings", "emblem-system-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("home");
            });
            menu.add_separator();
            menu.add_item("Sort by Name", "view-sort-ascending-symbolic", () => {
                sort_icons_by_name();
            });
            menu.add_item("Sort by Type", "view-list-symbolic", () => {
                sort_icons_by_type();
            });
            menu.add_item("Arrange to Grid", "view-grid-symbolic", () => {
                arrange_icons_to_grid();
            });
            menu.add_separator();
            menu.add_item("Refresh", "view-refresh-symbolic", () => {
                load_desktop_icons();
            });
            menu.popup();
        }

        private void sort_icons_by_name() {
            var names = new GLib.List<string>();
            icon_positions.foreach((name, pos) => {
                names.append(name);
            });
            names.sort((a, b) => {
                return strcmp(a.down(), b.down());
            });
            int x = 24;
            int y = 48;
            foreach (var name in names) {
                icon_positions.insert(name, new IconPosition(x, y));
                y += GRID_SIZE;
                if (y > 800) {
                    y = 48;
                    x += GRID_SIZE;
                }
            }
            save_positions();
            load_desktop_icons();
        }

        private void sort_icons_by_type() {
            var files = new GLib.List<FileEntry>();
            try {
                var desktop = File.new_for_path(desktop_path);
                var enumerator = desktop.enumerate_children("standard::*", FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = enumerator.next_file()) != null) {
                    string name = info.get_display_name();
                    if (name.has_prefix(".")) continue;
                    var entry = new FileEntry();
                    entry.name = name;
                    entry.content_type = info.get_content_type() ?? "application/octet-stream";
                    entry.is_directory = info.get_file_type() == FileType.DIRECTORY;
                    files.append(entry);
                }
            } catch (Error e) {
                return;
            }
            files.sort((a, b) => {
                if (a.is_directory && !b.is_directory) return -1;
                if (!a.is_directory && b.is_directory) return 1;
                int type_cmp = strcmp(a.content_type, b.content_type);
                if (type_cmp != 0) return type_cmp;
                return strcmp(a.name.down(), b.name.down());
            });
            int x = 24;
            int y = 48;
            foreach (var entry in files) {
                icon_positions.insert(entry.name, new IconPosition(x, y));
                y += GRID_SIZE;
                if (y > 800) {
                    y = 48;
                    x += GRID_SIZE;
                }
            }
            save_positions();
            load_desktop_icons();
        }

        private void arrange_icons_to_grid() {
            var names = new GLib.List<string>();
            icon_positions.foreach((name, pos) => {
                names.append(name);
            });
            int x = 24;
            int y = 48;
            foreach (var name in names) {
                icon_positions.insert(name, new IconPosition(x, y));
                y += GRID_SIZE;
                if (y > 800) {
                    y = 48;
                    x += GRID_SIZE;
                }
            }
            save_positions();
            load_desktop_icons();
        }
        private class FileEntry {
            public string name;
            public string content_type;
            public bool is_directory;
        }
    }
}
