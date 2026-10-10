using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class SharingSession : Object {
        public uint id;
        public string peer;
        public bool control;
        public bool clipboard;
        public int64 started;
    }

    public class SharingClient : Object {
        public const string BUS_NAME = "dev.sinty.Sharing";
        public const string PATH = "/dev/sinty/Sharing";
        public const string IFACE = "dev.sinty.Sharing1";
        public const string SCHEMA = "dev.sinty.sharing";

        private static SharingClient? _instance = null;

        public bool running { get; private set; default = false; }
        public GLib.Settings? settings { get; private set; default = null; }

        private HashTable<string, Variant> state = new HashTable<string, Variant>(str_hash, str_equal);
        private DBusConnection? conn = null;
        private bool refreshing = false;

        public signal void changed();

        public static SharingClient get_default() {
            if (_instance == null) _instance = new SharingClient();
            return _instance;
        }

        construct {
            var source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup(SCHEMA, true) != null) settings = new GLib.Settings(SCHEMA);
            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    conn = Bus.get.end(res);
                    conn.signal_subscribe(null, IFACE, "Changed", PATH, null, DBusSignalFlags.NONE,
                        () => refresh.begin());
                    Bus.watch_name_on_connection(conn, BUS_NAME, BusNameWatcherFlags.NONE,
                        () => refresh.begin(), () => {
                            running = false;
                            changed();
                        });
                    refresh.begin();
                } catch (Error e) {
                    warning("Sharing: %s", e.message);
                }
            });
        }

        public bool installed {
            get { return settings != null; }
        }

        public async void refresh() {
            if (conn == null || refreshing || settings == null) return;
            refreshing = true;
            try {
                var ret = yield conn.call(BUS_NAME, PATH, IFACE, "GetState", null, new VariantType("(a{sv})"),
                    DBusCallFlags.NONE, 5000, null);
                var dict = ret.get_child_value(0);
                var fresh = new HashTable<string, Variant>(str_hash, str_equal);
                var iter = dict.iterator();
                string key;
                Variant value;
                while (iter.next("{sv}", out key, out value)) fresh[key] = value;
                state = fresh;
                running = true;
            } catch (Error e) {
                running = false;
            }
            refreshing = false;
            changed();
        }

        public bool flag(string key) {
            var v = state[key];
            return v != null && v.is_of_type(VariantType.BOOLEAN) && v.get_boolean();
        }

        public string text(string key) {
            var v = state[key];
            return v != null && v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }

        public Variant? raw(string key) {
            return state[key];
        }

        public uint number(string key) {
            var v = state[key];
            return v != null && v.is_of_type(VariantType.UINT32) ? v.get_uint32() : 0;
        }

        public SharingSession[] sessions() {
            SharingSession[] list = {};
            var v = state["Sessions"];
            if (v == null || !v.is_of_type(new VariantType("a(ussbbx)"))) return list;
            var iter = v.iterator();
            uint id;
            string peer, kind;
            bool control, clipboard;
            int64 started;
            while (iter.next("(ussbbx)", out id, out peer, out kind, out control, out clipboard, out started)) {
                var s = new SharingSession();
                s.id = id;
                s.peer = peer;
                s.control = control;
                s.clipboard = clipboard;
                s.started = started;
                list += s;
            }
            return list;
        }

        public async void call(string method, Variant? args) throws Error {
            if (conn == null) conn = yield Bus.get(BusType.SESSION);
            yield conn.call(BUS_NAME, PATH, IFACE, method, args, null, DBusCallFlags.NONE, 30000, null);
            yield refresh();
        }

        public void set_enabled(string key, bool enabled) {
            if (settings != null) settings.set_boolean(key, enabled);
        }

        public static string ports_for_files(string backend, uint port) {
            return backend == "samba" ? "139/tcp,445/tcp,137-138/udp" : "%u/tcp".printf(port);
        }

        public void sync_firewall(string id, string label, bool enabled, string ports) {
            var firewall = FirewallManager.get_default();
            if (enabled) firewall.register_app.begin(id, label, ports.split(","), false);
            else firewall.unregister_app.begin(id);
        }
    }

    public class SharingPage : SettingsPage {
        private SettingsView view;
        private SharingClient client;
        private EntryRow name_row;
        private ActionRow address_row;
        private Button save_name;
        private ActionRow files_row;
        private ActionRow media_row;
        private ActionRow remote_row;
        private ActionRow collab_row;
        private Label name_error;

        public SharingPage(SettingsView view) {
            base(_("Sharing"));
            this.view = view;
            client = SharingClient.get_default();
            back_clicked.connect(() => view.go_home());

            var computer = new PreferencesGroup(_("This Computer"), _("Other devices on the network see this name."));
            name_row = new EntryRow(_("Computer Name"));
            computer.add_row(name_row);
            address_row = new ActionRow(_("Network Name"), "");
            address_row.activatable = false;
            computer.add_row(address_row);
            add_group(computer);
            name_error = new Label("");
            name_error.add_css_class("caption");
            name_error.add_css_class("error");
            name_error.wrap = true;
            name_error.xalign = 0;
            name_error.margin_start = 12;
            name_error.margin_top = 6;
            name_error.visible = false;
            add_widget(name_error);
            save_name = new Button.with_label(_("Rename"));
            save_name.add_css_class("pill");
            save_name.valign = Align.CENTER;
            save_name.sensitive = false;
            save_name.clicked.connect(() => rename.begin());
            name_row.entry_changed.connect(() => save_name.sensitive = name_row.text.strip() != "");
            name_row.entry_activated.connect(() => rename.begin());
            name_row.add_suffix(save_name);

            var services = new PreferencesGroup(_("Services"), _("Everything is off until you turn it on."));
            files_row = service_row(services, _("File Sharing"), "folder-remote-symbolic", "sharing-files");
            media_row = service_row(services, _("Media Sharing"), "folder-music-symbolic", "sharing-media");
            remote_row = service_row(services, _("Remote Desktop"), "preferences-desktop-remote-desktop-symbolic",
                "sharing-remote");
            collab_row = service_row(services, _("Collaboration"), "system-users-symbolic", "sharing-collab");
            add_group(services);

            add_search_action(_("File Sharing"), _("Share folders on the network"), () => view.navigate_to("sharing-files"));
            add_search_action(_("Media Sharing"), _("Share music, photos and videos with players"),
                () => view.navigate_to("sharing-media"));
            add_search_action(_("Remote Desktop"), _("Let someone see and control this screen"),
                () => view.navigate_to("sharing-remote"));

            client.changed.connect(sync);
            map.connect(() => {
                load_name.begin();
                client.refresh.begin();
            });
            load_name.begin();
            sync();
        }

        private ActionRow service_row(PreferencesGroup group, string title, string icon, string page) {
            var row = new ActionRow(title, null, icon);
            row.activatable = true;
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            chevron.add_css_class("dim-label");
            chevron.valign = Align.CENTER;
            row.add_suffix(chevron);
            row.activated.connect(() => view.navigate_to(page));
            group.add_row(row);
            return row;
        }

        private async void load_name() {
            var hostname = HostnameManager.get_default();
            yield hostname.load();
            name_row.text = HostnameManager.display_name(hostname.pretty_name, hostname.hostname);
            address_row.subtitle = "%s.local".printf(hostname.hostname);
            name_row.sensitive = hostname.can_change;
            save_name.visible = hostname.can_change;
            save_name.sensitive = false;
            if (!hostname.can_change) {
                name_error.label = _("The name can only be changed by the administrator of this system.");
                name_error.remove_css_class("error");
                name_error.add_css_class("dim-label");
                name_error.visible = true;
            }
        }

        private async void rename() {
            string pretty = name_row.text.strip();
            if (pretty == "") return;
            save_name.sensitive = false;
            try {
                yield HostnameManager.get_default().set_name(pretty);
                name_error.visible = false;
                yield load_name();
            } catch (Error e) {
                name_error.label = e.message;
                name_error.visible = true;
                save_name.sensitive = true;
            }
        }

        private async void sync_collab() {
            if (!Singularity.Collab.Client.installed()) {
                collab_row.subtitle = _("Not installed");
                return;
            }
            var collab = Singularity.Collab.Client.get_default();
            if (!(yield collab.get_enabled())) {
                collab_row.subtitle = _("Off");
                return;
            }
            int n = (yield collab.sessions()).size;
            collab_row.subtitle = n > 0 ? ngettext("%d session active", "%d sessions active", (ulong) n).printf(n) : _("On");
        }

        private void sync() {
            sync_collab.begin();
            var s = client.settings;
            if (s == null) {
                files_row.subtitle = _("Not installed");
                media_row.subtitle = _("Not installed");
                remote_row.subtitle = _("Not installed");
                return;
            }
            if (s.get_boolean("file-sharing-enabled")) {
                int n = s.get_strv("shared-folders").length;
                files_row.subtitle = ngettext("On, %d folder", "On, %d folders", (ulong) n).printf(n);
            } else {
                files_row.subtitle = _("Off");
            }
            if (client.running && !client.flag("MediaSharingAvailable")) media_row.subtitle = _("Not available");
            else media_row.subtitle = s.get_boolean("media-sharing-enabled") ? _("On") : _("Off");
            int viewers = client.sessions().length;
            if (viewers > 0) {
                remote_row.subtitle = ngettext("%d person connected", "%d people connected", (ulong) viewers).printf(viewers);
            } else if (client.running && !client.flag("RemoteDesktopAvailable")) {
                remote_row.subtitle = _("Not available");
            } else {
                remote_row.subtitle = s.get_boolean("remote-desktop-enabled") ? _("On") : _("Off");
            }
        }
    }
}
