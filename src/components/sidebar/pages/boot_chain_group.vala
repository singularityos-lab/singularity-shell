using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class BootChainGroup : PreferencesGroup {
        public const string SOCKET = "/run/updated.sock";

        private ActionRow loader_row;
        private Label loader_label;
        private Button update_btn;
        private SwitchRow auto_row;
        private ActionRow running_row;
        private Label running_label;
        private ActionRow pending_row;
        private Label pending_label;
        private ActionRow previous_row;
        private Label previous_label;
        private ActionRow recovery_row;
        private Label recovery_label;
        private bool syncing = false;

        public static bool available() {
            return FileUtils.test(SOCKET, FileTest.EXISTS);
        }

        public BootChainGroup() {
            base(_("Startup"), _("The pieces that start this computer, and the version of each one."));
            visible = false;

            loader_row = new ActionRow(_("Boot Loader"));
            update_btn = new Button.with_label(_("Update"));
            update_btn.valign = Align.CENTER;
            update_btn.add_css_class("suggested-action");
            update_btn.visible = false;
            update_btn.clicked.connect(() => update_loader.begin());
            loader_row.add_suffix(update_btn);
            loader_label = value_label(loader_row);
            add_row(loader_row);

            auto_row = new SwitchRow(_("Update Boot Loader Automatically"),
                _("A new boot loader is tried once on the next restart and kept only if the computer starts with it."));
            auto_row.switch_btn.notify["active"].connect(() => {
                if (!syncing) set_auto.begin(auto_row.switch_btn.active);
            });
            add_row(auto_row);

            running_row = new ActionRow(_("Running System"));
            running_label = value_label(running_row);
            add_row(running_row);
            pending_row = new ActionRow(_("Update Waiting for Restart"));
            pending_label = value_label(pending_row);
            add_row(pending_row);
            previous_row = new ActionRow(_("Previous System"), _("Started automatically if the running system fails."));
            previous_label = value_label(previous_row);
            add_row(previous_row);
            recovery_row = new ActionRow(_("Recovery"));
            recovery_label = value_label(recovery_row);
            add_row(recovery_row);

            refresh.begin();
        }

        private static Label value_label(ActionRow row) {
            var label = new Label("");
            label.add_css_class("dim-label");
            label.selectable = true;
            row.add_suffix(label);
            return label;
        }

        private static string running_version() {
            string cmdline;
            try {
                FileUtils.get_contents("/proc/cmdline", out cmdline);
            } catch (Error e) {
                return "";
            }
            foreach (var arg in cmdline.strip().split(" ")) {
                if (arg.has_prefix("atom.version=")) return arg.substring("atom.version=".length);
            }
            return "";
        }

        private static Json.Object? member(Json.Object? parent, string name) {
            if (parent == null || !parent.has_member(name)) return null;
            var node = parent.get_member(name);
            return node.get_node_type() == Json.NodeType.OBJECT ? node.get_object() : null;
        }

        private static string slot(Json.Object status, string name) {
            var slots = member(member(status, "boot"), "slots");
            return slots != null ? slots.get_string_member_with_default(name, "") : "";
        }

        private void show_value(ActionRow row, Label label, string value) {
            row.visible = value != "";
            label.label = value == "present" ? _("Installed") : value;
        }

        private void apply(Json.Object status) {
            int installed = (int) status.get_int_member_with_default("installed", 0);
            int candidate = (int) status.get_int_member_with_default("candidate", 0);
            int failed = (int) status.get_int_member_with_default("failed", 0);
            int latest = (int) status.get_int_member_with_default("available", 0);
            loader_label.label = installed > 0 ? _("Version %d").printf(installed) : _("Unknown");
            if (candidate > 0) {
                loader_row.subtitle = _("Version %d is tried on the next restart.").printf(candidate);
            } else if (failed > 0 && failed >= latest) {
                loader_row.subtitle = _("Version %d did not start on this computer, version %d stays.").printf(failed, installed);
            } else if (latest > installed) {
                loader_row.subtitle = _("Version %d is available.").printf(latest);
            } else {
                loader_row.subtitle = _("Up to date.");
            }
            update_btn.visible = candidate == 0 && latest > installed;
            update_btn.label = failed == latest ? _("Try Again") : _("Update");
            syncing = true;
            auto_row.switch_btn.active = status.get_boolean_member_with_default("auto", false);
            syncing = false;

            var boot = member(status, "boot");
            bool trial = boot != null && boot.get_boolean_member_with_default("trial", false);
            string running = running_version();
            if (running == "") running = slot(status, "active");
            show_value(running_row, running_label, running);
            running_row.subtitle = trial && candidate == 0 ? _("On trial: kept after it starts correctly.") : "";
            string next = slot(status, "next");
            show_value(pending_row, pending_label, next.has_prefix("loader ") || next == running ? "" : next);
            show_value(previous_row, previous_label, slot(status, "prev"));
            show_value(recovery_row, recovery_label, slot(status, "recovery"));
            string error = status.get_string_member_with_default("error", "");
            if (error != "") loader_row.subtitle = error;
            visible = true;
        }

        private async void refresh() {
            try {
                apply(yield request("GET", "/loader", 5));
            } catch (Error e) {
                debug("Startup versions: %s", e.message);
            }
        }

        private async void update_loader() {
            update_btn.sensitive = false;
            loader_row.subtitle = _("Downloading the boot loader");
            string retry = update_btn.label == _("Try Again") ? "?retry=1" : "";
            try {
                apply(yield request("POST", "/loader/update" + retry, 600));
            } catch (Error e) {
                loader_row.subtitle = e.message;
            }
            update_btn.sensitive = true;
        }

        private async void set_auto(bool enable) {
            try {
                apply(yield request("POST", "/loader/auto?enable=" + (enable ? "1" : "0"), 5));
            } catch (Error e) {
                loader_row.subtitle = e.message;
                yield refresh();
            }
        }

        internal static async Json.Object request(string method, string path, uint timeout) throws Error {
            var cancellable = new Cancellable();
            uint timeout_id = Timeout.add_seconds(timeout, () => {
                cancellable.cancel();
                return Source.REMOVE;
            });
            try {
                var conn = yield new SocketClient().connect_async(new UnixSocketAddress(SOCKET), cancellable);
                var req = method + " " + path + " HTTP/1.0\r\nHost: localhost\r\n\r\n";
                size_t written;
                yield conn.output_stream.write_all_async(req.data, Priority.DEFAULT, cancellable, out written);
                var input = new DataInputStream(conn.input_stream);
                var body = new StringBuilder();
                bool in_body = false;
                string? line;
                while ((line = yield input.read_line_async(Priority.DEFAULT, cancellable)) != null) {
                    if (in_body) {
                        if (body.len + line.length > 65536) throw new IOError.INVALID_DATA(_("The update service sent an invalid answer"));
                        body.append(line);
                    } else if (line.chomp() == "") {
                        in_body = true;
                    }
                }
                var parser = new Json.Parser();
                parser.load_from_data(body.str);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                    throw new IOError.INVALID_DATA(_("The update service sent an invalid answer"));
                }
                return root.get_object();
            } catch (IOError.CANCELLED e) {
                throw new IOError.TIMED_OUT(_("The update service did not answer in time"));
            } finally {
                if (!cancellable.is_cancelled()) Source.remove(timeout_id);
            }
        }
    }
}
