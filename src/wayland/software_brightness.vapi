[CCode (cheader_filename = "software_brightness.h")]
namespace Singularity.SoftwareBrightness {
    [CCode (cname = "SingularitySoftwareBrightnessReset", has_target = false)]
    public delegate void ResetCallback(void* data);

    [CCode (cname = "singularity_software_brightness_init")]
    public bool init(ResetCallback reset, void* data);
    [CCode (cname = "singularity_software_brightness_supported")]
    public bool supported();
    [CCode (cname = "singularity_software_brightness_set")]
    public void set(string connector, uint32 level);
}
