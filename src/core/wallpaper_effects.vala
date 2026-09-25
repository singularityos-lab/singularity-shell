using GLib;
using Gee;

namespace Singularity {
    public class WallpaperEffects : Object {
        public const uint64 BYTE_BUDGET = 500 * 1024 * 1024;
        private string cache_directory;
        private bool size_known = false;
        private uint64 known_size = 0;

        private class CacheFile : Object {
            public File file;
            public uint64 size;
            public uint64 modified;
            public CacheFile(File file, uint64 size, uint64 modified) {
                this.file = file; this.size = size; this.modified = modified;
            }
        }

        public WallpaperEffects(string? directory = null) {
            cache_directory = directory ?? Path.build_filename(
                Environment.get_user_cache_dir(), "singularity", "wallpaper-effects");
        }

        public Gdk.Pixbuf apply_grayscale(Gdk.Pixbuf source, string source_cache_key) {
            string key = make_key(source, source_cache_key, "grayscale:v1");
            var cached = get(key); if (cached != null) return cached;
            var output = source.copy();
            unowned uint8[] pixels = output.get_pixels_with_length();
            int channels = output.get_n_channels();
            int stride = output.get_rowstride();
            for (int y = 0; y < output.get_height(); y++) for (int x = 0; x < output.get_width(); x++) {
                int i = y * stride + x * channels;
                uint8 luma = (uint8) int.min(255, (int) Math.round(
                    0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2]));
                pixels[i] = pixels[i + 1] = pixels[i + 2] = luma;
            }
            put(key, output); return output;
        }

        public Gdk.Pixbuf apply_blur(Gdk.Pixbuf source, string source_cache_key, int radius) {
            radius = int.max(1, int.min(radius, 64));
            string key = make_key(source, source_cache_key, "blur:v1:r=%d".printf(radius));
            var cached = get(key); if (cached != null) return cached;
            var output = source.copy();
            for (int pass = 0; pass < 3; pass++) output = box_blur(output, radius);
            put(key, output); return output;
        }

