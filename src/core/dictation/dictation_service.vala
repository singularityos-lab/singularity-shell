namespace Singularity.Dictation {

    public enum DictationState {
        IDLE,
        LISTENING,
        FINISHING
    }

    public class DictationService : Object {
        private const int BARS = 5;
        private const uint PAUSE_MS = 900;
        private const uint NO_SPEECH_MS = 8000;
        private const uint FRAME_MS = 33;
        private const uint PULSE_MS = 1200;

        private static DictationService? instance = null;

        public signal void delivered(string text, bool through_input_method);

        public DictationState state { get; private set; default = DictationState.IDLE; }
        public string preview { get; private set; default = ""; }
        public double level { get; private set; default = 0; }
        public string engine_id { get; private set; default = ""; }

        public bool busy {
            get { return state != DictationState.IDLE; }
        }

        private GLib.Settings settings;
        private DictationEngine? engine = null;
        private AudioCapture? capture = null;
        private SilenceDetector detector;
        private double[] levels = new double[BARS];
        private bool pause_sent = false;
        private uint elapsed_ms = 0;
        private uint frame_timer = 0;
        private uint finish_timeout = 0;
        private int64 started_us = 0;
        private string language = "auto";
        private string session_text = "";

        public static DictationService get_default() {
            if (instance == null) instance = new DictationService();
            return instance;
        }

        private DictationService() {
            settings = new GLib.Settings("dev.sinty.desktop");
            var ime = InputMethodService.get_default();
            ime.escape_pressed.connect(() => {
                if (busy) cancel();
            });
            ime.dictation_clicked.connect(() => {
                if (state == DictationState.LISTENING) stop();
            });
        }

        public void toggle() {
            if (state == DictationState.IDLE) start();
            else if (state == DictationState.LISTENING) stop();
            else cancel();
        }

        public static string command_language(string setting) {
            if (setting != "" && setting != "auto") return setting;
            foreach (string name in Intl.get_language_names()) {
                if (name.has_prefix("it")) return "it";
                if (name.has_prefix("en")) return "en";
            }
            return "auto";
        }

        public void start() {
            if (busy) return;
            if (!settings.get_boolean("dictation-enabled")) {
                notify_problem(_("Dictation is turned off in Settings"));
                return;
            }
            string reason;
            var created = EngineLocator.create(settings, out reason);
            if (created == null) {
                notify_problem(reason);
                return;
            }
            language = settings.get_string("dictation-language");
            try {
                created.start(language == "" ? "auto" : language);
            } catch (Error e) {
                notify_problem(_("The speech engine could not start"));
                return;
            }
            engine = created;
            engine_id = created.id;
            created.partial.connect(on_partial);
            created.segment_ready.connect(on_segment);
            created.finished.connect(on_finished);
            created.failed.connect((message) => {
                notify_problem(message);
                cancel();
            });

            capture = new AudioCapture(Environment.get_variable("SINGULARITY_DICTATION_AUDIO"));
            capture.chunk.connect(on_chunk);
            capture.failed.connect((message) => {
                notify_problem(message);
                cancel();
            });
            try {
                capture.start();
            } catch (Error e) {
                engine.cancel();
                engine = null;
                notify_problem(e.message);
                return;
            }
            MicrophoneClients.get_default().acquire("dictation", _("Dictation"));
            detector = new SilenceDetector();
            levels = new double[BARS];
            pause_sent = false;
            elapsed_ms = 0;
            preview = "";
            session_text = "";
            started_us = get_monotonic_time();
            state = DictationState.LISTENING;
            var ime = InputMethodService.get_default();
            ime.dictating = true;
            ime.capture_escape = true;
            frame_timer = Timeout.add(FRAME_MS, () => {
                render();
                return Source.CONTINUE;
            });
            render();
        }

        public void stop() {
            if (state != DictationState.LISTENING) return;
            state = DictationState.FINISHING;
            stop_capture();
            engine.finish();
            finish_timeout = Timeout.add_seconds(30, () => {
                finish_timeout = 0;
                cancel();
                return Source.REMOVE;
            });
            render();
        }

        public void cancel() {
            if (state == DictationState.IDLE) return;
            stop_capture();
            if (engine != null) engine.cancel();
            var ime = InputMethodService.get_default();
            if (preview != "" && ime.active) ime.set_preedit("");
            cleanup();
        }

        private void stop_capture() {
            if (capture != null) {
                capture.stop();
                capture = null;
            }
            MicrophoneClients.get_default().release("dictation");
        }

        private void cleanup() {
            if (frame_timer != 0) {
                Source.remove(frame_timer);
                frame_timer = 0;
            }
            if (finish_timeout != 0) {
                Source.remove(finish_timeout);
                finish_timeout = 0;
            }
            engine = null;
            preview = "";
            level = 0;
            state = DictationState.IDLE;
            var ime = InputMethodService.get_default();
            ime.capture_escape = false;
            ime.dictating = false;
        }

        private void on_chunk(uint8[] pcm) {
            if (state != DictationState.LISTENING || engine == null) return;
            engine.feed(pcm);
            double value = detector.feed(pcm);
            level = value;
            for (int i = 0; i < BARS - 1; i++) levels[i] = levels[i + 1];
            levels[BARS - 1] = value;
            elapsed_ms += (uint) (pcm.length * 1000 / (SAMPLE_RATE * 2));
            if (detector.heard_speech && detector.silence_ms >= PAUSE_MS && !pause_sent) {
                pause_sent = true;
                engine.pause_detected();
            }
            if (detector.silence_ms < PAUSE_MS) pause_sent = false;
            if (!settings.get_boolean("dictation-auto-stop")) return;
            uint limit = settings.get_uint("dictation-silence-seconds") * 1000;
            if (detector.heard_speech && detector.silence_ms >= uint.max(limit, PAUSE_MS + 300)) {
                stop();
            } else if (!detector.heard_speech && elapsed_ms >= uint.max(limit, NO_SPEECH_MS)) {
                stop();
            }
        }

        private string context() {
            var ime = InputMethodService.get_default();
            string before = ime.active ? ime.text_before_cursor() : "";
            if (session_text == "" || before.has_suffix(session_text)) return before;
            return session_text;
        }

        private void on_partial(string text) {
            if (state == DictationState.IDLE) return;
            string formatted = DictationText.format(text, command_language(language),
                settings.get_boolean("dictation-auto-punctuation"), context());
            preview = formatted;
            var ime = InputMethodService.get_default();
            if (ime.active) ime.set_preedit(formatted);
        }

        private void on_segment(string text) {
            if (state == DictationState.IDLE) return;
            string formatted = DictationText.format(text, command_language(language),
                settings.get_boolean("dictation-auto-punctuation"), context());
            preview = "";
            if (formatted == "") return;
            var ime = InputMethodService.get_default();
            session_text += formatted;
            if (ime.active) {
                ime.commit_text(formatted);
                delivered(formatted, true);
            } else {
                Singularity.type_text(formatted);
                delivered(formatted, false);
            }
        }

        private void on_finished() {
            if (state == DictationState.IDLE) return;
            var ime = InputMethodService.get_default();
            if (preview != "" && ime.active) ime.set_preedit("");
            cleanup();
        }

        private void render() {
            var ime = InputMethodService.get_default();
            if (state == DictationState.IDLE || !ime.active) {
                if (state == DictationState.IDLE) ime.popup.hide();
                return;
            }
            double phase = 0;
            if (!Singularity.Motion.reduced()) {
                uint period = Singularity.Motion.get_default().scale(PULSE_MS);
                if (period > 0) phase = (double) (((get_monotonic_time() - started_us) / 1000) % period) / period;
            }
            string text = preview != "" ? preview.strip() : (state == DictationState.FINISHING ? _("Finishing") : _("Listening"));
            ime.popup.show_dictation(levels, phase, text, preview == "");
        }

        private void notify_problem(string message) {
            Singularity.Shell.OsdOverlay.get_default().show_osd("microphone-disabled-symbolic", -1, message);
        }
    }
}
