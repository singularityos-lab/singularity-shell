using GLib;

namespace Singularity {

    public class PlistValue : Object {
        public enum Kind { NULL, BOOL, INT, REAL, STRING, DATA, ARRAY, DICT }

        public Kind kind = Kind.NULL;
        public bool boolean;
        public int64 integer;
        public double real;
        public string text = "";
        public GenericArray<PlistValue> items = new GenericArray<PlistValue>();
        public HashTable<string, PlistValue> members = new HashTable<string, PlistValue>(str_hash, str_equal);

        public double number() {
            if (kind == Kind.REAL) return real;
            if (kind == Kind.INT) return (double) integer;
            if (kind == Kind.BOOL) return boolean ? 1.0 : 0.0;
            return double.NAN;
        }

        public PlistValue? get(string key) {
            return kind == Kind.DICT ? members.lookup(key) : null;
        }
    }

    public class BinaryPlist : Object {
        private uint8[] data;
        private int offset_size;
        private int ref_size;
        private int64 num_objects;
        private int64 table_offset;
        private int depth = 0;

        private BinaryPlist(uint8[] data) {
            this.data = data;
        }

        public static PlistValue parse(uint8[] bytes) throws Error {
            if (bytes.length < 40 || Memory.cmp(bytes, "bplist00".data, 8) != 0)
                throw new IOError.INVALID_DATA("Not a binary property list");
            var p = new BinaryPlist(bytes);
            int t = bytes.length - 32;
            p.offset_size = bytes[t + 6];
            p.ref_size = bytes[t + 7];
            p.num_objects = (int64) p.read_uint(t + 8, 8);
            int64 top = (int64) p.read_uint(t + 16, 8);
            p.table_offset = (int64) p.read_uint(t + 24, 8);
            if (p.offset_size < 1 || p.offset_size > 8 || p.ref_size < 1 || p.ref_size > 8)
                throw new IOError.INVALID_DATA("Bad property list trailer");
            if (p.table_offset + p.num_objects * p.offset_size > t || top >= p.num_objects)
                throw new IOError.INVALID_DATA("Bad property list offsets");
            return p.object_at(top);
        }

        private uint64 read_uint(int64 pos, int size) throws Error {
            if (pos < 0 || pos + size > data.length) throw new IOError.INVALID_DATA("Property list overflow");
            uint64 v = 0;
            for (int i = 0; i < size; i++) v = (v << 8) | data[pos + i];
            return v;
        }

        private int64 offset_of(int64 index) throws Error {
            if (index < 0 || index >= num_objects) throw new IOError.INVALID_DATA("Bad object reference");
            return (int64) read_uint(table_offset + index * offset_size, offset_size);
        }

        private int64 read_count(int info, ref int64 pos) throws Error {
            if (info != 0xF) return info;
            uint8 marker = (uint8) read_uint(pos, 1);
            if ((marker >> 4) != 0x1) throw new IOError.INVALID_DATA("Bad count");
            int size = 1 << (marker & 0xF);
            int64 count = (int64) read_uint(pos + 1, size);
            pos += 1 + size;
            return count;
        }

        private PlistValue object_at(int64 index) throws Error {
            if (++depth > 64) throw new IOError.INVALID_DATA("Property list too deep");
            var result = read_object(offset_of(index));
            depth--;
            return result;
        }

