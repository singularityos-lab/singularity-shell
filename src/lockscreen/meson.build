# A toolkit-less ext-session-lock-v1 locker (swaylock-style): renders with
# Cairo, reads the keyboard with xkbcommon, authenticates with PAM. The old
# GTK layer-shell approach conflicted with the lock-surface role and left the
# screen black (#35), so it is replaced here.
pam_dep = cc.find_library('pam', required: true)
lock_wl_dep         = dependency('wayland-client')
lock_xkb_dep        = dependency('xkbcommon')
lock_cairo_dep      = dependency('cairo')
lock_pangocairo_dep = dependency('pangocairo')
lock_pixbuf_dep     = dependency('gdk-pixbuf-2.0')
lock_gio_dep        = dependency('gio-2.0')

executable('singularity-lockscreen',
  ['lock_main.c', 'pam_auth.c', 'lock_media.c', 'lock_notifs.c', 'lock_fprint.c'],
  sources: [sl_proto_c, sl_proto_h],
  dependencies: [
    lock_wl_dep,
    lock_xkb_dep,
    lock_cairo_dep,
    lock_pangocairo_dep,
    lock_pixbuf_dep,
    lock_gio_dep,
    pam_dep,
    loginui_dep,
  ],
  include_directories: [
    include_directories('.'),
    include_directories('..'),
  ],
  install: true
)

install_data(
  'dev.sinty.lockscreen.gschema.xml',
  install_dir: join_paths(get_option('datadir'), 'glib-2.0', 'schemas')
)

install_data(
  'singularity-lockscreen.pam',
  install_dir: '/etc/pam.d',
  rename: 'singularity-lockscreen'
)
