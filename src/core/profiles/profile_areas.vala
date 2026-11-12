using GLib;
using Singularity.Profiles;

namespace Singularity {

    public class ProfileAreas : Object {
        private static ProfileAreas? _instance = null;

        private Gee.ArrayList<Area> _areas = new Gee.ArrayList<Area>();
        private DBusConnection? _conn = null;
        private GLib.Settings _desktop;
        private DBusProxy? _key = null;
        private GUdev.Client? _udev = null;
        private string[] _devices = {};
        private string _agent_mode = "";
        private string _default_printer = "";
        private string[] _printers = {};
        private uint32 _awake_cookie = 0;
        private ProfileApps _apps;

        public Area state_area { get; private set; }

        public static ProfileAreas get_default() {
            if (_instance == null) _instance = new ProfileAreas();
            return _instance;
        }

        private ProfileAreas() {
            _desktop = new GLib.Settings("dev.sinty.desktop");
            _apps = new ProfileApps();
        }

        public void start() {
            build_state();
            build_notifications();
            _areas.add(_apps.build());
            build_appearance();
            build_display();
            build_energy();
            build_audio();
            build_bluetooth();
            build_vpn();
            build_printer();
            build_system();
            build_dock();
            build_launcher();
            build_widgets();
            build_agent();
            Bus.get.begin(BusType.SESSION, null, (o, res) => {
                try {
                    _conn = Bus.get.end(res);
                } catch (IOError e) {
                    warning("profiles: no session bus: %s", e.message);
                    return;
                }
                foreach (var a in _areas) a.export(_conn);
                Bus.watch_name(BusType.SESSION, SERVICE_NAME, BusNameWatcherFlags.AUTO_START,
                    () => register_all.begin(), null);
            });
        }

        private async void register_all() {
            try {
                var proxy = yield Bus.get_proxy<ServiceProxy>(BusType.SESSION, SERVICE_NAME, SERVICE_PATH);
                foreach (var a in _areas) {
                    try {
                        yield proxy.register_area(a.info.id, new ObjectPath(a.object_path));
                    } catch (Error e) {
                        warning("profiles: could not register %s: %s", a.info.id, e.message);
                    }
                }
            } catch (Error e) {
                warning("profiles: service unreachable: %s", e.message);
            }
        }

        private Area area(string id, string icon) {
            var a = new Area(id, area_label(id), icon);
            _areas.add(a);
            return a;
        }

        private static Option ro(Option o) {
            o.read_only = true;
            return o;
        }

        private static string list_json(string[] items) {
            var b = new Json.Builder();
            b.begin_array();
            foreach (string s in items) b.add_string_value(s);
            b.end_array();
            return to_text(b.get_root(), false);
        }

        private static string? text_of(string json) {
            var n = parse_value(json);
            return n.get_value_type() == typeof(string) ? n.get_string() : null;
        }

        private static bool bool_of(string json) {
            var n = parse_value(json);
            return n.get_value_type() == typeof(bool) && n.get_boolean();
        }

        private static double number_of(string json, double fallback) {
            var n = parse_value(json);
            if (n.get_value_type() == typeof(int64)) return (double) n.get_int();
            if (n.get_value_type() == typeof(double)) return n.get_double();
            return fallback;
        }