        private PlistValue read_object(int64 pos) throws Error {
            uint8 marker = (uint8) read_uint(pos, 1);
            int type = marker >> 4;
            int info = marker & 0xF;
            pos++;
            var v = new PlistValue();
            switch (type) {
                case 0x0:
                    if (info == 0x8 || info == 0x9) {
                        v.kind = PlistValue.Kind.BOOL;
                        v.boolean = info == 0x9;
                    }
                    return v;
                case 0x1: {
                    int size = 1 << info;
                    v.kind = PlistValue.Kind.INT;
                    uint64 raw = read_uint(pos, int.min(size, 8));
                    v.integer = size == 8 ? (int64) raw : (int64) raw;
                    return v;
                }
                case 0x2: {
                    int size = 1 << info;
                    v.kind = PlistValue.Kind.REAL;
                    uint64 raw = read_uint(pos, size);
                    if (size == 4) {
                        uint32 bits = (uint32) raw;
                        float f = *((float*) (&bits));
                        v.real = f;
                    } else if (size == 8) {
                        double d = *((double*) (&raw));
                        v.real = d;
                    } else {
                        throw new IOError.INVALID_DATA("Bad real size");
                    }
                    return v;
                }
                case 0x4:
                case 0x5: {
                    int64 count = read_count(info, ref pos);
                    if (pos + count > data.length) throw new IOError.INVALID_DATA("String overflow");
                    v.kind = type == 0x4 ? PlistValue.Kind.DATA : PlistValue.Kind.STRING;
                    var sb = new StringBuilder();
                    for (int64 i = 0; i < count; i++) sb.append_c((char) data[pos + i]);
                    v.text = sb.str;
                    return v;
                }
                case 0x6: {
                    int64 count = read_count(info, ref pos);
                    var sb = new StringBuilder();
                    for (int64 i = 0; i < count; i++) sb.append_unichar((unichar) read_uint(pos + i * 2, 2));
                    v.kind = PlistValue.Kind.STRING;
                    v.text = sb.str;
                    return v;
                }
                case 0xA: {
                    int64 count = read_count(info, ref pos);
                    v.kind = PlistValue.Kind.ARRAY;
                    for (int64 i = 0; i < count; i++)
                        v.items.add(object_at((int64) read_uint(pos + i * ref_size, ref_size)));
                    return v;
                }
                case 0xD: {
                    int64 count = read_count(info, ref pos);
                    v.kind = PlistValue.Kind.DICT;
                    for (int64 i = 0; i < count; i++) {
                        var key = object_at((int64) read_uint(pos + i * ref_size, ref_size));
                        var val = object_at((int64) read_uint(pos + (count + i) * ref_size, ref_size));
                        v.members.insert(key.text, val);
                    }
                    return v;
                }
                default:
                    return v;
            }
        }
    }

    public class HeicDynamicMetadata : Object {
        public string solar = "";
        public string h24 = "";
        public string apr = "";

        public bool found {
            get { return solar != "" || h24 != "" || apr != ""; }
        }

        public static HeicDynamicMetadata scan(uint8[] bytes) {
            var meta = new HeicDynamicMetadata();
            meta.solar = find_value(bytes, "apple_desktop:solar");
            meta.h24 = find_value(bytes, "apple_desktop:h24");
            meta.apr = find_value(bytes, "apple_desktop:apr");
            return meta;
        }

        private static int index_of(uint8[] hay, uint8[] needle, int from) {
            int n = needle.length;
            for (int i = from; i + n <= hay.length; i++) {
                if (hay[i] != needle[0]) continue;
                if (Memory.cmp(&hay[i], needle, n) == 0) return i;
            }
            return -1;
        }

        private static string find_value(uint8[] bytes, string name) {
            int pos = 0;
            while (true) {
                int at = index_of(bytes, name.data, pos);
                if (at < 0) return "";
                int i = at + name.length;
                while (i < bytes.length && (bytes[i] == ' ' || bytes[i] == '\n' || bytes[i] == '\r' || bytes[i] == '\t')) i++;
                char end = 0;
                if (i < bytes.length && bytes[i] == '=') {
                    i++;
                    while (i < bytes.length && bytes[i] == ' ') i++;
                    if (i < bytes.length && (bytes[i] == '"' || bytes[i] == '\'')) { end = (char) bytes[i]; i++; }
                } else if (i < bytes.length && bytes[i] == '>') {
                    i++;
                    end = '<';
                }
                if (end != 0) {
                    var sb = new StringBuilder();
                    while (i < bytes.length && bytes[i] != end && sb.len < 1048576) {
                        char c = (char) bytes[i];
                        if (!c.isspace()) sb.append_c(c);
                        i++;
                    }
                    if (sb.len > 0) return sb.str;
                }
                pos = at + 1;
            }
        }

