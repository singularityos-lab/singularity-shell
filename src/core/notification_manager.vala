using GLib;

namespace Singularity {

    public class Notification : Object {
        public uint id { get; construct; }
        public string app_name { get; construct; }
        public string summary { get; construct; }
        public string body { get; construct; }
        public string icon { get; construct; }
        public string[] actions { get; construct; }
        public int64 timestamp { get; construct; }

        public Notification(uint id, string app_name, string summary, string body, string icon, string[] actions) {
            Object(
                id: id,
                app_name: app_name,
                summary: summary,
                body: body,
                icon: icon,
                actions: actions,
                timestamp: GLib.get_real_time()
            );
        }
    }

    [DBus (name = "org.freedesktop.Notifications")]
    public class NotificationManager : Object {
        internal uint next_id = 1;
        private List<Notification> history;
        private GLib.Settings settings;

        public signal void new_notification (uint id, string app_name, string summary, string body, string icon, string[] actions);
        public signal void close_notification_request (uint id);
        public signal void notification_closed (uint id, uint reason);
        public signal void action_invoked (uint id, string action_key);
        public signal void history_changed ();

        public NotificationManager() {
            history = new List<Notification>();
            settings = new GLib.Settings("dev.sinty.desktop");
        }

        [DBus (visible = false)]
        public unowned List<Notification> get_history() {
            return history;
        }

        [DBus (visible = false)]
        public void clear_history() {
            history = new List<Notification>();
            history_changed();
        }

        [DBus (visible = false)]
        public void remove_from_history(uint id) {
            foreach (var n in history) {
                if (n.id == id) {
                    history.remove(n);
                    history_changed();
                    break;
                }
            }
        }

        public uint notify (string app_name, uint replaces_id, string app_icon, string summary, string body, string[] actions, HashTable<string, Variant> hints, int timeout) {
            uint id = replaces_id;
            if (id == 0) {
                id = next_id++;
            }
            var urgency = hints.lookup("urgency");
            if (urgency != null && urgency.is_of_type(VariantType.BYTE) && urgency.get_byte() == 2) {
                critical_ids.add(id);
            } else {
                critical_ids.remove(id);
            }

            // Per the freedesktop notifications spec, clients (Telegram, Slack,
            // browsers, ...) usually pass per-notification images via hints -
            // not the `app_icon` argument. Resolve the best icon now so both
            // the inline notification UI and any plugin listener gets the
            // contact avatar instead of the app's static icon. Never let a
            // bad hint take the notification down with it.
            string effective_icon = app_icon;
            try {
                effective_icon = resolve_notification_icon(app_icon, hints, id);
            } catch (Error e) {
                warning("notify: icon resolution failed: %s", e.message);
            }

            // Add to history
            var notif = new Notification(id, app_name, summary, body, effective_icon, actions);
            history.prepend(notif);
            // Cap history at 50 entries to prevent unbounded growth
            if (history.length() > 50) {
                unowned List<Notification> last = history.last();
                history.remove(last.data);
            }
            history_changed();

            // Fire `new_notification` ALWAYS - even in do-not-disturb mode.
            // Consumers (the on-screen NotificationDisplay popup) check
            // do-not-disturb themselves before showing. This way plugins
            // tracking notifications (messaging-dock, etc.) still see them
            // and can update their dock-bubble state; only the visual popup
            // is suppressed by DnD.
            new_notification(id, app_name, summary, body, effective_icon, actions);
            return id;
        }

        [DBus (visible = false)]
        public bool do_not_disturb_active {
            get { return settings.get_boolean("do-not-disturb"); }
        }

