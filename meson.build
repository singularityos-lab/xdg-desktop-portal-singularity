project('xdg-desktop-portal-singularity', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0',
)

gnome = import('gnome')
cc = meson.get_compiler('c')
valac = meson.get_compiler('vala')

# Dependencies
gtk4_dep = dependency('gtk4')
gio_dep = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
gtk4_unix_print_dep = dependency('gtk4-unix-print')
wayland_client_dep = dependency('wayland-client')
posix_dep = valac.find_library('posix')

# Pipewire dependency handled via pkg-config to avoid valac issues
pipewire_cflags = run_command('pkg-config', '--cflags', 'libpipewire-0.3', check: true).stdout().strip().split()
pipewire_libs   = run_command('pkg-config', '--libs',   'libpipewire-0.3', check: true).stdout().strip().split()

# libsingularity dependency
if meson.is_subproject()
  libsingularity_subproj = subproject('libsingularity')
  libsingularity_dep = libsingularity_subproj.get_variable('libsingularity_dep')
else
  libsingularity_dep = dependency('singularity-1.0')
endif

# Protocols
wayland_scanner = find_program('wayland-scanner')

# ext-foreign-toplevel-list-v1 (needed as dependency for image-capture-source)
tl_proto_xml = 'protocols/ext-foreign-toplevel-list-v1.xml'
tl_proto_c = custom_target(
  'ext-foreign-toplevel-list-v1-protocol.c',
  output: 'ext-foreign-toplevel-list-v1-protocol.c',
  input: tl_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
tl_proto_h = custom_target(
  'ext-foreign-toplevel-list-v1-client-protocol.h',
  output: 'ext-foreign-toplevel-list-v1-client-protocol.h',
  input: tl_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)

# ext-image-capture-source-v1
src_proto_xml = 'protocols/ext-image-capture-source-v1.xml'
src_proto_c = custom_target(
  'ext-image-capture-source-v1-protocol.c',
  output: 'ext-image-capture-source-v1-protocol.c',
  input: src_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
src_proto_h = custom_target(
  'ext-image-capture-source-v1-client-protocol.h',
  output: 'ext-image-capture-source-v1-client-protocol.h',
  input: src_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)

# ext-image-copy-capture-v1
copy_proto_xml = 'protocols/ext-image-copy-capture-v1.xml'
copy_proto_c = custom_target(
  'ext-image-copy-capture-v1-protocol.c',
  output: 'ext-image-copy-capture-v1-protocol.c',
  input: copy_proto_xml,
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']
)
copy_proto_h = custom_target(
  'ext-image-copy-capture-v1-client-protocol.h',
  output: 'ext-image-copy-capture-v1-client-protocol.h',
  input: copy_proto_xml,
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']
)

sources = files(
  'src/main.vala',
  'src/settings.vala',
  'src/screenshot.vala',
  'src/screencast.vala',
  'src/screencast_backend.c',
  'src/file_chooser_portal.vala',
  'src/notification.vala',
  'src/inhibit.vala',
  'src/access.vala',
  'src/account.vala',
  'src/email.vala',
  'src/lockdown.vala',
  'src/wallpaper.vala',
  'src/app_chooser.vala',
  'src/open_uri.vala',
  'src/print.vala',
  'src/dynamic_launcher.vala',
  'src/ush.vala',
  'src/dbus_helper.c',
)

executable('xdg-desktop-portal-singularity',
  sources: sources + [tl_proto_c, tl_proto_h, src_proto_c, src_proto_h, copy_proto_c, copy_proto_h],
  include_directories: include_directories('src'),
  dependencies: [
    gtk4_dep,
    gio_dep,
    gio_unix_dep,
    gee_dep,
    json_dep,
    gtk4_unix_print_dep,
    wayland_client_dep,
    posix_dep,
    libsingularity_dep,
    cc.find_library('m')
  ],
  c_args: pipewire_cflags,
  link_args: pipewire_libs,
  vala_args: ['--pkg=gtk4-unix-print'],
  install: true,
  install_dir: get_option('libexecdir')
)

# Standalone screencast output chooser. Run as a separate process by the
# portal so GTK is never initialised inside the portal daemon (which would
# deadlock on its own Settings portal query during Gtk.init).
executable('singularity-screencast-chooser',
  sources: files('src/screencast_source_picker.vala', 'src/chooser_main.vala'),
  dependencies: [
    gtk4_dep,
    gio_dep,
    libsingularity_dep,
  ],
  install: true,
  install_dir: get_option('bindir')
)
