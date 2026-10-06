using GLib;
using Gee;

namespace Singularity {

    public class WallpaperCollectionInfo : Object {
        // Vala rejects a GObject property named "type"; keep these as fields.
        public string id;
        public string name;
        public string artist;
        public string dir;
        public string type;
        public string origin;
        public string registry_path;
        public bool theme_pack;
        public bool deletable;
        private string deletion_home;

        public WallpaperCollectionInfo(string id, string name, string artist, string dir, string type,
                                       string origin = "", string registry_path = "",
                                       string? user_home = null) {
            this.id = id;
            this.name = name;
            this.artist = artist;
            this.dir = dir;
            this.type = type;
            this.origin = origin;
            this.registry_path = registry_path;
            deletion_home = user_home ?? Environment.get_home_dir();
            deletable = can_delete_now();
            theme_pack = id == "pling" || id == "kde-look" || id == "gnome-look" ||
                id == "bing" || id == "ocs" || id == "openverse" || id == "unsplash" || id == "imported-ocs" || id.has_prefix("ocs-");
        }

        private static bool path_is_within(string path, string parent) {
            string? real_path = Posix.realpath(path, null);
            string? real_parent = Posix.realpath(parent, null);
            if (real_path == null || real_parent == null) return false;
            return real_path == real_parent || real_path.has_prefix(real_parent + Path.DIR_SEPARATOR_S);
        }

        public bool contains_uri(string uri) {
            string? path = File.new_for_uri(uri).get_path();
            return path != null && path_is_within(path, dir);
        }

        public bool can_delete_now() {
            return origin.strip() != "" && registry_path != "" &&
                path_is_within(dir, deletion_home) && path_is_within(registry_path, deletion_home);
        }
    }

    public class WallpaperCollections : Object {
        // parse() is first-root-wins, so system collections take precedence.
        public static string[] default_search_roots() {
            string[] roots = {};
            foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                roots += GLib.Path.build_filename(d, "singularity", "wallpaper-collections");
            roots += GLib.Path.build_filename(
                GLib.Environment.get_user_data_dir(), "singularity", "wallpaper-collections");
            return roots;
        }

        private static string? builtin_directory() {
            string[] candidates = {};
            foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                candidates += GLib.Path.build_filename(d, "backgrounds", "singularity");
            candidates += GLib.Path.build_filename(
                GLib.Environment.get_user_data_dir(), "backgrounds", "singularity");

            // Keep development builds usable when the wallpaper subproject has
            // not been installed yet. These paths are only accepted when they
            // exist, so an installed desktop never depends on the checkout.
            string cwd = GLib.Environment.get_current_dir();
            candidates += GLib.Path.build_filename(cwd, "subprojects", "singularity-wallpapers");
            candidates += GLib.Path.build_filename(cwd, "..", "subprojects", "singularity-wallpapers");
            try {
                string exe = GLib.FileUtils.read_link("/proc/self/exe");
                string exe_dir = GLib.Path.get_dirname(exe);
                candidates += GLib.Path.build_filename(exe_dir, "..", "share", "backgrounds", "singularity");
                candidates += GLib.Path.build_filename(exe_dir, "..", "..", "subprojects", "singularity-wallpapers");
            } catch (Error e) {}

            foreach (string candidate in candidates) {
                if (FileUtils.test(candidate, FileTest.IS_DIR)) return candidate;
            }
            return null;
        }

