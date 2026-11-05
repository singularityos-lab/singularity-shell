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

        public static async int key_state(string provider) {
            try {
                var bus = yield Bus.@get(BusType.SESSION);
                var locked = yield bus.call("org.freedesktop.secrets", "/org/freedesktop/secrets/aliases/default",
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", "org.freedesktop.Secret.Collection", "Locked"),
                    new VariantType("(v)"), DBusCallFlags.NONE, 5000, null);
                if (locked.get_child_value(0).get_variant().get_boolean()) return -1;
                var attributes = new VariantBuilder(new VariantType("a{ss}"));
                attributes.add("{ss}", "provider", provider);
                attributes.add("{ss}", "xdg:schema", "dev.sinty.agent.Key");
                var reply = yield bus.call("org.freedesktop.secrets", "/org/freedesktop/secrets",
                    "org.freedesktop.Secret.Service", "SearchItems",
                    new Variant("(a{ss})", attributes), new VariantType("(aoao)"),
                    DBusCallFlags.NONE, 5000, null);
                return reply.get_child_value(0).n_children() > 0 ? 1 : 0;
            } catch (Error e) {
                debug("Cannot look for the API key: %s", e.message);
                return -1;
            }
        }

        public static async string? grant_session() {
            try {
                var bus = yield Bus.@get(BusType.SESSION);
                var reply = yield bus.call("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1",
                    "GrantSession", null, new VariantType("(s)"), DBusCallFlags.NONE, 5000, null);
                string token;
                reply.get("(s)", out token);
                return token;
            } catch (Error e) {
                warning("No AI session token: %s", e.message);
                return null;
            }
        }

        public static void remove() {
            FileUtils.unlink(path());
        }
    }

    public class AgentConfirmations : Object {
        private const string NAME = "dev.sinty.Agent";
        private const string PATH = "/dev/sinty/Agent";
        private const string IFACE = "dev.sinty.Agent1";

        private static Gee.HashMap<uint32, Singularity.Shell.ShellDialog> open_dialogs;

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
                bus.signal_subscribe(NAME, IFACE, "ConfirmClosed", PATH, null, DBusSignalFlags.NONE,
                    (conn, sender, object_path, iface, name, parameters) => {
                        uint32 id;
                        parameters.get("(u)", out id);
                        var dialog = open_dialogs[id];
                        if (dialog != null) dialog.close_dialog();
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
            if (open_dialogs == null) open_dialogs = new Gee.HashMap<uint32, Singularity.Shell.ShellDialog>();
            open_dialogs[id] = dialog;
            dialog.notify["visible"].connect(() => {
                if (!dialog.visible && open_dialogs[id] == dialog) open_dialogs.unset(id);
            });
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
