using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    internal delegate void PowerRefresh();

    internal class PowerOptions {
        internal static string duration_label(int seconds) {
            if (seconds <= 0) return _("Never");
            if (seconds % 3600 == 0) {
                int hours = seconds / 3600;
                return ngettext("%d hour", "%d hours", hours).printf(hours);
            }
            if (seconds % 60 == 0) {
                int minutes = seconds / 60;
                return ngettext("%d minute", "%d minutes", minutes).printf(minutes);
            }
            return ngettext("%d second", "%d seconds", seconds).printf(seconds);
        }

        internal static Gee.ArrayList<Singularity.Core.AppSettingOption> durations(int[] presets, int current) {
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            bool known = current in presets;
            foreach (int seconds in presets) {
                if (!known && (seconds == 0 || seconds > current)) {
                    options.add(option(current));
                    known = true;
                }
                options.add(option(seconds));
            }
            return options;
        }

        private static Singularity.Core.AppSettingOption option(int seconds) {
            return new Singularity.Core.AppSettingOption() {
                id = seconds.to_string(), label = duration_label(seconds)
            };
        }

        internal static SelectionRow duration_row(string title, GLib.Settings settings, string key, int[] presets) {
            int current = settings.get_int(key);
            var row = new SelectionRow.with_options(title, durations(presets, current), current.to_string());
            row.selected.connect((id) => settings.set_int(key, int.parse(id)));
            settings.changed[key].connect(() => row.current_value = settings.get_int(key).to_string());
            return row;
        }
    }

    public class PowerPage : SettingsPage {
        private const int[] BLANK_PRESETS = { 60, 120, 180, 300, 600, 900, 1800, 3600, 0 };
        private const int[] SUSPEND_PRESETS = { 300, 600, 900, 1200, 1800, 2700, 3600, 7200, 0 };
        private const int[] LOCK_PRESETS = { 60, 120, 300, 600, 900, 1800, 3600, 0 };

        private SettingsView view;
        private GLib.Settings settings;
        private PreferencesGroup inhibit_group;
        private PreferencesGroup battery_group;
        private ActionRow battery_row;
        private Gee.ArrayList<Widget> inhibit_rows = new Gee.ArrayList<Widget>();

        public PowerPage(SettingsView view) {
            base(_("Power"));
            this.view = view;
            settings = new GLib.Settings("dev.sinty.desktop");
            back_clicked.connect(() => view.go_home());

            build_inhibitors();
            build_battery();
            build_idle();
            build_profile();
            build_buttons();

            var inhibitors = IdleInhibitors.get_default();
            inhibitors.changed.connect(update_inhibitors);
            update_inhibitors();
            BatteryManager.get_default().changed.connect(update_battery);
            map.connect(() => BatteryManager.get_default().refresh());
        }

        private void build_inhibitors() {
            inhibit_group = new PreferencesGroup(_("Kept Awake"),
                _("While these apps need it, the screen stays on and the computer does not suspend"));
            add_group(inhibit_group);
        }

        private void update_inhibitors() {
            foreach (var row in inhibit_rows) inhibit_group.remove_row(row);
            inhibit_rows.clear();
            var inhibitors = IdleInhibitors.get_default();
            foreach (var inhibitor in inhibitors.inhibitors) {
                if ((inhibitor.flags & (IdleInhibitors.IDLE | IdleInhibitors.SUSPEND)) == 0) continue;
                string title = (inhibitor.flags & IdleInhibitors.IDLE) != 0
                    ? _("Screen kept on by %s").printf(inhibitor.display_name)
                    : _("Suspend blocked by %s").printf(inhibitor.display_name);
                var row = new ActionRow(title, inhibitor.reason != "" ? inhibitor.reason : null);
                row.activatable = false;
                var icon = inhibitor.icon;
                var image = icon != null ? new Image.from_gicon(icon) : new Image.from_icon_name("application-x-executable-symbolic");
                image.pixel_size = 24;
                image.margin_end = 12;
                row.add_prefix(image);
                inhibit_group.add_row(row);
                inhibit_rows.add(row);
            }
            if (inhibitors.window_inhibit) {
                var row = new ActionRow(_("Screen kept on by an open window"),
                    _("A window asked the compositor to stay awake, for example a video playing full screen"),
                    "video-display-symbolic");
                row.activatable = false;
                inhibit_group.add_row(row);
                inhibit_rows.add(row);
            }
            inhibit_group.visible = inhibit_rows.size > 0;
        }

        private void build_battery() {
            battery_group = new PreferencesGroup(_("Battery"));
            battery_row = new ActionRow(_("Health and Charging"), null, "battery-full-charged-symbolic");
            battery_row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
            battery_row.activated.connect(() => view.open_subpage(new BatteryPage(view), "power-battery"));
            battery_group.add_row(battery_row);
            add_group(battery_group);
            update_battery();
        }

        private void update_battery() {
            var battery = BatteryManager.get_default().primary;
            battery_group.visible = battery != null;
            if (battery == null) return;
            string level = battery.level >= 0 ? _("%d%% charged").printf(battery.level) : "";
            string health = battery.health >= 0 ? _("%d%% of original capacity").printf(battery.health) : "";
            battery_row.subtitle = level != "" && health != "" ? "%s, %s".printf(level, health) : level + health;
        }

        private bool has_battery() {
            return BatteryManager.get_default().primary != null || IdleManager.get_default().on_battery;
        }

        private void build_idle() {
            var group = new PreferencesGroup(_("When Inactive"));
            var dim_row = new SwitchRow(_("Dim the Screen"),
                _("Dim the screens shortly before they turn off"), settings.get_boolean("idle-dim-screen"));
            settings.bind("idle-dim-screen", dim_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            group.add_row(dim_row);

            var source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup("dev.sinty.lockscreen", true) != null) {
                var lock_settings = new GLib.Settings("dev.sinty.lockscreen");
                int current = lock_settings.get_boolean("lock-enabled") ? lock_settings.get_int("idle-delay") : 0;
                var lock_row = new SelectionRow.with_options(_("Lock the Screen"),
                    PowerOptions.durations(LOCK_PRESETS, current), current.to_string());
                lock_row.selected.connect((id) => {
                    int seconds = int.parse(id);
                    if (seconds > 0) lock_settings.set_int("idle-delay", seconds);
                    lock_settings.set_boolean("lock-enabled", seconds > 0);
                });
                lock_settings.changed.connect((key) => {
                    if (key != "idle-delay" && key != "lock-enabled") return;
                    int seconds = lock_settings.get_boolean("lock-enabled") ? lock_settings.get_int("idle-delay") : 0;
                    lock_row.current_value = seconds.to_string();
                });
                group.add_row(lock_row);
            }

            if (has_battery()) {
                group.add_row(idle_link(_("Plugged In"), "ac-adapter-symbolic", false));
                group.add_row(idle_link(_("On Battery"), "battery-level-50-symbolic", true));
            } else {
                group.add_row(PowerOptions.duration_row(_("Turn Off the Screen"), settings, "screen-blank-ac", BLANK_PRESETS));
                group.add_row(suspend_row(settings, "suspend-idle-ac"));
            }
            add_group(group);
        }

        private ActionRow idle_link(string title, string icon, bool battery) {
            var row = new ActionRow(title, null, icon);
            row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
            string blank_key = battery ? "screen-blank-battery" : "screen-blank-ac";
            string suspend_key = battery ? "suspend-idle-battery" : "suspend-idle-ac";
            PowerRefresh update = () => {
                row.subtitle = _("Screen off: %s. Suspend: %s").printf(
                    PowerOptions.duration_label(settings.get_int(blank_key)),
                    PowerOptions.duration_label(settings.get_int(suspend_key)));
            };
            update();
            settings.changed[blank_key].connect(() => update());
            settings.changed[suspend_key].connect(() => update());
            row.activated.connect(() => view.open_subpage(new PowerIdlePage(view, battery), battery ? "power-battery-idle" : "power-ac-idle"));
            return row;
        }

        internal static SelectionRow suspend_row(GLib.Settings settings, string key) {
            var row = PowerOptions.duration_row(_("Suspend"), settings, key, SUSPEND_PRESETS);
            var actions = PowerActions.get_default();
            PowerRefresh update = () => {
                row.sensitive = actions.can_suspend;
                row.subtitle = actions.can_suspend ? "" : _("Suspend is not available on this system");
            };
            update();
            actions.notify["can-suspend"].connect(() => update());
            return row;
        }

        internal static SelectionRow blank_row(GLib.Settings settings, string key) {
            return PowerOptions.duration_row(_("Turn Off the Screen"), settings, key, BLANK_PRESETS);
        }

        private void build_profile() {
            var ppm = SystemMonitor.get_default().power_profiles;
            var extreme = ExtremeModeManager.get_default();
            var group = new PreferencesGroup(_("Power Mode"));
            string[] labels = { "Extreme Save", "Power Saver", "Balanced", "Performance" };
            var row = new SelectionRow(_("Mode"), labels, PerformancePage.current_profile_label(ppm, extreme));
            row.selected.connect((item) => PerformancePage.apply_profile_label(ppm, extreme, item));
            ppm.profile_changed.connect(() => row.current_value = PerformancePage.current_profile_label(ppm, extreme));
            group.add_row(row);
            group.visible = ppm.available;
            ppm.notify["available"].connect(() => group.visible = ppm.available);
            add_group(group);
        }

        private void build_buttons() {
            var group = new PreferencesGroup(_("Buttons and Lid"));
            var button_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            string[] ids = { "ask", "suspend", "power-off", "lock", "nothing" };
            string[] names = { _("Ask What to Do"), _("Suspend"), _("Power Off"), _("Lock the Screen"), _("Do Nothing") };
            for (int i = 0; i < ids.length; i++) {
                button_options.add(new Singularity.Core.AppSettingOption() { id = ids[i], label = names[i] });
            }
            var button_row = new SelectionRow.with_options(_("Power Button"), button_options,
                settings.get_string("power-button-action"));
            button_row.selected.connect((id) => settings.set_string("power-button-action", id));
            group.add_row(button_row);

            var lid = LidManager.get_default();
            var lid_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            string[] lid_ids = { "suspend", "lock", "nothing" };
            string[] lid_names = { _("Suspend"), _("Lock the Screen"), _("Do Nothing") };
            for (int i = 0; i < lid_ids.length; i++) {
                lid_options.add(new Singularity.Core.AppSettingOption() { id = lid_ids[i], label = lid_names[i] });
            }
            var lid_row = new SelectionRow.with_options(_("When the Lid Is Closed"), lid_options,
                settings.get_string("lid-close-action"));
            lid_row.selected.connect((id) => settings.set_string("lid-close-action", id));
            group.add_row(lid_row);

            var docked_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            docked_options.add(new Singularity.Core.AppSettingOption() { id = "keep-working", label = _("Keep Working") });
            docked_options.add(new Singularity.Core.AppSettingOption() { id = "suspend", label = _("Suspend") });
            var docked_row = new SelectionRow.with_options(_("With an External Display"), docked_options,
                settings.get_string("lid-close-docked-action"));
            docked_row.selected.connect((id) => settings.set_string("lid-close-docked-action", id));
            group.add_row(docked_row);

            lid_row.visible = lid.lid_present;
            docked_row.visible = lid.lid_present;
            lid.notify["lid-present"].connect(() => {
                lid_row.visible = lid.lid_present;
                docked_row.visible = lid.lid_present;
            });
            add_group(group);
        }
    }

    public class PowerIdlePage : SettingsPage {
        public PowerIdlePage(SettingsView view, bool battery) {
            base(battery ? _("On Battery") : _("Plugged In"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("power"));
            var settings = new GLib.Settings("dev.sinty.desktop");
            var group = new PreferencesGroup(_("After Inactivity"));
            group.add_row(PowerPage.blank_row(settings, battery ? "screen-blank-battery" : "screen-blank-ac"));
            group.add_row(PowerPage.suspend_row(settings, battery ? "suspend-idle-battery" : "suspend-idle-ac"));
            add_group(group);
        }
    }

    public class BatteryPage : SettingsPage {
        private Box groups_box;
        private PreferencesGroup charging_group;
        private SwitchRow limit_row;
        private bool syncing = false;

        public BatteryPage(SettingsView view) {
            base(_("Battery"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("power"));
            groups_box = new Box(Orientation.VERTICAL, 18);
            add_widget(groups_box);

            charging_group = new PreferencesGroup(_("Charging"));
            limit_row = new SwitchRow(_("Limit Charge to %d%%").printf(BatteryManager.LIMIT_PERCENT),
                _("Keeps the battery healthier when the computer stays plugged in most of the time"));
            limit_row.switch_btn.notify["active"].connect(on_limit_toggled);
            charging_group.add_row(limit_row);
            add_group(charging_group);

            var manager = BatteryManager.get_default();
            manager.changed.connect(rebuild);
            rebuild();
        }

        private void rebuild() {
            for (Widget? child = groups_box.get_first_child(); child != null; ) {
                Widget? next = child.get_next_sibling();
                groups_box.remove(child);
                child = next;
            }
            var manager = BatteryManager.get_default();
            var batteries = manager.batteries;
            for (int i = 0; i < batteries.size; i++) {
                groups_box.append(health_group(batteries[i], batteries.size > 1 ? i + 1 : 0));
            }
            if (batteries.size == 0) {
                var empty = new StatusPage();
                empty.compact = true;
                empty.icon_name = "battery-missing-symbolic";
                empty.title = _("No Battery");
                empty.description = _("This computer runs on external power only.");
                groups_box.append(empty);
            }
            sync_limit();
        }

        private PreferencesGroup health_group(BatteryHealth battery, int index) {
            var group = new PreferencesGroup(index > 0 ? _("Battery %d").printf(index) : _("Health"),
                battery.model != "" ? battery.model : null);
            var health = new ActionRow(_("Maximum Capacity"),
                battery.health >= 0 ? _("Compared with the capacity when new") : _("This battery does not report its capacity"));
            health.activatable = false;
            if (battery.health >= 0) health.add_suffix(value_label("%d%%".printf(battery.health)));
            group.add_row(health);

            var cycles = new ActionRow(_("Charge Cycles"),
                battery.cycles >= 0 ? null : _("This battery does not count its cycles"));
            cycles.activatable = false;
            if (battery.cycles >= 0) cycles.add_suffix(value_label(battery.cycles.to_string()));
            group.add_row(cycles);

            var level = new ActionRow(_("Charge"), status_text(battery.status));
            level.activatable = false;
            if (battery.level >= 0) level.add_suffix(value_label("%d%%".printf(battery.level)));
            group.add_row(level);

            var graph = new BatteryHistoryGraph();
            var graph_row = new PreferencesRow();
            graph_row.activatable = false;
            graph_row.set_child(graph);
            graph_row.visible = false;
            group.add_row(graph_row);
            BatteryManager.get_default().history.begin(battery.name, 86400, 96, (obj, res) => {
                var points = BatteryManager.get_default().history.end(res);
                graph.set_points(points);
                graph_row.visible = points.size >= 2;
            });
            return group;
        }

        private static Label value_label(string text) {
            var label = new Label(text);
            label.add_css_class("dim-label");
            return label;
        }

        private static string? status_text(string status) {
            switch (status) {
                case "Charging": return _("Charging");
                case "Discharging": return _("On battery power");
                case "Full": return _("Fully charged");
                case "Not charging": return _("Plugged in, not charging");
                default: return null;
            }
        }

        private void sync_limit() {
            var manager = BatteryManager.get_default();
            syncing = true;
            limit_row.switch_btn.active = manager.charge_limit_active;
            syncing = false;
            bool any_battery = manager.primary != null;
            charging_group.visible = any_battery;
            limit_row.sensitive = manager.charge_limit_available;
            if (manager.charge_limit_available) {
                limit_row.subtitle = manager.charge_limit_active
                    ? _("Charging stops at %d%% to keep the battery healthier").printf(BatteryManager.LIMIT_PERCENT)
                    : _("Keeps the battery healthier when the computer stays plugged in most of the time");
            } else if (manager.charge_limit_backend == null) {
                limit_row.subtitle = _("Charge limits are turned off on this system");
            } else {
                limit_row.subtitle = _("This battery does not support a charge limit");
            }
        }

        private void on_limit_toggled() {
            if (syncing) return;
            bool wanted = limit_row.switch_btn.active;
            limit_row.sensitive = false;
            BatteryManager.get_default().set_charge_limited.begin(wanted, (obj, res) => {
                try {
                    BatteryManager.get_default().set_charge_limited.end(res);
                    sync_limit();
                } catch (Error e) {
                    sync_limit();
                    limit_row.subtitle = _("Could not change the charge limit: %s").printf(e.message);
                }
            });
        }
    }

    public class BatteryHistoryGraph : DrawingArea {
        private Gee.List<HistoryPoint> points = new Gee.ArrayList<HistoryPoint>();

        public BatteryHistoryGraph() {
            content_height = 96;
            hexpand = true;
            margin_start = 12;
            margin_end = 12;
            margin_top = 8;
            margin_bottom = 10;
            tooltip_text = _("Charge over the last 24 hours");
            set_draw_func(draw);
        }

        public void set_points(Gee.List<HistoryPoint> points) {
            this.points = points;
            queue_draw();
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            var color = get_color();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.12);
            cr.set_line_width(1);
            for (int i = 0; i <= 4; i++) {
                double y = Math.floor(i * (height - 1) / 4.0) + 0.5;
                cr.move_to(0, y);
                cr.line_to(width, y);
            }
            cr.stroke();
            if (points.size < 2) return;
            uint32 start = points[0].time;
            uint32 span = uint32.max(points[points.size - 1].time - start, 1);
            cr.set_source_rgba(color.red, color.green, color.blue, 0.85);
            cr.set_line_width(2);
            cr.set_line_join(Cairo.LineJoin.ROUND);
            for (int i = 0; i < points.size; i++) {
                double x = (points[i].time - start) * (width - 2.0) / span + 1;
                double y = (height - 2) - points[i].value.clamp(0, 100) * (height - 4) / 100.0 + 1;
                if (i == 0) cr.move_to(x, y);
                else cr.line_to(x, y);
            }
            cr.stroke();
        }
    }
}
