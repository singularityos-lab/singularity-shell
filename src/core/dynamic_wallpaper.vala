using GLib;

namespace Singularity {

    public enum DynamicWallpaperKind {
        TIME,
        SOLAR,
        APPEARANCE,
        CYCLE;

        public string to_token() {
            switch (this) {
                case SOLAR: return "solar";
                case APPEARANCE: return "appearance";
                case CYCLE: return "cycle";
                default: return "time";
            }
        }

        public static DynamicWallpaperKind from_token(string? token) {
            switch (token) {
                case "solar": return SOLAR;
                case "appearance": return APPEARANCE;
                case "cycle": return CYCLE;
                default: return TIME;
            }
        }
    }

    public class DynamicWallpaperFrame : Object {
        public string image { get; set; default = ""; }
        public double elevation = double.NAN;
        public bool rising { get; set; default = true; }
        public int time_seconds { get; set; default = -1; }

        public DynamicWallpaperFrame(string image) {
            this.image = image;
        }
    }

    public class DynamicWallpaperSegment : Object {
        public int64 start { get; set; }
        public int64 duration { get; set; }
        public string from { get; set; }
        public string to { get; set; }

        public DynamicWallpaperSegment(int64 start, int64 duration, string from, string to) {
            this.start = start;
            this.duration = duration;
            this.from = from;
            this.to = to;
        }

        public bool is_transition {
            get { return from != to; }
        }
    }

    public class DynamicWallpaperState : Object {
        public string from { get; private set; }
        public string to { get; private set; }
        public double progress { get; private set; }
        public int64 seconds_to_change { get; private set; }

        public DynamicWallpaperState(string from, string to, double progress, int64 seconds_to_change = -1) {
            this.from = from;
            this.to = to;
            this.progress = progress.clamp(0.0, 1.0);
            this.seconds_to_change = seconds_to_change;
        }

        public bool is_blend {
            get { return from != to && progress > 0.0 && progress < 1.0; }
        }

        public string single_image {
            get { return progress >= 0.5 ? to : from; }
        }

        public DynamicWallpaperState quantized(int steps) {
            if (from == to || steps <= 1) return new DynamicWallpaperState(from, from, 0.0, seconds_to_change);
            int step = (int) Math.round(progress * steps);
            if (step <= 0) return new DynamicWallpaperState(from, from, 0.0, seconds_to_change);
            if (step >= steps) return new DynamicWallpaperState(to, to, 0.0, seconds_to_change);
            return new DynamicWallpaperState(from, to, (double) step / steps, seconds_to_change);
        }

        public string key() {
            if (!is_blend) return single_image;
            return "%s|%s|%.4f".printf(from, to, progress);
        }
    }

    public class DynamicWallpaperSun : Object {
        public const double NAUTICAL = -12.0;

        private static void day_terms(int year, int month, int day, out double decl, out double eqtime) {
            var date = Date();
            date.set_dmy((DateDay) day, (DateMonth) month, (DateYear) year);
            int doy = (int) date.get_day_of_year();
            int days = ((DateYear) year).is_leap_year() ? 366 : 365;
            double gamma = 2.0 * Math.PI / days * (doy - 1);
            eqtime = 229.18 * (0.000075 + 0.001868 * Math.cos(gamma) - 0.032077 * Math.sin(gamma)
                - 0.014615 * Math.cos(2 * gamma) - 0.040849 * Math.sin(2 * gamma));
            decl = 0.006918 - 0.399912 * Math.cos(gamma) + 0.070257 * Math.sin(gamma)
                - 0.006758 * Math.cos(2 * gamma) + 0.000907 * Math.sin(2 * gamma)
                - 0.002697 * Math.cos(3 * gamma) + 0.00148 * Math.sin(3 * gamma);
        }

        public static double elevation(DateTime moment, double latitude, double longitude) {
            var utc = moment.to_utc();
            double decl, eqtime;
            day_terms(utc.get_year(), utc.get_month(), utc.get_day_of_month(), out decl, out eqtime);
            double minutes = utc.get_hour() * 60.0 + utc.get_minute() + utc.get_seconds() / 60.0;
            double true_solar = minutes + eqtime + 4.0 * longitude;
            double ha = (true_solar / 4.0 - 180.0) * Math.PI / 180.0;
            double lat = latitude.clamp(-89.99, 89.99) * Math.PI / 180.0;
            double cos_zenith = Math.sin(lat) * Math.sin(decl) + Math.cos(lat) * Math.cos(decl) * Math.cos(ha);
            return 90.0 - Math.acos(cos_zenith.clamp(-1.0, 1.0)) * 180.0 / Math.PI;
        }

