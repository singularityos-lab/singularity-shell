[CCode (cheader_filename = "key_hold.h")]
namespace Singularity.KeyHold {
    [CCode (cname = "SingularityKeyHoldCallback", has_target = false)]
    public delegate void Callback(bool started, bool cancelled, void* data);

    [CCode (cname = "singularity_key_hold_init")]
    public bool init(Callback callback, void* data);
    [CCode (cname = "singularity_key_hold_supported")]
    public bool supported();
    [CCode (cname = "singularity_key_hold_set_delay")]
    public void set_delay(uint32 delay_ms);
    [CCode (cname = "singularity_key_hold_finish")]
    public void finish();
}
