# xdg-desktop-portal-singularity

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

A backend implementation for xdg-desktop-portal for the [Singularity Desktop Environment](https://github.com/singularityos-lab).

## Requirements

- [Meson](https://mesonbuild.com/) ≥ 1.0
- [Vala](https://vala.dev/) compiler
- GTK4
- gtk4-layer-shell
- libgee-0.8
- json-glib-1.0
- libpipewire-0.3
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## Permission prompts

Access, Background, GlobalShortcuts, RemoteDesktop and Usb ask the user through
`singularity-portal-consent`, a separate process installed next to the
daemon. It reads one JSON request on stdin, shows a full screen layer-shell
dialog and prints one JSON answer on stdout, so GTK never starts inside the
portal daemon. The request is cancelled when the app closes the portal
request.

## Portal status

| Interface | Status |
| --- | --- |
| Access | Consent dialog used by the Camera and Location portals of the frontend |
| Lockdown | `disable-camera`, `disable-microphone` and `disable-location` follow the privacy switches in `dev.sinty.desktop` |
| Background | App state from `ext-foreign-toplevel-list-v1`, background notice with Allow, This Time and Stop, autostart files |
| GlobalShortcuts | Version 2; grants stored in `portal-global-shortcuts`, bound and triggered by the shell |
| Usb | Device selection dialog, version 1 |
| Clipboard | Version 1, only inside a RemoteDesktop session the user allowed to use the clipboard; uses `ext-data-control-v1` |
| InputCapture | Not provided. It needs pointer barriers and an EIS server in the compositor |
| RemoteDesktop | Version 2, keyboard and pointer through `zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1`, screen streams from the ScreenCast implementation, confirmation dialog for every session, `ConnectToEIS` and touch not provided |

## For distributors

- Install `singularity-portal-consent` in the same directory as the daemon,
  or anywhere in `PATH`.
- Background app state comes from the `ext-foreign-toplevel-list-v1`
  Wayland protocol. On a compositor without it `GetAppState` fails, and the
  frontend skips its background checks instead of asking about every app.
- Location has no backend interface: the frontend talks to GeoClue directly
  and uses this backend for the consent dialog and the Lockdown switch.
- Settings, Privacy in the shell reads the same permission store the
  frontend writes; see `docs/privacy.md` in libsingularity.
- RemoteDesktop needs the compositor to offer
  `zwlr_virtual_pointer_manager_v1` and `zwp_virtual_keyboard_manager_v1`;
  without them `Start` fails. Keysyms are typed with the keymap of the
  session, read from the seat; characters missing from it get a spare key.
  Streams selected with `SelectSources` get the output's logical `position`
  and `size`, and `NotifyPointerMotionAbsolute` maps stream coordinates onto
  that output, also on scaled screens. The Wayland helpers are shared with
  singularity-sharing through the sharing host library of libsingularity
  (`docs/sharing-host.md`).
- Active RemoteDesktop sessions are listed on
  `/dev/sinty/portal/RemoteSessions` (`dev.sinty.portal.RemoteSessions`:
  `ListSessions`, `StopSession`, `StopAll`, signal `Changed`); the shell uses
  it for the screen sharing button in the top bar.

## License

LGPL-2.1-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on xdg-desktop-portal-singularity. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