        private void build_state() {
            var a = area(Areas.STATE, "preferences-system-symbolic");
            string[] keys = { "wifi", "known-wifi", "screens", "devices", "fullscreen", "game", "presenting", "key", "key-owner", "on-battery", "battery" };
            foreach (string k in keys) a.add(ro(new Option(k, k, OptionKind.STRUCTURED)));
            var net = SystemMonitor.get_default().network;
            var power = SystemMonitor.get_default().power;
            a.handlers((key) => {
                switch (key) {
                    case "wifi": return string_value(net.active_wifi_ssid() ?? "");
                    case "known-wifi":
                        string[] names = {};
                        var saved = net.saved_wifi_connections();
                        for (uint i = 0; i < saved.length; i++) names += saved[i].get_id();
                        return list_json(names);
                    case "screens": return list_json(screen_names());
                    case "devices": return list_json(_devices);
                    case "fullscreen": return bool_value(AppSystem.get_default().has_any_fullscreen_window());
                    case "game": return bool_value(GameModeManager.get_default().active);
                    case "presenting": return bool_value(FocusManager.get_default().presenting);
                    case "key": return bool_value(key_owner() != null);
                    case "key-owner": return string_value(key_owner() ?? "");
                    case "on-battery": return bool_value(power.is_present && !power.is_charging && !on_ac());
                    case "battery": return int_value((int64) Math.round(power.percentage));
                }
                return null;
            }, (key, json) => {});
            state_area = a;

            net.state_changed.connect(() => a.notify_changed({ "wifi" }));
            net.wifi_connections_changed.connect(() => a.notify_changed({ "known-wifi" }));
            power.state_changed.connect(() => a.notify_changed({ "on-battery", "battery" }));
            AppSystem.get_default().any_fullscreen_changed.connect(() => a.notify_changed({ "fullscreen" }));
            GameModeManager.get_default().state_changed.connect(() => a.notify_changed({ "game" }));
            FocusManager.get_default().changed.connect(() => a.notify_changed({ "presenting" }));
            var monitors = Gdk.Display.get_default().get_monitors();
            monitors.items_changed.connect(() => a.notify_changed({ "screens" }));

            _udev = new GUdev.Client({ "usb", "thunderbolt" });
            _udev.uevent.connect((action, dev) => {
                if (action == "add" || action == "remove") {
                    scan_devices();
                    a.notify_changed({ "devices" });
                }
            });
            scan_devices();

            connect_key.begin(a);
        }

        private async void connect_key(Area a) {
            try {
                _key = yield new DBusProxy.for_bus(BusType.SYSTEM, DBusProxyFlags.DO_NOT_AUTO_START, null,
                    "dev.sinty.Key1", "/dev/sinty/Key1", "dev.sinty.Key1");
                _key.g_properties_changed.connect(() => a.notify_changed({ "key", "key-owner" }));
                _key.notify["g-name-owner"].connect(() => a.notify_changed({ "key", "key-owner" }));
                a.notify_changed({ "key", "key-owner" });
            } catch (Error e) {
                debug("profiles: no Sinty Key service: %s", e.message);
            }
        }

        private static bool on_ac() {
            try {
                var dir = Dir.open("/sys/class/power_supply");
                string? name;
                while ((name = dir.read_name()) != null) {
                    string type;
                    string online;
                    string base_path = Path.build_filename("/sys/class/power_supply", name);
                    if (!FileUtils.get_contents(Path.build_filename(base_path, "type"), out type)) continue;
                    if (type.strip() != "Mains" && type.strip() != "USB") continue;
                    if (FileUtils.get_contents(Path.build_filename(base_path, "online"), out online) && online.strip() == "1") return true;
                }
            } catch (Error e) {
            }
            return false;
        }

        private string[] screen_names() {
            string[] names = {};
            var monitors = Gdk.Display.get_default().get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var m = (Gdk.Monitor) monitors.get_item(i);
                string label = string.joinv(" ", { m.connector ?? "", m.manufacturer ?? "", m.model ?? "" }).strip();
                if (label != "") names += label;
            }
            return names;
        }

        private void scan_devices() {
            string[] found = {};
            foreach (var dev in _udev.query_by_subsystem("usb")) {
                if (dev.get_devtype() != "usb_device") continue;
                string? product = dev.get_sysfs_attr("product") ?? dev.get_property("ID_MODEL_FROM_DATABASE");
                string? maker = dev.get_sysfs_attr("manufacturer") ?? dev.get_property("ID_VENDOR_FROM_DATABASE");
                if (product == null) continue;
                if (dev.get_sysfs_attr("bDeviceClass") == "09") continue;
                found += string.joinv(" ", { maker ?? "", product }).strip();
            }
            foreach (var dev in _udev.query_by_subsystem("thunderbolt")) {
                string? name = dev.get_sysfs_attr("device_name");
                if (name == null) continue;
                found += string.joinv(" ", { dev.get_sysfs_attr("vendor_name") ?? "", name }).strip();
            }
            _devices = found;
        }

