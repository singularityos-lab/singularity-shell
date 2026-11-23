using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class GameOverlay : Gtk.Window {
        private const int NOTIFICATION_COUNT = 3;

        private static GameOverlay? instance = null;
        private static int64 playing_since = 0;

        private Revealer _top;
        private Revealer _bottom;
        private Box _notes;
        private Label _clock;
        private Label _date;
        private Label _battery;
        private Label _app_title;
        private Label _app_sub;
        private Image _app_icon;
        private Button _first_tile;
        private uint _clock_id = 0;
        private bool _closing = false;
        private GLib.Settings _settings;

        public static void setup(Gtk.Application app) {
            SystemMonitor.get_default().shortcuts.game_overlay_triggered.connect(() => {
                if (instance == null) instance = new GameOverlay(app);
                instance.toggle();
            });
            AppSystem.get_default().any_fullscreen_changed.connect(() => {
                if (AppSystem.get_default().is_focused_window_fullscreen()) {
                    if (playing_since == 0) playing_since = GLib.get_monotonic_time();
                } else {
                    playing_since = 0;
                }
            });
        }

        public GameOverlay(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-game-overlay");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("game-overlay");
            _settings = new GLib.Settings("dev.sinty.desktop");

            var root = new Box(Orientation.VERTICAL, 0);
            root.add_css_class("game-overlay-stage");

            _top = new Revealer();
            _top.transition_type = RevealerTransitionType.SLIDE_DOWN;
            _top.transition_duration = Singularity.Motion.Duration.LARGE;
            _top.child = build_top();
            root.append(_top);

            var spacer = new Box(Orientation.VERTICAL, 0);
            spacer.vexpand = true;
            var dismiss = new GestureClick();
            dismiss.released.connect(() => close_overlay());
            spacer.add_controller(dismiss);
            root.append(spacer);

            _bottom = new Revealer();
            _bottom.transition_type = RevealerTransitionType.SLIDE_UP;
            _bottom.transition_duration = Singularity.Motion.Duration.LARGE;
            _bottom.child = build_bottom();
            root.append(_bottom);

            set_child(root);

            var keys = new EventControllerKey();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape || keyval == Gdk.Key.BackSpace) {
                    close_overlay();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller(keys);
        }

        public void toggle() {
            if (visible && !_closing) close_overlay();
            else open_overlay();
        }

        private void open_overlay() {
            _closing = false;
            refresh_app();
            refresh_clock();
            refresh_notifications();
            if (_clock_id == 0) _clock_id = GLib.Timeout.add_seconds(15, () => { refresh_clock(); refresh_app(); return GLib.Source.CONTINUE; });
            present();
            _top.reveal_child = true;
            _bottom.reveal_child = true;
            add_css_class("shown");
            GLib.Idle.add(() => { if (_first_tile != null) _first_tile.grab_focus(); return GLib.Source.REMOVE; });
        }

        private void close_overlay() {
            if (_closing) return;
            _closing = true;
            remove_css_class("shown");
            _top.reveal_child = false;
            _bottom.reveal_child = false;
            if (_clock_id != 0) { GLib.Source.remove(_clock_id); _clock_id = 0; }
            GLib.Timeout.add(Singularity.Motion.Duration.LARGE, () => {
                if (_closing) hide();
                _closing = false;
                return GLib.Source.REMOVE;
            });
        }

        private Widget build_top() {
            var bar = new Box(Orientation.HORIZONTAL, 24);
            bar.add_css_class("game-overlay-top");

            var app = new Box(Orientation.HORIZONTAL, 16);
            app.valign = Align.START;
            _app_icon = new Image();
            _app_icon.pixel_size = 56;
            app.append(_app_icon);
            var app_text = new Box(Orientation.VERTICAL, 2);
            app_text.valign = Align.CENTER;
            _app_title = new Label("");
            _app_title.add_css_class("game-overlay-app");
            _app_title.xalign = 0;
            _app_title.ellipsize = Pango.EllipsizeMode.END;
            _app_title.max_width_chars = 36;
            _app_sub = new Label("");
            _app_sub.add_css_class("game-overlay-sub");
            _app_sub.xalign = 0;
            app_text.append(_app_title);
            app_text.append(_app_sub);
            app.append(app_text);
            app.hexpand = true;
            bar.append(app);

            var right = new Box(Orientation.VERTICAL, 14);
            right.halign = Align.END;
            var time = new Box(Orientation.VERTICAL, 0);
            time.halign = Align.END;
            _clock = new Label("");
            _clock.add_css_class("game-overlay-clock");
            _clock.xalign = 1;
            _date = new Label("");
            _date.add_css_class("game-overlay-sub");
            _date.xalign = 1;
            _battery = new Label("");
            _battery.add_css_class("game-overlay-sub");
            _battery.xalign = 1;
            time.append(_clock);
            time.append(_date);
            time.append(_battery);
            right.append(time);
            _notes = new Box(Orientation.VERTICAL, 10);
            _notes.add_css_class("game-overlay-notes");
            right.append(_notes);
            bar.append(right);
            return bar;
        }

        private Widget build_bottom() {
            var area = new Box(Orientation.VERTICAL, 18);
            area.add_css_class("game-overlay-bottom");

            var tiles = new Box(Orientation.HORIZONTAL, 16);
            tiles.halign = Align.CENTER;
            var gm = GameModeManager.get_default();
            _first_tile = tile("applications-games-symbolic", _("Game Mode"),
                () => gm.active, () => game_mode_state(gm),
                () => { if (gm.requested) gm.deactivate(); else gm.activate("overlay"); });
            _first_tile.sensitive = gm.available;
            tiles.append(_first_tile);

            if (GLib.Environment.find_program_in_path("mangohud") != null) {
                tiles.append(tile("utilities-system-monitor-symbolic", _("Performance Overlay"),
                    () => _settings.get_boolean("mangohud-auto"),
                    () => _settings.get_boolean("mangohud-auto") ? _("From next launch") : _("Off"),
                    () => _settings.set_boolean("mangohud-auto", !_settings.get_boolean("mangohud-auto"))));
            }

            tiles.append(tile("video-display-symbolic", _("Allow Tearing"),
                () => _settings.get_boolean("allow-tearing"),
                () => _settings.get_boolean("allow-tearing") ? _("Lower input lag") : _("Off"),
                () => _settings.set_boolean("allow-tearing", !_settings.get_boolean("allow-tearing"))));

            var focus = FocusManager.get_default();
            tiles.append(tile("notifications-disabled-symbolic", _("Focus"),
                () => focus.state.active,
                () => focus.state.active ? _("Notifications held") : _("Off"),
                () => focus.toggle()));

            var ppm = SystemMonitor.get_default().power_profiles;
            if (ppm.available) {
                tiles.append(tile("power-profile-performance-symbolic", _("Power"),
                    () => ppm.active_profile == "performance",
                    () => ppm.active_profile == "performance" ? _("Performance") : ppm.active_profile == "power-saver" ? _("Power Saver") : _("Balanced"),
                    () => ppm.set_profile(ppm.active_profile == "performance" ? "balanced" : "performance")));
            }

            var shot = tile("camera-photo-symbolic", _("Screenshot"), () => false, () => _("Whole screen"), () => {
                close_overlay();
                GLib.Timeout.add(Singularity.Motion.Duration.LARGE + 120, () => {
                    SystemMonitor.get_default().shortcuts.execute_action("screenshot_tool");
                    return GLib.Source.REMOVE;
                });
            });
            tiles.append(shot);
            area.append(tiles);

            var sliders = new Box(Orientation.HORIZONTAL, 28);
            sliders.add_css_class("game-overlay-sliders");
            sliders.halign = Align.CENTER;
            var audio = SystemMonitor.get_default().audio;
            var vol = slider(audio.icon_name, 0, audio.max_volume, audio.volume, (v) => audio.update_volume(v));
            audio.state_changed.connect(() => {
                var s = (Scale) vol.get_last_child();
                if (Math.fabs(s.get_value() - audio.volume) > 0.5) s.set_value(audio.volume);
                ((Image) vol.get_first_child()).icon_name = audio.icon_name;
            });
            sliders.append(vol);
            var bri = SystemMonitor.get_default().brightness;
            var bri_box = slider("display-brightness-symbolic", 1, 100, bri.brightness, (v) => bri.set_level(v));
            sliders.append(bri_box);
            area.append(sliders);

            var hint = new Label(_("Esc or Super+G to get back to the game"));
            hint.add_css_class("game-overlay-hint");
            area.append(hint);
            return area;
        }

        private static string game_mode_state(GameModeManager gm) {
            if (!gm.available) return _("Not available");
            if (gm.requested) return _("Active");
            return gm.held_elsewhere ? _("On for the game") : _("Off");
        }

        private delegate bool StateFunc();
        private delegate string TextFunc();
        private delegate void ActFunc();
        private delegate void ValueFunc(double v);

        private Button tile(string icon, string title, owned StateFunc on, owned TextFunc text, owned ActFunc act) {
            var b = new Button();
            b.add_css_class("game-overlay-tile");
            var box = new Box(Orientation.VERTICAL, 10);
            var img = new Image.from_icon_name(icon);
            img.pixel_size = 28;
            img.halign = Align.START;
            var t = new Label(title);
            t.add_css_class("game-overlay-tile-title");
            t.xalign = 0;
            var s = new Label("");
            s.add_css_class("game-overlay-tile-sub");
            s.xalign = 0;
            s.ellipsize = Pango.EllipsizeMode.END;
            box.append(img);
            box.append(t);
            box.append(s);
            b.child = box;
            StateFunc state = (owned) on;
            TextFunc label = (owned) text;
            ActFunc run = (owned) act;
            GLib.SourceFunc sync = () => {
                s.label = label();
                if (state()) b.add_css_class("on");
                else b.remove_css_class("on");
                return GLib.Source.REMOVE;
            };
            sync();
            b.clicked.connect(() => { run(); GLib.Timeout.add(80, () => { sync(); return GLib.Source.REMOVE; }); });
            map.connect(() => sync());
            _settings.changed.connect(() => sync());
            SystemMonitor.get_default().power_profiles.profile_changed.connect(() => sync());
            GameModeManager.get_default().state_changed.connect(() => sync());
            FocusManager.get_default().changed.connect(() => sync());
            return b;
        }

        private Box slider(string icon, double min, double max, double value, owned ValueFunc set) {
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.add_css_class("game-overlay-slider");
            var img = new Image.from_icon_name(icon);
            img.pixel_size = 20;
            box.append(img);
            var scale = new Scale.with_range(Orientation.HORIZONTAL, min, max, 1);
            scale.draw_value = false;
            scale.set_size_request(260, -1);
            scale.set_value(value);
            ValueFunc apply = (owned) set;
            scale.value_changed.connect(() => apply(scale.get_value()));
            box.append(scale);
            return box;
        }

        private void refresh_app() {
            var apps = AppSystem.get_default();
            var handle = apps.get_focused_window_handle();
            var win = handle != null ? apps.get_window_by_handle(handle) : null;
            string id = win != null ? win.app_id : (apps.get_focused_app_id() ?? "");
            GLib.DesktopAppInfo? info = id != "" ? new GLib.DesktopAppInfo(id.has_suffix(".desktop") ? id : id + ".desktop") : null;
            _app_title.label = info != null ? info.get_display_name() : (win != null && win.title != "" ? win.title : _("Playing"));
            if (info != null && info.get_icon() != null) _app_icon.gicon = info.get_icon();
            else _app_icon.icon_name = "applications-games-symbolic";
            if (playing_since == 0 && win != null && win.is_fullscreen) playing_since = GLib.get_monotonic_time();
            if (playing_since > 0) {
                int64 min = (GLib.get_monotonic_time() - playing_since) / 60000000;
                _app_sub.label = min < 1 ? _("Playing now") : min < 60 ? _("Playing for %d min").printf((int) min) : _("Playing for %d h %d min").printf((int) (min / 60), (int) (min % 60));
            } else {
                _app_sub.label = _("Windowed");
            }
        }

        private void refresh_clock() {
            var now = new GLib.DateTime.now_local();
            _clock.label = now.format("%H:%M");
            _date.label = now.format("%A %e %B").strip();
            var power = SystemMonitor.get_default().power;
            _battery.visible = power.is_present;
            if (power.is_present) _battery.label = power.is_charging ? _("%d%% charging").printf((int) power.percentage) : _("%d%% battery").printf((int) power.percentage);
        }

        private void refresh_notifications() {
            Widget? c;
            while ((c = _notes.get_first_child()) != null) _notes.remove(c);
            int n = 0;
            unowned var history = SystemMonitor.get_default().notifications.get_history();
            for (unowned List<Notification>? l = history.last(); l != null && n < NOTIFICATION_COUNT; l = l.prev) {
                var note = l.data;
                var card = new Box(Orientation.HORIZONTAL, 12);
                card.add_css_class("game-overlay-note");
                var img = note.icon.has_prefix("/") ? new Image.from_file(note.icon) : new Image.from_icon_name(note.icon != "" ? note.icon : "preferences-system-notifications-symbolic");
                img.pixel_size = 32;
                img.valign = Align.START;
                card.append(img);
                var text = new Box(Orientation.VERTICAL, 2);
                var head = new Label(note.summary);
                head.add_css_class("game-overlay-note-title");
                head.xalign = 0;
                head.ellipsize = Pango.EllipsizeMode.END;
                head.max_width_chars = 34;
                var body = new Label(note.masked_body());
                body.add_css_class("game-overlay-note-body");
                body.xalign = 0;
                body.ellipsize = Pango.EllipsizeMode.END;
                body.max_width_chars = 40;
                body.visible = note.body != "";
                text.append(head);
                text.append(body);
                card.append(text);
                _notes.append(card);
                n++;
            }
            _notes.visible = n > 0;
        }
    }
}
