namespace Singularity.Dictation {

    [DBus (name = "dev.sinty.Dictation")]
    public class DictationBus : Object {
        public signal void partial(string path, string text);

        private static DictationBus? instance = null;

        public static void export() {
            if (instance != null) return;
            instance = new DictationBus();
            Bus.own_name(BusType.SESSION, "dev.sinty.Dictation", BusNameOwnerFlags.NONE,
                (connection) => {
                    try {
                        connection.register_object("/dev/sinty/Dictation", instance);
                    } catch (IOError e) {
                        warning("Dictation: cannot export the D-Bus object: %s", e.message);
                    }
                },
                null,
                () => warning("Dictation: cannot own dev.sinty.Dictation on the session bus"));
        }

        public async string transcribe_file(string path, string language) throws DBusError, IOError {
            var settings = new GLib.Settings("dev.sinty.desktop");
            string reason;
            var engine = EngineLocator.create(settings, out reason);
            if (engine == null) throw new DBusError.NOT_SUPPORTED(reason);
            uint8[] pcm;
            try {
                pcm = FileTranscriber.load_pcm(path);
            } catch (Error e) {
                throw new DBusError.INVALID_ARGS(e.message);
            }
            var transcriber = new FileTranscriber();
            transcriber.partial.connect((text) => partial(path, text));
            try {
                return yield transcriber.transcribe(engine, pcm, language);
            } catch (Error e) {
                throw new DBusError.FAILED(e.message);
            }
        }
    }
}
