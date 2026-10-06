[CCode (cheader_filename = "idle_notify.h")]
namespace Singularity.IdleNotify {
    [CCode (cname = "SingularityIdleCallback", has_target = false)]
    public delegate void Callback(int id, bool idle, void* data);

    [CCode (cname = "singularity_idle_init")]
    public bool init();
    [CCode (cname = "singularity_idle_input_only_supported")]
    public bool input_only_supported();
    [CCode (cname = "singularity_output_power_supported")]
    public bool output_power_supported();
    [CCode (cname = "singularity_idle_watch")]
    public void watch(int id, uint32 timeout_ms, bool input_only, Callback callback, void* data);
    [CCode (cname = "singularity_idle_unwatch")]
    public void unwatch(int id);
    [CCode (cname = "singularity_output_power_set")]
    public void output_power_set(bool on);
}
