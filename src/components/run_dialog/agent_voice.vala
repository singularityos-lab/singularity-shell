namespace Singularity {

    public enum AgentVoiceMode {
        MESSAGE,
        CALL
    }

    public class AgentVoice : Object {
        private const uint TURN_PAUSE_MS = 1300;
        private const uint NO_SPEECH_MS = 10000;
        private const string CLIENT_ID = "sinty-ai-voice";

        public signal void heard(string text);
        public signal void failed(string message);
        public signal void ended();

        public AgentVoiceMode mode { get; private set; default = AgentVoiceMode.MESSAGE; }
        public bool active { get; private set; default = false; }
        public bool listening { get; private set; default = false; }
        public bool speaking { get; private set; default = false; }
        public string preview { get; private set; default = ""; }

        private GLib.Settings settings;
        private Dictation.DictationEngine? engine = null;
        private Dictation.AudioCapture? capture = null;
        private Dictation.SilenceDetector detector;
        private string language = "auto";
        private string collected = "";
        private uint elapsed_ms = 0;
        private uint finish_timeout = 0;

        public AgentVoice() {
            settings = new GLib.Settings("dev.sinty.desktop");
        }

        public void start(AgentVoiceMode mode) {
            if (active) return;
            this.mode = mode;
            active = true;
            listen();
        }

        public void finish_turn() {
            if (!listening || engine == null) return;
            listening = false;
            stop_capture();
            engine.finish();
            finish_timeout = Timeout.add_seconds(30, () => {
                finish_timeout = 0;
                fail(_("The speech engine did not answer"));
                return Source.REMOVE;
            });
        }

        public void end() {
            if (!active) return;
            drop_engine();
            if (speaking) Speech.get_default().stop();
            speaking = false;
            active = false;
            ended();
        }

        public async void reply(string answer) {
            if (!active || mode != AgentVoiceMode.CALL) return;
            string text = plain(answer);
            if (text != "") {
                speaking = true;
                try {
                    yield Speech.get_default().say(text);
                } catch (Error e) {
                    debug("Sinty AI voice: %s", e.message);
                }
                speaking = false;
            }
            if (active) listen();
        }

        private static string plain(string answer) {
            string markup = AnswerMarkup.to_pango(answer);
            string text;
            try {
                Pango.parse_markup(markup, -1, 0, null, out text, null);
            } catch (Error e) {
                text = answer;
            }
            return text.strip();
        }

        private void listen() {
            drop_engine();
            string reason;
            var created = Dictation.EngineLocator.create(settings, out reason);
            if (created == null) {
                fail(reason);
                return;
            }
            language = settings.get_string("dictation-language");
            if (language == "") language = "auto";
            try {
                created.start(language);
            } catch (Error e) {
                fail(_("The speech engine could not start"));
                return;
            }
            engine = created;
            created.partial.connect(on_partial);
            created.segment_ready.connect(on_segment);
            created.finished.connect(on_finished);
            created.failed.connect(fail);

            capture = new Dictation.AudioCapture(Environment.get_variable("SINGULARITY_DICTATION_AUDIO"));
            capture.chunk.connect(on_chunk);
            capture.failed.connect(fail);
            try {
                capture.start();
            } catch (Error e) {
                capture = null;
                fail(e.message);
                return;
            }
            MicrophoneClients.get_default().acquire(CLIENT_ID, _("Sinty AI"));
            detector = new Dictation.SilenceDetector();
            collected = "";
            preview = "";
            elapsed_ms = 0;
            listening = true;
        }

        private void on_chunk(uint8[] pcm) {
            if (!listening || engine == null) return;
            engine.feed(pcm);
            detector.feed(pcm);
            elapsed_ms += (uint) (pcm.length * 1000 / (Dictation.SAMPLE_RATE * 2));
            if (detector.heard_speech && detector.silence_ms >= TURN_PAUSE_MS) {
                finish_turn();
            } else if (!detector.heard_speech && elapsed_ms >= NO_SPEECH_MS) {
                if (mode == AgentVoiceMode.CALL) {
                    listen();
                } else {
                    fail(_("No speech was heard"));
                }
            }
        }

        private string format(string text) {
            return Dictation.DictationText.format(text, Dictation.DictationService.command_language(language),
                settings.get_boolean("dictation-auto-punctuation"), collected);
        }

        private void on_partial(string text) {
            preview = (collected + format(text)).strip();
        }

        private void on_segment(string text) {
            collected += format(text);
            preview = collected.strip();
        }

        private void on_finished() {
            if (finish_timeout != 0) {
                Source.remove(finish_timeout);
                finish_timeout = 0;
            }
            string text = collected.strip();
            if (text == "") text = preview.strip();
            drop_engine();
            if (text != "" && mode == AgentVoiceMode.MESSAGE) {
                active = false;
                ended();
                heard(text);
            } else if (text != "") {
                heard(text);
            } else if (mode == AgentVoiceMode.CALL) {
                listen();
            } else {
                fail(_("No speech was heard"));
            }
        }

        private void stop_capture() {
            if (capture != null) {
                capture.chunk.disconnect(on_chunk);
                capture.stop();
                capture = null;
            }
            MicrophoneClients.get_default().release(CLIENT_ID);
        }

        private void drop_engine() {
            listening = false;
            stop_capture();
            if (finish_timeout != 0) {
                Source.remove(finish_timeout);
                finish_timeout = 0;
            }
            if (engine != null) {
                engine.partial.disconnect(on_partial);
                engine.segment_ready.disconnect(on_segment);
                engine.finished.disconnect(on_finished);
                engine.failed.disconnect(fail);
                engine.cancel();
                engine = null;
            }
        }

        private void fail(string message) {
            if (!active) return;
            drop_engine();
            speaking = false;
            active = false;
            failed(message);
            ended();
        }
    }
}
