[CCode (cheader_filename = "wayland_integration.h")]
namespace Singularity {
    [CCode (has_target = false)]
    public delegate void AppOpenedCallback(void* handle, string app_id, void* data);
    [CCode (has_target = false)]
    public delegate void AppClosedCallback(void* handle, void* data);
    [CCode (has_target = false)]
    public delegate void AppFocusedCallback(void* handle, void* data);
    [CCode (has_target = false)]
    public delegate void AppTitleChangedCallback(void* handle, string title, void* data);
    [CCode (has_target = false)]
    public delegate void AppStateChangedCallback(void* handle, int is_maximized, int is_fullscreen, int is_minimized, void* data);
    
    [CCode (has_target = false)]
    public delegate void WorkspaceCreatedCallback(void* handle, string name, void* data);
    [CCode (has_target = false)]
    public delegate void WorkspaceDestroyedCallback(void* handle, void* data);
    [CCode (has_target = false)]
    public delegate void WorkspaceStateCallback(void* handle, uint32 state, void* data);

    [CCode (cname = "singularity_wayland_init", cheader_filename = "wayland_integration.h")]
    public void wayland_init(
        AppOpenedCallback opened_cb, 
        AppClosedCallback closed_cb, 
        AppFocusedCallback focused_cb,
        AppTitleChangedCallback title_cb,
        AppStateChangedCallback state_cb,
        WorkspaceCreatedCallback ws_created_cb,
        WorkspaceDestroyedCallback ws_destroyed_cb,
        WorkspaceStateCallback ws_state_cb,
        void* user_data
    );

    [CCode (cname = "singularity_wayland_activate_window", cheader_filename = "wayland_integration.h")]
    public void wayland_activate_window(void* handle);

    [CCode (cname = "singularity_wayland_show_window_pip", cheader_filename = "wayland_integration.h")]
    public bool wayland_show_window_pip(void* handle);

    [CCode (cname = "singularity_wayland_show_region_pip", cheader_filename = "wayland_integration.h")]
    public bool wayland_show_region_pip(int x, int y, int width, int height);

    [CCode (cname = "singularity_wayland_close_pip", cheader_filename = "wayland_integration.h")]
    public void wayland_close_pip();

    [CCode (cname = "singularity_wayland_activate_workspace", cheader_filename = "wayland_integration.h")]
    public void wayland_activate_workspace(void* handle);

    [CCode (cname = "singularity_wayland_get_workspace_connector", cheader_filename = "wayland_integration.h")]
    public unowned string? wayland_get_workspace_connector(void* handle);

    [CCode (cname = "singularity_wayland_get_workspace_group", cheader_filename = "wayland_integration.h")]
    public void* wayland_get_workspace_group(void* handle);

    [CCode (cname = "singularity_wayland_assign_toplevel", cheader_filename = "wayland_integration.h")]
    public void wayland_assign_toplevel(void* workspace_handle, void* toplevel_handle);
    
    [CCode (cname = "singularity_wayland_create_workspace", cheader_filename = "wayland_integration.h")]
    public void wayland_create_workspace(string name);
    
    [CCode (cname = "singularity_wayland_remove_workspace", cheader_filename = "wayland_integration.h")]
    public void wayland_remove_workspace(void* handle);

    [CCode (cname = "singularity_wayland_minimize_window", cheader_filename = "wayland_integration.h")]
    public void minimize_window(void* handle);

    [CCode (cname = "singularity_wayland_unminimize_window", cheader_filename = "wayland_integration.h")]
    public void unminimize_window(void* handle);

    [CCode (cname = "singularity_wayland_close_window", cheader_filename = "wayland_integration.h")]
    public void close_window(void* handle);

    [CCode (cname = "PreviewCallback")]
    public delegate void PreviewCallback(int width, int height, int stride, void* data);

    [CCode (cname = "singularity_wayland_capture_preview", cheader_filename = "wayland_integration.h")]
    public void wayland_capture_preview(void* toplevel_handle, owned PreviewCallback callback);

    [CCode (cname = "singularity_wayland_capture_preview_cancellable", cheader_filename = "wayland_integration.h")]
    public void* wayland_capture_preview_cancellable(void* toplevel_handle, owned PreviewCallback callback);

    [CCode (cname = "singularity_wayland_cancel_capture", cheader_filename = "wayland_integration.h")]
    public void wayland_cancel_capture(void* token);

