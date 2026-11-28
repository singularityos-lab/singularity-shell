using Gtk;
using GtkLayerShell;

namespace Singularity {

    internal class HomeDeviceTile : Button {
        private Image _icon;
        private Label _name;
        private Label _state;

        public Home.Device device { get; construct; }

        public HomeDeviceTile(Home.Device device) {
            Object(device: device);
            add_css_class("home-device");
            var box = new Box(Orientation.VERTICAL, 0);
            _icon = new Image.from_icon_name(device.kind.icon_name());
            _icon.add_css_class("home-device-icon");
            _icon.halign = Align.START;
            box.append(_icon);
            var spacer = new Box(Orientation.VERTICAL, 0);
            spacer.vexpand = true;
            box.append(spacer);
            _name = new Label(device.name);
            _name.add_css_class("home-device-name");
            _name.xalign = 0;
            _name.ellipsize = Pango.EllipsizeMode.END;
            box.append(_name);
            _state = new Label("");
            _state.add_css_class("home-device-state");
            _state.xalign = 0;
            _state.ellipsize = Pango.EllipsizeMode.END;
            box.append(_state);
            child = box;
            device.notify.connect(() => sync());
            clicked.connect(() => {
                if (!device.kind.toggles() || !device.reachable) return;
                Home.Hub.get_default().toggle.begin(device);
            });
            sync();
        }

        private void sync() {
            _name.label = device.name;
            _state.label = device.state_label;
            bool lit = device.reachable && device.on && device.kind.toggles();
            if (lit) add_css_class("on");
            else remove_css_class("on");
            if (device.reachable) remove_css_class("offline");
            else add_css_class("offline");
            update_property(Gtk.AccessibleProperty.LABEL, "%s, %s".printf(device.name, device.state_label), -1);
        }
    }

    internal class HomeClimate : Box {
        private const double STEP = 0.5;
        private Label _now;
        private Label _target;
        private Label _room;
        private Home.Device? _device = null;

        public HomeClimate() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("home-card");
            add_css_class("home-climate");
            var heading = new Label(_("Climate"));
            heading.add_css_class("home-card-heading");
            heading.xalign = 0;
            append(heading);
            var row = new Box(Orientation.HORIZONTAL, 0);
            row.vexpand = true;
            var numbers = new Box(Orientation.VERTICAL, 0);
            numbers.hexpand = true;
            numbers.valign = Align.CENTER;
            _now = new Label("");
            _now.add_css_class("home-climate-now");
            _now.xalign = 0;
            _target = new Label("");
            _target.add_css_class("home-climate-target");
            _target.xalign = 0;
            _room = new Label("");
            _room.add_css_class("glance-subtitle");
            _room.xalign = 0;
            numbers.append(_now);
            numbers.append(_target);
            numbers.append(_room);
            row.append(numbers);
            var steps = new Box(Orientation.VERTICAL, 0);
            steps.add_css_class("home-climate-steps");
            steps.valign = Align.CENTER;
            steps.append(step("list-add-symbolic", _("Warmer"), STEP));
            steps.append(step("list-remove-symbolic", _("Cooler"), -STEP));
            row.append(steps);
            append(row);
        }

        public void bind(Home.Device? device) {
            _device = device;
            visible = device != null;
            if (device == null) return;
            device.notify.connect(() => sync());
            sync();
        }

        private Button step(string icon, string label, double delta) {
            var button = new Button();
            button.child = new Image.from_icon_name(icon);
            button.add_css_class("glance-round");
            button.tooltip_text = label;
            button.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            button.clicked.connect(() => {
                if (_device == null || _device.target.is_nan()) return;
                var attrs = new HashTable<string, Variant>(str_hash, str_equal);
                attrs["target"] = new Variant.double(_device.target + delta);
                Home.Hub.get_default().set_device.begin(_device, attrs);
            });
            return button;
        }

        private void sync() {
            if (_device == null) return;
            _now.label = _device.temperature.is_nan() ? "--" : "%.1f°".printf(_device.temperature);
            _target.label = _device.target.is_nan() ? "" : _("Heating to %.1f°").printf(_device.target);
            var room = room_name(_device.room);
            _room.label = room;
            _room.visible = room != "";
        }