        /**
         * Resolve the best per-notification icon, in priority order:
         *   1. `image-path` hint (or older `image_path`) - a path or URI.
         *   2. `image-data` (raw struct of pixels) - materialize to a tmp PNG.
         *   3. The deprecated `icon_data` hint - same struct as image-data.
         *   4. `app_icon` argument (themed name or path).
         *
         * Defensive: any failure unwinds to returning `app_icon` so a broken
         * hint never blocks the notification.
         */
        [DBus (visible = false)]
        public static string resolve_notification_icon(string app_icon,
                HashTable<string, Variant>? hints, uint id) {
            if (hints == null) return app_icon;

            // 1. image-path
            try {
                var ip = unwrap(hints.lookup("image-path"));
                if (ip == null) ip = unwrap(hints.lookup("image_path"));
                if (ip != null && ip.is_of_type(VariantType.STRING)) {
                    string s = ip.get_string();
                    if (s.length > 0) return s;
                }
            } catch (Error e) {
                warning("notify: failed reading image-path hint: %s", e.message);
            }

            // 2/3. image-data (or legacy icon_data)
            try {
                var idata = unwrap(hints.lookup("image-data"));
                if (idata == null) idata = unwrap(hints.lookup("image_data"));
                if (idata == null) idata = unwrap(hints.lookup("icon_data"));
                if (idata != null) {
                    string? path = save_image_data_to_tmp(idata, id);
                    if (path != null) return path;
                }
            } catch (Error e) {
                warning("notify: failed reading image-data hint: %s", e.message);
            }

            return app_icon;
        }

        /** If `v` is a `v`-wrapped variant, return the inner one; else `v`. */
        private static Variant? unwrap(Variant? v) {
            if (v == null) return null;
            if (v.is_of_type(VariantType.VARIANT)) return v.get_variant();
            return v;
        }

        private static string? save_image_data_to_tmp(Variant v, uint id) {
            // Expected signature: (iiibiiay) - width, height, rowstride,
            // has_alpha, bits_per_sample, channels, raw bytes.
            if (!v.is_of_type(new VariantType("(iiibiiay)"))) {
                warning("notify: image-data has unexpected type %s", v.get_type_string());
                return null;
            }
            try {
                int width            = v.get_child_value(0).get_int32();
                int height           = v.get_child_value(1).get_int32();
                int rowstride        = v.get_child_value(2).get_int32();
                bool has_alpha       = v.get_child_value(3).get_boolean();
                int bits_per_sample  = v.get_child_value(4).get_int32();
                // channels available via get_child_value(5); inferable from has_alpha.
                if (width <= 0 || height <= 0 || rowstride <= 0) return null;

                Variant byte_arr = v.get_child_value(6);
                Bytes data = byte_arr.get_data_as_bytes();
                // Sanity-check size before handing to GDK to avoid hard crashes.
                if (data.get_size() < (size_t)(rowstride * (height - 1) + (width * (has_alpha ? 4 : 3)))) {
                    warning("notify: image-data buffer too small (%zu < %dx%d)",
                            data.get_size(), width, height);
                    return null;
                }

                var pixbuf = new Gdk.Pixbuf.from_bytes(
                    data, Gdk.Colorspace.RGB, has_alpha,
                    bits_per_sample, width, height, rowstride);

                // Per-user runtime dir (0700, auto-cleaned on logout): safe for
                // stable names, unlike a shared /tmp subdir.
                string dir = GLib.Path.build_filename(
                    GLib.Environment.get_user_runtime_dir(), "singularity", "notif-icons");
                GLib.DirUtils.create_with_parents(dir, 0700);
                string path = GLib.Path.build_filename(dir, "notif-%u.png".printf(id));
                pixbuf.save(path, "png");
                return path;
            } catch (Error e) {
                warning("notify: save_image_data_to_tmp failed: %s", e.message);
                return null;
            }
        }

        private Gee.HashSet<uint> critical_ids = new Gee.HashSet<uint>();

        /** Whether notification `id` was sent with critical urgency and must stay until dismissed. */
        public bool is_critical (uint id) {
            return id in critical_ids;
        }

        public void close_notification (uint id) {
            close_notification_request(id);
            notification_closed(id, 3);
            remove_from_history(id);
        }

        public string[] get_capabilities () {
            return { "body", "actions", "icon-static", "persistence" };
        }

        public void get_server_information (out string name, out string vendor, out string version, out string spec_version) {
            name = "Singularity";
            vendor = "Singularity";
            version = "1.0";
            spec_version = "1.2";
        }

        public void invoke_action(uint id, string action_key) {
            action_invoked(id, action_key);
        }

        public void report_closed(uint id, uint reason) {
            notification_closed(id, reason);
        }
    }
}
