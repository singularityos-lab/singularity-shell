using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public abstract class SharingServicePage : SettingsPage {
        protected SettingsView view;
        protected SharingClient client;
        protected StatusPage unavailable;
        protected WelcomePage welcome;
        protected Gee.ArrayList<Widget> active_widgets = new Gee.ArrayList<Widget>();
        protected Label error_label;

        protected SharingServicePage(SettingsView view, string title) {
            base(title);
            this.view = view;
            client = SharingClient.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("sharing"));

            unavailable = new StatusPage();
            unavailable.compact = true;
            unavailable.visible = false;
            add_widget(unavailable);

            welcome = new WelcomePage();
            welcome.is_section = true;
            welcome.embedded = true;
            welcome.compact = true;
            welcome.visible = false;
            add_widget(welcome);

            error_label = new Label("");
            error_label.add_css_class("caption");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            error_label.xalign = 0;
            error_label.margin_start = 12;
            error_label.margin_top = 8;
            error_label.visible = false;
        }

        protected void track(Widget widget) {
            active_widgets.add(widget);
        }

        protected void add_active_group(Widget group) {
            add_group(group);
            track(group);
        }

        protected void show_state(bool available, bool enabled, string error) {
            unavailable.visible = !available;
            welcome.visible = available && !enabled;
            foreach (var w in active_widgets) w.visible = available && enabled;
            error_label.label = error;
            error_label.visible = available && error != "";
        }

        protected static string short_path(string path) {
            string home = Environment.get_home_dir();
            return path.has_prefix(home + "/") ? "~" + path.substring(home.length) : path;
        }

        protected static Image chevron() {
            var image = new Image.from_icon_name("go-next-symbolic");
            image.pixel_size = 12;
            image.add_css_class("dim-label");
            image.valign = Align.CENTER;
            return image;
        }

        protected static ActionRow copy_row(string title) {
            var row = new ActionRow(title, "");
            row.activatable = false;
            var copy = new Button.from_icon_name("edit-copy-symbolic");
            copy.valign = Align.CENTER;
            copy.tooltip_text = _("Copy");
            copy.add_css_class("flat");
            copy.clicked.connect(() => {
                var display = Gdk.Display.get_default();
                if (display != null && row.subtitle != "") display.get_clipboard().set_text(row.subtitle);
            });
            row.add_suffix(copy);
            return row;
        }

        protected Widget password_group(string kind, string title, string description, out PasswordRow row,
                                        out Label status) {
            var group = new PreferencesGroup(title, description);
            var pass = new PasswordRow(_("New Password"));
            group.add_row(pass);
            var box = new Box(Orientation.HORIZONTAL, 8);
            box.margin_top = 8;
            var info = new Label("");
            info.add_css_class("caption");
            info.add_css_class("dim-label");
            info.wrap = true;
            info.xalign = 0;
            info.hexpand = true;
            box.append(info);
            var set = new Button.with_label(_("Set Password"));
            set.add_css_class("pill");
            set.valign = Align.CENTER;
            set.sensitive = false;
            pass.entry_changed.connect(() => set.sensitive = pass.text.char_count() >= 6);
            SetPasswordCallback apply = () => {
                if (pass.text.char_count() < 6) return;
                set.sensitive = false;
                string value = pass.text;
                client.call.begin("SetPassword", new Variant("(ss)", kind, value), (o, r) => {
                    try {
                        client.call.end(r);
                        pass.text = "";
                        info.label = _("Password saved in your keyring.");
                    } catch (Error e) {
                        DBusError.strip_remote_error(e);
                        info.label = e.message;
                        set.sensitive = true;
                    }
                });
            };
            set.clicked.connect(() => apply());
            pass.entry_activated.connect(() => apply());
            box.append(set);
            var outer = new Box(Orientation.VERTICAL, 0);
            outer.append(group);
            outer.append(box);
            row = pass;
            status = info;
            return outer;
        }

        protected delegate void SetPasswordCallback();
    }

    public class FileSharingPage : SharingServicePage {
        private SwitchRow enabled_row;
        private ActionRow address_row;
        private ActionRow user_row;
        private PreferencesGroup folders_group;
        private SwitchRow read_only_row;
        private SelectionRow protocol_row;
        private Label password_status;
        private bool syncing = false;

        public FileSharingPage(SettingsView view) {
            base(view, _("File Sharing"));
            unavailable.icon_name = "folder-remote";
            unavailable.title = _("File Sharing Is Not Available");
            unavailable.description = _("The sharing service is not installed on this system.");

            welcome.app_icon_name = "folder-remote";
            welcome.title = _("Share Folders");
            welcome.subtitle = _("Let other computers on your network open the folders you choose. They sign in with your user name and a password you set here.");
            welcome.add_action("folder-publicshare", _("Share a Folder"), _("Choose a folder to share"),
                () => add_folder(true));

            var status = new PreferencesGroup(_("Connection"));
            enabled_row = new SwitchRow(_("Share Folders"), _("Visible to computers on this network"), false);
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (syncing) return;
                set_enabled(enabled_row.switch_btn.active);
            });
            status.add_row(enabled_row);
            address_row = copy_row(_("Address"));
            status.add_row(address_row);
            user_row = new ActionRow(_("User Name"), Environment.get_user_name());
            user_row.activatable = false;
            status.add_row(user_row);
            add_active_group(status);
            add_widget(error_label);

            folders_group = new PreferencesGroup(_("Shared Folders"));
            var add_btn = new Button.with_label(_("Add Folder"));
            add_btn.add_css_class("pill");
            add_btn.valign = Align.CENTER;
            add_btn.clicked.connect(() => add_folder(false));
            folders_group.add_header_suffix(add_btn);
            add_active_group(folders_group);

            var access = new PreferencesGroup(_("Access"));
            read_only_row = new SwitchRow(_("Read Only"), _("Others can open files but not change them"), true);
            read_only_row.switch_btn.notify["active"].connect(() => {
                if (syncing || client.settings == null) return;
                client.settings.set_boolean("file-sharing-read-only", read_only_row.switch_btn.active);
            });
            access.add_row(read_only_row);
            protocol_row = new SelectionRow(_("Protocol"), { "WebDAV", "Samba" });
            protocol_row.visible = false;
            protocol_row.selected.connect((item) => {
                if (syncing || client.settings == null) return;
                client.settings.set_string("file-sharing-protocol", item == "Samba" ? "samba" : "webdav");
            });
            access.add_row(protocol_row);
            add_active_group(access);

            PasswordRow pass;
            var pw = password_group("file-sharing", _("Password"), _("Needed by other computers together with your user name."),
                out pass, out password_status);
            add_widget(pw);
            track(pw);

            client.changed.connect(sync);
            if (client.settings != null) client.settings.changed.connect(() => sync());
            map.connect(() => client.refresh.begin());
            sync();
        }

        private void set_enabled(bool on) {
            if (client.settings == null) return;
            client.settings.set_boolean("file-sharing-enabled", on);
            client.sync_firewall("file-sharing", _("File Sharing"), on,
                SharingClient.ports_for_files(client.settings.get_string("file-sharing-protocol"),
                    client.settings.get_uint("file-sharing-port")));
        }

        private void add_folder(bool enable) {
            var dialog = new FileDialog();
            dialog.title = _("Choose a Folder to Share");
            dialog.modal = true;
            dialog.select_folder.begin(get_root() as Gtk.Window, null, (obj, res) => {
                try {
                    var file = dialog.select_folder.end(res);
                    if (file == null || file.get_path() == null || client.settings == null) return;
                    string[] folders = client.settings.get_strv("shared-folders");
                    if (!(file.get_path() in folders)) folders += file.get_path();
                    client.settings.set_strv("shared-folders", folders);
                    if (enable) set_enabled(true);
                } catch (Error e) {
                }
            });
        }

        private void remove_folder(string path) {
            if (client.settings == null) return;
            string[] kept = {};
            foreach (string f in client.settings.get_strv("shared-folders")) if (f != path) kept += f;
            client.settings.set_strv("shared-folders", kept);
            if (kept.length == 0) set_enabled(false);
        }

        private void sync() {
            var s = client.settings;
            if (s == null) {
                show_state(false, false, "");
                return;
            }
            syncing = true;
            bool on = s.get_boolean("file-sharing-enabled") && s.get_strv("shared-folders").length > 0;
            enabled_row.switch_btn.active = on;
            read_only_row.switch_btn.active = s.get_boolean("file-sharing-read-only");
            address_row.subtitle = client.text("FileSharingAddress");
            address_row.visible = address_row.subtitle != "";
            bool samba = client.flag("SambaAvailable");
            protocol_row.visible = samba;
            if (samba) protocol_row.current_value = s.get_string("file-sharing-protocol") == "samba" ? "Samba" : "WebDAV";
            folders_group.clear();
            foreach (string folder in s.get_strv("shared-folders")) {
                var row = new ActionRow(Path.get_basename(folder), short_path(folder), "folder-symbolic");
                row.activatable = false;
                var remove = new Button.from_icon_name("list-remove-symbolic");
                remove.valign = Align.CENTER;
                remove.add_css_class("flat");
                remove.tooltip_text = _("Stop Sharing This Folder");
                string path = folder;
                remove.clicked.connect(() => remove_folder(path));
                row.add_suffix(remove);
                folders_group.add_row(row);
            }
            if (password_status.label == "")
                password_status.label = client.flag("FileSharingHasPassword") ? _("A password is set.")
                    : _("Set a password before others can sign in.");
            show_state(true, on, client.text("FileSharingError"));
            syncing = false;
        }
    }

    public class MediaSharingPage : SharingServicePage {
        private SwitchRow enabled_row;
        private PreferencesGroup folders_group;
        private bool syncing = false;

        public MediaSharingPage(SettingsView view) {
            base(view, _("Media Sharing"));
            unavailable.icon_name = "folder-music";
            unavailable.title = _("Media Sharing Is Not Available");
            unavailable.description = _("Install a media server such as Rygel to play your music, photos and videos on TVs and players.");

            welcome.app_icon_name = "folder-music";
            welcome.title = _("Share Your Media");
            welcome.subtitle = _("TVs, game consoles and media players on your network can play music, photos and videos from this computer.");
            welcome.add_action("folder-music", _("Turn On Media Sharing"), _("Shares Music, Pictures and Videos"),
                () => set_enabled(true));

            var status = new PreferencesGroup(_("Connection"));
            enabled_row = new SwitchRow(_("Share Media"), _("Visible to players on this network"), false);
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (!syncing) set_enabled(enabled_row.switch_btn.active);
            });
            status.add_row(enabled_row);
            add_active_group(status);
            add_widget(error_label);

            folders_group = new PreferencesGroup(_("Shared Folders"));
            add_active_group(folders_group);

            client.changed.connect(sync);
            if (client.settings != null) client.settings.changed.connect(() => sync());
            map.connect(() => client.refresh.begin());
            sync();
        }

        private void set_enabled(bool on) {
            if (client.settings == null) return;
            client.settings.set_boolean("media-sharing-enabled", on);
            client.sync_firewall("media-sharing", _("Media Sharing"), on, "1900/udp,8200/tcp");
        }

        private void sync() {
            var s = client.settings;
            bool available = s != null && (!client.running || client.flag("MediaSharingAvailable"));
            if (!available) {
                show_state(false, false, "");
                return;
            }
            syncing = true;
            bool on = s.get_boolean("media-sharing-enabled");
            enabled_row.switch_btn.active = on;
            folders_group.clear();
            string[] folders = s.get_strv("media-folders");
            if (folders.length == 0) {
                UserDirectory[] dirs = { UserDirectory.MUSIC, UserDirectory.PICTURES, UserDirectory.VIDEOS };
                string[] names = { "Music", "Pictures", "Videos" };
                for (int i = 0; i < dirs.length; i++) {
                    string? path = Environment.get_user_special_dir(dirs[i]);
                    if (path == null || path == Environment.get_home_dir())
                        path = Path.build_filename(Environment.get_home_dir(), names[i]);
                    if (FileUtils.test(path, FileTest.IS_DIR)) folders += path;
                }
            }
            foreach (string folder in folders) {
                var row = new ActionRow(Path.get_basename(folder), short_path(folder), "folder-symbolic");
                row.activatable = false;
                folders_group.add_row(row);
            }
            show_state(true, on, client.text("MediaSharingError"));
            syncing = false;
        }
    }

    public class RemoteDesktopPage : SharingServicePage {
        private SwitchRow enabled_row;
        private ActionRow address_row;
        private ActionRow fingerprint_row;
        private SwitchRow control_row;
        private SwitchRow unattended_row;
        private PreferencesGroup screens_group;
        private string screens_key = "";
        private HashTable<string, Image> screen_marks = new HashTable<string, Image>(str_hash, str_equal);
        private PreferencesGroup sessions_group;
        private Widget password_box;
        private Label password_status;
        private bool syncing = false;

        public RemoteDesktopPage(SettingsView view) {
            base(view, _("Remote Desktop"));
            unavailable.icon_name = "preferences-desktop-remote-desktop";
            unavailable.title = _("Remote Desktop Is Not Available");
            unavailable.description = _("The sharing service is not installed, or this compositor cannot share its screen.");

            welcome.app_icon_name = "preferences-desktop-remote-desktop";
            welcome.title = _("Get Help or Connect From Anywhere");
            welcome.subtitle = _("Someone you trust can see this screen and use it from another computer with a VNC app, such as Connections. You confirm every connection here.");
            welcome.add_action("preferences-desktop-remote-desktop", _("Turn On Remote Desktop"),
                _("Other computers can ask to connect"), () => set_enabled(true));

            sessions_group = new PreferencesGroup(_("Connected Now"));
            var stop_all = new Button.with_label(_("Stop All"));
            stop_all.add_css_class("pill");
            stop_all.add_css_class("destructive-action");
            stop_all.valign = Align.CENTER;
            stop_all.clicked.connect(() => client.call.begin("StopAllSessions", null));
            sessions_group.add_header_suffix(stop_all);
            sessions_group.visible = false;
            add_group(sessions_group);

            var status = new PreferencesGroup(_("Connection"), _("Encrypted with TLS. Check that the fingerprint matches the one the other computer shows."));
            enabled_row = new SwitchRow(_("Allow Connections"), _("Every connection asks for your confirmation"), false);
            enabled_row.switch_btn.notify["active"].connect(() => {
                if (!syncing) set_enabled(enabled_row.switch_btn.active);
            });
            status.add_row(enabled_row);
            address_row = copy_row(_("Address"));
            status.add_row(address_row);
            fingerprint_row = new ActionRow(_("Fingerprint"), "");
            fingerprint_row.activatable = false;
            status.add_row(fingerprint_row);
            add_active_group(status);
            add_widget(error_label);

            var access = new PreferencesGroup(_("Access"));
            control_row = new SwitchRow(_("Allow Control"), _("Suggest mouse and keyboard control when asked"), true);
            control_row.switch_btn.notify["active"].connect(() => {
                if (!syncing && client.settings != null)
                    client.settings.set_boolean("remote-desktop-view-only", !control_row.switch_btn.active);
            });
            access.add_row(control_row);
            unattended_row = new SwitchRow(_("Unattended Access"), _("Connect with your user name and a password, without anyone here to confirm"), false);
            unattended_row.switch_btn.notify["active"].connect(() => {
                if (!syncing && client.settings != null)
                    client.settings.set_boolean("remote-desktop-unattended", unattended_row.switch_btn.active);
            });
            access.add_row(unattended_row);
            add_active_group(access);

            screens_group = new PreferencesGroup(_("Screen"), _("What other computers see. You can pick another screen when asked."));
            screens_group.visible = false;
            add_group(screens_group);

            PasswordRow pass;
            password_box = password_group("remote-desktop", _("Unattended Password"),
                _("Used only when Unattended Access is on."), out pass, out password_status);
            add_widget(password_box);
            track(password_box);

            client.changed.connect(sync);
            if (client.settings != null) client.settings.changed.connect(() => sync());
            map.connect(() => client.refresh.begin());
            sync();
        }

        private void set_enabled(bool on) {
            if (client.settings == null) return;
            client.settings.set_boolean("remote-desktop-enabled", on);
            client.sync_firewall("remote-desktop", _("Remote Desktop"), on,
                "%u/tcp".printf(client.settings.get_uint("remote-desktop-port")));
        }

        private void sync() {
            var s = client.settings;
            bool available = s != null && (!client.running || client.flag("RemoteDesktopAvailable"));
            if (!available) {
                sessions_group.visible = false;
                screens_group.visible = false;
                show_state(false, false, "");
                return;
            }
            syncing = true;
            bool on = s.get_boolean("remote-desktop-enabled");
            enabled_row.switch_btn.active = on;
            control_row.switch_btn.active = !s.get_boolean("remote-desktop-view-only");
            unattended_row.switch_btn.active = s.get_boolean("remote-desktop-unattended");
            sync_screens(s.get_string("remote-desktop-screen"), on);
            address_row.subtitle = client.text("RemoteDesktopAddress");
            address_row.visible = address_row.subtitle != "";
            fingerprint_row.subtitle = client.text("RemoteDesktopFingerprint");
            fingerprint_row.visible = fingerprint_row.subtitle != "";
            if (password_status.label == "")
                password_status.label = client.flag("RemoteDesktopHasPassword") ? _("A password is set.")
                    : _("No password is set yet.");
            sessions_group.clear();
            var sessions = client.sessions();
            foreach (var session in sessions) {
                var row = new ActionRow(session.peer, session.control ? _("Can use the mouse and keyboard") : _("Can only watch"),
                    "video-display-symbolic");
                row.activatable = false;
                var stop = new Button.with_label(_("Stop"));
                stop.add_css_class("pill");
                stop.valign = Align.CENTER;
                uint id = session.id;
                stop.clicked.connect(() => client.call.begin("StopSession", new Variant("(u)", id)));
                row.add_suffix(stop);
                sessions_group.add_row(row);
            }
            sessions_group.visible = sessions.length > 0;
            show_state(true, on, client.text("RemoteDesktopError"));
            password_box.visible = on && unattended_row.switch_btn.active;
            syncing = false;
        }

        private void sync_screens(string current, bool on) {
            string[] ids = { "all" };
            string[] labels = { _("All Screens") };
            string[] details = { _("Every screen, arranged as in Displays") };
            string key = "";
            var v = client.raw("Screens");
            if (v != null && v.is_of_type(new VariantType("a(ssiiiid)"))) {
                var iter = v.iterator();
                string id, label;
                int x, y, w, h;
                double scale;
                while (iter.next("(ssiiiid)", out id, out label, out x, out y, out w, out h, out scale)) {
                    ids += id;
                    labels += label;
                    details += scale != 1.0
                        ? _("%s, %d × %d, scale %g").printf(id, (int) Math.round(w * scale), (int) Math.round(h * scale), scale)
                        : _("%s, %d × %d").printf(id, w, h);
                    key += "%s|%s|%d|%d|%g;".printf(id, label, w, h, scale);
                }
            }
            if (key != screens_key) {
                screens_key = key;
                screens_group.clear();
                screen_marks.remove_all();
                for (int i = 0; i < ids.length; i++) {
                    var row = new ActionRow(labels[i], details[i]);
                    row.activatable = true;
                    var mark = new Image.from_icon_name("object-select-symbolic");
                    mark.valign = Align.CENTER;
                    row.add_suffix(mark);
                    screen_marks.insert(ids[i], mark);
                    string chosen = ids[i];
                    row.activated.connect(() => {
                        if (client.settings != null) client.settings.set_string("remote-desktop-screen", chosen);
                    });
                    screens_group.add_row(row);
                }
            }
            string shown = screen_marks.contains(current) ? current : "all";
            screen_marks.foreach((id, mark) => mark.visible = id == shown);
            screens_group.visible = on && ids.length > 2;
        }
    }
}
