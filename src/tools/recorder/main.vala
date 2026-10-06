using GLib;

namespace Singularity.Recorder {

    [DBus (name = "dev.sinty.portal.ScreenRecorder")]
    public interface PortalRecorder : Object {
        public abstract string list_windows() throws Error;
        public abstract async void start_capture(uint32 source_type, string source_id,
                                                 bool paint_cursors, out uint32 handle,
                                                 out uint32 node_id) throws Error;
        public abstract void stop_capture(uint32 handle) throws Error;
    }

    public class RecorderApp : Object {
        private const string PORTAL_NAME = "org.freedesktop.impl.portal.desktop.singularity";
        private const string PORTAL_PATH = "/dev/sinty/portal/ScreenRecorder";
        private const uint32 SOURCE_MONITOR = 1;
        private const uint32 SOURCE_WINDOW = 2;
        private const uint STOP_TIMEOUT_SECONDS = 15;

        private static string? opt_output = null;
        private static string? opt_window_app_id = null;
        private static string? opt_window_title = null;
        private static string? opt_crop = null;
        private static string? opt_output_size = null;
        private static string? opt_encoder = null;
        private static bool opt_cursor = false;
        private static bool opt_audio = false;
        private static bool opt_probe = false;
        [CCode (array_length = false, array_null_terminated = true)]
        private static string[]? opt_rest = null;

        private const OptionEntry[] OPTIONS = {
            { "output", 0, 0, OptionArg.STRING, ref opt_output, "Output (connector) to record", "NAME" },
            { "window-app-id", 0, 0, OptionArg.STRING, ref opt_window_app_id, "Record the window with this app id", "ID" },
            { "window-title", 0, 0, OptionArg.STRING, ref opt_window_title, "Title of the window to record", "TITLE" },
            { "crop", 0, 0, OptionArg.STRING, ref opt_crop, "Area of the output to keep, in logical pixels", "X,Y,W,H" },
            { "output-size", 0, 0, OptionArg.STRING, ref opt_output_size, "Logical size of the output", "WxH" },
            { "cursor", 0, 0, OptionArg.NONE, ref opt_cursor, "Include the pointer", null },
            { "audio", 0, 0, OptionArg.NONE, ref opt_audio, "Record the system audio", null },
            { "encoder", 0, 0, OptionArg.STRING, ref opt_encoder, "Force a video encoder element", "NAME" },
            { "probe", 0, 0, OptionArg.NONE, ref opt_probe, "Print the usable encoders and exit", null },
            { OPTION_REMAINING, 0, 0, OptionArg.FILENAME_ARRAY, ref opt_rest, null, "BASENAME" },
            { null }
        };

        private MainLoop loop = new MainLoop();
        private int exit_code = 0;
        private PortalRecorder? portal = null;
        private uint32 capture_handle = 0;
        private uint32 node_id = 0;
        private Gst.Pipeline? pipeline = null;
        private uint bus_watch_id = 0;
        private EncoderPlan[] plans = {};
        private int plan_index = 0;
        private bool with_audio = false;
        private string base_path = "";
        private string? out_path = null;
        private bool announced = false;
        private bool stopping = false;
        private bool done = false;
        private int encoded_frames = 0;
        private int crop_x = 0;
        private int crop_y = 0;
        private int crop_w = 0;
        private int crop_h = 0;
        private int logical_w = 0;
        private int logical_h = 0;
        private bool size_fixed = false;
        private uint stop_timeout_id = 0;

        public int run(string[] args) {
            try {
                var context = new OptionContext("- record the screen");
                context.add_main_entries(OPTIONS, null);
                context.parse(ref args);
            } catch (OptionError e) {
                stderr.printf("%s\n", e.message);
                return 2;
            }

            Gst.init(ref args);

            if (opt_probe) return probe();

            if (opt_rest == null || opt_rest[0] == null || opt_rest[0] == "") {
                stderr.printf("singularity-recorder: missing output basename\n");
                return 2;
            }
            base_path = opt_rest[0];
            parse_geometry();

            Unix.signal_add(ProcessSignal.INT, () => {
                request_stop();
                return Source.CONTINUE;
            });
            Unix.signal_add(ProcessSignal.TERM, () => {
                request_stop();
                return Source.CONTINUE;
            });
            watch_stdin();

            start.begin();
            loop.run();
            return exit_code;
        }

        private static bool element_available(string name) {
            return Gst.ElementFactory.find(name) != null;
        }

