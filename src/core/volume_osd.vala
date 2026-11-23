namespace Singularity {

    public class VolumeOsd {
        public const string HEARING_RISK_ICON = "audio-headphones-hearing-risk-symbolic";

        public static void show(AudioManager audio) {
            string device = audio.default_sink_friendly;
            if (device == "") device = audio.headphones ? _("Headphones") : _("Speakers");
            Singularity.Shell.OsdOverlay.get_default().show_level(
                audio.headphones ? "audio-headphones" : "audio-speakers",
                audio.volume, device,
                audio.hearing_risk ? _("High volume can damage your hearing") : null,
                audio.is_muted, audio.max_volume);
        }
    }
}
