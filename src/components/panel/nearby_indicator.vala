using Gtk;

namespace Singularity {

    public class NearbyIndicator : Gtk.Button {
        private Image device_icon;
        private Image battery_icon;
        private Singularity.Animation.MotionBin bin;
        private ulong changed_id = 0;
        private bool shown = false;

        public NearbyIndicator() {
            Object();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("nearby-indicator");

            var box = new Box(Orientation.HORIZONTAL, 2);
            device_icon = new Image.from_icon_name("phone-symbolic");
            device_icon.pixel_size = 16;
            box.append(device_icon);
            battery_icon = new Image.from_icon_name("battery-good-symbolic");
            battery_icon.pixel_size = 16;
            box.append(battery_icon);
            bin = new Singularity.Animation.MotionBin();
            bin.child = box;
            set_child(bin);

            var client = NearbyClient.get_default();
            clicked.connect(() => {
                var usable = client.usable_devices();
                NearbyClient.open_app(usable.size == 1 ? usable[0].id : null);
            });
            changed_id = client.changed.connect(() => sync(client));
            sync(client);
        }

        public override void dispose() {
            if (changed_id != 0) {
                NearbyClient.get_default().disconnect(changed_id);
                changed_id = 0;
            }
            base.dispose();
        }

        private void sync(NearbyClient client) {
            var usable = client.usable_devices();
            bool show = usable.size > 0;
            if (show) {
                var d = usable[0];
                device_icon.icon_name = d.icon_name;
                battery_icon.visible = d.battery >= 0;
                battery_icon.icon_name = d.battery_icon();
                string label = usable.size == 1 ? d.status_text() : ngettext("%d device connected", "%d devices connected", usable.size).printf(usable.size);
                tooltip_text = usable.size == 1 ? "%s, %s".printf(d.name, label) : label;
                update_property(Gtk.AccessibleProperty.LABEL, tooltip_text, -1);
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
