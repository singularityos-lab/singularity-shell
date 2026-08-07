using Gtk;

namespace Singularity {

    public class UpdateIndicator : Gtk.Button {
        private const string SOCKET = "/run/updated.sock";
        private const uint POLL_SECONDS = 5;
        private const uint RETRY_SECONDS = 1;

        private string state = "idle";
        private string latest = "";
        private string product_name = "";
        private string product_version = "";
        private string product_build = "";
        private string error = "";
        private string consent_token = "";
        private int percent = 0;
        private bool agent_available = false;
        private bool polling = false;
        private uint poll_id = 0;
        private uint interval = 0;

        public signal void restart_requested(string version);

        public UpdateIndicator(int icon_size) {
            add_css_class("dock-update-indicator");
            add_css_class("dock-item");
            add_css_class("flat");
            has_frame = false;
            set_size_request(icon_size + 4, icon_size + 4);

            var overlay = new Gtk.Overlay();
            var logo = new Gtk.Image.from_icon_name("sinty");
            logo.pixel_size = icon_size;
            overlay.set_child(logo);

            var badge = new Gtk.Image.from_icon_name("dev.sinty.installer");
            badge.pixel_size = int.max(14, (icon_size * 11) / 24);
            badge.halign = Align.END;
            badge.valign = Align.END;
            overlay.add_overlay(badge);
            set_child(overlay);
            ((Gtk.Widget) this).visible = false;
            clicked.connect(on_clicked);

            poll();
            arm(want_interval());
        }

        ~UpdateIndicator() {
            if (poll_id != 0) {
                Source.remove(poll_id);
            }
        }

        private uint want_interval() {
            return poll_interval(agent_available, state);
        }

        internal static uint poll_interval(bool agent_available, string state) {
            return !agent_available || state == "downloading" ? RETRY_SECONDS : POLL_SECONDS;
        }

        private void arm(uint secs) {
            if (poll_id != 0) {
                Source.remove(poll_id);
            }
            interval = secs;
            poll_id = Timeout.add_seconds(secs, on_tick);
        }

        private void adjust_interval() {
            uint want = want_interval();
            if (want != interval) arm(want);
        }

        private bool on_tick() {
            poll();
            uint want = want_interval();
            if (want != interval) {
                poll_id = 0;
                arm(want);
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        }

        private async string? request(string method, string path) {
            var cancellable = new Cancellable();
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(2, () => {
                timeout_id = 0;
                cancellable.cancel();
                return Source.REMOVE;
            });
            try {
                var client = new SocketClient();
                var conn = yield client.connect_async(new UnixSocketAddress(SOCKET), cancellable);
                var req = method + " " + path + " HTTP/1.0\r\nHost: localhost\r\n\r\n";
                size_t bytes_written;
                yield conn.output_stream.write_all_async(
                    req.data, Priority.DEFAULT, cancellable, out bytes_written);
                var dis = new DataInputStream(conn.input_stream);
                var body = new StringBuilder();
                string? line;
                bool got_status = false;
                bool in_body = false;
                while ((line = yield dis.read_line_async(Priority.DEFAULT, cancellable)) != null) {
                    if (!got_status) {
                        string[] parts = line.chomp().split(" ");
                        int status_code = 0;
                        if (parts.length < 2 ||
                            !int.try_parse(parts[1], out status_code) ||
                            status_code < 200 || status_code >= 300) {
                            return null;
                        }
                        got_status = true;
                    } else if (in_body) {
                        if (body.len + line.length > 65536) return null;
                        body.append(line);
                    } else if (line.length == 0 || line == "\r") {
                        in_body = true;
                    }
                }
                if (!got_status || !in_body) return null;
                return body.str;
            } catch (Error e) {
                return null;
            } finally {
                if (timeout_id != 0) Source.remove(timeout_id);
            }
        }

        private void poll() {
            if (!polling) poll_async.begin();
        }

        private async void poll_async() {
            polling = true;
            var body = yield request("GET", "/status");
            polling = false;
            if (body == null) {
                agent_available = false;
                ((Gtk.Widget) this).visible = false;
                adjust_interval();
                return;
            }
            try {
                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                    agent_available = false;
                    ((Gtk.Widget) this).visible = false;
                    adjust_interval();
                    return;
                }
                var o = root.get_object();
                state = o.get_string_member_with_default("state", "idle");
                latest = o.get_string_member_with_default("latest", "");
                product_name = o.get_string_member_with_default("product_name", "");
                product_version = o.get_string_member_with_default("product_version", "");
                product_build = o.get_string_member_with_default("product_build", "");
                error = o.get_string_member_with_default("error", "");
                string token = o.get_string_member_with_default("consent_token", "");
                consent_token = valid_consent_token(token) ? token : "";
                percent = (int) o.get_int_member_with_default("percent", 0);
            } catch (Error e) {
                agent_available = false;
                ((Gtk.Widget) this).visible = false;
                adjust_interval();
                return;
            }
            agent_available = true;
            render();
            adjust_interval();
        }

        private void render() {
            string version = display_version();
            switch (state) {
                case "available":
                    set_tooltip_text(_("Download %s").printf(version));
                    ((Gtk.Widget) this).visible = true;
                    break;
                case "downloading":
                    set_tooltip_text(_("Downloading %s: %d%%").printf(version, percent));
                    ((Gtk.Widget) this).visible = true;
                    break;
                case "ready":
                    set_tooltip_text(_("Update ready: restart to apply %s").printf(version));
                    ((Gtk.Widget) this).visible = true;
                    break;
                case "error":
                    set_tooltip_text(format_error(error));
                    ((Gtk.Widget) this).visible = true;
                    break;
                case "checking":
                    set_tooltip_text(_("Checking for updates"));
                    ((Gtk.Widget) this).visible = true;
                    break;
                default:
                    ((Gtk.Widget) this).visible = false;
                    break;
            }
        }

        private string display_version() {
            return format_version(latest, product_name, product_version, product_build);
        }

        internal static string format_version(string latest, string product_name,
                                              string product_version, string product_build) {
            string label = product_name.strip();
            string version = product_version.strip();
            string build = product_build.strip();
            bool has_public_metadata = label != "" || version != "" || build != "";

            if (version != "" && !label.contains(version))
                label = label == "" ? version : label + " " + version;
            if (build != "")
                label = label == "" ? _("Build %s").printf(build)
                    : _("%s (Build %s)").printf(label, build);
            if (!has_public_metadata) label = latest.strip();
            return label != "" ? label : _("system update");
        }

        internal static bool valid_consent_token(string token) {
            if (token.length != 64) return false;
            for (int i = 0; i < token.length; i++) {
                char c = token[i];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            }
            return true;
        }

        internal static string format_error(string error) {
            string detail = error.strip();
            return detail == "" ? _("Update failed. Click to try again.")
                : _("Update failed: %s. Click to try again.").printf(detail);
        }

        private void on_clicked() {
            switch (state) {
                case "available":
                    start_download.begin();
                    break;
                case "ready":
                    restart_requested(display_version());
                    break;
                case "error":
                    retry_check.begin();
                    break;
                default:
                    break;
            }
        }

        private async void start_download() {
            string token = consent_token;
            if (!valid_consent_token(token)) {
                poll();
                return;
            }
            state = "downloading";
            percent = 0;
            render();
            adjust_interval();
            yield request("POST", "/download?token=" + token);
            poll();
            arm(RETRY_SECONDS);
        }

        private async void retry_check() {
            state = "checking";
            render();
            yield request("GET", "/check");
            poll();
        }

        public void apply_update() {
            if (state == "ready") request.begin("POST", "/reboot");
        }
    }
}
