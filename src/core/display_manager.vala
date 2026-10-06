using Gtk;
using Gdk;
using Singularity;

namespace Singularity {

    public class DisplayManager : Object {
        private static DisplayManager? _instance;

        // A wl_output can only advertise an INTEGER scale, so a fractional value
        // below 1.0 does not make the UI smaller -- it enlarges the logical
        // desktop beyond the panel's native size while clients are told "scale
        // 1", so everything renders undersized, including the settings page that
        // would undo it.
        //
        // MAX_SCALE is a protocol sanity ceiling, NOT the settings slider's
        // range. Integer scales above the slider maximum (4 and up) are
        // representable and are legitimately used on very high-DPI panels and
        // for accessibility, so they are passed through. But the value reaches
        // wl_fixed_from_double() in apply_configuration(), and wl_fixed is 24.8
        // fixed point: a non-finite or absurdly large value -- from a
        // hand-edited displays.json or a misbehaving compositor -- cannot be
        // represented and would overflow into a bad output configuration.
        private const double MIN_SCALE = 1.0;
        private const double MAX_SCALE = 16.0;

        /**
         * A sensible starting scale for a display that has no saved setting.
         *
         * Without this a fresh install comes up at 1.0 on every panel, which on
         * a high-DPI screen means an unreadably small UI and sends the user
         * straight to the scale slider. The physical size needed to compute it
         * is already reported by wl_output and was previously stored and never
         * read.
         *
         * Returns 1.0 whenever the DPI cannot be trusted: many outputs report a
         * physical size of 0x0 (and projectors/TVs report sizes that are honest
         * but irrelevant), so the fallback has to be the safe one.
         */
        public static double dpi_default_scale(int phys_w_mm, int phys_h_mm, int px_w, int px_h) {
            if (phys_w_mm <= 0 || phys_h_mm <= 0 || px_w <= 0 || px_h <= 0) {
                return 1.0;
            }
            double diag_mm = Math.sqrt((double) phys_w_mm * phys_w_mm
                                     + (double) phys_h_mm * phys_h_mm);
            double diag_in = diag_mm / 25.4;
            if (diag_in < 1.0) return 1.0;
            double diag_px = Math.sqrt((double) px_w * px_w + (double) px_h * px_h);
            double dpi = diag_px / diag_in;

            // Fractional steps are deliberate -- 4K/27" lands near 163 dpi, where
            // 2.0 is too large and 1.0 too small.
            if (dpi >= 192.0) return 2.0;
            if (dpi >= 168.0) return 1.75;
            if (dpi >= 144.0) return 1.5;
            if (dpi >= 120.0) return 1.25;
            return 1.0;
        }

        private void apply_dpi_defaults() {
            foreach (var m in monitors) {
                if (m.scale_from_config) continue;
                int pw = 0, ph = 0;
                if (m.current_mode != null) {
                    pw = m.current_mode.width;
                    ph = m.current_mode.height;
                }
                double d = dpi_default_scale(m.phys_width, m.phys_height, pw, ph);
                if (d != m.scale) {
                    message("DisplayManager: %s has no saved scale, defaulting to %.2f "
                            + "(%dx%d px, %dx%d mm)", m.name, d, pw, ph,
                            m.phys_width, m.phys_height);
                    m.scale = d;
                }
            }
        }

        private static double clamp_scale(double value) {
            // The negated comparison also rejects NaN, which would otherwise
            // propagate into the compositor configuration.
            if (!(value >= MIN_SCALE)) return MIN_SCALE;
            if (!(value <= MAX_SCALE)) return MAX_SCALE;  // also catches +inf
            return value;
        }

        public struct Mode {
            public int width;
            public int height;
            public int refresh;
            public bool preferred;
        }
        public class Monitor : Object {
            public string name;
            public string description;
            public string make;
            public string model;
            public string serial;
            public int phys_width;
            public int phys_height;
            public int x;
            public int y;
            public double scale;
            // True once a saved scale has been restored for this output, so the
            // DPI-derived default does not overwrite a deliberate choice.
            public bool scale_from_config;
            public int transform;
            public bool enabled;
            public bool vrr_supported { get; set; default = false; }
            public bool vrr_enabled { get; set; default = false; }
            public List<Mode?> modes;
            public Mode? current_mode;
            public void* head_handle;

