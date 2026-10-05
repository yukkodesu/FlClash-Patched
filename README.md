[简体中文](README_zh_CN.md)

# FlClash-Meow

A desktop proxy client derived from [FlClash-Patched](https://github.com/chenx-dust/FlClash-Patched) and [FlClash](https://github.com/chen08209/FlClash), using the [meow-rs fork](https://github.com/yukkodesu/meow-rs) through an embedded Rust host.

This product uses one meow-rs core. Its target matrix is Windows, macOS and Linux, each on x64 and ARM64. Retained Android/iOS sources are outside the build and release scope. The client, data directory, Helper and update source have independent FlClash-Meow identities.

This is a draft desktop migration; FlClash-Meow release packages have not been published yet. Builds and local proxy checks do not certify installation or native TUN cleanup. See the [acceptance matrix and exact source/run records](docs/specs/meow-desktop-acceptance.md) for completed and pending checks, and [this fork's Releases](https://github.com/yukkodesu/FlClash-Patched/releases) for future packages.

## Features and differences

The client retains configuration/subscription management, Material You themes, system proxy, tray, shortcuts and autostart. Its runtime capabilities come from the pinned host rather than mihomo compatibility claims.

| Area | Product behavior |
|---|---|
| Configuration | Preserves original imports and checks derived configuration before applying it. Unsupported protocols/options, unknown keys and unsafe provider paths block application; nodes and rules are not silently dropped. Custom direct aliases are rejected because the adapter exposes DIRECT. |
| Proxies and providers | Supports the pinned meow build's groups, node selection, delay tests and provider query/refresh operations. Missing subscription metadata is unknown. |
| Runtime changes | Mode and log level change dynamically; other configuration changes use a controlled restart. Logs and actual bound listener/DNS/controller addresses are available. |
| Statistics and connections | Traffic includes all core traffic, rather than proxy-only totals. Connection snapshots and close operations cover TCP; there are no precise UDP connection details, per-node totals or complete request-history events. Available memory metrics describe the actual process, with unavailable values shown explicitly. |
| Authentication | meow always exempts source addresses 127.0.0.1/32 and ::1/128, even with an empty skip-auth-prefixes. Configuration checks expose this warning; loopback binding does not authenticate local programs. |
| TUN | Fake-IP range capture differs from experimental global route capture. IPv6 capture requires the appropriate global configuration and platform verification. Neither an enabled switch nor a ready Helper proves capture. Unsupported mihomo stack, strict-route, route-address and endpoint-independent-nat switches are removed. |

On Linux, other DNS managers may overwrite the TUN resolver change. Fake-IP requires queries through core DNS; verify the system resolver before relying on capture. Automatic OS DNS redirection remains unverified in the native records.

Tailscale/ZeroTier/EasyTier control, AGE key operations, Go GC/goroutine/pprof diagnostics, DNS query tracing, provider sideloading, manual geodata hot-replacement transactions and separate core/external-UI updaters are outside this product. The optional external-controller is independent of client IPC and defaults to disabled. See the [full capability and configuration policy](docs/specs/meow-desktop-client.md#6-功能取舍).

## Build from source

Start from a checkout of the intended FlClash-Meow client revision. The core source is the exact gitlink recorded at core/meow-rs, from yukkodesu/meow-rs; do not replace it with that repository's latest branch tip.

~~~bash
git submodule update --init --recursive
git ls-tree HEAD core/meow-rs
flutter pub get
~~~

Use Flutter **3.47.6**, Git, rustup/Cargo, CMake, a native C/C++ compiler, Python and libclang. The core pins Rust **1.98.1**; the separate plugins/rust_api/rust library pins **1.99.0**. Run Cargo from the relevant crate checkout so its toolchain pin applies. Set LIBCLANG_PATH to the libclang library directory if discovery fails.

| Build host | Additional prerequisites |
|---|---|
| Windows | Visual Studio Desktop development with C++, matching MSVC tools/Windows SDK, NASM and Inno Setup. The host embeds an architecture-matching official Wintun DLL; MEOW_WINTUN_DLL can select a verified local input. |
| Linux | Ninja, Clang, pkg-config, GTK3, libayatana-appindicator and libsecret development packages, plus the selected package format's tools. |
| macOS | Xcode/command-line tools, native LLVM/libclang, and Node/npm with appdmg for DMG packaging. |

Build on the matching operating system. Architecture values are amd64 or arm64; Windows/Linux require a matching native build host. Select one command for your target:

Linux packaging supports Debian, pacman, AppImage and zip. RPM is excluded because the current packager ignores uninstall hooks and Core hash protection. See the [uninstall scope and custom XDG limitation](linux/packaging/README.md).

~~~bash
dart setup.dart windows --arch amd64
dart setup.dart linux --arch arm64
dart setup.dart macos --arch amd64
dart setup.dart macos --arch arm64
~~~

Packaging builds the Rust host and separate runtime library, then embeds the final host hash in the Windows/Linux Helper and records a manifest. Keep both native build_assets hooks enabled for packaging. Go and mihomo are not desktop build dependencies. Detailed prerequisites, direct artifact builds and verification commands are in [.agents/project.md](.agents/project.md) and [.agents/commands.md](.agents/commands.md); the [native CI workflow](.github/workflows/build.yaml) checks the six target combinations.

## Attribution and license

The client derives from FlClash and FlClash-Patched and remains under [GPL-3.0](LICENSE). The embedded engine derives from [meow-rs](https://github.com/meow-rs/meow-rs) under its [MIT license](https://github.com/meow-rs/meow-rs/blob/HEAD/LICENSE). The product-specific Rust host stays in our meow-rs fork; bundled dependencies retain their own notices and licenses.
