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

        public static Gee.ArrayList<WallpaperCollectionInfo> parse(string[] search_roots) {
            var results = new Gee.ArrayList<WallpaperCollectionInfo>();
            var seen_ids = new Gee.HashSet<string>();

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

        // Returns true when deleting the final image also removed the empty pack.
        public static bool delete_image(WallpaperCollectionInfo collection, string uri) throws Error {
            if (!collection.can_delete_now() || !collection.contains_uri(uri))
                throw new IOError.PERMISSION_DENIED("Protected wallpaper image");
            var image = File.new_for_uri(uri);
            string? path = image.get_path();
            string? basename = image.get_basename();
            if (path == null || basename == null || image.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null) != FileType.REGULAR)
                throw new IOError.INVALID_ARGUMENT("Wallpaper image is not a regular file");
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