        private string? key_owner() {
            if (_key == null || _key.g_name_owner == null) return null;
            var value = _key.get_cached_property("Present");
            if (value == null) return null;
            string me = Environment.get_user_name();
            string? first = null;
            var iter = value.iterator();
            string device, id, owner, state;
            while (iter.next("(ssss)", out device, out id, out owner, out state)) {
                if (owner == me) return owner;
                if (first == null) first = owner;
            }
            return first;
        }

        private void build_notifications() {
            var a = area(Areas.NOTIFICATIONS, "preferences-system-notifications-symbolic");
            a.add(new Option("rules", _("Who Can Reach You"), OptionKind.STRUCTURED));
            var focus = FocusManager.get_default();
            a.handlers((key) => key == "rules" ? focus.profile_rules_json() : null,
                (key, json) => {
                    if (key == "rules") focus.apply_profile_rules(json);
                });
            focus.changed.connect(() => a.notify_changed({ "rules" }));
        }

        private void build_appearance() {
            var a = area(Areas.APPEARANCE, "preferences-desktop-appearance-symbolic");
            a.bind_setting(_desktop, "dark-mode", new Option("dark-mode", _("Dark Style"), OptionKind.BOOLEAN));
            var accent = new Option("accent", _("Accent Colour"), OptionKind.CHOICE);
            string[,] accents = {
                { "blue", _("Blue") }, { "teal", _("Teal") }, { "green", _("Green") }, { "yellow", _("Yellow") },
                { "orange", _("Orange") }, { "red", _("Red") }, { "pink", _("Pink") }, { "purple", _("Purple") },
                { "slate", _("Slate") }, { "wallpaper", _("From the Wallpaper") }
            };
            for (int i = 0; i < accents.length[0]; i++) accent.add_choice(accents[i, 0], accents[i, 1]);
            a.bind_setting(_desktop, "accent-color", accent);
            a.bind_setting(_desktop, "background-picture-uri", new Option("wallpaper", _("Wallpaper"), OptionKind.TEXT));
            var effect = new Option("background-effect", _("Liquid Glass"), OptionKind.CHOICE);
            effect.add_choice("disabled", _("Off")).add_choice("glass", _("Glass")).add_choice("liquid", _("Liquid Glass")).add_choice("blur", _("Blur"));
            a.bind_setting(_desktop, "background-effect", effect);
            a.bind_setting(_desktop, "night-light-enabled", new Option("night-light", _("Night Light"), OptionKind.BOOLEAN));
            a.bind_setting(_desktop, "large-text", new Option("large-text", _("Large Text"), OptionKind.BOOLEAN));
            var src = SettingsSchemaSource.get_default();
            var iface = src != null ? src.lookup("org.gnome.desktop.interface", true) : null;
            if (iface != null && iface.has_key("text-scaling-factor")) {
                a.bind_setting(new GLib.Settings("org.gnome.desktop.interface"), "text-scaling-factor",
                    new Option("text-size", _("Text Size"), OptionKind.NUMBER).with_range(0.8, 2.0));
            }
        }

        private void build_display() {
            var a = area(Areas.DISPLAY, "display-brightness-symbolic");
            a.add(new Option("brightness", _("Brightness"), OptionKind.INTEGER).with_range(0, 100));
            var brightness = BrightnessManager.get_default();
            a.handlers((key) => key == "brightness" ? int_value((int64) Math.round(brightness.brightness)) : null,
                (key, json) => {
                    if (key == "brightness") brightness.set_level(number_of(json, brightness.brightness).clamp(1, 100));
                });
            brightness.changed.connect(() => a.notify_changed({ "brightness" }));
        }

