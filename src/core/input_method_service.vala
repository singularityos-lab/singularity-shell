namespace Singularity {

    public class InputMethodService : Object {
        private const uint KEY_SPACE = 0x0020;
        private const uint KEY_BACKSPACE = 0xff08;
        private const uint KEY_ESCAPE = 0xff1b;
        private const uint KEY_RETURN = 0xff0d;
        private const uint KEY_KP_ENTER = 0xff8d;
        private const uint KEY_LEFT = 0xff51;
        private const uint KEY_RIGHT = 0xff53;
        private const uint MOD_BLOCKING = 0x2 | 0x4 | 0x8;
        private const uint HINT_PRIVATE = 0x40 | 0x80;
        private const int ACCENTS_PER_ROW = 10;

        private static InputMethodService? instance = null;

        public signal void suggestions_changed(string word, string[] suggestions);

        public bool active { get; private set; default = false; }

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
        private double[] chip_x = {};
        private double[] chip_y = {};
        private double[] chip_w = {};
        private double[] chip_h = {};

        public static InputMethodService get_default() {
            if (instance == null) instance = new InputMethodService();
            return instance;
        }

        private InputMethodService() {
            settings = new GLib.Settings("dev.sinty.desktop");
            checker = Singularity.Text.SpellChecker.get_default();
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
                || settings.get_boolean("press-hold-accents");
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
            Singularity.ime_start(on_key, on_state, on_pointer);
        }

        private bool spell_context() {
            return active && (purpose == 0 || purpose == 1) && (hint & HINT_PRIVATE) == 0
                && checker.enabled && checker.available;
        }

        public bool accent_context() {
            return active && (purpose <= 1 || purpose == 5 || purpose == 6 || purpose == 7)
                && (hint & HINT_PRIVATE) == 0;
        }

        private void update_grab() {
            bool grab = (settings.get_boolean("spell-autocorrect") && spell_context())
                || (settings.get_boolean("press-hold-accents") && accent_context());
            Singularity.ime_set_grab(grab);
        }

        private void on_state(bool is_active, string text, uint text_cursor, uint text_purpose, uint text_hint) {
            active = is_active;
            surrounding = text;
            cursor = uint.min(text_cursor, (uint) text.length);
            purpose = text_purpose;
            hint = text_hint;
            update_grab();
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

        private string word_before_cursor() {
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
            if (popup_accents) return;
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
        }

        public void apply_suggestion(string suggestion) {
            string word = word_before_cursor();
            if (!active || word == "") return;
            Singularity.ime_replace(word.length, 0, suggestion);
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
            if (!pressed) {
                if (key == hold_key) cancel_hold();
                return false;
            }
            if (hold_key != 0 && key != hold_key) cancel_hold();

            bool plain = (modifiers & MOD_BLOCKING) == 0;
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
            for (int i = 0; i < chip_x.length; i++) {
                if (x >= chip_x[i] && x < chip_x[i] + chip_w[i] && y >= chip_y[i] && y < chip_y[i] + chip_h[i]) {
                    if (popup_accents) choose_accent(i);
                    else apply_suggestion(popup_items[i]);
                    return;
                }
            }
        }

        private void show_popup(string[] items, bool accents, int selected) {
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
            chip_x = {};
            chip_y = {};
            chip_w = {};
            chip_h = {};
            if (shown) Singularity.ime_popup_hide();
        }

        private int output_scale() {
            int scale = 1;
            var monitors = Gdk.Display.get_default().get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = (Gdk.Monitor) monitors.get_item(i);
                scale = int.max(scale, (int) Math.ceil(monitor.scale));
            }
            return scale;
        }

        private void render_popup() {
            if (popup_items.length == 0) return;
            const double PAD = 6;
            const double GAP = 4;
            double chip_pad_x = popup_accents ? 8 : 12;
            double chip_height = popup_accents ? 40 : 30;

            var measure = new Cairo.ImageSurface(Cairo.Format.ARGB32, 1, 1);
            var measure_cr = new Cairo.Context(measure);
            var layout = Pango.cairo_create_layout(measure_cr);
            var font = Pango.FontDescription.from_string(popup_accents ? "Sans 15" : "Sans 11");
            layout.set_font_description(font);

            chip_x = {};
            chip_y = {};
            chip_w = {};
            chip_h = {};
            double x = PAD;
            double y = PAD;
            double width = 0;
            for (int i = 0; i < popup_items.length; i++) {
                if (popup_accents && i > 0 && i % ACCENTS_PER_ROW == 0) {
                    x = PAD;
                    y += chip_height + GAP;
                }
                layout.set_text(popup_items[i], -1);
                int text_w, text_h;
                layout.get_pixel_size(out text_w, out text_h);
                double w = double.max(text_w + chip_pad_x * 2, popup_accents ? 34 : 0);
                chip_x += x;
                chip_y += y;
                chip_w += w;
                chip_h += chip_height;
                x += w + GAP;
                width = double.max(width, x - GAP + PAD);
            }
            double height = y + chip_height + PAD;

            int scale = output_scale();
            int pixel_w = (int) Math.ceil(width) * scale;
            int pixel_h = (int) Math.ceil(height) * scale;
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, pixel_w, pixel_h);
            var cr = new Cairo.Context(surface);
            cr.scale(scale, scale);

            rounded(cr, 0.5, 0.5, Math.ceil(width) - 1, Math.ceil(height) - 1, 12);
            cr.set_source_rgba(0.13, 0.13, 0.14, 0.97);
            cr.fill_preserve();
            cr.set_source_rgba(1, 1, 1, 0.12);
            cr.set_line_width(1);
            cr.stroke();

            var accent = Gdk.RGBA();
            accent.parse(Singularity.Style.StyleManager.get_default().accent_hex);
            var draw_layout = Pango.cairo_create_layout(cr);
            draw_layout.set_font_description(font);
            var number_layout = Pango.cairo_create_layout(cr);
            number_layout.set_font_description(Pango.FontDescription.from_string("Sans 7"));

            for (int i = 0; i < popup_items.length; i++) {
                if (i == popup_selected) {
                    rounded(cr, chip_x[i], chip_y[i], chip_w[i], chip_h[i], 8);
                    cr.set_source_rgba(accent.red, accent.green, accent.blue, 0.9);
                    cr.fill();
                }
                draw_layout.set_text(popup_items[i], -1);
                int text_w, text_h;
                draw_layout.get_pixel_size(out text_w, out text_h);
                double text_y = chip_y[i] + (chip_h[i] - text_h) / 2 - (popup_accents ? 4 : 0);
                cr.move_to(chip_x[i] + (chip_w[i] - text_w) / 2, text_y);
                cr.set_source_rgba(1, 1, 1, 0.95);
                Pango.cairo_show_layout(cr, draw_layout);
                if (popup_accents && i < 9) {
                    number_layout.set_text((i + 1).to_string(), -1);
                    int num_w, num_h;
                    number_layout.get_pixel_size(out num_w, out num_h);
                    cr.move_to(chip_x[i] + (chip_w[i] - num_w) / 2, chip_y[i] + chip_h[i] - num_h - 2);
                    cr.set_source_rgba(1, 1, 1, 0.55);
                    Pango.cairo_show_layout(cr, number_layout);
                }
            }
            surface.flush();
            unowned uchar[] data = surface.get_data();
            Singularity.ime_popup_show((uint8[]) data, pixel_w, pixel_h, surface.get_stride(), scale);
        }

        private static void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }
    }
}
