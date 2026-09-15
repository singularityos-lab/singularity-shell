using GLib;

namespace Singularity {

// Pure-data result of reading a wallpaper's sibling <basename>.json sidecar.
// Three flavours drive the contract:
//   * OCS (origin="ocs"): title from image.title, author from artist.name.
//   * Bing (provider="bing"): title from caption, author from copyright.
//   * anything else / missing / malformed: valid=false, both empty. The
//     caller MUST treat valid=false as "clear the attribution overlay"; a
//     stale OCS attribution from a previous wallpaper must never bleed
//     through a plain local photo or a partial sidecar.
//
// `valid` is the discriminator; the caller does not need to check whether
// the JSON was well-formed separately. A sidecar with partial metadata
// (e.g. only title, no artist) reports valid=true with one field set and
// the other empty -- the overlay renders what it has.
public struct WallpaperAttribution {
    public string title;
    public string author;
    public string source;
    public string page_url;
    public string license_url;
    public bool valid;
}

// Read <basename>.json next to `path` (a local image file) and return
// attribution metadata for the desktop overlay. The contract:
//   * path may be a relative or absolute filesystem path; URI schemes
//     are not supported (the caller resolves file:// URIs to paths first
//     via GLib.File.get_path()).
//   * A missing or non-regular sidecar returns valid=false (the common
//     case for plain local photos).
//   * Each optional field is read defensively -- absent, null,
//     non-string, non-object, or empty-string collapses to "".
//   * A JSON top-level value that is not an object (array, number,
//     bool, null) returns valid=false without crashing.
//   * An unrecognised sidecar returns valid=false.
//
// Pure function: no GSettings, no I/O outside the sidecar file. Tests
// can construct fixture directories and exercise every branch without
// booting a GTK application.
public class WallpaperSidecar : GLib.Object {
    // Already-normalized fields are plain Label text, never markup.
    public static string display_text(WallpaperAttribution metadata) {
        if (!metadata.valid) return "";
        string result = metadata.title;
        if (metadata.author != "") result += (result != "" ? "\n" : "") + metadata.author;
        if (metadata.source != "") result += (result != "" ? "\n" : "") + metadata.source;
        return result;
    }

    private static string text(Json.Object obj, string field) {
        var node = obj.get_member(field);
        return node != null && node.get_value_type() == typeof(string) ? node.get_string() : "";
    }
    // Provider metadata is HTML content, never Pango markup. Strip tags
    // before decoding entities so encoded literal angle brackets survive.
    public static string plain_text(string text) {
        try {
            var tags = new Regex("<!--[\\s\\S]*?-->|</?[A-Za-z][^>]*>");
            string plain = tags.replace_literal(text, -1, 0, "");
            return plain.replace("&nbsp;", " ").replace("&copy;", "©")
                .replace("&quot;", "\"").replace("&#39;", "'")
                .replace("&apos;", "'").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&amp;", "&").strip();
        } catch (RegexError e) {
            return text;
        }
    }
    public static WallpaperAttribution read(string path) {
        var result = WallpaperAttribution() { title = "", author = "", source = "", page_url = "", license_url = "", valid = false };
        if (path == null || path == "") return result;
        // Sidecar sits next to the image: e.g.
        //   /var/cache/.../pling-123-01-foo.jpg  ->  pling-123-01-foo.json
        string basename = Path.get_basename(path);
        int dot = basename.last_index_of(".");
        if (dot <= 0) return result;
        string sidecar_name = basename.substring(0, dot) + ".json";
        string sidecar_path = Path.build_filename(Path.get_dirname(path), sidecar_name);
        if (!FileUtils.test(sidecar_path, FileTest.IS_REGULAR)) return result;
        string data;
        try {
            FileUtils.get_contents(sidecar_path, out data);
        } catch (Error e) {
            return result;
        }
        var parser = new Json.Parser();
        try {
            parser.load_from_data(data);
        } catch (Error e) {
            return result;
        }
        Json.Node? root = parser.get_root();
        if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return result;
        Json.Object obj = root.get_object();
        // The OCS and Bing helpers use different provenance discriminators.
        string origin = "";
        var onode = obj.get_member("origin");
        if (onode != null && onode.get_value_type() == typeof(string))
            origin = onode.get_string();
        if (origin == "ocs") {
            result.source = "OCS Network";
            // OCS shape: the image record carries the title; artist is top-level.
            var inode = obj.get_member("image");
            if (inode != null && inode.get_node_type() == Json.NodeType.OBJECT) {
                var img = inode.get_object();
                var tnode = img.get_member("title");
                if (tnode != null && tnode.get_value_type() == typeof(string)) {
                    string t = tnode.get_string().strip();
                    if (t != "") result.title = t;
                }
            }
            var anode = obj.get_member("artist");
            if (anode != null && anode.get_node_type() == Json.NodeType.OBJECT) {
                var artist = anode.get_object();
                var nnode = artist.get_member("name");
                if (nnode != null && nnode.get_value_type() == typeof(string)) {
                    string a = nnode.get_string().strip();
                    if (a != "") result.author = a;
                }
            }
            result.valid = true;
        } else {
            string provider = "";
            var pnode = obj.get_member("provider");
            if (pnode != null && pnode.get_value_type() == typeof(string))
                provider = pnode.get_string();
            if (provider == "openverse") {
                result.title = text(obj, "name");
                // The OpenAPI schema explicitly defines attribution as plain
                // text. Do not strip literal angle brackets from that field.
                result.author = text(obj, "attribution");
                if (result.author == "") result.author = text(obj, "author");
                result.source = "Openverse · " + text(obj, "license") + " " + text(obj, "license_version");
                result.page_url = text(obj, "page_url");
                result.license_url = text(obj, "license_url");
                result.valid = true;
                return result;
            }
            if (provider == "unsplash") {
                result.title = text(obj, "name");
                result.author = text(obj, "attribution");
                if (result.author == "") result.author = text(obj, "author");
                result.source = "Unsplash · " + text(obj, "license");
                result.page_url = text(obj, "page_url");
                result.license_url = text(obj, "license_url");
                result.valid = true;
                return result;
            }
            if (provider != "bing") return result;
            result.source = "Bing";
            // Bing shape: caption -> title, copyright -> author.
            var cnode = obj.get_member("caption");
            if (cnode != null && cnode.get_value_type() == typeof(string)) {
                string c = cnode.get_string().strip();
                if (c != "") result.title = c;
            }
            var crnode = obj.get_member("copyright");
            if (crnode != null && crnode.get_value_type() == typeof(string)) {
                string c = crnode.get_string().strip();
                if (c != "") result.author = c;
            }
            result.valid = true;
        }
        result.title = plain_text(result.title);
        result.author = plain_text(result.author);
        return result;
    }
}
}
