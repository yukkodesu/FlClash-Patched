# Project Context

FlClash-Meow is a Flutter desktop proxy client using meow-rs through an embedded Rust host. This fork ships Windows,
macOS, and Linux on x64 and ARM64. Mobile sources are retained from FlClash-Patched but are outside this product's build
and release scope. The implementation and capability differences are specified in `docs/specs/meow-desktop-client.md`.

## Version Notes

- Release CI pins Flutter 3.47.6. Local SDK may diverge, so trust the CI
  version as the source of truth for release builds.
- Root Dart SDK constraint: `>=3.10.0 <4.0.0`. Keep dependency upgrades separate
  from language-version changes; local packages may impose a higher SDK minimum.
- The pinned `core/meow-rs` submodule comes from `yukkodesu/meow-rs`. The host crate lives in
  `core/meow-rs/crates/flclash-meow-host`; update the gitlink only after verifying that exact fork commit.
- The engine/host uses its own pinned Rust 1.98.1 toolchain. `plugins/rust_api/rust` uses Rust 1.99.0 and remains a
  separate Flutter runtime library for IPC, scripting, and hotkeys.

## Forked Dependencies

Three `pubspec.yaml` dependencies are pinned to a fork — `window_manager` by branch,
the other two by commit SHA. All three
forks live under `chenx-dust` or `chen08209`, so they
are maintained in-house rather than tracked from a third party: advancing a pin
is a local decision, and there is no external maintainer to wait on for the patch
itself. What each fork still waits on is the *upstream* fix that would let the
pin be dropped entirely, recorded below.

Each entry records what the fork changes and what has to be true before it can go
back to the published package, so a future upgrade does not have to rediscover it.
Re-verify a fork by diffing its pub cache checkout against the published version
of the same number:

```bash
diff -ru ~/.pub-cache/hosted/pub.dev/<name>-<version> ~/.pub-cache/git/<name>-<sha>
```

`window_manager` — `chenx-dust/window_manager`, path `packages/window_manager`,
version 0.5.2, tracking `main` on top of
`chen08209/window_manager` tag `v0.5.1-flclash.3`.

- `windows/window_manager_plugin.cpp`: with `titleBarStyle: hidden` a maximized
  window uses the monitor work area (`GetMonitorInfo().rcWork`) instead of
  upstream's `adjustNCCALCSIZE` border fudge, so it no longer covers the taskbar.
- `linux/window_manager_plugin.cc`: GTK drops the placement of an unmapped
  window, so `hide` saves the geometry and the `map-event` handler applies it
  again. Upstream only moves the window while it is hidden, which a window
  manager is free to ignore — the window then reappears wherever it decides to
  place it, which on this repository's Linux runner is every appearance after the
  first, because `my_application.cc` never shows the toplevel itself.
- Adds `setWindowCornerPreference` (Windows) and `handleShouldTerminate` /
  `onWindowShouldTerminate` (macOS). These lived in a local `window_ext` plugin
  until they moved here; `lib/manager/window_manager.dart` and
  `macos/Runner/AppDelegate.swift` are the callers.
- Preserves Linux tray activation timestamps and Wayland tokens through the window visibility queue;
  the plugin consumes a token once when restoring a minimized window. Also retains `onWindowActivate`.
- Drop the fork once upstream carries these behaviors. The added APIs have call sites,
  so this is not a pin change alone.

`launch_at_startup` — `chen08209/launch_at_startup`, version 0.5.1.

- Migrates `win32_registry` from `^2.0.0` to `^3.0.3`, which is a breaking rename
  across the whole Windows implementation (`Registry.openPath` → `CURRENT_USER.open`,
  `createValue` → `setValue`, `getStringValue` → `getString`).
- This one is not optional while it lasts: FlClash depends on `win32_registry: ^3.0.3`
  directly, and upstream's `^2.0.0` constraint cannot co-resolve with it.
- Drop the fork when upstream publishes a release that accepts `win32_registry` 3.x.

`yaml_writer` — `chen08209/yaml_writer`, version 2.1.0.

- Adds `StringNode.quoteKey()` and applies it to map keys in `lib/src/node.dart`.
  Upstream quotes values but emits keys verbatim, so a profile key needing quotes
  is written as invalid YAML.
- Drop the fork once upstream quotes map keys by the same
  `isValidUnquotedString` rule it already applies to values.

## Dependency Ceilings

Dependency resolution was rechecked with Flutter 3.47.6 / Dart 3.13.5. The
remaining root-package upgrades are blocked by upstream constraints:

- `intl_utils` 2.8.16 requires `analyzer: ^13.0.0`, holding analyzer at 13.3.0.
  `freezed` 4.0.2 requires analyzer 14, so retain stable `freezed` 4.0.1 until
  intl_utils supports it. Do not restore the obsolete 3.2.6-dev.1 pin.
- `flutter_test` pins `test_api` to 0.7.12; `test` 1.32.0 requires 0.7.14.
  The pure Dart `plugins/setup/setup_hooks` package can use test 1.32.0 because
  it has no Flutter SDK dependency.
- Flutter pins `material_color_utilities` to 0.13.0. `intl` remains intentionally
  unbounded (`any`) so SDK localization constraints can resolve it.
- `vector_graphics_compiler` 1.3.0 constrains `xml` to `>=6.3.0 <=7.0.1`.
  Keep xml at 7.0.1 until that upper bound moves; 7.1.0 cannot co-resolve.
- `cross_file` 0.4.0 cannot co-resolve with the current image picker and file
  selector platform packages, which still require 0.3.x.

The root and local build packages use `code_assets` 2.1.0. Upgrading both
`plugins/rust_api` and `plugins/setup/setup_hooks` together lets
`native_toolchain_c`, `native_toolchain_rust`, and `objective_c` move to their
latest compatible releases. OS and architecture values can no longer be keys
in const maps or sets; use runtime collections in build hooks.

The Rust API pins `libc` to 0.2.189 for iOS: 0.2.190 restricts dyld declarations
to macOS, breaking the iOS build of `backtrace` 0.3.76. Keep this pin until
backtrace supports the changed declarations.

## Build Dependencies

Every desktop target needs the pinned Flutter SDK, Git, rustup/Cargo, CMake, a native C/C++ compiler, Python, and libclang
for meow's TUN bindings. The build hook fingerprints native toolchain inputs and reports missing tools as build failures.
Set `LIBCLANG_PATH` to the directory containing the native libclang shared library when automatic discovery fails.

Linux (plus the format-specific packaging tools installed by `setup.dart`):

```bash
sudo apt-get install cmake ninja-build clang libclang-dev pkg-config libgtk-3-dev libayatana-appindicator3-dev libsecret-1-dev
```

Windows:

- Visual Studio with Desktop development with C++, the target's MSVC tools and Windows SDK, LLVM/libclang, NASM,
  and Inno Setup. GCC is not the Windows MSVC host compiler.
- The meow build embeds the official Wintun DLL for the target architecture. `MEOW_WINTUN_DLL` may select a previously
  verified DLL; its contents participate in the build fingerprint. No DLL sidecar is required for the packaged host.

macOS:

- Xcode and command-line tools, CMake, native LLVM/libclang, and Node/npm for DMG packaging.

```bash
npm install -g appdmg
```

CI executes each target on a native runner and rejects a Rust host triple that differs from the matrix target.
macOS x64 uses `macos-26-intel`; ARM64 uses `macos-26`.