        public static Gee.ArrayList<WallpaperCollectionInfo> parse(string[] search_roots) {
            var results = new Gee.ArrayList<WallpaperCollectionInfo>();
            var seen_ids = new Gee.HashSet<string>();
            bool use_builtin_fallback = false;
            foreach (string default_root in default_search_roots()) {
                foreach (string root in search_roots) {
                    if (root == default_root) {
                        use_builtin_fallback = true;
                        break;
                    }
                }
                if (use_builtin_fallback) break;
            }

            foreach (string root in search_roots) {
                try {
                    var dir = File.new_for_path(root);
                    if (!dir.query_exists()) continue;
                    var en = dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE, null);
                    FileInfo info;
                    while ((info = en.next_file(null)) != null) {
                        string filename = info.get_name();
                        if (!filename.has_suffix(".collection")) continue;

                        var kf = new GLib.KeyFile();
                        try {
                            kf.load_from_file(GLib.Path.build_filename(root, filename), GLib.KeyFileFlags.NONE);
                        } catch (Error e) {
                            continue; // malformed file, skip it
                        }

                        string collection_dir;
                        try {
                            collection_dir = kf.get_string("Collection", "Dir").strip();
                        } catch (Error e) {
                            continue; // Dir-less collection, skip it
                        }
                        if (collection_dir == "") continue;

                        string id;
                        try {
                            id = kf.get_string("Collection", "Id").strip();
                        } catch (Error e) {
                            id = "";
                        }
                        if (id == "") {
                            id = filename.substring(0, filename.length - ".collection".length);
                        }
                        if (!seen_ids.add(id)) continue; // first root wins

                        string name;
                        try { name = kf.get_string("Collection", "Name").strip(); }
                        catch (Error e) { name = ""; }
                        if (name == "") name = id;

                        string artist;
                        try { artist = kf.get_string("Collection", "Artist").strip(); }
                        catch (Error e) { artist = ""; }

                        string type;
                        try { type = kf.get_string("Collection", "Type").strip(); }
                        catch (Error e) { type = ""; }
                        if (type == "") type = "static";

                        string origin;
                        try { origin = kf.get_string("Collection", "Origin").strip(); }
                        catch (Error e) { origin = ""; }

                        results.add(new WallpaperCollectionInfo(id, name, artist, collection_dir, type,
                            origin, GLib.Path.build_filename(root, filename)));
                    }
                } catch (Error e) {
                    continue;
                }
            }
            if (!use_builtin_fallback) return results;

            string? builtin_dir = builtin_directory();
            int builtin_index = -1;
            for (int i = 0; i < results.size; i++) {
                if (results[i].id == "singularity") {
                    builtin_index = i;
                    break;
                }
            }
            if (builtin_dir != null) {
                var builtin = new WallpaperCollectionInfo(
                    "singularity", "Singularity", "Singularity", builtin_dir, "static");
                if (builtin_index >= 0) results[builtin_index] = builtin;
                else results.insert(0, builtin);
            }
            return results;
        }


        private static void remove_tree(File file) throws Error {
            FileType type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            if (type == FileType.DIRECTORY) {
                var en = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo child;
                while ((child = en.next_file(null)) != null)
                    remove_tree(file.get_child(child.get_name()));
            }
            file.delete(null);
        }

        private static int image_count(string dir) throws Error {
            int count = 0;
            var en = File.new_for_path(dir).enumerate_children(
                "standard::content-type,standard::type", FileQueryInfoFlags.NONE, null);
            FileInfo info;
            while ((info = en.next_file(null)) != null) {
                string? mime = info.get_content_type();
                if (info.get_file_type() == FileType.REGULAR && mime != null && mime.has_prefix("image/")) count++;
            }
            return count;
        }

        private static void update_legacy_manifest(string dir, string basename) throws Error {
            string path = Path.build_filename(dir, "pack.json");
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return;
            var parser = new Json.Parser();
            parser.load_from_file(path);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
            var obj = root.get_object();
            if (!obj.has_member("images") || obj.get_member("images").get_node_type() != Json.NodeType.ARRAY) return;
            var images = obj.get_array_member("images");
            for (uint i = images.get_length(); i > 0; i--) {
                var node = images.get_element(i - 1);
                if (node.get_node_type() == Json.NodeType.OBJECT &&
                    node.get_object().has_member("file") &&
                    node.get_object().get_string_member("file") == basename)
                    images.remove_element(i - 1);
            }
            var generator = new Json.Generator();
            generator.set_root(root);
            generator.to_file(path);
        }

        public static void delete_pack(WallpaperCollectionInfo collection) throws Error {
            if (!collection.can_delete_now())
                throw new IOError.PERMISSION_DENIED("Protected wallpaper collection");
            remove_tree(File.new_for_path(collection.dir));
            File.new_for_path(collection.registry_path).delete(null);
        }

        public static bool needs_background_fallback(WallpaperCollectionInfo collection, string active_uri) {
            return active_uri != "" && collection.contains_uri(active_uri);
        }

        public static bool is_dynamic_entry(string uri) {
            string? path = File.new_for_uri(uri).get_path();
            return path != null && DynamicWallpaper.is_dynamic_path(path);
        }

        private static string? real_location(string path) {
            string? parent = Posix.realpath(Path.get_dirname(path), null);
            if (parent == null) return null;
            return Path.build_filename(parent, Path.get_basename(path));
        }

        private static bool is_removable(string path) {
            var type = File.new_for_path(path).query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            return type == FileType.REGULAR || type == FileType.SYMBOLIC_LINK;
        }

