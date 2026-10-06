namespace Singularity {

    public class LoginScreenSync : Object {
        private const string[] PKEXEC_PATHS = { "/usr/bin/pkexec", "/bin/pkexec" };
        private const string[] HELPER_PATHS = {
            "/opt/local/libexec/singularity-login-screen",
            "/usr/local/libexec/singularity-login-screen",
            "/usr/libexec/singularity-login-screen",
        };

        public bool displays { get; set; default = true; }
        public bool keyboard { get; set; default = true; }
        public bool pointer { get; set; default = true; }
        public bool cursor { get; set; default = true; }

        private static string? first_existing(string[] paths) {
            foreach (string path in paths) {
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) return path;
            }
            return null;
        }

        public static bool available() {
            return first_existing(PKEXEC_PATHS) != null && first_existing(HELPER_PATHS) != null;
        }

        private static string labwc_file(string name) {
            return Path.build_filename(Environment.get_user_config_dir(), "labwc", name);
        }

        private static string? read(string path) {
            string contents;
            try {
                if (FileUtils.get_contents(path, out contents)) return contents;
            } catch (FileError e) {
            }
            return null;
        }

        private static string? section(string text, string tag) {
            int start = text.index_of("<" + tag + ">");
            int end = text.index_of("</" + tag + ">");
            if (start < 0 || end < start) return null;
            return text.substring(start, end - start + tag.length + 3);
        }

        public string build_payload() {
            var payload = new StringBuilder();
            string? rc = read(labwc_file("rc.xml"));
            string? xkb = keyboard && rc != null ? section(rc, "xkb") : null;
            string? libinput = pointer && rc != null ? section(rc, "libinput") : null;
            if (xkb != null || libinput != null) {
                payload.append("%%FILE rc.xml\n<?xml version=\"1.0\"?>\n<labwc_config>\n");
                if (xkb != null) payload.append("  <keyboard>\n    %s\n  </keyboard>\n".printf(xkb));
                if (libinput != null) payload.append("  %s\n".printf(libinput));
                payload.append("</labwc_config>\n");
            }
            string? outputs = displays ? read(labwc_file("output.xml")) : null;
            if (outputs != null) {
                payload.append("%%FILE output.xml\n");
                payload.append(outputs.has_suffix("\n") ? outputs : outputs + "\n");
            }
            if (cursor) {
                string env = "";
                string? existing = read(labwc_file("environment"));
                if (existing != null) {
                    foreach (string line in existing.split("\n")) {
                        if (line.has_prefix("XCURSOR_THEME=") || line.has_prefix("XCURSOR_SIZE=")) env += line + "\n";
                    }
                }
                if (env != "") payload.append("%%FILE environment\n" + env);
            }
            return payload.str;
        }

        private async void run(string mode, string? input) throws Error {
            string? pkexec = first_existing(PKEXEC_PATHS);
            string? helper = first_existing(HELPER_PATHS);
            if (pkexec == null || helper == null) {
                throw new IOError.NOT_FOUND(_("The login screen helper is not installed"));
            }
            var process = new Subprocess.newv({ pkexec, helper, mode },
                SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDERR_PIPE);
            string? errors;
            yield process.communicate_utf8_async(input ?? "", null, null, out errors);
            if (!process.get_successful()) {
                string reason = errors != null ? errors.strip() : "";
                throw new IOError.FAILED(reason != "" ? reason : _("The change was not authorized"));
            }
        }

        private const string BACKGROUND_DIR = "/var/lib/singularity/login-screen";

        private async void run_bytes(string mode, Bytes input) throws Error {
            string? pkexec = first_existing(PKEXEC_PATHS);
            string? helper = first_existing(HELPER_PATHS);
            if (pkexec == null || helper == null) {
                throw new IOError.NOT_FOUND(_("The login screen helper is not installed"));
            }
            var process = new Subprocess.newv({ pkexec, helper, mode },
                SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDERR_PIPE);
            Bytes? errors;
            yield process.communicate_async(input, null, null, out errors);
            if (!process.get_successful()) {
                string reason = errors != null ? ((string) errors.get_data()).strip() : "";
                int newline = reason.index_of("\n");
                if (newline > 0) reason = reason.substring(0, newline);
                reason = reason.replace("singularity-login-screen: ", "");
                throw new IOError.FAILED(reason != "" ? reason : _("The change was not authorized"));
            }
        }

        public static string? background_image() {
            string path = Path.build_filename(BACKGROUND_DIR, "background");
            return FileUtils.test(path, FileTest.EXISTS) ? path : null;
        }

        public static string? background_color() {
            string? text = read(Path.build_filename(BACKGROUND_DIR, "background-color"));
            return text != null && text.strip() != "" ? text.strip() : null;
        }

        public async void set_background_image(File image) throws Error {
            var bytes = yield image.load_bytes_async(null, null);
            yield run_bytes("background-image", bytes);
        }

        public async void set_background_color(string hex) throws Error {
            yield run("background-color", hex);
        }

        public async void reset_background() throws Error {
            yield run("background-reset", null);
        }

        public async void apply() throws Error {
            yield run("apply", build_payload());
        }

        public async void reset() throws Error {
            yield run("reset", null);
        }
    }
}
