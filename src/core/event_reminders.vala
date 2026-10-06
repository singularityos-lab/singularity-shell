using GLib;
using Singularity.Calendar;

namespace Singularity {

    public class EventReminders : Object {
        private const int64 GRACE = 10 * TimeSpan.MINUTE;
        private Gee.HashMap<string, string> fired = new Gee.HashMap<string, string> ();
        private Gee.HashMap<uint, CalendarEvent?> shown = new Gee.HashMap<uint, CalendarEvent?> ();
        private Gee.ArrayList<CalendarEvent?> snoozed = new Gee.ArrayList<CalendarEvent?> ();
        private Gee.ArrayList<string> snoozed_until = new Gee.ArrayList<string> ();
        private string state_path;
        private bool checking = false;

        public EventReminders () {
            state_path = Path.build_filename (Environment.get_user_state_dir (), "singularity", "calendar-reminders");
            load_state ();
            var notifications = SystemMonitor.get_default ().notifications;
            notifications.action_invoked.connect (on_action);
            notifications.notification_closed.connect ((id, reason) => shown.unset (id));
            CalendarManager.get_default ().events_changed.connect (() => check.begin ());
            Timeout.add_seconds (5, () => {
                check.begin ();
                return Source.REMOVE;
            });
            Timeout.add_seconds (30, () => {
                check.begin ();
                return Source.CONTINUE;
            });
        }

        private void load_state () {
            try {
                string text;
                FileUtils.get_contents (state_path, out text);
                int64 horizon = new DateTime.now_utc ().to_unix () - 3 * 86400;
                foreach (string line in text.split ("\n")) {
                    string[] parts = line.split ("\t");
                    if (parts.length != 2) continue;
                    if (int64.parse (parts[1]) > horizon) fired[parts[0]] = parts[1];
                }
            } catch (Error e) {
            }
        }

        private void save_state () {
            var text = new StringBuilder ();
            int64 horizon = new DateTime.now_utc ().to_unix () - 3 * 86400;
            foreach (var entry in fired.entries) {
                if (int64.parse (entry.value) > horizon) text.append_printf ("%s\t%s\n", entry.key, entry.value);
            }
            try {
                DirUtils.create_with_parents (Path.get_dirname (state_path), 0700);
                FileUtils.set_contents (state_path, text.str);
            } catch (Error e) {
                warning ("Failed to save reminder state: %s", e.message);
            }
        }

        private async void check () {
            if (checking) return;
            checking = true;
            var now = new DateTime.now_local ();
            var events = yield CalendarManager.get_default ().get_events (now.add_hours (-1), now.add_days (8));
            bool changed = false;
            foreach (var evt in events) {
                if (evt.alarms == null) continue;
                foreach (int minutes in evt.alarms) {
                    var at = evt.start_time.add_minutes (-minutes);
                    int64 late = now.difference (at);
                    if (late < 0 || late > GRACE) continue;
                    string key = "%s#%d".printf (evt.series_key (), minutes);
                    if (fired.has_key (key)) continue;
                    fired[key] = now.to_unix ().to_string ();
                    changed = true;
                    show (evt);
                }
            }
            for (int i = snoozed.size - 1; i >= 0; i--) {
                if (int64.parse (snoozed_until[i]) <= now.to_unix ()) {
                    show (snoozed[i]);
                    snoozed.remove_at (i);
                    snoozed_until.remove_at (i);
                }
            }
            if (changed) save_state ();
            checking = false;
        }

        private void show (CalendarEvent evt) {
            var now = new DateTime.now_local ();
            string body;
            int64 until = evt.start_time.difference (now);
            if (evt.all_day) {
                body = _("All day");
            } else if (until <= TimeSpan.MINUTE) {
                body = _("Starting now");
            } else if (until < TimeSpan.HOUR) {
                int m = (int) ((until + TimeSpan.MINUTE - 1) / TimeSpan.MINUTE);
                body = ngettext ("In %d minute, at %s", "In %d minutes, at %s", m).printf (m, evt.start_time.format ("%H:%M"));
            } else {
                body = _("At %s").printf (evt.start_time.format ("%a %H:%M"));
            }
            if (evt.location != null && evt.location != "") body += "\n" + evt.location;
            var hints = new HashTable<string, Variant> (str_hash, str_equal);
            hints["desktop-entry"] = new Variant.string ("dev.sinty.calendar");
            hints["urgency"] = new Variant.byte (1);
            hints["category"] = new Variant.string ("x-singularity.calendar");
            string[] actions = { "default", _("Open"), "snooze", _("Snooze 5 Minutes") };
            uint id = SystemMonitor.get_default ().notifications.notify (_("Calendar"), 0, "x-office-calendar",
                evt.title != "" ? evt.title : _("Event"), body, actions, hints, -1);
            shown[id] = evt;
        }

        private void on_action (uint id, string action) {
            if (!shown.has_key (id)) return;
            var evt = shown[id];
            shown.unset (id);
            if (action == "snooze") {
                snoozed.add (evt);
                snoozed_until.add (new DateTime.now_local ().add_minutes (5).to_unix ().to_string ());
                return;
            }
            var info = new DesktopAppInfo ("dev.sinty.calendar.desktop");
            if (info == null) return;
            try {
                info.launch (null, null);
            } catch (Error e) {
                warning ("Failed to open Calendar: %s", e.message);
            }
        }
    }
}
