using Gtk;
using GLib;

namespace Singularity {

    /**
     * Backing store + visual factory for dock resources (files,
     * folders, web links dropped onto the dock).
     *
     * This is NOT a packed widget: the dock renders each resource as a normal
     * dock item (same pill geometry, hover and click animation as apps) and
     * asks this helper to build the icon visual and handle activation. The
     * URI list is persisted in the `dock-resources` gsetting.
     *
     *  - Images / GIFs        -> thumbnail preview
     *  - Folders that are      -> fanned "polaroid" preview of the first few
     *    mostly photos           media items
     *  - Other folders         -> folder icon
     *  - Other files           -> MIME-type icon
     *  - Web links             -> globe icon
     */
    public class DockResourcesArea : Object {
        private GLib.Settings _settings;

        public signal void changed();

        public DockResourcesArea() {
            _settings = new GLib.Settings("dev.sinty.desktop");
            _settings.changed["dock-resources"].connect(() => changed());
        }

        public string[] uris() { return _settings.get_strv("dock-resources"); }
        public bool is_empty() { return uris().length == 0; }

        public void add_uri(string uri) {
            string[] cur = _settings.get_strv("dock-resources");
            foreach (var u in cur) if (u == uri) return;
            cur += uri;
            _settings.set_strv("dock-resources", cur);
            changed();
        }

        public void remove_uri(string uri) {
            string[] keep = {};
            foreach (var u in _settings.get_strv("dock-resources"))
                if (u != uri) keep += u;
            _settings.set_strv("dock-resources", keep);
            changed();
        }

        // Reorder: move `uri` to `index` within the resource list.
        public void move_uri(string uri, int index) {
            string[] without = {};
            foreach (var u in _settings.get_strv("dock-resources"))
                if (u != uri) without += u;
            index = int.max(0, int.min(index, without.length));
            string[] result = {};
            for (int i = 0; i < without.length; i++) {
                if (i == index) result += uri;
                result += without[i];
            }
            if (result.length == without.length) result += uri;
            _settings.set_strv("dock-resources", result);
            changed();
        }

        public bool is_web(string uri) {
            return uri.has_prefix("http://") || uri.has_prefix("https://");
        }

        public string tooltip_for(string uri) {
            if (is_web(uri)) return uri;
            var f = File.new_for_uri(uri);
            return f.get_basename() ?? uri;
        }

        // Visual factory
        public Gtk.Widget make_visual(string uri, int icon_size) {
            if (is_web(uri)) {
                var img = new Gtk.Image();
                img.pixel_size = icon_size;
                // Prefer the system web-browser icon (full colour) over a
                // symbolic emblem.
                var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
                if (theme.has_icon("web-browser")) img.icon_name = "web-browser";
                else if (theme.has_icon("applications-internet")) img.icon_name = "applications-internet";
                else img.icon_name = "emblem-web-symbolic";
                return img;
            }
            var file = File.new_for_uri(uri);
            string path = file.get_path() ?? "";
            if (FileUtils.test(path, FileTest.IS_DIR))
                return build_folder_visual(file, path, icon_size);

            var img = new Gtk.Image();
            img.pixel_size = icon_size;
            set_file_visual(img, file, path, icon_size);
            return img;
        }

        public void activate(string uri, Gtk.Widget anchor) {
            if (is_web(uri)) { launch_uri(uri); return; }
            var file = File.new_for_uri(uri);
            string path = file.get_path() ?? "";
            if (FileUtils.test(path, FileTest.IS_DIR))
                open_folder_popover(anchor, file);
            else
                launch_uri(uri);
        }

        public void show_menu(string uri, Gtk.Widget anchor, double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(anchor);
            Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
            menu.set_pointing_to(rect);
            if (!is_web(uri)) {
                menu.add_item("Open", "document-open-symbolic", () => launch_uri(uri));
                menu.add_item("Show in Files", "folder-open-symbolic", () => reveal_in_files(uri));
                menu.add_separator();
            }
            menu.add_item("Remove from Dock", "edit-delete-symbolic", () => remove_uri(uri));
            menu.popup();
        }

        // File visual (thumbnail or themed icon)
        private void set_file_visual(Gtk.Image img, GLib.File file, string path, int icon_size) {
            string? ct = content_type_for(file);
            if (ct != null && ct.has_prefix("image/")) {
                try {
                    var pb = new Gdk.Pixbuf.from_file_at_scale(path, icon_size, icon_size, true);
                    img.set_from_paintable(Gdk.Texture.for_pixbuf(pb));
                    img.add_css_class("dock-resource-thumb");
                    return;
                } catch (Error e) { /* fall through */ }
            }
            // Use the file's own GIO icon (standard::icon) - that's the full
            // hicolor themed icon the file manager shows, not a symbolic one.
            img.gicon = gicon_for(file, ct);
        }

