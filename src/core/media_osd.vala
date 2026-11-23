namespace Singularity {

    public class MediaOsd {
        private const uint SETTLE_MS = 700;

        public static void play_pause() {
            run((np) => np.play_pause.begin());
        }

        public static void next() {
            run((np) => np.next.begin());
        }

        public static void previous() {
            run((np) => np.previous.begin());
        }

        private delegate void Command(NowPlayingCache np);

        private static void run(Command command) {
            var np = NowPlayingCache.get_default();
            if (!np.active) {
                Singularity.Shell.OsdOverlay.get_default().show_osd("media-playback-stop-symbolic", -1, _("Nothing Playing"));
                return;
            }
            ulong handler = 0;
            uint timeout = 0;
            handler = np.changed.connect(() => {
                np.disconnect(handler);
                if (timeout != 0) Source.remove(timeout);
                Idle.add(() => {
                    present(np);
                    return Source.REMOVE;
                });
            });
            timeout = Timeout.add(SETTLE_MS, () => {
                timeout = 0;
                np.disconnect(handler);
                present(np);
                return Source.REMOVE;
            });
            command(np);
        }

        private static void present(NowPlayingCache np) {
            Gdk.Texture? cover = null;
            if (np.cover_path != "") {
                try {
                    cover = Gdk.Texture.from_filename(np.cover_path);
                } catch (Error e) {
                    cover = null;
                }
            }
            Singularity.Shell.OsdOverlay.get_default().show_media(cover, np.app_id, np.title, np.artist, np.playing);
        }
    }
}
