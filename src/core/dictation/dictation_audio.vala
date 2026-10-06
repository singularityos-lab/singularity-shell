namespace Singularity.Dictation {

    public class AudioCapture : Object {
        private const int CHUNK_BYTES = SAMPLE_RATE * 2 / 10;

        public signal void chunk(uint8[] pcm);
        public signal void failed(string message);

        public string? file_source { get; construct; }
        public bool running { get; private set; default = false; }

        private Subprocess? process = null;
        private Cancellable? cancellable = null;
        private uint timer = 0;
        private uint8[] file_pcm = {};
        private int file_pos = 0;

        public AudioCapture(string? file_source = null) {
            Object(file_source: file_source);
        }

        public static string[]? recorder_argv() {
            string? pw = Environment.find_program_in_path("pw-record");
            if (pw != null) {
                return {
                    pw, "--rate", SAMPLE_RATE.to_string(), "--channels", "1", "--format", "s16",
                    "-P", "{ \"application.name\": \"Dictation\", \"application.id\": \"dev.sinty.desktop\", \"media.role\": \"Communication\" }",
                    "-"
                };
            }
            string? parec = Environment.find_program_in_path("parec");
            if (parec != null) {
                return {
                    parec, "--raw", "--rate=%d".printf(SAMPLE_RATE), "--channels=1", "--format=s16le",
                    "--client-name=Dictation"
                };
            }
            return null;
        }

        public void start() throws Error {
            if (running) return;
            cancellable = new Cancellable();
            if (file_source != null && file_source != "") {
                start_file();
            } else {
                string[]? argv = recorder_argv();
                if (argv == null) throw new IOError.NOT_FOUND(_("No audio recorder is available"));
                process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                read_loop.begin(process.get_stdout_pipe());
            }
            running = true;
        }

        public void stop() {
            if (!running) return;
            running = false;
            if (cancellable != null) cancellable.cancel();
            if (timer != 0) {
                Source.remove(timer);
                timer = 0;
            }
            if (process != null) {
                process.send_signal(Posix.Signal.TERM);
                process = null;
            }
        }

        private void start_file() throws Error {
            uint8[] data;
            FileUtils.get_data(file_source, out data);
            int rate, channels;
            uint8[]? pcm = Wav.decode(data, out rate, out channels);
            if (pcm == null) throw new IOError.INVALID_DATA(_("The audio file is not a 16-bit PCM WAV file"));
            file_pcm = Wav.resample(Wav.to_mono(pcm, channels), rate);
            file_pos = 0;
            timer = Timeout.add(100, () => {
                if (!running) {
                    timer = 0;
                    return Source.REMOVE;
                }
                uint8[] piece;
                if (file_pos < file_pcm.length) {
                    int end = int.min(file_pos + CHUNK_BYTES, file_pcm.length);
                    piece = file_pcm[file_pos:end];
                    file_pos = end;
                } else {
                    piece = new uint8[CHUNK_BYTES];
                }
                chunk(piece);
                return Source.CONTINUE;
            });
        }

        private async void read_loop(InputStream stream) {
            var pending = new ByteArray();
            try {
                while (running) {
                    var bytes = yield stream.read_bytes_async(CHUNK_BYTES, Priority.DEFAULT, cancellable);
                    if (bytes.get_size() == 0) break;
                    pending.append(bytes.get_data());
                    while (pending.len >= CHUNK_BYTES) {
                        chunk(pending.data[0:CHUNK_BYTES]);
                        pending.remove_range(0, CHUNK_BYTES);
                    }
                }
            } catch (Error e) {
                if (e is IOError.CANCELLED) return;
            }
            if (running) failed(_("The microphone stopped"));
        }
    }
}
