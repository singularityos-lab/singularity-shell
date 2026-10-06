[CCode (cheader_filename = "snap_layouts.h")]
namespace Singularity.SnapBridge {
    [CCode (cname = "SingularitySnapEventKind", cprefix = "SINGULARITY_SNAP_EVENT_", has_type_id = false)]
    public enum EventKind {
        SHOW,
        MOTION,
        HIDE,
        DROP
    }

    [CCode (cname = "SingularitySnapEventFunc", has_target = true)]
    public delegate void EventFunc(EventKind kind, void* toplevel, uint source, int x, int y, int width, int height, int area_x, int area_y, int area_width, int area_height);

    [CCode (cname = "singularity_snap_bridge_start")]
    public bool start(EventFunc func);
    [CCode (cname = "singularity_snap_bridge_available")]
    public bool available();
    [CCode (cname = "singularity_snap_bridge_set_enabled")]
    public void set_enabled(bool enabled);
    [CCode (cname = "singularity_snap_bridge_set_picker_area")]
    public void set_picker_area(int x, int y, int width, int height);
    [CCode (cname = "singularity_snap_bridge_set_zone_preview")]
    public void set_zone_preview(int x, int y, int width, int height, bool visible);
    [CCode (cname = "singularity_snap_bridge_snap_to_zone")]
    public void snap_to_zone(void* toplevel, int ref_x, int ref_y, int x, int y, int width, int height);
}