        public static bool is_rising(DateTime moment, double latitude, double longitude) {
            var utc = moment.to_utc();
            double decl, eqtime;
            day_terms(utc.get_year(), utc.get_month(), utc.get_day_of_month(), out decl, out eqtime);
            double noon = 720.0 - 4.0 * longitude - eqtime;
            double minutes = utc.get_hour() * 60.0 + utc.get_minute() + utc.get_seconds() / 60.0;
            double delta = Math.fmod(minutes - noon + 2160.0, 1440.0) - 720.0;
            return delta < 0.0;
        }

        public static DateTime time_for_elevation(DateTime local_day, double latitude, double longitude,
                                                  double target, bool rising) {
            var tz = local_day.get_timezone();
            var midnight = new DateTime(tz, local_day.get_year(), local_day.get_month(), local_day.get_day_of_month(), 0, 0, 0);
            var utc_noon_day = midnight.add_hours(12).to_utc();
            double decl, eqtime;
            day_terms(utc_noon_day.get_year(), utc_noon_day.get_month(), utc_noon_day.get_day_of_month(), out decl, out eqtime);
            double lat = latitude.clamp(-89.99, 89.99) * Math.PI / 180.0;
            double cos_ha = (Math.sin(target * Math.PI / 180.0) - Math.sin(lat) * Math.sin(decl))
                / (Math.cos(lat) * Math.cos(decl));
            double ha;
            if (cos_ha <= -1.0) ha = 180.0;
            else if (cos_ha >= 1.0) ha = 0.0;
            else ha = Math.acos(cos_ha) * 180.0 / Math.PI;
            double noon_utc = 720.0 - 4.0 * longitude - eqtime;
            double event_utc = rising ? noon_utc - 4.0 * ha : noon_utc + 4.0 * ha;
            var utc_midnight = new DateTime.utc(utc_noon_day.get_year(), utc_noon_day.get_month(), utc_noon_day.get_day_of_month(), 0, 0, 0);
            var result = utc_midnight.add_seconds(Math.round(event_utc * 60.0)).to_timezone(tz);
            var local_midnight_next = midnight.add_days(1);
            if (result.compare(midnight) < 0) result = result.add_days(1);
            else if (result.compare(local_midnight_next) >= 0) result = result.add_days(-1);
            return result;
        }
    }

    public class DynamicWallpaper : Object {
        public const string MANIFEST_SUFFIX = ".dynamic.json";
        public const int64 DAY = 86400;
        public const int DEFAULT_TRANSITION = 2700;

        public string path { get; private set; default = ""; }
        public string name { get; set; default = ""; }
        public DynamicWallpaperKind kind { get; set; default = DynamicWallpaperKind.TIME; }
        public string preview { get; set; default = ""; }
        public string light { get; set; default = ""; }
        public string dark { get; set; default = ""; }
        public int transition { get; set; default = DEFAULT_TRANSITION; }
        public DateTime? cycle_start { get; set; default = null; }
        public GenericArray<DynamicWallpaperFrame> frames = new GenericArray<DynamicWallpaperFrame>();
        public GenericArray<DynamicWallpaperSegment> cycle = new GenericArray<DynamicWallpaperSegment>();

        public static bool has_manifest_name(string path) {
            return path.down().has_suffix(MANIFEST_SUFFIX);
        }

        public static bool is_dynamic_path(string path) {
            if (has_manifest_name(path)) return true;
            string lower = path.down();
            if (lower.has_suffix(".xml")) return sniff_timed_xml(path);
            return false;
        }

        public static bool sniff_timed_xml(string path) {
            try {
                var stream = File.new_for_path(path).read();
                uint8[] buffer = new uint8[4096];
                size_t read;
                stream.read_all(buffer, out read);
                stream.close();
                string head = ((string) buffer).substring(0, (long) read);
                if (head.contains("<background") && (head.contains("<static") || head.contains("<starttime"))) return true;
                if (head.contains("<wallpapers") && head.contains("<filename-dark")) return true;
            } catch (Error e) {
            }
            return false;
        }

