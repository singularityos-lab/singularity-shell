using GLib;

namespace Singularity {

    public class WallpaperEffects : Object {
        public const int MAX_BLUR_RADIUS = 64;

        public static Gdk.Pixbuf apply(Gdk.Pixbuf source, string effect, int blur_radius) {
            if (effect != "grayscale" && effect != "blur") return source;
            var pixels = source.read_pixel_bytes();
            var id = "%s\n%dx%d\n%d\n%d\n%s\n%d".printf(
                Checksum.compute_for_bytes(ChecksumType.SHA256, pixels),
                source.width, source.height, source.rowstride, source.has_alpha ? 1 : 0,
                effect, blur_radius);
            var packed = Singularity.Compute.for_thread().call(7, Singularity.Compute.key("wallpaper-effect", id.data), () => {
                return Singularity.Compute.pack_pixbuf(compute(source, effect, blur_radius));
            });
            return Singularity.Compute.unpack_pixbuf(packed) ?? source;
        }

        private static Gdk.Pixbuf compute(Gdk.Pixbuf source, string effect, int blur_radius) {
            switch (effect) {
                case "grayscale":
                    return grayscale(source);
                case "blur":
                    return blur(source, blur_radius);
                default:
                    return source;
            }
        }

        public static Gdk.Pixbuf grayscale(Gdk.Pixbuf source) {
            var output = source.copy();
            unowned uint8[] pixels = output.get_pixels_with_length();
            int channels = output.get_n_channels();
            int stride = output.get_rowstride();
            for (int y = 0; y < output.get_height(); y++) {
                for (int x = 0; x < output.get_width(); x++) {
                    int i = y * stride + x * channels;
                    double luma = 0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2];
                    uint8 value = (uint8) int.min(255, (int) Math.round(luma));
                    pixels[i] = value;
                    pixels[i + 1] = value;
                    pixels[i + 2] = value;
                }
            }
            return output;
        }

        public static Gdk.Pixbuf blur(Gdk.Pixbuf source, int radius) {
            radius = radius.clamp(1, MAX_BLUR_RADIUS);
            var output = source;
            for (int pass = 0; pass < 3; pass++) {
                output = box_blur(output, radius);
            }
            return output;
        }

        private static Gdk.Pixbuf box_blur(Gdk.Pixbuf source, int radius) {
            int width = source.get_width();
            int height = source.get_height();
            int channels = source.get_n_channels();
            var horizontal = source.copy();
            var output = source.copy();
            unowned uint8[] src = source.get_pixels_with_length();
            unowned uint8[] mid = horizontal.get_pixels_with_length();
            unowned uint8[] dst = output.get_pixels_with_length();
            int src_stride = source.get_rowstride();
            int mid_stride = horizontal.get_rowstride();
            int dst_stride = output.get_rowstride();

            for (int y = 0; y < height; y++) {
                for (int c = 0; c < channels; c++) {
                    int count = int.min(width - 1, radius) + 1;
                    int sum = 0;
                    for (int x = 0; x < count; x++) sum += src[y * src_stride + x * channels + c];
                    for (int x = 0; x < width; x++) {
                        mid[y * mid_stride + x * channels + c] = (uint8) (sum / count);
                        int leaving = x - radius;
                        int entering = x + radius + 1;
                        if (leaving >= 0) {
                            sum -= src[y * src_stride + leaving * channels + c];
                            count--;
                        }
                        if (entering < width) {
                            sum += src[y * src_stride + entering * channels + c];
                            count++;
                        }
                    }
                }
            }

            for (int x = 0; x < width; x++) {
                for (int c = 0; c < channels; c++) {
                    int count = int.min(height - 1, radius) + 1;
                    int sum = 0;
                    for (int y = 0; y < count; y++) sum += mid[y * mid_stride + x * channels + c];
                    for (int y = 0; y < height; y++) {
                        dst[y * dst_stride + x * channels + c] = (uint8) (sum / count);
                        int leaving = y - radius;
                        int entering = y + radius + 1;
                        if (leaving >= 0) {
                            sum -= mid[leaving * mid_stride + x * channels + c];
                            count--;
                        }
                        if (entering < height) {
                            sum += mid[entering * mid_stride + x * channels + c];
                            count++;
                        }
                    }
                }
            }
            return output;
        }
    }
}
