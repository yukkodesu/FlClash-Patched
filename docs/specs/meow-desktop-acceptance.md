# FlClash-Meow desktop acceptance

This record distinguishes implementation checks from native release acceptance.
An untested cell remains pending. A declared CI target is not a passing build or
a native runtime result. No installation, service registration or system network
mutation has been performed on the user's workstation by the automated tests.

| Target | Locked host build | CoreController local proxy | Package/install isolation | Native TUN/cleanup |
|---|---|---|---|---|
| Windows x64 | development host built; pinned package pending | HTTP, delay, start/stop passed; connection adapter retest pending | pending | pending |
| Windows arm64 | pending | pending | pending | pending |
| macOS x64 | pending | pending | pending | pending |
| macOS arm64 | pending | pending | pending | pending |
| Linux x64 | pending | pending | pending | pending |
| Linux arm64 | pending | pending | pending | pending |

## Reproducible ordinary proxy check

Build the pinned `core/meow-rs` host and the platform's `rust_api` library. Set
`FLCLASH_MEOW_HOST` to the actual executable and
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` to the library directory. Run
`flutter test test/core/meow_host_integration_test.dart --reporter expanded`.
This test uses local origin servers, temporary product data and the production
IPC transport. It must run with these variables in dedicated native CI; a skipped
test in the general Dart suite is not acceptance evidence.

## Required native records

- Verify ordinary proxy configuration, authentication, cold start, tray,
  shortcuts, autostart, update source and independent install/uninstall paths.
- Verify each advertised fake-IP/global TUN mode with TCP, UDP, DNS, IP literals
  and its stated IPv6 behavior. Record authorization failure and ordinary proxy
  fallback, interface changes and occupied listener/device conflicts.
- Capture owned DNS/routes before start, after ready and after stop/restart/exit.
  Verify another writer's later network changes are preserved. Record partial
  setup failure, cleanup failure and inability to confirm prior generation exit.
- Exercise client IPC loss, host crash and privileged Helper loss in a disposable
  environment; record residue detection/recovery rather than assuming Drop runs.
- Verify Windows named-pipe PID, SCM/Job Object, Linux peer UID/cgroup/ownership
  and macOS privileged launch on their actual operating systems.
- Check final package host/hash manifest/Helper agreement for every architecture.

CI run links and exact source commits will be added as results become available.
Unverified native behavior keeps T1/V1 open and the client PR in draft.
