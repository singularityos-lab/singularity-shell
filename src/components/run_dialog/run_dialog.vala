using Gtk;

namespace Singularity {

    public class RunDialog : Singularity.Shell.ShellDialog {
        private Entry entry;
        private Label action_prefix;
        private Label error_label;
        private Revealer suggestions_revealer;
        private ListBox suggestions_list;
        private Revealer preview_revealer;
        private Box preview_box;
        private SearchManager search_manager;
        private Singularity.Animation.TimedAnimation? dialog_animation;
        private bool closing = false;
        private uint close_guard = 0;
        private GLib.Settings _desktop_settings = new GLib.Settings("dev.sinty.desktop");
        private bool action_mode = false;
        private bool ai_mode = false;
        private Box ai_controls;
        private bool ai_direct = false;
        private bool ai_compact = false;
        private Subprocess? ai_process = null;
        private string ai_conversation = "";
        private Spinner ai_spinner;
        private DropDown ai_mode_select;
        private Box ai_cards;
        private bool ai_mode_syncing = false;
        private const string[] AGENT_MODES = { "plan", "ask", "auto", "autopilot" };
        private Button ai_close;
        private Label ai_answer;
        private ScrolledWindow ai_scroll;
        private bool updating_text = false;
        private uint search_debounce = 0;
        private string active_query = "";

        private string[] _history = {};
        private int _history_pos = -1;

        private class PaletteAction {
            public string id;
            public string key;
            public string icon_name;
            public string title;
            public string subtitle;
            public bool developer_only;

            public PaletteAction(string id, string key, string icon_name,
                                 string title, string subtitle,
                                 bool developer_only = false) {
                this.id = id;
                this.key = key;
                this.icon_name = icon_name;
                this.title = title;
                this.subtitle = subtitle;
                this.developer_only = developer_only;
            }
        }

        private PaletteAction[] _actions;

