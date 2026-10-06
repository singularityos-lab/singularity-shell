using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class NearbyBridge : Object {
        private static NearbyBridge? _instance = null;
        private NearbyClient client;
        private QuickTile? tile = null;
        private string last_received = "";
        private bool started = false;

        public static NearbyBridge get_default() {
            if (_instance == null) _instance = new NearbyBridge();
            return _instance;
        }

        private NearbyBridge() {
            client = NearbyClient.get_default();
        }

        public void start() {
            if (started || !client.available) return;
            started = true;
            client.start();
            ClipboardHistory.get_default().text_copied.connect((text) => {
                if (text == last_received) return;
                client.send_clipboard(text);
            });
            client.clipboard_received.connect((text, device) => {
                last_received = text;
                ClipboardHistory.get_default().copy(new ClipboardEntry(0, "text/plain;charset=utf-8", new Bytes(text.data), get_real_time()));
            });
            client.changed.connect(sync_tile);
            install_tile();
        }

        private void install_tile() {
            tile = new QuickTile("dev.sinty.nearby", _("Nearby"), "phone-symbolic");
            tile.detail_title = _("Nearby");
            tile.toggleable = false;
            tile.clicked.connect(() => {
                bool on = !client.discoverable;
                client.set_service_property.begin("Discoverable", new Variant.boolean(on), (o, r) => {
                    try {
                        client.set_service_property.end(r);
                    } catch (Error e) {
                        warning("nearby: %s", e.message);
                    }
                });
            });
            tile.set_detail_page(() => NearbyTileDetail.build());
            PluginManager.get_default().get_context().add_quick_tile(tile);
            sync_tile();
        }

        private void sync_tile() {
            if (tile == null) return;
            var usable = client.usable_devices();
            tile.active = client.discoverable || usable.size > 0;
            if (usable.size == 1) {
                var d = usable[0];
                tile.subtitle = d.battery >= 0 ? "%s, %d%%".printf(d.name, d.battery) : d.name;
                tile.icon_name = d.icon_name;
            } else if (usable.size > 1) {
                tile.subtitle = ngettext("%d device", "%d devices", usable.size).printf(usable.size);
                tile.icon_name = "phone-symbolic";
            } else {
                tile.subtitle = client.discoverable ? _("Visible") : _("Hidden");
                tile.icon_name = "phone-symbolic";
            }
        }
    }

    public class NearbyTileDetail : Object {
        public static Widget build() {
            var client = NearbyClient.get_default();
            var box = new Box(Orientation.VERTICAL, 0);
            var visible_group = new PreferencesGroup(_("Visibility"));
            var visible_row = new SwitchRow(_("Visible to Nearby Devices"),
                _("Phones and computers on this network can find this computer and ask to pair."), client.discoverable);
            bool syncing = false;
            visible_row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                client.set_service_property.begin("Discoverable", new Variant.boolean(visible_row.switch_btn.active));
            });
            visible_group.add_row(visible_row);
            var devices_group = new PreferencesGroup(_("Devices"));
            devices_group.margin_top = 12;
            box.append(devices_group);
            box.append(visible_group);
            visible_group.margin_top = 12;

            Gee.HashSet<string> shown = new Gee.HashSet<string>();
            NearbyDetailFill fill = () => {};
            fill = () => {
                syncing = true;
                visible_row.switch_btn.active = client.discoverable;
                syncing = false;
                devices_group.clear();
                var paired = new Gee.ArrayList<NearbyDevice>();
                foreach (var d in client.devices) if (d.paired) paired.add(d);
                if (paired.size == 0) {
                    var row = new ActionRow(_("No Paired Devices"), _("Pair a phone in Connected Devices."), "phone-symbolic");
                    row.activatable = true;
                    row.activated.connect(() => NearbyClient.open_settings());
                    devices_group.add_row(row);
                    return;
                }
                Widget[] fresh = {};
                foreach (var d in paired) {
                    var row = new ActionRow(d.name, d.status_text(), d.icon_name);
                    string device_id = d.id;
                    row.activatable = true;
                    row.activated.connect(() => NearbyClient.open_app(device_id));
                    if (d.usable && d.has_plugin("findmyphone") && d.supports_find) {
                        var ring = new Button.from_icon_name("find-location-symbolic");
                        ring.add_css_class("flat");
                        ring.valign = Align.CENTER;
                        ring.tooltip_text = _("Ring %s").printf(d.name);
                        ring.update_property(AccessibleProperty.LABEL, ring.tooltip_text, -1);
                        string id = d.id;
                        ring.clicked.connect(() => client.simple.begin("Ring", new Variant("(s)", id)));
                        row.add_suffix(ring);
                    }
                    devices_group.add_row(row);
                    if (!shown.contains(d.id)) fresh += row;
                    shown.add(d.id);
                }
                if (fresh.length > 0) Motion.cascade(fresh, Motion.Preset.FADE);
            };
            fill();
            ulong h = client.changed.connect(() => fill());
            box.destroy.connect(() => client.disconnect(h));

            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 16;
            buttons.margin_bottom = 8;
            var settings_btn = new Button.with_label(_("Settings"));
            settings_btn.add_css_class("pill");
            settings_btn.clicked.connect(() => NearbyClient.open_settings());
            buttons.append(settings_btn);
            if (NearbyClient.app_installed()) {
                var app_btn = new Button.with_label(_("Open Nearby"));
                app_btn.add_css_class("pill");
                app_btn.add_css_class("suggested-action");
                app_btn.clicked.connect(() => NearbyClient.open_app());
                buttons.append(app_btn);
            }
            box.append(buttons);
            return box;
        }
    }

    public delegate void NearbyDetailFill();
}
