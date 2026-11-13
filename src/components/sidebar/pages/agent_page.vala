using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AgentPage : SettingsPage {
        private const string[] PROVIDERS = { "local", "claude-code", "codex", "claude-api", "ollama" };
        private const string[] MODES = { "plan", "ask", "auto" };
        private SelectionRow provider_row;
        private EntryRow model_row;
        private EntryRow endpoint_row;
        private PasswordRow key_row;
        private SwitchRow enabled_row;
        private AgentOrb hero_orb;
        private SelectionRow mode_row;
        private SwitchRow voice_row;
        private SwitchRow background_row;
        private PreferencesGroup model_group;
        private PreferencesGroup behaviour_group;
        private PreferencesGroup tasks_group;
        private PreferencesGroup changes_group;
        private bool loading = true;
        private uint key_timeout = 0;
        private string stored_key = "";

        private static string phones_summary() {
            string[] names = {};
            foreach (var d in NearbyClient.get_default().devices) {
                if (d.paired && d.has_plugin("sinty-ai")) names += d.name;
            }
            if (names.length == 0) return _("Turn on Sinty AI for a phone in Connected Devices");
            return string.joinv(", ", names);
        }

        public AgentPage(SettingsView view) {
            base(_("Sinty AI"));
            back_btn.visible = true;
            back_clicked.connect(() => view.go_home());

            hero_orb = new AgentOrb(56);
            hero_orb.halign = Align.CENTER;
            hero_orb.margin_top = 8;
            hero_orb.margin_bottom = 4;
            add_widget(hero_orb);

            var general = new PreferencesGroup(_("Sinty AI"),
                _("Off unless you turn it on. Without a model nothing on this computer uses AI."));
            enabled_row = new SwitchRow(_("Use AI"), _("Press Super+A to ask"));
            general.add_row(enabled_row);
            add_group(general);

            string provider, model, endpoint;
            AgentConfig.load(out provider, out model, out endpoint);
            enabled_row.switch_btn.active = AgentConfig.configured();

            model_group = new PreferencesGroup(_("Model"),
                _("Claude Code and Codex use your own login in their programs. Keys stay in the keyring."));
            string[] provider_names = { _("This Computer"), _("Claude Code"), _("Codex"), _("Claude API"), _("Ollama Cloud") };
            var provider_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            for (int i = 0; i < PROVIDERS.length; i++) {
                provider_options.add(new Singularity.Core.AppSettingOption() { id = PROVIDERS[i], label = provider_names[i] });
            }
            provider_row = new SelectionRow.with_options(_("Provider"), provider_options, provider != "" ? provider : PROVIDERS[0]);
            provider_row.selected.connect(() => {
                save();
                refresh_key_state.begin();
            });
            model_group.add_row(provider_row);
            model_row = new EntryRow(_("Model Name"));
            model_row.text = model;
            model_row.entry_changed.connect(save);
            model_group.add_row(model_row);
            endpoint_row = new EntryRow(_("Server Address"));
            endpoint_row.text = endpoint;
            endpoint_row.entry_changed.connect(save);
            model_group.add_row(endpoint_row);
            key_row = new PasswordRow(_("API Key"));
            key_row.entry_activated.connect(finish_key);
            key_row.entry_changed.connect(() => {
                if (key_timeout != 0) Source.remove(key_timeout);
                key_timeout = Timeout.add(800, () => {
                    key_timeout = 0;
                    store_key.begin();
                    return Source.REMOVE;
                });
            });
            var key_focus = new EventControllerFocus();
            key_focus.leave.connect(finish_key);
            key_row.add_controller(key_focus);
            model_group.add_row(key_row);
            refresh_key_state.begin();
            add_group(model_group);

            behaviour_group = new PreferencesGroup(_("Behaviour"), _("Plan only reads and suggests. Ask First asks before lasting changes. Automatic asks only before what cannot be undone."));
            string[] mode_names = { _("Plan"), _("Ask First"), _("Automatic") };
            int mode_index = 1;
            for (int i = 0; i < MODES.length; i++) if (MODES[i] == AgentConfig.mode()) mode_index = i;
            mode_row = new SelectionRow(_("Mode"), mode_names, mode_names[mode_index]);
            mode_row.selected.connect(() => {
                int i = mode_row.selected_index;
                if (i < 0 || i >= MODES.length) return;
                try {
                    AgentConfig.set_mode(MODES[i]);
                } catch (Error e) {
                    warning("Cannot save the AI mode: %s", e.message);
                }
            });
            behaviour_group.add_row(mode_row);
            voice_row = new SwitchRow(_("Voice"), _("Listen while Super+Shift+A is held"), AgentConfig.flag("voice", true));
            voice_row.switch_btn.notify["active"].connect(() => save_flag("voice", voice_row.switch_btn.active));
            behaviour_group.add_row(voice_row);
            background_row = new SwitchRow(_("Work in the Background"),
                _("Finish tasks while you use other apps. It still asks before anything that cannot be undone."),
                AgentConfig.flag("background", false));
            background_row.switch_btn.notify["active"].connect(() => save_flag("background", background_row.switch_btn.active));
            behaviour_group.add_row(background_row);
            add_group(behaviour_group);

            tasks_group = new PreferencesGroup(_("Background Tasks"),
                _("Ask Sinty AI for one, such as: every morning at 8 sort my mail. They run only while Work in the Background is on."));
            add_group(tasks_group);
            fill_tasks();

            changes_group = new PreferencesGroup(_("Recent Changes"),
                _("What Sinty AI changed on this computer, newest first."));
            add_group(changes_group);
            fill_changes.begin();

            var phones = new PreferencesGroup(_("Phones"),
                _("Ask Sinty AI from a paired phone. It has the same powers as this panel and asks you the same questions."));
            var phones_row = new ActionRow(_("Paired Phones"), phones_summary(), "phone-symbolic");
            phones_row.activatable = true;
            var arrow = new Image.from_icon_name("go-next-symbolic");
            arrow.pixel_size = 12;
            arrow.add_css_class("dim-label");
            arrow.valign = Align.CENTER;
            phones_row.add_suffix(arrow);
            phones_row.activated.connect(() => view.navigate_to("connected-devices"));
            var nearby = NearbyClient.get_default();
            ulong watch = nearby.changed.connect(() => phones_row.subtitle = phones_summary());
            phones_row.destroy.connect(() => nearby.disconnect(watch));
            phones.add_row(phones_row);
            add_group(phones);

            model_group.sensitive = enabled_row.switch_btn.active;
            behaviour_group.sensitive = enabled_row.switch_btn.active;
            tasks_group.sensitive = enabled_row.switch_btn.active;
            hero_orb.state = enabled_row.switch_btn.active ? AgentOrbState.IDLE : AgentOrbState.OFF;
            enabled_row.switch_btn.notify["active"].connect(() => {
                model_group.sensitive = enabled_row.switch_btn.active;
                behaviour_group.sensitive = enabled_row.switch_btn.active;
                tasks_group.sensitive = enabled_row.switch_btn.active;
                hero_orb.state = enabled_row.switch_btn.active ? AgentOrbState.IDLE : AgentOrbState.OFF;
                if (enabled_row.switch_btn.active && !loading) hero_orb.kick(1);
                if (enabled_row.switch_btn.active) save();
                else if (!loading) AgentConfig.remove();
            });
            loading = false;
            map.connect(reload);
        }

        private void reload() {
            loading = true;
            string provider, model, endpoint;
            AgentConfig.load(out provider, out model, out endpoint);
            enabled_row.switch_btn.active = AgentConfig.configured();
            if (provider != "") provider_row.current_value = provider;
            if (model_row.text != model) model_row.text = model;
            if (endpoint_row.text != endpoint) endpoint_row.text = endpoint;
            string[] mode_names = { _("Plan"), _("Ask First"), _("Automatic") };
            for (int i = 0; i < MODES.length; i++) if (MODES[i] == AgentConfig.mode()) mode_row.current_value = mode_names[i];
            voice_row.switch_btn.active = AgentConfig.flag("voice", true);
            background_row.switch_btn.active = AgentConfig.flag("background", false);
            fill_tasks();
            loading = false;
        }

        private static string tasks_path() {
            return Path.build_filename(Environment.get_user_config_dir(), "sinty-agent", "tasks.json");
        }

        private static string state_path(string name) {
            return Path.build_filename(Environment.get_user_state_dir(), "sinty-agent", name);
        }

        private static Json.Node? read_json(string path) {
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                return parser.get_root();
            } catch (Error e) {
                return null;
            }
        }

        private static void write_json(string path, Json.Node node) throws Error {
            var generator = new Json.Generator();
            generator.pretty = true;
            generator.set_root(node);
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            FileUtils.set_contents(path, generator.to_data(null));
        }

        private static string trigger_text(Json.Object task) {
            if (task.has_member("every_minutes")) {
                var m = task.get_int_member("every_minutes");
                if (m % 60 == 0) return ngettext("Every hour", "Every %d hours", (ulong) (m / 60)).printf((int) (m / 60));
                return ngettext("Every minute", "Every %d minutes", (ulong) m).printf((int) m);
            }
            if (task.has_member("at")) return _("Every day at %s").printf(task.get_string_member("at"));
            var e = task.get_string_member_with_default("event", "");
            if (e == "login") return _("When you log in");
            if (e.has_prefix("files:")) return _("When files arrive in %s").printf(Path.get_basename(e.substring(6)));
            return "";
        }

        private static string last_text(Json.Object? runs, string id) {
            if (runs == null || !runs.has_member(id)) return _("Not run yet");
            var r = runs.get_object_member(id);
            var when = new DateTime.from_unix_local(r.get_int_member_with_default("time", 0));
            var day = when.format("%x %H:%M");
            return r.get_boolean_member_with_default("ok", false) ? _("Last run %s").printf(day) : _("Did not finish %s").printf(day);
        }

        private void fill_tasks() {
            tasks_group.clear();
            var root = read_json(tasks_path());
            var state = read_json(state_path("tasks-state.json"));
            Json.Object? runs = state != null && state.get_node_type() == Json.NodeType.OBJECT ? state.get_object() : null;
            int shown = 0;
            if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                var list = root.get_array();
                for (uint i = 0; i < list.get_length(); i++) {
                    var node = list.get_element(i);
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var task = node.get_object();
                    var id = task.get_string_member_with_default("id", "");
                    if (id == "") continue;
                    var title = task.get_string_member_with_default("title", id);
                    var row = new SwitchRow(title, trigger_text(task) + " · " + last_text(runs, id),
                        task.get_boolean_member_with_default("enabled", true));
                    row.tooltip_text = task.get_string_member_with_default("prompt", "");
                    row.switch_btn.notify["active"].connect(() => set_task(id, row.switch_btn.active, false));
                    var remove = new Button.from_icon_name("user-trash-symbolic");
                    remove.add_css_class("flat");
                    remove.valign = Align.CENTER;
                    remove.tooltip_text = _("Remove Task");
                    remove.clicked.connect(() => set_task(id, false, true));
                    row.add_suffix(remove);
                    tasks_group.add_row(row);
                    shown++;
                }
            }
            var plans = read_json(state_path("plans.json"));
            if (plans != null && plans.get_node_type() == Json.NodeType.ARRAY) {
                var list = plans.get_array();
                for (uint i = 0; i < list.get_length(); i++) {
                    var plan = list.get_object_element(i);
                    if (plan.get_string_member_with_default("status", "active") != "active") continue;
                    var steps = plan.get_array_member("steps");
                    uint done = 0;
                    for (uint j = 0; j < steps.get_length(); j++) {
                        if (steps.get_object_element(j).get_boolean_member_with_default("done", false)) done++;
                    }
                    var id = plan.get_string_member_with_default("id", "");
                    var row = new ActionRow(plan.get_string_member_with_default("title", id),
                        _("Plan, %u of %u steps done. It continues after a restart.").printf(done, steps.get_length()), null);
                    var stop = new Button.with_label(_("Stop"));
                    stop.valign = Align.CENTER;
                    stop.clicked.connect(() => stop_plan(id));
                    row.add_suffix(stop);
                    tasks_group.add_row(row);
                    shown++;
                }
            }
            if (shown == 0) tasks_group.add_row(new ActionRow(_("No tasks yet"), null, null));
        }

        private void set_task(string id, bool enabled, bool remove) {
            var root = read_json(tasks_path());
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return;
            var kept = new Json.Array();
            var list = root.get_array();
            for (uint i = 0; i < list.get_length(); i++) {
                var node = list.get_element(i);
                if (node.get_node_type() == Json.NodeType.OBJECT && node.get_object().get_string_member_with_default("id", "") == id) {
                    if (remove) continue;
                    node.get_object().set_boolean_member("enabled", enabled);
                }
                kept.add_element(node);
            }
            var saved = new Json.Node(Json.NodeType.ARRAY);
            saved.set_array(kept);
            try {
                write_json(tasks_path(), saved);
            } catch (Error e) {
                warning("Cannot save the AI tasks: %s", e.message);
            }
            if (remove) fill_tasks();
        }

        private void stop_plan(string id) {
            var root = read_json(state_path("plans.json"));
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return;
            var list = root.get_array();
            for (uint i = 0; i < list.get_length(); i++) {
                var plan = list.get_object_element(i);
                if (plan.get_string_member_with_default("id", "") == id) plan.set_string_member("status", "paused");
            }
            try {
                write_json(state_path("plans.json"), root);
            } catch (Error e) {
                warning("Cannot save the AI plans: %s", e.message);
            }
            fill_tasks();
        }

        private async void fill_changes() {
            changes_group.clear();
            string json = "[]";
            try {
                var bus = yield Bus.get(BusType.SESSION);
                var reply = yield bus.call("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1",
                    "ListChanges", null, new VariantType("(s)"), DBusCallFlags.NO_AUTO_START, 5000, null);
                reply.get("(s)", out json);
            } catch (Error e) {
                debug("Sinty AI changes: %s", e.message);
            }
            int shown = 0;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var list = parser.get_root().get_array();
                for (uint i = 0; i < list.get_length() && shown < 10; i++) {
                    var ch = list.get_object_element(i);
                    var id = (uint) ch.get_int_member("id");
                    var app = ch.get_string_member_with_default("app", "");
                    var info = app != "" ? new GLib.DesktopAppInfo(app + ".desktop") : null;
                    var when = new DateTime.from_unix_local(ch.get_int_member_with_default("time", 0)).format("%H:%M");
                    var where = info != null ? info.get_display_name() : _("System");
                    var row = new ActionRow(ch.get_string_member_with_default("summary", ""), "%s · %s".printf(where, when), null);
                    if (ch.get_boolean_member_with_default("undone", false)) {
                        row.subtitle = row.subtitle + " · " + _("Undone");
                    } else {
                        var undo = new Button.with_label(_("Undo"));
                        undo.valign = Align.CENTER;
                        undo.clicked.connect(() => undo_change.begin(id, undo));
                        row.add_suffix(undo);
                    }
                    changes_group.add_row(row);
                    shown++;
                }
            } catch (Error e) {
                debug("Sinty AI changes: %s", e.message);
            }
            if (shown == 0) changes_group.add_row(new ActionRow(_("No changes yet"), null, null));
        }

        private async void undo_change(uint id, Button button) {
            button.sensitive = false;
            try {
                var bus = yield Bus.get(BusType.SESSION);
                var reply = yield bus.call("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1",
                    "Undo", new Variant("(u)", id), new VariantType("(s)"), DBusCallFlags.NONE, 130000, null);
                string json;
                reply.get("(s)", out json);
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var obj = parser.get_root().get_object();
                if (obj.has_member("instruction") && obj.get_member("instruction").get_node_type() != Json.NodeType.NULL) {
                    var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                    var token = yield AgentConfig.grant_session();
                    if (token != null) launcher.setenv("SINTY_AGENT_TOKEN", token, true);
                    var process = launcher.spawnv({ AgentConfig.BINARY, "ask", obj.get_string_member("instruction") });
                    yield process.wait_async(null);
                }
            } catch (Error e) {
                warning("Sinty AI undo: %s", e.message);
            }
            yield fill_changes();
        }

        private void save() {
            if (loading || !enabled_row.switch_btn.active) return;
            try {
                AgentConfig.save(provider_row.current_value, model_row.text.strip(), endpoint_row.text.strip());
            } catch (Error e) {
                warning("Cannot save the AI settings: %s", e.message);
            }
        }

        private void save_flag(string name, bool value) {
            if (loading || !enabled_row.switch_btn.active) return;
            try {
                AgentConfig.set_flag(name, value);
            } catch (Error e) {
                warning("Cannot save the AI settings: %s", e.message);
            }
        }

        private void finish_key() {
            if (key_timeout != 0) {
                Source.remove(key_timeout);
                key_timeout = 0;
            }
            store_key.begin((obj, res) => {
                if (store_key.end(res)) key_row.text = "";
            });
        }

        private async void refresh_key_state() {
            var uses_key = provider_row.current_value == "claude-api" || provider_row.current_value == "ollama";
            key_row.visible = uses_key;
            if (!uses_key) return;
            var state = yield AgentConfig.key_state(provider_row.current_value);
            if (state < 0) key_row.placeholder_text = _("Keyring locked");
            else key_row.placeholder_text = state > 0 ? _("Saved in the keyring") : _("Not set");
        }

        private async bool store_key() {
            var key = key_row.text.strip();
            if (key == "") return false;
            if (key == stored_key) return true;
            try {
                var process = new Subprocess(SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDERR_SILENCE,
                    AgentConfig.BINARY, "key", provider_row.current_value);
                yield process.communicate_utf8_async(key, null, null, null);
                if (!process.get_successful()) {
                    key_row.placeholder_text = _("Not saved: the keyring refused the key");
                    return false;
                }
                stored_key = key;
                yield refresh_key_state();
                return true;
            } catch (Error e) {
                warning("Cannot store the API key: %s", e.message);
                key_row.placeholder_text = _("Not saved: the keyring refused the key");
                return false;
            }
        }
    }
}