            public Monitor(void* handle) {
                this.head_handle = handle;
                this.modes = new List<Mode?>();
                this.scale = 1.0;
                this.enabled = true;
            }
        }
        private List<Monitor> monitors;
        public string shell_monitor_name { get; set; default = ""; }
        public signal void monitors_changed();
        private uint32 serial;
        private bool _topology_changed = true;
        private uint _restore_timeout_id = 0;

        public static DisplayManager get_default() {
            if (_instance == null) {
                _instance = new DisplayManager();
            }
            return _instance;
        }

        private DisplayManager() {
            monitors = new List<Monitor>();
        }

        public void handle_add_head(void* head_handle) {
            var monitor = new Monitor(head_handle);
            monitors.append(monitor);
            _topology_changed = true;
            monitors_changed();
        }
        [CCode (cname = "singularity_display_manager_add_head")]
        public static void add_head_c(void* head_handle) {
            get_default().handle_add_head(head_handle);
        }

        public void handle_update_head_info(void* head_handle, string? make, string? model, string? serial) {
             foreach (var m in monitors) {
                if (m.head_handle == head_handle) {
                    if (make != null) m.make = make;
                    if (model != null) m.model = model;
                    if (serial != null) m.serial = serial;
                    monitors_changed();
                    return;
                }
            }
        }
        [CCode (cname = "singularity_display_manager_update_head_info")]
        public static void update_head_info_c(void* head_handle, string? make, string? model, string? serial) {
            get_default().handle_update_head_info(head_handle, make, model, serial);
        }

        public void handle_update_head(void* head_handle, string? name, string? description, int phys_w, int phys_h, int x, int y, int transform, double scale, bool enabled) {
            foreach (var m in monitors) {
                if (m.head_handle == head_handle) {
                    if (name != null) m.name = name;
                    if (description != null) m.description = description;
                    m.phys_width = phys_w;
                    m.phys_height = phys_h;
                    m.x = x;
                    m.y = y;
                    m.transform = transform;
                    m.scale = clamp_scale(scale);
                    m.enabled = enabled;
                    monitors_changed();
                    return;
                }
            }
        }
        [CCode (cname = "singularity_display_manager_update_head")]
        public static void update_head_c(void* head_handle, string? name, string? description, int phys_w, int phys_h, int x, int y, int transform, double scale, int enabled) {
            get_default().handle_update_head(head_handle, name, description, phys_w, phys_h, x, y, transform, scale, enabled != 0);
        }

        public void handle_add_mode(void* head_handle, int width, int height, int refresh, bool preferred) {
             foreach (var m in monitors) {
                if (m.head_handle == head_handle) {
                    Mode mode = Mode() { width = width, height = height, refresh = refresh, preferred = preferred };
                    m.modes.append(mode);
                    if (preferred && m.current_mode == null) {
                        m.current_mode = mode;
                    }
                    return;
                }
            }
        }
        [CCode (cname = "singularity_display_manager_add_mode")]
        public static void add_mode_c(void* head_handle, int width, int height, int refresh, int preferred) {
            get_default().handle_add_mode(head_handle, width, height, refresh, preferred != 0);
        }

        public void handle_set_current_mode(void* head_handle, int width, int height, int refresh) {
            foreach (var m in monitors) {
                if (m.head_handle == head_handle) {
                    foreach (var mode in m.modes) {
                        if (mode.width == width && mode.height == height && mode.refresh == refresh) {
                            m.current_mode = mode;
                            return;
                        }
                    }
                }
            }
        }
        [CCode (cname = "singularity_display_manager_set_current_mode")]
        public static void set_current_mode_c(void* head_handle, int width, int height, int refresh) {
            get_default().handle_set_current_mode(head_handle, width, height, refresh);
        }

        public void handle_remove_head(void* head_handle) {
            Monitor? found = null;
            foreach (var m in monitors) {
                if (m.head_handle == head_handle) {
                    found = m;
                    break;
                }
            }
            if (found != null) {
                monitors.remove(found);
                _topology_changed = true;
                monitors_changed();
            }
        }
        [CCode (cname = "singularity_display_manager_remove_head")]
        public static void remove_head_c(void* head_handle) {
            get_default().handle_remove_head(head_handle);
        }

