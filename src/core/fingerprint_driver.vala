namespace Singularity {

    public class FingerprintDriver : Object {
        private const string[] PKEXEC_PATHS = { "/usr/bin/pkexec", "/bin/pkexec" };
        private const string[] HELPER_PATHS = {
            "/opt/local/libexec/singularity-fprint-driver",
            "/usr/local/libexec/singularity-fprint-driver",
            "/usr/libexec/singularity-fprint-driver",
        };

        public string id { get; private set; default = ""; }
        public string vendor { get; private set; default = ""; }
        public string name { get; private set; default = ""; }
        public string version { get; private set; default = ""; }
        public string license { get; private set; default = ""; }
        public string source { get; private set; default = ""; }
        public string url { get; private set; default = ""; }
        public int64 size { get; private set; default = 0; }
        public bool installed { get; private set; default = false; }

        private static string? first_existing(string[] paths) {
            foreach (string path in paths) {
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) return path;
            }
            return null;
        }

        public string host {
            owned get {
                try {
                    string? parsed = Uri.parse(url, UriFlags.NONE).get_host();
                    if (parsed != null) return parsed;
                } catch (UriError e) {
                }
                return url;
            }
        }

        public static async FingerprintDriver? find(string sensor) {
            string? helper = first_existing(HELPER_PATHS);
            if (helper == null) return null;
            try {
                var process = new Subprocess.newv({ helper, "info", sensor },
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string? output;
                yield process.communicate_utf8_async(null, null, out output, null);
                if (!process.get_successful() || output == null) return null;
                var driver = new FingerprintDriver();
                foreach (string line in output.split("\n")) {
                    int eq = line.index_of("=");
                    if (eq <= 0) continue;
                    string key = line.substring(0, eq);
                    string value = line.substring(eq + 1);
                    switch (key) {
                        case "id": driver.id = value; break;
                        case "vendor": driver.vendor = value; break;
                        case "name": driver.name = value; break;
                        case "version": driver.version = value; break;
                        case "license": driver.license = value; break;
                        case "source": driver.source = value; break;
                        case "url": driver.url = value; break;
                        case "size": driver.size = int64.parse(value); break;
                        case "installed": driver.installed = value == "true"; break;
                    }
                }
                return driver.id != "" && driver.url != "" ? driver : null;
            } catch (Error e) {
                return null;
            }
        }

        private async void run(string mode) throws Error {
            string? pkexec = first_existing(PKEXEC_PATHS);
            string? helper = first_existing(HELPER_PATHS);
            if (pkexec == null || helper == null) {
                throw new IOError.NOT_FOUND(_("The driver installer is not available"));
            }
            var process = new Subprocess.newv({ pkexec, helper, mode, id },
                SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
            string? errors;
            yield process.communicate_utf8_async(null, null, null, out errors);
            if (process.get_if_exited() && process.get_exit_status() == 126) {
                throw new IOError.CANCELLED(_("The change was not authorized"));
            }
            if (!process.get_successful()) {
                string reason = "";
                if (errors != null) {
                    foreach (string line in errors.strip().split("\n")) {
                        if (line.has_prefix("singularity-fprint-driver: ")) reason = line.substring(27);
                    }
                }
                throw new IOError.FAILED(reason != "" ? reason : mode == "install" ? _("The driver could not be installed") : _("The driver could not be removed"));
            }
            installed = mode == "install";
        }

        public async void install() throws Error {
            yield run("install");
        }

        public async void uninstall() throws Error {
            yield run("uninstall");
        }
    }
}
