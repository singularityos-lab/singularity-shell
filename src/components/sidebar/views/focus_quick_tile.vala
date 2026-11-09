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
                tile.subtitle = focus.profile_name != "" ? focus.profile_name : _("Off");
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
            nav_btn.tooltip_text = _("Choose Focus or a profile");
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
            var modes_group = new PreferencesGroup(_("Focus"), _("Only the people and apps you allow can reach you."));
            var durations = new PreferencesGroup(_("Duration"));
            var profiles_group = new PreferencesGroup(_("Profiles"), _("A profile changes the settings you chose for it."));
            box.append(modes_group);
            box.append(durations);
            box.append(profiles_group);
            profiles_group.margin_top = 12;
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
                var dnd = focus.modes.find(FocusMode.DO_NOT_DISTURB);
                if (dnd != null) {
                    var mode = dnd;
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

            var client = Singularity.Profiles.Client.get_default();
            FocusTileAction fill_profiles = () => {};
            fill_profiles = () => {
                client.load.begin((o, res) => {
                    Singularity.Profiles.ProfileSet set;
                    try {
                        set = client.load.end(res);
                    } catch (Error e) {
                        profiles_group.clear();
                        profiles_group.add_row(new ActionRow(_("Profiles Are Not Running"), e.message, "dialog-warning-symbolic"));
                        return;
                    }
                    profiles_group.clear();
                    foreach (var p in set.profiles) {
                        bool on = client.active_profile == p.id;
                        var row = new ActionRow(Singularity.Profiles.display_name(p),
                            on ? (client.detail != "" ? client.detail : _("On")) : _("Off"), p.icon_name);
                        row.activatable = true;
                        if (on) {
                            var check = new Image.from_icon_name("object-select-symbolic");
                            check.valign = Align.CENTER;
                            row.add_suffix(check);
                        }
                        string id = p.id;
                        row.activated.connect(() => {
                            if (on) client.deactivate.begin();
                            else client.activate.begin(id, "menu");
                        });
                        profiles_group.add_row(row);
                    }
                });
            };
            fill_profiles();
            ulong h2 = client.status_changed.connect(() => fill_profiles());
            ulong h3 = client.profiles_changed.connect(() => fill_profiles());
            box.destroy.connect(() => {
                client.disconnect(h2);
                client.disconnect(h3);
            });

            var settings_btn = new Button.with_label(_("Profiles and Focus Settings"));
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
