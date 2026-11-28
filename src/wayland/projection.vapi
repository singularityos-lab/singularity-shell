[CCode (cheader_filename = "projection.h")]
namespace Singularity.ProjectionBridge {
    [CCode (cname = "singularity_projection_available")]
    public bool available();
    [CCode (cname = "singularity_projection_create")]
    public void* create(string name, int width, int height, int refresh, string form_factor, out string? output_name, out int out_width, out int out_height);
    [CCode (cname = "singularity_projection_map_touch")]
    public void map_touch(void* projection, string device_name);
    [CCode (cname = "singularity_projection_set_mode")]
    public bool set_mode(void* projection, int width, int height, int refresh);
    [CCode (cname = "singularity_projection_destroy")]
    public void destroy(void* projection);
}
