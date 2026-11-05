using Gtk;

namespace Singularity {

    public class AgentRemoteIndicator : Gtk.Button {
        private const string NAME = "dev.sinty.Agent";
        private const string PATH = "/dev/sinty/Agent";
        private const string IFACE = "dev.sinty.Agent1";

        private Label device_label;
        private DBusConnection? bus = null;
        private uint subscription = 0;

        public AgentRemoteIndicator() {
            Object();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("agent-remote-indicator");

            var box = new Box(Orientation.HORIZONTAL, 6);
            var icon = new Image.from_icon_name("phone-symbolic");
            icon.pixel_size = 16;
            box.append(icon);
            device_label = new Label("");
            device_label.ellipsize = Pango.EllipsizeMode.END;
            device_label.max_width_chars = 18;
            box.append(device_label);
            set_child(box);

            clicked.connect(() => {
                if (bus != null) bus.call.begin(NAME, PATH, IFACE, "Stop", null, null, DBusCallFlags.NO_AUTO_START, -1, null);
            });
            if (!AgentConfig.available()) return;
            try {
                bus = Bus.get_sync(BusType.SESSION);
                subscription = bus.signal_subscribe(NAME, IFACE, "RemoteChanged", PATH, null, DBusSignalFlags.NONE,
                    (conn, sender, object_path, iface, name, parameters) => {
                        string device;
                        parameters.get("(s)", out device);
                        show_device(device);
                    });
                sync.begin();
            } catch (Error e) {
                warning("Cannot watch remote AI sessions: %s", e.message);
            }
        }

        public override void dispose() {
            if (subscription != 0 && bus != null) {
                bus.signal_unsubscribe(subscription);
                subscription = 0;
            }
            base.dispose();
        }

        private async void sync() {
            try {
                var reply = yield bus.call(NAME, PATH, IFACE, "GetStatus", null, new VariantType("(s)"), DBusCallFlags.NO_AUTO_START, 5000, null);
                string text;
                reply.get("(s)", out text);
                var parser = new Json.Parser();
                parser.load_from_data(text);
                show_device(parser.get_root().get_object().get_string_member_with_default("remote", ""));
            } catch (Error e) {
                show_device("");
            }
        }

        private void show_device(string device) {
            visible = device != "";
            device_label.label = device;
            string text = _("Sinty AI is controlled by %s. Click to stop it.").printf(device);
            tooltip_text = text;
            update_property(Gtk.AccessibleProperty.LABEL, text, -1);
        }
    }
}
