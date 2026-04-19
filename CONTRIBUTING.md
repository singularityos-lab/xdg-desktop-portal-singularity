# Contributing to libsingularity

## Development setup

```bash
git clone https://github.com/singularityos-lab/libsingularity
cd libsingularity
meson setup build
ninja -C build
```

To enable GObject Introspection:

```bash
meson setup build -Dintrospection=true
ninja -C build
```

## Code style

- Language: **Vala** or **C/C++** only.
- Indentation: **4 spaces** no tabs, no trailing whitespace.
- Keep files focused: one primary class per `.vala` file, named after the class
  (e.g. `ScreenshotPortal` -> `screenshot.vala`) the `Portal` suffix is not necessary.

## License

By contributing you agree your code will be released under [LGPL-2.1-only](LICENSE).

