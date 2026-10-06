using Gtk;

namespace Singularity {

    public class MicrophoneIndicator : Gtk.Button {
        private static bool _styled = false;
        private ulong _changed_id = 0;

        public MicrophoneIndicator() {
            Object();
            ensure_style();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("microphone-indicator");
            var icon = new Image.from_icon_name("audio-input-microphone-symbolic");
            icon.pixel_size = 16;
            set_child(icon);
            clicked.connect(() => {
                var dictation = Singularity.Dictation.DictationService.get_default();
                if (dictation.busy) dictation.stop();
            });
            var usage = MicrophoneClients.get_default();
            _changed_id = usage.changed.connect(() => sync(usage));
            sync(usage);
        }

        public override void dispose() {
            if (_changed_id != 0) {
                MicrophoneClients.get_default().disconnect(_changed_id);
                _changed_id = 0;
            }
            base.dispose();
        }

        private void sync(MicrophoneClients usage) {
            visible = usage.in_use;
            string names = string.joinv(", ", usage.labels());
            tooltip_text = _("Microphone in use by %s").printf(names);
            update_property(Gtk.AccessibleProperty.LABEL, tooltip_text, -1);
        }

        private static void ensure_style() {
            if (_styled) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            _styled = true;
            var provider = new Gtk.CssProvider();
            provider.load_from_data(CSS.data);
            Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_USER);
        }

        private const string CSS = """
.system-pill-button.microphone-indicator {
    background-color: alpha(@warning_color, 0.9);
}
.system-pill-button.microphone-indicator image {
    color: #1c1c1c;
}
.input-indicator .input-source {
    font-weight: 600;
    font-feature-settings: "tnum";
}
""";
    }

    public class InputIndicator : Gtk.Button {
        private const int BARS = 4;

        private Label _source_label;
        private Image _spell_icon;
        private DrawingArea _levels;
        private Label _preview_label;
        private uint _frame_timer = 0;
        private GLib.Settings _settings;
        private ulong[] _handlers = {};
        private Object[] _handler_owners = {};

        public InputIndicator() {
            Object();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("input-indicator");
            _settings = new GLib.Settings("dev.sinty.desktop");

            var box = new Box(Orientation.HORIZONTAL, 6);
            _levels = new DrawingArea();
            _levels.content_width = BARS * 5;
            _levels.content_height = 16;
            _levels.valign = Align.CENTER;
            _levels.set_draw_func(draw_levels);
            box.append(_levels);
            _preview_label = new Label("");
            _preview_label.ellipsize = Pango.EllipsizeMode.START;
            _preview_label.max_width_chars = 24;
            _preview_label.width_chars = 1;
            box.append(_preview_label);
            _spell_icon = new Image.from_icon_name("tools-check-spelling-symbolic");
            _spell_icon.pixel_size = 16;
            box.append(_spell_icon);
            _source_label = new Label("");
            _source_label.add_css_class("input-source");
            box.append(_source_label);
            set_child(box);

            clicked.connect(on_clicked);

            var sources = Singularity.InputMethods.InputSources.get_default();
            var dictation = Singularity.Dictation.DictationService.get_default();
            var ime = InputMethodService.get_default();
            track(sources, sources.changed.connect(sync));
            track(dictation, dictation.notify["state"].connect(sync));
            track(dictation, dictation.notify["preview"].connect(sync));
            track(ime, ime.notify["active"].connect(sync));
            track(ime, ime.notify["has-surrounding"].connect(sync));
            track(_settings, _settings.changed["spell-check-all-apps"].connect(sync));
            track(_settings, _settings.changed["input-method-show-indicator"].connect(sync));
            sync();
        }

        private void track(Object owner, ulong id) {
            _handler_owners += owner;
            _handlers += id;
        }

        public override void dispose() {
            for (int i = 0; i < _handlers.length; i++) {
                if (_handlers[i] != 0) _handler_owners[i].disconnect(_handlers[i]);
            }
            _handlers = {};
            _handler_owners = {};
            stop_frames();
            base.dispose();
        }

        private void on_clicked() {
            var dictation = Singularity.Dictation.DictationService.get_default();
            if (dictation.busy) {
                dictation.stop();
                return;
            }
            var sources = Singularity.InputMethods.InputSources.get_default();
            if (sources.configured().length > 0) sources.cycle();
        }

        private void sync() {
            var sources = Singularity.InputMethods.InputSources.get_default();
            var dictation = Singularity.Dictation.DictationService.get_default();
            var ime = InputMethodService.get_default();
            bool listening = dictation.busy;
            bool has_engines = sources.configured().length > 0 && _settings.get_boolean("input-method-show-indicator")
                && sources.installed_frameworks().length > 0;
            bool spelling = ime.active && _settings.get_boolean("spell-check-all-apps") && !ime.own_client()
                && !ime.engine_context();

            _levels.visible = listening;
            _preview_label.visible = listening;
            _preview_label.label = dictation.preview != "" ? dictation.preview.strip() : _("Listening");
            _source_label.visible = has_engines && !listening;
            _source_label.label = sources.label_for(sources.current);
            _spell_icon.visible = spelling && !listening;
            visible = listening || has_engines || spelling;

            if (listening) {
                tooltip_text = _("Dictation is listening, click to stop");
                start_frames();
            } else {
                stop_frames();
                var parts = new string[0];
                if (has_engines) parts += _("Input: %s").printf(sources.name_for(sources.current));
                if (spelling) parts += _("Checking spelling in this app");
                tooltip_text = string.joinv("\n", parts);
            }
            update_property(Gtk.AccessibleProperty.LABEL, tooltip_text, -1);
        }

        private void draw_levels(DrawingArea area, Cairo.Context cr, int width, int height) {
            var accent = Gdk.RGBA();
            accent.parse(Singularity.Style.StyleManager.get_default().accent_hex);
            double level = Singularity.Dictation.DictationService.get_default().level;
            bool reduced = Singularity.Motion.reduced();
            for (int i = 0; i < BARS; i++) {
                double wobble = reduced ? 0.5 : 0.35 + 0.65 * Math.fabs(Math.sin(get_monotonic_time() / 180000.0 + i * 1.3));
                double h = 4 + (height - 4) * double.min(1.0, level * 3) * wobble;
                double x = i * 5;
                double y = (height - h) / 2;
                cr.new_sub_path();
                cr.arc(x + 1.5, y + 1.5, 1.5, Math.PI, 3 * Math.PI / 2);
                cr.arc(x + 1.5, y + 1.5, 1.5, 3 * Math.PI / 2, 2 * Math.PI);
                cr.arc(x + 1.5, y + h - 1.5, 1.5, 0, Math.PI / 2);
                cr.arc(x + 1.5, y + h - 1.5, 1.5, Math.PI / 2, Math.PI);
                cr.close_path();
                cr.set_source_rgba(accent.red, accent.green, accent.blue, 1);
                cr.fill();
            }
        }

        private void start_frames() {
            if (_frame_timer != 0) return;
            _frame_timer = Timeout.add(Singularity.Motion.Duration.MICRO.ms(), () => {
                _levels.queue_draw();
                return Source.CONTINUE;
            });
        }

        private void stop_frames() {
            if (_frame_timer == 0) return;
            Source.remove(_frame_timer);
            _frame_timer = 0;
        }
    }
}
