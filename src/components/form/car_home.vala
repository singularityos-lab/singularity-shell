using Gtk;
using GtkLayerShell;

namespace Singularity {

    internal class CarNavCard : Box {
        private Image _maneuver;
        private Label _distance;
        private Label _instruction;
        private Label _street;
        private Label _destination;
        private Label _arrival;
        private Label _remaining;
        private Box _route;
        private Box _idle;
        private ulong _sig = 0;

        public signal void open_maps();

        public CarNavCard() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("car-card");
            add_css_class("car-nav-card");
            hexpand = true;
            vexpand = true;

            _route = new Box(Orientation.VERTICAL, 0);
            _route.vexpand = true;
            _destination = new Label("");
            _destination.add_css_class("car-nav-destination");
            _destination.xalign = 0;
            _destination.ellipsize = Pango.EllipsizeMode.END;
            _route.append(_destination);
            var focus = new Box(Orientation.VERTICAL, 0);
            focus.vexpand = true;
            focus.valign = Align.CENTER;
            var turn = new Box(Orientation.HORIZONTAL, 0);
            turn.add_css_class("car-nav-turn");
            _maneuver = new Image();
            _maneuver.add_css_class("car-nav-maneuver");
            turn.append(_maneuver);
            var words = new Box(Orientation.VERTICAL, 0);
            words.valign = Align.CENTER;
            _distance = new Label("");
            _distance.add_css_class("car-nav-distance");
            _distance.xalign = 0;
            _instruction = new Label("");
            _instruction.add_css_class("car-nav-instruction");
            _instruction.xalign = 0;
            _instruction.wrap = true;
            _instruction.lines = 2;
            _instruction.ellipsize = Pango.EllipsizeMode.END;
            words.append(_distance);
            words.append(_instruction);
            turn.append(words);
            focus.append(turn);
            _street = new Label("");
            _street.add_css_class("car-nav-street");
            _street.xalign = 0;
            _street.ellipsize = Pango.EllipsizeMode.END;
            focus.append(_street);
            _route.append(focus);
            var trip = new Box(Orientation.HORIZONTAL, 0);
            trip.add_css_class("car-nav-trip");
            _arrival = new Label("");
            _arrival.add_css_class("car-nav-arrival");
            _arrival.hexpand = true;
            _arrival.xalign = 0;
            _remaining = new Label("");
            _remaining.add_css_class("car-nav-remaining");
            trip.append(_arrival);
            trip.append(_remaining);
            _route.append(trip);
            append(_route);

            _idle = new Box(Orientation.VERTICAL, 0);
            _idle.vexpand = true;
            _idle.valign = Align.CENTER;
            var where = new Label(_("Where to?"));
            where.add_css_class("car-card-title");
            where.xalign = 0;
            _idle.append(where);
            var hint = new Label(_("Ask for a place or open Maps to start a route."));
            hint.add_css_class("car-card-subtitle");
            hint.xalign = 0;
            hint.wrap = true;
            _idle.append(hint);
            var maps = new Button.with_label(_("Open Maps"));
            maps.add_css_class("suggested-action");
            maps.add_css_class("car-pill");
            maps.halign = Align.START;
            maps.clicked.connect(() => open_maps());
            _idle.append(maps);
            append(_idle);

            var click = new GestureClick();
            click.released.connect(() => {
                if (_route.visible) open_maps();
            });
            _route.add_controller(click);

            _sig = NavigationStatus.get_default().changed.connect(() => update());
            update();
        }

        public override void dispose() {
            if (_sig != 0) {
                NavigationStatus.get_default().disconnect(_sig);
                _sig = 0;
            }
            base.dispose();
        }

