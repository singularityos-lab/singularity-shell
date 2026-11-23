namespace Singularity {

    public class VolumeOsd {
        public const string HEARING_RISK_ICON = "audio-headphones-hearing-risk-symbolic";

        private static double last_volume = -1.0;

        public static void show(AudioManager audio) {
            string device = audio.default_sink_friendly;
            if (device == "") device = audio.headphones ? _("Headphones") : _("Speakers");
            string icon = "audio-volume-high";
            if (audio.is_muted) icon = "audio-volume-muted";
            else if (last_volume >= 0.0 && audio.volume < last_volume) icon = "audio-volume-low";
            last_volume = audio.volume;
            Singularity.Shell.OsdOverlay.get_default().show_level(icon,
                audio.volume, device,
                audio.hearing_risk ? _("High volume can damage your hearing") : null,
                audio.is_muted, audio.max_volume);
        }
    }
}
