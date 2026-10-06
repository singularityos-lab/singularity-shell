namespace Singularity {

    public class OutputColorInfo : Object {
        public bool hdr_supported = false;
        public string hdr_reason = "";
        public bool hdr_active = false;
        public bool sdr_brightness_supported = false;
        public bool icc_supported = false;
        public bool icc_active = false;
        public string icc_profile = "";
        public string icc_error = "";
    }

    public class DisplayColor : Object {
        public const int SDR_DEFAULT = 203;
        public const int SDR_MIN = 80;
        public const int SDR_MAX = 480;

        private static DisplayColor? _instance;
        private GLib.Settings settings;
        private FileMonitor? monitor = null;
        private Gee.HashMap<string, OutputColorInfo> infos = new Gee.HashMap<string, OutputColorInfo>();
        public bool compositor_reports { get; private set; default = false; }
        public signal void changed();

        public static DisplayColor get_default() {
            if (_instance == null) _instance = new DisplayColor();
            return _instance;
        }

        construct {
            settings = new GLib.Settings("dev.sinty.desktop");
            string path = state_path();
            try {
                monitor = File.new_for_path(path).get_parent().monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
                monitor.changed.connect((file, other, ev) => {
                    string? name = file.get_basename();
                    string? other_name = other != null ? other.get_basename() : null;
                    string target = Path.get_basename(path);
                    if (name == target || other_name == target) reload();
                });
            } catch (Error e) {
                warning("DisplayColor: cannot watch %s: %s", path, e.message);
            }
            reload();
        }

        public static string state_path() {
            string display = Environment.get_variable("WAYLAND_DISPLAY") ?? "wayland-0";
            return Path.build_filename(Environment.get_user_runtime_dir(), "labwc-color-%s.ini".printf(display));
        }

        private void reload() {
            infos.clear();
            var kf = new KeyFile();
            try {
                kf.load_from_file(state_path(), KeyFileFlags.NONE);
                compositor_reports = true;
                foreach (string group in kf.get_groups()) {
                    var info = new OutputColorInfo();
                    info.hdr_supported = read_bool(kf, group, "HdrSupported");
                    info.hdr_reason = read_string(kf, group, "HdrReason");
                    info.hdr_active = read_bool(kf, group, "HdrActive");
                    info.sdr_brightness_supported = read_bool(kf, group, "SdrBrightnessSupported");
                    info.icc_supported = read_bool(kf, group, "IccSupported");
                    info.icc_active = read_bool(kf, group, "IccActive");
                    info.icc_profile = read_string(kf, group, "IccProfile");
                    info.icc_error = read_string(kf, group, "IccError");
                    infos[group] = info;
                }
            } catch (Error e) {
                compositor_reports = false;
            }
            changed();
        }

        private static bool read_bool(KeyFile kf, string group, string key) {
            try {
                return kf.get_boolean(group, key);
            } catch (Error e) {
                return false;
            }
        }

        private static string read_string(KeyFile kf, string group, string key) {
            try {
                return kf.get_string(group, key);
            } catch (Error e) {
                return "";
            }
        }

        public OutputColorInfo? info(string connector) {
            return infos.has_key(connector) ? infos[connector] : null;
        }

        public static string key_for(DisplayManager.Monitor m) {
            return ColorProfiles.display_key(m.make, m.model, m.serial, m.name ?? "");
        }

        public bool has_hdr_choice(string key) {
            return settings.get_value("output-hdr").lookup_value(key, VariantType.BOOLEAN) != null;
        }

        public bool hdr_enabled(string key) {
            var v = settings.get_value("output-hdr").lookup_value(key, VariantType.BOOLEAN);
            return v != null && v.get_boolean();
        }

        public void set_hdr(string key, bool enabled) {
            var builder = new VariantBuilder(new VariantType("a{sb}"));
            var iter = settings.get_value("output-hdr").iterator();
            string k;
            bool b;
            while (iter.next("{sb}", out k, out b)) {
                if (k != key) builder.add("{sb}", k, b);
            }
            builder.add("{sb}", key, enabled);
            settings.set_value("output-hdr", builder.end());
        }

        public int sdr_brightness(string key) {
            var v = settings.get_value("output-sdr-brightness").lookup_value(key, VariantType.INT32);
            return v != null ? v.get_int32().clamp(SDR_MIN, SDR_MAX) : SDR_DEFAULT;
        }

        public void set_sdr_brightness(string key, int nits) {
            var builder = new VariantBuilder(new VariantType("a{si}"));
            var iter = settings.get_value("output-sdr-brightness").iterator();
            string k;
            int n;
            while (iter.next("{si}", out k, out n)) {
                if (k != key) builder.add("{si}", k, n);
            }
            builder.add("{si}", key, nits.clamp(SDR_MIN, SDR_MAX));
            settings.set_value("output-sdr-brightness", builder.end());
        }

        public string? profile_path(string key) {
            string? path = ColorProfiles.stored_assignment(key);
            return path != null && path != "" ? path : null;
        }

        public void append_output_xml(StringBuilder xml, DisplayManager.Monitor m) {
            string key = key_for(m);
            if (has_hdr_choice(key)) {
                xml.append_printf("    <hdr>%s</hdr>\n", hdr_enabled(key) ? "yes" : "no");
                xml.append_printf("    <sdrBrightness>%d</sdrBrightness>\n", sdr_brightness(key));
            }
            string? icc = profile_path(key);
            if (icc != null) {
                xml.append_printf("    <iccProfile>%s</iccProfile>\n", Markup.escape_text(icc));
            }
        }

        public static string hdr_reason_text(OutputColorInfo? info, bool reports) {
            if (!reports || info == null) return _("The compositor does not report HDR support");
            string r = info.hdr_reason;
            if (r.contains("renderer")) return _("The graphics driver cannot show HDR");
            if (r != "") return _("This display does not support HDR");
            return _("HDR is not available");
        }
    }
}