        // Resolve a file's themed icon the way singularity-files does:
        // prefer standard::icon from the FileInfo, fall back to the MIME
        // content-type icon.
        private GLib.Icon gicon_for(GLib.File file, string? ct) {
            try {
                var info = file.query_info("standard::icon", FileQueryInfoFlags.NONE);
                var ic = info.get_icon();
                if (ic != null) return ic;
            } catch (Error e) {}
            return icon_for_content_type(ct);
        }

        // Folder visual: polaroid fan when media-heavy, else folder icon
        private Widget build_folder_visual(GLib.File dir, string path, int icon_size) {
            var media = collect_media(path, 3);
            int total = count_entries(path);
            if (media.length >= 2 && media.length * 2 >= int.min(total, 6))
                return build_polaroid_fan(media, icon_size);
            var img = new Gtk.Image();
            img.pixel_size = icon_size;
            img.gicon = gicon_for(dir, "inode/directory");
            return img;
        }

        private Widget build_polaroid_fan(string[] media_paths, int icon_size) {
            var overlay = new Gtk.Overlay();
            overlay.set_size_request(icon_size, icon_size);
            overlay.add_css_class("dock-polaroid-fan");
            int shown = int.min(3, media_paths.length);
            int thumb = (int)(icon_size * 0.74);
            int[] offx = { -6, 2, 8 };
            int[] offy = { 6, 0, -5 };
            for (int i = 0; i < shown; i++) {
                var pic = new Gtk.Picture();
                pic.content_fit = ContentFit.COVER;
                pic.can_shrink = true;
                pic.set_size_request(thumb, thumb);
                pic.add_css_class("dock-polaroid");
                pic.overflow = Overflow.HIDDEN;
                pic.halign = Align.CENTER;
                pic.valign = Align.CENTER;
                pic.margin_start = int.max(0, offx[i]);
                pic.margin_end   = int.max(0, -offx[i]);
                pic.margin_top   = int.max(0, offy[i]);
                pic.margin_bottom = int.max(0, -offy[i]);
                try {
                    var pb = new Gdk.Pixbuf.from_file_at_scale(media_paths[i], thumb, thumb, true);
                    pic.set_paintable(Gdk.Texture.for_pixbuf(pb));
                } catch (Error e) {}
                if (i == 0) overlay.set_child(pic);
                else overlay.add_overlay(pic);
            }
            return overlay;
        }

        // Folder popover (opens instantly; thumbnails fill in async)
        private void open_folder_popover(Gtk.Widget anchor, GLib.File dir) {
            var pop = new Gtk.Popover();
            pop.set_parent(anchor);
            pop.add_css_class("dock-folder-popover");

            var scroller = new Gtk.ScrolledWindow();
            scroller.max_content_height = 360;
            scroller.min_content_width = 320;
            scroller.propagate_natural_height = true;
            scroller.hscrollbar_policy = PolicyType.NEVER;

            var flow = new Gtk.FlowBox();
            flow.max_children_per_line = 4;
            flow.min_children_per_line = 4;
            flow.selection_mode = SelectionMode.NONE;
            flow.homogeneous = true;
            flow.margin_start = 8; flow.margin_end = 8;
            flow.margin_top = 8;   flow.margin_bottom = 8;

            // Collect entries fast (no thumbnail decode here) so the popover
            // appears instantly; image thumbnails are decoded lazily in idle
            // callbacks afterwards - decoding inline would kill the snappy
            // feel.
            var pending = new GLib.GenericArray<ThumbJob>();
            try {
                var en = dir.enumerate_children(
                    "standard::name,standard::content-type,standard::is-hidden,standard::icon",
                    FileQueryInfoFlags.NONE);
                FileInfo? info;
                int shown = 0;
                while ((info = en.next_file()) != null && shown < 64) {
                    if (info.get_is_hidden()) continue;
                    var child = dir.resolve_relative_path(info.get_name());
                    string path = child.get_path() ?? "";
                    string? ct = info.get_content_type();

                    var img = new Gtk.Image();
                    img.pixel_size = 56;
                    img.gicon = info.get_icon() ?? icon_for_content_type(ct);

                    var entry = build_popover_entry(child, info.get_name(), img, pop);
                    flow.append(entry);

                    if (ct != null && ct.has_prefix("image/") && path != "") {
                        var job = new ThumbJob();
                        job.path = path; job.img = img;
                        pending.add(job);
                    }
                    shown++;
                }
            } catch (Error e) {
                flow.append(new Gtk.Label(_("Couldn't read folder")));
            }

            scroller.set_child(flow);
            pop.set_child(scroller);
            pop.popup();

            // Decode thumbnails one per idle tick so the UI stays responsive.
            int idx = 0;
            GLib.Idle.add(() => {
                if (idx >= pending.length) return GLib.Source.REMOVE;
                var job = pending[idx++];
                try {
                    var pb = new Gdk.Pixbuf.from_file_at_scale(job.path, 56, 56, true);
                    job.img.set_from_paintable(Gdk.Texture.for_pixbuf(pb));
                } catch (Error e) {}
                return GLib.Source.CONTINUE;
            });
        }