        public void handle_adaptive_sync_changed(void* head_handle, uint32 state) {
            foreach (var m in monitors) {
                if (m.head_handle == head_handle) {
                    m.vrr_supported = true;
                    m.vrr_enabled = (state == 1);
                    monitors_changed();
                    return;
                }
            }
        }
        [CCode (cname = "singularity_display_manager_update_adaptive_sync")]
        public static void update_adaptive_sync_c(void* head_handle, uint32 state) {
            get_default().handle_adaptive_sync_changed(head_handle, state);
        }

        public void handle_set_serial(uint32 s) {
            this.serial = s;
            if (!_topology_changed) return;
            _topology_changed = false;
            if (_restore_timeout_id != 0) Source.remove(_restore_timeout_id);
            // output_manager.done arrives before the head data is copied into
            // DisplayManager, so wait until the full topology is available.
            _restore_timeout_id = Timeout.add(200, () => {
                _restore_timeout_id = 0;
                load_and_apply_saved();
                return Source.REMOVE;
            });
        }
        [CCode (cname = "singularity_display_manager_set_serial")]
        public static void set_serial_c(uint32 s) {
            get_default().handle_set_serial(s);
        }

        public unowned List<Monitor> get_monitors() {
            return monitors;
        }

        private string config_path() {
            return GLib.Path.build_filename(GLib.Environment.get_user_config_dir(), "singularity", "displays.json");
        }

        private string transform_name(int t) {
            switch (t) {
                case 1: return "90";
                case 2: return "180";
                case 3: return "270";
                case 4: return "flipped";
                case 5: return "flipped-90";
                case 6: return "flipped-180";
                case 7: return "flipped-270";
                default: return "normal";
            }
        }

        // Write labwc output.xml so positions survive compositor restart

        private void save_labwc_output_xml() {
            var xml = new StringBuilder();
            xml.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<outputs>\n");
            foreach (var m in monitors) {
                int mw = m.current_mode != null ? m.current_mode.width : 0;
                int mh = m.current_mode != null ? m.current_mode.height : 0;
                int mr = m.current_mode != null ? m.current_mode.refresh : 0;
                xml.append_printf("  <output name=\"%s\">\n", m.name ?? "");
                xml.append_printf("    <mode width=\"%d\" height=\"%d\" refresh=\"%d\"/>\n", mw, mh, mr);
                xml.append_printf("    <position x=\"%d\" y=\"%d\"/>\n", m.x, m.y);
                xml.append_printf("    <scale>%.4f</scale>\n", m.scale);
                xml.append_printf("    <transform>%s</transform>\n", transform_name(m.transform));
                xml.append_printf("    <enabled>%s</enabled>\n", m.enabled ? "yes" : "no");
                xml.append_printf("    <adaptiveSync>%s</adaptiveSync>\n", m.vrr_enabled ? "yes" : "no");
                DisplayColor.get_default().append_output_xml(xml, m);
                xml.append("  </output>\n");
            }
            xml.append("</outputs>\n");
            // Output positions are picked up by labwc on its next start, so this
            // only writes the file (no live reconfigure).
            if (Singularity.Compositor.LabwcBackend.get_default().write_config("output.xml", xml.str)) {
                message("DisplayManager: saved labwc output.xml");
            }
        }

        public void apply_color() {
            save_labwc_output_xml();
            Singularity.Compositor.LabwcBackend.get_default().reconfigure();
        }

        // Save JSON config for our own startup-apply

        public void save_configuration() {
            try {
                string dir = GLib.Path.build_filename(GLib.Environment.get_user_config_dir(), "singularity");
                GLib.DirUtils.create_with_parents(dir, 0755);
                var builder = new Json.Builder();
                builder.begin_object();
                builder.set_member_name("shell_monitor");
                builder.add_string_value(shell_monitor_name);
                builder.set_member_name("monitors");
                builder.begin_array();
                foreach (var m in monitors) {
                    builder.begin_object();
                    builder.set_member_name("name"); builder.add_string_value(m.name ?? "");
                    builder.set_member_name("x"); builder.add_int_value(m.x);
                    builder.set_member_name("y"); builder.add_int_value(m.y);
                    builder.set_member_name("scale"); builder.add_double_value(m.scale);
                    builder.set_member_name("transform"); builder.add_int_value(m.transform);
                    builder.set_member_name("enabled"); builder.add_boolean_value(m.enabled);
                    builder.set_member_name("vrr_enabled"); builder.add_boolean_value(m.vrr_enabled);
                    if (m.current_mode != null) {
                        builder.set_member_name("mode_w"); builder.add_int_value(m.current_mode.width);
                        builder.set_member_name("mode_h"); builder.add_int_value(m.current_mode.height);
                        builder.set_member_name("mode_r"); builder.add_int_value(m.current_mode.refresh);
                    }
                    builder.end_object();
                }
                builder.end_array();
                builder.end_object();
                var gen = new Json.Generator();
                gen.set_root(builder.get_root());
                gen.pretty = true;
                gen.to_file(config_path());
                message("DisplayManager: config saved to %s", config_path());
            } catch (GLib.Error e) {
                warning("DisplayManager: save failed: %s", e.message);
            }
            save_labwc_output_xml();
        }

