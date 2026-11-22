using Gtk;
using Gee;
using Singularity.Widgets;

namespace Singularity {

    public delegate void SettingsSearchCallback();

    public class SettingsSearchAction : Object {
        public string title;
        public string subtitle;
        public SettingsSearchCallback callback;

        public SettingsSearchAction(string title, string subtitle, owned SettingsSearchCallback callback) {
            this.title = title;
            this.subtitle = subtitle;
            this.callback = (owned) callback;
        }
    }

    public class SettingsTitles : Object {
        public static string heading(string title) {
            string[] pairs = {
                _("Accessibility"), _("Ease of Use"),
                _("Hands-free Control"), _("Hands-free"),
                _("Pointing and Clicking"), _("Pointer"),
                _("Screen Reader"), _("Read Aloud"),
                _("Text Recognition"), _("Text Scan"),
                _("Online Accounts"), _("Accounts"),
                _("Other Permissions"), _("Other Access"),
                _("Files and Folders"), _("Files"),
                _("Display, Sound and Services"), _("Connections"),
                _("Session Services"), _("Session"),
                _("System Services"), _("System"),
                _("Automatic Updates"), _("Auto Updates"),
                _("Update History"), _("History"),
                _("Clipboard History"), _("Clipboard"),
                _("Collaboration"), _("Teamwork"),
                _("Connected Devices"), _("Devices"),
                _("Add by Address"), _("By Address"),
                _("Saved Networks"), _("Saved"),
                _("Mobile Network"), _("Mobile"),
                _("Hotspot & Sharing"), _("Hotspot"),
                _("Dynamic Internet"), _("Dynamic"),
                _("Edit Shortcut"), _("Shortcut"),
                _("Global Shortcuts"), _("Shortcuts"),
                _("Colors and Effects"), _("Appearance"),
                _("Panel and Launcher"), _("Panel"),
                _("Windows and Snap"), _("Windows"),
                _("Wallpaper Sources"), _("Sources"),
                _("D-Bus Inspector"), _("D-Bus"),
                _("OAuth Clients"), _("OAuth"),
                _("Settings Editor"), _("Raw Settings"),
                _("Debug Options"), _("Debugging"),
                _("Test Triggers"), _("Triggers"),
                _("Allow bootloader unlock"), _("Bootloader"),
                _("Speech Models"), _("Models"),
                _("Learned Phrases"), _("Phrases"),
                _("Import a Table"), _("Import Table"),
                _("Input Methods"), _("Input"),
                _("Add Input Method"), _("Add Input"),
                _("Add Input Source"), _("Add Source"),
                _("Notifications"), _("Alerts"),
                _("Parental Controls"), _("Family"),
                _("Security Keys"), _("Hardware Key"),
                _("Change Password"), _("Password"),
                _("Search Providers"), _("Search"),
                _("Background Activity"), _("Background"),
                _("Screen Sharing"), _("Screencast"),
                _("Who Can Disturb"), _("Allowed"),
                _("Region & Language"), _("Language"),
                _("Media Sharing"), _("Media"),
                _("Remote Desktop"), _("Remote"),
                _("Make a Sinty Key"), _("New Key"),
                _("Open the Sinty Key"), _("Open Key"),
                _("Key for Your Files"), _("File Key"),
                _("Restore a Sinty Key"), _("Restore Key"),
                _("System Components"), _("Components"),
                _("Graphics Tablet"), _("Tablet"),
                _("Tablet Buttons"), _("Buttons"),
            };
            for (int i = 0; i + 1 < pairs.length; i += 2) {
                if (pairs[i] == title) return pairs[i + 1];
            }
            return title;
        }
    }

    public class SettingsArtwork : Object {
        public const string GENERIC = "singularity-settings";

        public static string? find(string page_name, string symbolic_name) {
            string name = named(page_name) ?? symbolic_name.replace("-symbolic", "");
            var theme = IconTheme.get_for_display(Gdk.Display.get_default());
            if (!theme.has_icon(name)) return null;
            var icon = theme.lookup_icon(name, null, Singularity.Widgets.PageHero.ICON_SIZE, 1, TextDirection.NONE, 0);
            string? file = icon.get_file() != null ? icon.get_file().get_path() : null;
            if (file == null || !file.has_suffix(".svg") || file.has_suffix("-symbolic.svg")) return null;
            return name;
        }

        private static string? named(string page_name) {
            if (page_name == NetworkPage.WIRED) return "network-workgroup";
            if (page_name == NetworkPage.VPN) return "singularity-vpn";
            switch (page_name) {
                case "network-mobile": case "dev-modem": return "phone";
                case "accounts": return "singularity-account-generic";
                case "datetime": return "document-open-recent";
                case "desktop": return "singularity-dynamic-wallpaper";
                case "sound": return "audio-speakers";
                case "wellbeing": return "singularity-screen-time";
                case "bluetooth": return "singularity-bluetooth";
                case "autostart": return "singularity-autostart";
                case "plugins": return "application-x-addon";
                case "updates": return "singularity-updates";
                case "sinty-key": return "sinty-key";
                case "sinty-core": return "sinty";
                case "sharing-media": return "folder-music";
                case "sharing-remote": return "preferences-desktop-remote-desktop";
                case "sharing-collab": return "system-users";
                case "sharing-files": return "folder-remote";
                case "firewall": return "aegis-security";
                case "quick-unlock": return "preferences-system-privacy";
                case "wallpaper-browser": return "singularity-dynamic-wallpaper";
            }
            return null;
        }
    }