        public Gdk.Pixbuf apply_oil_paint(Gdk.Pixbuf source, string source_cache_key,
                                           int radius, int intensity_levels = 24) {
            radius = int.max(1, int.min(radius, 12));
            intensity_levels = int.max(2, int.min(intensity_levels, 64));
            string key = make_key(source, source_cache_key,
                "oil:v1:r=%d:l=%d".printf(radius, intensity_levels));
            var cached = get(key); if (cached != null) return cached;
            var output = source.copy();
            unowned uint8[] src = source.get_pixels_with_length();
            unowned uint8[] dst = output.get_pixels_with_length();
            int ch = source.get_n_channels(), ss = source.get_rowstride(), ds = output.get_rowstride();
            int w = source.get_width(), h = source.get_height();
            int[] count = new int[intensity_levels];
            int[] red = new int[intensity_levels], green = new int[intensity_levels], blue = new int[intensity_levels];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                for (int b = 0; b < intensity_levels; b++) count[b] = red[b] = green[b] = blue[b] = 0;
                for (int yy = int.max(0, y - radius); yy <= int.min(h - 1, y + radius); yy++)
                    for (int xx = int.max(0, x - radius); xx <= int.min(w - 1, x + radius); xx++) {
                        int si = yy * ss + xx * ch;
                        int luma = (int) (0.2126 * src[si] + 0.7152 * src[si + 1] + 0.0722 * src[si + 2]);
                        int bin = int.min(intensity_levels - 1, luma * intensity_levels / 256);
                        count[bin]++; red[bin] += src[si]; green[bin] += src[si + 1]; blue[bin] += src[si + 2];
                    }
                int best = 0;
                for (int b = 1; b < intensity_levels; b++) if (count[b] > count[best]) best = b;
                int di = y * ds + x * ch;
                dst[di] = (uint8) (red[best] / count[best]);
                dst[di + 1] = (uint8) (green[best] / count[best]);
                dst[di + 2] = (uint8) (blue[best] / count[best]);
            }
            put(key, output); return output;
        }

        public Gdk.Pixbuf apply_quote_overlay(Gdk.Pixbuf source, string source_cache_key,
                                               string text, string font_description = "Sans Bold 42") {
            string key = make_key(source, source_cache_key,
                "quote:v1:text=%s:font=%s".printf(text, font_description));
            var cached = get(key); if (cached != null) return cached;
            if (text.strip() == "") return source.copy();
            int w = source.get_width(), h = source.get_height();
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context(surface);
            Gdk.cairo_set_source_pixbuf(cr, source, 0, 0); cr.paint();
            var layout = Pango.cairo_create_layout(cr);
            layout.set_text(text, -1);
            layout.set_font_description(Pango.FontDescription.from_string(font_description));
            layout.set_width((int) (w * 0.82 * Pango.SCALE));
            layout.set_alignment(Pango.Alignment.CENTER);
            layout.set_wrap(Pango.WrapMode.WORD_CHAR);
            int tw, th; layout.get_pixel_size(out tw, out th);
            double x = (w - tw) / 2.0, y = h - th - int.max(24, h / 14);
            double pad = int.max(12, h / 60);
            rounded_rect(cr, x - pad, y - pad, tw + pad * 2, th + pad * 2, pad);
            cr.set_source_rgba(0, 0, 0, 0.58); cr.fill();
            cr.move_to(x + 2, y + 3); cr.set_source_rgba(0, 0, 0, 0.8);
            Pango.cairo_show_layout(cr, layout);
            cr.move_to(x, y); cr.set_source_rgba(1, 1, 1, 1);
            Pango.cairo_show_layout(cr, layout);
            surface.flush();
            var output = pixbuf_from_surface(surface, source.get_has_alpha());
            put(key, output); return output;
        }

        private static Gdk.Pixbuf box_blur(Gdk.Pixbuf source, int radius) {
            int w = source.get_width(), h = source.get_height(), ch = source.get_n_channels();
            var horizontal = source.copy(); var output = source.copy();
            unowned uint8[] src = source.get_pixels_with_length();
            unowned uint8[] mid = horizontal.get_pixels_with_length();
            unowned uint8[] dst = output.get_pixels_with_length();
            int ss = source.get_rowstride(), ms = horizontal.get_rowstride(), ds = output.get_rowstride();
            for (int y = 0; y < h; y++) for (int c = 0; c < ch; c++) {
                int sum = 0, n = int.min(w - 1, radius) + 1;
                for (int xx = 0; xx < n; xx++) sum += src[y*ss+xx*ch+c];
                for (int x = 0; x < w; x++) {
                    mid[y*ms+x*ch+c] = (uint8) (sum/n);
                    int remove = x-radius, add = x+radius+1;
                    if (remove >= 0) { sum -= src[y*ss+remove*ch+c]; n--; }
                    if (add < w) { sum += src[y*ss+add*ch+c]; n++; }
                }
            }
            for (int x = 0; x < w; x++) for (int c = 0; c < ch; c++) {
                int sum = 0, n = int.min(h - 1, radius) + 1;
                for (int yy = 0; yy < n; yy++) sum += mid[yy*ms+x*ch+c];
                for (int y = 0; y < h; y++) {
                    dst[y*ds+x*ch+c] = (uint8) (sum/n);
                    int remove = y-radius, add = y+radius+1;
                    if (remove >= 0) { sum -= mid[remove*ms+x*ch+c]; n--; }
                    if (add < h) { sum += mid[add*ms+x*ch+c]; n++; }
                }
            }
            return output;
        }

        private static void rounded_rect(Cairo.Context cr, double x, double y, double w, double h, double r) {
            cr.new_sub_path(); cr.arc(x+w-r, y+r, r, -Math.PI/2, 0); cr.arc(x+w-r, y+h-r, r, 0, Math.PI/2);
            cr.arc(x+r, y+h-r, r, Math.PI/2, Math.PI); cr.arc(x+r, y+r, r, Math.PI, 3*Math.PI/2); cr.close_path();
        }

        private static Gdk.Pixbuf pixbuf_from_surface(Cairo.ImageSurface surface, bool alpha) {
            int w = surface.get_width(), h = surface.get_height(), stride = surface.get_stride();
            unowned uchar[] data = surface.get_data();
            var output = new Gdk.Pixbuf(Gdk.Colorspace.RGB, alpha, 8, w, h);
            unowned uint8[] dst = output.get_pixels_with_length(); int ds = output.get_rowstride(), ch = output.get_n_channels();
            for (int y=0; y<h; y++) for (int x=0; x<w; x++) {
                int si=y*stride+x*4, di=y*ds+x*ch; uint8 a=data[si+3];
                dst[di] = a == 0 ? 0 : (uint8) int.min(255, data[si+2]*255/a);
                dst[di+1] = a == 0 ? 0 : (uint8) int.min(255, data[si+1]*255/a);
                dst[di+2] = a == 0 ? 0 : (uint8) int.min(255, data[si]*255/a);
                if (ch == 4) dst[di+3] = a;
            }
            return output;
        }

        private static string make_key(Gdk.Pixbuf source, string source_key, string effect) {
            return Checksum.compute_for_string(ChecksumType.SHA256, "%s|%dx%d|%s".printf(
                source_key, source.get_width(), source.get_height(), effect));
        }
        private string path_for(string key) { return Path.build_filename(cache_directory, key + ".rgba"); }
        private new Gdk.Pixbuf? get(string key) {
            string path = path_for(key); if (!FileUtils.test(path, FileTest.IS_REGULAR)) return null;
            try {
                uint8[] data; FileUtils.get_data(path, out data);
                if (data.length < 16 || data[0] != 'S' || data[1] != 'F' || data[2] != 'X' || data[3] != '1') return null;
                int w = read_u32(data, 4), h = read_u32(data, 8), ch = read_u32(data, 12);
                if (w < 1 || h < 1 || (ch != 3 && ch != 4) || data.length != 16 + w*h*ch) return null;
                var pb = new Gdk.Pixbuf(Gdk.Colorspace.RGB, ch == 4, 8, w, h);
                unowned uint8[] pixels = pb.get_pixels_with_length(); int stride = pb.get_rowstride();
                for (int y=0; y<h; y++) for (int x=0; x<w*ch; x++) pixels[y*stride+x] = data[16+y*w*ch+x];
                try {
                    File.new_for_path(path).set_attribute_uint64(FileAttribute.TIME_MODIFIED,
                        (uint64) new DateTime.now_utc().to_unix(), FileQueryInfoFlags.NONE, null);
                } catch (Error e) {}
                return pb;
            } catch (Error e) {
                message("Discarding unreadable wallpaper effect cache %s: %s", path, e.message);
                return null;
            }
        }
        private void put(string key, Gdk.Pixbuf pixbuf) {
            if (DirUtils.create_with_parents(cache_directory, 0700) != 0) return;
            if (!size_known) refresh_size();
            string path=path_for(key), temp=Path.build_filename(cache_directory, ".effect-"+Uuid.string_random()+".tmp");
            uint64 old=file_size(path);
            try {
                int w=pixbuf.get_width(), h=pixbuf.get_height(), ch=pixbuf.get_n_channels(), stride=pixbuf.get_rowstride();
                uint8[] data = new uint8[16+w*h*ch];
                data[0]='S'; data[1]='F'; data[2]='X'; data[3]='1';
                write_u32(data,4,w); write_u32(data,8,h); write_u32(data,12,ch);
                unowned uint8[] pixels=pixbuf.get_pixels_with_length();
                for (int y=0; y<h; y++) for (int x=0; x<w*ch; x++) data[16+y*w*ch+x]=pixels[y*stride+x];
                FileUtils.set_data(temp, data);
                if (FileUtils.rename(temp, path) != 0) { FileUtils.unlink(temp); return; }
                uint64 fresh=file_size(path); known_size = known_size >= old ? known_size-old+fresh : fresh;
                if (known_size > BYTE_BUDGET) evict();
            } catch (Error e) {
                FileUtils.unlink(temp);
                message("Could not write wallpaper effect cache %s: %s", path, e.message);
            }
        }
        private static int read_u32(uint8[] data, int offset) {
            return (int) ((uint32)data[offset] | ((uint32)data[offset+1]<<8) |
                ((uint32)data[offset+2]<<16) | ((uint32)data[offset+3]<<24));
        }
        private static void write_u32(uint8[] data, int offset, int value) {
            uint32 v=(uint32)value; data[offset]=(uint8)v; data[offset+1]=(uint8)(v>>8);
            data[offset+2]=(uint8)(v>>16); data[offset+3]=(uint8)(v>>24);
        }
        private static uint64 file_size(string path) {
            try { return File.new_for_path(path).query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null).get_size(); }
            catch (Error e) { return 0; }
        }
        private void refresh_size() {
            known_size=0;
            try { var d=File.new_for_path(cache_directory); var en=d.enumerate_children("standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null); FileInfo i;
                while ((i=en.next_file(null)) != null) if (i.get_file_type()==FileType.REGULAR) known_size += i.get_size();
            } catch (Error e) {} size_known=true;
        }
        private void evict() {
            var entries=new ArrayList<CacheFile>(); uint64 total=0;
            try { var d=File.new_for_path(cache_directory); var en=d.enumerate_children("standard::name,standard::type,standard::size,time::modified", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null); FileInfo i;
                while ((i=en.next_file(null)) != null) if (i.get_file_type()==FileType.REGULAR) { var e=new CacheFile(d.get_child(i.get_name()),i.get_size(),i.get_attribute_uint64(FileAttribute.TIME_MODIFIED)); entries.add(e); total+=e.size; }
                entries.sort((a,b)=>a.modified<b.modified ? -1 : (a.modified>b.modified ? 1 : 0));
                foreach (var e in entries) { if (total<=BYTE_BUDGET) break; try { e.file.delete(null); total-=e.size; } catch (Error err) {} }
            } catch (Error e) {} known_size=total;
        }
    }
}
