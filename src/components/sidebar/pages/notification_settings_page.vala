using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class NotificationSettingsPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup focus_group;
        private PreferencesGroup apps_group;
        private AppNotificationSettings store;
        private Gee.ArrayList<ulong> _focus_handlers = new Gee.ArrayList<ulong>();

        public NotificationSettingsPage(SettingsView view) {
            base(_("Notifications"));
            this.view = view;
            store = AppNotificationSettings.get_default();
            back_clicked.connect(() => view.go_home());

            if (!store.available) {
                var missing = new StatusPage();
                missing.icon_name = "preferences-system-notifications";
                missing.title = _("Notification Settings Unavailable");
                missing.description = _("The notification settings schema is not installed on this system.");
                add_widget(missing);
                return;
            }

            focus_group = new PreferencesGroup(_("Focus"),
                _("Silence notifications while you work, sleep or play. Silenced notifications wait quietly in the notification centre."));
            add_group(focus_group);

            var history = new PreferencesGroup(_("Notification Centre"));
            history.add_row(retention_row());
            var sounds = new SwitchRow(_("Sounds"), _("Play a sound for apps that allow it"));
            store.settings.bind("sounds-enabled", sounds.switch_btn, "active", SettingsBindFlags.DEFAULT);
            history.add_row(sounds);
            var lock_row = new SwitchRow(_("Show on Lock Screen"), _("Each app chooses whether its content is shown"));
            store.settings.bind("lock-screen-enabled", lock_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            history.add_row(lock_row);
            add_group(history);

            apps_group = new PreferencesGroup(_("Apps"),
                _("Apps appear here once they send a notification."));
            add_group(apps_group);

            var focus = FocusManager.get_default();
            _focus_handlers.add(focus.changed.connect(rebuild_focus));
            _focus_handlers.add(focus.modes_changed.connect(rebuild_focus));
            ulong apps_handler = store.apps_changed.connect(rebuild_apps);
            destroy.connect(() => {
                foreach (ulong h in _focus_handlers) focus.disconnect(h);
                store.disconnect(apps_handler);
            });
            rebuild_focus();
            rebuild_apps();

            foreach (var mode in focus.modes.modes) {
                string id = mode.id;
                add_search_action(FocusManager.display_name(mode), _("Focus mode"), () => open_mode(id));
            }
        }

        private SelectionRow retention_row() {
            int[] days = { 0, 1, 7, 30 };
            string[] labels = { _("Until Restart"), _("1 Day"), _("1 Week"), _("1 Month") };
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            for (int i = 0; i < days.length; i++) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = days[i].to_string();
                o.label = labels[i];
                options.add(o);
            }
            var row = new SelectionRow.with_options(_("Keep History"), options,
                store.settings.get_int("history-retention-days").to_string());
            row.subtitle = _("Notifications stay in the centre after a restart for this long");
            row.selected.connect((id) => store.settings.set_int("history-retention-days", int.parse(id)));
            ulong h = store.settings.changed["history-retention-days"].connect(() => {
                row.current_value = store.settings.get_int("history-retention-days").to_string();
            });
            row.destroy.connect(() => store.settings.disconnect(h));
            return row;
        }

        public static string mode_summary(FocusMode mode) {
            var state = FocusManager.get_default().state;
            if (state.active && state.mode.id == mode.id) return FocusManager.reason_label(state.reason);
            string[] parts = {};
            int enabled = 0;
            foreach (var s in mode.schedules) {
                if (s.enabled) enabled++;
            }
            if (enabled > 0) parts += ngettext("%d schedule", "%d schedules", enabled).printf(enabled);
            if (mode.while_presenting) parts += _("when presenting");
            if (mode.while_fullscreen) parts += _("in full screen");
            if (parts.length == 0) return _("Off");
            return _("Off, turns on by itself: %s").printf(string.joinv(", ", parts));
        }

        private void rebuild_focus() {
            focus_group.clear();
            foreach (var mode in FocusManager.get_default().modes.modes) {
                var row = new ActionRow(FocusManager.display_name(mode), mode_summary(mode), mode.icon_name);
                row.activatable = true;
                var state = FocusManager.get_default().state;
                if (state.active && state.mode.id == mode.id) {
                    var on = new Label(_("On"));
                    on.add_css_class("focus-on-label");
                    on.valign = Align.CENTER;
                    row.add_suffix(on);
                }
                row.add_suffix(chevron());
                string id = mode.id;
                row.activated.connect(() => open_mode(id));
                focus_group.add_row(row);
            }
            var add_row = new ActionRow(_("Add Focus Mode…"), _("A mode with its own name, people and apps"), "list-add-symbolic");
            add_row.activatable = true;
            add_row.add_suffix(chevron());
            add_row.activated.connect(() => {
                var mode = FocusManager.get_default().add_mode(_("Custom"), "focus-custom-symbolic");
                open_mode(mode.id);
            });
            focus_group.add_row(add_row);
        }

        private void open_mode(string id) {
            var mode = FocusManager.get_default().modes.find(id);
            if (mode == null) return;
            view.open_subpage(new FocusModePage(view, mode), "focus-mode");
        }

        public static string app_summary(AppNotificationPolicy p) {
            if (!p.allowed) return _("Off");
            string[] parts = {};
            if (p.banners) parts += _("Banners");
            if (p.sounds) parts += _("Sounds");
            if (p.time_sensitive) parts += _("Time-sensitive");
            if (parts.length == 0) return _("Notification centre only");
            return string.joinv(", ", parts);
        }

        private void rebuild_apps() {
            apps_group.clear();
            string[] keys = store.known_apps();
            if (keys.length == 0) {
                var empty = new ActionRow(_("No Apps Yet"),
                    _("Apps that send notifications show up here, each with its own settings."),
                    "preferences-system-notifications-symbolic");
                apps_group.add_row(empty);
                return;
            }
            var sorted = new Gee.ArrayList<string>();
            foreach (string k in keys) sorted.add(k);
            sorted.sort((a, b) => store.display_name(a).collate(store.display_name(b)));
            foreach (string key in sorted) {
                var row = new ActionRow(store.display_name(key), app_summary(store.policy_for(key)));
                row.activatable = true;
                var img = new Image();
                img.pixel_size = 24;
                img.margin_end = 8;
                var gicon = store.icon_for(key);
                if (gicon != null) img.gicon = gicon;
                else img.icon_name = "application-x-executable";
                row.add_prefix(img);
                row.add_suffix(chevron());
                string k = key;
                row.activated.connect(() => view.open_subpage(new NotificationAppPage(view, k), "notification-app"));
                ulong h = store.app_changed.connect((changed) => {
                    if (changed == k) row.subtitle = app_summary(store.policy_for(k));
                });
                row.destroy.connect(() => store.disconnect(h));
                apps_group.add_row(row);
            }
        }

        public static Image chevron() {
            var c = new Image.from_icon_name("go-next-symbolic");
            c.pixel_size = 12;
            c.add_css_class("dim-label");
            c.valign = Align.CENTER;
            return c;
        }
    }

    public class NotificationAppPage : SettingsPage {
        public NotificationAppPage(SettingsView view, string key) {
            var store = AppNotificationSettings.get_default();
            base(store.display_name(key));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("notifications"));
            var s = store.for_app(key);

            var delivery = new PreferencesGroup(_("Delivery"));
            var allow = new SwitchRow(_("Allow Notifications"), _("Turned off, the app cannot notify you at all"));
            s.bind("enabled", allow.switch_btn, "active", SettingsBindFlags.DEFAULT);
            delivery.add_row(allow);
            var banners = new SwitchRow(_("Banners"), _("Show a banner on screen when a notification arrives"));
            s.bind("show-banners", banners.switch_btn, "active", SettingsBindFlags.DEFAULT);
            delivery.add_row(banners);
            var sounds = new SwitchRow(_("Sounds"), _("Play a sound when a notification arrives"));
            s.bind("sounds", sounds.switch_btn, "active", SettingsBindFlags.DEFAULT);
            delivery.add_row(sounds);
            add_group(delivery);

            var more = new PreferencesGroup(_("Privacy and Priority"));
            more.add_row(choice(s, "lock-screen", _("Lock Screen"),
                { "show", "hide-content", "hide" },
                { _("Show Content"), _("Hide Content"), _("Do Not Show") },
                { _("Title and text are visible while locked"), _("Only the app name is visible"), _("Nothing from this app while locked") }));
            more.add_row(choice(s, "priority", _("Priority"),
                { "normal", "time-sensitive" },
                { _("Normal"), _("Time-Sensitive") },
                { _("Waits while a Focus mode is on"), _("Comes through Focus modes that allow it") }));
            more.add_row(choice(s, "grouping", _("Grouping"),
                { "app", "off" },
                { _("Stack by App"), _("Off") },
                { _("Notifications from this app share one stack"), _("Every notification is shown on its own") }));
            add_group(more);

            s.changed["enabled"].connect(() => sync_sensitivity(s, banners, sounds, more));
            sync_sensitivity(s, banners, sounds, more);
        }

        private static void sync_sensitivity(GLib.Settings s, Widget a, Widget b, Widget c) {
            bool on = s.get_boolean("enabled");
            a.sensitive = on;
            b.sensitive = on;
            c.sensitive = on;
        }

        private static SelectionRow choice(GLib.Settings s, string key, string title, string[] ids, string[] labels,
                                           string?[] subtitles) {
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            for (int i = 0; i < ids.length; i++) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = ids[i];
                o.label = labels[i];
                o.subtitle = subtitles[i];
                options.add(o);
            }
            var row = new SelectionRow.with_options(title, options, s.get_string(key));
            row.selected.connect((id) => s.set_string(key, id));
            ulong h = s.changed[key].connect(() => row.current_value = s.get_string(key));
            row.destroy.connect(() => s.disconnect(h));
            return row;
        }
    }
}
