namespace Singularity.Tablet {

    public class TabletManager : Object {
        private static TabletManager? instance = null;

        public signal void changed();

        public State state { get; private set; default = new State(); }
        public string state_path { get; private set; default = ""; }

        private GLib.Settings settings;
        private FileMonitor? monitor = null;
        private uint reload_id = 0;
        private string last_data = "";
        private bool state_loaded = false;

        public static TabletManager get_default() {
            if (instance == null) instance = new TabletManager();
            return instance;
        }

        private TabletManager() {
            settings = new GLib.Settings("dev.sinty.desktop");
            string? display = Environment.get_variable("WAYLAND_DISPLAY");
            if (display == null || display == "" || display.contains("/")) display = "wayland-0";
            state_path = Path.build_filename(Environment.get_user_runtime_dir(), "labwc",
                "tablets-%s.ini".printf(display));
            try {
                monitor = File.new_for_path(state_path).monitor_file(FileMonitorFlags.WATCH_MOVES);
                monitor.changed.connect(() => queue_reload());
            } catch (Error e) {
                warning("tablet: cannot watch %s: %s", state_path, e.message);
            }
            reload();
            Idle.add(() => {
                DisplayManager.get_default().monitors_changed.connect(() => {
                    if (connected && settings.get_boolean("tablet-keep-aspect")) changed();
                });
                return Source.REMOVE;
            });
        }

        private void queue_reload() {
            if (reload_id != 0) return;
            reload_id = Timeout.add(150, () => {
                reload_id = 0;
                reload();
                return Source.REMOVE;
            });
        }

        public void reload() {
            string data = "";
            try {
                FileUtils.get_contents(state_path, out data);
            } catch (Error e) {
                data = "";
            }
            if (data == last_data && state_loaded) return;
            last_data = data;
            state_loaded = true;
            state = State.parse(data);
            changed();
        }

        public bool connected {
            get { return state.devices.size > 0; }
        }

        public void screen_size(out double width, out double height) {
            width = 0;
            height = 0;
            string output = settings.get_string("tablet-output");
            int min_x = int.MAX, min_y = int.MAX, max_x = int.MIN, max_y = int.MIN;
            foreach (var m in DisplayManager.get_default().get_monitors()) {
                if (!m.enabled || m.current_mode == null) continue;
                if (output != "" && m.name != output) continue;
                double scale = m.scale > 0 ? m.scale : 1.0;
                int w = (int) Math.round(m.current_mode.width / scale);
                int h = (int) Math.round(m.current_mode.height / scale);
                if (m.transform % 2 == 1) {
                    int swap = w;
                    w = h;
                    h = swap;
                }
                min_x = int.min(min_x, m.x);
                min_y = int.min(min_y, m.y);
                max_x = int.max(max_x, m.x + w);
                max_y = int.max(max_y, m.y + h);
            }
            if (min_x == int.MAX) return;
            width = max_x - min_x;
            height = max_y - min_y;
        }

        public Area? active_area() {
            var dev = state.primary;
            if (dev == null || dev.width_mm <= 0 || dev.height_mm <= 0) return null;
            bool custom = settings.get_boolean("tablet-area-custom");
            bool keep = settings.get_boolean("tablet-keep-aspect");
            if (!custom && !keep) return null;
            double x, y, w, h;
            settings.get("tablet-area", "(dddd)", out x, out y, out w, out h);
            double sw, sh;
            screen_size(out sw, out sh);
            return Geometry.active_area(dev.width_mm, dev.height_mm, custom, Area(x, y, w, h), keep, sw, sh);
        }

        public static HashTable<string, string> read_map(GLib.Settings settings, string key) {
            var table = new HashTable<string, string>(str_hash, str_equal);
            var iter = settings.get_value(key).iterator();
            string k, v;
            while (iter.next("{ss}", out k, out v)) table[k] = v;
            return table;
        }

        public static void write_map(GLib.Settings settings, string key, string button, string value) {
            var builder = new VariantBuilder(new VariantType("a{ss}"));
            var table = read_map(settings, key);
            table[button] = value;
            table.foreach((k, v) => {
                if (v != "default") builder.add("{ss}", k, v);
            });
            settings.set_value(key, builder.end());
        }

        public double[] curve() {
            double a, b, c, d;
            settings.get("tablet-pressure-curve", "(dddd)", out a, out b, out c, out d);
            return { a, b, c, d };
        }

        public string rc_xml(string command) {
            var input = new RcInput();
            input.output = settings.get_string("tablet-output");
            input.area = active_area();
            input.left_handed = settings.get_boolean("tablet-left-handed");
            input.curve = curve();
            input.mouse_mode = settings.get_boolean("tablet-mouse-mode");
            input.stylus = read_map(settings, "tablet-stylus-buttons");
            input.pad = read_map(settings, "tablet-pad-buttons");
            input.command = command;
            return Rc.build(input);
        }

        public static void send_shortcut(string text) {
            uint modifiers;
            string key;
            if (!Shortcut.parse(text, out modifiers, out key)) {
                warning("tablet: invalid shortcut %s", text);
                return;
            }
            uint keysym = Gdk.keyval_from_name(key);
            if (keysym == Gdk.Key.VoidSymbol || keysym == 0) keysym = Gdk.keyval_from_name(key.down());
            if (keysym == Gdk.Key.VoidSymbol || keysym == 0) {
                warning("tablet: unknown key %s", key);
                return;
            }
            var settings = new GLib.Settings("dev.sinty.desktop");
            Singularity.osk_set_layout(settings.get_string("xkb-layout"), settings.get_string("xkb-variant"));
            if (!Singularity.osk_press_keysym(keysym, modifiers))
                warning("tablet: no key for %s in the current layout", key);
        }
    }
}
