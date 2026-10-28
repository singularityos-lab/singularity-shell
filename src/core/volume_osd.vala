namespace Singularity {

    public class VolumeOsd {
        public const string HEARING_RISK_ICON = "audio-headphones-hearing-risk-symbolic";

        public static void show(AudioManager audio) {
            var osd = Singularity.Shell.OsdOverlay.get_default();
            if (audio.is_muted) {
                osd.show_osd(audio.icon_name, -1);
            } else if (audio.hearing_risk) {
                osd.show_osd(HEARING_RISK_ICON, audio.volume, _("High volume can damage your hearing"));
            } else {
                osd.show_osd(audio.icon_name, audio.volume);
            }
        }
    }
}
