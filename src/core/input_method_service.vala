namespace Singularity {

    public class InputMethodService : Object {
        private const uint KEY_SPACE = 0x0020;
        private const uint KEY_BACKSPACE = 0xff08;
        private const uint KEY_ESCAPE = 0xff1b;
        private const uint KEY_RETURN = 0xff0d;
        private const uint KEY_KP_ENTER = 0xff8d;
        private const uint KEY_LEFT = 0xff51;
        private const uint KEY_RIGHT = 0xff53;
        private const uint KEY_TAB = 0xff09;
        private const uint KEYCODE_BACKSPACE = 14;
        private const uint MOD_BLOCKING = 0x2 | 0x4 | 0x8;
        private const uint HINT_PRIVATE = 0x40 | 0x80;

        private static InputMethodService? instance = null;

        public signal void suggestions_changed(string word, string[] suggestions);
        public signal void escape_pressed();
        public signal void dictation_clicked();

        public bool active { get; private set; default = false; }
        public bool capture_escape { get; set; default = false; }
        public bool dictating { get; set; default = false; }
        public bool has_surrounding { get; private set; default = false; }
        private string typed_word = "";
        public Singularity.InputMethods.ImePopup popup { get; private set; }

        private GLib.Settings settings;
        private Singularity.Text.SpellChecker checker;
        private string surrounding = "";
        private uint cursor = 0;
        private uint purpose = 0;
        private uint hint = 0;
        private Gee.HashSet<string> rejected = new Gee.HashSet<string>();
        private string? corrected_from = null;
        private string? corrected_to = null;
        private uint hold_key = 0;
        private string hold_text = "";
        private uint hold_timeout = 0;
        private uint suggest_timeout = 0;
        private string current_word = "";
        private string[] popup_items = {};
        private bool popup_accents = false;
        private int popup_selected = -1;
        private Singularity.InputMethods.Candidates? engine_candidates = null;
        private string engine_preedit = "";
        private Queue<PendingKey?> key_queue = new Queue<PendingKey?>();
        private bool draining = false;
        private Singularity.InputMethods.InputEngine? bound_engine = null;

        private struct PendingKey {
            public uint key;
            public uint keysym;
            public bool pressed;
            public uint state;
        }

        public static InputMethodService get_default() {
            if (instance == null) instance = new InputMethodService();
            return instance;
        }

        private InputMethodService() {
            settings = new GLib.Settings("dev.sinty.desktop");
            checker = Singularity.Text.SpellChecker.get_default();
            popup = new Singularity.InputMethods.ImePopup();
            notify["capture-escape"].connect(update_grab);
            notify["dictating"].connect(() => {
                if (dictating) {
                    popup_items = {};
                    popup_accents = false;
                } else {
                    popup.hide();
                    schedule_suggestions();
                }
            });
            settings.changed["spell-check-all-apps"].connect(() => {
                update_grab();
                schedule_suggestions();
            });
            foreach (string key in new string[] { "spell-check-all-apps", "input-method-engines", "dictation-enabled" }) {
                settings.changed[key].connect(sync_environment);
            }
            var sources = Singularity.InputMethods.InputSources.get_default();
            sources.engine_ready.connect(bind_engine);
            sources.changed.connect(() => {
                if (sources.current == "") clear_engine_ui();
                update_grab();
            });
            foreach (string key in new string[] { "spell-autocorrect", "press-hold-accents" }) {
                settings.changed[key].connect(update_grab);
            }
            foreach (string key in new string[] { "spell-suggestions", "screen-keyboard-enabled" }) {
                settings.changed[key].connect(schedule_suggestions);
            }
            foreach (string key in new string[] { "spell-autocorrect", "spell-suggestions", "press-hold-accents" }) {
                settings.changed[key].connect(sync_environment);
            }
        }

        private static bool stale_gtk_module = false;
        private GLib.Settings? interface_settings = null;

        public static void prepare_environment() {
            if (Environment.get_variable("GTK_IM_MODULE") == "wayland") {
                Environment.unset_variable("GTK_IM_MODULE");
                stale_gtk_module = true;
            }
        }

        public static void keep_local_input() {
            var gtk_settings = Gtk.Settings.get_default();
            if (gtk_settings != null) gtk_settings.gtk_im_module = "gtk-im-context-simple";
        }

        private void sync_environment() {
            bool wanted = settings.get_boolean("spell-autocorrect") || settings.get_boolean("spell-suggestions")
                || settings.get_boolean("press-hold-accents") || settings.get_boolean("spell-check-all-apps")
                || settings.get_strv("input-method-engines").length > 0 || settings.get_boolean("dictation-enabled");
            sync_gtk_module(wanted);
            sync_qt_module(wanted);
        }

        private void sync_gtk_module(bool wanted) {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("org.gnome.desktop.interface", true) : null;
            if (schema == null || !schema.has_key("gtk-im-module")) return;
            if (interface_settings == null) interface_settings = new GLib.Settings("org.gnome.desktop.interface");
            string module = interface_settings.get_string("gtk-im-module");
            if (wanted && module == "") interface_settings.set_string("gtk-im-module", "wayland");
            else if (!wanted && module == "wayland") interface_settings.set_string("gtk-im-module", "");
        }

        private void sync_qt_module(bool wanted) {
            string env_path = Path.build_filename(Environment.get_user_config_dir(), "labwc", "environment");
            string existing = "";
            try {
                if (FileUtils.test(env_path, FileTest.EXISTS)) FileUtils.get_contents(env_path, out existing);
            } catch (FileError e) {
                warning("Input method: cannot read %s: %s", env_path, e.message);
                return;
            }
            bool foreign = false;
            string body = "";
            foreach (string line in existing.split("\n")) {
                string item = line.strip();
                if (item == "" || item == "GTK_IM_MODULE=wayland" || item == "QT_IM_MODULE=wayland") continue;
                if (item.has_prefix("QT_IM_MODULE=")) foreign = true;
                body += line + "\n";
            }
            if (wanted && !foreign) body += "QT_IM_MODULE=wayland\n";
            if (body != existing) {
                try {
                    DirUtils.create_with_parents(Path.get_dirname(env_path), 0700);
                    FileUtils.set_contents(env_path, body);
                } catch (FileError e) {
                    warning("Input method: cannot write %s: %s", env_path, e.message);
                }
            }
            if (foreign) return;
            if (wanted) Environment.set_variable("QT_IM_MODULE", "wayland", true);
            else if (Environment.get_variable("QT_IM_MODULE") == "wayland") Environment.unset_variable("QT_IM_MODULE");
            string[] argv = { "dbus-update-activation-environment", "QT_IM_MODULE=" + (wanted ? "wayland" : "") };
            if (stale_gtk_module) argv += "GTK_IM_MODULE=";
            try {
                new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            } catch (Error e) {
                warning("Input method: cannot update the activation environment: %s", e.message);
            }
        }

        public void start() {
            sync_environment();
            sync_typing_layout();
            settings.changed["xkb-layout"].connect(sync_typing_layout);
            settings.changed["xkb-variant"].connect(sync_typing_layout);
            Singularity.ime_start(on_key, on_state, on_pointer);
        }

        private void sync_typing_layout() {
            Singularity.type_text_set_layout(settings.get_string("xkb-layout"), settings.get_string("xkb-variant"));
        }

        private bool spell_context() {
            return active && (purpose == 0 || purpose == 1) && (hint & HINT_PRIVATE) == 0
                && settings.get_boolean("spell-check-all-apps") && !engine_context() && !own_client()
                && checker.enabled && checker.available;
        }

        public bool own_client() {
            string? app = AppSystem.get_default().get_focused_app_id();
            if (app == null || app == "") return false;
            if (app.has_prefix("dev.sinty.")) return true;
            return app in settings.get_strv("spell-skip-apps");
        }

        public bool engine_context() {
            var sources = Singularity.InputMethods.InputSources.get_default();
            if (!active || sources.current == "" || sources.engine == null) return false;
            if ((hint & HINT_PRIVATE) != 0) return false;
            return purpose <= 1 || purpose == 5 || purpose == 6 || purpose == 7 || purpose == 13;
        }

        public string text_before_cursor() {
            return active ? before_cursor() : "";
        }

        public void set_preedit(string text) {
            if (!active) return;
            Singularity.ime_preedit(text, text.length, text.length);
        }

        public bool accent_context() {
            return active && (purpose <= 1 || purpose == 5 || purpose == 6 || purpose == 7)
                && (hint & HINT_PRIVATE) == 0;
        }

        private void update_grab() {
            bool grab = (settings.get_boolean("spell-autocorrect") && spell_context())
                || (!has_surrounding && spell_context())
                || (settings.get_boolean("press-hold-accents") && accent_context() && !engine_context())
                || engine_context() || (capture_escape && active)
                || (popup_items.length > 0 && !popup_accents);
            Singularity.ime_set_grab(grab);
        }

        private void bind_engine(Singularity.InputMethods.InputEngine? engine) {
            if (engine == bound_engine) {
                update_grab();
                return;
            }
            if (bound_engine != null) SignalHandler.disconnect_matched(bound_engine, SignalMatchType.DATA, 0, 0, null, null, this);
            bound_engine = engine;
            clear_engine_ui();
            if (engine != null) {
                engine.commit.connect(on_engine_commit);
                engine.preedit.connect(on_engine_preedit);
                engine.candidates.connect(on_engine_candidates);
                engine.forward_key.connect(on_engine_forward);
                engine.delete_surrounding.connect(on_engine_delete);
                if (active) {
                    engine.focus_in();
                    engine.set_surrounding(surrounding, surrounding.substring(0, cursor).char_count());
                }
            }
            update_grab();
        }

        private void on_engine_commit(string text) {
            engine_preedit = "";
            if (active && text != "") Singularity.ime_replace(0, 0, text);
        }

        private void on_engine_preedit(string text, int char_cursor) {
            engine_preedit = text;
            if (!active) return;
            int clamped = int.max(0, int.min(char_cursor, text.char_count()));
            int byte_cursor = text.index_of_nth_char(clamped);
            Singularity.ime_preedit(text, byte_cursor, byte_cursor);
            if (engine_candidates != null) popup.show_candidates(engine_candidates, engine_preedit);
        }

        private void on_engine_candidates(Singularity.InputMethods.Candidates? list) {
            engine_candidates = list;
            if (dictating) return;
            if (list == null || !active) {
                popup.hide();
                return;
            }
            popup_items = {};
            popup_accents = false;
            popup.show_candidates(list, engine_preedit);
        }

        private void on_engine_forward(uint keysym, uint keycode, uint state) {
            if (keycode != 0) {
                Singularity.ime_forward_key(keycode, true);
                Singularity.ime_forward_key(keycode, false);
                return;
            }
            unichar c = Singularity.keysym_to_unicode(keysym);
            if (c != 0) Singularity.type_text(c.to_string());
        }

        private void on_engine_delete(int offset, uint count) {
            if (!active) return;
            string before = before_cursor();
            string after = surrounding.substring(cursor);
            int before_chars = before.char_count();
            int start = int.max(0, before_chars + offset);
            int end_chars = before_chars + offset + (int) count;
            uint delete_before = (uint) (before.length - before.index_of_nth_char(int.min(start, before_chars)));
            uint delete_after = 0;
            if (end_chars > before_chars) {
                int extra = int.min(end_chars - before_chars, after.char_count());
                delete_after = (uint) after.index_of_nth_char(extra);
            }
            Singularity.ime_replace(delete_before, delete_after, null);
        }

        private void clear_engine_ui() {
            bool had = engine_candidates != null;
            engine_candidates = null;
            engine_preedit = "";
            if (had && !dictating) popup.hide();
        }

        private uint engine_state(uint modifiers) {
            uint state = 0;
            if ((modifiers & 0x1) != 0) state |= Singularity.InputMethods.STATE_SHIFT;
            if ((modifiers & 0x2) != 0) state |= Singularity.InputMethods.STATE_CONTROL;
            if ((modifiers & 0x4) != 0) state |= Singularity.InputMethods.STATE_ALT;
            if ((modifiers & 0x8) != 0) state |= Singularity.InputMethods.STATE_SUPER;
            return state;
        }

        private async void drain_keys() {
            draining = true;
            while (!key_queue.is_empty()) {
                var item = key_queue.pop_head();
                var engine = Singularity.InputMethods.InputSources.get_default().engine;
                bool handled = false;
                if (engine != null && engine_context()) {
                    uint code = engine.framework == "fcitx5" ? item.key + 8 : item.key;
                    handled = yield engine.process_key(item.keysym, code, item.state, !item.pressed);
                }
                if (item.pressed) {
                    if (!handled) Singularity.ime_forward_key(item.key, true);
                } else if (Singularity.ime_key_forwarded(item.key)) {
                    Singularity.ime_forward_key(item.key, false);
                }
            }
            draining = false;
        }

        private void on_state(bool is_active, string text, uint text_cursor, uint text_purpose, uint text_hint) {
            bool was_active = active;
            if (is_active && !was_active) {
                has_surrounding = false;
                typed_word = "";
            }
            if (is_active && text != "" && !has_surrounding) has_surrounding = true;
            active = is_active;
            surrounding = text;
            cursor = uint.min(text_cursor, (uint) text.length);
            purpose = text_purpose;
            hint = text_hint;
            update_grab();
            if (bound_engine != null) {
                if (active && !was_active) bound_engine.focus_in();
                if (active) bound_engine.set_surrounding(surrounding, surrounding.substring(0, cursor).char_count());
                if (!active && was_active) {
                    bound_engine.reset();
                    bound_engine.focus_out();
                    clear_engine_ui();
                }
            }
            if (!active) {
                cancel_hold();
                close_popup();
                corrected_from = null;
                corrected_to = null;
                current_word = "";
                suggestions_changed("", {});
                return;
            }
            schedule_suggestions();
        }

        private string before_cursor() {
            return surrounding.substring(0, cursor);
        }

        private void track_typed(uint keysym, string text) {
            if (has_surrounding) {
                typed_word = "";
                return;
            }
            unichar c = text.char_count() == 1 ? text.get_char(0) : 0;
            if (keysym == KEY_BACKSPACE) {
                if (typed_word != "") {
                    typed_word = typed_word.substring(0, typed_word.index_of_nth_char(typed_word.char_count() - 1));
                }
            } else if (c != 0 && (c.isalpha() || c == '\'')) {
                typed_word += text;
            } else if (keysym != 0xffe1 && keysym != 0xffe2 && keysym != 0xfe03) {
                typed_word = "";
            }
            schedule_suggestions();
        }

        private string word_before_cursor() {
            if (!has_surrounding) {
                string word = typed_word;
                while (word.has_prefix("'")) word = word.substring(1);
                return word;
            }
            string before = before_cursor();
            int index = before.length;
            int start = index;
            unichar c;
            while (before.get_prev_char(ref index, out c)) {
                if (!c.isalpha() && c != '\'') break;
                start = index;
            }
            string word = before.substring(start);
            while (word.has_prefix("'")) word = word.substring(1);
            if ((int) cursor < surrounding.length && surrounding.get_char(cursor).isalpha()) return "";
            return word;
        }

        private string match_case(string word, string suggestion) {
            if (word.char_count() > 1 && word == word.up()) return suggestion.up();
            unichar first = word.get_char(0);
            if (first.isupper() && suggestion.length > 0) {
                unichar head = suggestion.get_char(0);
                return head.toupper().to_string() + suggestion.substring(head.to_string().length);
            }
            return suggestion;
        }

        private string[] corrections(string word) {
            if (!spell_context() || word.char_count() < 2) return {};
            if (rejected.contains(word.down()) || checker.check(word)) return {};
            string[] result = {};
            foreach (string suggestion in checker.suggest(word, 3)) {
                string candidate = match_case(word, suggestion);
                if (candidate != word && !(candidate in result)) result += candidate;
            }
            return result;
        }

        private void schedule_suggestions() {
            if (suggest_timeout != 0) Source.remove(suggest_timeout);
            suggest_timeout = Timeout.add(250, () => {
                suggest_timeout = 0;
                refresh_suggestions();
                return Source.REMOVE;
            });
        }

        private void refresh_suggestions() {
            if (popup_accents || dictating || engine_candidates != null) return;
            current_word = active ? word_before_cursor() : "";
            string[] items = corrections(current_word);
            suggestions_changed(items.length > 0 ? current_word : "", items);
            bool floating = settings.get_boolean("spell-suggestions")
                && !settings.get_boolean("screen-keyboard-enabled");
            if (floating && items.length > 0) {
                show_popup(items, false, settings.get_boolean("spell-autocorrect") ? 0 : -1);
            } else {
                close_popup();
            }
            update_grab();
        }

        public void apply_suggestion(string suggestion) {
            string word = word_before_cursor();
            if (!active || word == "") return;
            if (has_surrounding) {
                Singularity.ime_replace(word.length, 0, suggestion);
            } else {
                for (int i = 0; i < word.char_count(); i++) {
                    Singularity.ime_forward_key(KEYCODE_BACKSPACE, true);
                    Singularity.ime_forward_key(KEYCODE_BACKSPACE, false);
                }
                Singularity.ime_replace(0, 0, suggestion);
            }
            typed_word = "";
            close_popup();
            suggestions_changed("", {});
        }

        public void keep_word() {
            string word = word_before_cursor();
            if (word != "") rejected.add(word.down());
            close_popup();
            suggestions_changed("", {});
        }

        public bool commit_text(string text) {
            if (!active) return false;
            Singularity.ime_replace(0, 0, text);
            return true;
        }

        public bool replace_previous(string previous, string text) {
            if (!active || !before_cursor().has_suffix(previous)) return false;
            Singularity.ime_replace(previous.length, 0, text);
            return true;
        }

        private bool autocorrect() {
            string word = word_before_cursor();
            string[] items = corrections(word);
            if (items.length == 0) return false;
            Singularity.ime_replace(word.length, 0, items[0] + " ");
            corrected_from = word;
            corrected_to = items[0];
            close_popup();
            return true;
        }

        private bool revert(string from, string to) {
            string applied = to + " ";
            if (!before_cursor().has_suffix(applied)) return false;
            Singularity.ime_replace(applied.length, 0, from);
            rejected.add(from.down());
            return true;
        }

        public bool osk_space() {
            corrected_from = null;
            corrected_to = null;
            if (!settings.get_boolean("spell-autocorrect")) return false;
            return autocorrect();
        }

        public bool osk_backspace() {
            string? from = corrected_from;
            string? to = corrected_to;
            corrected_from = null;
            corrected_to = null;
            return from != null && revert(from, to);
        }

        public void osk_other_key() {
            corrected_from = null;
            corrected_to = null;
        }

        private bool on_key(uint key, uint keysym, string text, bool pressed, uint modifiers) {
            if (capture_escape && keysym == KEY_ESCAPE) {
                if (pressed) escape_pressed();
                return true;
            }
            if (engine_context() || draining) {
                key_queue.push_tail(PendingKey() { key = key, keysym = keysym, pressed = pressed, state = engine_state(modifiers) });
                if (!draining) drain_keys.begin();
                return true;
            }
            if (!pressed) {
                if (key == hold_key) cancel_hold();
                return false;
            }
            if (hold_key != 0 && key != hold_key) cancel_hold();

            bool plain = (modifiers & MOD_BLOCKING) == 0;
            if (plain && keysym == KEY_TAB && !popup_accents && popup_items.length > 0) {
                apply_suggestion(popup_items[popup_selected >= 0 ? popup_selected : 0]);
                return true;
            }
            if (plain) track_typed(keysym, text);
            else typed_word = "";
            if (popup_accents) {
                if (keysym == KEY_ESCAPE) {
                    close_popup();
                    return true;
                }
                if (plain && keysym >= '1' && keysym <= '9') {
                    int index = (int) (keysym - '1');
                    if (index < popup_items.length) choose_accent(index);
                    return true;
                }
                if (keysym == KEY_LEFT || keysym == KEY_RIGHT) {
                    int step = keysym == KEY_LEFT ? -1 : 1;
                    popup_selected = (popup_selected + step + popup_items.length) % popup_items.length;
                    render_popup();
                    return true;
                }
                if (keysym == KEY_RETURN || keysym == KEY_KP_ENTER) {
                    choose_accent(popup_selected);
                    return true;
                }
                close_popup();
            }

            string? from = corrected_from;
            string? to = corrected_to;
            corrected_from = null;
            corrected_to = null;

            if (plain && keysym == KEY_BACKSPACE && from != null && revert(from, to)) return true;
            if (plain && keysym == KEY_SPACE && settings.get_boolean("spell-autocorrect") && autocorrect()) {
                return true;
            }
            if (keysym == KEY_ESCAPE && popup_items.length > 0) {
                keep_word();
                return true;
            }
            if (plain && settings.get_boolean("press-hold-accents") && accent_context()
                    && text.char_count() == 1 && AccentTable.variants(text.get_char()).length > 0) {
                Singularity.ime_forward_key(key, true);
                Singularity.ime_forward_key(key, false);
                hold_key = key;
                hold_text = text;
                hold_timeout = Timeout.add(450, () => {
                    hold_timeout = 0;
                    show_popup(AccentTable.variants(hold_text.get_char()), true, 0);
                    return Source.REMOVE;
                });
                return true;
            }
            return false;
        }

        private void cancel_hold() {
            if (hold_timeout != 0) Source.remove(hold_timeout);
            hold_timeout = 0;
            hold_key = 0;
        }

        private void choose_accent(int index) {
            if (index < 0 || index >= popup_items.length) return;
            string choice = popup_items[index];
            close_popup();
            replace_previous(hold_text, choice);
        }

        private void on_pointer(double x, double y) {
            int action = popup.hit(x, y);
            if (action == Singularity.InputMethods.ImePopup.HIT_NONE) return;
            if (action == Singularity.InputMethods.ImePopup.HIT_DICTATION) {
                dictation_clicked();
                return;
            }
            if (engine_candidates != null && bound_engine != null) {
                if (action == Singularity.InputMethods.ImePopup.HIT_PREVIOUS) bound_engine.change_page(false);
                else if (action == Singularity.InputMethods.ImePopup.HIT_NEXT) bound_engine.change_page(true);
                else if (action >= 0) bound_engine.select_candidate(action);
                return;
            }
            if (action < 0 || action >= popup_items.length) return;
            if (popup_accents) choose_accent(action);
            else apply_suggestion(popup_items[action]);
        }

        private void show_popup(string[] items, bool accents, int selected) {
            if (dictating) return;
            popup_items = items;
            popup_accents = accents;
            popup_selected = selected;
            render_popup();
        }

        private void close_popup() {
            bool shown = popup_items.length > 0;
            popup_items = {};
            popup_accents = false;
            popup_selected = -1;
            if (shown && !dictating && engine_candidates == null) popup.hide();
        }

        private void render_popup() {
            if (popup_items.length == 0) return;
            popup.show_chips(popup_items, popup_accents, popup_selected);
        }
    }
}
