using GLib;

namespace Singularity {

    public class ScreenshotPortal : Object {
        private static ScreenshotPortal? _instance;
        private DBusConnection? connection;
        public signal void screenshot_taken(string uri);
        public signal void screenshot_failed(string error);

        public static ScreenshotPortal get_default() {
            if (_instance == null) {
                _instance = new ScreenshotPortal();
            }
            return _instance;
        }
        construct {
            try {
                connection = Bus.get_sync(BusType.SESSION);
            } catch (Error e) {
                warning("Failed to connect to session bus: %s", e.message);
            }
        }

        public bool is_available() {
            if (connection == null) {
                warning("[ScreenshotPortal] is_available: no session bus connection");
                return false;
            }
            try {
                var res = connection.call_sync(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "NameHasOwner",
                    new Variant("(s)", "org.freedesktop.portal.Desktop"),
                    new VariantType("(b)"),
                    DBusCallFlags.NONE, -1, null);
                bool owned;
                res.get("(b)", out owned);
                if (!owned) {
                    warning("[ScreenshotPortal] is_available: org.freedesktop.portal.Desktop has no owner");
                }
                return owned;
            } catch (Error e) {
                warning("[ScreenshotPortal] is_available: NameHasOwner call failed: %s", e.message);
                return false;
            }
        }

        public async void take_screenshot(bool interactive = true) {
            if (connection == null) {
                screenshot_failed("No D-Bus connection");
                return;
            }
            try {
                var handle_token = "singularity_%u".printf(Random.next_int());
                // ":1.42", remove ":", "1.42", replace ".", "1_42"
                var sender_name = connection.get_unique_name().replace(":", "").replace(".", "_");
                var request_path = "/org/freedesktop/portal/desktop/request/%s/%s".printf(
                    sender_name, handle_token
                );
                uint signal_id = 0;
                signal_id = connection.signal_subscribe(
                    "org.freedesktop.portal.Desktop",
                    "org.freedesktop.portal.Request",
                    "Response",
                    request_path,
                    null,
                    DBusSignalFlags.NONE,
                    (conn, sender, path, iface, signal_name, parameters) => {
                        handle_response(parameters);
                        if (signal_id != 0) {
                            connection.signal_unsubscribe(signal_id);
                        }
                    }
                );
                var options = new VariantBuilder(new VariantType("a{sv}"));
                options.add("{sv}", "handle_token", new Variant.string(handle_token));
                options.add("{sv}", "modal", new Variant.boolean(true));
                options.add("{sv}", "interactive", new Variant.boolean(interactive));
                yield connection.call(
                    "org.freedesktop.portal.Desktop",
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.Screenshot",
                    "Screenshot",
                    new Variant("(sa{sv})", "", options),
                    null,
                    DBusCallFlags.NONE,
                    -1,
                    null
                );
            } catch (Error e) {
                screenshot_failed("Portal call failed: %s".printf(e.message));
            }
        }

        private void handle_response(Variant parameters) {
            uint32 response;
            VariantIter results_iter;
            parameters.get("(ua{sv})", out response, out results_iter);
            if (response == 0) {
                string key;
                Variant val;
                while (results_iter.next("{sv}", out key, out val)) {
                    if (key == "uri") {
                        string uri = val.get_string();
                        screenshot_taken(uri);
                        return;
                    }
                }
                screenshot_failed("No URI in response");
            } else if (response == 1 || response == 2) {
                screenshot_failed("User cancelled");
            } else {
                screenshot_failed("Screenshot failed (code %u)".printf(response));
            }
        }

        public void copy_to_clipboard(string file_path) {
            try {
                uint8[] data;
                GLib.FileUtils.get_data(file_path, out data);
                SystemClipboard.set_bytes(new Bytes(data), { "image/png" });
                return;
            } catch (Error e) {
                warning("[Screenshot] system clipboard failed, falling back to GTK clipboard: %s", e.message);
            }
            try {
                var texture = Gdk.Texture.from_filename(file_path);
                var display = Gdk.Display.get_default();
                if (display != null) {
                    display.get_clipboard().set_texture(texture);
                }
            } catch (Error e) {
                warning("Failed to copy screenshot to clipboard: %s", e.message);
            }
        }

        public string? save_to_pictures(string source_uri) {
            try {
                var source = File.new_for_uri(source_uri);
                var now = new DateTime.now_local();
                string filename = "Screenshot from %s.png".printf(now.format("%Y-%m-%d %H-%M-%S"));
                string dest_path = Environment.get_home_dir() + "/Pictures/Screenshots/" + filename;
                var dest_dir = File.new_for_path(Environment.get_home_dir() + "/Pictures/Screenshots");
                if (!dest_dir.query_exists()) {
                    dest_dir.make_directory_with_parents();
                }
                var dest = File.new_for_path(dest_path);
                source.copy(dest, FileCopyFlags.OVERWRITE);
                return dest_path;
            } catch (Error e) {
                warning("Failed to save screenshot: %s", e.message);
                return null;
            }
        }
    }
}
