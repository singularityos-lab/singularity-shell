[CCode (cheader_filename = "process_info.h")]
namespace Singularity.ProcessInfo {
    [CCode (cname = "singularity_process_info_available")]
    public bool available();
    [CCode (cname = "singularity_process_info_get_pid")]
    public bool get_pid(void* toplevel, out int pid, out uint source);
    [CCode (cname = "SingularityProcessInfoResumeFunc", has_target = true)]
    public delegate void ResumeFunc(void* toplevel);
    [CCode (cname = "singularity_process_info_watch_resume")]
    public bool watch_resume(ResumeFunc func);
}
