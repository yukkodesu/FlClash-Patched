# FlClash-Meow desktop acceptance

This record distinguishes implementation checks from native release acceptance.
An untested cell remains pending. A declared CI target is not a passing build or
a native runtime result. No installation, service registration or system network
mutation has been performed on the user's workstation by the automated tests.

| Target | Locked host build | CoreController local proxy | Package/install isolation | Native TUN/cleanup |
|---|---|---|---|---|
| Windows x64 | native CI passed at core `604e72e1` | native CI passed; packaged `604e72e1` local E2E passed | pending | `604e72e1` DNS enumeration failed after device creation; final cleanup clean; repair pending |
| Windows arm64 | native CI passed at core `246592dc`; `604e72e1` CI pending | native CI passed at core `246592dc` | pending | pending |
| macOS x64 | native CI passed at core `75b3d420`; final pin pending | native CI passed at client `a357f8ad` | pending | pending |
| macOS arm64 | native CI passed at core `604e72e1` | native CI passed at client `7b9251ef` | pending | fake-IP IPv4 traffic/cleanup passed at core `604e72e1`; global/IPv6 pending |
| Linux x64 | native CI passed at core `604e72e1` | native CI passed at client `7b9251ef` | pending | fake-IP IPv4 traffic/cleanup passed at core `604e72e1`; global/IPv6 pending |
| Linux arm64 | native CI passed at core `604e72e1` | native CI passed at client `7b9251ef` | pending | fake-IP IPv4 traffic/cleanup passed at core `604e72e1`; global/IPv6 pending |

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

## Integration checks on 2026-10-06

