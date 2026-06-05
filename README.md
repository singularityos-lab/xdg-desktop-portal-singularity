# xdg-desktop-portal-singularity

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

## License

LGPL-2.1-only - see [LICENSE](LICENSE).
