using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class PrivacyCategory : Object {
        public string id { get; construct; }
        public string title { get; construct; }
        public string icon_name { get; construct; }
        public string large_icon { get; construct; }
        public string description { get; construct; }
        public string empty_title { get; construct; }
        public string empty_description { get; construct; }
        public string master_key { get; set; default = ""; }
        public string master_title { get; set; default = ""; }
        public string master_subtitle { get; set; default = ""; }

        public PrivacyCategory(string id, string title, string icon_name, string large_icon, string description,
                               string empty_title, string empty_description) {
            Object(id: id, title: title, icon_name: icon_name, large_icon: large_icon, description: description,
                   empty_title: empty_title, empty_description: empty_description);
        }

        public static PrivacyCategory? find(string id) {
            foreach (var category in all()) {
                if (category.id == id) return category;
            }
            return null;
        }

        public static PrivacyCategory[] all() {
            var camera = new PrivacyCategory("camera", _("Camera"), "camera-web-symbolic", "camera-web",
                _("Apps that asked to use a camera. Turn an app off to block it."),
                _("No Camera Requests"), _("Apps that ask to use a camera appear here."));
            camera.master_key = "privacy-camera-enabled";
            camera.master_title = _("Camera Access");
            camera.master_subtitle = _("Let apps ask to use cameras");

            var microphone = new PrivacyCategory("microphone", _("Microphone"), "audio-input-microphone-symbolic",
                "audio-input-microphone",
                _("Apps allowed to record sound. Blocking depends on the audio system of this computer."),
                _("No Microphone Requests"), _("Apps that ask to record sound appear here."));
            microphone.master_key = "privacy-microphone-enabled";
            microphone.master_title = _("Microphone Access");
            microphone.master_subtitle = _("Let apps ask to record sound");

            var location = new PrivacyCategory("location", _("Location"), "find-location-symbolic", "find-location",
                _("Apps that asked for your location."),
                _("No Location Requests"), _("Apps that ask where you are appear here."));
            location.master_key = "privacy-location-enabled";
            location.master_title = _("Location Services");
            location.master_subtitle = _("Let apps ask for your location");

            return {
                camera,
                microphone,
                location,
                new PrivacyCategory("screenshot", _("Screenshots"), "applets-screenshooter-symbolic", "applets-screenshooter",
                    _("Apps allowed to take screenshots without asking each time."),
                    _("No Screenshot Requests"), _("Apps that ask to take screenshots appear here.")),
                new PrivacyCategory("screencast", _("Screen Sharing"), "video-display-symbolic", "video-display",
                    _("Apps that can share or record your screen again without asking."),
                    _("No Saved Screen Sharing"), _("Apps you let share your screen appear here when they remember the choice.")),
                new PrivacyCategory("background", _("Background Activity"), "system-run-symbolic", "system-run",
                    _("Apps allowed to keep running with no open windows."),
                    _("No Background Apps"), _("Apps that keep running after you close them appear here.")),
                new PrivacyCategory("autostart", _("Autostart"), "system-run-symbolic", "singularity-autostart",
                    _("Apps that asked to start when you log in."),
                    _("No Apps Start at Login"), _("Apps that ask to start when you log in appear here.")),
                new PrivacyCategory("shortcuts", _("Global Shortcuts"), "input-keyboard-symbolic", "input-keyboard",
                    _("Keyboard shortcuts that work while the app is in the background."),
                    _("No Global Shortcuts"), _("Apps that ask for shortcuts that work everywhere appear here.")),
                new PrivacyCategory("notifications", _("Notifications"), "preferences-system-notifications-symbolic",
                    "preferences-system-notifications",
                    _("Apps allowed to show notifications through the notification portal."),
                    _("No Notification Requests"), _("Sandboxed apps that send notifications appear here.")),
                new PrivacyCategory("files", _("File Access"), "folder-symbolic", "folder",
                    _("Folders sandboxed apps can open without asking. Open an app to change them."),
                    _("No Sandboxed Apps"), _("Flatpak apps and the folders they can open appear here."))
            };
        }
    }

    public class PrivacyPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup in_use_group;
        private PreferencesGroup recent_group;
        private Gee.HashMap<string, ActionRow> rows = new Gee.HashMap<string, ActionRow>();
        private uint poll_id = 0;
        private bool refreshing = false;

        public const int RECENT_LIMIT = 3;

        public PrivacyPage(SettingsView view) {
            base(_("Privacy"));
            this.view = view;
            back_clicked.connect(() => view.go_home());

            in_use_group = new PreferencesGroup(_("In Use Now"),
                _("Apps using your camera or microphone, or running in the background."));
            in_use_group.visible = false;
            add_group(in_use_group);

            recent_group = new PreferencesGroup(_("Recently Used"));
            recent_group.visible = false;
            add_group(recent_group);

            var devices = new PreferencesGroup(_("Devices"), _("Choose which apps can use your hardware."));
            add_category_rows(devices, { "camera", "microphone", "location" });
            add_group(devices);

            var screen = new PreferencesGroup(_("Screen"));
            add_category_rows(screen, { "screenshot", "screencast" });
            add_group(screen);

            var activity = new PreferencesGroup(_("Activity"), _("What apps can do when you are not using them."));
            add_category_rows(activity, { "background", "autostart", "shortcuts", "notifications" });
            add_group(activity);

            var files = new PreferencesGroup(_("Files"));
            add_category_rows(files, { "files" });
            add_group(files);

            add_group(new CrashReportsGroup());
            add_search_action(_("Crash Reports"), _("What happens when an app quits unexpectedly"), () => view.navigate_to("privacy"));

            foreach (var category in PrivacyCategory.all()) {
                string id = category.id;
                add_search_action(category.title, category.description, () => view.navigate_to("privacy-" + id));
            }

            map.connect(() => {
                refresh.begin();
                if (poll_id == 0) poll_id = Timeout.add_seconds(3, () => {
                    refresh_in_use.begin();
                    return Source.CONTINUE;
                });
            });
            unmap.connect(() => {
                if (poll_id != 0) Source.remove(poll_id);
                poll_id = 0;
            });
            BackgroundApps.get_default().changed.connect(() => refresh_in_use.begin());
            PermissionStore.get_default().changed.connect(() => refresh.begin());
            Sandbox.Backends.get_default().changed.connect(() => refresh.begin());
            Privacy.Usage.get_default().changed.connect(() => refresh_recent.begin());
            refresh.begin();
        }

        private void add_category_rows(PreferencesGroup group, string[] ids) {
            foreach (string id in ids) {
                var category = PrivacyCategory.find(id);
                var row = new ActionRow(category.title, null, category.icon_name);
                row.activatable = true;
                row.add_suffix(PermissionRows.chevron());
                row.activated.connect(() => view.navigate_to("privacy-" + id));
                rows[id] = row;
                group.add_row(row);
            }
        }

        private async void refresh() {
            if (refreshing) return;
            refreshing = true;
            var settings = new GLib.Settings("dev.sinty.desktop");
            var backends = Sandbox.Backends.get_default();
            var apps = yield backends.apps();
            foreach (var category in PrivacyCategory.all()) {
                var row = rows[category.id];
                if (row == null) continue;
                if (category.master_key != "" && settings.settings_schema.has_key(category.master_key)
                    && !settings.get_boolean(category.master_key)) {
                    row.subtitle = _("Off for all apps");
                    continue;
                }
                if (category.id == "files") {
                    int n = apps.length;
                    row.subtitle = n == 0 ? _("No sandboxed apps")
                        : ngettext("%d sandboxed app", "%d sandboxed apps", (ulong) n).printf(n);
                    continue;
                }
                int total = (yield Privacy.Source.create(category.id).load()).length;
                foreach (var app in apps) {
                    var backend = backends.find(app.backend);
                    if (backend == null) continue;
                    var permission = yield backend.category_permission(app, category.id);
                    if (permission != null && (permission.enabled || permission.overridden)) total++;
                }
                row.subtitle = total == 0 ? _("No apps")
                    : ngettext("%d app", "%d apps", (ulong) total).printf(total);
            }
            yield refresh_in_use();
            yield refresh_recent();
            refreshing = false;
        }

        private async void refresh_in_use() {
            in_use_group.clear();
            int count = 0;
            foreach (var client in yield PrivacyInUse.camera()) {
                in_use_group.add_row(app_row(client.app_id, client.name, _("Using the camera"), "camera-web-symbolic"));
                count++;
            }
            foreach (var client in yield PrivacyInUse.microphone()) {
                in_use_group.add_row(app_row(client.app_id, client.name, _("Using the microphone"),
                    "audio-input-microphone-symbolic"));
                count++;
            }
            var background = BackgroundApps.get_default();
            yield background.start();
            foreach (var app in background.list()) {
                Privacy.Usage.get_default().record(app.app_id, "background");
                in_use_group.add_row(app_row(app.app_id, app.display_name,
                    app.message != "" ? app.message : _("Running in the background"), "system-run-symbolic"));
                count++;
            }
            in_use_group.visible = count > 0;
        }

        private async void refresh_recent() {
            var usage = Privacy.Usage.get_default();
            foreach (var grant in yield Privacy.Source.create("location").load()) {
                if (grant.last_used > 0) usage.record(grant.app_id, "location", grant.last_used);
            }
            recent_group.clear();
            int count = 0;
            int64 now = get_real_time();
            foreach (var entry in usage.recent(now, TimeSpan.DAY)) {
                if (count >= RECENT_LIMIT) break;
                string when = Privacy.Apps.ago(entry.when, now);
                string what = _("%s: %s").printf(PermissionRows.category_title(entry.category), when);
                recent_group.add_row(app_row(entry.app_id, entry.app_id, what, PermissionRows.category_icon(entry.category)));
                count++;
            }
            recent_group.visible = count > 0;
        }

        private ActionRow app_row(string? app_id, string name, string what, string icon_name) {
            string title = app_id != null && app_id != "" ? Privacy.Apps.display_name(app_id) : name;
            var row = new ActionRow(title != "" ? title : _("Unknown App"), what, icon_name);
            if (app_id != null && app_id != "" && PermissionRows.app_info_for(app_id) != null) {
                row.activatable = true;
                row.add_suffix(PermissionRows.chevron());
                string target = app_id;
                row.activated.connect(() => PermissionRows.open_app(view, target, "privacy"));
            } else {
                row.activatable = false;
            }
            return row;
        }
    }
}
