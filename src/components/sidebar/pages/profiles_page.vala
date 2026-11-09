using Gtk;
using Singularity.Widgets;
using Singularity.Profiles;

namespace Singularity.SidebarPages {

    public class ProfileEditor : Object {
        public Profile profile { get; set; }
        public Gee.ArrayList<AreaInfo> areas { get; set; default = new Gee.ArrayList<AreaInfo>(); }
        public Json.Object? facts { get; set; default = null; }
        private uint _save_id = 0;

        public ProfileEditor(Profile profile) {
            this.profile = profile;
        }

        public void commit() {
            if (_save_id != 0) Source.remove(_save_id);
            _save_id = Timeout.add(250, () => {
                _save_id = 0;
                save_now.begin();
                return Source.REMOVE;
            });
        }

        public async string save_now() {
            try {
                string id = yield Client.get_default().save(profile);
                profile.id = id;
                return id;
            } catch (Error e) {
                warning("profiles: could not save %s: %s", profile.id, e.message);
                return profile.id;
            }
        }

        public string[] fact_list(string key) {
            string[] out_list = {};
            if (facts == null || !facts.has_member(key)) return out_list;
            var node = facts.get_member(key);
            if (node.get_node_type() == Json.NodeType.ARRAY) {
                node.get_array().foreach_element((a, i, n) => {
                    if (n.get_value_type() == typeof(string) && n.get_string() != "") out_list += n.get_string();
                });
            } else if (node.get_value_type() == typeof(string) && node.get_string() != "") {
                out_list += node.get_string();
            }
            return out_list;
        }
    }

    public class ProfilesPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup status_group;
        private PreferencesGroup list_group;
        private ProfileSet? _set = null;
        private Gee.ArrayList<ulong> _handlers = new Gee.ArrayList<ulong>();

        public ProfilesPage(SettingsView view) {
            base(_("Profiles"));
            this.view = view;
            back_clicked.connect(() => view.go_home());

            status_group = new PreferencesGroup(_("Now"));
            add_group(status_group);
            list_group = new PreferencesGroup(_("Profiles"),
                _("A profile changes only what you pick. Everything set to Don't Change stays as you left it, and is put back when the profile ends."));
            add_group(list_group);

            var client = Client.get_default();
            _handlers.add(client.status_changed.connect(() => reload.begin()));
            _handlers.add(client.profiles_changed.connect(() => reload.begin()));
            destroy.connect(() => {
                foreach (ulong h in _handlers) client.disconnect(h);
            });
            foreach (string id in new string[] { "work", "evening", "game", "presentation", "sleep" }) {
                string pid = id;
                add_search_action(builtin_name(pid), _("Profile"), () => open_profile.begin(pid));
            }
            reload.begin();
        }

        private static string builtin_name(string id) {
            var p = new Profile(id, id, "", true);
            return display_name(p);
        }

        public static string profile_summary(Profile p, string active, string reason) {
            int enabled = 0;
            foreach (var r in p.rules) {
                if (r.enabled && r.conditions.size > 0) enabled++;
            }
            int changes = p.count_values();
            string what = changes == 0 ? _("Changes nothing yet")
                : ngettext("Changes %d setting", "Changes %d settings", changes).printf(changes);
            if (enabled == 0) return what;
            var first = p.rules[0];
            foreach (var r in p.rules) {
                if (r.enabled && r.conditions.size > 0) {
                    first = r;
                    break;
                }
            }
            return "%s, %s".printf(what, describe_rule(first));
        }

        private async void reload() {
            var client = Client.get_default();
            status_group.clear();
            list_group.clear();
            if (!client.available) {
                status_group.add_row(new ActionRow(_("Profiles Are Not Running"),
                    _("The profiles service did not start. Log out and back in to try again."), "dialog-warning-symbolic"));
                return;
            }
            try {
                _set = yield client.load();
            } catch (Error e) {
                status_group.add_row(new ActionRow(_("Profiles Are Not Running"), e.message, "dialog-warning-symbolic"));
                return;
            }
            string active = client.active_profile;
            var current = active != "" ? _set.find(active) : null;
            if (current != null) {
                var row = new ActionRow(display_name(current), client.detail != "" ? client.detail : _("On"), current.icon_name);
                var off = new Button.with_label(_("Turn Off"));
                off.valign = Align.CENTER;
                off.add_css_class("pill");
                off.clicked.connect(() => client.deactivate.begin());
                row.add_suffix(off);
                status_group.add_row(row);
            } else {
                status_group.add_row(new ActionRow(_("No Profile"), _("Your settings are as you left them"), "focus-custom-symbolic"));
            }

            foreach (var p in _set.profiles) {
                var row = new ActionRow(display_name(p), profile_summary(p, active, client.reason), p.icon_name);
                row.activatable = true;
                if (p.id == active) {
                    var on = new Label(_("On"));
                    on.add_css_class("focus-on-label");
                    on.valign = Align.CENTER;
                    row.add_suffix(on);
                }
                row.add_suffix(NotificationSettingsPage.chevron());
                string id = p.id;
                row.activated.connect(() => open_profile.begin(id));
                list_group.add_row(row);
            }
            var add = new ActionRow(_("Add Profile…"), _("Starts with everything set to Don't Change"), "list-add-symbolic");
            add.activatable = true;
            add.add_suffix(NotificationSettingsPage.chevron());
            add.activated.connect(() => create.begin());
            list_group.add_row(add);
        }