    public class SettingsPage : Box {
        public Box content_box;
        public ScrolledWindow scroller;
        public Box header;
        public Button back_btn;
        public Button adaptive_back_btn;
        public Widget? top_spacer = null;
        public string page_title { get; private set; }
        private Label _title_label;
        private Singularity.Widgets.PageHero? _hero = null;
        private string? _artwork = null;
        private const int HEADER_SIDE = 72;
        private ArrayList<Widget> _groups = new ArrayList<Widget>();
        public signal void back_clicked();

        public SettingsPage(string title) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            page_title = title;
            header = new Box(Orientation.HORIZONTAL, 12);
            header.add_css_class("page-header");

            back_btn = new Button.from_icon_name("go-previous-symbolic");
            back_btn.has_frame = false;
            back_btn.add_css_class("navigation-button");
            back_btn.visible = false; // Hidden by default
            back_btn.clicked.connect(() => {
                back_clicked();
            });
            header.append(back_btn);

            adaptive_back_btn = new Button.from_icon_name("go-previous-symbolic");
            adaptive_back_btn.has_frame = false;
            adaptive_back_btn.add_css_class("navigation-button");
            adaptive_back_btn.visible = false;
            header.append(adaptive_back_btn);

            var title_lbl = new Label(SettingsTitles.heading(title));
            title_lbl.add_css_class("page-title");
            title_lbl.halign = Align.START;
            title_lbl.hexpand = true;
            title_lbl.ellipsize = Pango.EllipsizeMode.END;
            title_lbl.xalign = 0;
            header.append(title_lbl);
            _title_label = title_lbl;

            // Header is outside the scroller so it's always visible
            append(header);

            scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.vscrollbar_policy = PolicyType.AUTOMATIC;
            scroller.propagate_natural_height = true;
            scroller.vexpand = true;
            // No max_content_height here - the outer sidebar_scroll caps total height

            content_box = new Box(Orientation.VERTICAL, 0); // No spacing by default
            content_box.add_css_class("settings-page-content");

            scroller.set_child(content_box);
            append(scroller);
        }

        public void show_artwork(string icon_name) {
            var hero = new Singularity.Widgets.PageHero(_artwork ?? icon_name, _title_label.label);
            hero.watch(content_box);
            _title_label.bind_property("label", hero, "title", BindingFlags.SYNC_CREATE);
            _title_label.opacity = 0;
            hero.can_target = false;
            _hero = hero;
            for (var child = _title_label.get_next_sibling(); child != null; child = child.get_next_sibling()) {
                child.notify["visible"].connect(center_hero);
            }
            map.connect(center_hero);
            center_hero();

            var bar = new Overlay();
            bar.margin_bottom = 8;
            remove(header);
            header.valign = Align.CENTER;
            bar.set_child(header);
            bar.add_overlay(hero);
            bar.set_measure_overlay(hero, true);
            prepend(bar);
        }

        protected void set_artwork(string icon_name) {
            _artwork = icon_name;
            if (_hero != null) _hero.icon_name = icon_name;
        }

        private void center_hero() {
            if (_hero == null) return;
            int side = header_side();
            _hero.margin_start = side;
            _hero.margin_end = side;
        }

        private int header_side() {
            int trailing = 0;
            for (var child = _title_label.get_next_sibling(); child != null; child = child.get_next_sibling()) {
                if (!child.visible) continue;
                int natural;
                child.measure(Orientation.HORIZONTAL, -1, null, out natural, null, null);
                if (natural > 0) trailing += natural + header.spacing;
            }
            return int.max(HEADER_SIDE, trailing + header.spacing);
        }

        public void show_top_spacer(bool show) {
            if (show) {
                if (top_spacer == null) {
                    var s = new Box(Orientation.VERTICAL, 0);
                    s.set_size_request(-1, 46);
                    content_box.prepend(s);
                    top_spacer = s;
                }
                top_spacer.visible = true;
            } else if (top_spacer != null) {
                top_spacer.visible = false;
            }
        }

        public void add_group(Widget group) {
            _groups.add(group);
            group.margin_top = 0;
            content_box.append(group);
        }

        public Gee.List<Widget> get_groups() {
            return _groups.read_only_view;
        }

        private ArrayList<SettingsSearchAction> _search_actions = new ArrayList<SettingsSearchAction>();

        public void add_search_action(string title, string subtitle, owned SettingsSearchCallback callback) {
            _search_actions.add(new SettingsSearchAction(title, subtitle, (owned) callback));
        }

        public Gee.List<SettingsSearchAction> get_search_actions() {
            return _search_actions.read_only_view;
        }

        public void add_widget(Widget widget) {
            content_box.append(widget);
        }
    }
    public class ToggleTile : Button {
        public Label title_label;
        public Image icon;
        public bool active { get; set; default = false; }

        public ToggleTile(string title, string icon_name, bool is_active = false) {
            this.active = is_active;
            add_css_class("toggle-tile");
            if (active) add_css_class("active");
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.halign = Align.START;
            box.valign = Align.CENTER;
            icon = new Image.from_icon_name(icon_name);
            icon.pixel_size = 24;
            box.append(icon);
            title_label = new Label(title);
            title_label.ellipsize = Pango.EllipsizeMode.END;
            box.append(title_label);
            set_child(box);
            notify["active"].connect(() => {
                if (active) add_css_class("active");
                else remove_css_class("active");
            });
            clicked.connect(() => {
                active = !active;
            });
        }
    }
}
