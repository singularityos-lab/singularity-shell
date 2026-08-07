using Gtk;
using Singularity.Widgets;

namespace Singularity.LockScreen {

    public class LockScreenApp : Gtk.Application {
        public LockScreenWindow? window;

        public LockScreenApp() {
            Object(
                application_id: "dev.sinty.lockscreen",
                flags: ApplicationFlags.FLAGS_NONE
            );
        }

        protected override void activate() {
            Singularity.Style.StyleManager.get_default().load_theme();
            var settings = new GLib.Settings("dev.sinty.desktop");
            Singularity.Style.StyleManager.get_default().apply_accent_color(
                settings.get_string("accent-color"));

            var display = Gdk.Display.get_default();
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var mon = (Gdk.Monitor) monitors.get_item(i);
                window = new LockScreenWindow(this, mon);
                window.present();
            }
        }

        public static int main(string[] args) {
            var app = new LockScreenApp();
            return app.run(args);
        }
    }

    [CCode (has_target = false)]
    private static void on_lock_locked(void* data) {
        Idle.add(() => {
            message("LockScreen: compositor confirmed lock");
            return GLib.Source.REMOVE;
        });
    }

    [CCode (has_target = false)]
    private static void on_lock_finished(void* data) {
        Idle.add(() => {
            var app = GLib.Application.get_default() as LockScreenApp;
            if (app != null) app.quit();
            return GLib.Source.REMOVE;
        });
    }

    public class LockScreenWindow : Gtk.Window {
        private PasswordEntry _password_entry;
        private Label _status_label;
        private Label _big_time;
        private Label _date_label;
        private Gtk.Image _avatar;
        private uint _clock_timer_id = 0;
        private bool _authenticating = false;

        public LockScreenWindow(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);

            add_css_class("lock-screen-window");

            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_monitor(this, monitor);
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            GtkLayerShell.set_exclusive_zone(this, -1);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);

            decorated = false;
            resizable = false;

            var overlay = new Overlay();
            set_child(overlay);

            var bg = new Box(Orientation.HORIZONTAL, 0);
            bg.add_css_class("lock-screen-bg");
            bg.hexpand = true;
            bg.vexpand = true;
            var bg_picture = new Gtk.Picture();
            bg_picture.hexpand = true;
            bg_picture.vexpand = true;
            bg_picture.content_fit = ContentFit.COVER;
            load_wallpaper(bg_picture);
            bg.append(bg_picture);
            overlay.set_child(bg);

            var scrim = new Box(Orientation.HORIZONTAL, 0);
            scrim.add_css_class("lock-screen-scrim");
            scrim.hexpand = true;
            scrim.vexpand = true;
            overlay.add_overlay(scrim);

            var main_box = new Box(Orientation.VERTICAL, 48);
            main_box.valign = Align.CENTER;
            main_box.halign = Align.CENTER;
            overlay.add_overlay(main_box);

            var clock_box = new Box(Orientation.VERTICAL, 4);
            clock_box.halign = Align.CENTER;
            _big_time = new Label("");
            _big_time.add_css_class("greeter-clock");
            clock_box.append(_big_time);
            _date_label = new Label("");
            _date_label.add_css_class("greeter-date");
            clock_box.append(_date_label);
            main_box.append(clock_box);

            main_box.append(build_user_card());

            _clock_timer_id = GLib.Timeout.add_seconds(1, update_clock);
            update_clock();

            // SECURITY: the Ctrl+Alt+Shift+B debug bypass that unlocked the screen
            // without a PIN was removed (it shipped in release = a backdoor).

            map.connect(() => {
                _password_entry.grab_focus();
                request_lock();
            });
        }

        private void request_lock() {
            int ret = Singularity.Lock.lock_screen(this, on_lock_locked, on_lock_finished, (void*)this);
            if (ret != 0) {
                warning("LockScreen: ext-session-lock-v1 failed (ret=%d), operating in layer-shell fallback", ret);
            }
        }

        private Gtk.Widget build_user_card() {
            var card_outer = new Overlay();
            card_outer.halign = Align.CENTER;

            var card = new Box(Orientation.VERTICAL, 16);
            card.add_css_class("greeter-card");
            card.margin_top = 60;
            card.halign = Align.CENTER;
            card.width_request = 320;

            var username_label = new Label(GLib.Environment.get_user_name());
            username_label.add_css_class("greeter-username");
            username_label.halign = Align.CENTER;
            card.append(username_label);

            _password_entry = new PasswordEntry();
            _password_entry.placeholder_text = Singularity.Runtime.is_sinty_os() ? _("PIN") : _("Password");
            _password_entry.add_css_class("greeter-password-entry");
            _password_entry.halign = Align.FILL;
            _password_entry.activate.connect(try_auth);
            card.append(_password_entry);

            _status_label = new Label("");
            _status_label.add_css_class("greeter-status");
            _status_label.visible = false;
            _status_label.wrap = true;
            card.append(_status_label);

            var unlock_btn = new Button.with_label(_("Unlock"));
            unlock_btn.add_css_class("pill");
            unlock_btn.add_css_class("suggested-action");
            unlock_btn.halign = Align.CENTER;
            unlock_btn.clicked.connect(try_auth);
            card.append(unlock_btn);

            card_outer.set_child(card);

            _avatar = new Gtk.Image();
            _avatar.pixel_size = 112;
            _avatar.add_css_class("greeter-avatar");
            _avatar.halign = Align.CENTER;
            _avatar.valign = Align.START;
            update_avatar();
            card_outer.add_overlay(_avatar);

            return card_outer;
        }

        // On Sinty OS the lockscreen runs as the SESSION USER and cannot read the
        // root-only key blobs, so pam_sinty -> `sintykey unseal` gives EACCES and the
        // PIN is wrongly rejected. The CE key is already in the keyring from login, so
        // unlock only needs to VERIFY the PIN: ask the root sinty-recoverd daemon over
        // its socket (SO_PEERCRED-gated to our own uid, rate-limited).
        private int verify_via_daemon(string pin) {
            try {
                var sock = new GLib.Socket(GLib.SocketFamily.UNIX, GLib.SocketType.STREAM,
                                           GLib.SocketProtocol.DEFAULT);
                sock.connect(new GLib.UnixSocketAddress("/run/sinty-recoverd.sock"), null);
                string req = "verify\n%u\n%s\n".printf((uint) Posix.getuid(), pin);
                sock.send(req.data);
                var buf = new uint8[16];
                ssize_t n = sock.receive(buf);
                sock.close();
                return (n >= 2 && buf[0] == 'O' && buf[1] == 'K') ? 0 : 1;
            } catch (GLib.Error e) {
                warning("LockScreen: daemon verify failed: %s", e.message);
                return 1;
            }
        }

        private void try_auth() {
            if (_authenticating) return;
            string password = _password_entry.text;
            if (password == "") return;

            _authenticating = true;
            _password_entry.sensitive = false;
            _status_label.label = "";
            _status_label.visible = false;

            new Thread<void>("pam-auth", () => {
                string username = GLib.Environment.get_user_name();
                int result = Singularity.Runtime.is_sinty_os()
                    ? verify_via_daemon(password)
                    : Singularity.Pam.authenticate(username, password);

                Idle.add(() => {
                    _authenticating = false;
                    _password_entry.sensitive = true;

                    if (result == 0) {
                        Singularity.Lock.unlock_and_destroy();
                        var app = GLib.Application.get_default() as LockScreenApp;
                        if (app != null) app.quit();
                    } else {
                        _status_label.label = Singularity.Runtime.is_sinty_os() ? _("Incorrect PIN") : _("Incorrect password");
                        _status_label.visible = true;
                        _password_entry.text = "";
                        _password_entry.add_css_class("error");
                        GLib.Timeout.add(600, () => {
                            _password_entry.remove_css_class("error");
                            return GLib.Source.REMOVE;
                        });
                        _password_entry.grab_focus();
                    }
                    return false;
                });
            });
        }

        private void load_wallpaper(Gtk.Picture picture) {
            try {
                var s = new GLib.Settings("dev.sinty.desktop");
                string uri = s.get_string("background-picture-uri");
                message("LockScreen: loading wallpaper from %s", uri);
                if (uri != "") {
                    string path = uri;
                    if (uri.has_prefix("file://")) {
                        path = uri.substring(7);
                    }
                    if (GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) {
                        picture.set_file(GLib.File.new_for_path(path));
                        message("LockScreen: wallpaper loaded successfully");
                    } else {
                        warning("LockScreen: wallpaper file not found: %s", path);
                    }
                }
            } catch (Error e) {
                warning("LockScreen: failed to load wallpaper: %s", e.message);
            }
        }

        private void update_avatar() {
            string username = GLib.Environment.get_user_name();
            string[] paths = {
                "/var/lib/AccountsService/icons/" + username,
                GLib.Environment.get_home_dir() + "/.face",
                "/usr/share/pixmaps/faces/user-generic.png"
            };
            foreach (var p in paths) {
                if (GLib.FileUtils.test(p, GLib.FileTest.EXISTS)) {
                    _avatar.set_from_file(p);
                    return;
                }
            }
            _avatar.set_from_icon_name("avatar-default");
        }

        private bool update_clock() {
            var now = new DateTime.now_local();
            _big_time.label = now.format(_("%H:%M"));
            _date_label.label = now.format(_("%A, %B %e"));
            return GLib.Source.CONTINUE;
        }

        protected override void dispose() {
            if (_clock_timer_id != 0) {
                GLib.Source.remove(_clock_timer_id);
                _clock_timer_id = 0;
            }
            base.dispose();
        }
    }
}