# proxy

FlClash's desktop system-proxy integration.

- Windows uses a Flutter method channel and WinINet settings.
- macOS uses `/usr/sbin/networksetup` for each active network service.
- Linux uses GNOME/MATE `gsettings` or KDE `kwriteconfig` based on the active
  desktop environment.

The public `Proxy` API validates the port, applies HTTP, HTTPS, and SOCKS
settings to `127.0.0.1`, and returns `false` when the selected platform backend
is unavailable or a command fails.


`Proxy` serializes system mutations. `close()` fences queued/future starts,
waits for an in-progress operation, then restores this instance's changes. Ordinary
stop remains reusable. A new inactive instance never disables another product's
proxy. Cleanup retains the original backend, home, macOS services and Windows
connections; it restores each changed value only while its installed value still
matches. A later endpoint writer keeps its manual activation, and separately
changed bypass/PAC values survive. macOS never changes PAC and refuses unreadable
authenticated credentials before mutation. KDE requires matching `kreadconfig`
and `kwriteconfig`; keys absent before installation are deleted on restore.

Failed writes can have effects. Their snapshots remain owned, cleanup failures
return `false`, and a successor cannot replace an unconfirmed generation. Native
commands have a 20-second deadline, 1 MiB per output stream, and kill/reap on timeout.
Unconfirmed children remain owned and block settings cleanup. These are in-process
leases; forced termination does not provide a persistent proxy recovery journal.
The Rust host's persistent TUN recovery is a separate contract.

Portable tests use process fixtures and the Windows WinINet adapter boundary.
Actual OS restoration is separately opt-in and must run on disposable GitHub-hosted
runners, never a developer's workstation:

- Set `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted` and
  `FLCLASH_MEOW_PROXY_NATIVE_ACCEPTANCE=1`.
- Set `FLCLASH_MEOW_PROXY_EVIDENCE_PATH` to an existing artifact directory's JSON file.
- Linux: run `dart run tool/native_proxy_acceptance.dart` under a disposable
  `dbus-run-session` with GNOME proxy schemas and dconf installed.
- macOS: run the same Dart script with permission to change networksetup settings.
- Windows: build the existing `proxy_test` CMake target with `include_proxy_tests=ON`
  and run `--gtest_filter=ProxyNativeAcceptance.*`.

Each native fixture records baseline/before/installed/after/later-writer states,
checks inactive preservation and owned restoration, and restores its fixture
baseline in a finally/RAII path. Guarded local runs skip real OS mutation. Portable
green checks do not establish native acceptance; retain the separate CI evidence.