        public static PlistValue decode(string base64) throws Error {
            return BinaryPlist.parse(Base64.decode(base64));
        }

        public DynamicWallpaper to_wallpaper(string[] frame_paths) throws Error {
            var wp = new DynamicWallpaper();
            if (solar != "") {
                var root = decode(solar);
                var list = root.get("si");
                if (list == null || list.kind != PlistValue.Kind.ARRAY) throw new IOError.INVALID_DATA("Solar metadata has no entries");
                wp.kind = DynamicWallpaperKind.SOLAR;
                foreach (var entry in list.items.data) {
                    int idx = (int) number_of(entry, "i");
                    if (idx < 0 || idx >= frame_paths.length) continue;
                    var frame = new DynamicWallpaperFrame(frame_paths[idx]);
                    frame.elevation = number_of(entry, "a");
                    double azimuth = number_of(entry, "z");
                    frame.rising = azimuth.is_nan() || azimuth < 180.0;
                    wp.frames.add(frame);
                }
                apply_appearance(wp, root.get("ap"), frame_paths);
            } else if (h24 != "") {
                var root = decode(h24);
                var list = root.get("ti");
                if (list == null || list.kind != PlistValue.Kind.ARRAY) throw new IOError.INVALID_DATA("Time metadata has no entries");
                wp.kind = DynamicWallpaperKind.TIME;
                foreach (var entry in list.items.data) {
                    int idx = (int) number_of(entry, "i");
                    if (idx < 0 || idx >= frame_paths.length) continue;
                    var frame = new DynamicWallpaperFrame(frame_paths[idx]);
                    double t = number_of(entry, "t");
                    frame.time_seconds = (int) (((int64) Math.round(t.clamp(0.0, 1.0) * DynamicWallpaper.DAY)) % DynamicWallpaper.DAY);
                    wp.frames.add(frame);
                }
                apply_appearance(wp, root.get("ap"), frame_paths);
            } else if (apr != "") {
                wp.kind = DynamicWallpaperKind.APPEARANCE;
                apply_appearance(wp, decode(apr), frame_paths);
            } else {
                throw new IOError.NOT_SUPPORTED("No dynamic desktop metadata");
            }
            if (wp.kind != DynamicWallpaperKind.APPEARANCE && wp.frames.length == 0)
                throw new IOError.INVALID_DATA("Metadata refers to no decoded frame");
            if (wp.kind == DynamicWallpaperKind.APPEARANCE && wp.light == "" && wp.dark == "")
                throw new IOError.INVALID_DATA("Appearance metadata refers to no decoded frame");
            return wp;
        }

        private static double number_of(PlistValue entry, string key) {
            var v = entry.get(key);
            return v != null ? v.number() : double.NAN;
        }

        private static void apply_appearance(DynamicWallpaper wp, PlistValue? ap, string[] frames) {
            if (ap == null) return;
            double l = number_of(ap, "l");
            double d = number_of(ap, "d");
            if (!l.is_nan() && (int) l >= 0 && (int) l < frames.length) wp.light = frames[(int) l];
            if (!d.is_nan() && (int) d >= 0 && (int) d < frames.length) wp.dark = frames[(int) d];
            if (wp.light != "") wp.preview = wp.light;
        }
    }

    public class DynamicWallpaperImporter : Object {
        public const string CONFIG_NAME = "dynamic-wallpapers.conf";

        public static string import_root() {
            return Path.build_filename(Environment.get_user_data_dir(), "backgrounds", "singularity-dynamic");
        }

