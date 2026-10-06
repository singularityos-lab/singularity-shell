namespace Singularity.Crash {

    public enum SourceKind {
        HANDLER,
        COREDUMPCTL,
        LAUNCHER;

        public string id() {
            switch (this) {
                case HANDLER: return "handler";
                case COREDUMPCTL: return "coredumpctl";
                default: return "launcher";
            }
        }

        public static SourceKind? from_id(string id) {
            switch (id.strip().down()) {
                case "handler": return HANDLER;
                case "coredumpctl": return COREDUMPCTL;
                case "launcher": return LAUNCHER;
                default: return null;
            }
        }
    }

    public class Report : Object {
        public const string GROUP = "Crash";

        public SourceKind source { get; set; default = SourceKind.LAUNCHER; }
        public int pid { get; set; default = 0; }
        public int uid { get; set; default = -1; }
        public int signal_number { get; set; default = 0; }
        public int64 timestamp { get; set; default = 0; }
        public string executable { get; set; default = ""; }
        public string command_line { get; set; default = ""; }
        public string app_id { get; set; default = ""; }
        public string desktop_file { get; set; default = ""; }
        public string core_path { get; set; default = ""; }
        public string backtrace { get; set; default = ""; }
        public string backtrace_tool { get; set; default = ""; }
        public string app_name { get; set; default = ""; }
        public string app_version { get; set; default = ""; }
        public string bug_url { get; set; default = ""; }
        public string os_name { get; set; default = ""; }
        public string kernel { get; set; default = ""; }
        public string report_path { get; set; default = ""; }
        public bool seen { get; set; default = false; }

        public string key() {
            return "%d:%s".printf(pid, Path.get_basename(executable));
        }

        public string display_name() {
            if (app_name != "") return app_name;
            if (app_id != "") return app_id;
            if (executable != "") return Path.get_basename(executable);
            return "";
        }

        public static Report? from_keyfile_data(string data, string path = "") {
            var kf = new KeyFile();
            try {
                kf.load_from_data(data, data.length, KeyFileFlags.NONE);
            } catch (Error e) {
                return null;
            }
            if (!kf.has_group(GROUP)) return null;
            var report = new Report();
            report.report_path = path;
            report.source = SourceKind.from_id(read_string(kf, "Source")) ?? SourceKind.HANDLER;
            report.pid = read_int(kf, "Pid", 0);
            report.uid = read_int(kf, "Uid", -1);
            report.signal_number = read_int(kf, "Signal", 0);
            report.timestamp = (int64) read_double(kf, "Time", 0);
            report.executable = read_string(kf, "Executable");
            report.command_line = read_string(kf, "CommandLine");
            report.desktop_file = read_string(kf, "DesktopFile");
            report.app_id = read_string(kf, "AppId");
            if (report.app_id == "" && report.desktop_file != "") {
                report.app_id = app_id_from_desktop_path(report.desktop_file);
            }
            report.core_path = read_string(kf, "Core");
            if (report.core_path != "" && !Path.is_absolute(report.core_path) && path != "") {
                report.core_path = Path.build_filename(Path.get_dirname(path), report.core_path);
            }
            report.backtrace = unescape_block(read_string(kf, "Backtrace"));
            report.backtrace_tool = read_string(kf, "BacktraceTool");
            report.seen = read_string(kf, "Seen") == "true";
            if (report.pid <= 0 || report.executable == "") return null;
            return report;
        }

        public static Report? from_file(string path) {
            string data;
            try {
                FileUtils.get_contents(path, out data);
            } catch (Error e) {
                return null;
            }
            return from_keyfile_data(data, path);
        }

        public bool mark_seen() {
            if (report_path == "") return false;
            var kf = new KeyFile();
            try {
                kf.load_from_file(report_path, KeyFileFlags.KEEP_COMMENTS);
                kf.set_string(GROUP, "Seen", "true");
                if (backtrace != "") {
                    kf.set_string(GROUP, "Backtrace", escape_block(backtrace));
                    kf.set_string(GROUP, "BacktraceTool", backtrace_tool);
                }
                if (core_path == "") kf.remove_key(GROUP, "Core");
                kf.save_to_file(report_path);
            } catch (Error e) {
                return false;
            }
            seen = true;
            return true;
        }

        private static string read_string(KeyFile kf, string key) {
            try {
                return kf.has_key(GROUP, key) ? kf.get_string(GROUP, key).strip() : "";
            } catch (Error e) {
                return "";
            }
        }

        private static int read_int(KeyFile kf, string key, int fallback) {
            string value = read_string(kf, key);
            int64 parsed = 0;
            if (value != "" && int64.try_parse(value, out parsed)) return (int) parsed;
            return fallback;
        }

        private static double read_double(KeyFile kf, string key, double fallback) {
            string value = read_string(kf, key);
            double parsed = 0;
            if (value != "" && double.try_parse(value, out parsed)) return parsed;
            return fallback;
        }

        public static string escape_block(string text) {
            return text.replace("\\", "\\\\").replace("\n", "\\n");
        }

        public static string unescape_block(string text) {
            var builder = new StringBuilder();
            bool escaped = false;
            for (int i = 0; i < text.length; i++) {
                char c = text[i];
                if (escaped) {
                    builder.append_c(c == 'n' ? '\n' : c);
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else {
                    builder.append_c(c);
                }
            }
            return builder.str;
        }

        public static string app_id_from_desktop_path(string path) {
            string base_name = Path.get_basename(path);
            if (base_name.has_suffix(".desktop")) base_name = base_name.substring(0, base_name.length - 8);
            return base_name;
        }

        public string format_time() {
            if (timestamp <= 0) return "";
            var dt = new DateTime.from_unix_local(timestamp);
            return dt != null ? dt.format("%Y-%m-%d %H:%M:%S") : "";
        }

        public string to_text() {
            var builder = new StringBuilder();
            builder.append("Crash Report\n");
            append_line(builder, "App", display_name());
            append_line(builder, "App ID", app_id);
            append_line(builder, "Version", app_version);
            append_line(builder, "Executable", executable);
            append_line(builder, "Command Line", command_line);
            append_line(builder, "Process ID", pid > 0 ? pid.to_string() : "");
            append_line(builder, "Signal", signal_label(signal_number));
            append_line(builder, "Time", format_time());
            append_line(builder, "Operating System", os_name);
            append_line(builder, "Kernel", kernel);
            append_line(builder, "Collected By", source_label(source));
            builder.append("\nBacktrace");
            if (backtrace_tool != "") builder.append(" (%s)".printf(backtrace_tool));
            builder.append("\n");
            builder.append(backtrace != "" ? backtrace.strip() : "Not available");
            builder.append("\n");
            return builder.str;
        }

        private static void append_line(StringBuilder builder, string label, string value) {
            if (value == "") return;
            builder.append("%s: %s\n".printf(label, value));
        }

        public static string source_label(SourceKind kind) {
            switch (kind) {
                case SourceKind.HANDLER: return "Singularity crash handler";
                case SourceKind.COREDUMPCTL: return "systemd-coredump";
                default: return "App launcher";
            }
        }

        public static string signal_name(int number) {
            switch (number) {
                case 4: return "SIGILL";
                case 5: return "SIGTRAP";
                case 6: return "SIGABRT";
                case 7: return "SIGBUS";
                case 8: return "SIGFPE";
                case 11: return "SIGSEGV";
                case 31: return "SIGSYS";
                default: return number > 0 ? "SIG%d".printf(number) : "";
            }
        }

        public static string signal_description(int number) {
            switch (number) {
                case 4: return "Illegal instruction";
                case 5: return "Trace or breakpoint trap";
                case 6: return "Aborted";
                case 7: return "Bus error";
                case 8: return "Arithmetic exception";
                case 11: return "Segmentation fault";
                case 31: return "Bad system call";
                default: return "";
            }
        }

        public static string signal_label(int number) {
            string name = signal_name(number);
            string description = signal_description(number);
            if (name == "") return "";
            return description != "" ? "%s (%s)".printf(name, description) : name;
        }

        public static bool is_crash_signal(int number) {
            switch (number) {
                case 4: case 5: case 6: case 7: case 8: case 11: case 31:
                    return true;
                default:
                    return false;
            }
        }

        public static string trim_backtrace(string text, int max_lines = 400) {
            string body = text;
            int threads = body.index_of("\nThread ");
            if (threads >= 0 && body.contains("Core was generated")) body = body.substring(threads + 1);
            var lines = body.split("\n");
            var builder = new StringBuilder();
            int kept = 0;
            foreach (string line in lines) {
                if (line.has_prefix("[New LWP") || line.has_prefix("[Thread debugging")
                    || line.has_prefix("Using host libthread_db") || line.has_prefix("warning: Can't open file")
                    || line.has_prefix("Downloading")) continue;
                if (kept >= max_lines) {
                    builder.append("...\n");
                    break;
                }
                builder.append(line);
                builder.append_c('\n');
                kept++;
            }
            return builder.str.strip();
        }

        public static string extract_coredumpctl_stack(string info) {
            int start = info.index_of("Stack trace of thread");
            if (start < 0) return "";
            string tail = info.substring(start);
            int end = tail.index_of("\n\n\n");
            string block = end > 0 ? tail.substring(0, end) : tail;
            var builder = new StringBuilder();
            foreach (string line in block.strip().split("\n")) {
                string clean = line.strip();
                if (clean == "") continue;
                if (builder.len > 0) builder.append_c('\n');
                builder.append(clean.has_prefix("#") ? "  " + clean : clean);
            }
            return builder.str;
        }
    }

    public class AppMetadata : Object {
        public string version { get; set; default = ""; }
        public string bug_url { get; set; default = ""; }

        public static string metainfo_version(string xml) {
            MatchInfo info;
            try {
                var re = new Regex("<release\\b[^>]*\\bversion=\"([^\"]+)\"");
                if (re.match(xml, 0, out info)) return info.fetch(1).strip();
            } catch (RegexError e) {
            }
            return "";
        }

        public static string metainfo_bug_url(string xml) {
            MatchInfo info;
            try {
                var re = new Regex("<url\\b[^>]*\\btype=\"bugtracker\"[^>]*>\\s*([^<\\s]+)\\s*</url>");
                if (re.match(xml, 0, out info)) return sanitize_url(info.fetch(1));
            } catch (RegexError e) {
            }
            return "";
        }

        public static string sanitize_url(string? url) {
            if (url == null) return "";
            string value = url.strip().replace("&amp;", "&");
            string lower = value.down();
            if (!lower.has_prefix("https://") && !lower.has_prefix("http://")) return "";
            if (value.contains(" ") || value.contains("\n")) return "";
            return value;
        }
    }

    public class RateLimiter : Object {
        public int window_seconds { get; construct; }
        public int max_per_app { get; construct; }
        public int global_window_seconds { get; construct; }
        public int max_global { get; construct; }

        private HashTable<string, Array<int64?>> per_app = new HashTable<string, Array<int64?>>(str_hash, str_equal);
        private Array<int64?> global = new Array<int64?>();

        public RateLimiter(int window_seconds = 600, int max_per_app = 3, int global_window_seconds = 60, int max_global = 5) {
            Object(window_seconds: window_seconds, max_per_app: max_per_app,
                   global_window_seconds: global_window_seconds, max_global: max_global);
        }

        public enum Verdict {
            SHOW,
            REPEATED,
            SUPPRESS
        }

        public Verdict check(string app, int64 now) {
            prune(global, now - global_window_seconds);
            var entries = per_app.lookup(app);
            if (entries == null) {
                entries = new Array<int64?>();
                per_app.insert(app, entries);
            }
            prune(entries, now - window_seconds);
            if (global.length >= max_global) return Verdict.SUPPRESS;
            if (entries.length >= max_per_app) return Verdict.SUPPRESS;
            entries.append_val(now);
            global.append_val(now);
            return entries.length == max_per_app ? Verdict.REPEATED : Verdict.SHOW;
        }

        private static void prune(Array<int64?> entries, int64 cutoff) {
            while (entries.length > 0 && entries.index(0) <= cutoff) entries.remove_index(0);
        }
    }

    public class SourceSelection : Object {
        public static SourceKind[] select(string requested, bool handler_present, bool coredumpctl_present) {
            SourceKind[] result = {};
            string value = requested.strip().down();
            if (value == "" || value == "auto") {
                if (handler_present) result += SourceKind.HANDLER;
                if (coredumpctl_present) result += SourceKind.COREDUMPCTL;
                result += SourceKind.LAUNCHER;
                return result;
            }
            if (value == "none") return result;
            foreach (string part in value.split(",")) {
                var kind = SourceKind.from_id(part);
                if (kind == null) continue;
                bool dup = false;
                foreach (var existing in result) if (existing == kind) dup = true;
                if (!dup) result += kind;
            }
            return result;
        }

        public static bool pattern_uses_handler(string core_pattern) {
            return core_pattern.has_prefix("|") && core_pattern.contains("singularity-crash-handler");
        }

        public static bool pattern_uses_coredump(string core_pattern) {
            return core_pattern.has_prefix("|") && core_pattern.contains("systemd-coredump");
        }

        public static Report[] parse_coredumpctl_json(string json, int uid, int64 since_usec) {
            Report[] result = {};
            var parser = new Json.Parser();
            try {
                parser.load_from_data(json);
            } catch (Error e) {
                return result;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return result;
            foreach (var node in root.get_array().get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var obj = node.get_object();
                int64 time = obj.has_member("time") ? obj.get_int_member("time") : 0;
                if (time <= since_usec) continue;
                if (uid >= 0 && obj.has_member("uid") && obj.get_int_member("uid") != uid) continue;
                var report = new Report();
                report.source = SourceKind.COREDUMPCTL;
                report.timestamp = time / 1000000;
                report.pid = obj.has_member("pid") ? (int) obj.get_int_member("pid") : 0;
                report.uid = obj.has_member("uid") ? (int) obj.get_int_member("uid") : -1;
                report.signal_number = obj.has_member("sig") ? (int) obj.get_int_member("sig") : 0;
                report.executable = obj.has_member("exe") ? (obj.get_string_member("exe") ?? "") : "";
                if (obj.has_member("corefile")) {
                    string state = obj.get_string_member("corefile") ?? "";
                    if (state == "present") report.core_path = "coredumpctl:%d".printf(report.pid);
                }
                if (report.pid > 0 && report.executable != "") result += report;
            }
            return result;
        }
    }
}
