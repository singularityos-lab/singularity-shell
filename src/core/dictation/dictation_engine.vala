namespace Singularity.Dictation {

    public const int SAMPLE_RATE = 16000;

    public class Wav : Object {
        public static uint8[] encode(uint8[] pcm, int rate = SAMPLE_RATE) {
            var out_data = new ByteArray.sized(pcm.length + 44);
            out_data.append("RIFF".data);
            append_u32(out_data, 36 + pcm.length);
            out_data.append("WAVEfmt ".data);
            append_u32(out_data, 16);
            append_u16(out_data, 1);
            append_u16(out_data, 1);
            append_u32(out_data, rate);
            append_u32(out_data, rate * 2);
            append_u16(out_data, 2);
            append_u16(out_data, 16);
            out_data.append("data".data);
            append_u32(out_data, pcm.length);
            out_data.append(pcm);
            return out_data.steal();
        }

        public static uint8[]? decode(uint8[] data, out int rate, out int channels) {
            rate = 0;
            channels = 0;
            if (data.length < 12 || Memory.cmp(data, "RIFF".data, 4) != 0) return null;
            if (Memory.cmp(&data[8], "WAVE".data, 4) != 0) return null;
            int bits = 0;
            int format = 0;
            size_t pos = 12;
            while (pos + 8 <= data.length) {
                uint32 size = read_u32(data, pos + 4);
                size_t body = pos + 8;
                if (Memory.cmp(&data[pos], "fmt ".data, 4) == 0 && body + 16 <= data.length) {
                    format = read_u16(data, body);
                    channels = read_u16(data, body + 2);
                    rate = (int) read_u32(data, body + 4);
                    bits = read_u16(data, body + 14);
                } else if (Memory.cmp(&data[pos], "data".data, 4) == 0) {
                    if (format != 1 || bits != 16 || channels < 1) return null;
                    size_t end = size_t.min(body + size, data.length);
                    return data[body:end];
                }
                pos = body + size + (size % 2);
            }
            return null;
        }

        public static uint8[] to_mono(uint8[] pcm, int channels) {
            if (channels <= 1) return pcm;
            int frames = pcm.length / (2 * channels);
            var mono = new uint8[frames * 2];
            for (int f = 0; f < frames; f++) {
                int sum = 0;
                for (int c = 0; c < channels; c++) {
                    int offset = (f * channels + c) * 2;
                    sum += (int16) (pcm[offset] | (pcm[offset + 1] << 8));
                }
                int16 value = (int16) (sum / channels);
                mono[f * 2] = (uint8) (value & 0xff);
                mono[f * 2 + 1] = (uint8) ((value >> 8) & 0xff);
            }
            return mono;
        }

        public static uint8[] resample(uint8[] pcm, int from_rate, int to_rate = SAMPLE_RATE) {
            if (from_rate == to_rate || from_rate <= 0) return pcm;
            int frames = pcm.length / 2;
            int out_frames = (int) ((int64) frames * to_rate / from_rate);
            var result = new uint8[out_frames * 2];
            for (int i = 0; i < out_frames; i++) {
                double src = (double) i * from_rate / to_rate;
                int a = int.min((int) src, frames - 1);
                int b = int.min(a + 1, frames - 1);
                double t = src - a;
                int16 va = (int16) (pcm[a * 2] | (pcm[a * 2 + 1] << 8));
                int16 vb = (int16) (pcm[b * 2] | (pcm[b * 2 + 1] << 8));
                int16 v = (int16) (va + (vb - va) * t);
                result[i * 2] = (uint8) (v & 0xff);
                result[i * 2 + 1] = (uint8) ((v >> 8) & 0xff);
            }
            return result;
        }

        private static void append_u32(ByteArray array, uint32 value) {
            uint8[] bytes = { (uint8) value, (uint8) (value >> 8), (uint8) (value >> 16), (uint8) (value >> 24) };
            array.append(bytes);
        }

        private static void append_u16(ByteArray array, uint16 value) {
            uint8[] bytes = { (uint8) value, (uint8) (value >> 8) };
            array.append(bytes);
        }

        private static uint32 read_u32(uint8[] data, size_t pos) {
            return data[pos] | (data[pos + 1] << 8) | (data[pos + 2] << 16) | ((uint32) data[pos + 3] << 24);
        }

        private static int read_u16(uint8[] data, size_t pos) {
            return data[pos] | (data[pos + 1] << 8);
        }
    }

    public class SilenceDetector : Object {
        public uint silence_ms { get; private set; default = 0; }
        public uint speech_ms { get; private set; default = 0; }
        public bool heard_speech { get; private set; default = false; }
        public double level { get; private set; default = 0; }
        public double threshold { get; set; default = 500; }

        private double floor = -1;

        public double feed(uint8[] pcm) {
            int frames = pcm.length / 2;
            if (frames == 0) return level;
            double sum = 0;
            for (int i = 0; i < frames; i++) {
                int16 v = (int16) (pcm[i * 2] | (pcm[i * 2 + 1] << 8));
                sum += (double) v * v;
            }
            double rms = Math.sqrt(sum / frames);
            if (floor < 0 || rms < floor) floor = rms;
            else floor = floor * 0.995 + rms * 0.005;
            double limit = double.max(threshold, floor * 3);
            uint ms = (uint) (frames * 1000 / SAMPLE_RATE);
            if (rms >= limit) {
                speech_ms += ms;
                silence_ms = 0;
                if (speech_ms >= 120) heard_speech = true;
            } else {
                silence_ms += ms;
                if (silence_ms > 300) speech_ms = 0;
            }
            level = double.min(1.0, rms / 6000.0);
            return level;
        }

        public void reset_pause() {
            silence_ms = 0;
        }
    }

    public class EngineOutput : Object {
        public static string clean_whisper(string output) {
            var text = new StringBuilder();
            foreach (string raw in output.split("\n")) {
                string line = raw.strip();
                if (line.has_prefix("[") && line.contains("-->")) {
                    int close = line.index_of("]");
                    line = close >= 0 ? line.substring(close + 1).strip() : "";
                }
                line = drop_markers(line, '[', ']');
                line = drop_markers(line, '(', ')');
                line = drop_markers(line, '*', '*');
                line = line.strip();
                if (line == "" || line == "-") continue;
                if (text.len > 0) text.append_c(' ');
                text.append(line);
            }
            return text.str.strip();
        }

        private static string drop_markers(string line, char open, char close) {
            var result = new StringBuilder();
            int i = 0;
            while (i < line.length) {
                if (line[i] == open) {
                    int end = line.index_of_char(close, i + 1);
                    if (end > i) {
                        i = end + 1;
                        continue;
                    }
                }
                result.append_c(line[i]);
                i++;
            }
            return result.str;
        }

        public static string? parse_stream_line(string line, out bool is_final) {
            is_final = false;
            string trimmed = line.strip();
            if (trimmed == "") return null;
            var parser = new Json.Parser();
            try {
                parser.load_from_data(trimmed);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
            var obj = root.get_object();
            if (obj.has_member("text")) {
                is_final = true;
                return obj.get_string_member("text").strip();
            }
            if (obj.has_member("partial")) return obj.get_string_member("partial").strip();
            return null;
        }
    }

    public abstract class DictationEngine : Object {
        public signal void partial(string text);
        public signal void segment_ready(string text);
        public signal void finished();
        public signal void failed(string message);

        public bool live { get; set; default = true; }

        public abstract string id { get; }
        public abstract void start(string language) throws Error;
        public abstract void feed(uint8[] pcm);
        public abstract void pause_detected();
        public abstract void finish();
        public abstract void cancel();
    }

    public class WhisperEngine : DictationEngine {
        private const int PARTIAL_BYTES = SAMPLE_RATE * 2 * 3 / 2;
        private const int MIN_BYTES = SAMPLE_RATE * 2 / 2;

        public override string id { get { return "whisper"; } }
        public string binary { get; construct; }
        public string model { get; construct; }
        public int threads { get; set; default = 4; }

        private ByteArray buffer = new ByteArray();
        private int since_partial = 0;
        private bool busy = false;
        private bool closing = false;
        private bool cancelled = false;
        private bool segment_pending = false;
        private string language = "auto";
        private string work_dir;
        private int counter = 0;
        private uint generation = 0;
        private Cancellable cancellable = new Cancellable();

        public WhisperEngine(string binary, string model) {
            Object(binary: binary, model: model);
        }

        public override void start(string language) throws Error {
            this.language = language == "" ? "auto" : language;
            string base_dir = Environment.get_user_runtime_dir() ?? Environment.get_tmp_dir();
            work_dir = Path.build_filename(base_dir, "singularity-dictation");
            DirUtils.create_with_parents(work_dir, 0700);
        }

        public override void feed(uint8[] pcm) {
            if (closing || cancelled) return;
            buffer.append(pcm);
            since_partial += pcm.length;
            if (live && !busy && since_partial >= PARTIAL_BYTES && buffer.len >= MIN_BYTES) run(false);
        }

        public override void pause_detected() {
            if (closing || cancelled || buffer.len < MIN_BYTES) return;
            if (busy) {
                segment_pending = true;
                return;
            }
            run(true);
        }

        public override void finish() {
            if (closing || cancelled) return;
            closing = true;
            if (!busy) conclude();
        }

        public override void cancel() {
            cancelled = true;
            cancellable.cancel();
        }

        private void conclude() {
            if (buffer.len >= MIN_BYTES) {
                run(true);
            } else {
                finished();
            }
        }

        private void run(bool final_segment) {
            busy = true;
            since_partial = 0;
            uint8[] pcm = buffer.data[0:buffer.len];
            uint my_generation = generation;
            if (final_segment) {
                buffer = new ByteArray();
                generation++;
            }
            transcribe.begin(pcm, (obj, res) => {
                string? text = transcribe.end(res);
                busy = false;
                if (cancelled) return;
                if (text == null) {
                    failed(_("The speech engine stopped unexpectedly"));
                    return;
                }
                if (final_segment) {
                    if (text != "") segment_ready(text);
                } else if (my_generation == generation && text != "") {
                    partial(text);
                }
                if (segment_pending) {
                    segment_pending = false;
                    if (buffer.len >= MIN_BYTES) {
                        run(true);
                        return;
                    }
                }
                if (closing) {
                    if (buffer.len >= MIN_BYTES) run(true);
                    else finished();
                    return;
                }
                if (live && since_partial >= PARTIAL_BYTES && buffer.len >= MIN_BYTES) run(false);
            });
        }

        public string[] arguments(string wav_path) {
            return {
                binary, "-m", model, "-f", wav_path, "-l", language, "-nt", "-np",
                "-t", threads.to_string()
            };
        }

        private async string? transcribe(uint8[] pcm) {
            string path = Path.build_filename(work_dir, "segment-%d.wav".printf(counter++ % 4));
            try {
                FileUtils.set_data(path, Wav.encode(pcm));
                var process = new Subprocess.newv(arguments(path),
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string? output = null;
                yield process.communicate_utf8_async(null, cancellable, out output, null);
                FileUtils.unlink(path);
                if (!process.get_successful()) return null;
                return EngineOutput.clean_whisper(output ?? "");
            } catch (Error e) {
                FileUtils.unlink(path);
                if (!(e is IOError.CANCELLED)) warning("Dictation: whisper failed: %s", e.message);
                return null;
            }
        }
    }

    public class StreamEngine : DictationEngine {
        public override string id { get { return engine_id; } }
        public string engine_id { get; construct; }
        public string[] argv { get; construct; }

        private Subprocess? process = null;
        private OutputStream? input = null;
        private DataInputStream? output = null;
        private Queue<Bytes> pending = new Queue<Bytes>();
        private bool writing = false;
        private bool closing = false;
        private bool cancelled = false;
        private Cancellable cancellable = new Cancellable();

        public StreamEngine(string engine_id, string[] argv) {
            Object(engine_id: engine_id, argv: argv);
        }

        public override void start(string language) throws Error {
            string[] command = {};
            foreach (string arg in argv) command += arg.replace("%l", language == "" ? "auto" : language);
            process = new Subprocess.newv(command,
                SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            input = process.get_stdin_pipe();
            output = new DataInputStream(process.get_stdout_pipe());
            read_lines.begin();
        }

        public override void feed(uint8[] pcm) {
            if (closing || cancelled || input == null) return;
            pending.push_tail(new Bytes(pcm));
            if (!writing) write_next.begin();
        }

        public override void pause_detected() {
        }

        public override void finish() {
            if (closing || cancelled) return;
            closing = true;
            if (!writing) close_input.begin();
        }

        public override void cancel() {
            cancelled = true;
            cancellable.cancel();
            if (process != null) process.force_exit();
        }

        private async void write_next() {
            writing = true;
            while (!pending.is_empty() && !cancelled) {
                var chunk = pending.pop_head();
                try {
                    size_t written;
                    yield input.write_all_async(chunk.get_data(), Priority.DEFAULT, cancellable, out written);
                } catch (Error e) {
                    writing = false;
                    if (!cancelled) failed(_("The speech engine stopped unexpectedly"));
                    return;
                }
            }
            writing = false;
            if (closing) yield close_input();
        }

        private async void close_input() {
            try {
                yield input.close_async(Priority.DEFAULT, null);
            } catch (Error e) {
            }
        }

        private async void read_lines() {
            try {
                while (true) {
                    string? line = yield output.read_line_utf8_async(Priority.DEFAULT, cancellable);
                    if (line == null) break;
                    bool is_final;
                    string? text = EngineOutput.parse_stream_line(line, out is_final);
                    if (text == null || cancelled) continue;
                    if (is_final) {
                        if (text != "") segment_ready(text);
                    } else if (text != "") {
                        partial(text);
                    }
                }
            } catch (Error e) {
                if (cancelled) return;
            }
            if (cancelled) return;
            bool ok = false;
            try {
                ok = (yield process.wait_async(cancellable)) && process.get_successful();
            } catch (Error e) {
                ok = false;
            }
            if (cancelled) return;
            if (closing && ok) finished();
            else failed(_("The speech engine stopped unexpectedly"));
        }
    }

    public class FileTranscriber : Object {
        private const int CHUNK = SAMPLE_RATE * 2 / 10;
        private const int64 MAX_BYTES = 1024 * 1024 * 1024;

        public signal void partial(string text);

        public static uint8[] load_pcm(string path) throws Error {
            var file = File.new_for_path(path);
            var info = file.query_info(FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE);
            if (info.get_file_type() != FileType.REGULAR) throw new IOError.NOT_REGULAR_FILE(_("Not a regular file"));
            if (info.get_size() > MAX_BYTES) throw new IOError.NO_SPACE(_("The recording is too long"));
            uint8[] data;
            FileUtils.get_data(path, out data);
            int rate, channels;
            uint8[]? pcm = Wav.decode(data, out rate, out channels);
            if (pcm == null) throw new IOError.INVALID_DATA(_("The audio file is not a 16-bit PCM WAV file"));
            return Wav.resample(Wav.to_mono(pcm, channels), rate);
        }

        public async string transcribe(DictationEngine engine, uint8[] pcm, string language) throws Error {
            var text = new StringBuilder();
            string? failure = null;
            bool done = false;
            engine.live = false;
            engine.partial.connect((t) => partial(t));
            engine.segment_ready.connect((t) => {
                if (text.len > 0) text.append_c(' ');
                text.append(t.strip());
            });
            engine.finished.connect(() => {
                if (done) return;
                done = true;
                Idle.add(transcribe.callback);
            });
            engine.failed.connect((message) => {
                if (done) return;
                done = true;
                failure = message;
                Idle.add(transcribe.callback);
            });
            engine.start(language == "" ? "auto" : language);
            for (int offset = 0; offset < pcm.length; offset += CHUNK) {
                engine.feed(pcm[offset:int.min(offset + CHUNK, pcm.length)]);
            }
            engine.finish();
            yield;
            if (failure != null) throw new IOError.FAILED(failure);
            return text.str;
        }
    }
}
