namespace Singularity {
    [CCode (cname = "SingularityClipboardFunc", has_target = true, cheader_filename = "clipboard_watch.h")]
    public delegate void ClipboardWatchFunc(string mime, GLib.Bytes? data, bool sensitive);

    [CCode (cname = "singularity_clipboard_watch_start", cheader_filename = "clipboard_watch.h")]
    public bool clipboard_watch_start(ClipboardWatchFunc func);

    [CCode (cname = "singularity_clipboard_watch_available", cheader_filename = "clipboard_watch.h")]
    public bool clipboard_watch_available();

    [CCode (cname = "singularity_clipboard_set", cheader_filename = "clipboard_watch.h")]
    public bool clipboard_set(string mime, GLib.Bytes data);

    [CCode (cname = "singularity_clipboard_send_paste", cheader_filename = "clipboard_watch.h")]
    public bool clipboard_send_paste();
}
