[CCode (cheader_filename = "motion_hints.h")]
namespace Singularity.MotionHints {
    [CCode (cname = "singularity_motion_hints_set_icon_rect")]
    public void set_icon_rect(Gtk.Widget window, string app_id, int x, int y, int width, int height);
    [CCode (cname = "singularity_motion_hints_clear")]
    public void clear(Gtk.Widget window);
    [CCode (cname = "singularity_motion_hints_launch")]
    public void launch(Gtk.Widget window, string app_id);
    [CCode (cname = "singularity_motion_hints_available")]
    public bool available(Gtk.Widget window);
}
