using GLib;
using Gee;

namespace Singularity {
    internal class WallpaperCandidate : Object {
        public string uri { get; private set; }
        public bool is_recent { get; private set; }

        public WallpaperCandidate(string uri, bool is_recent) {
            this.uri = uri;
            this.is_recent = is_recent;
        }
    }

    internal class WallpaperGallery : Object {
        // Membership comes from the selected scan. History can reorder its
        // members, but must never introduce images from another source.
        public static ArrayList<WallpaperCandidate> scan(string? selected_dir,
                                                        string[] collection_dirs,
                                                        string[] recent) {
            var scanned = new ArrayList<WallpaperCandidate>();
            var members = new HashSet<string>();
            var excluded = new HashSet<string>();
            var result = new ArrayList<WallpaperCandidate>();
            if (selected_dir == null) return result;
            string root = canonical_path(selected_dir);
            foreach (string dir in collection_dirs) {
                string other = canonical_path(dir);
                if (other != root) excluded.add(other);
            }
            scan_wallpaper_dir(root, scanned, members, new HashSet<string>(), excluded, 0);
            var added = new HashSet<string>();
            foreach (string uri in recent) {
                if (members.contains(uri) && added.add(uri))
                    result.add(new WallpaperCandidate(uri, true));
            }
            foreach (var candidate in scanned) {
                if (added.add(candidate.uri)) result.add(candidate);
            }
            return result;
        }

        // Bound traversal of user-controlled collection directories.
        private const int WALLPAPER_SCAN_MAX_DEPTH = 3;

        // Dir= values across .collection files may point at the same
        // directory through different symlinks (a pack install living
        // outside /usr/share is a common layout) -- resolve to the real
        // path before comparing, or the source-boundary exclusion above
        // silently fails to recognize them as the same root.
        private static string canonical_path(string path) {
            string? real = Posix.realpath(path, null);
            return real ?? File.new_for_path(path).get_path();
        }

        // Other registered roots are separate sources, even when nested.
        private static void scan_wallpaper_dir(string path,
                                               ArrayList<WallpaperCandidate> candidates,
                                               HashSet<string> thread_seen,
                                               HashSet<string> visited_dirs,
                                               HashSet<string> excluded_dirs,
                                               int depth) {
            if (depth > WALLPAPER_SCAN_MAX_DEPTH || excluded_dirs.contains(path)) return;
            if (visited_dirs.contains(path)) return;
            visited_dirs.add(path);

            try {
                var dir = File.new_for_path(path);
                if (!dir.query_exists()) return;
                var enumerator = dir.enumerate_children(
                    "standard::name,standard::content-type,standard::type,standard::is-symlink,standard::symlink-target",
                    FileQueryInfoFlags.NONE, null);
                FileInfo info;
                while ((info = enumerator.next_file(null)) != null) {
                    var child = dir.get_child(info.get_name());

                    if (info.get_file_type() == FileType.DIRECTORY) {
                        // Not followed as a directory either: a symlinked
                        // directory is the easy way to walk in a circle.
                        if (info.get_is_symlink()) continue;
                        scan_wallpaper_dir(child.get_path(), candidates, thread_seen,
                                           visited_dirs, excluded_dirs, depth + 1);
                        continue;
                    }

                    // default.jpg is a symlink the rotator repoints at whichever
                    // wallpaper is current, at a target enumerated in this same
                    // directory -- following it would list one image twice, once
                    // under its own name and once as "default". Only elide a
                    // same-directory pointer like that one: a pack that ships an
                    // image as a symlink to a shared asset OUTSIDE this directory
                    // is real content, and the previous scanner listed it fine
                    // (content-type resolves through the link either way, since
                    // enumerate_children above passes no NOFOLLOW flag).
                    if (info.get_is_symlink()) {
                        string? target = info.get_symlink_target();
                        if (target != null) {
                            string resolved = Path.is_absolute(target)
                                ? target
                                : Path.build_filename(path, target);
                            if (Path.get_dirname(resolved) == path) continue;
                        }
                    }

                    string mime = info.get_content_type();
                    if (mime == null || !mime.has_prefix("image/")) continue;

                    string uri = child.get_uri();
                    if (thread_seen.contains(uri)) continue;
                    thread_seen.add(uri);
                    candidates.add(new WallpaperCandidate(uri, false));
                }
            } catch (Error e) {
            }
        }

    }
}
