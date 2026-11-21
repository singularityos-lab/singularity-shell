[CCode (cheader_filename = "window_card.h")]
namespace Singularity.WindowCardBridge {
    [CCode (cname = "SingularityMotionCardDone", has_target = true)]
    public delegate void Done();
    [CCode (cname = "singularity_motion_card_available")]
    public bool available();
    [CCode (cname = "singularity_motion_card_new")]
    public void* create(void* toplevel, owned Done done);
    [CCode (cname = "singularity_motion_card_set_rect")]
    public void set_rect(void* card, int x, int y, int width, int height, int radius);
    [CCode (cname = "singularity_motion_card_release")]
    public void release(void* card, bool minimize, int x, int y, int width, int height, int radius, int velocity_x, int velocity_y);
    [CCode (cname = "singularity_motion_card_free")]
    public void free(void* card);
}