        internal static string room_name(string id) {
            foreach (var r in Home.Hub.get_default().rooms) {
                if (r.id == id) return r.name;
            }
            return "";
        }
    }

    internal class HomeCamera : Box {
        private Picture _picture;
        private Label _name;
        private Home.Device? _device = null;

        public signal void open(Home.Device camera);

        public HomeCamera() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("home-card");
            add_css_class("home-camera");
            overflow = Overflow.HIDDEN;
            var stage = new Overlay();
            stage.vexpand = true;
            _picture = new Picture();
            _picture.content_fit = ContentFit.COVER;
            _picture.can_shrink = true;
            _picture.add_css_class("home-camera-picture");
            stage.child = _picture;
            var label = new Box(Orientation.HORIZONTAL, 0);
            label.add_css_class("home-camera-label");
            label.valign = Align.END;
            label.halign = Align.START;
            var dot = new Box(Orientation.HORIZONTAL, 0);
            dot.add_css_class("home-live-dot");
            dot.valign = Align.CENTER;
            label.append(dot);
            _name = new Label("");
            label.append(_name);
            stage.add_overlay(label);
            append(stage);
            var click = new GestureClick();
            click.released.connect(() => {
                if (_device != null) open(_device);
            });
            add_controller(click);
        }

        public void bind(Home.Device? device) {
            _device = device;
            visible = device != null;
            if (device == null) return;
            device.notify["snapshot"].connect(() => load());
            _name.label = device.name;
            load();
        }

        private void load() {
            if (_device == null || _device.snapshot == "") {
                _picture.paintable = null;
                return;
            }
            _picture.file = File.new_for_path(_device.snapshot);
        }
    }

    internal class HomeDoorbell : Box {
        private Picture _picture;
        private Label _title;
        private Button _unlock;
        private Home.Device? _lock = null;
        private uint _timeout = 0;

        public HomeDoorbell() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("home-doorbell");
            visible = false;
            _title = new Label("");
            _title.add_css_class("home-doorbell-title");
            append(_title);
            _picture = new Picture();
            _picture.content_fit = ContentFit.COVER;
            _picture.can_shrink = true;
            _picture.vexpand = true;
            _picture.add_css_class("home-doorbell-picture");
            append(_picture);
            var actions = new Box(Orientation.HORIZONTAL, 0);
            actions.add_css_class("home-doorbell-actions");
            actions.halign = Align.CENTER;
            var talk = action("audio-input-microphone-symbolic", _("Talk"), "suggested-action");
            _unlock = action("changes-allow-symbolic", _("Unlock Door"), "");
            _unlock.clicked.connect(() => {
                if (_lock == null) return;
                var attrs = new HashTable<string, Variant>(str_hash, str_equal);
                attrs["on"] = new Variant.boolean(false);
                Home.Hub.get_default().set_device.begin(_lock, attrs);
            });
            var dismiss = action("window-close-symbolic", _("Dismiss"), "");
            dismiss.clicked.connect(() => hide_bell());
            actions.append(talk);
            actions.append(_unlock);
            actions.append(dismiss);
            append(actions);
            Home.Hub.get_default().doorbell.connect((camera, snapshot) => ring(camera, snapshot));
        }

        private static Button action(string icon, string label, string css) {
            var box = new Box(Orientation.HORIZONTAL, 0);
            box.append(new Image.from_icon_name(icon));
            box.append(new Label(label));
            var button = new Button();
            button.child = box;
            button.add_css_class("home-pill");
            if (css != "") button.add_css_class(css);
            return button;
        }

        public void ring(Home.Device camera, string snapshot) {
            _title.label = _("Someone is at %s").printf(camera.name);
            string path = snapshot != "" ? snapshot : camera.snapshot;
            _picture.file = path != "" ? File.new_for_path(path) : null;
            _lock = Home.Hub.get_default().first_of(Home.DeviceKind.LOCK);
            _unlock.visible = _lock != null && _lock.reachable;
            visible = true;
            if (_timeout != 0) Source.remove(_timeout);
            _timeout = Timeout.add_seconds(60, () => {
                _timeout = 0;
                hide_bell();
                return Source.REMOVE;
            });
        }

        private void hide_bell() {
            visible = false;
            if (_timeout != 0) {
                Source.remove(_timeout);
                _timeout = 0;
            }
        }
    }

    internal class HomeNight : Box {
        private Label _clock;
        private Label _date;

        public HomeNight() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("home-night");
            visible = false;
            valign = Align.FILL;
            var center = new Box(Orientation.VERTICAL, 0);
            center.vexpand = true;
            center.valign = Align.CENTER;
            _clock = new Label("");
            _clock.add_css_class("home-night-clock");
            _date = new Label("");
            _date.add_css_class("home-night-date");
            center.append(_clock);
            center.append(_date);
            append(center);
        }

        public void tick() {
            var now = new DateTime.now_local();
            _clock.label = now.format("%H:%M");
            _date.label = now.format(_("%A %e %B"));
        }
    }

    public class SmartHome : Gtk.Window {
        private const string NIGHT_KEY = "smart-display-night-mode";
        private const int NIGHT_IDLE_SECONDS = 120;
        private const int NIGHT_FROM = 22;
        private const int NIGHT_UNTIL = 7;
        private const int GUTTER = 48;

        private Label _greeting;
        private Label _clock;
        private Label _date;
        private Box _scenes;
        private Box _rooms;
        private FlowBox _devices;
        private HomeClimate _climate;
        private HomeCamera _camera;
        private HomeDoorbell _doorbell;
        private HomeNight _night;
        private Label _empty;
        private string _room = "";
        private GLib.Settings? _settings = null;
        private ulong _sig_clock = 0;
        private ulong _sig_hub = 0;
        private int64 _last_touch = 0;

        public SmartHome(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-smart-home");
            set_layer(this, GtkLayerShell.Layer.BOTTOM);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.ON_DEMAND);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("smart-home");
            var area = monitor.geometry;
            if (area.height < 700) add_css_class("home-compact");

            var schema = SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true);
            if (schema != null && schema.has_key(NIGHT_KEY)) {
                _settings = new GLib.Settings("dev.sinty.desktop");
                _settings.changed[NIGHT_KEY].connect(() => sync_night());
            }

            var stage = new Overlay();
            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("home-page");
            page.append(build_head());

            var body = new Box(Orientation.HORIZONTAL, 0);
            body.add_css_class("home-body");
            body.vexpand = true;
            var main = new Box(Orientation.VERTICAL, 0);
            main.hexpand = true;
            main.add_css_class("home-main");
            main.append(section(_("Scenes")));
            _scenes = new Box(Orientation.HORIZONTAL, 0);
            _scenes.add_css_class("home-scenes");
            main.append(scroller(_scenes));
            _rooms = new Box(Orientation.HORIZONTAL, 0);
            _rooms.add_css_class("home-rooms");
            main.append(scroller(_rooms));
            _devices = new FlowBox();
            _devices.add_css_class("home-devices");
            _devices.selection_mode = SelectionMode.NONE;
            _devices.homogeneous = true;
            _devices.min_children_per_line = 2;
            _devices.max_children_per_line = 3;
            _devices.valign = Align.START;
            var flow = new Box(Orientation.VERTICAL, 0);
            flow.append(_devices);
            _empty = new Label(_("No devices yet. Add them from the Home settings."));
            _empty.add_css_class("glance-subtitle");
            _empty.xalign = 0;
            flow.append(_empty);
            flow.append(section(_("Widgets")));
            flow.append(new TvWidgetRow(0));
            var dev_scroll = new ScrolledWindow();
            dev_scroll.hscrollbar_policy = PolicyType.NEVER;
            dev_scroll.vexpand = true;
            dev_scroll.child = flow;
            main.append(dev_scroll);
            body.append(main);

            var side = new Box(Orientation.VERTICAL, 0);
            side.add_css_class("home-side");
            _camera = new HomeCamera();
            _camera.open.connect((camera) => _doorbell.ring(camera, camera.snapshot));
            side.append(_camera);
            _climate = new HomeClimate();
            side.append(_climate);
            side.append(new GlanceMedia(false, 96, "home-card"));
            body.append(side);
            page.append(body);
            stage.child = page;

            _night = new HomeNight();
            stage.add_overlay(_night);
            _doorbell = new HomeDoorbell();
            stage.add_overlay(_doorbell);
            child = stage;

            var touch = new GestureClick();
            touch.propagation_phase = PropagationPhase.CAPTURE;
            touch.pressed.connect(() => {
                _last_touch = get_monotonic_time();
                if (_night.visible) {
                    _night.visible = false;
                    touch.set_state(EventSequenceState.CLAIMED);
                }
            });
            ((Widget) this).add_controller(touch);
            _last_touch = get_monotonic_time();

            _sig_hub = Home.Hub.get_default().changed.connect(() => fill());
            _sig_clock = SharedClock.get_default().minute_changed.connect(() => tick());
            fill();
            tick();
        }

        public override void dispose() {
            if (_sig_clock != 0) {
                SharedClock.get_default().disconnect(_sig_clock);
                _sig_clock = 0;
            }
            if (_sig_hub != 0) {
                Home.Hub.get_default().disconnect(_sig_hub);
                _sig_hub = 0;
            }
            base.dispose();
        }

        private Widget build_head() {
            var head = new Box(Orientation.HORIZONTAL, 0);
            head.add_css_class("home-head");
            var left = new Box(Orientation.VERTICAL, 0);
            left.hexpand = true;
            _greeting = new Label("");
            _greeting.add_css_class("home-greeting");
            _greeting.xalign = 0;
            _date = new Label("");
            _date.add_css_class("home-date");
            _date.xalign = 0;
            left.append(_greeting);
            left.append(_date);
            head.append(left);
            _clock = new Label("");
            _clock.add_css_class("home-clock");
            _clock.valign = Align.CENTER;
            head.append(_clock);
            return head;
        }

        private static Label section(string text) {
            var label = new Label(text);
            label.add_css_class("home-section");
            label.xalign = 0;
            return label;
        }

        private static ScrolledWindow scroller(Widget child) {
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.EXTERNAL;
            scroll.vscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.child = child;
            return scroll;
        }

        private void tick() {
            var now = new DateTime.now_local();
            _clock.label = now.format("%H:%M");
            _date.label = now.format(_("%A %e %B"));
            int hour = now.get_hour();
            if (hour < 12) _greeting.label = _("Good morning");
            else if (hour < 18) _greeting.label = _("Good afternoon");
            else _greeting.label = _("Good evening");
            _night.tick();
            sync_night();
        }

        private string night_mode() {
            return _settings != null ? _settings.get_string(NIGHT_KEY) : "auto";
        }

        private void sync_night() {
            string mode = night_mode();
            if (mode == "always") {
                _night.visible = true;
                return;
            }
            if (mode == "never") {
                _night.visible = false;
                return;
            }
            int hour = new DateTime.now_local().get_hour();
            bool night_hours = hour >= NIGHT_FROM || hour < NIGHT_UNTIL;
            bool idle = (get_monotonic_time() - _last_touch) / 1000000 >= NIGHT_IDLE_SECONDS;
            if (night_hours && idle && !_doorbell.visible) _night.visible = true;
        }

        private void fill() {
            var hub = Home.Hub.get_default();
            clear(_scenes);
            foreach (var scene in hub.scenes) {
                var box = new Box(Orientation.HORIZONTAL, 0);
                box.append(new Image.from_icon_name(scene.icon != "" ? scene.icon : "starred-symbolic"));
                box.append(new Label(scene.name));
                var button = new Button();
                button.child = box;
                button.add_css_class("home-pill");
                button.add_css_class("home-scene");
                button.clicked.connect(() => hub.activate_scene.begin(scene));
                _scenes.append(button);
            }
            _scenes.visible = hub.scenes.length > 0;

            clear(_rooms);
            ToggleButton? group = null;
            var all = room_chip("", _("All"), ref group);
            _rooms.append(all);
            foreach (var room in hub.rooms) _rooms.append(room_chip(room.id, room.name, ref group));
            _rooms.visible = hub.rooms.length > 1;

            fill_devices();
            _climate.bind(hub.first_of(Home.DeviceKind.THERMOSTAT));
            _camera.bind(hub.first_of(Home.DeviceKind.CAMERA));
        }

        private ToggleButton room_chip(string id, string name, ref ToggleButton? group) {
            var chip = new ToggleButton.with_label(name);
            chip.add_css_class("home-pill");
            chip.add_css_class("home-room");
            if (group != null) chip.group = group;
            else group = chip;
            chip.active = id == _room;
            chip.toggled.connect(() => {
                if (!chip.active) return;
                _room = id;
                fill_devices();
            });
            return chip;
        }

        private void fill_devices() {
            Widget? child;
            while ((child = _devices.get_first_child()) != null) _devices.remove(child);
            int shown = 0;
            foreach (var device in Home.Hub.get_default().devices) {
                if (device.kind == Home.DeviceKind.CAMERA || device.kind == Home.DeviceKind.THERMOSTAT) continue;
                if (_room != "" && device.room != _room) continue;
                _devices.append(new HomeDeviceTile(device));
                shown++;
            }
            _empty.visible = shown == 0;
            _devices.visible = shown > 0;
        }

        private static void clear(Box box) {
            Widget? child;
            while ((child = box.get_first_child()) != null) box.remove(child);
        }
    }
}
