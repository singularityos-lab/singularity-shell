using GLib;
using Gee;

namespace Singularity {
    public errordomain WallpaperOcsError { INVALID }
    public class WallpaperOcsChoice : Object {
        public string id;
        public string name;
        public WallpaperOcsChoice(string id, string name) { this.id = id; this.name = name; }
    }
    public class WallpaperOcsItem : Object {
        public string provider = "";
        public string id = "";
        public string name = "";
        public string author = "";
        public string license = "";
        public string preview = "";
        public string key { owned get { return provider + ":" + id; } }
    }
    // JSON from the helper is untrusted. Check types before Json-GLib getters,
    // which otherwise emit criticals (fatal in the GLib.Test harness).
    public class WallpaperOcs : Object {
        internal static Json.Object object_node(Json.Node? node) throws Error {
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT)
                throw new WallpaperOcsError.INVALID("Expected a JSON object");
            return node.get_object();
        }
        internal static Json.Object document(string data, bool schema = true) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(data);
            var obj = object_node(parser.get_root());
            if (schema) {
                var node = obj.get_member("schema");
                if (node == null || node.get_value_type() != typeof(int64) || node.get_int() != 1)
                    throw new WallpaperOcsError.INVALID("Unsupported OCS response schema");
            }
            return obj;
        }
        internal static string text(Json.Object obj, string field, bool required = true) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.is_null()) {
                if (!required) return "";
                throw new WallpaperOcsError.INVALID("Missing OCS field: " + field);
            }
            if (node.get_value_type() != typeof(string))
                throw new WallpaperOcsError.INVALID("Invalid OCS field: " + field);
            string value = node.get_string();
            if (required && value.strip() == "")
                throw new WallpaperOcsError.INVALID("Empty OCS field: " + field);
            return value;
        }
        internal static Json.Array array(Json.Object obj, string field) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY)
                throw new WallpaperOcsError.INVALID("Invalid OCS list: " + field);
            return node.get_array();
        }
        internal static bool numeric_id(string id) {
            if (id.length == 0) return false;
            foreach (char c in id.to_utf8()) if (c < '0' || c > '9') return false;
            return true;
        }
        internal static bool provider_id(string id) {
            return id == "pling" || id == "opendesktop" || id == "kde-look" || id == "gnome-look";
        }
        public static ArrayList<WallpaperOcsChoice> providers(string data) throws Error {
            var obj = object_node(document(data).get_member("providers"));
            var result = new ArrayList<WallpaperOcsChoice>();
            foreach (string id in obj.get_members()) {
                if (!provider_id(id)) throw new WallpaperOcsError.INVALID("Unknown OCS provider: " + id);
                text(object_node(obj.get_member(id)), "base");
                result.add(new WallpaperOcsChoice(id, id));
            }
            result.sort((a, b) => strcmp(a.id, b.id));
            return result;
        }
        public static ArrayList<WallpaperOcsChoice> categories(string data, string provider) throws Error {
            var entries = array(document(data), "entries");
            var seen = new HashSet<string>();
            var result = new ArrayList<WallpaperOcsChoice>();
            foreach (var node in entries.get_elements()) {
                var entry = object_node(node);
                string reference = text(entry, "ref");
                if (!reference.has_prefix(provider + ":")) continue;
                string id = reference.substring(provider.length + 1);
                if (!numeric_id(id)) throw new WallpaperOcsError.INVALID("Invalid OCS category identity");
                var usable = entry.get_member("usable");
                if (usable == null || usable.get_value_type() != typeof(bool))
                    throw new WallpaperOcsError.INVALID("Invalid OCS category usability");
                if (!usable.get_boolean() || !seen.add(id)) continue;
                string name = text(entry, "display_name", false);
                if (name == "") name = text(entry, "name");
                result.add(new WallpaperOcsChoice(id, name));
            }
            result.sort((a, b) => a.name.collate(b.name));
            return result;
        }
        public static ArrayList<WallpaperOcsItem> items(string data, string provider, string category) throws Error {
            var obj = document(data);
            if (text(obj, "provider") != provider || text(obj, "category") != category)
                throw new WallpaperOcsError.INVALID("OCS response does not match the requested category");
            var result = new ArrayList<WallpaperOcsItem>();
            var seen = new HashSet<string>();
            foreach (var node in array(obj, "items").get_elements()) {
                var entry = object_node(node);
                var item = new WallpaperOcsItem();
                item.provider = text(entry, "provider");
                item.id = text(entry, "id");
                if (item.provider != provider || !provider_id(provider) || !numeric_id(item.id))
                    throw new WallpaperOcsError.INVALID("Invalid OCS item identity");
                item.name = text(entry, "name");
                item.author = text(entry, "author", false);
                item.license = text(entry, "license", false);
                item.preview = text(entry, "preview", false);
                if (seen.add(item.key)) result.add(item);
            }
            return result;
        }
    }
    // The backend owns disk writes. This model tracks an active import and
    // reconciles completed imports against its real registry/provenance files.
    public class WallpaperOcsImports : Object {
        private string active = "";
        private HashSet<string> added = new HashSet<string>();
        public bool busy { get { return active != ""; } }
        public bool begin(string key) {
            if (busy || added.contains(key)) return false;
            active = key;
            return true;
        }
        public void fail(string key) { if (active == key) active = ""; }
        public bool is_added(string key) { return added.contains(key); }
        private static string installed_key(string dir) throws Error {
            string data;
            FileUtils.get_contents(Path.build_filename(dir, "pack.json"), out data);
            var pack = WallpaperOcs.document(data, false);
            if (WallpaperOcs.text(pack, "origin") != "ocs") return "";
            string provider = WallpaperOcs.text(pack, "provider");
            string id = WallpaperOcs.text(WallpaperOcs.object_node(pack.get_member("source")), "ocs_id");
            if (!WallpaperOcs.provider_id(provider) || !WallpaperOcs.numeric_id(id)) return "";
            // Only the helper's normalized image files count, not metadata alone.
            var listing = Dir.open(dir);
            string? name;
            while ((name = listing.read_name()) != null) {
                if (name.has_suffix(".jpg") && FileUtils.test(Path.build_filename(dir, name), FileTest.IS_REGULAR))
                    return provider + ":" + id;
            }
            return "";
        }
        public void discover(ArrayList<WallpaperCollectionInfo> collections) {
            added.clear();
            foreach (var collection in collections) {
                try { string key = installed_key(collection.dir); if (key != "") added.add(key); }
                catch (Error e) { /* Absent/incomplete provenance is not an import. */ }
            }
        }
        public void complete(string key, string data, string[] roots) throws Error {
            if (active != key) throw new WallpaperOcsError.INVALID("No matching import is active");
            var obj = WallpaperOcs.document(data, false);
            string id = WallpaperOcs.text(obj, "pack_id");
            string dir = WallpaperOcs.text(obj, "destination");
            string collection_path = WallpaperOcs.text(obj, "collection");
            if (!Path.is_absolute(dir) || !FileUtils.test(collection_path, FileTest.IS_REGULAR) ||
                WallpaperOcs.text(obj, "pack_json") != Path.build_filename(dir, "pack.json"))
                throw new WallpaperOcsError.INVALID("Import did not produce registered pack files");
            bool registered = false;
            foreach (var collection in WallpaperCollections.parse(roots)) {
                if (collection.id == id && collection.dir == dir) registered = true;
            }
            if (!registered || installed_key(dir) != key)
                throw new WallpaperOcsError.INVALID("Imported pack is missing from the collection registry");
            var images = WallpaperOcs.array(obj, "images");
            if (images.get_length() == 0) throw new WallpaperOcsError.INVALID("Imported pack contains no images");
            foreach (var node in images.get_elements()) {
                string name = WallpaperOcs.text(WallpaperOcs.object_node(node), "file");
                if (name != Path.get_basename(name) || !name.has_suffix(".jpg") ||
                    !FileUtils.test(Path.build_filename(dir, name), FileTest.IS_REGULAR))
                    throw new WallpaperOcsError.INVALID("Imported image is missing");
            }
            added.add(key);
            active = "";
        }
    }
}