        private static void find_dynamic_manifests(string dir, int depth, GenericArray<string> found) {
            try {
                var en = File.new_for_path(dir).enumerate_children("standard::name,standard::type",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo info;
                while ((info = en.next_file(null)) != null) {
                    string child = Path.build_filename(dir, info.get_name());
                    if (info.get_file_type() == FileType.DIRECTORY) {
                        if (depth < 2) find_dynamic_manifests(child, depth + 1, found);
                    } else if (info.get_file_type() == FileType.REGULAR && DynamicWallpaper.is_dynamic_path(child)) {
                        found.add(child);
                    }
                }
            } catch (Error e) {
            }
        }

        private static bool tree_has_files(File dir) {
            try {
                var en = dir.enumerate_children("standard::name,standard::type",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo info;
                while ((info = en.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.DIRECTORY) return true;
                    if (tree_has_files(dir.get_child(info.get_name()))) return true;
                }
            } catch (Error e) {
                return true;
            }
            return false;
        }

        private static string[] dynamic_images(DynamicWallpaper wp) {
            string[] list = wp.images();
            if (wp.preview != "") list += wp.preview;
            return list;
        }

        public static string[] dynamic_files_to_delete(WallpaperCollectionInfo collection, string manifest) {
            string? real_manifest = real_location(manifest);
            string? real_root = Posix.realpath(collection.dir, null);
            string? real_owner = Posix.realpath(Path.get_dirname(manifest), null);
            if (real_manifest == null || real_root == null || real_owner == null) return {};
            if (real_owner != real_root && !real_owner.has_prefix(real_root + Path.DIR_SEPARATOR_S)) return {};
            DynamicWallpaper wp;
            try {
                wp = DynamicWallpaper.load(manifest);
            } catch (Error e) {
                return {};
            }
            var shared = new Gee.HashSet<string>();
            var others = new GenericArray<string>();
            find_dynamic_manifests(collection.dir, 0, others);
            foreach (string other in others.data) {
                string? real_other = real_location(other);
                if (real_other == null || real_other == real_manifest) continue;
                try {
                    foreach (string img in dynamic_images(DynamicWallpaper.load(other))) {
                        string? r = real_location(img);
                        if (r != null) shared.add(r);
                    }
                } catch (Error e) {
                }
            }
            var result = new Gee.ArrayList<string>();
            foreach (string img in dynamic_images(wp)) {
                if (img == "" || !Path.is_absolute(img)) continue;
                string? real_img = real_location(img);
                if (real_img == null || real_img == real_manifest) continue;
                if (!real_img.has_prefix(real_owner + Path.DIR_SEPARATOR_S)) continue;
                if (shared.contains(real_img) || result.contains(real_img)) continue;
                if (!is_removable(real_img)) continue;
                result.add(real_img);
            }
            return result.to_array();
        }

        private static bool delete_dynamic(WallpaperCollectionInfo collection, string manifest) throws Error {
            string[] frames = dynamic_files_to_delete(collection, manifest);
            foreach (string frame in frames) File.new_for_path(frame).delete(null);
            File.new_for_path(manifest).delete(null);
            string? real_root = Posix.realpath(collection.dir, null);
            string? real_owner = Posix.realpath(Path.get_dirname(manifest), null);
            if (real_root != null && real_owner != null && real_owner != real_root
                    && real_owner.has_prefix(real_root + Path.DIR_SEPARATOR_S)
                    && !tree_has_files(File.new_for_path(real_owner))) {
                remove_tree(File.new_for_path(real_owner));
            }
            if (!tree_has_files(File.new_for_path(collection.dir))) {
                delete_pack(collection);
                return true;
            }
            return false;
        }

        // Returns true when deleting the final image also removed the empty pack.
        public static bool delete_image(WallpaperCollectionInfo collection, string uri) throws Error {
            if (!collection.can_delete_now() || !collection.contains_uri(uri))
                throw new IOError.PERMISSION_DENIED("Protected wallpaper image");
            var image = File.new_for_uri(uri);
            string? path = image.get_path();
            string? basename = image.get_basename();
            if (path == null || basename == null || image.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null) != FileType.REGULAR)
                throw new IOError.INVALID_ARGUMENT("Wallpaper image is not a regular file");
            if (DynamicWallpaper.is_dynamic_path(path)) return delete_dynamic(collection, path);
            image.delete(null);
            int dot = basename.last_index_of(".");
            if (dot > 0) {
                var sidecar = File.new_for_path(Path.build_filename(collection.dir, basename.substring(0, dot) + ".json"));
                if (sidecar.query_exists(null)) sidecar.delete(null);
            }
            update_legacy_manifest(collection.dir, basename);
            if (image_count(collection.dir) == 0) {
                delete_pack(collection);
                return true;
            }
            return false;
        }
    }
}