        public static DynamicWallpaper load(string path) throws Error {
            if (has_manifest_name(path)) return load_manifest(path);
            if (path.down().has_suffix(".xml")) return load_timed_xml(path);
            throw new IOError.NOT_SUPPORTED("Not a dynamic wallpaper: %s", path);
        }

        public string display_name() {
            if (name != "") return name;
            string base_name = Path.get_basename(path);
            if (has_manifest_name(base_name)) base_name = base_name.substring(0, base_name.length - MANIFEST_SUFFIX.length);
            else if (base_name.down().has_suffix(".xml")) base_name = base_name.substring(0, base_name.length - 4);
            return base_name.replace("-", " ").replace("_", " ");
        }

        public string preview_image(bool dark_mode = false) {
            if (preview != "") return preview;
            if (kind == DynamicWallpaperKind.APPEARANCE) return dark_mode && dark != "" ? dark : (light != "" ? light : dark);
            if (frames.length > 0) return frames[0].image;
            if (cycle.length > 0) return cycle[0].from;
            return light != "" ? light : dark;
        }

        public string[] images() {
            var list = new GenericArray<string>();
            foreach (var frame in frames.data) add_unique(list, frame.image);
            foreach (var seg in cycle.data) {
                add_unique(list, seg.from);
                add_unique(list, seg.to);
            }
            if (light != "") add_unique(list, light);
            if (dark != "") add_unique(list, dark);
            return list.data;
        }

        private static void add_unique(GenericArray<string> list, string value) {
            foreach (string existing in list.data) if (existing == value) return;
            list.add(value);
        }

        public static int parse_clock(string? text) {
            if (text == null) return -1;
            var parts = text.strip().split(":");
            if (parts.length < 2 || parts.length > 3) return -1;
            int total = 0;
            int[] limits = { 24, 60, 60 };
            for (int i = 0; i < parts.length; i++) {
                string part = parts[i];
                if (part.length == 0) return -1;
                for (int c = 0; c < part.length; c++) if (!part[c].isdigit()) return -1;
                int value = int.parse(part);
                if (value >= limits[i]) return -1;
                total += value * (i == 0 ? 3600 : (i == 1 ? 60 : 1));
            }
            return total;
        }

        public static string format_clock(int seconds) {
            seconds = (int) (((seconds % DAY) + DAY) % DAY);
            return "%02d:%02d".printf(seconds / 3600, (seconds / 60) % 60);
        }

        private static string resolve(string base_dir, string file) {
            if (file == "") return "";
            if (file.has_prefix("file://")) return File.new_for_uri(file).get_path() ?? "";
            if (Path.is_absolute(file)) return file;
            return File.new_for_path(Path.build_filename(base_dir, file)).get_path() ?? "";
        }

        public static DynamicWallpaper load_manifest(string path) throws Error {
            var parser = new Json.Parser();
            parser.load_from_file(path);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT)
                throw new IOError.INVALID_DATA("Manifest root must be an object");
            return from_json(root.get_object(), path);
        }

