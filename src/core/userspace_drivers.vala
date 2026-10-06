namespace Singularity {

    public class UserspaceDriver : Object {
        public UserspaceDriverProvider provider { get; construct; }
        public string device_id { get; set; default = ""; }
        public string vendor { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string version { get; set; default = ""; }
        public string license { get; set; default = ""; }
        public string source { get; set; default = ""; }
        public string url { get; set; default = ""; }
        public int64 size { get; set; default = 0; }
        public bool installed { get; set; default = false; }

        public UserspaceDriver(UserspaceDriverProvider provider) {
            Object(provider: provider);
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

        public async void install() throws Error {
            yield provider.run("install", device_id);
            installed = true;
        }

        public async void uninstall() throws Error {
            yield provider.run("uninstall", device_id);
            installed = false;
        }
    }

    public class UserspaceDriverProvider : Object {
        public const string GROUP = "Driver Provider";
        private const string[] PKEXEC_PATHS = { "/usr/bin/pkexec", "/bin/pkexec" };
        private const string[] HELPER_DIRS = {
            "/opt/local/libexec",
            "/usr/local/libexec",
            "/usr/libexec",
            "/usr/lib/singularity",
        };

        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string icon_name { get; set; default = "application-x-firmware-symbolic"; }
        public string helper { get; set; default = ""; }
        public string detect { get; set; default = "command"; }
        public string setup_page { get; set; default = ""; }
        public string[] usb_vendors = {};
        public string[] product_keywords = {};

        public static UserspaceDriverProvider fingerprint() {
            var provider = new UserspaceDriverProvider();
            provider.id = "fingerprint";
            provider.name = _("Fingerprint Reader");
            provider.icon_name = "auth-fingerprint-symbolic";
            provider.helper = "singularity-fprint-driver";
            provider.detect = "fingerprint";
            provider.setup_page = "users";
            return provider;
        }

        public static UserspaceDriverProvider? from_keyfile(KeyFile keyfile, string fallback_id) {
            try {
                if (!keyfile.has_group(GROUP)) return null;
                var provider = new UserspaceDriverProvider();
                provider.id = keyfile.has_key(GROUP, "Id") ? keyfile.get_string(GROUP, "Id").strip() : fallback_id;
                provider.name = keyfile.get_locale_string(GROUP, "Name", null).strip();
                provider.helper = keyfile.get_string(GROUP, "Helper").strip();
                if (keyfile.has_key(GROUP, "Icon")) provider.icon_name = keyfile.get_string(GROUP, "Icon").strip();
                if (keyfile.has_key(GROUP, "Detect")) provider.detect = keyfile.get_string(GROUP, "Detect").strip().down();
                if (keyfile.has_key(GROUP, "SetupPage")) provider.setup_page = keyfile.get_string(GROUP, "SetupPage").strip();
                if (keyfile.has_key(GROUP, "USBVendors")) provider.usb_vendors = keyfile.get_string_list(GROUP, "USBVendors");
                if (keyfile.has_key(GROUP, "ProductKeywords")) provider.product_keywords = keyfile.get_string_list(GROUP, "ProductKeywords");
                if (provider.id == "" || provider.name == "" || provider.helper == "") return null;
                return provider;
            } catch (KeyFileError e) {
                warning("Drivers: invalid provider %s: %s", fallback_id, e.message);
                return null;
            }
        }

        public string? helper_path() {
            if (helper.has_prefix("/")) {
                return FileUtils.test(helper, FileTest.IS_EXECUTABLE) ? helper : null;
            }
            if (helper.contains("/")) return null;
            foreach (string dir in HELPER_DIRS) {
                string path = Path.build_filename(dir, helper);
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) return path;
            }
            return null;
        }

        public async string[] detect_devices() {
            switch (detect) {
                case "fingerprint":
                    string? sensor = FingerprintManager.unsupported_sensor();
                    return sensor != null ? new string[] { sensor } : new string[] {};
                case "usb":
                    return usb_devices();
            }
            string? path = helper_path();
            if (path == null) return {};
            string? output = yield capture({ path, "detect" });
            if (output == null) return {};
            string[] ids = {};
            foreach (string line in output.split("\n")) {
                if (line.strip() != "") ids += line.strip();
            }
            return ids;
        }

        private string[] usb_devices() {
            string[] ids = {};
            try {
                var dir = Dir.open("/sys/bus/usb/devices");
                string? entry;
                while ((entry = dir.read_name()) != null) {
                    string base_path = Path.build_filename("/sys/bus/usb/devices", entry);
                    string vendor, product, label = "";
                    try {
                        FileUtils.get_contents(Path.build_filename(base_path, "idVendor"), out vendor);
                        FileUtils.get_contents(Path.build_filename(base_path, "idProduct"), out product);
                    } catch (FileError e) {
                        continue;
                    }
                    vendor = vendor.strip();
                    if (usb_vendors.length > 0 && !(vendor in usb_vendors)) continue;
                    try {
                        FileUtils.get_contents(Path.build_filename(base_path, "product"), out label);
                    } catch (FileError e) {
                    }
                    if (product_keywords.length > 0) {
                        bool matched = false;
                        foreach (string keyword in product_keywords) {
                            if (keyword != "" && label.down().contains(keyword.down())) matched = true;
                        }
                        if (!matched) continue;
                    }
                    string id = "%s:%s".printf(vendor, product.strip());
                    if (!(id in ids)) ids += id;
                }
            } catch (FileError e) {
            }
            return ids;
        }

        private static async string? capture(string[] argv) {
            try {
                var process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string? output;
                yield process.communicate_utf8_async(null, null, out output, null);
                return process.get_successful() ? output : null;
            } catch (Error e) {
                return null;
            }
        }

        public async UserspaceDriver? info(string device) {
            string? path = helper_path();
            if (path == null) return null;
            string? output = yield capture({ path, "info", device });
            if (output == null) return null;
            var driver = new UserspaceDriver(this);
            foreach (string line in output.split("\n")) {
                int eq = line.index_of("=");
                if (eq <= 0) continue;
                string key = line.substring(0, eq);
                string value = line.substring(eq + 1);
                switch (key) {
                    case "id": driver.device_id = value; break;
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
            return driver.device_id != "" && driver.name != "" ? driver : null;
        }

        public async Gee.ArrayList<UserspaceDriver> drivers() {
            var list = new Gee.ArrayList<UserspaceDriver>();
            foreach (string device in yield detect_devices()) {
                var driver = yield info(device);
                if (driver != null) list.add(driver);
            }
            return list;
        }

        public async void run(string mode, string device) throws Error {
            string? pkexec = null;
            foreach (string candidate in PKEXEC_PATHS) {
                if (FileUtils.test(candidate, FileTest.IS_EXECUTABLE)) {
                    pkexec = candidate;
                    break;
                }
            }
            string? path = helper_path();
            if (pkexec == null || path == null) {
                throw new IOError.NOT_FOUND(_("The driver installer is not available"));
            }
            var process = new Subprocess.newv({ pkexec, path, mode, device },
                SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
            string? errors;
            yield process.communicate_utf8_async(null, null, null, out errors);
            if (process.get_if_exited() && process.get_exit_status() == 126) {
                throw new IOError.CANCELLED(_("The change was not authorized"));
            }
            if (!process.get_successful()) {
                string prefix = Path.get_basename(path) + ": ";
                string reason = "";
                if (errors != null) {
                    foreach (string line in errors.strip().split("\n")) {
                        if (line.has_prefix(prefix)) reason = line.substring(prefix.length);
                    }
                }
                throw new IOError.FAILED(reason != "" ? reason
                    : mode == "install" ? _("The driver could not be installed") : _("The driver could not be removed"));
            }
        }
    }

    public class UserspaceDrivers : Object {
        public const string DIR_NAME = "singularity/drivers.d";

        public static string[] search_dirs() {
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs()) dirs += Path.build_filename(dir, DIR_NAME);
            dirs += Path.build_filename("/etc", DIR_NAME);
            foreach (unowned string dir in Environment.get_system_data_dirs()) dirs += Path.build_filename(dir, DIR_NAME);
            dirs += Path.build_filename("/opt/local/share", DIR_NAME);
            return dirs;
        }

        public static Gee.ArrayList<UserspaceDriverProvider> providers() {
            var seen_files = new Gee.HashSet<string>();
            var hidden = new Gee.HashSet<string>();
            var by_id = new Gee.HashMap<string, UserspaceDriverProvider>();
            var order = new Gee.ArrayList<string>();
            foreach (string dir_path in search_dirs()) {
                Dir dir;
                try {
                    dir = Dir.open(dir_path);
                } catch (FileError e) {
                    continue;
                }
                var names = new Gee.ArrayList<string>();
                string? entry;
                while ((entry = dir.read_name()) != null) {
                    if (entry.has_suffix(".conf")) names.add(entry);
                }
                names.sort();
                foreach (string file_name in names) {
                    if (seen_files.contains(file_name)) continue;
                    seen_files.add(file_name);
                    var keyfile = new KeyFile();
                    try {
                        keyfile.load_from_file(Path.build_filename(dir_path, file_name), KeyFileFlags.NONE);
                    } catch (Error e) {
                        warning("Drivers: cannot read %s/%s: %s", dir_path, file_name, e.message);
                        continue;
                    }
                    string fallback = file_name.substring(0, file_name.length - 5);
                    bool is_hidden = false;
                    try {
                        is_hidden = keyfile.has_group(UserspaceDriverProvider.GROUP)
                            && keyfile.has_key(UserspaceDriverProvider.GROUP, "Hidden")
                            && keyfile.get_boolean(UserspaceDriverProvider.GROUP, "Hidden");
                    } catch (KeyFileError e) {
                    }
                    if (is_hidden) {
                        string hidden_id = fallback;
                        try {
                            if (keyfile.has_key(UserspaceDriverProvider.GROUP, "Id")) {
                                hidden_id = keyfile.get_string(UserspaceDriverProvider.GROUP, "Id").strip();
                            }
                        } catch (KeyFileError e) {
                        }
                        hidden.add(hidden_id);
                        continue;
                    }
                    var provider = UserspaceDriverProvider.from_keyfile(keyfile, fallback);
                    if (provider == null || by_id.has_key(provider.id)) continue;
                    by_id[provider.id] = provider;
                    order.add(provider.id);
                }
            }
            if (!by_id.has_key("fingerprint")) {
                by_id["fingerprint"] = UserspaceDriverProvider.fingerprint();
                order.insert(0, "fingerprint");
            }
            var list = new Gee.ArrayList<UserspaceDriverProvider>();
            foreach (string id in order) {
                if (!hidden.contains(id)) list.add(by_id[id]);
            }
            return list;
        }
    }
}
