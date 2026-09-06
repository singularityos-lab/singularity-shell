using GLib;
using Gee;

namespace Singularity {

    public class WallpaperCollectionInfo : Object {
        // Plain public fields, not GObject properties: Vala's property
        // system rejects a property literally named "type" ("error:
        // Property 'type' not allowed", collides with GObject's own type
        // machinery). Plain fields sidestep that and still match the
        // interface this class is documented to expose -- "public fields:
        // string id, string name, string artist, string dir, string type".
        public string id;
        public string name;
        public string artist;
        public string dir;
        public string type;

        public WallpaperCollectionInfo(string id, string name, string artist, string dir, string type) {
            this.id = id;
            this.name = name;
            this.artist = artist;
            this.dir = dir;
            this.type = type;
        }
    }

    // Parses the .collection registry (INI-shaped KeyFiles, one per pack or
    // provider) into a list of WallpaperCollectionInfo, in the priority order
    // the search roots are given -- a later root's file for the same Id is
    // ignored, matching "first root wins" so callers pass roots most-specific
    // (e.g. per-user) LAST if they want a user override to win, or FIRST if
    // they want the shipped default to win. desktop_page.vala's caller passes
    // system dirs then the user dir, so a user's own collection can override
    // one bundled with the OS.
    //
    // Callers pass explicit search_roots (not read from GLib.Environment
    // here) so this class stays testable against a temp directory with no
    // real filesystem layout assumptions.
    public class WallpaperCollections : Object {
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

                        results.add(new WallpaperCollectionInfo(id, name, artist, collection_dir, type));
                    }
                } catch (Error e) {
                    continue;
                }
            }
            return results;
        }
    }
}