        private void build_energy() {
            var a = area(Areas.ENERGY, "power-profile-balanced-symbolic");
            var mode = new Option("mode", _("Energy Mode"), OptionKind.CHOICE);
            mode.add_choice("power-saver", _("Power Saver")).add_choice("balanced", _("Balanced")).add_choice("performance", _("Performance"));
            a.add(mode);
            var pp = PowerProfilesManager.get_default();
            a.handlers((key) => key == "mode" ? string_value(pp.active_profile) : null,
                (key, json) => {
                    string? v = text_of(json);
                    if (key == "mode" && v != null) pp.set_profile(v);
                });
            pp.profile_changed.connect(() => a.notify_changed({ "mode" }));
        }

        private void build_audio() {
            var a = area(Areas.AUDIO, "audio-volume-high-symbolic");
            var audio = AudioManager.get_default();
            var output = new Option("output", _("Sound Output"), OptionKind.CHOICE);
            var input = new Option("input", _("Microphone"), OptionKind.CHOICE);
            a.add(output);
            a.add(new Option("volume", _("Volume"), OptionKind.INTEGER).with_range(0, 100));
            a.add(new Option("muted", _("Mute Sound"), OptionKind.BOOLEAN));
            a.add(input);
            a.add(new Option("microphone-muted", _("Mute Microphone"), OptionKind.BOOLEAN));
            a.add(new Option("microphone-volume", _("Microphone Volume"), OptionKind.INTEGER).with_range(0, 100));
            AudioDeviceChoices.fill(audio, output, input);
            audio.devices_changed.connect(() => {
                AudioDeviceChoices.fill(audio, output, input);
                a.notify_changed({ "output", "input" });
            });
            a.handlers((key) => {
                switch (key) {
                    case "output": return string_value(AudioDeviceChoices.default_name(audio.sinks));
                    case "input": return string_value(AudioDeviceChoices.default_name(audio.sources));
                    case "volume": return int_value((int64) Math.round(audio.volume));
                    case "muted": return bool_value(audio.is_muted);
                    case "microphone-muted": return bool_value(audio.input_muted);
                    case "microphone-volume": return int_value((int64) Math.round(audio.input_volume));
                }
                return null;
            }, (key, json) => {
                switch (key) {
                    case "output":
                        string? v = text_of(json);
                        if (v != null && v != "") audio.set_default_sink(v);
                        break;
                    case "input":
                        string? v = text_of(json);
                        if (v != null && v != "") audio.set_default_source(v);
                        break;
                    case "volume": audio.update_volume(number_of(json, audio.volume).clamp(0, 100)); break;
                    case "muted": if (bool_of(json) != audio.is_muted) audio.toggle_mute(); break;
                    case "microphone-muted": if (bool_of(json) != audio.input_muted) audio.toggle_input_mute(); break;
                    case "microphone-volume": audio.update_input_volume(number_of(json, audio.input_volume).clamp(0, 100)); break;
                }
            });
            audio.state_changed.connect(() => a.notify_changed({ "volume", "muted", "microphone-muted", "microphone-volume", "output", "input" }));
        }

        private void build_bluetooth() {
            var a = area(Areas.BLUETOOTH, "bluetooth-active-symbolic");
            a.add(new Option("enabled", _("Bluetooth"), OptionKind.BOOLEAN));
            var bt = SystemMonitor.get_default().bluetooth;
            a.handlers((key) => key == "enabled" ? bool_value(bt.is_powered) : null,
                (key, json) => {
                    if (key == "enabled" && bt.is_available) bt.set_power.begin(bool_of(json));
                });
            bt.state_changed.connect(() => a.notify_changed({ "enabled" }));
        }