- Client `a357f8ad` pins core `75b3d420d3a94208d8ff6db0d59dd5577ef16782`; native cleanup and storage ownership are still separate work in progress.
- Windows CoreController E2E now queries the actual ephemeral DNS endpoint and checks a known local A record. All upstream services are local fixtures; geodata fixture files suppress unrelated network downloads.
- Recovery contract/UI regression: 89 tests passed and Flutter analyze reported no issues. The configuration transaction's entire 39-test suite also passed. A Windows suite-load interruption could not be reproduced by running the six TV navigation cases alone; full regression is still pending.
- [First native CI run](https://github.com/yukkodesu/FlClash-Patched/actions/runs/37340715186): Windows Helper, Rust runtime library and plugin checks passed. Generated localization format, an old host pin's Clippy violations, and macOS LLVM library-path contamination caused failures; these were repaired before the second run.
- [Second native CI run](https://github.com/yukkodesu/FlClash-Patched/actions/runs/37341993846): Windows x64, Linux x64/arm64 and macOS x64/arm64 passed locked host checks, release build, native Rust API build and mandatory CoreController E2E. Windows ARM64 failed in BoringSSL assembly selection; its target-scoped portable C fix is included in the next pin. Dart shard 3 exposed an obsolete NTP view; it was removed at `dbbfff73`, pending the next full run. Other completed shards, Dart format/analyze, Windows Helper, Rust library and plugin checks passed. These results do not prove package installation or native TUN cleanup.
- Local client `f1276589` retains runtime failure feedback and derives active indicators from actual listener state. Focused state regression passed 45 tests; failure contract/action regression passed 36 tests and analysis. Only the start-listener RPC receives the longer timeout needed by the existing 300-second native startup budget.
- Client `da1eb360` pins core `246592dc6e7a957a1403fe148036b590323dcbec`. The actual Windows release harness rebuilt this source, stamped that identity, and built the Helper from its final SHA256 (`a490ccf8a43fe39e473393abeb1938cb7e6337fe802a23d9fa09e547aa923c4b`). Manifest and Helper embedded hash match; the next harness invocation hit both caches. CoreController E2E against that bundled executable passed alongside six facade contract tests, including real DNS, HTTP authentication refusal/acceptance, SOCKS5 authentication refusal/acceptance and TCP transfer. The fixture binds one local non-loopback address because meow always exempts loopback sources from authentication; that limitation is surfaced as a configuration warning.
- Disposable native TUN and actual Windows/Linux Helper lifetime harnesses are wired into the six-target matrix. Their guarded local skips are not native acceptance. Windows privileged product-home/caller file authority is being strengthened after an audit found its constraints weaker than the verified Unix boundary; T1/V1 remain open.
- [Third native CI run](https://github.com/yukkodesu/FlClash-Patched/actions/runs/37350297487), client `691d2d71` and core `246592dc`: all eight Dart regression shards, Dart checks, plugins, Rust API and Windows Helper tests passed. Windows x64 passed mandatory CoreController E2E and the actual privileged Helper harness, including hash mismatch refusal, clean stop, IPC loss, Helper crash and recovery. Its native TUN scenario failed before device setup because Windows PowerShell could not load `Microsoft.PowerShell.Security` under the inherited runner environment; its final recovery record was clean. Unix targets exposed a target-specific Clippy error, repaired in core `5e8fc77`. Windows ARM64 passed native host/Rust API builds and mandatory CoreController E2E; native TUN hit its PowerShell command deadline before setup, and its Helper observation timer expired during a slow native action. These failures are repaired in the fourth run's source and remain subject to native rerun. These results do not establish TUN or complete package acceptance.
- A full Windows x64 Flutter release build at client `618b3e6a` and core `246592dc` produced `FlClashMeow.exe`, the Rust host and native runtime libraries. The packaged host identifies the pinned source; its SHA256 is `936557393b4300b412208f0e85ba9be698586f3525519aab64dd34237d683cf5`, with matching manifest and Helper embedded hash. The release directory contains no legacy `FlClashCore.exe`, `FlClashHelperService.exe` or `mihomo.exe`. This build used a task-local command wrapper to retain the Scoop Rust toolchain environment that Flutter's hook runner filters out; it did not alter the shared SDK or global Rust settings. No installation or native network acceptance is inferred from the build.
- Windows caller authority checkpoint `f8fb8a3c` also passed the real CoreController E2E plus six facade contract tests. The connected named-pipe server's retained process/token authorizes the product home; a separate real-executable test rejects a profile hardlink to an outside file while preserving normal profile reads, HTTP traffic and graceful shutdown. Common storage fixtures cover reparse points, hardlinks, parent replacement, short file names and nested thread-token restoration. The elevated caller-owner case is explicitly scheduled on disposable Windows CI rather than run on the development machine.
- Client `98531fe2` pins verified core integration `f34a0680add1ee6b84751d3c59551a9dc23a6043`, including Windows caller storage authority and the PowerShell module-path repair. Integrated fmt, strict host/common Clippy, 13 host tests and 102 common tests passed; the one elevated storage fixture remains reserved for CI. A fresh full Windows release build passed. Its actual packaged host identifies this source and has SHA256 `324b8a5ea9969f27e51b5becf603c8589d7ff75ddce4614fdc3f4648a315c375`, with matching manifest and Helper embedded hash and no old kernel artifacts. CoreController E2E and six facade contracts passed again using both the host and Rust API DLL from this release directory.
- Client `64f55f57` pins core `604e72e16d67922be390a4ae98823e56f4ee59f9`. A full Windows x64 Flutter release build passed with both native hooks enabled. The actual bundled host reports that exact source; SHA256 `b1e940a6676915eda2af90b52e3618ff3ca067dabfeb13d155e8205fcd344f7e` matches the manifest and embedded Helper hash. Seven real CoreController/facade tests passed using the bundled host and `rust_api.dll`. This is build and ordinary proxy evidence, not installation or privileged network evidence.
- [Fourth native CI run](https://github.com/yukkodesu/FlClash-Patched/actions/runs/37357154622), client `7b9251ef` and core `604e72e1`, enables production package builds. All eight Dart shards, Dart checks, plugins, Rust API and Windows Helper tests passed. Linux x64's completed native job passed locked host/common checks, release/Rust API build and mandatory CoreController E2E. Its privileged fake-IP fixture passed TCP/UDP echo, DNS, normal stop, shutdown, IPC EOF, SIGTERM, forced-exit recovery and final clean restoration. The loopback IP literal remains outside fake-IP capture; the IPv4-only fixture returns AAAA NODATA and does not establish global or IPv6 capture. The actual Linux systemd Helper fixture also passed hash refusal, session stop, IPC loss, service stop/crash/recovery and final uninstall with no Core processes and service `not-found`. Other targets and actual installation packages remain pending.
- The actual installer/UI/uninstall harness is tracked in [meow-package-native-acceptance.md](meow-package-native-acceptance.md). Workstation-safe tests passed, and a read-only Windows release audit found coherent host/manifest/Helper identity. Its six native installer jobs have not run; static updater repository inspection does not establish update download/replacement or rendered Linux tray behavior.
- The fourth run's Linux ARM64 and macOS ARM64 native jobs also completed successfully with the same fake-IP IPv4 traffic and stop/shutdown/IPC EOF/SIGTERM/forced-exit recovery phases and final `clean` restoration. Linux ARM64's actual systemd Helper lifetime/uninstall fixture passed with service `not-found` and no remaining Core. Windows x64 passed ordinary host/common checks, the elevated caller-owner storage fixture and CoreController E2E, then created its Wintun device and route. Its native DNS plan failed when `Get-DnsClientServerAddress` queried a network adapter without that address-family object; final recovery was `clean`. This is a product enumeration failure under repair, not accepted Windows TUN behavior. The run's package jobs depend on all native gates, so this failure prevents production package generation.
