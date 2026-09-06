project('singularity-shell', ['vala', 'c'],
  version: '0.1.0',
  default_options: ['buildtype=release', 'strip=true'],
)
add_project_arguments('-DGETTEXT_PACKAGE="singularity-desktop"', language: 'c')
add_project_arguments('-D_GNU_SOURCE', language: 'c')
add_project_arguments('-DGOA_API_IS_SUBJECT_TO_CHANGE', language: 'c')
add_project_arguments('-DGOA_BACKEND_COMPILATION', language: 'c')
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
  dependency('gtk4'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('vte-2.91-gtk4'),
]

shell_deps = [
  dependency('gtk4-layer-shell-0'),
  dependency('poppler-glib'),
  dependency('gtksourceview-5'),
  dependency('wayland-client'),
  dependency('libnm', version: '>= 1.0.0'),
  dependency('upower-glib', version: '>= 0.99.0'),
  dependency('libpulse'),
  dependency('libpulse-mainloop-glib'),
  dependency('goa-1.0'),
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
    'src/core/wallpaper_collections.vala',
    'src/core/wallpaper_gallery.vala',
    'src/core/wallpaper_rotation_state.vala',
    'src/core/wallpaper_ocs.vala',
    'src/core/wayland_gamma_backend.vala',
    'src/core/shortcut_manager.vala',
    'src/core/ush_portal.vala',
    'src/core/screenshot_portal.vala',
    'src/core/screenshot_tool.vala',
    'src/core/plugin_manager.vala',
    'src/components/dock/dock.vala',
    'src/components/dock/update_indicator.vala',
    'src/components/dock/dock_resources.vala',
    'src/components/dock/dock_dbus_service.vala',
    'src/components/background/background.vala',
    'src/components/sidebar/sidebar.vala',
    'src/components/sidebar/settings_window.vala',
    'src/components/sidebar/widgets/settings_widgets.vala',
    'src/components/sidebar/widgets/developer_page.vala',
    'src/components/preview/preview_dialog.vala',
    'src/core/preview_manager.vala',
    'src/components/desktop/desktop_icons.vala',
    'src/components/notifications/notification_display.vala',
    'src/components/notifications/notification_center.vala',
    'src/core/notification_manager.vala',
    'src/components/sidebar/views/system_view.vala',
    'src/components/sidebar/views/power_confirm_dialog.vala',
    'src/components/sidebar/views/settings_view.vala',
    'src/components/sidebar/pages/network_page.vala',
    'src/components/sidebar/pages/desktop_page.vala',
    'src/components/sidebar/pages/wallpaper_ocs_browser.vala',
    'src/components/sidebar/pages/sound_page.vala',
    'src/components/sidebar/pages/keyboard_page.vala',
    'src/components/sidebar/pages/accessibility_page.vala',
    'src/components/sidebar/pages/apps_page.vala',
    'src/components/sidebar/pages/autostart_page.vala',
    'src/components/sidebar/pages/app_details_page.vala',
    'src/components/sidebar/pages/default_apps_page.vala',
    'src/components/sidebar/pages/calendar_page.vala',
    'src/components/sidebar/pages/notifications_page.vala',
    'src/components/sidebar/pages/accounts_page.vala',
    'src/components/sidebar/pages/system_page.vala',
    'src/components/sidebar/pages/users_page.vala',
    'src/components/sidebar/pages/plugins_page.vala',
    'src/components/sidebar/pages/plugin_details_page.vala',
    'src/components/sidebar/pages/performance_page.vala',
    'src/core/display_manager.vala',
    'src/core/hot_corner_manager.vala',
    'src/core/safe_mode.vala',
    'src/core/hand_control_manager.vala',
    'src/core/layer_window.vala',
    'src/core/monitor_osd.vala',
    'src/core/system_components.vala',
    'src/core/debug_manager.vala',
    'src/core/debug_hud_window.vala',
    'src/core/devtools/dev_panel.vala',
    'src/core/devtools/devtools_inspector.vala',
    'src/core/devtools/devtools_overlay.vala',
    'src/core/shell_surface_host.vala',
    'src/core/tiling_manager.vala',
    'src/components/displays/monitor_preview.vala',
    'src/components/sidebar/pages/displays_page.vala',
    'src/components/sidebar/pages/datetime_page.vala',
    'src/components/sidebar/pages/region_page.vala',
    'src/components/sidebar/pages/bluetooth_page.vala',
    'src/components/sidebar/pages/add_input_source_page.vala',
    'src/components/sidebar/pages/add_account_page.vala',
    'src/shared/widgets/password_dialog.vala',
    'src/components/sidebar/pages/vpn_config_page.vala',
    'src/shared/edit_themes.vala',
    'src/components/calendar/calendar_view.vala',
    'src/core/calendar/local_provider.vala',
    'src/core/calendar/goa_provider.vala',
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
    'src/core/search/providers/app_provider.vala',
    'src/core/search/providers/file_search_provider.vala',
    'src/core/search/providers/math_provider.vala',
    'src/wayland/wayland_integration.c',
    'src/wayland/wayland_integration.vapi',
    'src/wayland/blur_surface.c',
    'src/wayland/vkbd.c',
    'src/wayland/xwl_icon.c',
)

subdir('src/lockscreen')

executable('singularity-desktop',
  sources: ['src/core/main.vala'] + singularity_core_sources + [
    wl_proto_c, wl_proto_h, ws_proto_c, ws_proto_h, sp_proto_c, sp_proto_h, pip_proto_c, pip_proto_h, om_proto_c, om_proto_h, st_proto_c, st_proto_h, sg_proto_c, sg_proto_h, gc_proto_c, gc_proto_h, vk_proto_c, vk_proto_h
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

safe_mode_test = executable('safe-mode-test',
  sources: ['src/core/safe_mode.vala', 'tests/safe_mode_test.vala'],
  dependencies: [dependency('gobject-2.0')],
)
test('safe-mode', safe_mode_test)

wallpaper_collections_test = executable('wallpaper-collections-test',
  sources: ['src/core/wallpaper_collections.vala', 'tests/wallpaper_collections_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('glib-2.0'), dependency('gio-2.0'), gee_dep],
)
test('wallpaper-collections', wallpaper_collections_test)

wallpaper_rotation_state_test = executable('wallpaper-rotation-state-test',
  sources: ['src/core/wallpaper_rotation_state.vala', 'tests/wallpaper_rotation_state_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('glib-2.0'), dependency('gio-2.0')],
)
test('wallpaper-rotation-state', wallpaper_rotation_state_test)

wallpaper_gallery_test = executable('wallpaper-gallery-test',
  sources: ['src/core/wallpaper_gallery.vala', 'tests/wallpaper_gallery_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep],
)
test('wallpaper-gallery', wallpaper_gallery_test)

wallpaper_ocs_test = executable('wallpaper-ocs-test',
  sources: ['src/core/wallpaper_ocs.vala', 'src/core/wallpaper_collections.vala', 'tests/wallpaper_ocs_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep, json_dep],
)
test('wallpaper-ocs', wallpaper_ocs_test)
