namespace Singularity.Recorder {

    public delegate bool ElementAvailable(string factory);

    public class EncoderPlan : Object {
        public string encoder { get; construct; }
        public string video_chain { get; construct; }
        public string muxer { get; construct; }
        public string extension { get; construct; }
        public bool hardware { get; construct; }

        public EncoderPlan(string encoder, string video_chain, string muxer,
                           string extension, bool hardware) {
            Object(encoder: encoder, video_chain: video_chain, muxer: muxer,
                   extension: extension, hardware: hardware);
        }

        public string[] required_elements() {
            string[] names = {};
            foreach (var part in video_chain.split("!")) {
                string element = part.strip().split(" ")[0];
                if (element != "" && !element.contains("/")) names += element;
            }
            names += muxer;
            return names;
        }

        public string muxer_description() {
            if (muxer == "mp4mux") return "mp4mux faststart=true name=mux";
            return muxer + " name=mux";
        }
    }

    public class EncoderPlanner : Object {
        public static string[] base_elements() {
            return {
                "pipewiresrc", "queue", "videoconvert", "videocrop", "videoscale",
                "videorate", "capsfilter", "filesink"
            };
        }

        public static string[] audio_elements() {
            return { "pipewiresrc", "audioconvert", "audioresample", "opusenc" };
        }

        public static EncoderPlan[] candidates() {
            return {
                new EncoderPlan("vah264lpenc",
                    "video/x-raw,format=NV12 ! vah264lpenc ! h264parse",
                    "mp4mux", "mp4", true),
                new EncoderPlan("vah264enc",
                    "video/x-raw,format=NV12 ! vah264enc ! h264parse",
                    "mp4mux", "mp4", true),
                new EncoderPlan("vaapih264enc",
                    "video/x-raw,format=NV12 ! vaapih264enc ! h264parse",
                    "mp4mux", "mp4", true),
                new EncoderPlan("x264enc",
                    "video/x-raw,format=I420 ! x264enc speed-preset=veryfast tune=zerolatency ! h264parse",
                    "mp4mux", "mp4", false),
                new EncoderPlan("openh264enc",
                    "video/x-raw,format=I420 ! openh264enc ! h264parse",
                    "mp4mux", "mp4", false),
                new EncoderPlan("vp8enc",
                    "video/x-raw,format=I420 ! vp8enc deadline=1 cpu-used=8",
                    "webmmux", "webm", false)
            };
        }

        public static EncoderPlan[] usable(ElementAvailable available, string? only = null) {
            EncoderPlan[] plans = {};
            foreach (var plan in candidates()) {
                if (only != null && only != "" && plan.encoder != only) continue;
                bool ok = true;
                foreach (var name in plan.required_elements()) {
                    if (!available(name)) {
                        ok = false;
                        break;
                    }
                }
                if (ok) plans += plan;
            }
            return plans;
        }

        public static string[] missing(ElementAvailable available, string[] names) {
            string[] absent = {};
            foreach (var name in names) {
                if (!available(name)) absent += name;
            }
            return absent;
        }
    }

    public struct CropBox {
        public int left;
        public int top;
        public int right;
        public int bottom;

        public int width(int frame_width) {
            return frame_width - left - right;
        }

        public int height(int frame_height) {
            return frame_height - top - bottom;
        }
    }

    public class CropMath : Object {
        public static CropBox compute(int frame_width, int frame_height,
                                      int logical_width, int logical_height,
                                      int x, int y, int w, int h) {
            var box = CropBox();
            if (w > 0 && h > 0 && logical_width > 0 && logical_height > 0) {
                double sx = (double) frame_width / logical_width;
                double sy = (double) frame_height / logical_height;
                int x1 = ((int) Math.floor(x * sx)).clamp(0, frame_width);
                int y1 = ((int) Math.floor(y * sy)).clamp(0, frame_height);
                int x2 = ((int) Math.ceil((x + w) * sx)).clamp(x1, frame_width);
                int y2 = ((int) Math.ceil((y + h) * sy)).clamp(y1, frame_height);
                box.left = x1;
                box.top = y1;
                box.right = frame_width - x2;
                box.bottom = frame_height - y2;
            }
            if (box.width(frame_width) % 2 != 0) box.right++;
            if (box.height(frame_height) % 2 != 0) box.bottom++;
            if (box.width(frame_width) < 2 || box.height(frame_height) < 2) {
                box = CropBox();
                box.right = frame_width % 2;
                box.bottom = frame_height % 2;
            }
            return box;
        }
    }
}
