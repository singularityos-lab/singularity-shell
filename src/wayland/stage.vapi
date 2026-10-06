[CCode (cheader_filename = "stage.h")]
namespace Singularity.StageBridge {
    [CCode (cname = "singularity_stage_available")]
    public bool available();
    [CCode (cname = "singularity_stage_set_hidden")]
    public void set_hidden(void* toplevel, bool hidden, int x, int y, int width, int height);
    [CCode (cname = "singularity_stage_groups_supported")]
    public bool groups_supported();
    [CCode (cname = "singularity_stage_set_group")]
    public void set_group(void* toplevel, uint group);
    [CCode (cname = "singularity_stage_get_group")]
    public bool get_group(void* toplevel, out uint group, out bool hidden);
}
