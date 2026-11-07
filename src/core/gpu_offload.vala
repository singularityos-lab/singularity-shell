namespace Singularity {

    public class GpuOffload : Object {
        private const string DRM = "/sys/class/drm";

        private static GpuOffload? instance = null;
        private string[] keys = {};
        private string[] values = {};

        public bool available { get { return keys.length > 0; } }
        public string name { get; private set; default = ""; }

        public static GpuOffload get_default() {
            if (instance == null) instance = new GpuOffload();
            return instance;
        }

        private GpuOffload() {
            probe();
        }

        public static bool prefers(GLib.AppInfo app_info) {
            var dai = app_info as GLib.DesktopAppInfo;
            if (dai == null) return false;
            return dai.get_boolean("PrefersNonDefaultGPU") || dai.get_boolean("X-KDE-RunOnDiscreteGpu");
        }

        public void apply(GLib.AppLaunchContext ctx) {
            for (int i = 0; i < keys.length; i++) ctx.setenv(keys[i], values[i]);
        }

        private void probe() {
            Dir dir;
            try {
                dir = Dir.open(DRM);
            } catch (FileError e) {
                return;
            }
            var cards = new GLib.List<string>();
            string? entry;
            while ((entry = dir.read_name()) != null) {
                if (entry.has_prefix("card") && !entry.contains("-")) cards.insert_sorted(entry, strcmp);
            }
            string[] slots = {};
            string[] drivers = {};
            string[] vendors = {};
            int primary = 0;
            foreach (string card in cards) {
                string device = Path.build_filename(DRM, card, "device");
                string? slot = link_name(device);
                string? driver = link_name(Path.build_filename(device, "driver"));
                if (slot == null || driver == null || !slot.contains(":") || slot in slots) continue;
                if (read_line(Path.build_filename(device, "boot_vga")) == "1") primary = slots.length;
                slots += slot;
                drivers += driver;
                vendors += read_line(Path.build_filename(device, "vendor"));
            }
            if (slots.length < 2) return;
            int other = primary == 0 ? 1 : 0;
            if (drivers[other] == "nvidia") {
                keys = { "__NV_PRIME_RENDER_OFFLOAD", "__GLX_VENDOR_LIBRARY_NAME", "__VK_LAYER_NV_optimus" };
                values = { "1", "nvidia", "NVIDIA_only" };
            } else {
                keys = { "DRI_PRIME" };
                values = { "pci-" + slots[other].replace(":", "_").replace(".", "_") };
            }
            name = vendor_name(vendors[other]);
        }

        private static string vendor_name(string vendor) {
            switch (vendor) {
                case "0x10de": return "NVIDIA";
                case "0x1002": return "AMD";
                case "0x8086": return "Intel";
                default: return "";
            }
        }

        private static string? link_name(string path) {
            try {
                return Path.get_basename(FileUtils.read_link(path));
            } catch (FileError e) {
                return null;
            }
        }

        private static string read_line(string path) {
            try {
                string text;
                FileUtils.get_contents(path, out text);
                return text.strip();
            } catch (FileError e) {
                return "";
            }
        }
    }
}