        public static string collection_file() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "wallpaper-collections",
                "dynamic-imports.collection");
        }

        public static void ensure_collection() throws Error {
            string file = collection_file();
            DirUtils.create_with_parents(Path.get_dirname(file), 0755);
            DirUtils.create_with_parents(import_root(), 0755);
            if (FileUtils.test(file, FileTest.EXISTS)) return;
            var kf = new KeyFile();
            kf.set_string("Collection", "Id", "dynamic-imports");
            kf.set_string("Collection", "Name", _("Dynamic"));
            kf.set_string("Collection", "Dir", import_root());
            kf.set_string("Collection", "Type", "dynamic");
            kf.set_string("Collection", "Origin", "import");
            FileUtils.set_contents(file, kf.to_data());
        }

        private static string slug(string name) {
            var sb = new StringBuilder();
            string lower = name.down();
            for (int i = 0; i < lower.length; i++) {
                char c = lower[i];
                if (c.isalnum()) sb.append_c(c);
                else if (sb.len > 0 && sb.str[sb.len - 1] != '-') sb.append_c('-');
            }
            string s = sb.str;
            while (s.has_suffix("-")) s = s.substring(0, s.length - 1);
            return s != "" ? s : "wallpaper";
        }

        private static string unique_dir(string base_name) {
            string root = import_root();
            string candidate = Path.build_filename(root, base_name);
            int n = 2;
            while (FileUtils.test(candidate, FileTest.EXISTS)) {
                candidate = Path.build_filename(root, "%s-%d".printf(base_name, n++));
            }
            DirUtils.create_with_parents(candidate, 0755);
            return candidate;
        }

        private static string stem(string path) {
            string b = Path.get_basename(path);
            if (DynamicWallpaper.has_manifest_name(b)) return b.substring(0, b.length - DynamicWallpaper.MANIFEST_SUFFIX.length);
            int dot = b.last_index_of(".");
            return dot > 0 ? b.substring(0, dot) : b;
        }

        public static string import_file(string source, string[]? decoder_override = null) throws Error {
            string lower = source.down();
            ensure_collection();
            if (lower.has_suffix(".heic") || lower.has_suffix(".heif")) return import_heic(source, decoder_override);
            if (DynamicWallpaper.has_manifest_name(lower)) {
                var wp = DynamicWallpaper.load_manifest(source);
                string dir = unique_dir(slug(stem(source)));
                wp.save_to(Path.build_filename(dir, Path.get_basename(source)));
                return wp.path;
            }
            if (lower.has_suffix(".xml")) {
                var wp = DynamicWallpaper.load_timed_xml(source);
                string dir = unique_dir(slug(stem(source)));
                if (wp.kind == DynamicWallpaperKind.APPEARANCE) {
                    wp.name = wp.name != "" ? wp.name : stem(source);
                    string target = Path.build_filename(dir, slug(stem(source)) + DynamicWallpaper.MANIFEST_SUFFIX);
                    wp.save_to(target);
                    return target;
                }
                string target = Path.build_filename(dir, Path.get_basename(source));
                File.new_for_path(source).copy(File.new_for_path(target), FileCopyFlags.OVERWRITE);
                return target;
            }
            throw new IOError.NOT_SUPPORTED(_("This file is not a dynamic wallpaper"));
        }

        public static string[] decoder_command() {
            var kf = new KeyFile();
            var dirs = new GenericArray<string>();
            dirs.add(Environment.get_user_config_dir());
            foreach (unowned string d in Environment.get_system_config_dirs()) dirs.add(d);
            foreach (string d in dirs.data) {
                try {
                    kf.load_from_file(Path.build_filename(d, "singularity", CONFIG_NAME), KeyFileFlags.NONE);
                    string cmd = kf.get_string("HEIC", "Decoder").strip();
                    if (cmd == "none") return {};
                    string[] argv = {};
                    if (cmd != "" && GLib.Shell.parse_argv(cmd, out argv)) return argv;
                } catch (Error e) {
                }
            }
            if (Environment.find_program_in_path("magick") != null) return { "magick", "%i[%n]", "%o" };
            if (Environment.find_program_in_path("heif-dec") != null) return { "heif-dec", "--quiet", "%i", "%a" };
            if (Environment.find_program_in_path("heif-convert") != null) return { "heif-convert", "--quiet", "%i", "%a" };
            return {};
        }

        public static bool heic_supported() {
            return decoder_command().length > 0;
        }

        private static int max_index(HeicDynamicMetadata meta) {
            int best = 0;
            foreach (string b64 in new string[] { meta.solar, meta.h24, meta.apr }) {
                if (b64 == "") continue;
                try {
                    var root = HeicDynamicMetadata.decode(b64);
                    best = int.max(best, scan_indices(root));
                } catch (Error e) {
                }
            }
            return best;
        }

        private static int scan_indices(PlistValue v) {
            int best = 0;
            if (v.kind == PlistValue.Kind.DICT) {
                v.members.foreach((k, child) => {
                    if ((k == "i" || k == "l" || k == "d") && child.kind == PlistValue.Kind.INT)
                        best = int.max(best, (int) child.integer);
                    best = int.max(best, scan_indices(child));
                });
            } else if (v.kind == PlistValue.Kind.ARRAY) {
                foreach (var c in v.items.data) best = int.max(best, scan_indices(c));
            }
            return best;
        }

        private static string[] expand(string[] template, string input, int index, string output, string all_output) {
            string[] argv = {};
            foreach (string part in template) {
                argv += part.replace("%i", input).replace("%n", index.to_string())
                    .replace("%o", output).replace("%a", all_output);
            }
            return argv;
        }

        private static bool template_uses(string[] template, string token) {
            foreach (string part in template) if (part.contains(token)) return true;
            return false;
        }

        public static string[] decode_frames(string source, int count, string dir, string[]? decoder_override) throws Error {
            string[] template = decoder_override ?? decoder_command();
            if (template.length == 0)
                throw new IOError.NOT_SUPPORTED(_("No HEIC decoder is available on this system"));
            string[] frames = {};
            if (template_uses(template, "%n")) {
                for (int i = 0; i < count; i++) {
                    string out_path = Path.build_filename(dir, "frame-%02d.png".printf(i));
                    run(expand(template, source, i, out_path, ""));
                    if (!FileUtils.test(out_path, FileTest.EXISTS))
                        throw new IOError.FAILED(_("The HEIC decoder did not produce frame %d").printf(i));
                    frames += out_path;
                }
                return frames;
            }
            string all_out = Path.build_filename(dir, "frame.png");
            run(expand(template, source, 0, all_out, all_out));
            for (int i = 0; i < count; i++) {
                string numbered = Path.build_filename(dir, "frame-%d.png".printf(i + 1));
                string target = Path.build_filename(dir, "frame-%02d.png".printf(i));
                if (FileUtils.test(numbered, FileTest.EXISTS)) FileUtils.rename(numbered, target);
                else if (i == 0 && FileUtils.test(all_out, FileTest.EXISTS)) FileUtils.rename(all_out, target);
                if (!FileUtils.test(target, FileTest.EXISTS))
                    throw new IOError.FAILED(_("The HEIC decoder did not produce frame %d").printf(i));
                frames += target;
            }
            return frames;
        }

        private static void run(string[] argv) throws Error {
            string std_err;
            int status;
            Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL,
                null, null, out std_err, out status);
            Process.check_wait_status(status);
        }

        public static string import_heic(string source, string[]? decoder_override = null) throws Error {
            var mapped = new MappedFile(source, false);
            unowned uint8[] bytes = (uint8[]) mapped.get_contents();
            bytes.length = (int) mapped.get_length();
            var meta = HeicDynamicMetadata.scan(bytes);
            if (!meta.found) throw new IOError.NOT_SUPPORTED(_("This HEIC file has no dynamic desktop information"));
            int count = max_index(meta) + 1;
            string dir = unique_dir(slug(stem(source)));
            string[] frames = decode_frames(source, count, dir, decoder_override);
            var wp = meta.to_wallpaper(frames);
            wp.name = stem(source).replace("_", " ");
            string target = Path.build_filename(dir, slug(stem(source)) + DynamicWallpaper.MANIFEST_SUFFIX);
            wp.save_to(target);
            return target;
        }
    }
}
