using GLib;

namespace Singularity {

    public class ScreenRecordingRequest : Object {
        public string? output = null;
        public string? window_app_id = null;
        public string? window_title = null;
        public int crop_x = 0;
        public int crop_y = 0;
        public int crop_width = 0;
        public int crop_height = 0;
        public int output_width = 0;
        public int output_height = 0;
        public bool cursor = true;
        public bool audio = false;

        public string[] to_args(string basename) {
            string[] args = {};
            if (output != null && output != "") args += "--output=" + output;
            if (window_app_id != null && window_app_id != "") {
                args += "--window-app-id=" + window_app_id;
                if (window_title != null) args += "--window-title=" + window_title;
            }
            if (crop_width > 0 && crop_height > 0) {
                args += "--crop=%d,%d,%d,%d".printf(crop_x, crop_y, crop_width, crop_height);
            }
            if (output_width > 0 && output_height > 0) {
                args += "--output-size=%dx%d".printf(output_width, output_height);
            }
            if (cursor) args += "--cursor";
            if (audio) args += "--audio";
            args += basename;
            return args;
        }
    }

    public class ScreenRecorder : Object {
        private static ScreenRecorder? _instance = null;
        private const uint STOP_GRACE_SECONDS = 20;

        public bool recording { get; private set; default = false; }
        public bool busy { get { return _proc != null; } }

        public signal void tick(int64 seconds);
        public signal void finished(string path, string[] warnings);
        public signal void failed(string message);

        private GLib.Subprocess? _proc = null;
        private int64 _started_at = 0;
        private uint _tick_id = 0;
        private uint _kill_id = 0;
        private string[] _warnings = {};
        private bool _reported = false;
        private string? _output_path = null;

        public static ScreenRecorder get_default() {
            if (_instance == null) _instance = new ScreenRecorder();
            return _instance;
        }

        public int64 elapsed_seconds {
            get {
                if (!recording) return 0;
                return (GLib.get_monotonic_time() - _started_at) / 1000000;
            }
        }

        public static string videos_dir() {
            string? configured = Environment.get_user_special_dir(UserDirectory.VIDEOS);
            if (configured != null && configured.strip() != "" &&
                    !File.new_for_path(configured).equal(File.new_for_path(Environment.get_home_dir()))) {
                return configured;
            }
            return Path.build_filename(Environment.get_home_dir(), "Videos");
        }

        public static string new_basename() throws Error {
            string dir = videos_dir();
            if (DirUtils.create_with_parents(dir, 0755) != 0) {
                throw new IOError.FAILED(_("Could not create the folder %s").printf(dir));
            }
            var now = new DateTime.now_local();
            return Path.build_filename(dir, "Recording %s".printf(now.format("%Y-%m-%d %H-%M-%S")));
        }

        public void start(ScreenRecordingRequest request) {
            if (_proc != null) return;
            _warnings = {};
            _reported = false;
            _output_path = null;

            string basename;
            try {
                basename = new_basename();
            } catch (Error e) {
                report_failure(e.message);
                return;
            }

            string[] argv = { AppSystem.resolve_companion_bin("singularity-recorder") };
            foreach (var arg in request.to_args(basename)) argv += arg;

            try {
                _proc = new GLib.Subprocess.newv(argv,
                    GLib.SubprocessFlags.STDIN_PIPE | GLib.SubprocessFlags.STDOUT_PIPE);
            } catch (Error e) {
                _proc = null;
                report_failure(_("Could not start the screen recorder: %s").printf(e.message));
                return;
            }

            var proc = _proc;
            read_status.begin(proc);
            proc.wait_async.begin(null, (obj, res) => {
                try {
                    proc.wait_async.end(res);
                } catch (Error e) {
                    warning("[ScreenRecorder] wait failed: %s", e.message);
                }
                on_exit(proc);
            });
        }

        public void stop() {
            if (_proc == null) return;
            update_recording(false);
            var stdin_pipe = _proc.get_stdin_pipe();
            if (stdin_pipe != null) {
                try {
                    stdin_pipe.close();
                } catch (Error e) {
                    warning("[ScreenRecorder] closing recorder input: %s", e.message);
                }
            }
            if (_kill_id == 0) {
                var proc = _proc;
                _kill_id = Timeout.add_seconds(STOP_GRACE_SECONDS, () => {
                    _kill_id = 0;
                    if (_proc == proc) {
                        warning("[ScreenRecorder] recorder did not finish, stopping it");
                        report_failure(_("The screen recorder did not finish saving the video."));
                        proc.force_exit();
                    }
                    return Source.REMOVE;
                });
            }
        }

        private async void read_status(GLib.Subprocess proc) {
            var stream = new DataInputStream(proc.get_stdout_pipe());
            while (true) {
                string? line = null;
                try {
                    line = yield stream.read_line_utf8_async(Priority.DEFAULT, null);
                } catch (Error e) {
                    line = null;
                }
                if (line == null) return;
                handle_status(proc, line);
            }
        }

        private void handle_status(GLib.Subprocess proc, string line) {
            if (proc != _proc) return;
            int space = line.index_of_char(' ');
            string verb = space < 0 ? line : line.substring(0, space);
            string rest = space < 0 ? "" : line.substring(space + 1);
            switch (verb) {
                case "recording":
                    _output_path = rest;
                    if (_kill_id == 0) {
                        _started_at = GLib.get_monotonic_time();
                        update_recording(true);
                    }
                    break;
                case "warning":
                    _warnings += rest;
                    break;
                case "saved":
                    if (!_reported) {
                        _reported = true;
                        finished(rest, _warnings);
                    }
                    break;
                case "error":
                    report_failure(rest);
                    break;
                case "cancelled":
                    _reported = true;
                    break;
                default:
                    break;
            }
        }

        private void on_exit(GLib.Subprocess proc) {
            if (proc != _proc) return;
            if (_kill_id != 0) {
                Source.remove(_kill_id);
                _kill_id = 0;
            }
            _proc = null;
            update_recording(false);
            if (!_reported) {
                discard_partial_output();
                report_failure(_("The screen recorder stopped unexpectedly."));
            }
        }

        private void discard_partial_output() {
            if (_output_path == null) return;
            string part = Path.build_filename(Path.get_dirname(_output_path),
                "." + Path.get_basename(_output_path) + ".part");
            FileUtils.unlink(part);
            try {
                var info = File.new_for_path(_output_path).query_info(
                    FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                if (info.get_size() == 0) FileUtils.unlink(_output_path);
            } catch (Error e) {
            }
        }

        private void report_failure(string message) {
            if (_reported) return;
            _reported = true;
            failed(message);
        }

        private void update_recording(bool value) {
            if (recording == value) return;
            recording = value;
            if (value) {
                tick(0);
                _tick_id = Timeout.add_seconds(1, () => {
                    tick(elapsed_seconds);
                    return Source.CONTINUE;
                });
            } else if (_tick_id != 0) {
                Source.remove(_tick_id);
                _tick_id = 0;
            }
        }
    }
}
