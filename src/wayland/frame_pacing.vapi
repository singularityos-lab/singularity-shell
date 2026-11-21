[CCode (cheader_filename = "frame_pacing.h")]
namespace Singularity.FramePacingBridge {
    [CCode (cname = "singularity_frame_pacing_init")]
    public bool init();
    [CCode (cname = "singularity_frame_pacing_set")]
    public void set(string connector, uint32 rate);
}
