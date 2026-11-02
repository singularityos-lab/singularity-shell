using Gtk;

namespace Singularity {

    public class AgentConfig : Object {
        public const string BINARY = "/usr/bin/sinty";

        public static string path() {
            return Path.build_filename(Environment.get_user_config_dir(), "sinty-agent", "config.json");
        }

        public static bool available() {
            return FileUtils.test(BINARY, FileTest.IS_EXECUTABLE);
        }

        public static bool configured() {
            return available() && FileUtils.test(path(), FileTest.EXISTS);
        }

        public static void load(out string provider, out string model, out string endpoint) {
            provider = "";
            model = "";
            endpoint = "";
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path());
                var root = parser.get_root().get_object();
                provider = root.get_string_member_with_default("provider", "");
                model = root.get_string_member_with_default("model", "");
                endpoint = root.get_string_member_with_default("endpoint", "");
            } catch (Error e) {
                debug("No AI configuration: %s", e.message);
            }
        }

        public static void save(string provider, string model, string endpoint) throws Error {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("provider").add_string_value(provider);
            builder.set_member_name("model").add_string_value(model);
            builder.set_member_name("endpoint").add_string_value(endpoint);
            builder.end_object();
            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            DirUtils.create_with_parents(Path.get_dirname(path()), 0700);
            FileUtils.set_contents(path(), generator.to_data(null));
        }

        public static void remove() {
            FileUtils.unlink(path());
        }
    }

    public class AgentDialog : Singularity.Shell.ShellDialog {
        private Entry entry;
        private Label answer;
        private Spinner spinner;
        private Subprocess? running = null;

        public AgentDialog(Gtk.Application app) {
            Object(
                application: app,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            add_css_class("power-confirm-dialog");

            var box = new Box(Orientation.VERTICAL, 14);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            box.add_css_class("power-card");
            box.margin_top = 28;
            box.margin_bottom = 28;
            box.margin_start = 28;
            box.margin_end = 28;
            content_box.append(box);

            var row = new Box(Orientation.HORIZONTAL, 10);
            entry = new Entry();
            entry.placeholder_text = _("Ask Sinty AI");
            entry.hexpand = true;
            entry.width_chars = 56;
            entry.activate.connect(ask);
            row.append(entry);
            spinner = new Spinner();
            row.append(spinner);
            box.append(row);

            answer = new Label("");
            answer.wrap = true;
            answer.wrap_mode = Pango.WrapMode.WORD_CHAR;
            answer.selectable = true;
            answer.xalign = 0;
            answer.max_width_chars = 64;
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 420;
            scroll.child = answer;
            box.append(scroll);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, keycode, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                close_dialog();
                return true;
            });
            ((Widget) this).add_controller(keys);
            hide();
        }

        public void toggle() {
            if (visible) {
                close_dialog();
                return;
            }
            open_dialog();
            entry.grab_focus();
        }

        private void ask() {
            var text = entry.text.strip();
            if (text == "" || running != null) return;
            if (text.has_prefix("--")) text = " " + text;
            answer.label = "";
            spinner.start();
            entry.sensitive = false;
            run.begin(text);
        }

        private async void run(string text) {
            string? out_text = null;
            string? err_text = null;
            try {
                running = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                    AgentConfig.BINARY, "ask", text);
                yield running.communicate_utf8_async(null, null, out out_text, out err_text);
                answer.label = running.get_successful() ? (out_text ?? "") : (err_text ?? _("The request failed"));
            } catch (Error e) {
                answer.label = e.message;
            }
            running = null;
            spinner.stop();
            entry.sensitive = true;
            entry.text = "";
            entry.grab_focus();
        }
    }

    public class AgentConfirmations : Object {
        private const string NAME = "dev.sinty.Agent";
        private const string PATH = "/dev/sinty/Agent";
        private const string IFACE = "dev.sinty.Agent1";

        public static void start(Gtk.Application app) {
            if (!AgentConfig.available()) return;
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                bus.signal_subscribe(NAME, IFACE, "ConfirmRequested", PATH, null, DBusSignalFlags.NONE,
                    (conn, sender, object_path, iface, name, parameters) => {
                        uint32 id;
                        string text;
                        parameters.get("(us)", out id, out text);
                        show(app, conn, id, text);
                    });
            } catch (Error e) {
                warning("Cannot watch AI confirmations: %s", e.message);
            }
        }

        private static void call(DBusConnection conn, string method, Variant args) {
            conn.call.begin(NAME, PATH, IFACE, method, args, null, DBusCallFlags.NO_AUTO_START, -1, null);
        }

        private static void show(Gtk.Application app, DBusConnection conn, uint32 id, string text) {
            var dialog = new Singularity.Shell.ShellDialog.anchored(app, true, true, true, true);
            dialog.add_css_class("power-confirm-dialog");
            var box = new Box(Orientation.VERTICAL, 14);
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            box.add_css_class("power-card");
            box.margin_top = 28;
            box.margin_bottom = 28;
            box.margin_start = 40;
            box.margin_end = 40;
            dialog.content_box.append(box);

            var title = new Label(_("Allow this AI action?"));
            title.add_css_class("title-1");
            box.append(title);

            var detail = new Label(text.length > 600 ? text.substring(0, text.index_of_nth_char(600)) : text);
            detail.add_css_class("dim-label");
            detail.wrap = true;
            detail.wrap_mode = Pango.WrapMode.WORD_CHAR;
            detail.max_width_chars = 64;
            box.append(detail);

            var row = new Box(Orientation.HORIZONTAL, 12);
            row.halign = Align.CENTER;
            box.append(row);
            var deny = new Button.with_label(_("Deny"));
            deny.add_css_class("pill");
            deny.clicked.connect(() => {
                call(conn, "Answer", new Variant("(ub)", id, false));
                dialog.close_dialog();
            });
            row.append(deny);
            var session = new Button.with_label(_("Allow for This Session"));
            session.add_css_class("pill");
            session.clicked.connect(() => {
                call(conn, "AllowSession", new Variant("(u)", id));
                dialog.close_dialog();
            });
            row.append(session);
            var allow = new Button.with_label(_("Allow"));
            allow.add_css_class("pill");
            allow.add_css_class("suggested-action");
            allow.clicked.connect(() => {
                call(conn, "Answer", new Variant("(ub)", id, true));
                dialog.close_dialog();
            });
            row.append(allow);
            dialog.open_dialog();
            deny.grab_focus();
        }
    }
}
