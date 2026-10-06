using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public delegate void FocusTileAction();

    public class FocusQuickTile : Object {
        public static void sync(QuickSettingTile tile) {
            var focus = FocusManager.get_default();
            var state = focus.state;
            if (state.active) {
                tile.active = true;
                tile.title = FocusManager.display_name(state.mode);
                tile.icon_name = state.mode.icon_name;
                tile.subtitle = state.reason == FocusReason.MANUAL ? until_label(focus.until) : FocusManager.reason_label(state.reason);
            } else {
                var mode = focus.modes.find(focus.manual_mode_id) ?? focus.modes.find(FocusMode.DO_NOT_DISTURB);
                tile.active = false;
                tile.title = mode != null ? FocusManager.display_name(mode) : _("Focus");
                tile.icon_name = mode != null ? mode.icon_name : "notifications-disabled-symbolic";
                tile.subtitle = _("Off");
            }
        }

        public static void sync_indicator(Widget button, Image icon) {
            var state = FocusManager.get_default().state;
            if (state.active) {
                icon.icon_name = state.mode.icon_name;
                button.add_css_class("focus-active");
                button.tooltip_text = _("%s is on").printf(FocusManager.display_name(state.mode));
            } else {
                icon.icon_name = "preferences-system-notifications-symbolic";
                button.remove_css_class("focus-active");
                button.tooltip_text = _("Notifications");
            }
        }

        public static string until_label(int64 until) {
            if (until <= 0) return _("On");
            var t = new DateTime.from_unix_local(until);
            return _("Until %s").printf(t.format("%H:%M"));
        }

        public static Widget wrap(QuickSettingTile tile, owned FocusTileAction show_detail) {
            var wrapper = new Box(Orientation.HORIZONTAL, 0);
            wrapper.add_css_class("quick-setting-group");
            tile.hexpand = true;
            wrapper.append(tile);
            var nav_btn = new Button();
            nav_btn.has_frame = false;
            nav_btn.add_css_class("quick-setting-nav-btn");
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            nav_btn.set_child(chevron);
            nav_btn.valign = Align.FILL;
            nav_btn.tooltip_text = _("Choose a Focus mode");
            nav_btn.clicked.connect(() => show_detail());
            wrapper.append(nav_btn);
            var long_press = new GestureLongPress();
            long_press.propagation_phase = PropagationPhase.NONE;
            long_press.pressed.connect((x, y) => {
                long_press.set_state(EventSequenceState.CLAIMED);
                show_detail();
            });
            tile.add_controller(long_press);
            tile.set_data<GestureLongPress>("quick-setting-long-press", long_press);
            return wrapper;
        }

        public static Widget detail(owned FocusTileAction open_settings) {
            var box = new Box(Orientation.VERTICAL, 0);
            var modes_group = new PreferencesGroup(_("Modes"), _("Only the people and apps you allow can reach you."));
            var durations = new PreferencesGroup(_("Duration"));
            box.append(modes_group);
            box.append(durations);
            durations.margin_top = 12;
            var focus = FocusManager.get_default();

            uint selected_minutes = 0;
            string[] labels = { _("Until Turned Off"), _("For 1 Hour"), _("Until Tomorrow Morning") };
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            for (int i = 0; i < labels.length; i++) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = i.to_string();
                o.label = labels[i];
                options.add(o);
            }
            var duration_row = new SelectionRow.with_options(_("Keep On"), options, "0");
            duration_row.selected.connect((id) => {
                switch (id) {
                    case "1": selected_minutes = 60; break;
                    case "2":
                        var now = new DateTime.now_local();
                        var morning = new DateTime.local(now.get_year(), now.get_month(), now.get_day_of_month(), 7, 0, 0);
                        if (morning.compare(now) <= 0) morning = morning.add_days(1);
                        selected_minutes = (uint) ((morning.to_unix() - now.to_unix()) / 60);
                        break;
                    default: selected_minutes = 0; break;
                }
            });
            durations.add_row(duration_row);

            FocusTileAction fill = () => {};
            fill = () => {
                modes_group.clear();
                var state = focus.state;
                foreach (var mode in focus.modes.modes) {
                    bool on = state.active && state.mode.id == mode.id;
                    var row = new ActionRow(FocusManager.display_name(mode),
                        on ? FocusManager.reason_label(state.reason) : _("Off"), mode.icon_name);
                    row.activatable = true;
                    if (on) {
                        var check = new Image.from_icon_name("object-select-symbolic");
                        check.valign = Align.CENTER;
                        row.add_suffix(check);
                    }
                    string id = mode.id;
                    row.activated.connect(() => {
                        if (on) focus.deactivate();
                        else focus.activate(id, selected_minutes);
                    });
                    modes_group.add_row(row);
                }
            };
            fill();
            ulong h = focus.changed.connect(() => fill());
            box.destroy.connect(() => focus.disconnect(h));

            var settings_btn = new Button.with_label(_("Focus Settings"));
            settings_btn.halign = Align.CENTER;
            settings_btn.margin_top = 16;
            settings_btn.margin_bottom = 8;
            settings_btn.add_css_class("pill");
            settings_btn.clicked.connect(() => open_settings());
            box.append(settings_btn);
            return box;
        }
    }
}
