project('singularity-shell', ['vala', 'c'],
  version: '0.1.0',
  default_options: ['buildtype=release', 'strip=true'],
)
add_project_arguments('-DGETTEXT_PACKAGE="singularity-desktop"', language: 'c')
add_project_arguments('-D_GNU_SOURCE', language: 'c')
add_project_arguments([
  '-DSINGULARITY_SHELL_LIBEXECDIR="@0@"'.format(get_option('prefix') / get_option('libexecdir')),
  '-DSINGULARITY_SHELL_DATADIR="@0@"'.format(get_option('prefix') / get_option('datadir')),
], language: 'c')
add_project_arguments([
  '-DGNOME_DESKTOP_USE_UNSTABLE_API',
], language: 'c')
add_project_arguments([
  '--vapidir', join_paths(meson.current_source_dir(), 'src/vapi'),
  '--vapidir', join_paths(meson.current_source_dir(), 'src/wayland'),
  '--pkg=posix',
  '--pkg=poppler-glib',
  '--pkg=gtksourceview-5',
], language: 'vala')

if get_option('buildtype').startswith('release')
  add_project_arguments(['-ffunction-sections', '-fdata-sections'], language: 'c')
endif

core_deps = [
  dependency('gtk4', version: '>= 4.10'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('vte-2.91-gtk4'),
]

shell_deps = [
  dependency('gtk4-layer-shell-0'),
  dependency('poppler-glib'),
  dependency('gtksourceview-5'),
  dependency('wayland-client'),
  meson.get_compiler('c').find_library('xkbcommon'),
  dependency('libnm', version: '>= 1.0.0'),
  dependency('upower-glib', version: '>= 0.99.0'),
  dependency('libpulse'),
  dependency('libpulse-mainloop-glib'),
  dependency('polkit-gobject-1'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0'),
  dependency('libpeas-2'),
  dependency('dbusmenu-glib-0.4'),
  dependency('atspi-2'),
  dependency('tracker-sparql-3.0'),
  dependency('gudev-1.0'),
]

dependencies = core_deps + shell_deps
cc = meson.get_compiler('c')
polkit_agent_dep = cc.find_library('polkit-agent-1', dirs: ['/usr/lib/x86_64-linux-gnu', '/usr/lib'])
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')

wayland_scanner = find_program('wayland-scanner')
wl_proto_xml = 'protocols/wlr-foreign-toplevel-management-unstable-v1.xml'
wl_proto_c = custom_target(
  'wlr-foreign-toplevel-management-unstable-v1-protocol.c',
  output: 'wlr-foreign-toplevel-management-unstable-v1-protocol.c',
  input: wl_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
wl_proto_h = custom_target(
  'wlr-foreign-toplevel-management-unstable-v1-client-protocol.h',
  output: 'wlr-foreign-toplevel-management-unstable-v1-client-protocol.h',
  input: wl_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
om_proto_xml = 'protocols/wlr-output-management-unstable-v1.xml'
om_proto_c = custom_target(
  'wlr-output-management-unstable-v1-protocol.c',
  output: 'wlr-output-management-unstable-v1-protocol.c',
  input: om_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
om_proto_h = custom_target(
  'wlr-output-management-unstable-v1-client-protocol.h',
  output: 'wlr-output-management-unstable-v1-client-protocol.h',
  input: om_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
ws_proto_xml = 'protocols/ext-workspace-v1.xml'
ws_proto_c = custom_target(
  'ext-workspace-v1-protocol.c',
  output: 'ext-workspace-v1-protocol.c',
  input: ws_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
ws_proto_h = custom_target(
  'ext-workspace-v1-client-protocol.h',
  output: 'ext-workspace-v1-client-protocol.h',
  input: ws_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
sp_proto_xml = 'protocols/singularity-preview-unstable-v1.xml'
sp_proto_c = custom_target(
  'singularity-preview-unstable-v1-protocol.c',
  output: 'singularity-preview-unstable-v1-protocol.c',
  input: sp_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
sp_proto_h = custom_target(
  'singularity-preview-unstable-v1-client-protocol.h',
  output: 'singularity-preview-unstable-v1-client-protocol.h',
  input: sp_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
stg_proto_xml = 'protocols/singularity-stage-unstable-v1.xml'
stg_proto_c = custom_target(
  'singularity-stage-unstable-v1-protocol.c',
  output: 'singularity-stage-unstable-v1-protocol.c',
  input: stg_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
stg_proto_h = custom_target(
  'singularity-stage-unstable-v1-client-protocol.h',
  output: 'singularity-stage-unstable-v1-client-protocol.h',
  input: stg_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
proc_proto_xml = 'protocols/singularity-process-unstable-v1.xml'
proc_proto_c = custom_target(
  'singularity-process-unstable-v1-protocol.c',
  output: 'singularity-process-unstable-v1-protocol.c',
  input: proc_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
proc_proto_h = custom_target(
  'singularity-process-unstable-v1-client-protocol.h',
  output: 'singularity-process-unstable-v1-client-protocol.h',
  input: proc_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
mo_proto_xml = 'protocols/singularity-motion-unstable-v1.xml'
mo_proto_c = custom_target(
  'singularity-motion-unstable-v1-protocol.c',
  output: 'singularity-motion-unstable-v1-protocol.c',
  input: mo_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
mo_proto_h = custom_target(
  'singularity-motion-unstable-v1-client-protocol.h',
  output: 'singularity-motion-unstable-v1-client-protocol.h',
  input: mo_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
pip_proto_xml = 'protocols/singularity-pip-unstable-v1.xml'
pip_proto_c = custom_target(
  'singularity-pip-unstable-v1-protocol.c',
  output: 'singularity-pip-unstable-v1-protocol.c',
  input: pip_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
pip_proto_h = custom_target(
  'singularity-pip-unstable-v1-client-protocol.h',
  output: 'singularity-pip-unstable-v1-client-protocol.h',
  input: pip_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
gc_proto_xml = 'protocols/wlr-gamma-control-unstable-v1.xml'
gc_proto_c = custom_target(
  'wlr-gamma-control-unstable-v1-protocol.c',
  output: 'wlr-gamma-control-unstable-v1-protocol.c',
  input: gc_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
gc_proto_h = custom_target(
  'wlr-gamma-control-unstable-v1-client-protocol.h',
  output: 'wlr-gamma-control-unstable-v1-client-protocol.h',
  input: gc_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
st_proto_xml = 'protocols/singularity-tiling-unstable-v1.xml'
st_proto_c = custom_target(
  'singularity-tiling-unstable-v1-protocol.c',
  output: 'singularity-tiling-unstable-v1-protocol.c',
  input: st_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
st_proto_h = custom_target(
  'singularity-tiling-unstable-v1-client-protocol.h',
  output: 'singularity-tiling-unstable-v1-client-protocol.h',
  input: st_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
sg_proto_xml = 'protocols/singularity-gesture-unstable-v1.xml'
sg_proto_c = custom_target(
  'singularity-gesture-unstable-v1-protocol.c',
  output: 'singularity-gesture-unstable-v1-protocol.c',
  input: sg_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
sg_proto_h = custom_target(
  'singularity-gesture-unstable-v1-client-protocol.h',
  output: 'singularity-gesture-unstable-v1-client-protocol.h',
  input: sg_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
sc_proto_xml = 'protocols/wlr-screencopy-unstable-v1.xml'
sc_proto_c = custom_target(
  'wlr-screencopy-unstable-v1-protocol.c',
  output: 'wlr-screencopy-unstable-v1-protocol.c',
  input: sc_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
sc_proto_h = custom_target(
  'wlr-screencopy-unstable-v1-client-protocol.h',
  output: 'wlr-screencopy-unstable-v1-client-protocol.h',
  input: sc_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
xo_proto_xml = 'protocols/xdg-output-unstable-v1.xml'
xo_proto_c = custom_target(
  'xdg-output-unstable-v1-protocol.c',
  output: 'xdg-output-unstable-v1-protocol.c',
  input: xo_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
xo_proto_h = custom_target(
  'xdg-output-unstable-v1-client-protocol.h',
  output: 'xdg-output-unstable-v1-client-protocol.h',
  input: xo_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
eftl_proto_xml = 'protocols/ext-foreign-toplevel-list-v1.xml'
eftl_proto_c = custom_target(
  'ext-foreign-toplevel-list-v1-protocol.c',
  output: 'ext-foreign-toplevel-list-v1-protocol.c',
  input: eftl_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
eftl_proto_h = custom_target(
  'ext-foreign-toplevel-list-v1-client-protocol.h',
  output: 'ext-foreign-toplevel-list-v1-client-protocol.h',
  input: eftl_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
eis_proto_xml = 'protocols/ext-image-capture-source-v1.xml'
eis_proto_c = custom_target(
  'ext-image-capture-source-v1-protocol.c',
  output: 'ext-image-capture-source-v1-protocol.c',
  input: eis_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
eis_proto_h = custom_target(
  'ext-image-capture-source-v1-client-protocol.h',
  output: 'ext-image-capture-source-v1-client-protocol.h',
  input: eis_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
eic_proto_xml = 'protocols/ext-image-copy-capture-v1.xml'
eic_proto_c = custom_target(
  'ext-image-copy-capture-v1-protocol.c',
  output: 'ext-image-copy-capture-v1-protocol.c',
  input: eic_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
eic_proto_h = custom_target(
  'ext-image-copy-capture-v1-client-protocol.h',
  output: 'ext-image-copy-capture-v1-client-protocol.h',
  input: eic_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
sl_proto_xml = 'protocols/ext-session-lock-v1.xml'
sl_proto_c = custom_target(
  'ext-session-lock-v1-protocol.c',
  output: 'ext-session-lock-v1-protocol.c',
  input: sl_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
sl_proto_h = custom_target(
  'ext-session-lock-v1-client-protocol.h',
  output: 'ext-session-lock-v1-client-protocol.h',
  input: sl_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
vk_proto_xml = 'protocols/virtual-keyboard-unstable-v1.xml'
vk_proto_c = custom_target(
  'virtual-keyboard-unstable-v1-protocol.c',
  output: 'virtual-keyboard-unstable-v1-protocol.c',
  input: vk_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
vk_proto_h = custom_target(
  'virtual-keyboard-unstable-v1-client-protocol.h',
  output: 'virtual-keyboard-unstable-v1-client-protocol.h',
  input: vk_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
dc_proto_xml = 'protocols/ext-data-control-v1.xml'
dc_proto_c = custom_target(
  'ext-data-control-v1-protocol.c',
  output: 'ext-data-control-v1-protocol.c',
  input: dc_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
dc_proto_h = custom_target(
  'ext-data-control-v1-client-protocol.h',
  output: 'ext-data-control-v1-client-protocol.h',
  input: dc_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
im_proto_xml = 'protocols/input-method-unstable-v2.xml'
im_proto_c = custom_target(
  'input-method-unstable-v2-protocol.c',
  output: 'input-method-unstable-v2-protocol.c',
  input: im_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
im_proto_h = custom_target(
  'input-method-unstable-v2-client-protocol.h',
  output: 'input-method-unstable-v2-client-protocol.h',
  input: im_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
idle_proto_xml = 'protocols/ext-idle-notify-v1.xml'
idle_proto_c = custom_target(
  'ext-idle-notify-v1-protocol.c',
  output: 'ext-idle-notify-v1-protocol.c',
  input: idle_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
idle_proto_h = custom_target(
  'ext-idle-notify-v1-client-protocol.h',
  output: 'ext-idle-notify-v1-client-protocol.h',
  input: idle_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)
op_proto_xml = 'protocols/wlr-output-power-management-unstable-v1.xml'
op_proto_c = custom_target(
  'wlr-output-power-management-unstable-v1-protocol.c',
  output: 'wlr-output-power-management-unstable-v1-protocol.c',
  input: op_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
op_proto_h = custom_target(
  'wlr-output-power-management-unstable-v1-client-protocol.h',
  output: 'wlr-output-power-management-unstable-v1-client-protocol.h',
  input: op_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)

kh_proto_xml = 'protocols/singularity-key-hold-unstable-v1.xml'
kh_proto_c = custom_target(
  'singularity-key-hold-unstable-v1-protocol.c',
  output: 'singularity-key-hold-unstable-v1-protocol.c',
  input: kh_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
kh_proto_h = custom_target(
  'singularity-key-hold-unstable-v1-client-protocol.h',
  output: 'singularity-key-hold-unstable-v1-client-protocol.h',
  input: kh_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)

snap_proto_xml = 'protocols/singularity-snap-unstable-v1.xml'
snap_proto_c = custom_target(
  'singularity-snap-unstable-v1-protocol.c',
  output: 'singularity-snap-unstable-v1-protocol.c',
  input: snap_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
snap_proto_h = custom_target(
  'singularity-snap-unstable-v1-client-protocol.h',
  output: 'singularity-snap-unstable-v1-client-protocol.h',
  input: snap_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)
system_dep = dependency('singularity-system-1.0',
  fallback: ['libsingularity', 'libsingularity_system_dep']
)
loginui_dep = dependency('singularity-loginui',
  fallback: ['singularity-loginui', 'loginui_dep']
)
if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

singularity_core_sources = files(
    'src/components/panel/panel.vala',
    'src/components/workspace_switch_feedback.vala',
    'src/core/bar_layout.vala',
    'src/core/bar_layout_edit_controller.vala',
    'src/core/bar_layout_edit_overlay.vala',
    'src/core/dbus_menu_adapter.vala',
    'src/core/atspi_menu_provider.vala',
    'src/core/gtk_actions_menu_provider.vala',
    'src/core/xdg_user_dirs.vala',
    'src/core/app_system.vala',
    'src/core/os_identity.vala',
    'src/core/compositor_backend.vala',
    'src/core/system_monitor.vala',
    'src/core/preview_cache.vala',
    'src/core/extreme_mode_manager.vala',
    'src/core/wallpaper_manager.vala',
    'src/core/dynamic_wallpaper.vala',
    'src/core/dynamic_wallpaper_heic.vala',
    'src/core/dynamic_wallpaper_controller.vala',
    'src/core/wallpaper_collections.vala',
    'src/core/wallpaper_gallery.vala',
    'src/core/wallpaper_rotation_state.vala',
    'src/core/wallpaper_rotator.vala',
    'src/core/artist_pack_manager.vala',
    'src/core/wallpaper_sidecar.vala',
    'src/core/wallpaper_browse_cache.vala',
    'src/core/wallpaper_thumbnail_cache.vala',
    'src/core/wallpaper_provider.vala',
    'src/core/settings_safety.vala',
    'src/core/wayland_gamma_backend.vala',
    'src/core/shortcut_manager.vala',
    'src/core/xsettings_daemon.vala',
    'src/core/process_terminator.vala',
    'src/core/ush_portal.vala',
    'src/core/screenshot_portal.vala',
    'src/core/screenshot_tool.vala',
    'src/core/screenshot_thumbnail.vala',
    'src/core/screen_recorder.vala',
    'src/components/panel/recording_indicator.vala',
    'src/components/panel/screen_sharing_indicator.vala',
    'src/components/panel/nearby_indicator.vala',
    'src/core/plugin_manager.vala',
    'src/components/dock/dock.vala',
    'src/components/dock/dock_motion_hints.vala',
    'src/components/dock/dock_magnifier.vala',
    'src/components/dock/dock_sharp_icon.vala',
    'src/components/dock/dock_launch_feedback.vala',
    'src/components/dock/update_indicator.vala',
    'src/components/dock/dock_resources.vala',
    'src/components/dock/dock_dbus_service.vala',
    'src/components/background/background.vala',
    'src/components/sidebar/sidebar.vala',
    'src/components/sidebar/settings_window.vala',
    'src/components/sidebar/widgets/settings_widgets.vala',
    'src/components/sidebar/widgets/fan_widgets.vala',
    'src/components/sidebar/widgets/developer_page.vala',
    'src/components/sidebar/widgets/settings_subpages.vala',
    'src/components/sidebar/pages/dev_settings_editor_page.vala',
    'src/components/sidebar/pages/dev_dbus_page.vala',
    'src/components/sidebar/pages/dev_profiler_page.vala',
    'src/components/sidebar/pages/dev_oauth_clients_page.vala',
    'src/components/preview/preview_dialog.vala',
    'src/core/preview_manager.vala',
    'src/components/desktop/desktop_icons.vala',
    'src/components/notifications/notification_display.vala',
    'src/components/notifications/notification_center.vala',
    'src/components/notifications/swipe_dismiss.vala',
    'src/core/notification_manager.vala',
    'src/core/notifications/notification_rules.vala',
    'src/core/notifications/notification_history.vala',
    'src/core/notifications/app_notification_settings.vala',
    'src/core/notifications/notification_sound.vala',
    'src/core/notifications/notification_lock_service.vala',
    'src/core/focus/focus_model.vala',
    'src/core/focus/focus_manager.vala',
    'src/core/focus/focus_contacts.vala',
    'src/components/sidebar/pages/notification_settings_page.vala',
    'src/components/sidebar/pages/focus_mode_page.vala',
    'src/components/sidebar/views/focus_quick_tile.vala',
    'src/core/stage/stage_model.vala',
    'src/core/stage/stage_manager.vala',
    'src/core/stage/stage_service.vala',
    'src/components/stage/stage_strip.vala',
    'src/core/clipboard/clipboard_model.vala',
    'src/core/clipboard/clipboard_history.vala',
    'src/core/clipboard/clipboard_plugin_migration.vala',
    'src/core/plugins/pomodoro_plugin_migration.vala',
    'src/core/nearby_bridge.vala',
    'src/components/clipboard/clipboard_popup.vala',
    'src/components/sidebar/pages/clipboard_settings_page.vala',
    'src/components/sidebar/views/system_view.vala',
    'src/components/sidebar/views/power_confirm_dialog.vala',
    'src/components/sidebar/views/settings_view.vala',
    'src/components/sidebar/pages/network_page.vala',
    'src/components/sidebar/pages/sharing_page.vala',
    'src/components/sidebar/pages/sharing_detail_pages.vala',
    'src/components/sidebar/pages/firewall_page.vala',
    'src/components/sidebar/pages/desktop_page.vala',
    'src/components/sidebar/pages/dynamic_wallpaper_group.vala',
    'src/components/sidebar/pages/wallpaper_provider_browser.vala',
    'src/components/sidebar/pages/provider_credential_group.vala',
    'src/components/sidebar/pages/sound_page.vala',
    'src/components/sidebar/pages/equalizer_page.vala',
    'src/components/sidebar/pages/keyboard_page.vala',
    'src/components/sidebar/pages/accessibility_page.vala',
    'src/components/sidebar/pages/screen_reader_page.vala',
    'src/components/sidebar/pages/apps_page.vala',
    'src/components/sidebar/pages/autostart_page.vala',
    'src/components/sidebar/pages/permission_rows.vala',
    'src/components/sidebar/pages/app_permissions_page.vala',
    'src/components/sidebar/pages/privacy_page.vala',
    'src/components/sidebar/pages/privacy_category_page.vala',
    'src/components/sidebar/widgets/background_apps_group.vala',
    'src/components/sidebar/pages/app_details_page.vala',
    'src/components/sidebar/pages/default_apps_page.vala',
    'src/components/sidebar/pages/calendar_page.vala',
    'src/components/sidebar/pages/notifications_page.vala',
    'src/components/sidebar/pages/accounts_page.vala',
    'src/components/sidebar/pages/system_page.vala',
    'src/components/sidebar/pages/users_page.vala',
    'src/components/sidebar/pages/parental_controls_page.vala',
    'src/components/sidebar/pages/parental_subpages.vala',
    'src/components/sidebar/pages/screen_time_page.vala',
    'src/components/sidebar/pages/wellbeing_page.vala',
    'src/components/sidebar/pages/plugins_page.vala',
    'src/components/sidebar/pages/plugin_details_page.vala',
    'src/components/sidebar/pages/performance_page.vala',
    'src/components/sidebar/pages/updates_page.vala',
    'src/components/sidebar/pages/update_history_page.vala',
    'src/components/sidebar/pages/automatic_updates_page.vala',
    'src/components/sidebar/pages/firmware_page.vala',
    'src/components/sidebar/pages/device_security_page.vala',
    'src/core/userspace_drivers.vala',
    'src/core/updates_scheduler.vala',
    'src/core/display_manager.vala',
    'src/core/display_color.vala',
    'src/core/tablet/tablet_model.vala',
    'src/core/tablet/tablet_manager.vala',
    'src/components/sidebar/pages/tablet_page.vala',
    'src/core/lid_manager.vala',
    'src/core/idle_inhibitors.vala',
    'src/core/idle_manager.vala',
    'src/core/parental/screen_time_tracker.vala',
    'src/core/parental/parental_enforcer.vala',
    'src/core/power_key_manager.vala',
    'src/components/sidebar/pages/power_page.vala',
    'src/wayland/idle_notify.c',
    'src/wayland/idle_notify.vapi',
    'src/wayland/key_hold.c',
    'src/wayland/key_hold.vapi',
    'src/core/shortcut_cheatsheet_model.vala',
    'src/core/app_accels_reader.vala',
    'src/components/shortcut_cheatsheet/shortcut_cheatsheet.vala',
    'src/core/hot_corner_manager.vala',
    'src/core/safe_mode.vala',
    'src/core/hand_control_manager.vala',
    'src/core/layer_window.vala',
    'src/core/monitor_osd.vala',
    'src/core/accessibility_feedback.vala',
    'src/core/system_components.vala',
    'src/core/debug_manager.vala',
    'src/core/debug_hud_window.vala',
    'src/core/devtools/dev_panel.vala',
    'src/core/devtools/devtools_inspector.vala',
    'src/core/devtools/devtools_overlay.vala',
    'src/core/shell_surface_host.vala',
    'src/core/tiling_manager.vala',
    'src/components/displays/monitor_preview.vala',
    'src/components/displays/scale_chooser.vala',
    'src/components/sidebar/pages/displays_page.vala',
    'src/components/sidebar/pages/display_color_page.vala',
    'src/components/sidebar/pages/night_light_page.vala',
    'src/components/sidebar/pages/datetime_page.vala',
    'src/components/sidebar/pages/region_page.vala',
  'src/components/sidebar/pages/text_recognition_page.vala',
    'src/components/sidebar/pages/bluetooth_page.vala',
    'src/components/sidebar/pages/add_input_source_page.vala',
    'src/components/sidebar/pages/custom_shortcut_page.vala',
    'src/components/sidebar/pages/add_account_page.vala',
    'src/components/sidebar/pages/account_detail_page.vala',
    'src/components/sidebar/pages/printers_page.vala',
    'src/components/sidebar/pages/connected_devices_page.vala',
    'src/components/sidebar/pages/nearby_device_page.vala',
    'src/components/sidebar/pages/nearby_bluetooth_group.vala',
    'src/components/sidebar/pages/add_printer_page.vala',
    'src/components/sidebar/pages/printer_detail_page.vala',
    'src/components/sidebar/sidebar_wait.vala',
    'src/components/sidebar/sidebar_width.vala',
    'src/shared/widgets/password_dialog.vala',
    'src/components/sidebar/pages/vpn_config_page.vala',
    'src/shared/edit_themes.vala',
    'src/components/calendar/calendar_view.vala',
    'src/core/session_recovery.vala',
    'src/components/sidebar/views/session_restore_dialog.vala',
    'src/components/overview/overview.vala',
    'src/components/overview/app_menu.vala',
    'src/components/overview/app_launcher_grid.vala',
    'src/components/overview/app_folder_button.vala',
    'src/components/overview/app_menu_list.vala',
    'src/components/overview/app_folder_overlay.vala',
    'src/components/overview/search_result_row.vala',
    'src/components/overview/workspace_overview.vala',
    'src/components/run_dialog/run_dialog.vala',
    'src/components/emoji_picker/emoji_picker.vala',
    'src/components/app_switcher/app_switcher.vala',
    'src/core/search/search_manager.vala',
    'src/core/search/search_round.vala',
    'src/core/search/providers/app_provider.vala',
    'src/core/search/providers/file_search_provider.vala',
    'src/core/search/providers/remote_search_provider.vala',
    'src/core/search/providers/math_provider.vala',
    'src/wayland/wayland_integration.c',
    'src/wayland/wayland_integration.vapi',
    'src/wayland/blur_surface.c',
    'src/wayland/motion_hints.c',
    'src/wayland/motion_hints.vapi',
    'src/wayland/stage.c',
    'src/wayland/stage.vapi',
    'src/wayland/process_info.c',
    'src/wayland/process_info.vapi',
    'src/wayland/vkbd.c',
    'src/wayland/clipboard_watch.c',
    'src/wayland/clipboard_watch.vapi',
    'src/wayland/osk.c',
    'src/wayland/ime.c',
    'src/core/input_method_service.vala',
    'src/core/input_method/input_engine.vala',
    'src/core/input_method/ibus_framework.vala',
    'src/core/input_method/fcitx_framework.vala',
    'src/core/input_method/input_sources.vala',
    'src/core/input_method/ime_popup.vala',
    'src/core/dictation/dictation_text.vala',
    'src/core/dictation/dictation_engine.vala',
    'src/core/dictation/dictation_models.vala',
    'src/core/dictation/dictation_audio.vala',
    'src/core/dictation/dictation_service.vala',
    'src/core/dictation/dictation_bus.vala',
    'src/components/panel/input_indicator.vala',
    'src/components/sidebar/pages/input_methods_page.vala',
    'src/components/sidebar/pages/dictation_page.vala',
    'src/core/accent_table.vala',
    'src/core/login_screen_sync.vala',
    'src/core/media_stream_control.vala',
    'src/core/event_reminders.vala',
    'src/core/account_alerts.vala',
    'src/core/fingerprint_manager.vala',
    'src/core/fingerprint_driver.vala',
    'src/components/osk/on_screen_keyboard.vala',
    'src/core/crash/crash_report.vala',
    'src/core/crash/crash_config.vala',
    'src/core/crash/crash_sources.vala',
    'src/core/crash/crash_reporter.vala',
    'src/components/crash/crash_details_window.vala',
    'src/components/sidebar/pages/crash_reports_group.vala',
    'src/wayland/xwl_icon.c',
    'src/core/snap/snap_layout_model.vala',
    'src/core/snap/snap_controller.vala',
    'src/components/snap/snap_picker.vala',
    'src/components/snap/snap_assist.vala',
    'src/wayland/snap_layouts.c',
    'src/wayland/snap_layouts.vapi',
)

subdir('src/lockscreen')

executable('singularity-desktop',
  sources: ['src/core/main.vala'] + singularity_core_sources + [
    wl_proto_c, wl_proto_h, ws_proto_c, ws_proto_h, sp_proto_c, sp_proto_h, pip_proto_c, pip_proto_h, om_proto_c, om_proto_h, st_proto_c, st_proto_h, sg_proto_c, sg_proto_h, gc_proto_c, gc_proto_h, vk_proto_c, vk_proto_h, dc_proto_c, dc_proto_h, im_proto_c, im_proto_h, idle_proto_c, idle_proto_h, op_proto_c, op_proto_h, mo_proto_c, mo_proto_h, stg_proto_c, stg_proto_h, proc_proto_c, proc_proto_h, kh_proto_c, kh_proto_h, snap_proto_c, snap_proto_h
  ],
  dependencies: dependencies + [libsingularity_dep, system_dep, gee_dep, json_dep, cc.find_library('m'), cc.find_library('crypt'), dependency('xcb')],
  include_directories: [
    include_directories('src'),
    include_directories('src/core'),
    include_directories('src/components/background'),
    include_directories('src/components/dock'),
    include_directories('src/components/overview'),
    include_directories('src/components/panel'),
    include_directories('src/components/sidebar'),
    include_directories('src/components/sidebar/widgets'),
    include_directories('src/shared/widgets'),
    include_directories('src/wayland'),
    include_directories('.')
  ],
  export_dynamic: true,
  install: true
)

executable('singularity-region-picker',
  sources: ['src/tools/region-picker/main.vala'],
  dependencies: dependencies,
  install: true
)
executable('singularity-markup',
  sources: ['src/tools/markup/main.vala'],
  dependencies: dependencies + [libsingularity_dep, gee_dep],
  install: true
)
install_data('data/dictation/dictation-models.json',
  install_dir: get_option('datadir') / 'singularity')
install_data('data/dictation/singularity-dictation-vosk',
  install_dir: get_option('libexecdir'),
  install_mode: 'rwxr-xr-x')

dictation_text_test = executable('dictation-text-test',
  sources: ['src/core/dictation/dictation_text.vala', 'tests/dictation_text_test.vala'],
  dependencies: [dependency('gobject-2.0')],
)
test('dictation-text', dictation_text_test)

dictation_engine_test = executable('dictation-engine-test',
  sources: ['src/core/dictation/dictation_engine.vala', 'src/core/dictation/dictation_models.vala',
            'tests/dictation_engine_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), dependency('json-glib-1.0'),
                 dependency('libsoup-3.0'), cc.find_library('m')],
  vala_args: ['--pkg=posix'],
)
test('dictation-engine', dictation_engine_test, env: ['DICTATION_TEST_DIR=' + meson.current_build_dir() / 'dictation-test',
  'DICTATION_SOURCE_DIR=' + meson.current_source_dir()])

input_engine_test = executable('input-engine-test',
  sources: ['src/core/input_method/input_engine.vala', 'tests/input_engine_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0')],
)
test('input-engine', input_engine_test)

install_data('data/markup/dev.sinty.markup.desktop',
  install_dir: get_option('datadir') / 'applications')
executable('singularity-keyboard-reset',
  sources: ['src/tools/keyboard-reset/main.vala'],
  dependencies: dependencies,
  install: true
)
executable('singularity-screenshot',
  sources: ['src/tools/screenshot/main.c', sc_proto_c, sc_proto_h, xo_proto_c, xo_proto_h,
            eftl_proto_c, eftl_proto_h, eis_proto_c, eis_proto_h, eic_proto_c, eic_proto_h],
  dependencies: [
    dependency('wayland-client'),
    dependency('libpng'),
  ],
  include_directories: [include_directories('.')],
  install: true
)

executable('singularity-recorder',
  sources: ['src/tools/recorder/main.vala', 'src/tools/recorder/recorder_plan.vala'],
  dependencies: [
    dependency('gio-2.0'),
    dependency('gio-unix-2.0'),
    dependency('gstreamer-1.0'),
    json_dep,
    cc.find_library('m'),
  ],
  install: true
)

recorder_plan_test = executable('recorder-plan-test',
  sources: ['src/tools/recorder/recorder_plan.vala', 'tests/recorder_plan_test.vala'],
  dependencies: [dependency('gobject-2.0'), cc.find_library('m')],
)
test('recorder-plan', recorder_plan_test)

os_identity_test = executable('os-identity-test',
  sources: ['src/core/os_identity.vala', 'tests/os_identity_test.vala'],
  dependencies: [dependency('gobject-2.0')],
)
test('os-identity', os_identity_test)

update_indicator_test = executable('update-indicator-test',
  sources: ['src/components/dock/update_indicator.vala', 'tests/update_indicator_test.vala'],
  dependencies: core_deps + [json_dep],
)
test('update-indicator', update_indicator_test)

bar_layout_test = executable('bar-layout-test',
  sources: ['src/core/bar_layout.vala', 'tests/bar_layout_test.vala'],
  dependencies: [dependency('gobject-2.0'), gee_dep],
)
test('bar-layout', bar_layout_test)

tablet_model_test = executable('tablet-model-test',
  sources: ['src/core/tablet/tablet_model.vala', 'tests/tablet_model_test.vala'],
  dependencies: [dependency('gobject-2.0'), gee_dep],
)
test('tablet-model', tablet_model_test)

safe_mode_test = executable('safe-mode-test',
  sources: ['src/core/safe_mode.vala', 'tests/safe_mode_test.vala'],
  dependencies: [dependency('gobject-2.0')],
)
test('safe-mode', safe_mode_test)

xsettings_daemon_test = executable('xsettings-daemon-test',
  sources: ['src/core/xsettings_daemon.vala', 'tests/xsettings_daemon_test.vala'],
  dependencies: [dependency('gio-2.0')],
  vala_args: ['--pkg', 'posix'],
)
fake_xsettingsd = executable('fake-xsettingsd', 'tests/fake_xsettingsd.c')
test('xsettings-daemon', xsettings_daemon_test, timeout: 60,
  env: ['FAKE_XSETTINGSD=' + fake_xsettingsd.full_path()], depends: [fake_xsettingsd])

process_terminator_test = executable('process-terminator-test',
  sources: ['src/core/process_terminator.vala', 'tests/process_terminator_test.vala'],
  dependencies: [dependency('gio-2.0')],
  vala_args: ['--pkg', 'posix'],
)
test('process-terminator', process_terminator_test, timeout: 60)

search_round_test = executable('search-round-test',
  sources: ['src/core/search/search_round.vala', 'tests/search_round_test.vala'],
  dependencies: [dependency('gobject-2.0')],
)
test('search-round', search_round_test)

fan_control_deps = [dependency('gio-2.0'), dependency('gio-unix-2.0'), gee_dep, system_dep]

executable('singularity-fan-control',
  sources: ['src/services/fan-control/fan_controller.vala', 'src/services/fan-control/main.vala'],
  dependencies: fan_control_deps + [dependency('polkit-gobject-1'), cc.find_library('m')],
  install: true
)

fan_controller_test = executable('fan-controller-test',
  sources: ['src/services/fan-control/fan_controller.vala', 'tests/fan_controller_test.vala'],
  dependencies: fan_control_deps + [cc.find_library('m')],
)
test('fan-controller', fan_controller_test)

fan_control_conf = configuration_data()
fan_control_conf.set('bindir', get_option('prefix') / get_option('bindir'))
fan_control_conf.set('libdir', get_option('prefix') / get_option('libdir'))
configure_file(
  input: 'data/fan-control/singularity-fan-control.service.in',
  output: 'singularity-fan-control.service',
  configuration: fan_control_conf,
  install_dir: get_option('prefix') / 'lib' / 'systemd' / 'system',
)
configure_file(
  input: 'data/fan-control/dev.sinty.FanControl.service.in',
  output: 'dev.sinty.FanControl.service',
  configuration: fan_control_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'system-services',
)
install_data('data/fan-control/dev.sinty.FanControl.conf',
  install_dir: get_option('datadir') / 'dbus-1' / 'system.d')
install_data('data/fan-control/dev.sinty.fan-control.policy',
  install_dir: get_option('datadir') / 'polkit-1' / 'actions')

if get_option('firewall-helper')
  executable('singularity-firewall-helper',
    sources: ['src/services/firewall-helper/main.c'],
    c_args: ['-DFIREWALL_STATE_FILE="@0@"'.format(get_option('firewall-state-file'))],
    install: true,
    install_dir: get_option('libexecdir'),
  )
  firewall_helper_conf = configuration_data()
  firewall_helper_conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
  configure_file(
    input: 'data/firewall/dev.sinty.firewall.policy.in',
    output: 'dev.sinty.firewall.policy',
    configuration: firewall_helper_conf,
    install_dir: get_option('datadir') / 'polkit-1' / 'actions',
  )
endif

parental_helper_dir = get_option('prefix') / get_option('localstatedir') / 'lib' / 'singularity' / 'parental'
parental_helper = executable('singularity-parental-helper',
  sources: ['src/services/parental-helper/main.c'],
  c_args: ['-DSINGULARITY_PARENTAL_DIR="@0@"'.format(parental_helper_dir)],
  dependencies: [dependency('glib-2.0')],
  install: true,
  install_dir: get_option('libexecdir'),
)
parental_policy_conf = configuration_data()
parental_policy_conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/parental/dev.sinty.parental.policy.in',
  output: 'dev.sinty.parental.policy',
  configuration: parental_policy_conf,
  install_dir: get_option('datadir') / 'polkit-1' / 'actions',
)
install_data('data/parental/parental-controls.conf',
  install_dir: get_option('sysconfdir') / 'xdg' / 'singularity')
test('parental-helper', find_program('tests/parental_helper_test.sh'),
  args: [parental_helper.full_path()],
  depends: parental_helper,
  env: ['TMPDIR=' + meson.current_build_dir()])

if get_option('power-helper')
  executable('singularity-power-helper',
    sources: ['src/services/power-helper/main.c'],
    install: true,
    install_dir: get_option('libexecdir'),
  )
  power_helper_conf = configuration_data()
  power_helper_conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
  configure_file(
    input: 'data/power/dev.sinty.power.policy.in',
    output: 'dev.sinty.power.policy',
    configuration: power_helper_conf,
    install_dir: get_option('datadir') / 'polkit-1' / 'actions',
  )
endif

install_data('data/artist-packs/singularity-artist-pack-inventory',
  install_dir: '/usr/local/bin', install_mode: 'rwxr-xr-x')
install_data('data/artist-packs/singularity-artist-pack-install',
  install_dir: '/usr/local/bin', install_mode: 'rwxr-xr-x')
install_data('data/artist-packs/dev.sinty.desktop.artist-pack-install.policy',
  install_dir: get_option('datadir') / 'polkit-1' / 'actions')

install_data('data/icons/singularity-account-secure-mail.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

wallpaper_collections_test = executable('wallpaper-collections-test',
  sources: ['src/core/wallpaper_collections.vala', 'src/core/dynamic_wallpaper.vala', 'tests/wallpaper_collections_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('glib-2.0'), dependency('gio-2.0'), gee_dep, json_dep],
)
test('wallpaper-collections', wallpaper_collections_test)

wallpaper_rotation_state_test = executable('wallpaper-rotation-state-test',
  sources: ['src/core/wallpaper_rotation_state.vala', 'tests/wallpaper_rotation_state_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('glib-2.0'), dependency('gio-2.0')],
)
test('wallpaper-rotation-state', wallpaper_rotation_state_test)

wallpaper_gallery_test = executable('wallpaper-gallery-test',
  sources: ['src/core/wallpaper_gallery.vala', 'src/core/dynamic_wallpaper.vala', 'tests/wallpaper_gallery_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep, json_dep],
)
test('wallpaper-gallery', wallpaper_gallery_test)
wallpaper_rotator_test = executable('wallpaper-rotator-test',
  sources: ['src/core/wallpaper_collections.vala', 'src/core/wallpaper_gallery.vala', 'src/core/dynamic_wallpaper.vala',
            'src/core/wallpaper_rotation_state.vala', 'src/core/wallpaper_rotator.vala',
            'tests/wallpaper_rotator_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('glib-2.0'), dependency('gio-2.0'), gee_dep, json_dep],
)
test('wallpaper-rotator', wallpaper_rotator_test)

wallpaper_ocs_test = executable('wallpaper-ocs-test',
  sources: ['src/core/wallpaper_ocs.vala', 'src/core/wallpaper_browse_cache.vala', 'src/core/wallpaper_thumbnail_cache.vala', 'src/core/wallpaper_provider.vala', 'src/core/wallpaper_collections.vala', 'src/core/wallpaper_gallery.vala', 'src/core/dynamic_wallpaper.vala', 'tests/wallpaper_ocs_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep, json_dep, libsingularity_dep],
)
test('wallpaper-ocs', wallpaper_ocs_test)

wallpaper_sidecar_test = executable('wallpaper-sidecar-test',
  sources: ['src/core/wallpaper_sidecar.vala', 'tests/wallpaper_sidecar_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep, json_dep],
)
test('wallpaper-sidecar', wallpaper_sidecar_test)

dynamic_wallpaper_test = executable('dynamic-wallpaper-test',
  sources: ['src/core/dynamic_wallpaper.vala', 'src/core/dynamic_wallpaper_heic.vala', 'tests/dynamic_wallpaper_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), dependency('gdk-pixbuf-2.0'), json_dep, libsingularity_dep],
)
test('dynamic-wallpaper', dynamic_wallpaper_test)

settings_safety_test = executable('settings-safety-test',
  sources: ['src/core/settings_safety.vala', 'tests/settings_safety_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0')],
)
test('settings-safety', settings_safety_test)

notification_focus_test = executable('notification-focus-test',
  sources: ['src/core/focus/focus_model.vala', 'src/core/notifications/notification_rules.vala',
            'src/core/notifications/notification_history.vala', 'tests/notification_focus_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep, json_dep],
)
test('notification-focus', notification_focus_test)

install_data('data/notifications/dev.sinty.desktop.notifications.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')

clipboard_model_test = executable('clipboard-model-test',
  sources: ['src/core/clipboard/clipboard_model.vala', 'tests/clipboard_model_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep, json_dep],
)
test('clipboard-model', clipboard_model_test)

snap_layout_test = executable('snap-layout-test',
  sources: ['src/core/snap/snap_layout_model.vala', 'tests/snap_layout_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0')],
)
test('snap-layout', snap_layout_test)

stage_model_test = executable('stage-model-test',
  sources: ['src/core/stage/stage_model.vala', 'tests/stage_model_test.vala'],
  dependencies: [dependency('gobject-2.0'), gee_dep],
)
test('stage-model', stage_model_test)

shortcut_cheatsheet_test = executable('shortcut-cheatsheet-test',
  sources: ['src/core/shortcut_cheatsheet_model.vala', 'src/core/app_accels_reader.vala', 'tests/shortcut_cheatsheet_test.vala'],
  dependencies: [dependency('gtk4')],
)
test('shortcut-cheatsheet', shortcut_cheatsheet_test)

clipboard_migration_test = executable('clipboard-migration-test',
  sources: ['src/core/clipboard/clipboard_plugin_migration.vala', 'tests/clipboard_migration_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0')],
)
test('clipboard-migration', clipboard_migration_test)

pomodoro_migration_test = executable('pomodoro-migration-test',
  sources: ['src/core/plugins/pomodoro_plugin_migration.vala', 'tests/pomodoro_migration_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0')],
)
test('pomodoro-migration', pomodoro_migration_test)

crash_spool_dir = get_option('crash-spool-dir')
crash_conf = configuration_data()
crash_conf.set('SPOOL_DIR', crash_spool_dir)
crash_conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/crash/crash-reporter.conf.in',
  output: 'crash-reporter.conf',
  configuration: crash_conf,
  install_dir: get_option('sysconfdir') / 'xdg' / 'singularity',
)
install_data('data/crash/dev.sinty.desktop.crash.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')
if get_option('crash-handler')
  crash_handler = executable('singularity-crash-handler',
    sources: ['src/services/crash-handler/main.c'],
    c_args: [
      '-DSINGULARITY_CRASH_CONFIG_FILE="@0@"'.format(get_option('prefix') / get_option('sysconfdir') / 'xdg' / 'singularity' / 'crash-reporter.conf'),
      '-DSINGULARITY_CRASH_SPOOL_DIR="@0@"'.format(crash_spool_dir),
    ],
    install: true,
    install_dir: get_option('libexecdir'),
  )
  configure_file(
    input: 'data/crash/50-singularity-crash-handler.conf.in',
    output: '50-singularity-crash-handler.conf.example',
    configuration: crash_conf,
    install_dir: get_option('datadir') / 'singularity' / 'crash',
  )
  test('crash-handler', find_program('tests/crash_handler_test.sh'),
    args: [crash_handler.full_path()],
    depends: crash_handler,
    env: ['TMPDIR=' + meson.current_build_dir()])
endif

crash_report_test = executable('crash-report-test',
  sources: ['src/core/crash/crash_report.vala', 'src/core/crash/crash_config.vala', 'tests/crash_report_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), json_dep],
)
test('crash-report', crash_report_test)
