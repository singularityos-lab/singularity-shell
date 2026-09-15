using GLib;
using Gee;

namespace Singularity {
    // Persistent cache for remote OCS preview bytes. Decoding remains the
    // browser's responsibility so the original image format is preserved.
    public class WallpaperThumbnailCache : Object {
        // Enough for a large working set of previews without allowing an OCS
        // crawl to consume the user's cache directory without bound.
        public const uint64 BYTE_BUDGET = 200 * 1024 * 1024;

        private bool size_known = false;
        private uint64 known_size = 0;

        private class CacheFile : Object {
            public File file;
            public uint64 size;
            public uint64 modified;

            public CacheFile(File file, uint64 size, uint64 modified) {
                this.file = file;
                this.size = size;
                this.modified = modified;
            }
        }

        public static string directory() {
            return Path.build_filename(Environment.get_user_cache_dir(),
                "singularity", "wallpaper-thumbnails");
        }

        private static string path_for(string url) {
            string key = Checksum.compute_for_string(ChecksumType.SHA256, url);
            return Path.build_filename(directory(), key);
        }

        // Missing, empty and unreadable entries are all ordinary cache misses.
        public new Bytes? get(string url) {
            string path = path_for(url);
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return null;
            try {
                uint8[] data;
                FileUtils.get_data(path, out data);
                if (data.length == 0) return null;
                // mtime is the LRU clock. Failure to touch it does not make an
                // otherwise valid cache entry unusable.
                try {
                    File.new_for_path(path).set_attribute_uint64(
                        FileAttribute.TIME_MODIFIED,
                        (uint64) new DateTime.now_utc().to_unix(),
                        FileQueryInfoFlags.NONE, null);
                } catch (Error e) {}
                return new Bytes.take((owned) data);
            } catch (Error e) {
                message("Discarding unreadable wallpaper thumbnail cache %s: %s",
                    path, e.message);
                return null;
            }
        }

        // Best effort and atomic: cache failures never interrupt browsing.
        public void put(string url, Bytes data) {
            if (data.get_size() == 0) return;
            string dir = directory();
            if (DirUtils.create_with_parents(dir, 0700) != 0) {
                message("Could not create wallpaper thumbnail cache directory %s", dir);
                return;
            }

            if (!size_known) refresh_size();
            string path = path_for(url);
            uint64 replaced_size = file_size(path);
            string temporary = Path.build_filename(dir,
                ".thumbnail-" + Uuid.string_random() + ".tmp");
            try {
                unowned uint8[] contents = data.get_data();
                FileUtils.set_data(temporary, contents);
                if (FileUtils.rename(temporary, path) != 0) {
                    FileUtils.unlink(temporary);
                    message("Could not move wallpaper thumbnail cache %s into place", path);
                    return;
                }
                known_size = known_size >= replaced_size
                    ? known_size - replaced_size + data.get_size()
                    : data.get_size();
                if (known_size > BYTE_BUDGET) evict();
            } catch (Error e) {
                FileUtils.unlink(temporary);
                message("Could not write wallpaper thumbnail cache %s: %s", path, e.message);
            }
        }

        private static uint64 file_size(string path) {
            try {
                return File.new_for_path(path).query_info(FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null).get_size();
            } catch (Error e) {
                return 0;
            }
        }

        private void refresh_size() {
            known_size = 0;
            try {
                var dir = File.new_for_path(directory());
                var enumerator = dir.enumerate_children(
                    "standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo info;
                while ((info = enumerator.next_file(null)) != null)
                    if (info.get_file_type() == FileType.REGULAR)
                        known_size += info.get_size();
            } catch (Error e) {}
            size_known = true;
        }

        private void evict() {
            var entries = new ArrayList<CacheFile>();
            uint64 total = 0;
            try {
                var dir = File.new_for_path(directory());
                var enumerator = dir.enumerate_children(
                    "standard::name,standard::type,standard::size,time::modified",
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo info;
                while ((info = enumerator.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.REGULAR) continue;
                    var entry = new CacheFile(dir.get_child(info.get_name()),
                        info.get_size(), info.get_attribute_uint64(FileAttribute.TIME_MODIFIED));
                    entries.add(entry);
                    total += entry.size;
                }
                entries.sort((a, b) => a.modified < b.modified ? -1
                    : (a.modified > b.modified ? 1 : 0));
                foreach (var entry in entries) {
                    if (total <= BYTE_BUDGET) break;
                    try {
                        entry.file.delete(null);
                        total -= entry.size;
                    } catch (Error e) {}
                }
            } catch (Error e) {}
            known_size = total;
        }
    }
}