        private int probe() {
            var usable = EncoderPlanner.usable(element_available, opt_encoder);
            string[] absent = EncoderPlanner.missing(element_available, EncoderPlanner.base_elements());
            foreach (var name in absent) stdout.printf("missing %s\n", name);
            foreach (var plan in usable) {
                stdout.printf("encoder %s %s %s\n", plan.encoder, plan.muxer, plan.extension);
            }
            string[] audio_absent = EncoderPlanner.missing(element_available, EncoderPlanner.audio_elements());
            stdout.printf("audio %s\n", audio_absent.length == 0 ? "yes" : "no");
            return (usable.length > 0 && absent.length == 0) ? 0 : 1;
        }

        private void parse_geometry() {
            if (opt_crop != null) {
                string[] parts = opt_crop.split(",");
                if (parts.length == 4) {
                    int.try_parse(parts[0], out crop_x);
                    int.try_parse(parts[1], out crop_y);
                    int.try_parse(parts[2], out crop_w);
                    int.try_parse(parts[3], out crop_h);
                }
            }
            if (opt_output_size != null) {
                string[] parts = opt_output_size.split("x");
                if (parts.length == 2) {
                    int.try_parse(parts[0], out logical_w);
                    int.try_parse(parts[1], out logical_h);
                }
            }
        }

        private void emit(string line) {
            stdout.printf("%s\n", line);
            stdout.flush();
        }

        private void watch_stdin() {
            var input = new UnixInputStream(0, false);
            read_stdin.begin(input);
        }

        private async void read_stdin(InputStream input) {
            var data = new DataInputStream(input);
            while (true) {
                string? line = null;
                try {
                    line = yield data.read_line_async(Priority.DEFAULT, null);
                } catch (Error e) {
                    line = null;
                }
                if (line == null || line.strip() == "stop") {
                    request_stop();
                    return;
                }
            }
        }

        private async void start() {
            string[] absent = EncoderPlanner.missing(element_available, EncoderPlanner.base_elements());
            if (absent.length > 0) {
                fail(_("Screen recording needs these GStreamer elements: %s").printf(string.joinv(", ", absent)));
                return;
            }
            plans = EncoderPlanner.usable(element_available, opt_encoder);
            if (plans.length == 0) {
                fail(_("No video encoder is available. Install the GStreamer x264, OpenH264 or VPX plugin."));
                return;
            }
            with_audio = opt_audio;
            if (with_audio && EncoderPlanner.missing(element_available, EncoderPlanner.audio_elements()).length > 0) {
                warning("audio elements missing, recording video only");
                with_audio = false;
            }

            try {
                portal = yield Bus.get_proxy<PortalRecorder>(BusType.SESSION, PORTAL_NAME, PORTAL_PATH,
                    DBusProxyFlags.DO_NOT_LOAD_PROPERTIES | DBusProxyFlags.DO_NOT_CONNECT_SIGNALS);
            } catch (Error e) {
                fail(describe_portal_error(e));
                return;
            }

            uint32 source_type = SOURCE_MONITOR;
            string? source_id = opt_output;
            if (opt_window_app_id != null) {
                string? window_id = find_window();
                if (window_id != null) {
                    source_type = SOURCE_WINDOW;
                    source_id = window_id;
                    crop_w = 0;
                    crop_h = 0;
                }
            }
            if (source_id == null || source_id == "") {
                fail(_("Could not find the screen or window to record."));
                return;
            }

            try {
                yield portal.start_capture(source_type, source_id, opt_cursor, out capture_handle, out node_id);
            } catch (Error e) {
                fail(describe_portal_error(e));
                return;
            }
            if (stopping) {
                cancel();
                return;
            }
            start_pipeline();
        }

        private string? find_window() {
            string json;
            try {
                json = portal.list_windows();
            } catch (Error e) {
                warning("listing windows failed: %s", e.message);
                return null;
            }
            string? by_title = null;
            string? by_app = null;
            int title_matches = 0;
            int app_matches = 0;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var root = parser.get_root().get_object();
                foreach (var node in root.get_array_member("sources").get_elements()) {
                    var item = node.get_object();
                    if (item.get_string_member_with_default("app_id", "") != opt_window_app_id) continue;
                    string id = item.get_string_member("id");
                    app_matches++;
                    by_app = id;
                    if (opt_window_title != null && item.get_string_member_with_default("label", "") == opt_window_title) {
                        title_matches++;
                        by_title = id;
                    }
                }
            } catch (Error e) {
                warning("invalid window list: %s", e.message);
                return null;
            }
            if (title_matches == 1) return by_title;
            if (title_matches == 0 && app_matches == 1) return by_app;
            return null;
        }