        public static DynamicWallpaper from_json(Json.Object obj, string path) throws Error {
            var wp = new DynamicWallpaper();
            wp.path = path;
            string dir = Path.get_dirname(path);
            if (obj.has_member("version") && obj.get_int_member("version") > 1)
                throw new IOError.NOT_SUPPORTED("Unsupported manifest version");
            wp.name = obj.has_member("name") ? obj.get_string_member("name") : "";
            wp.preview = resolve(dir, obj.has_member("preview") ? obj.get_string_member("preview") : "");
            wp.light = resolve(dir, obj.has_member("light") ? obj.get_string_member("light") : "");
            wp.dark = resolve(dir, obj.has_member("dark") ? obj.get_string_member("dark") : "");
            if (obj.has_member("transition")) wp.transition = (int) obj.get_int_member("transition").clamp(0, DAY / 2);
            if (obj.has_member("frames")) {
                foreach (var node in obj.get_array_member("frames").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var f = node.get_object();
                    string image = resolve(dir, f.has_member("image") ? f.get_string_member("image") : "");
                    if (image == "") continue;
                    var frame = new DynamicWallpaperFrame(image);
                    if (f.has_member("elevation")) frame.elevation = f.get_double_member("elevation").clamp(-90.0, 90.0);
                    if (f.has_member("phase")) frame.rising = f.get_string_member("phase") != "setting";
                    if (f.has_member("time")) frame.time_seconds = parse_clock(f.get_string_member("time"));
                    wp.frames.add(frame);
                }
            }
            string kind_token = obj.has_member("kind") ? obj.get_string_member("kind") : "";
            if (kind_token != "") wp.kind = DynamicWallpaperKind.from_token(kind_token);
            else if (wp.frames.length == 0) wp.kind = DynamicWallpaperKind.APPEARANCE;
            else wp.kind = DynamicWallpaperKind.TIME;
            if (wp.kind == DynamicWallpaperKind.APPEARANCE) {
                if (wp.light == "" && wp.dark == "") throw new IOError.INVALID_DATA("Appearance wallpaper needs light or dark");
            } else if (wp.frames.length == 0) {
                throw new IOError.INVALID_DATA("Manifest has no frames");
            }
            return wp;
        }

