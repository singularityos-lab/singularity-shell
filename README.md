# Singularity Shell

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

The desktop shell for the Singularity Desktop Environment: the panel, dock,
overview, sidebar, notifications, run dialog, app switcher, lock screen, and
the compositor integration that drives `labwc`.

This builds the main `singularity-desktop` executable along with the
`singularity-region-picker`, `singularity-keyboard-reset`, and
`singularity-screenshot` helpers.

## Requirements

- [Meson](https://mesonbuild.com/) >= 0.59
- [Vala](https://vala.dev/) compiler
- GTK4, gtk4-layer-shell, wayland-client, wayland-scanner
- VTE (`vte-2.91-gtk4`), GtkSourceView 5, poppler-glib
- NetworkManager (`libnm`), UPower, PulseAudio
- singularity-accounts (online accounts service, D-Bus activated)
- polkit, gnome-desktop-4, libsoup-3.0, json-glib, libpeas-2
- dbusmenu-glib, atspi-2, tracker-sparql-3.0, gudev-1.0
- PAM (`libpam`, lock screen authentication)
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## For distributors

- Crash reports: the shell reads crashes from systemd-coredump, from
  `singularity-crash-handler` (installed in `libexecdir`, enabled only when
  `kernel.core_pattern` points to it, example drop-in in
  `datadir/singularity/crash`) or, as a fallback, from the apps it launches.
  Configure it in `/etc/xdg/singularity/crash-reporter.conf`; meson options
  `crash-handler` and `crash-spool-dir`. The full description is in
  `docs/crash-reports.md` of libsingularity.

- Shortcuts overview: holding Super on its own shows the desktop shortcuts
  and those of the focused app. The hold is detected by the compositor
  through `singularity-key-hold-unstable-v1` (implemented by the bundled
  labwc). On a compositor without it the overview still opens with
  Super+/ (`toggle_shortcut_cheatsheet`). The app part comes from the
  `accel` attributes of the exported menu bar (org.gtk.Menus) or the
  `shortcut` property of a com.canonical.dbusmenu menu. Keys
  `shortcut-cheatsheet-hold` and `shortcut-cheatsheet-delay` in
  `dev.sinty.desktop` turn it off or change the delay.

- Window groups: an optional mode (`stage-manager` in `dev.sinty.desktop`,
  off by default, quick settings tile "Window Groups") that shows one group
  of windows at a time and the others as thumbnails in a strip on the left.
  Windows are hidden and shown through `singularity-stage-unstable-v1`
  (implemented by the bundled labwc), which also moves them to and from
  their thumbnail. On a compositor without it the shell falls back to the
  minimize requests of `wlr-foreign-toplevel-management`, with the
  compositor's own minimize animation. Scripts can drive it through
  `dev.sinty.Shell.Stage` on `/dev/sinty/Shell/Stage` (ListSets, Activate,
  MoveWindow, SetEnabled). Every monitor has its own groups and strip; a
  window dragged to another monitor joins the group shown there, and the
  groups of a monitor that goes away join the first one. Version 2 of the
  protocol keeps a group number on each window inside the compositor, so a
  shell restart finds the same groups; the order of the strips and the
  group on stage are kept in `$XDG_STATE_HOME/singularity/stage-groups.json`.
  With version 1 only, groups start over after a restart and hidden
  windows stay minimized in the dock. When the mode is off at startup,
  windows hidden by a previous session are shown again.

- Snap layouts: resting the pointer on the maximize button of a window
  with server side decorations, or dragging any window to the top edge,
  shows a layout picker (halves, thirds, quarters, two thirds and one
  third, plus layouts for ultrawide and portrait outputs). After a snap the
  other open windows are offered to fill the rest of the layout. The
  triggers and the zone snapping live in the compositor through
  `singularity-snap-unstable-v1` (implemented by the bundled labwc, which
  keeps its own edge snapping until the shell enables the picker). Zones
  are labwc regions in thousandths of the work area, so windows stay
  snapped when panels or outputs change. On a compositor without the
  protocol the picker is simply not offered. Keys `snap-layouts` and
  `snap-assist` in `dev.sinty.desktop`; the picker is off while automatic
  tiling is on.

- Dynamic wallpapers: `*.dynamic.json` manifests, time-based XML slideshows and
  imported macOS HEIC dynamic desktops change with the sun, the time of day
  or the light and dark appearance, with no network access (the sun is
  computed from the time zone or from coordinates set by the user). HEIC
  import needs a decoder command (ImageMagick or libheif with an HEVC
  plugin), configurable in `/etc/xdg/singularity/dynamic-wallpapers.conf`.
  The full description is in `docs/dynamic-wallpapers.md` of libsingularity.

- Input methods, dictation and spelling: the shell is the
  `zwp_input_method_v2` client of the session. It drives Fcitx 5 or IBus
  over D-Bus (starting them without their Wayland frontend when they are
  not running) and draws their candidates itself; dictation runs
  whisper.cpp, Vosk (`singularity-dictation-vosk` in `libexecdir`) or any
  program that reads 16 kHz audio on standard input; the downloadable model
  list is `datadir/singularity/dictation-models.json` and can be replaced
  from `/etc/xdg/singularity/`. The full description, including what works
  for X11 apps, is in `docs/input-methods-and-dictation.md` of
  libsingularity.

- X11 settings: X11 and XWayland apps get the font, cursor, icon theme,
  window button layout and global menu settings over XSETTINGS. The shell
  writes them to `~/.xsettingsd` (atomically) and runs its own
  [xsettingsd](https://github.com/derat/xsettingsd) child with
  `-c ~/.xsettingsd`, started once `DISPLAY` is set. Changes reload that
  child with SIGHUP; the shell never signals other xsettingsd processes,
  so other sessions of the same user keep their own. The child ends with
  the shell (parent death signal on Linux, plus a pid record in
  `$XDG_RUNTIME_DIR/singularity/xsettingsd.pid` that a restarted shell
  uses to end a leftover child after checking its command line and
  `DISPLAY`). If it exits it is restarted with a backoff and left stopped
  after five quick exits in a row, until the next settings change. Without
  xsettingsd installed the file is still written and X11 apps keep their
  own defaults; Wayland apps are not affected. Do not start another
  xsettingsd for the same display from the session.

- Force quit: Shift + right click on a running app in the dock offers
  "Force Kill". The shell asks the compositor which process owns each
  window of the app through `singularity-process-unstable-v1`
  (implemented by the bundled labwc): the Wayland client credentials for
  native windows, `_NET_WM_PID` for X11 windows, never the X server. It
  sends SIGTERM to those processes, and SIGKILL after three seconds to the
  ones still running. When a process sits in its own `app-*.scope` cgroup
  (as GLib, Flatpak and systemd launchers create), the other processes of
  that scope are included. Processes of other users, pid 1 and the
  shell's own ancestors are never signalled, and a pid is checked against
  its start time before every signal. On a compositor without the
  protocol, or when no process is known, the shell shows a notification
  and stops nothing.

## Third-party code

- `src/vapi/polkit-agent-1.vapi`: the polkit agent bindings shipped with [Vala](https://vala.dev/), GNU LGPL 2.1 or later.
- `src/vapi/dbusmenu-glib-0.4.vapi` and `src/vapi/libpeas-2-copy.vapi`: Vala bindings generated with vapigen from the libdbusmenu and libpeas introspection data.
- `protocols/ext-*.xml`, `protocols/wlr-*.xml`, `protocols/xdg-output-unstable-v1.xml`, `protocols/input-method-unstable-v2.xml` and `protocols/virtual-keyboard-unstable-v1.xml`: Wayland protocol definitions from [wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols) and [wlr-protocols](https://gitlab.freedesktop.org/wlroots/wlr-protocols), under the licenses stated in each file.

## License

GPL-3.0-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-shell. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
