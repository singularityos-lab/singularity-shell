using GLib;
using Gdk;

namespace Singularity {

    public delegate void PreviewReadyCallback(Gdk.Texture? texture);

    private class PreviewWaiter : Object {
        public PreviewReadyCallback cb;
        public PreviewWaiter(owned PreviewReadyCallback cb) { this.cb = (owned) cb; }
    }

    public class PreviewCache : Object {
        private static PreviewCache? _instance = null;
        private Gee.HashSet<string> pending = new Gee.HashSet<string>();
        // Callbacks waiting on an in-flight capture, keyed by capture key. A
        // fast workspace switch creates a new preview for the same window while
        // the previous capture is still running; queue its callback instead of
        // dropping it, otherwise the new preview stays blank (#48).
        private Gee.HashMap<string, Gee.ArrayList<PreviewWaiter>> waiters =
            new Gee.HashMap<string, Gee.ArrayList<PreviewWaiter>>();

        public static PreviewCache get_default() {
            if (_instance == null) _instance = new PreviewCache();
            return _instance;
        }

        public void clear() {
            pending.clear();
            waiters.clear();
            // Free the compositor-side SHM buffer pool. The overview is closing,
            // so the recycled capture buffers (which labwc keeps mapped) are no
            // longer needed and would otherwise sit idle.
            Singularity.wayland_preview_pool_trim();
        }

        public void request(void* handle, int max_w, int max_h, owned PreviewReadyCallback callback) {
            debug("[PreviewCache] request: handle=%p max=%dx%d", handle, max_w, max_h);
            if (handle == null) {
                debug("[PreviewCache] null handle, skipping");
                callback(null);
                return;
            }

            string key = "%lu:%d:%d".printf((ulong)handle, max_w, max_h);
            // Capture a fresh frame every time a preview is requested, so it
            // shows the window as it looks now rather than the first frame ever
            // taken (#195). No texture is kept between requests; concurrent
            // requests for the same window still share one in-flight capture
            // through the waiter queue instead of each spawning their own.
            if (!waiters.has_key(key)) waiters[key] = new Gee.ArrayList<PreviewWaiter>();
            waiters[key].add(new PreviewWaiter((owned) callback));
            if (pending.contains(key)) return;
            pending.add(key);

            Singularity.wayland_capture_preview(handle, (w, h, s, data) => {
                pending.remove(key);
                Gdk.Texture? result = null;
                if (data == null || w <= 0 || h <= 0 || s <= 0) {
                    warning("[PreviewCache] capture failed for key %s: w=%d h=%d s=%d data=%s", key, w, h, s, data == null ? "null" : "ok");
                } else {
                    unowned uint8[] buf = (uint8[])data;
                    buf.length = h * s;
                    try {
                        result = new Gdk.MemoryTexture(w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, new Bytes(buf), s);
                    } catch (Error e) {
                        result = null;
                    }
                }
                var ws = waiters[key];
                waiters.unset(key);
                if (ws != null) {
                    foreach (var wt in ws) wt.cb(result);
                }
            });
        }
    }
}