        public RunDialog(Gtk.Application app) {
            Object(
                application: app,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            add_css_class("run-dialog");
            var compact_css = new CssProvider();
            compact_css.load_from_string(
                "window.run-dialog.run-compact { background-color: transparent; }" +
                ".agent-card { padding: 12px; border-radius: 14px; background-color: alpha(currentColor, 0.06); }");
            StyleContext.add_provider_for_display(Gdk.Display.get_default(), compact_css,
                STYLE_PROVIDER_PRIORITY_USER);
            search_manager = SearchManager.get_default();
            search_manager.results_updated.connect(on_search_results);

            _actions = {
                new PaletteAction("customize", "e", "document-edit-symbolic",
                    _("Customize Panel and Dock"), _("Arrange desktop bar items directly on screen")),
                new PaletteAction("settings", "s", "preferences-system-symbolic",
                    _("Open Settings"), _("Open Singularity desktop settings")),
                new PaletteAction("lock", "l", "system-lock-screen-symbolic",
                    _("Lock Screen"), _("Lock this session")),
                new PaletteAction("workspaces", "w", "view-grid-symbolic",
                    _("Workspace Overview"), _("Show windows and workspaces")),
                new PaletteAction("launcher", "a", "view-app-grid-symbolic",
                    _("Application Launcher"), _("Browse installed applications")),
                new PaletteAction("terminal", "t", "utilities-terminal-symbolic",
                    _("Open Terminal"), _("Start the default terminal")),
                new PaletteAction("emoji", "m", "face-smile-symbolic",
                    _("Emoji Picker"), _("Insert an emoji or symbol")),
                new PaletteAction("screenshot", "p", "camera-photo-symbolic",
                    _("Take Screenshot"), _("Open the screenshot tool")),
                new PaletteAction("tiling", "i", "view-grid-symbolic",
                    _("Toggle Tiling"), _("Enable or disable automatic window tiling")),
                new PaletteAction("retile", "g", "view-refresh-symbolic",
                    _("Retile Windows"), _("Arrange the current windows again")),
                new PaletteAction("restart", "r", "system-reboot-symbolic",
                    _("Restart Shell"), _("Restart the desktop shell")),
                new PaletteAction("reload", "c", "view-refresh-symbolic",
                    _("Reload Compositor Configuration"), _("Regenerate and reload labwc settings"), true),
                new PaletteAction("nested", "n", "utilities-terminal-symbolic",
                    _("Start Nested Session"), _("Open a test desktop inside this session"), true)
            };

            entry = new Entry();
            entry.placeholder_text = _("Search apps or run a command...");
            entry.primary_icon_name = "system-search-symbolic";
            entry.primary_icon_activatable = false;
            entry.primary_icon_sensitive = false;
            entry.width_request = 450;
            entry.add_css_class("run-entry");
            entry.activate.connect(on_activate);
            entry.changed.connect(on_text_changed);

            var entry_overlay = new Overlay();
            entry_overlay.halign = Align.START;
            entry_overlay.set_child(entry);
            action_prefix = new Label("!");
            action_prefix.add_css_class("run-action-prefix");
            action_prefix.halign = Align.START;
            action_prefix.valign = Align.CENTER;
            action_prefix.margin_start = 13;
            action_prefix.can_target = false;
            action_prefix.visible = false;
            entry_overlay.add_overlay(action_prefix);

            ai_controls = new Box(Orientation.HORIZONTAL, 6);
            ai_controls.halign = Align.END;
            ai_controls.valign = Align.CENTER;
            ai_controls.margin_end = 6;
            ai_mode_select = new DropDown.from_strings({
                _("Plan"), _("Ask"), _("Auto"), _("Autopilot")
            });
            ai_mode_select.tooltip_text = _("How much Sinty AI may do without asking");
            ai_mode_select.visible = false;
            ai_mode_select.notify["selected"].connect(() => {
                if (!ai_mode_syncing) set_agent_mode(ai_mode_select.selected);
            });
            ai_controls.append(ai_mode_select);
            ai_spinner = new Spinner();
            ai_spinner.visible = false;
            ai_controls.append(ai_spinner);
            ai_close = new Button.from_icon_name("window-close-symbolic");
            ai_close.add_css_class("flat");
            ai_close.add_css_class("circular");
            ai_close.tooltip_text = _("Close");
            ai_close.visible = false;
            ai_close.clicked.connect(close_dialog);
            ai_controls.append(ai_close);
            entry_overlay.add_overlay(ai_controls);
            content_box.append(entry_overlay);

            error_label = new Label("");
            error_label.add_css_class("run-error");
            error_label.halign = Align.START;
            error_label.visible = false;
            error_label.wrap = true;
            error_label.xalign = 0;
            error_label.margin_start = 10;
            error_label.margin_end = 10;
            error_label.margin_bottom = 6;
            content_box.append(error_label);

            ai_answer = new Label("");
            ai_answer.wrap = true;
            ai_answer.wrap_mode = Pango.WrapMode.WORD_CHAR;
            ai_answer.selectable = true;
            ai_answer.xalign = 0;
            ai_answer.max_width_chars = 60;
            ai_answer.margin_start = 10;
            ai_answer.margin_end = 10;
            ai_answer.margin_top = 6;
            ai_answer.margin_bottom = 8;
            ai_scroll = new ScrolledWindow();
            ai_scroll.hscrollbar_policy = PolicyType.NEVER;
            ai_scroll.propagate_natural_height = true;
            ai_scroll.max_content_height = 560;
            ai_scroll.width_request = 450;
            ai_cards = new Box(Orientation.VERTICAL, 8);
            ai_cards.margin_start = 6;
            ai_cards.margin_end = 6;
            ai_cards.margin_top = 6;
            ai_cards.visible = false;
            var ai_body = new Box(Orientation.VERTICAL, 0);
            ai_body.append(ai_cards);
            ai_body.append(ai_answer);
            ai_scroll.child = ai_body;
            watch_agent_cards();
            ai_scroll.visible = false;
            content_box.append(ai_scroll);

            suggestions_revealer = new Revealer();
            suggestions_revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            suggestions_revealer.transition_duration = 120;
            suggestions_list = new ListBox();
            suggestions_list.add_css_class("run-suggestions");
            suggestions_list.selection_mode = SelectionMode.SINGLE;
            suggestions_list.row_activated.connect(on_suggestion_activated);

            var suggestions_scroll = new ScrolledWindow();
            suggestions_scroll.hscrollbar_policy = PolicyType.NEVER;
            suggestions_scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            suggestions_scroll.propagate_natural_height = true;
            suggestions_scroll.max_content_height = 300;
            suggestions_scroll.width_request = 450;
            suggestions_scroll.set_child(suggestions_list);
            suggestions_revealer.child = suggestions_scroll;

            preview_revealer = new Revealer();
            preview_revealer.transition_type = RevealerTransitionType.SLIDE_LEFT;
            preview_revealer.transition_duration = 160;
            preview_box = new Box(Orientation.VERTICAL, 8);
            preview_box.add_css_class("run-preview");
            preview_box.width_request = 300;
            preview_box.visible = false;
            preview_revealer.set_child(preview_box);

            var result_area = new Box(Orientation.HORIZONTAL, 0);
            result_area.append(suggestions_revealer);
            result_area.append(preview_revealer);
            content_box.append(result_area);

            suggestions_list.row_selected.connect(update_preview);

            var entry_keys = new EventControllerKey();
            entry_keys.key_pressed.connect(on_entry_key_pressed);
            entry.add_controller(entry_keys);

            var list_keys = new EventControllerKey();
            list_keys.key_pressed.connect(on_list_key_pressed);
            suggestions_list.add_controller(list_keys);

            var card_keys = new EventControllerKey();
            card_keys.key_pressed.connect((keyval) => {
                if (keyval != Gdk.Key.Escape) return false;
                close_dialog();
                return true;
            });
            ai_body.add_controller(card_keys);

            hide();
        }

        private bool dev_mode() {
            return _desktop_settings.get_boolean("developer-mode");
        }

        private void load_history() {
            string path = GLib.Path.build_filename(
                GLib.Environment.get_user_data_dir(), "singularity", "run_history");
            try {
                string contents;
                GLib.FileUtils.get_contents(path, out contents);
                _history = contents.strip().split("\n");
            } catch {
                _history = {};
            }
        }

        private void save_to_history(string command) {
            if (command.strip() == "") return;
            string[] history = { command.strip() };
            foreach (string item in _history) {
                if (item.strip() != "" && item.strip() != command.strip()) {
                    history += item.strip();
                }
                if (history.length >= 50) break;
            }
            _history = history;
            string path = GLib.Path.build_filename(
                GLib.Environment.get_user_data_dir(), "singularity", "run_history");
            try {
                GLib.DirUtils.create_with_parents(GLib.Path.get_dirname(path), 0755);
                GLib.FileUtils.set_contents(path, string.joinv("\n", _history));
            } catch { }
        }

        private void clear_suggestions() {
            while (suggestions_list.get_first_child() != null) {
                suggestions_list.remove(suggestions_list.get_first_child());
            }
        }

        private void set_results_visible(bool visible) {
            suggestions_revealer.reveal_child = visible;
            if (visible) content_box.add_css_class("has-results");
            else content_box.remove_css_class("has-results");
        }

        private void on_text_changed() {
            if (updating_text) return;
            string query = entry.text.strip();
            error_label.visible = false;

            if (ai_mode) return;

            if (!action_mode && query.has_prefix("@") && AgentConfig.configured()) {
                enter_ai_mode(query.substring(1));
                return;
            }

            if (!action_mode && query.has_prefix("!")) {
                enter_action_mode(query.substring(1));
                return;
            }

            if (action_mode) {
                schedule_action_results();
                return;
            }
            clear_suggestions();
            hide_preview();
            set_results_visible(false);

            entry.primary_icon_name = query == ""
                ? "system-search-symbolic" : "system-run-symbolic";
            schedule_search(query);
        }

        private void enter_action_mode(string query) {
            action_mode = true;
            action_prefix.visible = true;
            entry.primary_icon_name = null;
            entry.add_css_class("action-mode");
            entry.placeholder_text = _("Search actions and settings");
            updating_text = true;
            entry.text = query;
            entry.set_position(-1);
            updating_text = false;
            clear_suggestions();
            show_action_results(query);
            warm_settings_index();
        }

        private void leave_action_mode() {
            if (action_debounce != 0) {
                GLib.Source.remove(action_debounce);
                action_debounce = 0;
            }
            action_mode = false;
            action_prefix.visible = false;
            entry.remove_css_class("action-mode");
            entry.placeholder_text = _("Search apps or run a command...");
            entry.primary_icon_name = "system-search-symbolic";
            updating_text = true;
            entry.text = "";
            updating_text = false;
            clear_suggestions();
            hide_preview();
            set_results_visible(false);
            entry.grab_focus();
        }

        private void enter_ai_mode(string query) {
            if (search_debounce != 0) {
                GLib.Source.remove(search_debounce);
                search_debounce = 0;
            }
            active_query = "";
            ai_mode = true;
            action_prefix.label = "@";
            action_prefix.visible = true;
            entry.primary_icon_name = null;
            entry.add_css_class("action-mode");
            entry.placeholder_text = _("Ask Sinty AI");
            updating_text = true;
            entry.text = query;
            entry.set_position(-1);
            updating_text = false;
            clear_suggestions();
            hide_preview();
            set_results_visible(false);
            sync_agent_mode();
        }

        private void sync_agent_mode() {
            ai_mode_select.visible = ai_mode;
            reserve_ai_space();
            fetch_agent_mode.begin(2);
        }

        private async void fetch_agent_mode(int attempts) {
            try {
                var bus = yield Bus.get(BusType.SESSION);
                var reply = yield bus.call("dev.sinty.Agent", "/dev/sinty/Agent",
                    "dev.sinty.Agent1", "GetStatus", null, new VariantType("(s)"),
                    DBusCallFlags.NONE, 10000, null);
                string json;
                reply.get("(s)", out json);
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var current = parser.get_root().get_object().get_string_member_with_default("mode", "ask");
                for (uint i = 0; i < AGENT_MODES.length; i++) {
                    if (AGENT_MODES[i] != current) continue;
                    ai_mode_syncing = true;
                    ai_mode_select.selected = i;
                    ai_mode_syncing = false;
                }
                ai_mode_select.visible = ai_mode;
            } catch (Error e) {
                if (attempts > 1 && ai_mode) {
                    Timeout.add(500, () => {
                        fetch_agent_mode.begin(attempts - 1);
                        return Source.REMOVE;
                    });
                    return;
                }
                warning("Sinty AI status: %s", e.message);
                ai_mode_select.visible = false;
            }
            reserve_ai_space();
        }

        private void set_agent_mode(uint index) {
            if (index >= AGENT_MODES.length) return;
            store_agent_mode.begin(AGENT_MODES[index]);
        }

        private async void store_agent_mode(string mode) {
            try {
                var bus = yield Bus.get(BusType.SESSION);
                yield bus.call("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1",
                    "SetMode", new Variant("(s)", mode), null, DBusCallFlags.NONE, 10000, null);
            } catch (Error e) {
                warning("Sinty AI mode: %s", e.message);
                sync_agent_mode();
            }
        }

        private void leave_ai_mode() {
            stop_ai();
            set_ai_compact(false);
            ai_mode_select.visible = false;
            ai_mode = false;
            reserve_ai_space();
            ai_direct = false;
            action_prefix.label = "!";
            action_prefix.visible = false;
            ai_answer.label = "";
            clear_agent_cards();
            ai_scroll.visible = false;
            entry.sensitive = true;
            entry.remove_css_class("action-mode");
            entry.placeholder_text = _("Search apps or run a command...");
            entry.primary_icon_name = "system-search-symbolic";
            updating_text = true;
            entry.text = "";
            updating_text = false;
        }

        private void reserve_ai_space() {
            int min, nat, bmin, bnat;
            ai_controls.measure(Orientation.HORIZONTAL, -1, out min, out nat, out bmin, out bnat);
            var text = entry.get_delegate() as Widget;
            if (text == null) return;
            text.margin_end = ai_mode_select.visible || ai_close.visible ? nat + ai_controls.margin_end + 6 : 0;
        }

        private void stop_ai() {
            if (ai_process != null) ai_process.force_exit();
            ai_process = null;
            ai_spinner.stop();
            ai_spinner.visible = false;
        }

        private void set_ai_compact(bool compact) {
            if (ai_compact == compact) return;
            ai_compact = compact;
            ai_close.visible = compact;
            reserve_ai_space();
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, !compact);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, !compact);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, !compact);
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, compact ? 12 : 0);
            content_box.margin_top = compact ? 36 : 0;
            content_box.margin_bottom = compact ? 60 : 0;
            content_box.margin_start = compact ? 48 : 0;
            content_box.margin_end = compact ? 48 : 0;
            if (compact) add_css_class("run-compact");
            else remove_css_class("run-compact");
            if (compact) set_default_size(-1, -1);
            queue_resize();
        }

        private void watch_agent_cards() {
            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    var bus = Bus.get.end(res);
                    bus.signal_subscribe("dev.sinty.Agent", "dev.sinty.Agent1", "IntentDone", "/dev/sinty/Agent",
                        null, DBusSignalFlags.NONE, (conn, sender, path, iface, name, parameters) => {
                            string app, intent, args, result;
                            parameters.get("(ssss)", out app, out intent, out args, out result);
                            show_agent_card(app, intent, args, result);
                        });
                } catch (Error e) {
                    warning("Sinty AI cards: %s", e.message);
                }
            });
        }

        private void show_agent_card(string app, string intent, string args, string result) {
            if (!visible || !ai_mode) return;
            var card = AgentCards.get_default().build(app, intent, args, result);
            if (card == null) return;
            ai_cards.append(card);
            ai_cards.visible = true;
            ai_scroll.visible = true;
            queue_resize();
        }

        private void clear_agent_cards() {
            Widget? child;
            while ((child = ai_cards.get_first_child()) != null) ai_cards.remove(child);
            ai_cards.visible = false;
        }

        private void ask_ai() {
            var text = entry.text.strip();
            if (text == "" || ai_process != null) return;
            if (text.has_prefix("--")) text = " " + text;
            error_label.visible = false;
            ai_answer.label = "";
            clear_agent_cards();
            ai_scroll.visible = false;
            ai_spinner.visible = true;
            ai_spinner.start();
            entry.sensitive = false;
            set_ai_compact(true);
            run_ai.begin(text);
        }

        private async void run_ai(string text) {
            string? out_text = null;
            string? err_text = null;
            Subprocess? process = null;
            bool ok = false;
            string failure = "";
            try {
                var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                var token = yield AgentConfig.grant_session();
                if (token != null) launcher.setenv("SINTY_AGENT_TOKEN", token, true);
                process = launcher.spawnv({ AgentConfig.BINARY, "ask", "--conversation", ai_conversation, text });
                ai_process = process;
                yield process.communicate_utf8_async(null, null, out out_text, out err_text);
                ok = process.get_successful();
                failure = ((out_text ?? "") + "\n" + (err_text ?? "")).strip();
            } catch (Error e) {
                failure = e.message;
            }
            if (ai_process != process) return;
            ai_process = null;
            ai_spinner.stop();
            ai_spinner.visible = false;
            entry.sensitive = true;
            entry.grab_focus();
            if (ok) {
                string answer = (out_text ?? "").strip();
                string markup = AnswerMarkup.to_pango(answer);
                try {
                    Pango.parse_markup(markup, -1, 0, null, null, null);
                    ai_answer.set_markup(markup);
                } catch (Error e) {
                    ai_answer.label = answer;
                }
                ai_answer.visible = answer != "";
                ai_scroll.visible = answer != "" || ai_cards.visible;
                updating_text = true;
                entry.text = "";
                updating_text = false;
            } else if (failure.contains("no key for this provider")) {
                error_label.label = _("No API key saved. Add one in Settings, Sinty AI.");
                error_label.visible = true;
            } else {
                error_label.label = failure.strip() != "" ? failure.strip() : _("The request failed");
                error_label.visible = true;
            }
            queue_resize();
        }

        private void schedule_search(string query) {
            if (search_debounce != 0) {
                GLib.Source.remove(search_debounce);
                search_debounce = 0;
            }
            active_query = query;
            if (query == "") {
                set_results_visible(false);
                return;
            }

            search_debounce = GLib.Timeout.add(120, () => {
                search_debounce = 0;
                search_manager.query.begin(query);
                return GLib.Source.REMOVE;
            });
        }

        private void on_search_results(List<SearchResult> results) {
            if (!visible || action_mode || entry.text.strip() != active_query) return;
            clear_suggestions();
            int count = 0;
            foreach (var result in results) {
                var row = new ListBoxRow();
                var row_box = new Box(Orientation.HORIZONTAL, 8);
                row_box.margin_start = 8;
                row_box.margin_end = 8;
                row_box.margin_top = 6;
                row_box.margin_bottom = 6;
                var image = new Image();
                image.pixel_size = 20;
                if (result.gicon != null) image.set_from_gicon(result.gicon);
                else image.icon_name = result.icon_name ?? "system-search-symbolic";
                row_box.append(image);

                var labels = new Box(Orientation.VERTICAL, 1);
                labels.hexpand = true;
                var title = new Label(result.title);
                title.halign = Align.START;
                title.ellipsize = Pango.EllipsizeMode.END;
                labels.append(title);
                if (result.provider.id != "apps"
                        && result.description != null && result.description != "") {
                    var description = new Label(result.description);
                    description.halign = Align.START;
                    description.ellipsize = Pango.EllipsizeMode.MIDDLE;
                    description.add_css_class("dim-label");
                    description.add_css_class("caption");
                    labels.append(description);
                }
                row_box.append(labels);
                var preview = SearchResultRow.build_result_preview(result.preview, 24);
                if (preview != null) row_box.append(preview);
                var actions = SearchResultRow.build_result_actions(result, () => close_dialog());
                if (actions != null) row_box.append(actions);
                row.set_child(row_box);
                row.set_data<SearchResult>("search-result", result);
                suggestions_list.append(row);
                if (++count >= 10) break;
            }
            suggestions_list.set_header_func(search_group_header);
            set_results_visible(count > 0);
            var first = suggestions_list.get_row_at_index(0);
            if (first != null) suggestions_list.select_row(first);
        }

        private void search_group_header(ListBoxRow row, ListBoxRow? before) {
            SearchResult? result = row.get_data<SearchResult>("search-result");
            SearchResult? previous = before != null ? before.get_data<SearchResult>("search-result") : null;
            if (result == null || (previous != null && previous.provider.id == result.provider.id)
                    || (previous == null && before == null && result.provider.id == "apps")) {
                row.set_header(null);
                return;
            }
            var label = new Label(result.provider.name);
            label.add_css_class("dim-label");
            label.add_css_class("caption");
            label.halign = Align.START;
            label.margin_start = 8;
            label.margin_top = 6;
            row.set_header(label);
        }

        private void show_action_results(string query) {
            string needle = query.strip().down();
            int count = 0;
            foreach (var action in _actions) {
                if (action.developer_only && !dev_mode()) continue;
                string title = action.title;
                if (action.id == "tiling") {
                    title = _desktop_settings.get_boolean("tiling-enabled")
                        ? _("Disable Tiling") : _("Enable Tiling");
                }
                if (needle != ""
                        && !action.key.has_prefix(needle)
                        && !title.down().contains(needle)
                        && !action.subtitle.down().contains(needle)) {
                    continue;
                }

                var row = new ListBoxRow();
                var row_box = new Box(Orientation.HORIZONTAL, 8);
                row_box.margin_start = 8;
                row_box.margin_end = 8;
                row_box.margin_top = 6;
                row_box.margin_bottom = 6;
                var image = new Image.from_icon_name(action.icon_name);
                image.pixel_size = 20;
                row_box.append(image);
                var label = new Label(title);
                label.halign = Align.START;
                label.hexpand = true;
                row_box.append(label);
                var key = new Label("!" + action.key);
                key.add_css_class("dim-label");
                key.add_css_class("caption");
                row_box.append(key);
                row.set_child(row_box);
                row.set_data<string>("action-id", action.id);
                suggestions_list.append(row);
                count++;
            }
            if (needle.char_count() >= 2 && settings_index_ready) count += append_setting_results(needle);
            set_results_visible(count > 0);
            if (count > 0) suggestions_list.select_row(suggestions_list.get_row_at_index(0));
        }

        private Gee.List<SettingsEntry>? setting_entries = null;
        private bool settings_index_ready = false;
        private bool settings_index_warming = false;
        private uint action_debounce = 0;

        private void warm_settings_index() {
            if (settings_index_ready || settings_index_warming) return;
            var app = GLib.Application.get_default() as SingularityApp;
            if (app == null) return;
            settings_index_warming = true;
            app.warm_settings_index.begin((obj, res) => {
                app.warm_settings_index.end(res);
                settings_index_warming = false;
                settings_index_ready = true;
                if (visible && action_mode) refresh_action_results();
            });
        }

        private void schedule_action_results() {
            if (action_debounce != 0) GLib.Source.remove(action_debounce);
            action_debounce = GLib.Timeout.add(60, () => {
                action_debounce = 0;
                refresh_action_results();
                return GLib.Source.REMOVE;
            });
        }

        private void refresh_action_results() {
            if (!action_mode) return;
            clear_suggestions();
            show_action_results(entry.text.strip());
        }

        private int append_setting_results(string needle) {
            if (setting_entries == null) {
                var app = GLib.Application.get_default() as SingularityApp;
                if (app == null) return 0;
                setting_entries = new Gee.ArrayList<SettingsEntry>();
                setting_entries.add_all(app.settings_entries());
            }
            int count = 0;
            foreach (var entry in setting_entries) {
                string haystack = "%s %s %s %s".printf(entry.title, entry.subtitle, entry.group,
                    entry.page_title).down();
                if (!haystack.contains(needle)) continue;

                var row = new ListBoxRow();
                var row_box = new Box(Orientation.HORIZONTAL, 8);
                row_box.margin_start = 8;
                row_box.margin_end = 8;
                row_box.margin_top = 6;
                row_box.margin_bottom = 6;
                var image = new Image.from_icon_name(entry.icon_name);
                image.pixel_size = 20;
                row_box.append(image);
                var labels = new Box(Orientation.VERTICAL, 0);
                labels.hexpand = true;
                var title = new Label(entry.title);
                title.halign = Align.START;
                title.ellipsize = Pango.EllipsizeMode.END;
                labels.append(title);
                var path = new Label(entry.group != "" ? "%s / %s".printf(entry.page_title, entry.group)
                    : entry.page_title);
                path.add_css_class("dim-label");
                path.add_css_class("caption");
                path.halign = Align.START;
                path.ellipsize = Pango.EllipsizeMode.END;
                labels.append(path);
                row_box.append(labels);
                var state = new Label("");
                state.add_css_class("dim-label");
                state.add_css_class("caption");
                row_box.append(state);
                update_setting_state(entry, state);
                row.set_child(row_box);
                row.set_data<SettingsEntry>("setting-entry", entry);
                row.set_data<Label>("setting-state", state);
                suggestions_list.append(row);
                if (++count >= 40) break;
            }
            return count;
        }

        private void update_setting_state(SettingsEntry entry, Label state) {
            var toggle = entry.toggle();
            if (toggle != null) {
                state.label = toggle.active ? _("On") : _("Off");
            } else if (entry.kind == SettingsEntryKind.LAUNCH) {
                state.label = _("Open");
            } else {
                state.label = _("Show");
            }
        }

        private void on_suggestion_activated(ListBoxRow row) {
            SettingsEntry? entry = row.get_data<SettingsEntry>("setting-entry");
            if (entry != null) {
                var toggle = entry.toggle();
                if (toggle != null) {
                    toggle.active = !toggle.active;
                    update_setting_state(entry, row.get_data<Label>("setting-state"));
                    return;
                }
                close_dialog();
                var app = GLib.Application.get_default() as SingularityApp;
                app?.reveal_setting(entry, entry.kind == SettingsEntryKind.LAUNCH);
                return;
            }
            string? action_id = row.get_data<string>("action-id");
            if (action_id != null) {
                execute_palette_action(action_id);
                return;
            }

            SearchResult? result = row.get_data<SearchResult>("search-result");
            if (result == null) return;
            result.activate();
            if (!result.keeps_open) close_dialog();
        }

        private void update_preview(ListBoxRow? row) {
            hide_preview();
            if (row == null || action_mode) return;
            SearchResult? result = row.get_data<SearchResult>("search-result");
            if (result == null || result.provider.id != "files"
                    || result.action_id == null || result.mime_type == null) {
                return;
            }

            string mime_type = result.mime_type;
            if (mime_type.has_prefix("image/")) {
                show_image_preview(result);
            } else if (mime_type.has_prefix("text/")
                    || mime_type == "application/json"
                    || mime_type == "application/javascript"
                    || mime_type == "application/xml") {
                show_text_preview(result);
            }
        }

        private void hide_preview() {
            preview_revealer.reveal_child = false;
            preview_box.visible = false;
            while (preview_box.get_first_child() != null) {
                preview_box.remove(preview_box.get_first_child());
            }
        }

        private void append_preview_header(SearchResult result) {
            var title = new Label(result.title);
            title.add_css_class("run-preview-title");
            title.halign = Align.START;
            title.ellipsize = Pango.EllipsizeMode.END;
            preview_box.append(title);
            if (result.description != null && result.description != "") {
                var path = new Label(result.description);
                path.halign = Align.START;
                path.ellipsize = Pango.EllipsizeMode.MIDDLE;
                path.add_css_class("dim-label");
                path.add_css_class("caption");
                preview_box.append(path);
            }
        }

        private void show_image_preview(SearchResult result) {
            var file = GLib.File.new_for_uri(result.action_id);
            string? path = file.get_path();
            if (path == null) return;
            try {
                var pixbuf = Singularity.Compute.load_scaled(path, 300, 240, true);
                var texture = Gdk.Texture.for_pixbuf(pixbuf);
                var picture = new Picture();
                picture.set_paintable(texture);
                picture.content_fit = ContentFit.CONTAIN;
                picture.height_request = 240;
                picture.hexpand = true;
                append_preview_header(result);
                preview_box.append(picture);
                preview_box.visible = true;
                preview_revealer.reveal_child = true;
            } catch (Error e) { }
        }

        private void show_text_preview(SearchResult result) {
            var file = GLib.File.new_for_uri(result.action_id);
            try {
                var stream = file.read();
                uint8[] buffer = new uint8[4096];
                size_t bytes_read;
                stream.read_all(buffer, out bytes_read);
                if (bytes_read == 0) return;
                buffer.length = (int)bytes_read;
                string text = ((string)buffer).substring(0, (long)bytes_read);
                if (!text.validate()) return;

                var text_view = new TextView();
                text_view.editable = false;
                text_view.cursor_visible = false;
                text_view.monospace = true;
                text_view.wrap_mode = WrapMode.WORD_CHAR;
                text_view.buffer.text = text;
                text_view.add_css_class("run-preview-text");

                var scroll = new ScrolledWindow();
                scroll.hscrollbar_policy = PolicyType.NEVER;
                scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
                scroll.height_request = 240;
                scroll.set_child(text_view);
                append_preview_header(result);
                preview_box.append(scroll);
                preview_box.visible = true;
                preview_revealer.reveal_child = true;
            } catch (Error e) { }
        }

        private bool focus_suggestion(bool last) {
            if (!suggestions_revealer.reveal_child) return false;
            int index = last ? int.max(0, row_count() - 1) : 0;
            var row = suggestions_list.get_row_at_index(index);
            if (row == null) return false;
            suggestions_list.select_row(row);
            row.grab_focus();
            return true;
        }

        private int row_count() {
            int count = 0;
            while (suggestions_list.get_row_at_index(count) != null) count++;
            return count;
        }

        private bool on_entry_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (keyval == Gdk.Key.Escape) {
                if (ai_mode) {
                    if (ai_direct || ai_compact) close_dialog();
                    else leave_ai_mode();
                } else if (action_mode) leave_action_mode();
                else close_dialog();
                return true;
            }
            if (ai_mode) return false;
            if (keyval == Gdk.Key.Down) {
                if (focus_suggestion(false)) return true;
                if (_history_pos <= 0) {
                    _history_pos = -1;
                    entry.text = "";
                } else {
                    _history_pos--;
                    entry.text = _history[_history_pos];
                    entry.set_position(-1);
                }
                return true;
            }
            if (keyval == Gdk.Key.Up) {
                if (focus_suggestion(true)) return true;
                if (_history.length == 0) return true;
                _history_pos = int.min(_history_pos + 1, (int)_history.length - 1);
                entry.text = _history[_history_pos];
                entry.set_position(-1);
                return true;
            }
            if (keyval == Gdk.Key.Page_Down) return focus_suggestion(true);
            if (keyval == Gdk.Key.Page_Up) return focus_suggestion(false);
            return false;
        }

        private bool on_list_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (keyval == Gdk.Key.Escape) {
                if (action_mode) leave_action_mode();
                else close_dialog();
                return true;
            }
            return false;
        }

        private void on_activate() {
            if (ai_mode) {
                ask_ai();
                return;
            }
            if (action_mode) {
                var selected = suggestions_list.get_selected_row();
                if (selected != null) on_suggestion_activated(selected);
                return;
            }

            var selected = suggestions_list.get_selected_row();
            if (selected != null
                    && selected.get_data<SearchResult>("search-result") != null) {
                on_suggestion_activated(selected);
                return;
            }

            string command = entry.text.strip();
            if (command == "") return;
            error_label.visible = false;
            if (!ParentalEnforcer.get_default().allows_command(command)) {
                show_error(_("This app is blocked by parental controls."));
                return;
            }

            string inner = command + "; exec \"${SHELL:-bash}\"";
            string wrapped = "sh -lc " + GLib.Shell.quote(inner);
            try {
                var info = AppInfo.create_from_commandline(
                    wrapped, null, AppInfoCreateFlags.NEEDS_TERMINAL);
                info.launch(null, null);
                save_to_history(command);
                close_dialog();
            } catch (Error e) {
                try {
                    SystemMonitor.get_default().shortcuts.spawn_terminal_with_command(wrapped);
                    save_to_history(command);
                    close_dialog();
                } catch (Error fallback_error) {
                    show_error(fallback_error.message);
                }
            }
        }

        private void execute_palette_action(string id) {
            switch (id) {
                case "customize":
                    close_dialog();
                    _desktop_settings.set_boolean("bar-layout-edit-mode", true);
                    break;
                case "settings":
                    close_dialog();
                    var app = GLib.Application.get_default() as SingularityApp;
                    app?.open_settings_page("home");
                    break;
                case "lock":
                    close_dialog();
                    SystemMonitor.get_default().shortcuts.execute_action("lock_screen");
                    break;
                case "workspaces":
                    close_dialog();
                    SystemMonitor.get_default().shortcuts.execute_action("toggle_workspace_overview");
                    break;
                case "launcher":
                    close_dialog();
                    SystemMonitor.get_default().shortcuts.execute_action("toggle_launcher");
                    break;
                case "terminal":
                    close_dialog();
                    SystemMonitor.get_default().shortcuts.execute_action("spawn_terminal");
                    break;
                case "emoji":
                    close_dialog();
                    SystemMonitor.get_default().shortcuts.execute_action("toggle_emoji_picker");
                    break;
                case "screenshot":
                    close_dialog();
                    SystemMonitor.get_default().shortcuts.execute_action("screenshot_tool");
                    break;
                case "tiling":
                    close_dialog();
                    _desktop_settings.set_boolean("tiling-enabled",
                        !_desktop_settings.get_boolean("tiling-enabled"));
                    break;
                case "retile":
                    close_dialog();
                    SystemMonitor.get_default().shortcuts.execute_action("retile_windows");
                    break;
                case "restart":
                    close_dialog();
                    Posix.kill(Posix.getpid(), Posix.Signal.USR1);
                    break;
                case "reload":
                    close_dialog();
                    Singularity.Compositor.LabwcBackend.get_default().reconfigure();
                    GLib.Timeout.add(300, () => {
                        Posix.kill(Posix.getpid(), Posix.Signal.USR1);
                        return GLib.Source.REMOVE;
                    });
                    break;
                case "nested":
                    close_dialog();
                    launch_nested_session();
                    break;
            }
        }

        private void show_error(string message) {
            error_label.label = _("Error: %s").printf(message);
            error_label.visible = true;
        }

        private void launch_nested_session() {
            string prefix = "/opt/local";
            try {
                string executable = GLib.FileUtils.read_link("/proc/self/exe");
                prefix = GLib.Path.get_dirname(GLib.Path.get_dirname(executable));
            } catch (Error e) { }
            string script = ("""
set -e
export LD_LIBRARY_PATH=%s/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export GSETTINGS_SCHEMA_DIR=%s/share/glib-2.0/schemas
export PATH=%s/bin:$PATH
export GDK_BACKEND=wayland
export GSK_RENDERER=gl
export XDG_CURRENT_DESKTOP=Singularity
S=$(mktemp /tmp/sing-nested.XXXXXX.sh)
cat > "$S" <<'INNER'
#!/bin/bash
%s/bin/singularity-desktop &
sleep 1
( command -v gtk4-demo >/dev/null && gtk4-demo ) &
( command -v gnome-text-editor >/dev/null && gnome-text-editor ) &
INNER
chmod +x "$S"
exec dbus-run-session -- %s/bin/labwc -s "$S"
""").printf(prefix, prefix, prefix, prefix, prefix);
            try {
                Process.spawn_async(null,
                    { "/bin/bash", "-c", script, null },
                    null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (Error e) {
                show_error(_("Nested launch failed: %s").printf(e.message));
            }
        }

        public override void open_dialog() {
            setting_entries = null;
            ai_conversation = "palette-" + GLib.get_real_time().to_string() + "-" + GLib.Random.next_int().to_string();
            load_history();
            _history_pos = -1;
            leave_ai_mode();
            leave_action_mode();
            cancel_close();
            opacity = 0;
            if (dialog_animation != null) dialog_animation.skip();
            dialog_animation = new Singularity.Animation.TimedAnimation(
                this, 0, 1, 180,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC
            );
            dialog_animation.tick.connect(() => { opacity = dialog_animation.value; });
            dialog_animation.play();
            present();
        }

        public override void close_dialog() {
            stop_ai();
            if (search_debounce != 0) {
                GLib.Source.remove(search_debounce);
                search_debounce = 0;
            }
            set_results_visible(false);
            hide_preview();
            error_label.visible = false;
            if (dialog_animation != null) dialog_animation.skip();
            dialog_animation = new Singularity.Animation.TimedAnimation(
                this, 1, 0, 130,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC
            );
            dialog_animation.tick.connect(() => { opacity = dialog_animation.value; });
            dialog_animation.done.connect(finish_close);
            closing = true;
            if (close_guard != 0) GLib.Source.remove(close_guard);
            close_guard = GLib.Timeout.add(300, () => {
                close_guard = 0;
                finish_close();
                return GLib.Source.REMOVE;
            });
            dialog_animation.play();
        }

        private void cancel_close() {
            closing = false;
            if (close_guard != 0) {
                GLib.Source.remove(close_guard);
                close_guard = 0;
            }
        }

        private void finish_close() {
            if (!closing) return;
            cancel_close();
            hide();
        }

        private bool shown() {
            return visible && !closing;
        }

        public void toggle_ai() {
            if (!AgentConfig.configured()) return;
            if (shown() && ai_mode) {
                close_dialog();
                return;
            }
            if (!shown()) open_dialog();
            else leave_action_mode();
            enter_ai_mode("");
            ai_direct = true;
            entry.grab_focus();
        }

        public void toggle() {
            if (shown()) {
                close_dialog();
            } else {
                open_dialog();
                entry.grab_focus();
            }
        }
    }
}
