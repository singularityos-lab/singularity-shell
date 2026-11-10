namespace Singularity {

    public class FingerprintDriver : Object {
        public const string SERVICE = "dev.sinty.FingerprintDriver1";
        private const string SERVICE_PATH = "/dev/sinty/FingerprintDriver1";

        public string id { get; private set; default = ""; }
        public string vendor { get; private set; default = ""; }
        public string name { get; private set; default = ""; }
        public string version { get; private set; default = ""; }
        public string license { get; private set; default = ""; }
        public string source { get; private set; default = ""; }
        public string url { get; private set; default = ""; }
        public int64 size { get; private set; default = 0; }
        public bool installed { get; private set; default = false; }

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
            if (!SystemService.activatable(SERVICE)) return null;
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var reply = yield bus.call(SERVICE, SERVICE_PATH, SERVICE, "Info", new Variant("(s)", sensor),
                    new VariantType("(a{ss})"), DBusCallFlags.NONE, 10000, null);
                var driver = new FingerprintDriver();
                var iter = reply.get_child_value(0).iterator();
                string key;
                string value;
                while (iter.next("{ss}", out key, out value)) {
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

        private async void run(string method) throws Error {
            try {
                yield SystemService.call(SERVICE, SERVICE_PATH, method, new Variant("(s)", id),
                    _("The driver installer is not available"));
            } catch (IOError.PERMISSION_DENIED e) {
                throw new IOError.CANCELLED(e.message);
            } catch (IOError.FAILED e) {
                throw new IOError.FAILED(e.message != "" ? e.message : method == "Install" ? _("The driver could not be installed") : _("The driver could not be removed"));
            }
            installed = method == "Install";
        }

        public async void install() throws Error {
            yield run("Install");
        }

        public async void uninstall() throws Error {
            yield run("Uninstall");
        }
    }
}
