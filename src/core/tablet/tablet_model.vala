namespace Singularity.Tablet {

    public struct Area {
        public double x;
        public double y;
        public double width;
        public double height;

        public Area(double x, double y, double width, double height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }

        public bool is_empty() {
            return width <= 0 || height <= 0;
        }
    }

    public class Geometry {

        public static Area clamp(Area area, double tablet_width, double tablet_height) {
            double x = area.x.clamp(0, tablet_width);
            double y = area.y.clamp(0, tablet_height);
            double w = area.width.clamp(0, tablet_width - x);
            double h = area.height.clamp(0, tablet_height - y);
            return Area(x, y, w, h);
        }

        public static Area fit_aspect(Area area, double target_width, double target_height) {
            if (area.is_empty() || target_width <= 0 || target_height <= 0) return area;
            double target = target_width / target_height;
            double current = area.width / area.height;
            if ((current - target).abs() < 1e-9) return area;
            if (current > target) {
                double w = area.height * target;
                return Area(area.x + (area.width - w) / 2.0, area.y, w, area.height);
            }
            double h = area.width / target;
            return Area(area.x, area.y + (area.height - h) / 2.0, area.width, h);
        }

        public static Area active_area(double tablet_width, double tablet_height, bool custom, Area custom_area,
                                       bool keep_aspect, double screen_width, double screen_height) {
            var area = Area(0, 0, tablet_width, tablet_height);
            if (custom) {
                var clamped = clamp(custom_area, tablet_width, tablet_height);
                if (!clamped.is_empty()) area = clamped;
            }
            if (keep_aspect) area = fit_aspect(area, screen_width, screen_height);
            return area;
        }
    }

    public class PressureCurve {
        private const double[] PRESETS = {
            0.0, 0.6, 0.4, 1.0,
            0.0, 0.3, 0.7, 1.0,
            0.0, 0.0, 1.0, 1.0,
            0.3, 0.0, 1.0, 0.7,
            0.6, 0.0, 1.0, 0.4
        };

        public const int PRESET_COUNT = 5;
        public const int LINEAR = 2;

        public static double[] preset(int index) {
            int i = index.clamp(0, PRESET_COUNT - 1) * 4;
            return { PRESETS[i], PRESETS[i + 1], PRESETS[i + 2], PRESETS[i + 3] };
        }

        public static int preset_index(double[] curve) {
            if (curve.length != 4) return -1;
            for (int p = 0; p < PRESET_COUNT; p++) {
                bool same = true;
                for (int k = 0; k < 4; k++) {
                    if ((PRESETS[p * 4 + k] - curve[k]).abs() > 0.001) same = false;
                }
                if (same) return p;
            }
            return -1;
        }

        private static double bezier(double p1, double p2, double t) {
            double u = 1.0 - t;
            return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t;
        }

        public static double apply(double[] curve, double pressure) {
            if (pressure <= 0) return 0;
            if (pressure >= 1) return 1;
            double lo = 0;
            double hi = 1;
            double t = pressure;
            for (int i = 0; i < 32; i++) {
                t = (lo + hi) / 2.0;
                if (bezier(curve[0], curve[2], t) < pressure) lo = t;
                else hi = t;
            }
            return bezier(curve[1], curve[3], t).clamp(0, 1);
        }
    }

    public class DeviceInfo : Object {
        public string name = "";
        public uint vendor_id = 0;
        public uint product_id = 0;
        public double width_mm = 0;
        public double height_mm = 0;
        public int pad_buttons = 0;
        public int pad_rings = 0;
        public int pad_strips = 0;
    }

    public class ToolInfo : Object {
        public string tool_type = "pen";
        public bool pressure = false;
        public string[] buttons = {};
    }

    public class State : Object {
        public Gee.ArrayList<DeviceInfo> devices = new Gee.ArrayList<DeviceInfo>();
        public Gee.ArrayList<ToolInfo> tools = new Gee.ArrayList<ToolInfo>();

        public static State parse(string data) {
            var state = new State();
            var file = new KeyFile();
            try {
                file.load_from_data(data, data.length, KeyFileFlags.NONE);
            } catch (Error e) {
                return state;
            }
            foreach (string group in file.get_groups()) {
                if (group.has_prefix("Tablet ")) {
                    var dev = new DeviceInfo();
                    dev.name = read_string(file, group, "Name");
                    dev.vendor_id = (uint) read_int(file, group, "VendorId");
                    dev.product_id = (uint) read_int(file, group, "ProductId");
                    dev.width_mm = read_double(file, group, "WidthMm");
                    dev.height_mm = read_double(file, group, "HeightMm");
                    dev.pad_buttons = read_int(file, group, "PadButtons");
                    dev.pad_rings = read_int(file, group, "PadRings");
                    dev.pad_strips = read_int(file, group, "PadStrips");
                    state.devices.add(dev);
                } else if (group.has_prefix("Tool ")) {
                    var tool = new ToolInfo();
                    tool.tool_type = read_string(file, group, "Type");
                    tool.pressure = read_string(file, group, "Pressure") == "true";
                    string[] buttons = {};
                    foreach (string b in read_string(file, group, "Buttons").split(";")) {
                        if (b.strip() != "") buttons += b.strip();
                    }
                    tool.buttons = buttons;
                    state.tools.add(tool);
                }
            }
            return state;
        }

        public DeviceInfo? primary {
            owned get { return devices.size > 0 ? devices[0] : null; }
        }

        public int pad_buttons {
            get {
                int count = 0;
                foreach (var dev in devices) count = int.max(count, dev.pad_buttons);
                return count;
            }
        }

        public bool has_button(string name) {
            foreach (var tool in tools) {
                foreach (string b in tool.buttons) {
                    if (b == name) return true;
                }
            }
            return false;
        }

        private static string read_string(KeyFile file, string group, string key) {
            try {
                return file.get_value(group, key);
            } catch (Error e) {
                return "";
            }
        }

        private static int read_int(KeyFile file, string group, string key) {
            return int.parse(read_string(file, group, key));
        }

        private static double read_double(KeyFile file, string group, string key) {
            return double.parse(read_string(file, group, key));
        }
    }

    public class Shortcut {
        public const uint SHIFT = 1;
        public const uint CTRL = 2;
        public const uint ALT = 4;
        public const uint SUPER = 8;

        public static bool parse(string text, out uint modifiers, out string key) {
            modifiers = 0;
            key = "";
            string[] parts = text.strip().split("+");
            for (int i = 0; i < parts.length; i++) {
                string part = parts[i].strip().down();
                bool last = i == parts.length - 1;
                if (!last && part == "ctrl") modifiers |= CTRL;
                else if (!last && part == "shift") modifiers |= SHIFT;
                else if (!last && part == "alt") modifiers |= ALT;
                else if (!last && part == "super") modifiers |= SUPER;
                else if (last && part != "") key = parts[i].strip();
                else return false;
            }
            return key != "";
        }
    }

    public class RcInput : Object {
        public string output = "";
        public Area? area = null;
        public bool left_handed = false;
        public double[] curve = { 0.0, 0.0, 1.0, 1.0 };
        public bool mouse_mode = false;
        public HashTable<string, string> stylus = new HashTable<string, string>(str_hash, str_equal);
        public HashTable<string, string> pad = new HashTable<string, string>(str_hash, str_equal);
        public string command = "";
    }

    public class Rc {
        public const string[] STYLUS_BUTTONS = { "Stylus", "Stylus2", "Stylus3" };
        public const string[] PAD_BUTTONS = { "Pad", "Pad2", "Pad3", "Pad4", "Pad5", "Pad6", "Pad7", "Pad8", "Pad9" };

        public static string? mouse_button(string value) {
            switch (value) {
                case "left": return "Left";
                case "right": return "Right";
                case "middle": return "Middle";
                case "back": return "Side";
                case "forward": return "Extra";
                case "none": return "None";
            }
            return null;
        }

        private static string num(double value) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return value.format(buf, "%.3f");
        }

        private static string escape(string text) {
            return Markup.escape_text(text);
        }

        public static string build(RcInput input) {
            var xml = new StringBuilder();
            xml.append_printf("  <tablet rotate=\"%d\" mouseEmulation=\"no\">\n", input.left_handed ? 180 : 0);
            if (input.output != "")
                xml.append_printf("    <mapToOutput>%s</mapToOutput>\n", escape(input.output));
            if (input.area != null && !input.area.is_empty()) {
                xml.append_printf("    <area top=\"%s\" left=\"%s\" width=\"%s\" height=\"%s\" />\n",
                    num(input.area.y), num(input.area.x), num(input.area.width), num(input.area.height));
            }
            foreach (string button in STYLUS_BUTTONS) {
                string? value = input.stylus.lookup(button);
                string? target = value != null ? mouse_button(value) : null;
                if (target != null)
                    xml.append_printf("    <map button=\"%s\" to=\"%s\" />\n", button, target);
            }
            foreach (string button in PAD_BUTTONS) {
                string? value = input.pad.lookup(button);
                if (value == null || value == "" || value == "default") continue;
                string? target = mouse_button(value);
                if (value == "none") {
                    xml.append_printf("    <padbind button=\"%s\" />\n", button);
                } else if (target != null) {
                    xml.append_printf("    <padbind button=\"%s\" to=\"%s\" />\n", button, target);
                } else if (value.has_prefix("action:") || value.has_prefix("key:")) {
                    string action = value.has_prefix("action:") ? value.substring(7) : "tablet-" + value;
                    xml.append_printf("    <padbind button=\"%s\"><action name=\"Execute\"><command>%s %s</command></action></padbind>\n",
                        button, escape(input.command), escape(action));
                }
            }
            xml.append("  </tablet>\n");
            double[] c = input.curve.length == 4 ? input.curve : new double[] { 0.0, 0.0, 1.0, 1.0 };
            bool linear = PressureCurve.preset_index(c) == PressureCurve.LINEAR;
            xml.append_printf("  <tabletTool motion=\"%s\"", input.mouse_mode ? "relative" : "absolute");
            if (!linear)
                xml.append_printf(" pressureCurve=\"%s,%s,%s,%s\"", num(c[0]), num(c[1]), num(c[2]), num(c[3]));
            xml.append(" />\n");
            return xml.str;
        }
    }
}