        public string to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version"); b.add_int_value(1);
            if (name != "") { b.set_member_name("name"); b.add_string_value(name); }
            b.set_member_name("kind"); b.add_string_value(kind.to_token());
            string dir = path != "" ? Path.get_dirname(path) : "";
            if (preview != "") { b.set_member_name("preview"); b.add_string_value(relative(dir, preview)); }
            if (light != "") { b.set_member_name("light"); b.add_string_value(relative(dir, light)); }
            if (dark != "") { b.set_member_name("dark"); b.add_string_value(relative(dir, dark)); }
            if (frames.length > 0) {
                b.set_member_name("transition"); b.add_int_value(transition);
                b.set_member_name("frames");
                b.begin_array();
                foreach (var f in frames.data) {
                    b.begin_object();
                    b.set_member_name("image"); b.add_string_value(relative(dir, f.image));
                    if (!f.elevation.is_nan()) {
                        b.set_member_name("elevation"); b.add_double_value(f.elevation);
                        b.set_member_name("phase"); b.add_string_value(f.rising ? "rising" : "setting");
                    }
                    if (f.time_seconds >= 0) { b.set_member_name("time"); b.add_string_value(format_clock(f.time_seconds)); }
                    b.end_object();
                }
                b.end_array();
            }
            b.end_object();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            return gen.to_data(null) + "\n";
        }

        public void save_to(string manifest_path) throws Error {
            path = manifest_path;
            FileUtils.set_contents(manifest_path, to_json());
        }

        private static string relative(string dir, string file) {
            if (dir != "" && file.has_prefix(dir + "/")) return file.substring(dir.length + 1);
            return file;
        }

        public static DynamicWallpaper load_timed_xml(string path) throws Error {
            string contents;
            FileUtils.get_contents(path, out contents);
            return parse_timed_xml(contents, path);
        }

        public static DynamicWallpaper parse_timed_xml(string contents, string path) throws Error {
            var reader = new TimedXmlReader(Path.get_dirname(path));
            reader.parse(contents);
            var wp = new DynamicWallpaper();
            wp.path = path;
            if (reader.segments.length > 0) {
                wp.kind = DynamicWallpaperKind.CYCLE;
                wp.cycle_start = reader.start;
                int64 offset = 0;
                foreach (var seg in reader.segments.data) {
                    seg.start = offset;
                    offset += seg.duration;
                    wp.cycle.add(seg);
                }
                if (offset <= 0) throw new IOError.INVALID_DATA("Background cycle has no duration");
                return wp;
            }
            if (reader.light != "" || reader.dark != "") {
                wp.kind = DynamicWallpaperKind.APPEARANCE;
                wp.name = reader.name;
                wp.light = reader.light;
                wp.dark = reader.dark != "" ? reader.dark : reader.light;
                if (wp.light == "") wp.light = wp.dark;
                return wp;
            }
            throw new IOError.INVALID_DATA("No timed background or light and dark wallpaper found");
        }

        private class TimedXmlReader : Object {
            public string base_dir;
            public GenericArray<DynamicWallpaperSegment> segments = new GenericArray<DynamicWallpaperSegment>();
            public DateTime? start = null;
            public string name = "";
            public string light = "";
            public string dark = "";
            private GenericArray<string> stack = new GenericArray<string>();
            private StringBuilder text = new StringBuilder();
            private int[] start_fields = { 2011, 1, 1, 0, 0, 0 };
            private double duration = 0;
            private string file_best = "";
            private int file_best_size = -1;
            private int size_attr = 0;
            private string from = "";
            private string to = "";
            private bool in_wallpaper = false;
            private bool wallpaper_done = false;

            public TimedXmlReader(string base_dir) {
                this.base_dir = base_dir;
            }

            private string parent() {
                return stack.length >= 2 ? stack[stack.length - 2] : "";
            }

            private string resolve_file(string value) {
                return DynamicWallpaper.resolve(base_dir, value.strip());
            }

            private void on_start(MarkupParseContext ctx, string element, string[] names, string[] values) throws MarkupError {
                stack.add(element);
                text.truncate(0);
                if (element == "size") {
                    size_attr = 0;
                    for (int i = 0; names[i] != null; i++) {
                        if (names[i] == "width") size_attr = int.parse(values[i]);
                    }
                } else if (element == "file") {
                    file_best = "";
                    file_best_size = -1;
                } else if (element == "static" || element == "transition") {
                    duration = 0;
                    from = "";
                    to = "";
                    file_best = "";
                    file_best_size = -1;
                } else if (element == "wallpaper" && !wallpaper_done) {
                    in_wallpaper = true;
                }
            }

            private void on_end(MarkupParseContext ctx, string element) throws MarkupError {
                string value = text.str.strip();
                string p = parent();
                if (p == "starttime") {
                    int idx = -1;
                    switch (element) {
                        case "year": idx = 0; break;
                        case "month": idx = 1; break;
                        case "day": idx = 2; break;
                        case "hour": idx = 3; break;
                        case "minute": idx = 4; break;
                        case "second": idx = 5; break;
                    }
                    if (idx >= 0) start_fields[idx] = int.parse(value);
                } else if (element == "starttime") {
                    start = new DateTime.local(start_fields[0], start_fields[1].clamp(1, 12),
                        start_fields[2].clamp(1, 28), start_fields[3].clamp(0, 23),
                        start_fields[4].clamp(0, 59), start_fields[5].clamp(0, 59));
                } else if (element == "duration") {
                    duration = double.parse(value);
                } else if (element == "size") {
                    if (size_attr > file_best_size) {
                        file_best_size = size_attr;
                        file_best = resolve_file(value);
                    }
                } else if (element == "file" && p == "static") {
                    if (file_best == "" && value != "") file_best = resolve_file(value);
                } else if (element == "from") {
                    from = resolve_file(value);
                } else if (element == "to") {
                    to = resolve_file(value);
                } else if (element == "static") {
                    if (file_best != "" && duration > 0)
                        segments.add(new DynamicWallpaperSegment(0, (int64) Math.round(duration), file_best, file_best));
                } else if (element == "transition") {
                    if (from != "" && to != "" && duration > 0)
                        segments.add(new DynamicWallpaperSegment(0, (int64) Math.round(duration), from, to));
                } else if (in_wallpaper && p == "wallpaper") {
                    if (element == "name" && name == "") name = value;
                    else if (element == "filename" && light == "") light = resolve_file(value);
                    else if (element == "filename-dark" && dark == "") dark = resolve_file(value);
                } else if (element == "wallpaper" && in_wallpaper) {
                    in_wallpaper = false;
                    if (dark != "") wallpaper_done = true;
                    else { name = ""; light = ""; }
                }
                if (stack.length > 0) stack.remove_index(stack.length - 1);
                text.truncate(0);
            }

            private void on_text(MarkupParseContext ctx, string chunk, size_t len) throws MarkupError {
                text.append_len(chunk, (ssize_t) len);
            }

            public void parse(string contents) throws Error {
                MarkupParser parser = { on_start, on_end, on_text, null, null };
                var context = new MarkupParseContext(parser, 0, this, null);
                context.parse(contents, contents.length);
                context.end_parse();
                if (start == null && segments.length > 0) start = new DateTime.local(2011, 1, 1, 0, 0, 0);
            }
        }

        public GenericArray<DynamicWallpaperSegment> day_schedule(DateTime local_now, bool have_location,
                                                                   double latitude, double longitude) {
            var timed = new GenericArray<DynamicWallpaperFrame>();
            var times = new GenericArray<int>();
            var midnight = new DateTime(local_now.get_timezone(), local_now.get_year(), local_now.get_month(),
                local_now.get_day_of_month(), 0, 0, 0);
            int n = frames.length;
            for (int i = 0; i < n; i++) {
                var frame = frames[i];
                int t = -1;
                if (kind == DynamicWallpaperKind.SOLAR && have_location && !frame.elevation.is_nan()) {
                    var at = DynamicWallpaperSun.time_for_elevation(local_now, latitude, longitude, frame.elevation, frame.rising);
                    t = (int) (at.difference(midnight) / TimeSpan.SECOND);
                }
                if (t < 0) t = frame.time_seconds;
                if (t < 0) t = (int) (DAY * i / int.max(1, n));
                t = (int) (((t % DAY) + DAY) % DAY);
                int pos = 0;
                while (pos < times.length && times[pos] <= t) pos++;
                timed.insert(pos, frame);
                times.insert(pos, t);
            }
            var segs = new GenericArray<DynamicWallpaperSegment>();
            int m = timed.length;
            for (int i = 0; i < m; i++) {
                int next = (i + 1) % m;
                int64 gap = m == 1 ? DAY : ((times[next] - times[i]) % DAY + DAY) % DAY;
                if (gap == 0 && m > 1) continue;
                int64 trans = m == 1 ? 0 : int64.min(transition, gap / 2);
                string img = timed[i].image;
                string next_img = timed[next].image;
                if (img == next_img) trans = 0;
                if (gap - trans > 0) segs.add(new DynamicWallpaperSegment(times[i], gap - trans, img, img));
                if (trans > 0) segs.add(new DynamicWallpaperSegment(times[i] + gap - trans, trans, img, next_img));
            }
            return segs;
        }

        public static DynamicWallpaperState evaluate_cycle(GenericArray<DynamicWallpaperSegment> segs, int64 offset) {
            if (segs.length == 0) return new DynamicWallpaperState("", "", 0.0);
            int64 first = segs[0].start;
            int64 total = 0;
            foreach (var s in segs.data) total += s.duration;
            if (total <= 0) return new DynamicWallpaperState(segs[0].from, segs[0].from, 0.0);
            int64 x = (((offset - first) % total) + total) % total;
            int64 cursor = 0;
            foreach (var s in segs.data) {
                if (x < cursor + s.duration) {
                    int64 into = x - cursor;
                    if (!s.is_transition) return new DynamicWallpaperState(s.from, s.from, 0.0, s.duration - into);
                    double p = (double) into / (double) s.duration;
                    return new DynamicWallpaperState(s.from, s.to, p, 1);
                }
                cursor += s.duration;
            }
            var last = segs[segs.length - 1];
            return new DynamicWallpaperState(last.to, last.to, 0.0);
        }

        public DynamicWallpaperState evaluate(DateTime local_now, bool dark_mode, bool have_location,
                                              double latitude, double longitude) {
            switch (kind) {
                case DynamicWallpaperKind.APPEARANCE: {
                    string img = dark_mode ? (dark != "" ? dark : light) : (light != "" ? light : dark);
                    return new DynamicWallpaperState(img, img, 0.0);
                }
                case DynamicWallpaperKind.CYCLE: {
                    var anchor = cycle_start ?? new DateTime.local(2011, 1, 1, 0, 0, 0);
                    int64 offset = local_now.difference(anchor) / TimeSpan.SECOND;
                    return evaluate_cycle(cycle, offset);
                }
                default: {
                    var segs = day_schedule(local_now, have_location, latitude, longitude);
                    var midnight = new DateTime(local_now.get_timezone(), local_now.get_year(), local_now.get_month(),
                        local_now.get_day_of_month(), 0, 0, 0);
                    int64 offset = local_now.difference(midnight) / TimeSpan.SECOND;
                    return evaluate_cycle(segs, offset);
                }
            }
        }
    }
}
