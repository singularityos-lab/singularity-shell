using Gtk;

namespace Singularity {

    public class DeviceChargingIndicator : Gtk.Button {
        private const string USB_DEVICES = "/sys/bus/usb/devices";
        private const string TYPEC = "/sys/class/typec";
        private const string[] PHONE_VENDORS = {
            "18d1", "04e8", "22b8", "2717", "12d1", "2a70", "0fce", "1004",
            "2d95", "22d9", "0bb4", "2ae5", "1ebf", "29a9", "05c6", "19d2"
        };
        private const string[] ORDER = { "phone", "tablet", "watch", "headphones", "device" };

        private class Charging {
            public string kind;
            public string name;
            public double percent;

            public Charging(string kind, string name, double percent = -1) {
                this.kind = kind;
                this.name = name;
                this.percent = percent;
            }
        }

        private Image icon;
        private Singularity.Animation.MotionBin bin;
        private GUdev.Client udev;
        private UPower.Client? upower = null;
        private Gee.ArrayList<UPower.Device> watched = new Gee.ArrayList<UPower.Device>();
        private uint pending = 0;
        private bool shown = false;

        public DeviceChargingIndicator() {
            Object();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("device-charging-indicator");
            icon = new Image.from_icon_name("device-charging-symbolic");
            icon.pixel_size = 16;
            bin = new Singularity.Animation.MotionBin();
            bin.child = icon;
            set_child(bin);
            clicked.connect(() => {
                var app = GLib.Application.get_default() as SingularityApp;
                if (app != null) app.open_settings_page("power");
            });

            udev = new GUdev.Client({ "usb", "typec", "power_supply" });
            udev.uevent.connect(on_uevent);
            try {
                upower = UPower.Client.new_full(null);
                upower.device_added.connect(on_device_added);
                upower.device_removed.connect(on_device_removed);
                var devices = upower.get_devices();
                for (uint i = 0; i < devices.length; i++) watch((UPower.Device) devices.get(i));
            } catch (Error e) {
                upower = null;
            }
            sync();
        }

        public override void dispose() {
            if (pending != 0) {
                Source.remove(pending);
                pending = 0;
            }
            if (udev != null) udev.uevent.disconnect(on_uevent);
            foreach (var d in watched) d.notify.disconnect(on_device_notify);
            watched.clear();
            if (upower != null) {
                upower.device_added.disconnect(on_device_added);
                upower.device_removed.disconnect(on_device_removed);
                upower = null;
            }
            base.dispose();
        }

        private void on_uevent(string action, GUdev.Device device) {
            queue_sync();
        }

        private void on_device_added(UPower.Device device) {
            watch(device);
            queue_sync();
        }

        private void on_device_removed(UPower.Device device) {
            device.notify.disconnect(on_device_notify);
            watched.remove(device);
            queue_sync();
        }

        private void on_device_notify(Object o, ParamSpec p) {
            queue_sync();
        }

        private void watch(UPower.Device device) {
            if (watched.contains(device)) return;
            watched.add(device);
            device.notify.connect(on_device_notify);
        }

        private void queue_sync() {
            if (pending != 0) return;
            pending = Timeout.add(400, () => {
                pending = 0;
                sync();
                return Source.REMOVE;
            });
        }

        private static string? read(string path) {
            try {
                string text;
                FileUtils.get_contents(path, out text);
                return text.strip();
            } catch (Error e) {
                return null;
            }
        }

        private static bool typec_sourcing() {
            Dir dir;
            try {
                dir = Dir.open(TYPEC);
            } catch (Error e) {
                return false;
            }
            string? name;
            while ((name = dir.read_name()) != null) {
                if (name.contains("-")) continue;
                var role = read(Path.build_filename(TYPEC, name, "power_role"));
                if (role != null && role.contains("[source]") &&
                    FileUtils.test(Path.build_filename(TYPEC, name + "-partner"), FileTest.EXISTS)) return true;
            }
            return false;
        }

