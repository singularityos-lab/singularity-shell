namespace Singularity {

    public class ShellMediaStreamControl : Object, MediaStreamControl {
        private AudioManager audio;

        public ShellMediaStreamControl(AudioManager audio) {
            this.audio = audio;
            audio.mixer_changed.connect(() => streams_changed());
        }

        public bool find_streams(int pid, string[] hints, out bool muted) {
            return audio.find_streams(pid, hints, out muted);
        }

        public void set_streams_muted(int pid, string[] hints, bool muted) {
            audio.set_streams_muted(pid, hints, muted);
        }
    }

    public class MediaPlaybackGuard : Object {
        private DBusConnection? bus = null;
        private GLib.Settings settings = new GLib.Settings("dev.sinty.desktop");

        public MediaPlaybackGuard() {
            start.begin();
        }

        private async void start() {
            try {
                bus = yield Bus.get(BusType.SESSION);
            } catch (Error e) {
                return;
            }
            bus.signal_subscribe(null, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", DBusSignalFlags.NONE,
                (conn, sender, path, iface, member, parameters) => {
                    var status = parameters.get_child_value(1).lookup_value("PlaybackStatus", VariantType.STRING);
                    if (status != null && status.get_string() == "Playing"
                            && settings.get_boolean("media-exclusive-playback")) {
                        pause_others.begin(sender);
                    }
                });
        }

        private async void pause_others(string playing_owner) {
            try {
                var names = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListNames", null, new VariantType("(as)"),
                    DBusCallFlags.NONE, 1000, null);
                foreach (string name in names.get_child_value(0).get_strv()) {
                    if (!name.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    try {
                        var owner = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                            "org.freedesktop.DBus", "GetNameOwner", new Variant("(s)", name),
                            new VariantType("(s)"), DBusCallFlags.NONE, 500, null);
                        if (owner.get_child_value(0).get_string() == playing_owner) continue;
                        var status = yield bus.call(name, "/org/mpris/MediaPlayer2",
                            "org.freedesktop.DBus.Properties", "Get",
                            new Variant("(ss)", "org.mpris.MediaPlayer2.Player", "PlaybackStatus"),
                            new VariantType("(v)"), DBusCallFlags.NONE, 500, null);
                        if (status.get_child_value(0).get_variant().get_string() != "Playing") continue;
                        yield bus.call(name, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player",
                            "Pause", null, null, DBusCallFlags.NONE, 1000, null);
                    } catch (Error e) {}
                }
            } catch (Error e) {}
        }
    }
}
