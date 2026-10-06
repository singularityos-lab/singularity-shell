namespace Singularity.Crash {

    public class Config : Object {
        public const string FILE_NAME = "crash-reporter.conf";
        public const string GROUP = "Crash Reporter";
        public const string DEFAULT_SPOOL = "/var/lib/singularity/crashes";

        public string sources { get; set; default = "auto"; }
        public string spool_dir { get; set; default = DEFAULT_SPOOL; }
        public string backtrace_tool { get; set; default = "auto"; }
        public int backtrace_timeout { get; set; default = 30; }
        public bool notify_unknown { get; set; default = false; }
        public bool delete_core_after_backtrace { get; set; default = true; }
        public string loaded_from { get; set; default = ""; }

        public static Config load() {
            string? env = Environment.get_variable("SINGULARITY_CRASH_CONFIG");
            if (env != null && env != "") return load_file(env);
            foreach (string dir in Environment.get_system_config_dirs()) {
                string path = Path.build_filename(dir, "singularity", FILE_NAME);
                if (FileUtils.test(path, FileTest.IS_REGULAR)) return load_file(path);
            }
            return new Config();
        }

        public static Config load_file(string path) {
            var config = new Config();
            string data;
            try {
                FileUtils.get_contents(path, out data);
            } catch (Error e) {
                return config;
            }
            config.apply(data);
            config.loaded_from = path;
            return config;
        }

        public void apply(string data) {
            var kf = new KeyFile();
            try {
                kf.load_from_data(data, data.length, KeyFileFlags.NONE);
            } catch (Error e) {
                return;
            }
            if (!kf.has_group(GROUP)) return;
            sources = read(kf, "Sources", sources);
            spool_dir = read(kf, "SpoolDir", spool_dir);
            backtrace_tool = read(kf, "BacktraceTool", backtrace_tool).down();
            string timeout = read(kf, "BacktraceTimeout", "");
            int64 parsed = 0;
            if (timeout != "" && int64.try_parse(timeout, out parsed) && parsed > 0 && parsed <= 600) {
                backtrace_timeout = (int) parsed;
            }
            notify_unknown = read(kf, "NotifyUnknownPrograms", notify_unknown ? "true" : "false").down() == "true";
            delete_core_after_backtrace = read(kf, "DeleteCoreAfterBacktrace",
                delete_core_after_backtrace ? "true" : "false").down() == "true";
        }

        private static string read(KeyFile kf, string key, string fallback) {
            try {
                if (kf.has_key(GROUP, key)) {
                    string value = kf.get_string(GROUP, key).strip();
                    if (value != "") return value;
                }
            } catch (Error e) {
            }
            return fallback;
        }

        public string user_spool_dir(int uid) {
            return Path.build_filename(spool_dir, uid.to_string());
        }

        public static string read_core_pattern() {
            string? override_path = Environment.get_variable("SINGULARITY_CRASH_CORE_PATTERN_FILE");
            string path = override_path != null && override_path != "" ? override_path : "/proc/sys/kernel/core_pattern";
            string data;
            try {
                FileUtils.get_contents(path, out data);
            } catch (Error e) {
                return "";
            }
            return data.strip();
        }
    }
}