    [CCode (cname = "singularity_wayland_preview_pool_trim", cheader_filename = "wayland_integration.h")]
    public void wayland_preview_pool_trim();

    [CCode (cname = "singularity_wayland_begin_output_config", cheader_filename = "wayland_integration.h")]
    public void wayland_begin_output_config(uint32 serial);

    [CCode (cname = "singularity_wayland_config_head", cheader_filename = "wayland_integration.h")]
    public void wayland_config_head(void* head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh);

    [CCode (cname = "singularity_wayland_config_head_v2", cheader_filename = "wayland_integration.h")]
    public void wayland_config_head_v2(void* head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh, int adaptive_sync);

    [CCode (cname = "singularity_wayland_finish_output_config", cheader_filename = "wayland_integration.h")]
    public void wayland_finish_output_config();

    [CCode (cname = "singularity_wayland_set_geometry", cheader_filename = "wayland_integration.h")]
    public void wayland_set_geometry(void* toplevel_handle, int x, int y, int width, int height);
    [CCode (cname = "singularity_wayland_set_close_gesture_progress", cheader_filename = "wayland_integration.h")]
    public void wayland_set_close_gesture_progress(void* toplevel_handle, double progress);

    [CCode (cname = "singularity_wayland_get_window_geometry", cheader_filename = "wayland_integration.h")]
    public bool wayland_get_window_geometry(void* toplevel_handle,
        out int x, out int y, out int width, out int height,
        out int maximized, out int fullscreen, out string? connector);

    [CCode (cname = "singularity_wayland_get_window_workarea", cheader_filename = "wayland_integration.h")]
    public bool wayland_get_window_workarea(void* toplevel_handle,
        out int x, out int y, out int width, out int height);

    [CCode (cname = "singularity_wayland_get_layout_workarea", cheader_filename = "wayland_integration.h")]
    public bool wayland_get_layout_workarea(out int x, out int y,
        out int width, out int height);

    [CCode (cname = "singularity_wayland_get_layout_output_count", cheader_filename = "wayland_integration.h")]
    public int wayland_get_layout_output_count();

    [CCode (cname = "singularity_wayland_get_layout_output_workarea", cheader_filename = "wayland_integration.h")]
    public bool wayland_get_layout_output_workarea(int index,
        out int x, out int y, out int width, out int height);

    [CCode (has_target = false)]
    public delegate void CursorPositionCallback(int x, int y, void* data);

    [CCode (cname = "singularity_wayland_set_cursor_position_callback", cheader_filename = "wayland_integration.h")]
    public void wayland_set_cursor_position_callback(
        CursorPositionCallback cb, void* data);

    [CCode (cname = "singularity_wayland_request_cursor_position", cheader_filename = "wayland_integration.h")]
    public bool wayland_request_cursor_position();

    [CCode (cname = "singularity_wayland_window_is_tileable", cheader_filename = "wayland_integration.h")]
    public bool wayland_window_is_tileable(void* toplevel_handle);

    [CCode (cname = "singularity_wayland_set_tiled", cheader_filename = "wayland_integration.h")]
    public void wayland_set_tiled(void* toplevel_handle, uint32 tiled);

    [CCode (cname = "singularity_wayland_set_scrolling_mode", cheader_filename = "wayland_integration.h")]
    public void wayland_set_scrolling_mode(uint32 enabled);

    [CCode (cname = "singularity_wayland_detach_tiled", cheader_filename = "wayland_integration.h")]
    public void wayland_detach_tiled(void* toplevel_handle);

    [CCode (cname = "singularity_wayland_set_tiling_drop_preview", cheader_filename = "wayland_integration.h")]
    public void wayland_set_tiling_drop_preview(int x, int y, int width,
        int height, uint32 visible);

    [CCode (cname = "singularity_wayland_snap_view", cheader_filename = "wayland_integration.h")]
    public void wayland_snap_view(void* toplevel_handle, uint32 direction);

    [CCode (cname = "singularity_wayland_move_to_workspace", cheader_filename = "wayland_integration.h")]
    public void wayland_move_to_workspace(void* toplevel_handle, uint32 workspace_index);

    [CCode (cname = "singularity_wayland_set_night_light", cheader_filename = "wayland_integration.h")]
    public void wayland_set_night_light(int temperature);

    [CCode (cname = "singularity_wayland_reset_night_light", cheader_filename = "wayland_integration.h")]
    public void wayland_reset_night_light();

