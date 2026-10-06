using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.Notifications")]
    public class NotificationManager : Object {
        internal uint next_id = 1;
        private List<Notification> history;
        private GLib.Settings settings;
        private NotificationHistoryFile _file;
        private uint _save_id = 0;
        private Gee.HashMap<uint, NotificationDecision> _decisions = new Gee.HashMap<uint, NotificationDecision>();
        private NotificationSound _sound = new NotificationSound();

        public signal void new_notification (uint id, string app_name, string summary, string body, string icon, string[] actions);
        public signal void close_notification_request (uint id);
        public signal void notification_closed (uint id, uint reason);
        public signal void action_invoked (uint id, string action_key);
        public signal void notification_replied (uint id, string text);
        public signal void history_changed ();

        public NotificationManager() {
            history = new List<Notification>();
            settings = new GLib.Settings("dev.sinty.desktop");
            _file = new NotificationHistoryFile(NotificationHistoryFile.default_path());
            restore_history();
            var ns = AppNotificationSettings.get_default();
            if (ns.available) {
                ns.settings.changed["history-retention-days"].connect(() => {
                    prune_history();
                    schedule_save();
                });
            }
            foreach (int sig in new int[] { Posix.Signal.TERM, Posix.Signal.INT, Posix.Signal.HUP }) {
                int signum = sig;
                GLib.Unix.signal_add(signum, () => {
                    save_now();
                    Posix.signal(signum, Posix.SIG_DFL);
                    Posix.raise(signum);
                    return Source.REMOVE;
                });
            }
            Timeout.add_seconds(3600, () => {
                if (prune_history()) schedule_save();
                return Source.CONTINUE;
            });
        }

        private int retention_days() {
            var ns = AppNotificationSettings.get_default();
            return ns.available ? ns.settings.get_int("history-retention-days") : 0;
        }

        private int history_limit() {
            var ns = AppNotificationSettings.get_default();
            int limit = ns.available ? ns.settings.get_int("history-limit") : NotificationHistoryFile.DEFAULT_LIMIT;
            return limit > 0 ? limit : NotificationHistoryFile.DEFAULT_LIMIT;
        }

        private void restore_history() {
            next_id = uint.max(next_id, _file.load_next_id());
            if (retention_days() <= 0) {
                _file.save(new Gee.ArrayList<Notification>(), next_id);
                _file.clear_icons(new Gee.ArrayList<Notification>());
                return;
            }
            var loaded = NotificationHistoryFile.prune(_file.load(), retention_days(), get_real_time(), history_limit());
            foreach (var n in loaded) {
                history.append(n);
                if (n.id >= next_id) next_id = n.id + 1;
            }
        }

        private Gee.ArrayList<Notification> history_list() {
            var list = new Gee.ArrayList<Notification>();
            foreach (var n in history) list.add(n);
            return list;
        }

        private bool prune_history() {
            int days = retention_days();
            var kept = NotificationHistoryFile.prune(history_list(), days > 0 ? days : 0, get_real_time(), history_limit());
            if (kept.size == history.length()) return false;
            history = new List<Notification>();
            foreach (var n in kept) history.append(n);
            history_changed();
            return true;
        }

        private void schedule_save() {
            if (_save_id != 0) return;
            _save_id = Timeout.add(700, () => {
                _save_id = 0;
                save_now();
                return Source.REMOVE;
            });
        }

        [DBus (visible = false)]
        public void save_now() {
            if (_save_id != 0) {
                Source.remove(_save_id);
                _save_id = 0;
            }
            var items = retention_days() > 0 ? history_list() : new Gee.ArrayList<Notification>();
            _file.save(items, next_id);
            _file.clear_icons(items);
        }

        [DBus (visible = false)]
        public unowned List<Notification> get_history() {
            return history;
        }

        [DBus (visible = false)]
        public Notification? find(uint id) {
            foreach (var n in history) {
                if (n.id == id) return n;
            }
            return null;
        }

        [DBus (visible = false)]
        public void clear_history() {
            uint[] live = {};
            foreach (var n in history) {
                if (!n.restored) live += n.id;
            }
            history = new List<Notification>();
            foreach (uint id in live) notification_closed(id, 2);
            history_changed();
            schedule_save();
        }

        [DBus (visible = false)]
        public void remove_from_history(uint id) {
            foreach (var n in history) {
                if (n.id == id) {
                    history.remove(n);
                    history_changed();
                    schedule_save();
                    break;
                }
            }
        }

        [DBus (visible = false)]
        public bool should_show_banner(uint id) {
            if (_decisions.has_key(id)) return _decisions[id].banner;
            return !FocusManager.get_default().state.active;
        }

        private static string? hint_string(HashTable<string, Variant> hints, string key) {
            var v = hints.lookup(key);
            if (v != null && v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            if (v == null || !v.is_of_type(VariantType.STRING)) return null;
            return v.get_string();
        }

        private static bool hint_bool(HashTable<string, Variant> hints, string key) {
            var v = hints.lookup(key);
            if (v != null && v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            if (v == null) return false;
            if (v.is_of_type(VariantType.BOOLEAN)) return v.get_boolean();
            if (v.is_of_type(VariantType.BYTE)) return v.get_byte() != 0;
            if (v.is_of_type(VariantType.INT32)) return v.get_int32() != 0;
            return false;
        }

        public uint notify (string app_name, uint replaces_id, string app_icon, string summary, string body, string[] actions, HashTable<string, Variant> hints, int timeout) {
            uint id = replaces_id;
            if (id == 0) {
                id = next_id++;
            }
            uint8 urgency_level = 1;
            var urgency = hints.lookup("urgency");
            if (urgency != null && urgency.is_of_type(VariantType.VARIANT)) urgency = urgency.get_variant();
            if (urgency != null && urgency.is_of_type(VariantType.BYTE)) urgency_level = urgency.get_byte();
            if (urgency_level == 2) {
                critical_ids.add(id);
            } else {
                critical_ids.remove(id);
            }

            string effective_icon = app_icon;
            try {
                effective_icon = resolve_notification_icon(app_icon, hints, id);
            } catch (Error e) {
                warning("notify: icon resolution failed: %s", e.message);
            }

            string? desktop_entry = hint_string(hints, "desktop-entry");
            string key = NotificationRules.app_key_for(app_name, desktop_entry);
            var app_settings = AppNotificationSettings.get_default();
            var policy = app_settings.policy_for(key);
            var facts = new NotificationFacts();
            facts.app_key = key;
            facts.summary = summary;
            facts.body = body;
            facts.urgency = urgency_level;
            facts.suppress_sound = hint_bool(hints, "suppress-sound");
            facts.transient = hint_bool(hints, "transient");
            var focus = FocusManager.get_default().state;
            var decision = NotificationRules.decide(policy, focus.mode, facts);
            _decisions[id] = decision;
            app_settings.remember(key, app_name, app_icon);
            debug("notify: %u app=%s store=%s banner=%s sound=%s silenced=%s", id, key,
                decision.store.to_string(), decision.banner.to_string(), decision.sound.to_string(), decision.silenced.to_string());

            if (!decision.store && !decision.banner) return id;

            var notif = new Notification(id, app_name, summary, body, effective_icon, actions);
            notif.app_key = key;
            notif.desktop_entry = desktop_entry ?? "";
            notif.silenced = decision.silenced;
            notif.time_sensitive = decision.time_sensitive;
            notif.lock_screen = decision.lock_screen;
            notif.grouping = policy.grouping;
            notif.reply_placeholder = hint_string(hints, "x-kde-reply-placeholder-text") ?? "";
            notif.reply_submit = hint_string(hints, "x-kde-reply-submit-button-text") ?? "";

            foreach (var old in history) {
                if (old.id == id) {
                    history.remove(old);
                    break;
                }
            }
            if (decision.store) {
                history.prepend(notif);
                int limit = history_limit();
                while (history.length() > limit) {
                    unowned List<Notification> last = history.last();
                    history.remove(last.data);
                }
                history_changed();
                schedule_save();
            }

            if (decision.sound) _sound.play(hints);
            new_notification(id, app_name, summary, body, effective_icon, actions);
            return id;
        }

        [DBus (visible = false)]
        public bool do_not_disturb_active {
            get { return FocusManager.get_default().state.active; }
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
                    GLib.Path.get_dirname(NotificationHistoryFile.default_path()), "icons");
                GLib.DirUtils.create_with_parents(dir, 0700);
                string path = GLib.Path.build_filename(dir, "notif-%u-%s.png".printf(id,
                    GLib.get_real_time().to_string()));
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
            return { "body", "actions", "icon-static", "persistence", "inline-reply", "sound", "x-kde-reply-placeholder-text" };
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

        [DBus (visible = false)]
        public void reply(uint id, string text, bool report_close = true) {
            if (text.strip() == "") return;
            notification_replied(id, text);
            if (report_close) notification_closed(id, 2);
            remove_from_history(id);
        }
    }
}
