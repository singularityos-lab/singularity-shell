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

    public class SettingsPage : Box {
        public Box content_box;
        public ScrolledWindow scroller;
        public Box header;
        public Button back_btn;
        public Button adaptive_back_btn;
        public Widget? top_spacer = null;
        public string page_title { get; private set; }
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

            var title_lbl = new Label(title);
            title_lbl.add_css_class("page-title");
            title_lbl.halign = Align.START;
            title_lbl.hexpand = true;
            title_lbl.ellipsize = Pango.EllipsizeMode.END;
            title_lbl.xalign = 0;
            header.append(title_lbl);

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