        private void build_vpn() {
            var a = area(Areas.VPN, "network-vpn-symbolic");
            var net = SystemMonitor.get_default().network;
            var opt = new Option("connection", _("VPN"), OptionKind.CHOICE);
            a.add(opt);
            fill_vpn_choices(net, opt);
            net.vpn_connections_changed.connect(() => fill_vpn_choices(net, opt));
            a.handlers((key) => key == "connection" ? string_value(net.vpn_active ? net.vpn_name : "") : null,
                (key, json) => {
                    if (key != "connection") return;
                    string want = text_of(json) ?? "";
                    var list = net.get_vpn_connections();
                    for (uint i = 0; i < list.length; i++) {
                        var c = list[i];
                        bool on = net.vpn_link_state(c) != NetworkManagerWrapper.VpnLinkState.DISCONNECTED;
                        if (c.get_id() == want && !on) net.activate_vpn.begin(c);
                        else if (c.get_id() != want && on) net.deactivate_connection.begin(c);
                    }
                });
            net.vpn_state_changed.connect(() => a.notify_changed({ "connection" }));
        }

        private static void fill_vpn_choices(NetworkManagerWrapper net, Option opt) {
            opt.choices.clear();
            opt.add_choice("", _("Off"));
            var list = net.get_vpn_connections();
            for (uint i = 0; i < list.length; i++) opt.add_choice(list[i].get_id(), list[i].get_id());
        }

        private void build_printer() {
            var a = area(Areas.PRINTER, "printer-symbolic");
            var opt = new Option("default", _("Default Printer"), OptionKind.CHOICE);
            a.add(opt);
            a.handlers((key) => key == "default" ? string_value(_default_printer) : null,
                (key, json) => {
                    string? v = text_of(json);
                    if (key != "default" || v == null || v == "" || v == _default_printer) return;
                    _default_printer = v;
                    var backend = Singularity.Print.PrinterBackend.get_default();
                    backend.set_default.begin(v, (o, res) => {
                        try {
                            backend.set_default.end(res);
                        } catch (Error e) {
                            warning("profiles: default printer not changed: %s", e.message);
                        }
                        refresh_printers.begin(a, opt);
                    });
                });
            refresh_printers.begin(a, opt);
        }

        private async void refresh_printers(Area a, Option opt) {
            var backend = Singularity.Print.PrinterBackend.get_default();
            try {
                var list = yield backend.list_printers();
                opt.choices.clear();
                string[] names = {};
                foreach (var p in list) {
                    opt.add_choice(p.name, p.display_name);
                    names += p.name;
                }
                _printers = names;
            } catch (Error e) {
                debug("profiles: printers unavailable: %s", e.message);
            }
            _default_printer = (yield backend.default_printer()) ?? "";
            a.notify_changed({ "default" });
        }

        private void build_system() {
            var a = area(Areas.SYSTEM, "preferences-system-symbolic");
            a.add(new Option("keep-awake", _("Keep the Screen On"), OptionKind.BOOLEAN)
                .with_subtitle(_("The screen does not dim, lock or sleep")));
            a.handlers((key) => key == "keep-awake" ? bool_value(_awake_cookie != 0) : null,
                (key, json) => {
                    if (key != "keep-awake") return;
                    bool on = bool_of(json);
                    var inhibitors = IdleInhibitors.get_default();
                    if (on && _awake_cookie == 0) {
                        _awake_cookie = inhibitors.add("singularity-profiles", "dev.sinty.settings", _("A profile keeps the screen on"),
                            IdleInhibitors.IDLE | IdleInhibitors.SUSPEND);
                    } else if (!on && _awake_cookie != 0) {
                        inhibitors.remove(_awake_cookie, "singularity-profiles");
                        _awake_cookie = 0;
                    }
                    a.notify_changed({ "keep-awake" });
                });
        }

        private void build_dock() {
            var a = area(Areas.DOCK, "user-bookmarks-symbolic");
            a.bind_setting(_desktop, "dock-enabled", new Option("enabled", _("Show the Dock"), OptionKind.BOOLEAN));
            var pos = new Option("position", _("Position"), OptionKind.CHOICE);
            pos.add_choice("bottom", _("Bottom")).add_choice("left", _("Left")).add_choice("right", _("Right"));
            a.bind_setting(_desktop, "dock-position", pos);
            a.bind_setting(_desktop, "dock-autohide", new Option("autohide", _("Hide Automatically"), OptionKind.BOOLEAN));
            a.bind_setting(_desktop, "dock-icon-size", new Option("icon-size", _("Icon Size"), OptionKind.INTEGER).with_range(24, 96));
            a.bind_setting(_desktop, "dock-magnification", new Option("magnification", _("Magnification"), OptionKind.BOOLEAN));
            a.bind_setting(_desktop, "pinned-apps", new Option("pinned", _("Pinned Apps"), OptionKind.STRUCTURED));
        }