        private static string? usb_kind(string dev, string product) {
            var vendor = read(Path.build_filename(dev, "idVendor")) ?? "";
            if (vendor == "05ac") {
                if (product.has_prefix("iPad")) return "tablet";
                if (product.has_prefix("iPhone")) return "phone";
                if (product.contains("Watch")) return "watch";
                return null;
            }
            Dir dir;
            try {
                dir = Dir.open(dev);
            } catch (Error e) {
                return null;
            }
            string prefix = Path.get_basename(dev) + ":";
            bool phone_interface = false;
            bool other_function = false;
            string? entry;
            while ((entry = dir.read_name()) != null) {
                if (!entry.has_prefix(prefix)) continue;
                var path = Path.build_filename(dev, entry);
                var cls = read(Path.build_filename(path, "bInterfaceClass")) ?? "";
                var sub = read(Path.build_filename(path, "bInterfaceSubClass")) ?? "";
                var proto = read(Path.build_filename(path, "bInterfaceProtocol")) ?? "";
                var label = read(Path.build_filename(path, "interface")) ?? "";
                if (label == "MTP" || (cls == "ff" && sub == "42" && proto == "01")) phone_interface = true;
                else if (cls == "08" || cls == "09" || cls == "03" || cls == "0e" || cls == "01") other_function = true;
            }
            if (phone_interface) return "phone";
            if (!other_function && vendor in PHONE_VENDORS) return "phone";
            return null;
        }

        private Gee.ArrayList<Charging> scan() {
            var found = new Gee.ArrayList<Charging>();
            bool apple_reported = false;
            foreach (var d in watched) {
                if (d.state != UPower.DeviceState.CHARGING) continue;
                string? path = null;
                string? model = null;
                d.get("native-path", out path, "model", out model);
                if (path == null) path = "";
                if (path.contains("bluez")) continue;
                string? kind = null;
                switch (d.kind) {
                    case UPower.DeviceKind.PHONE:
                        kind = "phone";
                        break;
                    case UPower.DeviceKind.TABLET:
                        kind = "tablet";
                        break;
                    case UPower.DeviceKind.HEADPHONES:
                    case UPower.DeviceKind.HEADSET:
                        kind = "headphones";
                        break;
                    case UPower.DeviceKind.MEDIA_PLAYER:
                        kind = "device";
                        break;
                    default:
                        break;
                }
                if (kind == null) continue;
                if (path.has_prefix("idevice")) apple_reported = true;
                found.add(new Charging(kind, model ?? "", d.percentage));
            }
            Dir dir;
            try {
                dir = Dir.open(USB_DEVICES);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.contains(":") || name.has_prefix("usb")) continue;
                    var dev = Path.build_filename(USB_DEVICES, name);
                    var product = read(Path.build_filename(dev, "product")) ?? "";
                    var kind = usb_kind(dev, product);
                    if (kind == null) continue;
                    if (apple_reported && read(Path.build_filename(dev, "idVendor")) == "05ac") continue;
                    found.add(new Charging(kind, product));
                }
            } catch (Error e) {
            }
            if (found.size == 0 && typec_sourcing()) found.add(new Charging("device", ""));
            found.sort((a, b) => rank(a.kind) - rank(b.kind));
            return found;
        }

        private static int rank(string kind) {
            for (int i = 0; i < ORDER.length; i++) if (ORDER[i] == kind) return i;
            return ORDER.length;
        }

        private string icon_for(string kind) {
            string name;
            switch (kind) {
                case "phone": name = "phone-charging-symbolic"; break;
                case "tablet": name = "tablet-charging-symbolic"; break;
                case "watch": name = "watch-charging-symbolic"; break;
                case "headphones": name = "audio-headphones-charging-symbolic"; break;
                default: name = "device-charging-symbolic"; break;
            }
            if (!IconTheme.get_for_display(get_display()).has_icon(name)) return "battery-full-charging-symbolic";
            return name;
        }

        private void sync() {
            var found = scan();
            bool show = found.size > 0;
            if (show) {
                var first = found[0];
                icon.icon_name = icon_for(first.kind);
                string label;
                if (found.size > 1) {
                    label = ngettext("Charging %d device", "Charging %d devices", found.size).printf(found.size);
                } else if (first.name == "") {
                    label = _("Charging a connected device");
                } else if (first.percent >= 0) {
                    label = _("Charging %s, %d%%").printf(first.name, (int) Math.round(first.percent));
                } else {
                    label = _("Charging %s").printf(first.name);
                }
                tooltip_text = label;
                update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            }
            if (show == shown) return;
            shown = show;
            if (show) {
                visible = true;
                Motion.reveal(bin, Motion.Preset.SCALE_FADE);
            } else {
                Motion.conceal(bin, Motion.Preset.SCALE_FADE).done.connect(() => {
                    if (!shown) visible = false;
                });
            }
        }
    }
}