        // Load saved positions and apply them at startup

        public void load_and_apply_saved() {
            string path = config_path();
            if (!GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) {
                // First boot: nothing saved, so every output takes the default.
                apply_dpi_defaults();
                apply_configuration();
                return;
            }
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null) {
                    warning("DisplayManager: malformed config");
                    return;
                }
                Json.Array arr;
                // Support both old (array) and new (object with "monitors" key) format
                if (root.get_node_type() == Json.NodeType.OBJECT) {
                    var root_obj = root.get_object();
                    if (root_obj.has_member("shell_monitor")) {
                        shell_monitor_name = root_obj.get_string_member("shell_monitor");
                    }
                    if (!root_obj.has_member("monitors")) {
                        warning("DisplayManager: malformed config (no monitors key)");
                        return;
                    }
                    arr = root_obj.get_array_member("monitors");
                } else if (root.get_node_type() == Json.NodeType.ARRAY) {
                    arr = root.get_array();
                } else {
                    warning("DisplayManager: malformed config");
                    return;
                }
                foreach (var node in arr.get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var obj = node.get_object();
                    if (!obj.has_member("name")) continue;
                    string name = obj.get_string_member("name");
                    foreach (var m in monitors) {
                        if (m.name == name) {
                            m.x = (int)obj.get_int_member("x");
                            m.y = (int)obj.get_int_member("y");
                            m.scale = clamp_scale(obj.get_double_member("scale"));
                            m.scale_from_config = true;
                            m.transform = (int)obj.get_int_member("transform");
                            m.enabled = obj.get_boolean_member("enabled");
                            if (obj.has_member("vrr_enabled")) m.vrr_enabled = obj.get_boolean_member("vrr_enabled");
                            if (obj.has_member("mode_w")) {
                                int mw = (int)obj.get_int_member("mode_w");
                                int mh = (int)obj.get_int_member("mode_h");
                                int mr = (int)obj.get_int_member("mode_r");
                                foreach (var mode in m.modes) {
                                    if (mode.width == mw && mode.height == mh && mode.refresh == mr) {
                                        m.current_mode = mode;
                                        break;
                                    }
                                }
                            }
                            break;
                        }
                    }
                }
                // An output the config has never seen (new monitor, or a config
                // written before this display was attached) is still a fresh
                // display and gets the DPI default rather than a flat 1.0.
                apply_dpi_defaults();
                message("DisplayManager: loaded saved config from %s", path);
                apply_configuration();
            } catch (GLib.Error e) {
                warning("DisplayManager: load failed: %s", e.message);
            }
        }

        public void apply_configuration() {
            Singularity.wayland_begin_output_config(serial);
            foreach (var m in monitors) {
                int mode_w = 0;
                int mode_h = 0;
                int mode_r = 0;
                if (m.current_mode != null) {
                    mode_w = m.current_mode.width;
                    mode_h = m.current_mode.height;
                    mode_r = m.current_mode.refresh;
                }
                int vrr = m.vrr_supported ? (m.vrr_enabled ? 1 : 0) : 2;
                Singularity.wayland_config_head_v2(m.head_handle, m.enabled ? 1 : 0, m.x, m.y, m.scale, m.transform, mode_w, mode_h, mode_r, vrr);
            }
            Singularity.wayland_finish_output_config();
        }

        public Monitor? get_shell_monitor() {
            if (shell_monitor_name == "") return null;
            foreach (var m in monitors) {
                if (m.name == shell_monitor_name) return m;
            }
            return null;
        }

        public void apply_shell_monitor() {
            var settings = new GLib.Settings("dev.sinty.desktop");
            settings.set_string("shell-monitor", shell_monitor_name);
            save_configuration();
        }
    }
}
