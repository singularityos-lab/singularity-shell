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
        private GLib.Settings _desktop_settings = new GLib.Settings("dev.sinty.desktop");
        private bool action_mode = false;
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
            content_box.append(entry_overlay);

            error_label = new Label("");
            error_label.add_css_class("run-error");
            error_label.halign = Align.START;
            error_label.visible = false;
            error_label.wrap = true;
            error_label.xalign = 0;
            content_box.append(error_label);

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

            if (!action_mode && query.has_prefix("!")) {
                enter_action_mode(query.substring(1));
                return;
            }

            clear_suggestions();
            hide_preview();
            set_results_visible(false);
            if (action_mode) {
                show_action_results(query);
                return;
            }

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
        }

        private void leave_action_mode() {
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
                row.set_child(row_box);
                row.set_data<SearchResult>("search-result", result);
                suggestions_list.append(row);
                if (++count >= 10) break;
            }
            set_results_visible(count > 0);
            var first = suggestions_list.get_row_at_index(0);
            if (first != null) suggestions_list.select_row(first);
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
            if (needle.char_count() >= 2) count += append_setting_results(needle);
            set_results_visible(count > 0);
            if (count > 0) suggestions_list.select_row(suggestions_list.get_row_at_index(0));
        }

        private Gee.List<SettingsEntry>? setting_entries = null;

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
            close_dialog();
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
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 300, 240, true);
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
                if (action_mode) leave_action_mode();
                else close_dialog();
                return true;
            }
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
            load_history();
            _history_pos = -1;
            leave_action_mode();
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
            dialog_animation.done.connect(() => { hide(); });
            dialog_animation.play();
        }

        public void toggle() {
            if (visible) {
                close_dialog();
            } else {
                open_dialog();
                entry.grab_focus();
            }
        }
    }
}