        private string describe_portal_error(Error e) {
            if (e is DBusError.SERVICE_UNKNOWN || e is DBusError.NAME_HAS_NO_OWNER) {
                return _("The Singularity portal is not running, so the screen cannot be captured.");
            }
            if (e is DBusError.UNKNOWN_METHOD || e is DBusError.UNKNOWN_OBJECT ||
                e is DBusError.UNKNOWN_INTERFACE) {
                return _("The installed Singularity portal is too old for screen recording. Update xdg-desktop-portal-singularity.");
            }
            DBusError.strip_remote_error(e);
            return e.message;
        }

        private string chain_with_encoder_name(EncoderPlan plan) {
            string[] parts = plan.video_chain.split("!");
            for (int i = 0; i < parts.length; i++) {
                string part = parts[i].strip();
                if (part.split(" ")[0] == plan.encoder) {
                    parts[i] = " " + plan.encoder + " name=venc" + part.substring(plan.encoder.length) + " ";
                }
            }
            return string.joinv("!", parts);
        }

        private void start_pipeline() {
            var plan = plans[plan_index];
            out_path = "%s.%s".printf(base_path, plan.extension);
            string description =
                "pipewiresrc name=vsrc ! videocrop name=crop ! videoscale n-threads=0 ! capsfilter name=size " +
                "! videorate ! video/x-raw,framerate=30/1 ! videoconvert n-threads=0 ! " +
                chain_with_encoder_name(plan) + " ! queue ! " + plan.muxer_description() +
                " ! filesink name=sink";
            if (with_audio) {
                description += " pipewiresrc name=asrc ! queue ! audioconvert ! audioresample " +
                    "! audio/x-raw,rate=48000,channels=2 ! opusenc bitrate=128000 ! queue ! mux.";
            }

            try {
                pipeline = (Gst.Pipeline) Gst.parse_launch(description);
            } catch (Error e) {
                next_plan_or_fail(e.message);
                return;
            }

            var vsrc = pipeline.get_by_name("vsrc");
            vsrc.set("path", node_id.to_string());
            vsrc.set("do-timestamp", true);
            vsrc.set("provide-clock", false);
            vsrc.set("keepalive-time", 500);
            set_enum_if_present(vsrc, "on-disconnect", "eos");
            if (with_audio) {
                var asrc = pipeline.get_by_name("asrc");
                asrc.set("do-timestamp", true);
                asrc.set("provide-clock", false);
                unowned string rest;
                asrc.set("stream-properties", new Gst.Structure.from_string(
                    "props,stream.capture.sink=(string)true,media.category=(string)Capture,node.name=(string)singularity-recorder-audio", out rest));
            }
            pipeline.get_by_name("sink").set("location", out_path);
            if (plan.muxer == "mp4mux") pipeline.get_by_name("mux").set("faststart-file", part_path());

            var crop = pipeline.get_by_name("crop");
            crop.get_static_pad("sink").add_probe(
                Gst.PadProbeType.EVENT_DOWNSTREAM | Gst.PadProbeType.EVENT_UPSTREAM, on_crop_event);
            pipeline.get_by_name("venc").get_static_pad("src").add_probe(Gst.PadProbeType.BUFFER, (pad, info) => {
                AtomicInt.inc(ref encoded_frames);
                return Gst.PadProbeReturn.OK;
            });

            bus_watch_id = pipeline.get_bus().add_watch(Priority.DEFAULT, on_bus_message);
            if (pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                next_plan_or_fail(_("Could not start the %s encoder.").printf(plan.encoder));
            }
        }

        private void set_enum_if_present(Gst.Element element, string property, string nick) {
            var spec = element.get_class().find_property(property);
            if (spec == null) return;
            Gst.Util.set_object_arg(element, property, nick);
        }

        private Gst.PadProbeReturn on_crop_event(Gst.Pad pad, Gst.PadProbeInfo info) {
            var event = info.get_event();
            if (event == null) return Gst.PadProbeReturn.OK;
            if (event.type == Gst.EventType.RECONFIGURE) return Gst.PadProbeReturn.DROP;
            if (event.type != Gst.EventType.CAPS) return Gst.PadProbeReturn.OK;
            Gst.Caps caps;
            event.parse_caps(out caps);
            unowned Gst.Structure s = caps.get_structure(0);
            int width = 0;
            int height = 0;
            if (!s.get_int("width", out width) || !s.get_int("height", out height)) {
                return Gst.PadProbeReturn.OK;
            }
            var box = CropMath.compute(width, height, logical_w, logical_h, crop_x, crop_y, crop_w, crop_h);
            var crop = pad.get_parent_element();
            crop.set("left", box.left, "top", box.top, "right", box.right, "bottom", box.bottom);
            if (!size_fixed) {
                size_fixed = true;
                var size = pipeline.get_by_name("size");
                size.set("caps", Gst.Caps.from_string("video/x-raw,width=%d,height=%d,pixel-aspect-ratio=1/1".printf(
                    box.width(width), box.height(height))));
            }
            return Gst.PadProbeReturn.OK;
        }