        private async void create() {
            var p = new Profile("", _("New Profile"), "focus-custom-symbolic");
            var editor = new ProfileEditor(p);
            string id = yield editor.save_now();
            yield open_profile(id);
        }

        private async void open_profile(string id) {
            var client = Client.get_default();
            try {
                var set = yield client.load();
                var p = set.find(id);
                if (p == null) return;
                var editor = new ProfileEditor(p);
                editor.areas = yield client.areas();
                editor.facts = yield client.facts();
                view.open_subpage(new ProfileDetailPage(view, editor), "profile");
            } catch (Error e) {
                warning("profiles: could not open %s: %s", id, e.message);
            }
        }
    }

    public class ProfileDetailPage : SettingsPage {
        private SettingsView view;
        private ProfileEditor editor;
        private SwitchRow on_row;
        private PreferencesGroup rules_group;
        private bool _syncing = false;

        public ProfileDetailPage(SettingsView view, ProfileEditor editor) {
            base(display_name(editor.profile));
            this.view = view;
            this.editor = editor;
            var p = editor.profile;
            var client = Client.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("profiles"));

            var status = new PreferencesGroup(_("Status"));
            on_row = new SwitchRow(_("Turn On Now"), _("Stays on until you turn it off or pick another profile"));
            on_row.switch_btn.notify["active"].connect(() => {
                if (_syncing) return;
                if (on_row.switch_btn.active) {
                    editor.save_now.begin((o, res) => {
                        editor.save_now.end(res);
                        client.activate.begin(p.id, "settings");
                    });
                } else if (client.active_profile == p.id) {
                    client.deactivate.begin();
                }
            });
            status.add_row(on_row);
            if (!p.builtin) {
                var name_row = new EntryRow(_("Name"));
                name_row.text = p.name;
                name_row.entry_changed.connect(() => {
                    string n = name_row.text.strip();
                    if (n == "" || n == p.name) return;
                    p.name = n;
                    editor.commit();
                });
                status.add_row(name_row);
            }
            var announce = new SwitchRow(_("Tell Me When It Changes"), _("A notification says which profile turned on and why"));
            announce.switch_btn.active = p.announce;
            announce.switch_btn.notify["active"].connect(() => {
                p.announce = announce.switch_btn.active;
                editor.commit();
            });
            status.add_row(announce);
            var shortcut_row = new EntryRow(_("Keyboard Shortcut"));
            shortcut_row.text = p.shortcut;
            shortcut_row.placeholder_text = "<Super><Alt>1";
            shortcut_row.entry_changed.connect(() => {
                string accel = shortcut_row.text.strip();
                if (accel != "") {
                    uint key;
                    Gdk.ModifierType mods;
                    if (!Gtk.accelerator_parse(accel, out key, out mods) || key == 0) return;
                }
                if (accel == p.shortcut) return;
                p.shortcut = accel;
                editor.commit();
            });
            status.add_row(shortcut_row);
            add_group(status);

            var disturb = new PreferencesGroup(_("Who Can Disturb"));
            var people = new ActionRow(_("People, Apps and Calls"), notifications_summary(p), "preferences-system-notifications-symbolic");
            people.activatable = true;
            people.add_suffix(NotificationSettingsPage.chevron());
            people.activated.connect(() => view.open_subpage(new ProfileDisturbPage(view, editor), "profile-disturb"));
            disturb.add_row(people);
            add_group(disturb);

            rules_group = new PreferencesGroup(_("Turn On Automatically"),
                _("When more than one profile could turn on, the one with the most specific rule wins."));
            add_group(rules_group);
            rebuild_rules();

            var apps = new PreferencesGroup(area_label(Areas.APPS));
            apps.add_row(apps_row(_("Open Apps"), "open"));
            apps.add_row(apps_row(_("Close Apps"), "close"));
            add_group(apps);

            foreach (var info in editor.areas) {
                if (info.id == Areas.STATE || info.id == Areas.NOTIFICATIONS || info.id == Areas.APPS) continue;
                var group = new PreferencesGroup(info.label);
                int rows = 0;
                foreach (var opt in info.options) {
                    if (opt.read_only) continue;
                    var row = ProfileOptionRows.build(editor, info.id, opt);
                    if (row == null) continue;
                    group.add_row(row);
                    rows++;
                }
                if (rows > 0) add_group(group);
            }

            var actions = new PreferencesGroup(_("Save"));
            var capture = new ActionRow(_("Save As It Is Now"),
                _("Every setting this profile can change takes the value it has right now"), "document-save-symbolic");
            var capture_btn = new Button.with_label(_("Save"));
            capture_btn.valign = Align.CENTER;
            capture_btn.add_css_class("pill");
            capture.add_suffix(capture_btn);
            capture_btn.clicked.connect(() => {
                client.capture.begin(p.id, (o, res) => {
                    try {
                        var captured = client.capture.end(res);
                        if (captured == null) return;
                        captured.name = p.name;
                        captured.icon_name = p.icon_name;
                        captured.announce = p.announce;
                        captured.shortcut = p.shortcut;
                        editor.profile = captured;
                        editor.save_now.begin((o2, r2) => {
                            editor.save_now.end(r2);
                            view.open_subpage(new ProfileDetailPage(view, editor), "profile");
                        });
                    } catch (Error e) {
                        warning("profiles: capture failed: %s", e.message);
                    }
                });
            });
            actions.add_row(capture);
            var reset = new ActionRow(_("Change Nothing"), _("Every setting goes back to Don't Change"), "edit-clear-symbolic");
            var reset_btn = new Button.with_label(_("Reset"));
            reset_btn.valign = Align.CENTER;
            reset_btn.add_css_class("pill");
            reset.add_suffix(reset_btn);
            reset_btn.clicked.connect(() => {
                foreach (string area in p.areas()) p.clear_area(area);
                editor.save_now.begin((o, res) => {
                    editor.save_now.end(res);
                    view.open_subpage(new ProfileDetailPage(view, editor), "profile");
                });
            });
            actions.add_row(reset);
            add_group(actions);

            if (!p.builtin) {
                var danger = new PreferencesGroup(_("Remove"));
                var remove = new ConfirmRow(_("Remove Profile"), _("Its settings and rules are removed too"), "user-trash-symbolic");
                remove.confirm_label = _("Remove");
                remove.confirmed.connect(() => {
                    client.remove.begin(p.id, (o, res) => {
                        try {
                            client.remove.end(res);
                        } catch (Error e) {
                            warning("profiles: remove failed: %s", e.message);
                        }
                        view.navigate_to("profiles");
                    });
                });
                danger.add_row(remove);
                add_group(danger);
            }

            ulong h = client.status_changed.connect(sync_state);
            destroy.connect(() => client.disconnect(h));
            sync_state();
        }

        private void sync_state() {
            var client = Client.get_default();
            _syncing = true;
            bool on = client.active_profile == editor.profile.id;
            on_row.switch_btn.active = on;
            on_row.subtitle = on && client.reason != "manual" && client.detail != ""
                ? client.detail
                : _("Stays on until you turn it off or pick another profile");
            _syncing = false;
        }

        public static string notifications_summary(Profile p) {
            string? json = p.get_value(Areas.NOTIFICATIONS, "rules");
            if (json == null) return _("Don't Change");
            var node = parse_value(json);
            if (node.get_node_type() != Json.NodeType.OBJECT) return _("Don't Change");
            var o = node.get_object();
            if (o.has_member("silence") && !o.get_boolean_member("silence")) return _("Everyone");
            int people = o.has_member("people") ? (int) o.get_array_member("people").get_length() : 0;
            int apps = o.has_member("apps") ? (int) o.get_array_member("apps").get_length() : 0;
            if (people == 0 && apps == 0) return _("Silenced, with exceptions you choose");
            return _("Silenced except %s and %s").printf(
                ngettext("%d person", "%d people", people).printf(people),
                ngettext("%d app", "%d apps", apps).printf(apps));
        }

        private ActionRow apps_row(string title, string key) {
            var list = ProfileAppEntry.list_from(editor.profile.get_value(Areas.APPS, key) ?? "[]");
            string sub;
            if (editor.profile.get_value(Areas.APPS, key) == null) {
                sub = _("Don't Change");
            } else {
                string[] names = {};
                foreach (var e in list) {
                    var info = new DesktopAppInfo(e.app + ".desktop");
                    names += info != null ? info.get_display_name() : e.app;
                    if (names.length == 3) break;
                }
                sub = names.length == 0 ? _("None") : string.joinv(", ", names) + (list.size > 3 ? "…" : "");
            }
            var row = new ActionRow(title, sub, key == "open" ? "view-app-grid-symbolic" : "window-close-symbolic");
            row.activatable = true;
            row.add_suffix(NotificationSettingsPage.chevron());
            row.activated.connect(() => view.open_subpage(new ProfileAppsPage(view, editor, key, title), "profile-apps"));
            return row;
        }

        private void rebuild_rules() {
            rules_group.clear();
            var p = editor.profile;
            foreach (var rule in p.rules) {
                var row = new ActionRow(describe_rule(rule), rule.conditions.size > 1
                    ? ngettext("%d condition, all must hold", "%d conditions, all must hold", rule.conditions.size).printf(rule.conditions.size)
                    : "", "preferences-system-time-symbolic");
                row.activatable = true;
                var sw = new Switch();
                sw.valign = Align.CENTER;
                sw.active = rule.enabled;
                sw.tooltip_text = _("Use this rule");
                var r = rule;
                sw.notify["active"].connect(() => {
                    r.enabled = sw.active;
                    editor.commit();
                });
                row.add_suffix(sw);
                row.add_suffix(NotificationSettingsPage.chevron());
                row.activated.connect(() => view.open_subpage(new ProfileRulePage(view, editor, r, false), "profile-rule"));
                rules_group.add_row(row);
            }
            var add = new ActionRow(_("Add Rule…"), _("Time, Wi-Fi, screens, devices, games, Sinty Key or battery"), "list-add-symbolic");
            add.activatable = true;
            add.add_suffix(NotificationSettingsPage.chevron());
            add.activated.connect(() => view.open_subpage(new ProfileRulePage(view, editor, new Rule(), true), "profile-rule"));
            rules_group.add_row(add);
        }
    }

    public class ProfileOptionRows : Object {
        private const string KEEP = "__keep";
        private const string NOW = "__now";

        private static Singularity.Core.AppSettingOption choice(string id, string label) {
            var o = new Singularity.Core.AppSettingOption();
            o.id = id;
            o.label = label;
            return o;
        }

        public static Widget? build(ProfileEditor editor, string area, Option opt) {
            var p = editor.profile;
            string? value = p.get_value(area, opt.key);
            switch (opt.kind) {
                case OptionKind.BOOLEAN: {
                    var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                    options.add(choice(KEEP, _("Don't Change")));
                    options.add(choice("true", _("On")));
                    options.add(choice("false", _("Off")));
                    string current = value == null ? KEEP : (bool_of(value) ? "true" : "false");
                    var row = new SelectionRow.with_options(opt.label, options, current);
                    if (opt.subtitle != "") row.subtitle = opt.subtitle;
                    row.selected.connect((id) => {
                        if (id == KEEP) p.unset_value(area, opt.key);
                        else p.set_value(area, opt.key, id);
                        editor.commit();
                    });
                    return row;
                }
                case OptionKind.CHOICE: {
                    if (opt.choices.size == 0 && value == null) return null;
                    var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                    options.add(choice(KEEP, _("Don't Change")));
                    string current = KEEP;
                    string? stored = value != null ? text_of(value) : null;
                    bool found = false;
                    foreach (var c in opt.choices) {
                        options.add(choice(c.value == "" ? "__empty" : c.value, c.label));
                        if (stored != null && c.value == stored) found = true;
                    }
                    if (stored != null) {
                        if (!found) options.add(choice(stored == "" ? "__empty" : stored, stored));
                        current = stored == "" ? "__empty" : stored;
                    }
                    var row = new SelectionRow.with_options(opt.label, options, current);
                    if (opt.subtitle != "") row.subtitle = opt.subtitle;
                    row.selected.connect((id) => {
                        if (id == KEEP) p.unset_value(area, opt.key);
                        else p.set_value(area, opt.key, string_value(id == "__empty" ? "" : id));
                        editor.commit();
                    });
                    return row;
                }
                case OptionKind.INTEGER:
                case OptionKind.NUMBER: {
                    double min = opt.min;
                    double max = opt.max > opt.min ? opt.max : 100;
                    bool integer = opt.kind == OptionKind.INTEGER;
                    double start = value != null ? number_of(value, min) : (min + max) / 2;
                    var row = new SpinRow(opt.label, value == null ? _("Don't Change") : (opt.subtitle != "" ? opt.subtitle : null),
                        min, max, integer ? 1 : 0.05, start);
                    if (!integer) row.spin_btn.digits = 2;
                    row.spin_btn.sensitive = value != null;
                    var sw = new Switch();
                    sw.valign = Align.CENTER;
                    sw.active = value != null;
                    sw.tooltip_text = _("Change this setting");
                    row.add_suffix(sw);
                    sw.notify["active"].connect(() => {
                        row.spin_btn.sensitive = sw.active;
                        row.subtitle = sw.active ? opt.subtitle : _("Don't Change");
                        if (sw.active) p.set_value(area, opt.key, number_text(row.spin_btn.value, integer));
                        else p.unset_value(area, opt.key);
                        editor.commit();
                    });
                    row.spin_btn.value_changed.connect(() => {
                        if (!sw.active) return;
                        p.set_value(area, opt.key, number_text(row.spin_btn.value, integer));
                        editor.commit();
                    });
                    return row;
                }
                case OptionKind.TEXT:
                case OptionKind.STRUCTURED: {
                    var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                    options.add(choice(KEEP, _("Don't Change")));
                    options.add(choice(NOW, _("As It Is Now")));
                    var row = new SelectionRow.with_options(opt.label, options, value == null ? KEEP : NOW);
                    row.subtitle = value == null ? opt.subtitle : short_text(value);
                    row.selected.connect((id) => {
                        if (id == KEEP) {
                            p.unset_value(area, opt.key);
                            row.subtitle = opt.subtitle;
                            editor.commit();
                            return;
                        }
                        Client.get_default().capture.begin(p.id, (o, res) => {
                            try {
                                var now = Client.get_default().capture.end(res);
                                string? v = now != null ? now.get_value(area, opt.key) : null;
                                if (v == null) return;
                                p.set_value(area, opt.key, v);
                                row.subtitle = short_text(v);
                                editor.commit();
                            } catch (Error e) {
                                warning("profiles: could not read %s.%s: %s", area, opt.key, e.message);
                            }
                        });
                    });
                    return row;
                }
            }
            return null;
        }

        private static string short_text(string json) {
            var n = parse_value(json);
            if (n.get_value_type() == typeof(string)) {
                string s = n.get_string();
                if (s.has_prefix("file://")) s = Path.get_basename(s);
                return s == "" ? _("Empty") : s;
            }
            if (n.get_node_type() == Json.NodeType.ARRAY) {
                uint len = n.get_array().get_length();
                return ngettext("%u item", "%u items", len).printf(len);
            }
            return _("Saved");
        }

        private static string number_text(double v, bool integer) {
            return integer ? int_value((int64) Math.round(v)) : double_value(v);
        }

        public static string? text_of(string json) {
            var n = parse_value(json);
            return n.get_value_type() == typeof(string) ? n.get_string() : null;
        }

        public static bool bool_of(string json) {
            var n = parse_value(json);
            return n.get_value_type() == typeof(bool) && n.get_boolean();
        }

        public static double number_of(string json, double fallback) {
            var n = parse_value(json);
            if (n.get_value_type() == typeof(int64)) return (double) n.get_int();
            if (n.get_value_type() == typeof(double)) return n.get_double();
            return fallback;
        }
    }

    public delegate bool ProfileFlagGet();
    public delegate void ProfileFlagSet(bool v);

    public class ProfileDisturbPage : SettingsPage {
        private SettingsView view;
        private ProfileEditor editor;
        private FocusMode mode;
        private PreferencesGroup people_group;
        private PreferencesGroup apps_group;
        private SwitchRow change_row;
        private SwitchRow silence_row;

        public ProfileDisturbPage(SettingsView view, ProfileEditor editor) {
            base(_("Who Can Disturb"));
            this.view = view;
            this.editor = editor;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new ProfileDetailPage(view, editor), "profile"));
            var p = editor.profile;
            string? json = p.get_value(Areas.NOTIFICATIONS, "rules");
            var node = json != null ? parse_value(json) : null;
            bool silence = true;
            FocusMode? parsed = null;
            if (node != null && node.get_node_type() == Json.NodeType.OBJECT) {
                var o = node.get_object();
                o.set_string_member("id", "profile");
                parsed = FocusMode.from_json(o);
                silence = !o.has_member("silence") || o.get_boolean_member("silence");
            }
            if (parsed == null) {
                parsed = new FocusMode("profile", p.name, p.icon_name);
                parsed.allow_time_sensitive = false;
            }
            mode = parsed;

            var top = new PreferencesGroup(_("Notifications"));
            change_row = new SwitchRow(_("Change Notifications"), _("Off means Don't Change"));
            change_row.switch_btn.active = json != null;
            top.add_row(change_row);
            silence_row = new SwitchRow(_("Silence Notifications"),
                _("Silenced notifications wait quietly in the notification centre"));
            silence_row.switch_btn.active = silence;
            top.add_row(silence_row);
            add_group(top);

            people_group = new PreferencesGroup(_("Allowed People"), _("Notifications that name these contacts still come through."));
            apps_group = new PreferencesGroup(_("Allowed Apps"), _("These apps can always notify you."));
            var exceptions = new PreferencesGroup(_("Exceptions"));
            exceptions.add_row(flag_row(_("Time-Sensitive Notifications"), _("Apps set to time-sensitive come through"),
                () => mode.allow_time_sensitive, (v) => mode.allow_time_sensitive = v));
            exceptions.add_row(flag_row(_("Repeated Calls"), _("A second call from the same person within three minutes comes through"),
                () => mode.allow_repeated_calls, (v) => mode.allow_repeated_calls = v));
            var extras = new PreferencesGroup(_("Badges and Sounds"));
            extras.add_row(flag_row(_("Show Badges in the Dock"), _("Unread counts stay visible on app icons"),
                () => mode.show_badges, (v) => mode.show_badges = v));
            extras.add_row(flag_row(_("Mute Notification Sounds"), _("Even notifications that come through stay quiet"),
                () => mode.mute_sounds, (v) => mode.mute_sounds = v));
            add_group(people_group);
            add_group(apps_group);
            add_group(exceptions);
            add_group(extras);

            change_row.switch_btn.notify["active"].connect(() => {
                silence_row.sensitive = change_row.switch_btn.active;
                save();
            });
            silence_row.switch_btn.notify["active"].connect(save);
            silence_row.sensitive = change_row.switch_btn.active;
            rebuild();
        }

        private SwitchRow flag_row(string title, string subtitle, ProfileFlagGet get_flag, owned ProfileFlagSet set_flag) {
            var row = new SwitchRow(title, subtitle);
            row.switch_btn.active = get_flag();
            ProfileFlagSet setter = (owned) set_flag;
            row.switch_btn.notify["active"].connect(() => {
                setter(row.switch_btn.active);
                if (!change_row.switch_btn.active) change_row.switch_btn.active = true;
                else save();
            });
            return row;
        }

        private void save() {
            var p = editor.profile;
            if (!change_row.switch_btn.active) {
                p.unset_value(Areas.NOTIFICATIONS, "rules");
                editor.commit();
                return;
            }
            var o = mode.to_json().get_object();
            foreach (string k in new string[] { "id", "name", "icon", "builtin", "while-presenting", "while-fullscreen", "schedules" }) {
                if (o.has_member(k)) o.remove_member(k);
            }
            o.set_boolean_member("silence", silence_row.switch_btn.active);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            p.set_value(Areas.NOTIFICATIONS, "rules", to_text(node, false));
            editor.commit();
        }

        private void picked() {
            if (!change_row.switch_btn.active) change_row.switch_btn.active = true;
            else save();
        }

        private void rebuild() {
            people_group.clear();
            foreach (var person in mode.allowed_people) {
                people_group.add_row(new ActionRow(person.name, string.joinv(", ", person.handles), "avatar-default-symbolic"));
            }
            var add_person = new ActionRow(_("Choose People…"), _("Pick from your contacts"), "list-add-symbolic");
            add_person.activatable = true;
            add_person.add_suffix(NotificationSettingsPage.chevron());
            add_person.activated.connect(() => view.open_subpage(new FocusPeoplePage(view, mode,
                () => view.open_subpage(new ProfileDisturbPage(view, editor), "profile-disturb"), picked), "focus-people"));
            people_group.add_row(add_person);

            apps_group.clear();
            var store = AppNotificationSettings.get_default();
            foreach (string key in mode.allowed_apps) {
                apps_group.add_row(new ActionRow(store.display_name(key), ""));
            }
            var add_app = new ActionRow(_("Choose Apps…"), _("Pick apps that may notify you"), "list-add-symbolic");
            add_app.activatable = true;
            add_app.add_suffix(NotificationSettingsPage.chevron());
            add_app.activated.connect(() => view.open_subpage(new FocusAppsPage(view, mode,
                () => view.open_subpage(new ProfileDisturbPage(view, editor), "profile-disturb"), picked), "focus-apps"));
            apps_group.add_row(add_app);
        }
    }

    public class ProfileRulePage : SettingsPage {
        private ProfileEditor editor;
        private Rule working;
        private PreferencesGroup conditions_group;

        public ProfileRulePage(SettingsView view, ProfileEditor editor, Rule rule, bool is_new) {
            base(is_new ? _("New Rule") : _("Rule"));
            this.editor = editor;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new ProfileDetailPage(view, editor), "profile"));
            working = copy_rule(rule);

            conditions_group = new PreferencesGroup(_("When All of These Hold"),
                _("A rule with more conditions is more specific and wins over simpler ones."));
            add_group(conditions_group);

            var add_box = new PreferencesGroup(_("Add a Condition"));
            ConditionKind[] kinds = { ConditionKind.TIME, ConditionKind.WIFI, ConditionKind.SCREEN, ConditionKind.DEVICE,
                ConditionKind.FULLSCREEN, ConditionKind.GAME, ConditionKind.PRESENTING, ConditionKind.KEY, ConditionKind.BATTERY };
            foreach (var kind in kinds) {
                var row = new ActionRow(condition_kind_label(kind), "", "list-add-symbolic");
                row.activatable = true;
                var k = kind;
                row.activated.connect(() => {
                    var c = new Condition(k);
                    string[] options = suggestions(k);
                    if (options.length > 0) c.match = options[0];
                    working.conditions.add(c);
                    rebuild();
                });
                add_box.add_row(row);
            }
            add_group(add_box);

            var buttons = new Box(Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 24;
            if (!is_new) {
                var remove = new Button.with_label(_("Remove"));
                remove.add_css_class("destructive-action");
                remove.add_css_class("pill");
                remove.clicked.connect(() => {
                    editor.profile.rules.remove(rule);
                    editor.commit();
                    view.open_subpage(new ProfileDetailPage(view, editor), "profile");
                });
                buttons.append(remove);
            }
            var save = new Button.with_label(is_new ? _("Add") : _("Save"));
            save.add_css_class("suggested-action");
            save.add_css_class("pill");
            save.clicked.connect(() => {
                if (working.conditions.size == 0) return;
                if (is_new) {
                    working.enabled = true;
                    editor.profile.rules.add(working);
                } else {
                    int i = editor.profile.rules.index_of(rule);
                    if (i >= 0) editor.profile.rules[i] = working;
                }
                editor.commit();
                view.open_subpage(new ProfileDetailPage(view, editor), "profile");
            });
            buttons.append(save);
            add_widget(buttons);
            rebuild();
        }

        private static Rule copy_rule(Rule rule) {
            var r = new Rule();
            r.enabled = rule.enabled;
            foreach (var c in rule.conditions) {
                var n = new Condition(c.kind);
                n.days = c.days;
                n.start_minute = c.start_minute;
                n.end_minute = c.end_minute;
                n.match = c.match;
                n.below_percent = c.below_percent;
                r.conditions.add(n);
            }
            return r;
        }

        private string[] suggestions(ConditionKind kind) {
            switch (kind) {
                case ConditionKind.WIFI: {
                    string[] list = editor.fact_list("wifi");
                    foreach (string s in editor.fact_list("known-wifi")) {
                        if (!(s in list)) list += s;
                    }
                    return list;
                }
                case ConditionKind.SCREEN: return editor.fact_list("screens");
                case ConditionKind.DEVICE: return editor.fact_list("devices");
                default: return {};
            }
        }

        private void rebuild() {
            conditions_group.clear();
            if (working.conditions.size == 0) {
                conditions_group.add_row(new ActionRow(_("No Conditions Yet"), _("Add one below"), "dialog-information-symbolic"));
            }
            foreach (var c in working.conditions) conditions_group.add_row(condition_row(c));
        }

        private Button remove_button(Condition c) {
            var b = new Button.from_icon_name("list-remove-symbolic");
            b.add_css_class("flat");
            b.add_css_class("circular");
            b.valign = Align.CENTER;
            b.tooltip_text = _("Remove");
            b.clicked.connect(() => {
                working.conditions.remove(c);
                rebuild();
            });
            return b;
        }

        private Widget condition_row(Condition c) {
            switch (c.kind) {
                case ConditionKind.TIME: {
                    var box = new Box(Orientation.VERTICAL, 0);
                    var row = new ActionRow(condition_kind_label(c.kind), days_text(c.days), "preferences-system-time-symbolic");
                    var start = new TimePicker(Condition.format_minute(c.start_minute));
                    start.changed.connect(() => c.start_minute = Condition.parse_minute(start.time, c.start_minute));
                    var end = new TimePicker(Condition.format_minute(c.end_minute));
                    end.changed.connect(() => c.end_minute = Condition.parse_minute(end.time, c.end_minute));
                    row.add_suffix(start);
                    row.add_suffix(new Label(_("to")));
                    row.add_suffix(end);
                    row.add_suffix(remove_button(c));
                    box.append(row);
                    var days_box = new Box(Orientation.HORIZONTAL, 4);
                    days_box.add_css_class("focus-days");
                    days_box.halign = Align.CENTER;
                    days_box.margin_top = 4;
                    days_box.margin_bottom = 8;
                    var monday = new DateTime.local(2024, 1, 1, 12, 0, 0);
                    for (int i = 0; i < 7; i++) {
                        int bit = 1 << i;
                        var toggle = new ToggleButton.with_label(monday.add_days(i).format("%a").get_char(0).toupper().to_string());
                        toggle.tooltip_text = monday.add_days(i).format("%A");
                        toggle.add_css_class("focus-day");
                        toggle.set_size_request(36, 36);
                        toggle.active = (c.days & bit) != 0;
                        toggle.toggled.connect(() => {
                            if (toggle.active) c.days |= bit;
                            else c.days &= ~bit;
                            row.subtitle = days_text(c.days);
                        });
                        days_box.append(toggle);
                    }
                    box.append(days_box);
                    box.set_data<string>("settings-title", condition_kind_label(c.kind));
                    return box;
                }
                case ConditionKind.WIFI:
                case ConditionKind.SCREEN:
                case ConditionKind.DEVICE: {
                    string[] items = suggestions(c.kind);
                    if (c.match != "" && !(c.match in items)) items += c.match;
                    if (items.length > 0) {
                        var row = new SelectionRow(condition_kind_label(c.kind), items, c.match);
                        row.subtitle = describe_condition(c);
                        row.selected.connect((v) => {
                            c.match = v;
                            row.subtitle = describe_condition(c);
                        });
                        row.add_suffix(remove_button(c));
                        return row;
                    }
                    var entry = new EntryRow(condition_kind_label(c.kind));
                    entry.text = c.match;
                    entry.placeholder_text = c.kind == ConditionKind.WIFI ? _("Network name") : _("Part of the name");
                    entry.entry_changed.connect(() => c.match = entry.text.strip());
                    entry.add_suffix(remove_button(c));
                    return entry;
                }
                case ConditionKind.KEY: {
                    var row = new SwitchRow(condition_kind_label(c.kind), _("Only my own Sinty Key"));
                    row.switch_btn.active = c.match != "";
                    row.switch_btn.notify["active"].connect(() => {
                        c.match = row.switch_btn.active ? Environment.get_user_name() : "";
                    });
                    row.add_suffix(remove_button(c));
                    return row;
                }
                case ConditionKind.BATTERY: {
                    var row = new SpinRow(condition_kind_label(c.kind), _("Turns on below this charge, on battery"), 5, 95, 5, c.below_percent);
                    row.spin_btn.value_changed.connect(() => c.below_percent = (int) row.spin_btn.value);
                    row.add_suffix(remove_button(c));
                    return row;
                }
                default: {
                    var row = new ActionRow(condition_kind_label(c.kind), describe_condition(c), "emblem-default-symbolic");
                    row.add_suffix(remove_button(c));
                    return row;
                }
            }
        }
    }

    public class ProfileAppsPage : SettingsPage {
        private ProfileEditor editor;
        private string key;
        private Gee.ArrayList<ProfileAppEntry> chosen;
        private PreferencesGroup chosen_group;
        private PreferencesGroup list;
        private Singularity.Widgets.SearchEntry search;
        private SwitchRow change_row;

        public ProfileAppsPage(SettingsView view, ProfileEditor editor, string key, string title) {
            base(title);
            this.editor = editor;
            this.key = key;
            back_btn.visible = true;
            back_clicked.connect(() => view.open_subpage(new ProfileDetailPage(view, editor), "profile"));
            string? value = editor.profile.get_value(Areas.APPS, key);
            chosen = ProfileAppEntry.list_from(value ?? "[]");

            var top = new PreferencesGroup(_("Apps"),
                key == "open" ? _("These apps open when the profile starts, and close when it ends unless they hold unsaved work.")
                              : _("These apps close when the profile starts and open again when it ends. Apps with unsaved work stay open."));
            change_row = new SwitchRow(_("Change Apps"), _("Off means Don't Change"));
            change_row.switch_btn.active = value != null;
            change_row.switch_btn.notify["active"].connect(save);
            top.add_row(change_row);
            add_group(top);

            chosen_group = new PreferencesGroup(_("Chosen"));
            add_group(chosen_group);

            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search Apps");
            search.margin_top = 12;
            search.search_changed.connect(fill);
            add_widget(search);
            list = new PreferencesGroup(_("Add"));
            add_group(list);
            rebuild_chosen();
            fill();
        }

        private void save() {
            if (!change_row.switch_btn.active) editor.profile.unset_value(Areas.APPS, key);
            else editor.profile.set_value(Areas.APPS, key, ProfileAppEntry.list_to(chosen));
            editor.commit();
        }

        private static string app_name(string app) {
            var info = new DesktopAppInfo(app + ".desktop");
            return info != null ? info.get_display_name() : app;
        }

        private static Image app_icon(string app) {
            var img = new Image();
            img.pixel_size = 24;
            img.margin_end = 8;
            var info = new DesktopAppInfo(app + ".desktop");
            if (info != null && info.get_icon() != null) img.gicon = info.get_icon();
            else img.icon_name = "application-x-executable";
            return img;
        }

        private void rebuild_chosen() {
            chosen_group.clear();
            if (chosen.size == 0) {
                chosen_group.add_row(new ActionRow(_("No Apps"), _("Pick apps below"), "view-app-grid-symbolic"));
                return;
            }
            string[] screens = editor.fact_list("screens");
            foreach (var e in chosen) {
                var row = new ActionRow(app_name(e.app), "");
                row.add_prefix(app_icon(e.app));
                var entry = e;
                if (key == "open") {
                    if (screens.length > 0) {
                        var options = new Gtk.StringList(null);
                        options.append(_("Any Screen"));
                        uint selected = 0;
                        for (int i = 0; i < screens.length; i++) {
                            options.append(screens[i]);
                            if (screens[i].split(" ")[0] == e.output) selected = i + 1;
                        }
                        var dd = new DropDown(options, null);
                        dd.valign = Align.CENTER;
                        dd.selected = selected;
                        dd.tooltip_text = _("Screen");
                        dd.notify["selected"].connect(() => {
                            entry.output = dd.selected == 0 ? "" : screens[dd.selected - 1].split(" ")[0];
                            save();
                        });
                        row.add_suffix(dd);
                    }
                    var desk = new SpinButton.with_range(0, 9, 1);
                    desk.valign = Align.CENTER;
                    desk.value = e.workspace + 1;
                    desk.tooltip_text = _("Desktop, 0 for the current one");
                    desk.value_changed.connect(() => {
                        entry.workspace = (int) desk.value - 1;
                        save();
                    });
                    row.add_suffix(desk);
                }
                var rm = new Button.from_icon_name("list-remove-symbolic");
                rm.add_css_class("flat");
                rm.add_css_class("circular");
                rm.valign = Align.CENTER;
                rm.tooltip_text = _("Remove");
                rm.clicked.connect(() => {
                    chosen.remove(entry);
                    save();
                    rebuild_chosen();
                    fill();
                });
                row.add_suffix(rm);
                chosen_group.add_row(row);
            }
        }

        private void fill() {
            list.clear();
            var apps = new Gee.ArrayList<AppInfo>();
            foreach (var info in AppInfo.get_all()) {
                if (info.should_show() && info.get_id() != null) apps.add(info);
            }
            apps.sort((a, b) => a.get_display_name().collate(b.get_display_name()));
            string q = search.text.strip().down();
            int shown = 0;
            foreach (var info in apps) {
                string id = info.get_id();
                if (id.has_suffix(".desktop")) id = id.substring(0, id.length - ".desktop".length);
                if (ProfileAppEntry.find(chosen, id) != null) continue;
                if (q != "" && !info.get_display_name().down().contains(q)) continue;
                var row = new ActionRow(info.get_display_name(), "");
                row.add_prefix(app_icon(id));
                row.activatable = true;
                row.add_suffix(new Image.from_icon_name("list-add-symbolic"));
                string app = id;
                row.activated.connect(() => {
                    chosen.add(new ProfileAppEntry(app));
                    if (!change_row.switch_btn.active) change_row.switch_btn.active = true;
                    else save();
                    rebuild_chosen();
                    fill();
                });
                list.add_row(row);
                if (++shown >= 80) break;
            }
        }
    }
}
