# Desktop build harness

The setup and `rust_api` hooks resolve the macOS SDK and Apple compiler through
`xcrun`. When Flutter supplies an Xcode compiler, its Developer directory selects
the SDK even though the hook environment omits `DEVELOPER_DIR`. Target-specific
Cargo compiler, linker, archiver and bindgen variables use that selection; CMake
also receives the SDK and deployment target. Hooks use Flutter's requested macOS
minimum. Direct host builds use `MACOSX_DEPLOYMENT_TARGET`, defaulting to 12.0.

The host cache includes the resolved environment, compiler/SDK versions and SDK
settings files. Both hooks register those settings as dependencies.

Build probe `37374536042` at client `d675cea` / Core `b5ae847` failed on both Macs:
ring could not find `TargetConditionals.h`, and ARM64 blake3 could not find
`assert.h`. Xcode had SDK 26.2 and deployment target 12.0; hook Cargo instead used
bare `cc`, no sysroot, and a derived 26.2 minimum. `hooks_runner` filters these
environment variables, and `native_toolchain_rust` also removes Xcode from PATH.

The public `buildPlatform` subprocess fixture reproduced missing SDK/compiler
environment before the repair. Windows then passed all 36 harness tests, including
both Apple architecture requests, selected-Xcode paths containing spaces, SDK
metadata changes and SDK switches invalidating the cache. The fixture substitutes
tool executables; it does not establish Apple compilation or installer success.
Both macOS package builds still require a native CI rerun.