        private bool on_bus_message(Gst.Bus bus, Gst.Message message) {
            switch (message.type) {
                case Gst.MessageType.STATE_CHANGED:
                    if (message.src == pipeline && !announced) {
                        Gst.State old_state, new_state, pending;
                        message.parse_state_changed(out old_state, out new_state, out pending);
                        if (new_state == Gst.State.PLAYING) {
                            announced = true;
                            emit("recording " + out_path);
                        }
                    }
                    break;
                case Gst.MessageType.EOS:
                    bus_watch_id = 0;
                    finish();
                    return Source.REMOVE;
                case Gst.MessageType.ERROR:
                    bus_watch_id = 0;
                    Error err;
                    string debug;
                    message.parse_error(out err, out debug);
                    warning("pipeline error from %s: %s (%s)", message.src.name, err.message, debug ?? "");
                    if (AtomicInt.get(ref encoded_frames) == 0 && !stopping) {
                        next_plan_or_fail(err.message);
                    } else if (stopping && AtomicInt.get(ref encoded_frames) > 0) {
                        finish();
                    } else {
                        teardown_pipeline();
                        discard_output();
                        fail(_("Recording stopped because of an error: %s").printf(err.message));
                    }
                    return Source.REMOVE;
                default:
                    break;
            }
            return Source.CONTINUE;
        }

        private void next_plan_or_fail(string reason) {
            teardown_pipeline();
            discard_output();
            if (with_audio) {
                warning("recording with audio failed (%s), retrying without audio", reason);
                with_audio = false;
                emit("warning " + _("System audio could not be recorded."));
                start_pipeline();
                return;
            }
            if (plan_index + 1 < plans.length) {
                warning("encoder %s failed (%s), trying %s", plans[plan_index].encoder, reason,
                    plans[plan_index + 1].encoder);
                plan_index++;
                start_pipeline();
                return;
            }
            fail(_("Could not start recording: %s").printf(reason));
        }

        private void request_stop() {
            if (stopping || done) return;
            stopping = true;
            if (pipeline == null) return;
            pipeline.send_event(new Gst.Event.eos());
            stop_timeout_id = Timeout.add_seconds(STOP_TIMEOUT_SECONDS, () => {
                stop_timeout_id = 0;
                warning("pipeline did not drain in time");
                finish();
                return Source.REMOVE;
            });
        }

        private void finish() {
            if (done) return;
            teardown_pipeline();
            release_capture();
            if (AtomicInt.get(ref encoded_frames) == 0 || out_path == null || !has_data(out_path)) {
                discard_output();
                fail(_("Nothing was recorded because the screen did not send any frames."));
                return;
            }
            done = true;
            emit("saved " + out_path);
            exit_code = 0;
            loop.quit();
        }

        private void cancel() {
            release_capture();
            done = true;
            emit("cancelled");
            exit_code = 0;
            loop.quit();
        }

        private void fail(string message) {
            if (done) return;
            done = true;
            teardown_pipeline();
            release_capture();
            emit("error " + message.replace("\n", " "));
            exit_code = 1;
            loop.quit();
        }

        private void teardown_pipeline() {
            if (stop_timeout_id != 0) {
                Source.remove(stop_timeout_id);
                stop_timeout_id = 0;
            }
            if (bus_watch_id != 0) {
                Source.remove(bus_watch_id);
                bus_watch_id = 0;
            }
            if (pipeline != null) {
                pipeline.set_state(Gst.State.NULL);
                pipeline = null;
            }
            size_fixed = false;
        }

        private void release_capture() {
            if (portal == null || capture_handle == 0) return;
            try {
                portal.stop_capture(capture_handle);
            } catch (Error e) {
                warning("stopping capture failed: %s", e.message);
            }
            capture_handle = 0;
        }

        private string part_path() {
            return Path.build_filename(Path.get_dirname(out_path), "." + Path.get_basename(out_path) + ".part");
        }

        private void discard_output() {
            if (out_path == null) return;
            FileUtils.unlink(out_path);
            FileUtils.unlink(part_path());
        }

        private bool has_data(string path) {
            try {
                var info = File.new_for_path(path).query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                return info.get_size() > 1024;
            } catch (Error e) {
                return false;
            }
        }
    }

    public static int main(string[] args) {
        Intl.setlocale(LocaleCategory.ALL, "");
        return new RecorderApp().run(args);
    }
}
