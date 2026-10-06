using Gtk;

namespace Singularity {

    public class ScreenSharingIndicator : Gtk.Button {
        public const string PORTAL_BUS = "org.freedesktop.impl.portal.desktop.singularity";
        public const string PORTAL_PATH = "/dev/sinty/portal/RemoteSessions";
        public const string PORTAL_IFACE = "dev.sinty.portal.RemoteSessions";

        private static bool _styled = false;
        private Label _label;
        private DBusConnection? _conn = null;
        private string[] _portal_names = {};
        private string[] _portal_handles = {};
        private ulong _changed_id = 0;
        private uint _signal_id = 0;

        public ScreenSharingIndicator() {
            Object();
            ensure_style();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("screen-sharing-indicator");
            update_property(Gtk.AccessibleProperty.LABEL, _("Stop Screen Sharing"), -1);

            var box = new Box(Orientation.HORIZONTAL, 6);
            var dot = new Box(Orientation.HORIZONTAL, 0);
            dot.add_css_class("sharing-dot");
            dot.valign = Align.CENTER;
            box.append(dot);
            var icon = new Image.from_icon_name("video-display-symbolic");
            icon.pixel_size = 14;
            box.append(icon);
            _label = new Label(_("Sharing"));
            box.append(_label);
            var stop = new Image.from_icon_name("media-playback-stop-symbolic");
            stop.pixel_size = 12;
            stop.add_css_class("stop-icon");
            box.append(stop);
            set_child(box);

            clicked.connect(stop_all);
            var client = SidebarPages.SharingClient.get_default();
            _changed_id = client.changed.connect(sync);

            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    _conn = Bus.get.end(res);
                    _signal_id = _conn.signal_subscribe(PORTAL_BUS, PORTAL_IFACE, "Changed", PORTAL_PATH, null,
                        DBusSignalFlags.NONE, () => refresh_portal.begin());
                    refresh_portal.begin();
                } catch (Error e) {
                    warning("ScreenSharingIndicator: %s", e.message);
                }
            });
            sync();
        }

        public override void dispose() {
            if (_changed_id != 0) {
                SidebarPages.SharingClient.get_default().disconnect(_changed_id);
                _changed_id = 0;
            }
            if (_signal_id != 0 && _conn != null) {
                _conn.signal_unsubscribe(_signal_id);
                _signal_id = 0;
            }
            base.dispose();
        }

        private async void refresh_portal() {
            if (_conn == null) return;
            string[] names = {};
            string[] handles = {};
            try {
                var ret = yield _conn.call(PORTAL_BUS, PORTAL_PATH, PORTAL_IFACE, "ListSessions", null,
                    new VariantType("(aa{sv})"), DBusCallFlags.NO_AUTO_START, 3000, null);
                var iter = ret.get_child_value(0).iterator();
                Variant? item;
                while ((item = iter.next_value()) != null) {
                    var handle = item.lookup_value("handle", VariantType.STRING);
                    var name = item.lookup_value("name", VariantType.STRING);
                    var app = item.lookup_value("app_id", VariantType.STRING);
                    if (handle == null) continue;
                    handles += handle.get_string();
                    string shown = name != null && name.get_string() != "" ? name.get_string()
                        : app != null && app.get_string() != "" ? app.get_string() : _("An app");
                    names += shown;
                }
            } catch (Error e) {
            }
            _portal_names = names;
            _portal_handles = handles;
            sync();
        }

        public static string describe(string[] people, string[] apps) {
            string[] all = {};
            foreach (unowned string p in people) all += p;
            foreach (unowned string a in apps) all += a;
            if (all.length == 0) return "";
            if (all.length == 1) return _("%s can see this screen. Click to stop.").printf(all[0]);
            return ngettext("%d connection can see this screen. Click to stop them.",
                "%d connections can see this screen. Click to stop them.", (ulong) all.length).printf(all.length);
        }

        private void sync() {
            string[] people = {};
            foreach (var s in SidebarPages.SharingClient.get_default().sessions()) people += s.peer;
            int total = people.length + _portal_names.length;
            visible = total > 0;
            _label.label = total > 1 ? _("Sharing (%d)").printf(total) : _("Sharing");
            tooltip_text = describe(people, _portal_names);
        }

        private void stop_all() {
            var client = SidebarPages.SharingClient.get_default();
            if (client.sessions().length > 0) client.call.begin("StopAllSessions", null);
            if (_conn != null && _portal_handles.length > 0) {
                _conn.call.begin(PORTAL_BUS, PORTAL_PATH, PORTAL_IFACE, "StopAll", null, null,
                    DBusCallFlags.NO_AUTO_START, 3000, null);
            }
        }

        private static void ensure_style() {
            if (_styled) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            _styled = true;
            var provider = new Gtk.CssProvider();
            provider.load_from_data(SHARING_CSS.data);
            Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string SHARING_CSS = """
.screen-sharing-indicator .sharing-dot {
    background-color: @warning_color;
    min-width: 8px;
    min-height: 8px;
    border-radius: 999px;
}
""";
    }
}