        private void update() {
            var nav = NavigationStatus.get_default();
            _route.visible = nav.active;
            _idle.visible = !nav.active;
            if (!nav.active) return;
            _maneuver.icon_name = nav.maneuver_icon;
            _distance.label = NavigationStatus.format_distance(nav.maneuver_distance);
            _instruction.label = nav.instruction;
            _destination.label = nav.destination != "" ? _("To %s").printf(nav.destination) : "";
            _destination.visible = nav.destination != "";
            _street.label = nav.street;
            _street.visible = nav.street != "";
            string eta = nav.arrival_label;
            _arrival.label = eta != "" ? _("Arrive at %s").printf(eta) : "";
            _remaining.label = NavigationStatus.format_distance(nav.remaining_distance);
        }
    }

    internal class CarGuidanceBanner : Box {
        private Image _maneuver;
        private Label _distance;
        private Label _instruction;
        private ulong _sig = 0;

        public bool wanted { get; set; default = true; }

        public CarGuidanceBanner() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            add_css_class("car-guidance");
            halign = Align.FILL;
            valign = Align.START;
            _maneuver = new Image();
            _maneuver.add_css_class("car-guidance-maneuver");
            append(_maneuver);
            _distance = new Label("");
            _distance.add_css_class("car-guidance-distance");
            append(_distance);
            _instruction = new Label("");
            _instruction.add_css_class("car-guidance-instruction");
            _instruction.hexpand = true;
            _instruction.xalign = 0;
            _instruction.ellipsize = Pango.EllipsizeMode.END;
            append(_instruction);
            _sig = NavigationStatus.get_default().changed.connect(() => update());
            notify["wanted"].connect(() => update());
            update();
        }

        public override void dispose() {
            if (_sig != 0) {
                NavigationStatus.get_default().disconnect(_sig);
                _sig = 0;
            }
            base.dispose();
        }

        private void update() {
            var nav = NavigationStatus.get_default();
            visible = wanted && nav.active;
            if (!visible) return;
            _maneuver.icon_name = nav.maneuver_icon;
            _distance.label = NavigationStatus.format_distance(nav.maneuver_distance);
            _instruction.label = nav.instruction;
        }
    }

    internal class CarMessages : Box {
        private const int SHOWN = 3;
        private Box _list;
        private Label _empty;
        private ulong _sig = 0;

        public CarMessages() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("car-card");
            add_css_class("car-messages");
            hexpand = true;
            vexpand = true;
            var title = new Label(_("Recent"));
            title.add_css_class("car-card-heading");
            title.xalign = 0;
            append(title);
            _list = new Box(Orientation.VERTICAL, 0);
            _list.vexpand = true;
            append(_list);
            _empty = new Label(_("No new messages"));
            _empty.add_css_class("car-card-subtitle");
            _empty.xalign = 0;
            _empty.vexpand = true;
            _empty.valign = Align.CENTER;
            append(_empty);
            var manager = SystemMonitor.get_default().notifications;
            _sig = manager.history_changed.connect(() => fill());
            fill();
        }

        public override void dispose() {
            if (_sig != 0) {
                SystemMonitor.get_default().notifications.disconnect(_sig);
                _sig = 0;
            }
            base.dispose();
        }

        private void fill() {
            Widget? child;
            while ((child = _list.get_first_child()) != null) _list.remove(child);
            int shown = 0;
            foreach (var n in SystemMonitor.get_default().notifications.get_history()) {
                if (shown >= SHOWN) break;
                _list.append(row(n));
                shown++;
            }
            _empty.visible = shown == 0;
            _list.visible = shown > 0;
        }

        private Widget row(Notification n) {
            var box = new Box(Orientation.HORIZONTAL, 0);
            box.add_css_class("car-message");
            var icon = new Image();
            icon.add_css_class("car-message-icon");
            load_notification_icon(icon, n.icon, n.app_name);
            box.append(icon);
            var text = new Box(Orientation.VERTICAL, 0);
            text.hexpand = true;
            text.valign = Align.CENTER;
            var who = new Label(n.summary);
            who.add_css_class("car-message-title");
            who.xalign = 0;
            who.ellipsize = Pango.EllipsizeMode.END;
            var what = new Label(n.masked_body());
            what.add_css_class("car-message-body");
            what.xalign = 0;
            what.ellipsize = Pango.EllipsizeMode.END;
            text.append(who);
            text.append(what);
            box.append(text);
            return box;
        }
    }

    internal class CarDialer : Box {
        private Label _number;
        private Label _error;

        public CarDialer() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            add_css_class("car-dialer");
            hexpand = true;
            vexpand = true;
            var left = new Box(Orientation.VERTICAL, 0);
            left.hexpand = true;
            left.valign = Align.CENTER;
            _number = new Label("");
            _number.add_css_class("car-dialer-number");
            _number.xalign = 0;
            _number.ellipsize = Pango.EllipsizeMode.START;
            left.append(_number);
            var hint = new Label(_("Enter a number or say who to call"));
            hint.add_css_class("glance-subtitle");
            hint.xalign = 0;
            hint.wrap = true;
            left.append(hint);
            _number.notify["label"].connect(() => hint.visible = _number.label == "");
            _error = new Label("");
            _error.add_css_class("car-card-subtitle");
            _error.xalign = 0;
            _error.wrap = true;
            _error.visible = false;
            left.append(_error);
            var actions = new Box(Orientation.HORIZONTAL, 0);
            actions.add_css_class("car-dialer-actions");
            var call = new Button();
            call.child = new Image.from_icon_name("call-start-symbolic");
            call.add_css_class("car-call-accept");
            call.add_css_class("car-round");
            call.tooltip_text = _("Call");
            call.update_property(Gtk.AccessibleProperty.LABEL, _("Call"), -1);
            call.clicked.connect(() => dial());
            var erase = new Button();
            erase.child = new Image.from_icon_name("edit-clear-symbolic");
            erase.add_css_class("car-round");
            erase.tooltip_text = _("Delete");
            erase.update_property(Gtk.AccessibleProperty.LABEL, _("Delete"), -1);
            erase.clicked.connect(() => {
                string text = _number.label;
                if (text.length > 0) _number.label = text.substring(0, text.length - 1);
            });
            actions.append(call);
            actions.append(erase);
            left.append(actions);
            append(left);

            var keys = new Grid();
            keys.add_css_class("car-keypad");
            keys.halign = Align.END;
            keys.valign = Align.CENTER;
            keys.row_homogeneous = true;
            keys.column_homogeneous = true;
            string[] digits = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#" };
            for (int i = 0; i < digits.length; i++) {
                string d = digits[i];
                var key = new Button.with_label(d);
                key.add_css_class("car-key");
                key.clicked.connect(() => _number.label += d);
                keys.attach(key, i % 3, i / 3);
            }
            append(keys);
        }

        private void dial() {
            string number = _number.label.strip();
            if (number == "") return;
            _error.visible = false;
            var voice = Telephony.Voice.get_default();
            voice.start.begin((obj, res) => {
                voice.start.end(res);
                voice.dial.begin(number, (o, r) => {
                    try {
                        voice.dial.end(r);
                        _number.label = "";
                    } catch (Error e) {
                        _error.label = e.message;
                        _error.visible = true;
                    }
                });
            });
        }
    }

    internal class CarCallScreen : Box {
        private Label _who;
        private Label _state;
        private Button _accept;
        private Button _mute;
        private Telephony.Call? _call = null;
        private uint _tick = 0;

        public signal void finished();

        public CarCallScreen() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("car-call");
            hexpand = true;
            vexpand = true;
            visible = false;
            var avatar = new Image.from_icon_name("avatar-default-symbolic");
            avatar.add_css_class("car-call-avatar");
            avatar.vexpand = true;
            avatar.valign = Align.END;
            append(avatar);
            _who = new Label("");
            _who.add_css_class("car-call-who");
            _who.ellipsize = Pango.EllipsizeMode.END;
            append(_who);
            _state = new Label("");
            _state.add_css_class("car-call-state");
            append(_state);
            var actions = new Box(Orientation.HORIZONTAL, 0);
            actions.add_css_class("car-call-actions");
            actions.halign = Align.CENTER;
            actions.vexpand = true;
            actions.valign = Align.START;
            _mute = round("microphone-sensitivity-muted-symbolic", _("Mute"), "car-call-mute");
            _mute.clicked.connect(() => {
                if (_call == null) return;
                Telephony.Voice.get_default().set_mute.begin(_call, !_call.muted);
            });
            _accept = round("call-start-symbolic", _("Answer"), "car-call-accept");
            _accept.clicked.connect(() => {
                if (_call != null) Telephony.Voice.get_default().accept.begin(_call);
            });
            var hang = round("call-stop-symbolic", _("End Call"), "car-call-end");
            hang.clicked.connect(() => {
                if (_call != null) Telephony.Voice.get_default().hang_up.begin(_call);
            });
            actions.append(_mute);
            actions.append(_accept);
            actions.append(hang);
            append(actions);

            var voice = Telephony.Voice.get_default();
            voice.call_added.connect((call) => show_call(call));
            voice.call_changed.connect((call) => {
                if (call == _call || _call == null) show_call(call);
            });
            voice.start.begin();
        }

        public override void dispose() {
            stop_ticking();
            base.dispose();
        }

        private static Button round(string icon, string label, string css) {
            var button = new Button();
            button.child = new Image.from_icon_name(icon);
            button.add_css_class("car-round");
            button.add_css_class(css);
            button.tooltip_text = label;
            button.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            return button;
        }

        private void show_call(Telephony.Call call) {
            if (!call.state.is_live()) {
                if (call == _call) {
                    _call = null;
                    stop_ticking();
                    visible = false;
                    finished();
                }
                return;
            }
            _call = call;
            visible = true;
            _who.label = call.number != "" ? call.number : _("Unknown Caller");
            _accept.visible = call.state == Telephony.CallState.RINGING_IN || call.state == Telephony.CallState.WAITING;
            _mute.visible = call.can_mute && !_accept.visible;
            if (call.muted) _mute.add_css_class("active");
            else _mute.remove_css_class("active");
            update_state();
            if (call.state == Telephony.CallState.ACTIVE && _tick == 0) {
                _tick = Timeout.add_seconds(1, () => {
                    update_state();
                    return Source.CONTINUE;
                });
            }
        }

        private void update_state() {
            if (_call == null) return;
            switch (_call.state) {
                case Telephony.CallState.RINGING_IN:
                case Telephony.CallState.WAITING:
                    _state.label = _("Incoming call");
                    break;
                case Telephony.CallState.DIALING:
                case Telephony.CallState.RINGING_OUT:
                    _state.label = _("Calling…");
                    break;
                case Telephony.CallState.HELD:
                    _state.label = _("On hold");
                    break;
                default:
                    int64 secs = _call.answered > 0 ? get_real_time() / 1000000 - _call.answered : 0;
                    _state.label = "%d:%02d".printf((int) (secs / 60), (int) (secs % 60));
                    break;
            }
        }

        private void stop_ticking() {
            if (_tick != 0) {
                Source.remove(_tick);
                _tick = 0;
            }
        }
    }

    public class CarHome : Gtk.Window {
        private const string MAPS_APP = "dev.sinty.maps.desktop";
        private const string[] CAR_CATEGORIES = { "Audio", "Music", "Player", "Maps", "Telephony", "Weather", "News", "Feed" };
        private const string FORM_FACTORS_KEY = "X-Sinty-FormFactors";

        private Stack _pages;
        private Label _clock;
        private CarGuidanceBanner _banner;
        private CarCallScreen _call;
        private FlowBox _apps;
        private Gee.HashMap<string, ToggleButton> _rail_buttons = new Gee.HashMap<string, ToggleButton>();
        private ulong _sig_clock = 0;
        private int _cover;

        public CarHome(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-car-home");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("car-home");
            var area = monitor.geometry;
            add_css_class(size_class(area.height));
            _cover = area.height < 600 ? 112 : (area.height < 900 ? 168 : 248);

            var root = new Box(Orientation.HORIZONTAL, 0);
            root.append(build_rail());

            var content = new Overlay();
            content.hexpand = true;
            content.vexpand = true;
            var column = new Box(Orientation.VERTICAL, 0);
            _pages = new Stack();
            _pages.transition_type = StackTransitionType.CROSSFADE;
            _pages.add_css_class("car-pages");
            _pages.add_named(build_dashboard(), "home");
            var media = new GlanceMedia(true, _cover * 2, "car-media-page");
            _pages.add_named(media, "media");
            _pages.add_named(build_phone(), "phone");
            _pages.add_named(build_apps(), "apps");
            _banner = new CarGuidanceBanner();
            column.append(_banner);
            _pages.vexpand = true;
            column.append(_pages);
            content.child = column;
            _call = new CarCallScreen();
            _call.notify["visible"].connect(() => _banner.wanted = !_call.visible && _pages.visible_child_name != "home");
            content.add_overlay(_call);
            root.append(content);
            child = root;

            _pages.notify["visible-child-name"].connect(() => {
                _banner.wanted = !_call.visible && _pages.visible_child_name != "home";
                sync_rail();
            });
            show_page("home");
        }

        public override void dispose() {
            if (_sig_clock != 0) {
                SharedClock.get_default().disconnect(_sig_clock);
                _sig_clock = 0;
            }
            base.dispose();
        }

        private static string size_class(int height) {
            if (height < 600) return "car-small";
            if (height < 900) return "car-medium";
            return "car-large";
        }

        public void show_page(string name) {
            _pages.visible_child_name = name;
            _banner.wanted = !_call.visible && name != "home";
            sync_rail();
        }

        private void sync_rail() {
            foreach (var entry in _rail_buttons.entries) entry.value.active = entry.key == _pages.visible_child_name;
        }

        private Widget build_rail() {
            var rail = new Box(Orientation.VERTICAL, 0);
            rail.add_css_class("car-rail");
            _clock = new Label("");
            _clock.add_css_class("car-clock");
            rail.append(_clock);
            update_clock();
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => update_clock());
            rail.append(rail_button("home", "go-home-symbolic", _("Home")));
            var maps = rail_action("mark-location-symbolic", _("Maps"));
            maps.clicked.connect(() => open_maps());
            rail.append(maps);
            rail.append(rail_button("media", "audio-x-generic-symbolic", _("Music")));
            rail.append(rail_button("phone", "call-start-symbolic", _("Phone")));
            rail.append(rail_button("apps", "view-app-grid-symbolic", _("Apps")));
            var spacer = new Box(Orientation.VERTICAL, 0);
            spacer.vexpand = true;
            rail.append(spacer);
            var voice = rail_action("audio-input-microphone-symbolic", _("Voice"));
            voice.add_css_class("car-voice");
            voice.clicked.connect(() => SystemMonitor.get_default().shortcuts.execute_action("toggle_agent"));
            rail.append(voice);
            return rail;
        }

        private void update_clock() {
            _clock.label = new DateTime.now_local().format("%H:%M");
        }

        private ToggleButton rail_button(string page, string icon, string label) {
            var button = new ToggleButton();
            button.child = new Image.from_icon_name(icon);
            button.add_css_class("car-rail-button");
            button.tooltip_text = label;
            button.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            button.clicked.connect(() => show_page(page));
            _rail_buttons[page] = button;
            return button;
        }

        private Button rail_action(string icon, string label) {
            var button = new Button();
            button.child = new Image.from_icon_name(icon);
            button.add_css_class("car-rail-button");
            button.tooltip_text = label;
            button.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            return button;
        }

        private Widget build_dashboard() {
            var grid = new Box(Orientation.HORIZONTAL, 0);
            grid.add_css_class("car-dashboard");
            var nav = new CarNavCard();
            nav.open_maps.connect(() => open_maps());
            grid.append(nav);
            var side = new Box(Orientation.VERTICAL, 0);
            side.add_css_class("car-side");
            side.hexpand = true;
            var media = new GlanceMedia(false, _cover, "car-card");
            media.expand.connect(() => show_page("media"));
            side.append(media);
            side.append(new CarMessages());
            grid.append(side);
            return grid;
        }

        private Widget build_phone() {
            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("car-page");
            page.append(new CarDialer());
            return page;
        }

        private Widget build_apps() {
            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("car-page");
            _apps = new FlowBox();
            _apps.add_css_class("car-apps");
            _apps.selection_mode = SelectionMode.NONE;
            _apps.homogeneous = true;
            _apps.activate_on_single_click = true;
            _apps.valign = Align.START;
            _apps.child_activated.connect((child) => {
                var id = child.get_data<string>("car-app");
                var info = id != null ? new GLib.DesktopAppInfo(id) : null;
                if (info != null) AppSystem.launch_app(info);
            });
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = _apps;
            page.append(scroll);
            fill_apps();
            AppSystem.get_default().apps_changed.connect(() => fill_apps());
            return page;
        }

        private void fill_apps() {
            Widget? child;
            while ((child = _apps.get_first_child()) != null) _apps.remove(child);
            var list = new GLib.List<GLib.DesktopAppInfo>();
            foreach (var app in GLib.AppInfo.get_all()) {
                var info = app as GLib.DesktopAppInfo;
                if (info != null && info.should_show() && for_car(info)) list.insert_sorted(info, (a, b) => a.get_display_name().collate(b.get_display_name()));
            }
            foreach (var info in list) {
                var tile = new Box(Orientation.VERTICAL, 0);
                tile.add_css_class("car-app");
                var icon = new Image();
                icon.gicon = info.get_icon() ?? new ThemedIcon("application-x-executable");
                icon.add_css_class("car-app-icon");
                tile.append(icon);
                var name = new Label(info.get_display_name());
                name.add_css_class("car-app-name");
                name.ellipsize = Pango.EllipsizeMode.END;
                tile.append(name);
                var item = new FlowBoxChild();
                item.child = tile;
                item.set_data<string>("car-app", info.get_id());
                item.update_property(Gtk.AccessibleProperty.LABEL, info.get_display_name(), -1);
                _apps.append(item);
            }
        }

        private static bool for_car(GLib.DesktopAppInfo info) {
            if (info.has_key(FORM_FACTORS_KEY)) {
                foreach (var f in info.get_string(FORM_FACTORS_KEY).split(";")) {
                    if (f.strip() == "car") return true;
                }
                return false;
            }
            string? cats = info.get_categories();
            if (cats == null) return false;
            foreach (var c in cats.split(";")) {
                if (c in CAR_CATEGORIES) return true;
            }
            return false;
        }

        private void open_maps() {
            var info = new GLib.DesktopAppInfo(MAPS_APP);
            if (info != null) AppSystem.launch_app(info);
        }
    }
}
