using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class SignInRequest : Object {
        public string id;
        public string kind;
        public string name;
        public string address;

        public bool is_login {
            get { return kind == "login"; }
        }
    }

    public class SignInDialog : Singularity.Shell.ShellDialog {
        private Label title_label;
        private Label message_label;
        private PreferencesGroup number_group;
        private EntryRow number_entry;
        private Label error_label;
        private Button deny_btn;
        private Button allow_btn;
        private Singularity.Animation.TimedAnimation? anim;
        private bool finished;

        public SignInRequest? request { get; private set; }

        public signal void answered(bool allow, string number);
        public signal void dismissed(SignInRequest? request);
        public signal void reconfirm();

        public SignInDialog(Gtk.Application app) {
            Object(
                application: app,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            add_css_class("auth-dialog");

            var box = new Box(Orientation.VERTICAL, 16);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            box.add_css_class("power-card");
            box.margin_top = 28;
            box.margin_bottom = 24;
            box.margin_start = 40;
            box.margin_end = 40;
            content_box.append(box);

            var icon = new Image.from_icon_name("dialog-password");
            icon.pixel_size = 64;
            box.append(icon);

            title_label = new Label("");
            title_label.add_css_class("title-2");
            title_label.wrap = true;
            title_label.max_width_chars = 36;
            title_label.justify = Justification.CENTER;
            box.append(title_label);

            message_label = new Label("");
            message_label.add_css_class("dim-label");
            message_label.wrap = true;
            message_label.max_width_chars = 42;
            message_label.justify = Justification.CENTER;
            box.append(message_label);

            number_group = new PreferencesGroup();
            number_entry = new EntryRow(_("Number on the Sign-in Page"));
            number_entry.input_purpose = InputPurpose.DIGITS;
            number_entry.max_length = 2;
            number_entry.entry_changed.connect(update_allow);
            number_entry.entry_activated.connect(() => {
                if (allow_btn.sensitive) allow();
            });
            number_group.add_row(number_entry);
            box.append(number_group);

            error_label = new Label("");
            error_label.add_css_class("error");
            error_label.wrap = true;
            error_label.max_width_chars = 42;
            error_label.justify = Justification.CENTER;
            error_label.visible = false;
            box.append(error_label);

            var buttons = new Box(Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            box.append(buttons);

            deny_btn = new Button.with_label(_("Deny"));
            deny_btn.add_css_class("pill");
            deny_btn.width_request = 120;
            deny_btn.clicked.connect(() => {
                if (finished) {
                    close_dialog();
                    return;
                }
                set_busy(true);
                answered(false, "");
            });
            buttons.append(deny_btn);

            allow_btn = new Button.with_label(_("Allow"));
            allow_btn.add_css_class("pill");
            allow_btn.add_css_class("suggested-action");
            allow_btn.width_request = 140;
            allow_btn.clicked.connect(allow);
            buttons.append(allow_btn);

            visible = false;
        }

        private static string digits(string text) {
            var b = new StringBuilder();
            unichar c;
            int i = 0;
            while (text.get_next_char(ref i, out c)) {
                if (c >= '0' && c <= '9') b.append_unichar(c);
            }
            return b.str;
        }

        private void update_allow() {
            allow_btn.sensitive = request == null || !request.is_login || digits(number_entry.text).length == 2;
        }

        private void allow() {
            if (request == null) {
                close_dialog();
                reconfirm();
                return;
            }
            set_busy(true);
            answered(true, digits(number_entry.text));
        }

        private void set_busy(bool busy) {
            deny_btn.sensitive = !busy;
            number_entry.sensitive = !busy;
            if (busy) allow_btn.sensitive = false;
            else update_allow();
        }

        public void show_request(SignInRequest r, string organization) {
            request = r;
            if (r.is_login) {
                title_label.label = _("Sign In to %s?").printf(r.name);
                message_label.label = r.address != ""
                    ? _("Someone is signing in as you at %s, from %s. If it is you, type the number shown on the sign-in page.").printf(organization, r.address)
                    : _("Someone is signing in as you at %s. If it is you, type the number shown on the sign-in page.").printf(organization);
            } else {
                title_label.label = _("Trust %s?").printf(r.name);
                message_label.label = _("A new device wants to confirm your sign-ins at %s. Allow it only if you are setting it up now.").printf(organization);
            }
            finished = false;
            number_group.visible = r.is_login;
            number_entry.text = "";
            error_label.visible = false;
            allow_btn.label = _("Allow");
            allow_btn.visible = true;
            deny_btn.label = _("Deny");
            set_busy(false);
            open_dialog();
        }

        public void show_device_waiting(string device, string organization) {
            request = null;
            finished = true;
            title_label.label = _("Confirm This Device");
            message_label.label = _("Approve %s from a device you already use to sign in at %s. If this is your first device, sign in again to confirm it.").printf(device, organization);
            number_group.visible = false;
            error_label.visible = false;
            allow_btn.label = _("Sign In Again");
            allow_btn.visible = true;
            allow_btn.sensitive = true;
            deny_btn.label = _("Not Now");
            deny_btn.sensitive = true;
            open_dialog();
        }

        public void show_error(string message, bool final) {
            error_label.label = message;
            error_label.visible = true;
            finished = final;
            if (final) {
                allow_btn.visible = false;
                deny_btn.label = _("Close");
                deny_btn.sensitive = true;
                number_entry.sensitive = false;
            } else {
                set_busy(false);
            }
            open_dialog();
        }

        public override void open_dialog() {
            opacity = 0;
            if (anim != null) anim.skip();
            anim = new Singularity.Animation.TimedAnimation(
                this, 0, 1, 160,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
            anim.tick.connect(() => { opacity = anim.value; });
            anim.done.connect(() => {
                anim = null;
                if (number_group.visible && number_entry.sensitive) number_entry.grab_focus();
            });
            anim.play();
            present();
        }

        public void fade_out() {
            if (anim != null) anim.skip();
            anim = new Singularity.Animation.TimedAnimation(
                this, 1, 0, 120,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC);
            anim.tick.connect(() => { opacity = anim.value; });
            anim.done.connect(() => {
                anim = null;
                visible = false;
            });
            anim.play();
        }

        public override void close_dialog() {
            if (!finished && !deny_btn.sensitive) return;
            var r = request;
            request = null;
            fade_out();
            dismissed(r);
        }
    }

    public class SignInConfirm : Object {
        private const string NAME = "dev.sinty.IdentityAgent1";
        private const string PATH = "/dev/sinty/IdentityAgent1";
        private const int ANSWER_TIMEOUT_MS = 240000;

        private static SignInConfirm? instance;

        private Gtk.Application app;
        private DBusProxy? proxy;
        private SignInDialog? dialog;
        private Gee.ArrayList<SignInRequest> queue = new Gee.ArrayList<SignInRequest>();
        private Gee.HashSet<string> handled = new Gee.HashSet<string>();
        private string organization = "";
        private bool asked_waiting = false;

        public static void setup(Gtk.Application app) {
            if (instance == null) instance = new SignInConfirm(app);
        }

        private SignInConfirm(Gtk.Application app) {
            this.app = app;
            Bus.watch_name(BusType.SESSION, NAME, BusNameWatcherFlags.NONE,
                (conn, name, owner) => connect_agent.begin(),
                (conn, name) => {
                    proxy = null;
                    queue.clear();
                    if (dialog != null && dialog.visible) dialog.fade_out();
                });
        }

        private async void connect_agent() {
            try {
                proxy = yield new DBusProxy.for_bus(BusType.SESSION, DBusProxyFlags.DO_NOT_AUTO_START,
                    null, NAME, PATH, NAME, null);
                proxy.g_properties_changed.connect(() => refresh());
                refresh();
            } catch (Error e) {
                warning("sign-in confirmations: %s", e.message);
            }
        }

        private static string host_of(string address) {
            try {
                return GLib.Uri.parse(address, UriFlags.NONE).get_host() ?? address;
            } catch (Error e) {
                return address;
            }
        }

        private void refresh() {
            if (proxy == null) return;
            var org = proxy.get_cached_property("Organization");
            if (org != null) organization = host_of(org.get_string());
            var list = proxy.get_cached_property("Requests");
            var waiting = new Gee.HashSet<string>();
            if (list != null) {
                var it = list.iterator();
                string id, kind, name, address;
                int64 created;
                while (it.next("(ssssx)", out id, out kind, out name, out address, out created)) {
                    waiting.add(id);
                    if (handled.contains(id) || queued(id)) continue;
                    var r = new SignInRequest();
                    r.id = id;
                    r.kind = kind;
                    r.name = name;
                    r.address = address;
                    queue.add(r);
                }
            }
            var still = new Gee.ArrayList<SignInRequest>();
            foreach (var r in queue) if (waiting.contains(r.id)) still.add(r);
            queue = still;
            if (dialog != null && dialog.visible && dialog.request != null && !waiting.contains(dialog.request.id)) {
                dialog.fade_out();
            }
            show_next();
            var state = proxy.get_cached_property("State");
            if (state != null && state.get_string() == "waiting" && !asked_waiting && queue.size == 0 && (dialog == null || !dialog.visible)) {
                asked_waiting = true;
                ensure_dialog();
                dialog.show_device_waiting(Environment.get_host_name(), organization);
            }
        }

        private void ensure_dialog() {
            if (dialog != null) return;
            dialog = new SignInDialog(app);
            dialog.answered.connect((allow, number) => answer.begin(allow, number));
            dialog.dismissed.connect((r) => {
                if (r != null) handled.add(r.id);
                Idle.add(() => { show_next(); return false; });
            });
            dialog.reconfirm.connect(() => reconfirm.begin());
        }

        private async void reconfirm() {
            var manager = Singularity.Accounts.Manager.get_default();
            yield manager.load();
            foreach (var account in manager.get_accounts()) {
                if (account.provider != "sinty") continue;
                try {
                    yield account.step_up("sinty:2");
                    if (proxy != null) yield proxy.call("Retry", null, DBusCallFlags.NONE, 60000, null);
                } catch (Error e) {
                    warning("sign-in confirmations: %s", e.message);
                }
                return;
            }
        }

        private bool queued(string id) {
            foreach (var r in queue) if (r.id == id) return true;
            return dialog != null && dialog.request != null && dialog.request.id == id;
        }

        private void show_next() {
            if (dialog != null && dialog.visible) return;
            if (queue.size == 0) return;
            var r = queue.remove_at(0);
            ensure_dialog();
            dialog.show_request(r, organization);
        }

        private async void answer(bool allow, string number) {
            var r = dialog.request;
            if (r == null || proxy == null) return;
            if (allow) dialog.fade_out();
            try {
                yield proxy.call("Answer", new Variant("(ssb)", r.id, number, allow), DBusCallFlags.NONE, ANSWER_TIMEOUT_MS, null);
                handled.add(r.id);
                if (dialog.visible) dialog.fade_out();
                Idle.add(() => { show_next(); return false; });
            } catch (Error e) {
                string name = DBusError.get_remote_error(e) ?? "";
                string kind = name.has_prefix(NAME + ".Error.") ? name.substring(NAME.length + 7) : "";
                switch (kind) {
                    case "NotConfirmed":
                        dialog.show_error(_("Your PIN was not confirmed. Choose Allow to try again."), false);
                        break;
                    case "WrongNumber":
                        handled.add(r.id);
                        dialog.show_error(_("That is not the number on the sign-in page, so the sign-in was refused. Start it again there."), true);
                        break;
                    case "Gone":
                        handled.add(r.id);
                        dialog.show_error(_("This request is no longer waiting."), true);
                        break;
                    case "LockedOut":
                        dialog.show_error(_("Too many wrong PINs. Wait a moment and try again."), false);
                        break;
                    default:
                        dialog.show_error(_("The sign-in could not be answered. Check your connection and try again."), false);
                        break;
                }
            }
        }
    }
}
