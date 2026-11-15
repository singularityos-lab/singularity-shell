using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class PhoneNavBar : Gtk.Window {
        public signal void back_requested();
        public signal void home_requested();
        public signal void recents_requested();

        public PhoneNavBar(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-phone-nav");
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            auto_exclusive_zone_enable(this);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("phone-nav");

            var bar = new CenterBox();
            bar.add_css_class("phone-nav-bar");
            var back = nav_button("go-previous-symbolic", _("Back"));
            back.clicked.connect(() => back_requested());
            var home = new Button();
            home.add_css_class("phone-nav-home");
            home.tooltip_text = _("Home");
            home.update_property(Gtk.AccessibleProperty.LABEL, _("Home"), -1);
            var pill = new Box(Orientation.HORIZONTAL, 0);
            pill.add_css_class("phone-nav-pill");
            pill.halign = Align.CENTER;
            pill.valign = Align.CENTER;
            home.child = pill;
            home.clicked.connect(() => home_requested());
            var recents = nav_button("view-grid-symbolic", _("Recent Apps"));
            recents.clicked.connect(() => recents_requested());
            bar.start_widget = back;
            bar.center_widget = home;
            bar.end_widget = recents;
            set_child(bar);
        }

        private Button nav_button(string icon, string label) {
            var b = new Button.from_icon_name(icon);
            b.add_css_class("phone-nav-button");
            b.tooltip_text = label;
            b.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            return b;
        }
    }

    public class TvHome : Gtk.Window {
        private FlowBox _apps;
        private FlowBox _resume;
        private Label _resume_title;
        private Label _clock;
        private ulong _sig_clock = 0;
        private ulong _sig_running = 0;
        private ulong _sig_apps = 0;

        public TvHome(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-tv-home");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("tv-home");

            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("tv-home-page");
            var head = new Box(Orientation.HORIZONTAL, 0);
            head.add_css_class("tv-home-head");
            var title = new Label(greeting());
            title.add_css_class("tv-home-title");
            title.hexpand = true;
            title.xalign = 0;
            _clock = new Label("");
            _clock.add_css_class("tv-home-clock");
            head.append(title);
            head.append(_clock);
            page.append(head);

            _resume_title = section_label(_("Resume"));
            page.append(_resume_title);
            _resume = new_row();
            page.append(_resume);
            page.append(section_label(_("Apps")));
            _apps = new_row();
            page.append(_apps);
            set_child(page);

            var app_system = AppSystem.get_default();
            _sig_running = app_system.running_apps_changed.connect(() => fill_resume());
            _sig_apps = app_system.apps_changed.connect(() => fill_apps());
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            update_clock();
            fill_apps();
            fill_resume();
        }

        public override void dispose() {
            var app_system = AppSystem.get_default();
            if (_sig_running != 0) { app_system.disconnect(_sig_running); _sig_running = 0; }
            if (_sig_apps != 0) { app_system.disconnect(_sig_apps); _sig_apps = 0; }
            if (_sig_clock != 0) { SharedClock.get_default().disconnect(_sig_clock); _sig_clock = 0; }
            base.dispose();
        }

        private static string greeting() {
            int h = new DateTime.now_local().get_hour();
            if (h < 12) return _("Good morning");
            if (h < 18) return _("Good afternoon");
            return _("Good evening");
        }

        private Label section_label(string text) {
            var l = new Label(text);
            l.add_css_class("tv-home-section");
            l.xalign = 0;
            return l;
        }

        private FlowBox new_row() {
            var row = new FlowBox();
            row.add_css_class("tv-home-row");
            row.selection_mode = SelectionMode.NONE;
            row.homogeneous = true;
            row.min_children_per_line = 3;
            row.max_children_per_line = 6;
            row.column_spacing = 28;
            row.row_spacing = 28;
            row.activate_on_single_click = true;
            row.child_activated.connect((child) => {
                var action = child.get_data<string>("tv-action");
                var handle = child.get_data<void*>("tv-window");
                if (handle != null) {
                    Singularity.wayland_activate_window(handle);
                    return;
                }
                if (action != null) {
                    var info = new GLib.DesktopAppInfo(action);
                    if (info != null) AppSystem.launch_app(info);
                }
            });
            return row;
        }

        private FlowBoxChild tile(GLib.Icon? icon, string icon_name, string label) {
            var box = new Box(Orientation.VERTICAL, 14);
            box.add_css_class("tv-tile");
            var img = icon != null ? new Image.from_gicon(icon) : new Image.from_icon_name(icon_name);
            img.pixel_size = 112;
            img.add_css_class("tv-tile-icon");
            var name = new Label(label);
            name.add_css_class("tv-tile-label");
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 14;
            box.append(img);
            box.append(name);
            var child = new FlowBoxChild();
            child.child = box;
            child.focusable = true;
            child.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            return child;
        }

        private void fill_apps() {
            Widget? w;
            while ((w = _apps.get_first_child()) != null) _apps.remove(w);
            var settings = new GLib.Settings("dev.sinty.desktop");
            foreach (string id in settings.get_strv("pinned-apps")) {
                var info = new GLib.DesktopAppInfo(id);
                if (info == null || info.get_nodisplay()) continue;
                var child = tile(info.get_icon(), "application-x-executable", info.get_display_name());
                child.set_data<string>("tv-action", id);
                _apps.append(child);
            }
        }

        private void fill_resume() {
            Widget? w;
            while ((w = _resume.get_first_child()) != null) _resume.remove(w);
            int n = 0;
            foreach (var win in AppSystem.get_default().get_mru_windows()) {
                if (n++ >= 6) break;
                var child = tile(win.gicon, win.icon_name, win.title);
                child.set_data<void*>("tv-window", win.handle);
                _resume.append(child);
            }
            _resume.visible = n > 0;
            _resume_title.visible = n > 0;
        }

        private void update_clock() {
            _clock.label = new DateTime.now_local().format("%H:%M");
        }

        public void focus_first() {
            var first = (_resume.visible ? _resume : _apps).get_child_at_index(0);
            if (first != null) first.grab_focus();
        }
    }

    public class WatchFace : Gtk.Window {
        private Label _time;
        private Label _date;
        private ulong _sig_clock = 0;

        public WatchFace(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-watch-face");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("watch-face");

            var face = new Box(Orientation.VERTICAL, 0);
            face.add_css_class("watch-face-dial");
            face.halign = Align.CENTER;
            face.valign = Align.CENTER;
            _date = new Label("");
            _date.add_css_class("watch-face-date");
            _time = new Label("");
            _time.add_css_class("watch-face-time");
            face.append(_date);
            face.append(_time);
            set_child(face);
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            update_clock();
        }

        public override void dispose() {
            if (_sig_clock != 0) { SharedClock.get_default().disconnect(_sig_clock); _sig_clock = 0; }
            base.dispose();
        }

        private void update_clock() {
            var now = new DateTime.now_local();
            _time.label = now.format("%H:%M");
            _date.label = now.format("%a %e").up();
        }
    }

    public class FormShell : Object {
        private const uint ESCAPE_KEYCODE = 1;
        private const int TABLET_DOCK_ICON_SIZE = 64;

        private unowned Gtk.Application _app;
        private PhoneNavBar? _nav = null;
        private TvHome? _tv = null;
        private WatchFace? _watch = null;
        private ulong _sig_opened = 0;
        private bool _keymap_ready = false;

        public signal void home_requested();
        public signal void recents_requested();

        public FormShell(Gtk.Application app) {
            _app = app;
            _sig_opened = AppSystem.get_default().app_opened.connect((handle, app_id) => {
                if (Singularity.FormFactor.current().is_full_screen()) {
                    Idle.add(() => {
                        Singularity.wayland_set_maximized(handle, true);
                        return Source.REMOVE;
                    });
                }
            });
            Singularity.FormFactor.get_default().changed.connect(() => sync());
            sync();
        }

        public static bool wants_panel() {
            var kind = Singularity.FormFactor.current();
            return kind != Singularity.FormFactorKind.TV && kind != Singularity.FormFactorKind.WATCH;
        }

        public static int dock_icon_size(GLib.Settings settings) {
            int size = settings.get_int("dock-icon-size");
            if (Singularity.FormFactor.current() == Singularity.FormFactorKind.TABLET) return int.max(size, TABLET_DOCK_ICON_SIZE);
            return size;
        }

        public static bool wants_dock() {
            var kind = Singularity.FormFactor.current();
            return kind == Singularity.FormFactorKind.DESKTOP || kind == Singularity.FormFactorKind.TABLET;
        }

        public void sync() {
            var kind = Singularity.FormFactor.current();
            if (kind == Singularity.FormFactorKind.PHONE) {
                if (_nav == null) {
                    _nav = new PhoneNavBar(_app);
                    _nav.back_requested.connect(() => go_back());
                    _nav.home_requested.connect(() => home_requested());
                    _nav.recents_requested.connect(() => recents_requested());
                }
                _nav.present();
            } else if (_nav != null) {
                _nav.destroy();
                _nav = null;
            }
            if (kind == Singularity.FormFactorKind.TV) {
                if (_tv == null) _tv = new TvHome(_app);
                _tv.present();
                _tv.focus_first();
            } else if (_tv != null) {
                _tv.destroy();
                _tv = null;
            }
            if (kind == Singularity.FormFactorKind.WATCH) {
                if (_watch == null) _watch = new WatchFace(_app);
                _watch.present();
            } else if (_watch != null) {
                _watch.destroy();
                _watch = null;
            }
            bool maximize = kind.is_full_screen();
            foreach (var win in AppSystem.get_default().get_windows()) {
                if (maximize != win.is_maximized) Singularity.wayland_set_maximized(win.handle, maximize);
            }
        }

        private void go_back() {
            if (!_keymap_ready) {
                var settings = new GLib.Settings("dev.sinty.desktop");
                _keymap_ready = Singularity.osk_set_layout(settings.get_string("xkb-layout"), settings.get_string("xkb-variant"));
            }
            Singularity.osk_press(ESCAPE_KEYCODE, 0);
        }
    }
}