        private void build_launcher() {
            var a = area(Areas.LAUNCHER, "view-app-grid-symbolic");
            var mode = new Option("mode", _("Launcher Style"), OptionKind.CHOICE);
            mode.add_choice("fullscreen", _("Full Screen")).add_choice("menu", _("Menu"));
            a.bind_setting(_desktop, "app-launcher-mode", mode);
        }

        private void build_widgets() {
            var a = area(Areas.WIDGETS, "view-grid-symbolic");
            a.bind_setting(_desktop, "overview-widgets", new Option("layout", _("Widgets"), OptionKind.STRUCTURED));
        }

        private void build_agent() {
            var a = area(Areas.AGENT, "dialog-question-symbolic");
            var mode = new Option("mode", _("What Sinty AI Can Do Alone"), OptionKind.CHOICE);
            mode.add_choice("plan", _("Plan"))
                .add_choice("ask", _("Ask First"))
                .add_choice("auto", _("Automatic"))
                .add_choice("autopilot", _("Autopilot"));
            a.add(mode);
            a.handlers((key) => {
                if (key != "mode") return null;
                refresh_agent.begin(a);
                return _agent_mode != "" ? string_value(_agent_mode) : null;
            }, (key, json) => {
                string? v = text_of(json);
                if (key != "mode" || v == null || _conn == null) return;
                _conn.call.begin("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1", "SetMode",
                    new Variant("(s)", v), null, DBusCallFlags.NO_AUTO_START, 3000, null, (o, res) => {
                        try {
                            _conn.call.end(res);
                            _agent_mode = v;
                        } catch (Error e) {
                            warning("profiles: agent mode not changed: %s", e.message);
                        }
                    });
            });
            refresh_agent.begin(a);
        }

        private async void refresh_agent(Area a) {
            if (_conn == null) {
                try {
                    _conn = yield Bus.get(BusType.SESSION);
                } catch (IOError e) {
                    return;
                }
            }
            try {
                var reply = yield _conn.call("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1", "GetStatus",
                    null, new VariantType("(s)"), DBusCallFlags.NO_AUTO_START, 2000, null);
                string status;
                reply.get("(s)", out status);
                var parser = new Json.Parser();
                parser.load_from_data(status);
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.OBJECT && root.get_object().has_member("mode")) {
                    string m = root.get_object().get_string_member("mode");
                    if (m != _agent_mode) {
                        _agent_mode = m;
                        a.notify_changed({ "mode" });
                    }
                }
            } catch (Error e) {
                _agent_mode = "";
            }
        }
    }

    public class AudioDeviceChoices : Object {
        public static void fill(AudioManager audio, Option output, Option input) {
            output.choices.clear();
            input.choices.clear();
            unowned List<AudioManager.AudioDevice?> l = audio.sinks;
            while (l != null) {
                if (l.data != null) output.add_choice(l.data.name, l.data.friendly_name ?? l.data.description);
                l = l.next;
            }
            l = audio.sources;
            while (l != null) {
                if (l.data != null && !l.data.name.has_suffix(".monitor")) input.add_choice(l.data.name, l.data.friendly_name ?? l.data.description);
                l = l.next;
            }
        }

        public static string default_name(List<AudioManager.AudioDevice?> devices) {
            unowned List<AudioManager.AudioDevice?> l = devices;
            while (l != null) {
                if (l.data != null && l.data.is_default) return l.data.name;
                l = l.next;
            }
            return "";
        }
    }
}