    [CCode (cname = "singularity_wayland_get_window_monitor", cheader_filename = "wayland_integration.h")]
    public Gdk.Monitor? wayland_get_window_monitor(void* handle);

    [CCode (has_target = false)]
    public delegate void WindowOutputChangedCallback(void* handle, void* data);
    [CCode (cname = "singularity_wayland_set_window_output_changed_callback", cheader_filename = "wayland_integration.h")]
    public void wayland_set_window_output_changed_callback(WindowOutputChangedCallback cb, void* data);

    [CCode (has_target = false)]
    public delegate void DesktopGestureCallback(uint32 phase, uint32 fingers,
        uint32 direction,
        double dx, double dy, int cancelled, int committed, void* data);
    [CCode (cname = "singularity_wayland_set_desktop_gesture_callback", cheader_filename = "wayland_integration.h")]
    public void wayland_set_desktop_gesture_callback(DesktopGestureCallback cb, void* data);

    [CCode (cname = "singularity_wayland_toggle_desktop_reveal", cheader_filename = "wayland_integration.h")]
    public void wayland_toggle_desktop_reveal();

    [CCode (has_target = false)]
    public delegate void TilingInteractionCallback(void* handle, uint32 phase,
        uint32 kind, int x, int y, int width, int height,
        int cursor_x, int cursor_y, uint32 edges, int float_candidate,
        void* data);
    [CCode (cname = "singularity_wayland_set_tiling_interaction_callback", cheader_filename = "wayland_integration.h")]
    public void wayland_set_tiling_interaction_callback(
        TilingInteractionCallback cb, void* data);

    [CCode (cname = "singularity_wayland_list_globals", cheader_filename = "wayland_integration.h")]
    public string wayland_list_globals();

    [CCode (cname = "singularity_surface_set_input_passthrough", cheader_filename = "blur_surface.h")]
    public void surface_set_input_passthrough(Gtk.Widget widget);

    [CCode (cname = "singularity_type_text", cheader_filename = "vkbd.h")]
    public void type_text(string text);

    [CCode (cname = "singularity_osk_set_layout", cheader_filename = "osk.h")]
    public bool osk_set_layout(string layout, string variant);
    [CCode (cname = "singularity_osk_press", cheader_filename = "osk.h")]
    public void osk_press(uint evdev_code, uint modifiers);
    [CCode (cname = "singularity_osk_label", cheader_filename = "osk.h")]
    public string? osk_label(uint evdev_code, bool shifted);

    [CCode (cname = "SingularityImeKeyFunc", cheader_filename = "ime.h")]
    public delegate bool ImeKeyFunc(uint key, uint keysym, string text, bool pressed, uint modifiers);
    [CCode (cname = "SingularityImeStateFunc", cheader_filename = "ime.h")]
    public delegate void ImeStateFunc(bool active, string surrounding, uint cursor, uint purpose, uint hint);
    [CCode (cname = "SingularityImePointerFunc", cheader_filename = "ime.h")]
    public delegate void ImePointerFunc(double x, double y);
    [CCode (cname = "singularity_ime_start", cheader_filename = "ime.h")]
    public bool ime_start(ImeKeyFunc key_func, ImeStateFunc state_func, ImePointerFunc pointer_func);
    [CCode (cname = "singularity_ime_set_grab", cheader_filename = "ime.h")]
    public void ime_set_grab(bool grab);
    [CCode (cname = "singularity_ime_forward_key", cheader_filename = "ime.h")]
    public void ime_forward_key(uint key, bool pressed);
    [CCode (cname = "singularity_ime_replace", cheader_filename = "ime.h")]
    public void ime_replace(uint delete_before, uint delete_after, string? text);
    [CCode (cname = "singularity_ime_popup_show", cheader_filename = "ime.h")]
    public void ime_popup_show([CCode (array_length = false)] uint8[] pixels, int width, int height, int stride, int scale);
    [CCode (cname = "singularity_ime_popup_hide", cheader_filename = "ime.h")]
    public void ime_popup_hide();

    [CCode (cname = "singularity_xwayland_icon", cheader_filename = "xwl_icon.h")]
    public Gdk.Texture? xwayland_icon(string? app_id, string? title);

    [CCode (cname = "singularity_xwayland_active_window", cheader_filename = "xwl_icon.h")]
    public uint32 xwayland_active_window();
}