        private class ThumbJob : Object {
            public string path;
            public Gtk.Image img;
        }

        private Widget build_popover_entry(GLib.File file, string name,
                                           Gtk.Image img, Gtk.Popover pop) {
            var box = new Gtk.Box(Orientation.VERTICAL, 4);
            box.add_css_class("dock-folder-entry");
            var btn = new Button();
            btn.has_frame = false;
            btn.set_child(img);
            btn.clicked.connect(() => {
                string p = file.get_path() ?? "";
                if (p != "" && FileUtils.test(p, FileTest.IS_DIR))
                    open_in_files(p);          // navigate Files INTO the folder
                else
                    launch_uri(file.get_uri()); // open file with default app
                pop.popdown();
            });
            box.append(btn);
            var lbl = new Gtk.Label(name);
            lbl.ellipsize = Pango.EllipsizeMode.MIDDLE;
            lbl.max_width_chars = 10;
            lbl.add_css_class("caption");
            box.append(lbl);
            return box;
        }

        // Helpers
        private string? content_type_for(GLib.File file) {
            try {
                var info = file.query_info("standard::content-type", FileQueryInfoFlags.NONE);
                return info.get_content_type();
            } catch (Error e) { return null; }
        }

        private GLib.Icon icon_for_content_type(string? ct) {
            if (ct == null) return new ThemedIcon("text-x-generic");
            return GLib.ContentType.get_icon(ct);
        }

        private string[] collect_media(string dir_path, int max) {
            string[] result = {};
            try {
                var dir = File.new_for_path(dir_path);
                var en = dir.enumerate_children(
                    "standard::name,standard::content-type,standard::is-hidden",
                    FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = en.next_file()) != null && result.length < max) {
                    if (info.get_is_hidden()) continue;
                    string? ct = info.get_content_type();
                    if (ct != null && ct.has_prefix("image/")) {
                        var child = dir.resolve_relative_path(info.get_name());
                        string? p = child.get_path();
                        if (p != null) result += p;
                    }
                }
            } catch (Error e) {}
            return result;
        }

        private int count_entries(string dir_path) {
            int n = 0;
            try {
                var dir = File.new_for_path(dir_path);
                var en = dir.enumerate_children("standard::name,standard::is-hidden",
                    FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = en.next_file()) != null && n < 50)
                    if (!info.get_is_hidden()) n++;
            } catch (Error e) {}
            return n;
        }

        private void launch_uri(string uri) {
            if (uri.has_prefix("file://")) {
                Singularity.Widgets.FileOpener.open(File.new_for_uri(uri), null);
                return;
            }
            try { GLib.AppInfo.launch_default_for_uri(uri, null); }
            catch (Error e) { warning("dock resource: launch %s: %s", uri, e.message); }
        }

        // Open singularity-files navigated INTO the given directory path.
        private void open_in_files(string dir_path) {
            try {
                Process.spawn_command_line_async(
                    AppSystem.resolve_companion_bin("singularity-files") + " " + GLib.Shell.quote(dir_path));
            } catch (Error e) { warning("open_in_files: %s", e.message); }
        }

        private void reveal_in_files(string uri) {
            var f = File.new_for_uri(uri);
            var parent = f.get_parent();
            string target = (parent != null ? parent : f).get_path() ?? "";
            if (target == "") return;
            try {
                Process.spawn_command_line_async(
                    AppSystem.resolve_companion_bin("singularity-files") + " " + GLib.Shell.quote(target));
            } catch (Error e) { warning("reveal: %s", e.message); }
        }
    }
}
