using Singularity.Widgets;

namespace Singularity {

    public class HearingRiskRow : ActionRow {
        public HearingRiskRow(AudioManager audio) {
            Object();
            title = _("High Volume");
            subtitle = _("Listening this loud on headphones for a long time can damage your hearing.");
            var icon = new Gtk.Image.from_icon_name(VolumeOsd.HEARING_RISK_ICON);
            icon.add_css_class("row-icon");
            icon.add_css_class("warning");
            add_prefix(icon);
            visible = audio.hearing_risk;
            audio.state_changed.connect(() => {
                visible = audio.hearing_risk;
            });
        }
    }
}
