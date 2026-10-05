# Architecture

## Core Integration

FlClash-Meow desktop launches `FlClashMeowCore` as a separate process. The executable is `flclash-meow-host` from the
pinned `core/meow-rs` fork and embeds meow's Runtime directly. The product contract is in
`docs/specs/meow-desktop-client.md`.

- `rust_api` supplies named pipes on Windows and Unix sockets on macOS/Linux. It remains a separate Flutter FFI library
  for IPC, scripting, and hotkeys.
- `lib/core/controller.dart` is the application facade and primary integration-test boundary. `CoreHandlerInterface`
  exposes the service contract; identity/capability negotiation precedes engine-dependent initialization.
- `lib/core/service.dart` composes the transport, RPC client, launchers, and lifecycle owner.
- `lib/core/desktop/transport.dart` owns transport events and replaceable bindings. `rpc_client.dart` correlates requests,
  enforces timeouts, and fences application RPC during shutdown while allowing bounded session shutdown.
- `lib/core/desktop/lifecycle.dart` is the sole process convergence owner. `launcher.dart` supplies direct and
  session-scoped Helper leases; `helper_client.dart` implements the Helper's separate local HTTP contract.
- `core/meow-rs/crates/flclash-meow-host` owns config validation/translation, Runtime start/stop, RPC, events,
  identity/capabilities, and process shutdown. Engine changes suitable for upstream remain separate from the coupled host.

Legacy mobile sources are outside this desktop migration and are not built or released by this product.

## Listener Exposure

The desktop profile adapter preserves imported YAML and derives a runtime configuration using the pinned host's
capability contract. Unsupported fields/protocols fail validation before Runtime starts. Retaining a Flutter model field
does not imply meow implements it; configuration rejection must be actionable and visible.

System proxy follows the effective running listener endpoint. Loopback binding limits exposure to the local machine but
does not authenticate other local programs. TUN requires a privileged launch; a requested TUN start must not silently
succeed through an unelevated fallback. Capability gating and runtime validation must remain consistent.

## Lifecycle Ownership And Convergence

### Shared Flutter Layer

`CoreController.start()`, `restart()`, `stop()`, and `close()` are the only shared lifecycle facade. `close()` is terminal;
callers must not try to reuse a closed platform implementation.

`CoreAction` in `lib/providers/actions/core.dart` owns the user-facing Core status and setup sequence:

- `startCore()` publishes `connecting`, starts the platform Core, publishes `connected`, then initializes Core state. A
  startup error publishes `disconnected` and displays the error.
- `restartCore()` coalesces overlapping callers behind one worker. `_requestedRestartRevision` records newer requests,
  while `_latestExplicitStart` retains the newest requested post-restart running intent. After the lifecycle restart and
  `initCore()`, the worker reapplies profile/running state until it has consumed the latest revision.
- The provider is an orchestration and presentation layer, not a process owner. Platform lifecycle code remains responsible
  for determining whether a Core process/service is actually running.

Application exit is centralized in `SystemAction` and `SystemExitCoordinator`:

1. Optionally save config and clean up DNS, system proxy, and tray resources in parallel.
2. Close the desktop window.
3. Call terminal `CoreController.close()`.
4. Exit the application exactly once.

The coordinator is idempotent, continues later cleanup steps after an earlier error, preserves the first error for the
caller, and uses a three-second watchdog as an emergency application-exit path. `Application.dispose()` and
`CoreManager.onCrash()` do not independently destroy Core; this avoids competing shutdown owners.

### Desktop Lifecycle

`DesktopCoreLifecycle` is a latest-desired-intent reconciler, not a queue that blindly executes every request:

- Public intents receive monotonically increasing revisions and target running, restarted, stopped, or closed.
- Observable phases are `idle`, `starting`, `running`, `stopping`, `failed`, and `closed`.
- A completed command reports `applied`, `coalesced`, or `superseded`, allowing callers and tests to distinguish a command
  that won from one satisfied or replaced by a newer compatible intent.
- Startup opens or replaces the IPC transport, resolves a launcher, generates a 128-bit lowercase hexadecimal session ID,
  launches Core, and waits for the matching connection. Windows additionally verifies that the named-pipe peer PID equals
  the process PID returned by the Helper lease.
- Each running session retains its process owner, lease, PID, session ID, and transport connection generation. Stop waits
  for both process-exit confirmation and the matching disconnect generation; a missing disconnect replaces the transport
  before later starts.
- An unconfirmed process exit is retained as an unconfirmed lease. New start/restart intents fail until ownership can be
  cleaned up, preventing two Core instances from being treated as the active session. Terminal close may continue on a
  best-effort basis because the application is exiting.
- An unexpected disconnect or transport failure while running is converted to `DesktopCoreFailure`, the owned process is
  cleaned up, and `CoreService` emits a Core crash event for the normal UI recovery path.

Direct launch is used on macOS, inside an AppImage, and as the Windows/Linux fallback when the privileged Helper is not
ready. When the Helper is ready, it owns the Core child and Dart owns it through a session-scoped lease.



## Core Protocol And Event Delivery

The shared protocol uses `CoreMethodCall(id, method, arguments)` and `CoreMethodResponse(id, result, error)` in both
directions. The envelope is the only JSON serialization layer: keep arguments, results, and event data as structured JSON
values rather than embedding pre-encoded JSON strings. Plain domain strings, such as country codes or provider contents,
remain strings.

The Rust host owns bounded request concurrency, response delivery, and separate state/bulk event streams. Responses
retain request IDs; shutdown acknowledges before closing the connection. Payloads represent the pinned Runtime's
capabilities, and missing capabilities are reported explicitly.

Desktop RPC accepts an event object or list. Listener dispatch isolates observer failures. IPC framing, malformed
requests, backpressure, and shutdown have separate Rust/Dart contract tests. CoreController E2E verifies application
behavior through the real host.

## User-Facing Core And Delay Feedback

`CoreStatusButton` in `lib/views/dashboard/widgets/core_status_button.dart` is the desktop dashboard's status/restart
surface. It is shown only outside dashboard edit mode and only when `coreLib == null`:

- Provider state remains authoritative. The widget keeps a separate display-only status so a fast
  `connecting -> connected` transition still shows at least 600 milliseconds of progress instead of flashing.
- The hold arms only after an observed transition to `connecting`; mounting while already connecting does not invent a new
  delay. A real `disconnected` transition cancels the hold immediately so failure is never hidden, while a long-running
  connecting state remains visible after the timer expires.
- Taps during the display hold or while the provider is genuinely connecting are inert. Connected/disconnected taps show
  the appropriate confirmation and delegate restart to `CoreAction`; the widget never starts Core directly.

Proxy delay testing follows the same failure-safe UI rule. `proxyDelayTest()` records an in-progress zero delay, writes the
real result on success, and logs plus records `-1` on exceptions. `DelayTestButton` reverses its animation in `finally`, so
an RPC failure cannot leave the control permanently spinning.

## Settings Rows

`lib/widgets/config_item.dart` holds the shared settings-row vocabulary: `ConfigToggleItem`, `ConfigOptionsItem`,
`ConfigTextItem`, and `ConfigListInputItem`. Each takes a `selector` (a `ProviderListenable`, normally
`someProvider.select(...)`) and an `onChanged(ref, value)` writer, and watches its own selector so changing one setting
rebuilds one row instead of the whole section. Titles and subtitles are `ConfigLabel` callbacks that receive
`AppLocalizations`, which keeps literal labels such as `IPv6` and localized labels in the same shape.

Build settings screens from these directly, or from a file-local helper that binds one provider once — see `_dnsToggle`
in `lib/views/config/dns.dart` and `_appSettingToggle` in `lib/views/application_setting.dart`. Declare a named
`ConsumerWidget` only when a row is genuinely reused across screens, as `lib/views/config/network.dart` rows are by
`lib/views/dashboard/widgets/quick_options.dart`. Rows with bespoke behaviour — a custom dialog, a derived value, or a
second provider write — stay hand-written rather than growing extra parameters on the shared items.

## State Management

Provider files in `lib/providers/`:

- `app.dart`: runtime/UI state, logs, traffic, delays, loading, navigation.
- `config.dart`: persistent config providers, app settings, theme, VPN, proxy style.
- `state.dart`: derived/computed providers, navigation, proxy, tray, color scheme.
  Like `action.dart`, this is an entry point only: the providers live under
  `lib/providers/state/` and are joined with `part` directives, so importing
  `state.dart` still reaches all of them.
  - `state/proxies.dart`: group and proxy lists, filter/sort, delay, selection.
  - `state/navigation.dart`: navigation items, current page, dashboard, more tools.
  - `state/system.dart`: tray, VPN params, access control, hot keys, shared state.
  - `state/theme.dart`: dynamic color, color scheme, brightness.
  - `state/profile.dart`: profiles, current profile, clash config, setup state.
  - `state/overwrite.dart`: custom overwrite validity and the staged group/rule notifiers.
- `action.dart`: business logic notifiers, setup, backup, core lifecycle, proxy selection.
- `core.dart`: `coreHandlerProvider`, the container-scoped handle on `CoreController`.
- `database.dart`: Drift database provider wrappers.

### Reaching Singletons

`lib/common/` and `lib/core/` publish process-wide singletons (`coreController`,
`system`, `preferences`, `appPath`, `request`, and others). Code that already has a
`Ref` or a `WidgetRef` reads them through a provider instead, so a test can scope a
fake to one `ProviderContainer` rather than swapping a global and relying on a
tearDown to put it back.

`coreHandlerProvider` is the established case. Every call site under
`lib/providers/`, `lib/manager/` and `lib/views/` goes through it; notifiers and
`ConsumerState` classes that touch Core repeatedly hold it as
`CoreController get _core => ref.read(coreHandlerProvider)`.

Tests override it with `coreHandlerProvider.overrideWithValue(CoreController.scoped(fake))`,
which does not claim the singleton. `CoreController.test` does claim it, and is
only for tests that have not moved yet. Prefer the scoped override even when a
test passes either way: a test that claims the singleton makes the global and the
provider resolve to the same fake, so it cannot tell a provider read from a
leftover global read, and a half-migrated call site stays green.

One deliberate exception: `globalState` owns the `ProviderContainer`, so it cannot
itself live in one. Code without a `Ref` reaches providers through
`globalState.container.read(...)`. The remaining call sites are `lib/core/lib.dart`,
`lib/common/print.dart`, and the tray `read` callback in
`lib/providers/actions/system.dart` — all singletons or platform callbacks with no
`Ref` in scope.

`lib/models/profile.dart` no longer reaches Core. `Profile.saveFile` and
`Profile.update` take a `ValidateConfig` callback, and every caller passes
`(path) => _core.validateConfig(path)`, keeping the Core handle lazy so a profile
path that never validates never resolves the controller.

The UI layer must not reach a process-wide singleton directly.
`test/lint/ui_layer_singleton_test.dart` scans `lib/views`, `lib/widgets`,
`lib/pages` and `lib/features` for `globalState.container` and the bare
`coreController` global and fails the run on either. Widgets that need Core hold
`CoreController get _core => ref.read(coreHandlerProvider)`.

`globalState.measure` and `globalState.theme` stay global on purpose. Both are
context-derived caches assigned by `ThemeManager`, and tests already scope them by
assigning in the app builder (see `test/helpers/test_app.dart`); moving them into
providers would touch every layout call site without changing behaviour.

`globalState` in `lib/state.dart` is a singleton holding ambient app state — the
package info, the measure and theme, the container, and the start/stop flags —
plus `safeRun`/`loadingRun`. Startup orchestration is **not** on it: `init` and
`attach` live in `lib/bootstrap.dart`, above `lib/common`, because they drive the
window, the autostart entry, the tray and the permission prompts. Providers are
generated into `lib/providers/generated/`.

The root navigator key lives in `lib/common/navigator.dart` as `rootNavigatorKey`;
`globalState.navigatorKey` is a getter onto it. `lib/common/dialog.dart` reaches
the key directly, so the dialog helpers no longer import `lib/state.dart`.

### Platform Layering

`lib/common/common.dart` deliberately does not export `tray.dart`, `window.dart`,
`launch.dart`, `system_dns.dart`, or `permission.dart`. Those five modules import
`tray_manager`, `window_manager`, `launch_at_startup`, and `screen_retriever`;
exporting them put those packages in the compile graph of all 132 files that
import the barrel for a string helper. Import the specific module instead.

`test/lint/platform_layering_test.dart` enforces four rules. Three are local: the
barrel never re-exports one of those five modules, nothing under `lib/common`,
`lib/enum` or `lib/models` other than those five imports a desktop platform
package, and `lib/common` never imports the `lib/manager/manager.dart` barrel
(import the single manager needed, as `common/context.dart` does with
`manager/status_manager.dart`). The fourth walks the barrel's whole transitive
closure and fails if *any* file in it imports one of those packages. That one is
the real invariant — the local rules only stop the shortest path, and every leak
found so far arrived through a longer one.

Four consequences are already in the tree:

- `System.back` and `System.exit` no longer touch `window`; the window half of
  both lives in `SystemAction`.
- `KeyboardModifier.toHotKeyModifier()` moved from `lib/enum/enum.dart` to
  `lib/manager/hotkey_manager.dart`, its only consumer.
- Startup orchestration moved off `GlobalState` into `lib/bootstrap.dart`.
  `common/num.dart`, `common/print.dart` and `common/request.dart` import
  `state.dart` for `theme`, `container` and `packageInfo`/`ua`, so anything
  `GlobalState` reaches lands in the barrel's closure; the ambient state it now
  holds reaches nothing platform-specific.
- `SystemAction` talks to `WindowPort` and `TrayPort` from
  `lib/common/app_ports.dart` instead of importing `common/window.dart` and
  `common/tray.dart`. `lib/bootstrap.dart` binds `windowPort` and `trayPort` to
  the real implementations; both stay null in tests, where every call through
  them is a no-op. A test that needs the real tray assigns `trayPort` itself, as
  `test/common/tray_menu_test.dart` does.

Narrow the barrel imports too: `lib/providers/providers.dart` re-exports
`action.dart`, so importing the providers barrel from `lib/common` or from
`providers/app.dart` reaches the whole action layer. Those three now import
`providers/state.dart` and `providers/config.dart` directly.

The same shape appeared twice more, without a platform package involved: a data
type in a lower layer holding the widget that renders it, which drags the whole
view tree into the barrel's closure.

- `lib/common/navigation.dart` was a route table building view widgets. It is
  now `lib/views/navigation.dart` implementing `NavigationPort`, which
  `providers/state/navigation.dart` reads through and `bootstrap.init` binds.
  Unbound it yields no items, so a test that renders navigation assigns
  `navigationPort` itself, as `test/pages/home_test.dart` does.
- `DashboardWidget` carried a `GridItem` per value, so `lib/enum/enum.dart`
  imported the dashboard cards — and `lib/widgets/widgets.dart` with them. The
  enum is persisted in the app settings, so it is back to plain data; the
  mapping lives in `lib/views/dashboard/widget_registry.dart`, the reverse
  lookup relying on the branches returning canonical consts.

Together those took the closure from 258 files to 187, with nothing under
`lib/views` left in it. `test/lint/platform_layering_test.dart` pins that
directly: the barrel's closure must contain no `lib/views` file. Data the
provider layer needs from the UI layer goes through a port in
`lib/common/app_ports.dart` rather than an import in the other direction.

### High-Frequency Buffers

`logsProvider`, `requestsProvider` and `trafficsProvider` hold a `FixedList`
(`lib/common/fixed.dart`), which trades a normal copy-on-write for a shared
buffer tagged with a generation counter:

- `append` mutates the buffer in place and returns a new wrapper one generation
  ahead. That is what providers publish, so `updateShouldNotify` still fires.
- `list` returns an immutable copy, cached until the next mutation. It must stay
  eager: an older wrapper shares the buffer, so its contents move on. Anything
  that needs a stable view has to read `list` at the moment it is notified, not
  hold the wrapper and read later.
- Consumers that only need to know *that* the buffer changed watch `revision`,
  not `list` — selecting on the list snapshots and deep-compares the whole
  buffer on every arrival, which is what this design exists to avoid. See
  `lib/views/logs.dart` for the pattern: watch the generation, snapshot inside
  the throttled callback.

`add`/`clear` mutate in place without advancing the generation; use them only on
a buffer you own outright (seeding, resets, tests), never on published state.

## Database

The app uses Drift/SQLite in `lib/database/`. Current schema version is 2.

Tables:

- `Profiles`
- `Scripts`
- `Rules`
- `ProfileRuleLinks` (`profile_rule_mapping`)
- `ProxyGroups`
- `IconRecords` (`icon_records`)

Rule scenes distinguish global added rules, profile added rules, profile custom rules, and disabled links. Rule and proxy-group ordering use fractional indexing.

Generated Drift output lives in `lib/database/generated/database.g.dart`. After schema changes, run code generation and add or update focused database tests under `test/database/` when converter or migration behavior changes.

## Manager Stack

Managers are nested `InheritedWidget`/`StatefulWidget` components built by `buildManagerStack()` in `lib/application.dart`:

```text
AppEnvManager > LocaleManager > StatusManager > ThemeManager > BackManager
  > [Desktop: WindowManager > TrayManager > HotKeyManager > ProxyManager]
    [Mobile: MobileManager > TileManager]
  > AppStateManager > CoreManager > ConnectivityManager
  > [Desktop: WindowHeaderContainer] [Android: VpnManager]
  > app content
```

Each manager in `lib/manager/` handles a specific platform concern. The
platform slots are exclusive: no desktop manager appears on mobile, no mobile
manager appears on desktop, and the Android-only `VpnManager` never wraps iOS.

The order is an ownership contract, not a layout detail. `ConnectivityManager`
sits below `CoreManager` because its `onConnectivityChanged` callback reads
Core-backed state, so Core must already be mounted when it fires. `StatusManager`,
`ThemeManager`, and `BackManager` sit above the platform managers so every
platform can surface messages, read the theme, and route keyboard, gamepad, and
mouse back actions through Flutter's pop route handling.

`buildManagerStack()` is a pure function of `isDesktop`, `isAndroid`, the
connectivity callback, and the app content, so `test/application_test.dart`
asserts the whole order by constructing the stack without mounting it. Changing
the nesting means updating both this diagram and that test.

## Core Controller and Actions

`lib/core/controller.dart` (`CoreController`) is a singleton facade over `CoreHandlerInterface`. Public methods delegate to the desktop service over local IPC. It has an `@visibleForTesting` constructor and `resetInstance()` for test injection.

`lib/providers/action.dart` is the public library entry point for action
providers. The Riverpod notifier implementations are split by responsibility
under `lib/providers/actions/` and joined to the entry point with `part`
directives, so consumers continue to import the same public API:

- `CommonAction`: update check and common UI operations.
- `SetupAction`: config setup and TUN management.
- `BackupAction`: backup/restore with WebDAV sync.
- `CoreAction`: core lifecycle, initialization, coalesced restart, and post-restart profile/running-state application.
- `SystemAction`: system integration, tray, coordinated resource cleanup, terminal Core close, exit, and brightness.
- `StoreAction`: profile storage operations.
- `ThemeAction`: theme state updates.
- `ProxiesAction`: group management and proxy selection.
- `ProfilesAction`: profile CRUD, auto-update, import.
- `GeoResourceAction`: geo resource updates and URL configuration.
- `UpdatingAction`: stale sweep over `UpdatingKeys`.

`UpdatingKeys` in `lib/providers/app.dart` owns every per-entity updating flag; `isUpdatingProvider(key)` is the
read-only view widgets watch. Callers pair `start(key, scope: ...)` with `stop(key, operation)` using the returned
token, so overlapping operations on one key are reference counted and a late `stop` from a superseded operation
cannot clear a newer one. Keys started with `UpdatingScope.core` depend on the Core to make progress, so
`UpdatingKeys` discards them itself when `coreStatusProvider` leaves `connected` — that is the state's own
invariant, not a policy, and it must stay inside the notifier where no warm-up ordering can miss it.
`UpdatingScope.local` keys (profile updates run entirely in Dart) survive a Core restart. `UpdatingAction` holds
only the policy half: the periodic sweep that discards a key stuck past `updatingStaleTimeout`. Do not move the
timeout back into `UpdatingKeys`, and do not widen the disconnect reset to every scope.

## Platform Managers

Desktop:

- `WindowManager`
- `TrayManager`
- `HotKeyManager`
- `ProxyManager`

Mobile:

- `MobileManager`
- `TileManager`
- `VpnManager` (Android only)

Shared:

- `ConnectivityManager`
- `CoreManager`
- `AppStateManager`
- `StatusManager`
- `ThemeManager`
- `BackManager`

## Build System

`setup.dart` writes `env.json` and packages desktop releases with the existing `chenx-dust/flutter_distributor` fork.
It accepts only `windows|linux|macos` and `amd64|arm64`, requires both native hooks enabled, and keeps the Linux package
formats and Windows portable `config/`. Mobile packaging and Go microarchitecture variants are outside this build.

`plugins/setup/hook/build.dart` invokes `CoreBuilder` from the pure Dart `plugins/setup/setup_hooks` package.
`buildPlatform` builds the pinned host in release mode, hashes the executable, then builds the Windows/Linux Helper in
release mode with that exact hash and publishes the manifest. macOS stages the host alone. `plugins/rust_api` is built
independently by Flutter Rust Bridge's native hook.

- `HostBuilder` invokes locked Cargo for the target triple and embeds Git HEAD through `MEOW_HOST_COMMIT`. Sources, Git
  commit, configuration, harness inputs, Rust/CMake versions, native environment, and selected Wintun DLL contents enter
  its fingerprint. Helper inputs additionally include the final Core SHA256.
- The cache under `.dart_tool/setup_build_cache/` uses per-target locks and publishes records only after success. A hit
  requires unchanged inputs and recorded outputs. Failed compilation preserves the last staged binary and manifest,
  while reporting failure so packaging cannot continue with them.
- Tool lookup adds rustup/Homebrew paths and Visual Studio's bundled CMake/Ninja directories when needed. Missing tools
  are infrastructure failures; failed compilation is a build failure.
- Hooks have no Flutter mode/caller information and always build release host/Helper binaries. User defines
  `setup.build_assets` and `rust_api.build_assets` are the local test switches. Packaging refuses disabled hooks.
- Windows/Linux CMake and macOS Stage Core copy artifacts from `libclash/<platform>/`. The Debug Windows install step
  stops only a stale Helper at the exact output path before replacing it.
- macOS packaging supplies architecture-specific Xcode configuration. CI executes x64 on `macos-26-intel` and ARM64
  on `macos-26`, checking the runner's native Rust triple before building.

Independent product identities are `FlClash-Meow` display name, `FlClashMeow` executable, `FlClashMeowCore` host,
`FlClashMeowHelperService` Helper, `com.yukko.flclashmeow` bundle ID, and `flclash-meow` URI/package ID. Helper protocol 6
and its wire header remain unchanged; service, port/socket, and Core IPC namespaces are isolated.

Defaults are in `plugins/setup/setup_hooks/lib/src/options.dart` and `build_config.yaml`. Six native CI jobs build/test the
host and Rust API and run CoreController E2E with explicit artifacts. Manual dispatch also builds desktop packages
without publishing a release. Elevated TUN and install/uninstall evidence is recorded separately in
`docs/specs/meow-desktop-acceptance.md`.

## Local Plugins

- `setup`: build-time harness for the embedded Rust host and privileged Helper, driven by a Dart build hook; no runtime Dart API.
- `proxy`: system proxy configuration.
- `rust_api`: runtime Flutter Rust Bridge FFI package built through Native Assets. See below.
- `tray`: system tray for Linux, macOS and Windows. Written for FlClash; replaced the `tray_manager` fork.
- `wifi_ssid`: Wi-Fi SSID detection.
- `flutter_distributor`: app packaging/distribution.

## rust_api Crate Layout

`plugins/rust_api` has no platform folders. `hook/build.dart` is a Dart build hook: Flutter runs it for every platform
build and for `flutter test`, and `flutter_rust_bridge_hooks` (over `native_toolchain_rust`) compiles the crate with
Cargo and registers `librust_api` as a code asset that Flutter bundles and signs. The build runs
`rustup run <channel>`, so `rust/rust-toolchain.toml` must pin an exact channel and list every target the project ships;
the hook refuses `stable` and a target missing from that list. `rustup show` installs the pinned toolchain and those
targets on first use.

`plugins/rust_api/rust/src/` separates the bridge boundary from the code behind it:

- `api/` is the only input flutter_rust_bridge parses (`rust_input: crate::api`). Every function there is a thin
  delegation, so the generated bindings stay identical on every platform.
- `ipc/` implements the desktop socket server: `frame` (length-prefixed framing and the write backoff), `queue` (the
  bounded send queue), `platform` (socket cleanup, Windows peer credentials and the non-blocking pipe reader), and
  `server` (lifecycle, accept loop, and the `RUNNING`/`STATE` globals).
- `script/` runs profile override scripts on QuickJS through `rquickjs`.
- `hotkey/` registers desktop global shortcuts through `global-hotkey`: `keys` maps Flutter USB HID usages to key
  codes, `owner` runs every registration on the thread the platform binds it to (a dedicated message-loop thread on
  Windows, the main dispatch queue on macOS, in place on Linux), and `service` owns the registry and forwards presses
  to Dart. Linux is X11 only; a Wayland session without XWayland gets an error rather than a silent no-op.

What a platform does not use, it does not compile. `interprocess` and `global-hotkey` are declared under
`cfg(not(target_os = "android"))`, and `ipc/mod.rs` and `hotkey/mod.rs` swap in their `unsupported.rs` there, because
Those Android gates are retained source and are outside the desktop release scope. Adding a capability follows the same
shape: implement it in its own module, gate the dependency by target, and keep the `api/` entry point unconditional.

`RustLib.init()` runs on every platform now, not only desktop — the script engine is shared.

## Profile Script Engine

`lib/common/javascript.dart` sends the profile as JSON to `evaluate_script`, which runs `main(config)` on QuickJS and
returns the JSON the script produced. Nothing about the script runs in Dart.

- QuickJS is compiled from source for the target being built, which is what removed the prebuilt `quickjs-c-bridge`
  binaries: `flutter_js` shipped x64 Windows and desktop-only libraries, so Windows ARM64 could not start (#2361).
- `rquickjs` carries pre-generated bindings for every target this project builds except the Android and iOS ones, so those
  builds enable its `bindgen` feature. That needs the NDK's own libclang and sysroot: `native_toolchain_rust` exports
  the sysroot through `BINDGEN_EXTRA_CLANG_ARGS_<target>`, and `hook/build.dart` adds `LIBCLANG_PATH` from the NDK
  toolchain Flutter hands the hook, because bindgen otherwise loads whatever libclang the host has, or none.
- Evaluation is bounded: a 10-second interrupt deadline and a memory ceiling, because a script that never returns would
  otherwise hold the profile forever. `console` is installed before the script runs, since scripts written for other
  clients log as they work.
- `rust/tests/fixtures/profile_script.js` is the compatibility regression: an overwrite written for the suite that
  performs the transform real ones perform, so it exercises `Map`/`Set`, spread, destructuring, optional chaining,
  nullish coalescing, `Object.fromEntries`, named capture groups and lookbehind in one pass. Keep it first-party and
  free of external URLs — vendoring somebody's published script here carries their attribution and their links.

## Rust Helper Service

`services/helper/` is the privileged helper that starts the core elevated so TUN works. It ships on Windows and Linux
and is built by the setup build hook alongside the Core, which always compiles the Helper in Rust release mode
after calculating the SHA256 of the Core produced for the active Flutter configuration.

The helper owns its Windows Service Control Manager lifecycle through two elevated commands:

- `FlClashMeowHelperService.exe install` stops and removes any stale registration, creates the auto-start service for the
  current executable path, starts it, and waits for the running state.
- `FlClashMeowHelperService.exe uninstall` stops the service, waits for shutdown, removes its registration, and is also used
  by the Windows package uninstaller.

The Dart layer only launches the helper's `install` command through `ShellExecuteW`; it does not compose `sc.exe`,
`taskkill`, or `cmd.exe` command lines.

Linux takes the same shape with systemd in place of the Service Control Manager, and the same install timing: nothing
is registered at package install, and `Linux.registerService` asks for elevation only when TUN authorization needs it.

- `FlClashMeowHelperService install`, run through `pkexec` so polkit raises the system prompt, writes
  `/etc/systemd/system/flclash-meow-helper.service` for the current executable path and enables and restarts it. It reads
  `PKEXEC_UID`/`SUDO_UID` to learn who asked, and refuses to install without one — there would be no account to grant
  the socket to. It also refuses a Helper whose binary or directory is not root-owned and non-writable (a unit runs it
  as root at every boot, so an unpacked bundle would be a standing escalation), and refuses to replace a unit already
  installed for a different UID rather than restart the service out from under that account.
- That ownership check is why the `flutter_distributor` fork normalizes the packaging tree to 0755/0644 before
  `dpkg-deb`, `rpmbuild` and `appimagetool` run: they record modes verbatim, and Ubuntu's per-user default umask
  of 002 would otherwise ship `/opt/flclash-meow` as 0775, which the installer rejects as group-writable.
- The rpm spec sets `debug_package` and `__os_install_post` to nil for the same reason: rpmbuild's find-debuginfo and
  brp-strip rewrite `FlClashMeowCore`, and a Core whose SHA256 no longer matches the Helper's embedded value is refused at
  `/start`. A requested TUN start must surface this failure instead of falling back to an unelevated Core.
- `FlClashMeowHelperService uninstall` disables the unit, removes it and reloads systemd.
- The unit carries `Group=` (the owner's primary GID), `RuntimeDirectory=flclash-meow`, the owner's UID/GID in
  `FLCLASH_MEOW_HELPER_OWNER_UID`/`_GID`, a double-quoted `ExecStart=` with `%` escaped, and `Restart=on-failure` under a
  start limit so a broken unit ends up failed instead of restarting forever. The helper serves
  `/run/flclash-meow/helper.sock` at mode `0660`, additionally drops any connection whose `SO_PEERCRED` UID is not the
  owner's, logs and retries an `accept` failure instead of letting hyper end the server, and handles SIGTERM so
  `systemctl stop` still runs its own Core teardown.
- `/start` additionally requires the Core address to be a socket owned by the owner UID before spawning, since the
  Core connects to it as root.
- The Core is spawned with the owner's real UID and an effective UID of 0, which is what a setuid Core would have had.
  Rust runtime files must respect that owner identity; native acceptance checks that elevated runs do not leave a
  root-owned data tree in the user's home.
- On Linux and macOS, an app already running with effective UID 0 skips authorization and launches the Core directly,
  inheriting its existing privileges. `System.isRunningAsRoot` reads `geteuid()` rather than an environment variable;
  Linux excludes this case from `hasHelperService`.
- An AppImage has neither a stable executable path nor a writable Core, and its FUSE mount is `nosuid`, so a non-root
  app reports TUN authorization as unavailable. An app already running as root uses the same direct-launch path above.
- A Linux host without systemd (`/run/systemd/system` absent) has no Helper: `system.hasHelperService` is false there,
  readiness is the `stat` check, and `pkexec` sets the setuid bit on the bundled Core as before.

In every Flutter build mode `/start` opens the fixed Core executable beside the Helper without write/delete sharing,
validates it against the SHA256 embedded only in the Helper, and keeps that handle open through process creation.
`/ping` only compares the requested `coreSha256` with the Helper's embedded value and checks the fixed Core path exists;
it never hashes the Core. Protocol version 6 uses 32-character lowercase-hex session ownership:

- `GET /ping?coreSha256=...` returns the current Helper executable path with `x-flclash-helper-protocol` when the
  requested SHA matches.
- `POST /start` rejects unknown JSON fields, validates `{address, sessionId}`, then releases any previously managed Core
  before verifying the Core — so every outcome, including a rejected one, leaves the Helper owning no Core — and returns
  `{sessionId, pid}`.
- `POST /stop` validates `{sessionId}` and only stops the matching managed Core. A session mismatch is HTTP 409.
- `GET /logs` exposes the bounded recent Helper/Core stderr buffer with `no-store` caching.

Endpoints bind only to `127.0.0.1:47891` on Windows and to `/run/flclash-meow/helper.sock` on Linux, and do not use
request-token authentication. Lifecycle safety comes from the fixed executable/hash, the strict address namespace
(`\\.\pipe\FlClashMeowCore_<32 hex>` on Windows, `/tmp/FlClashMeowSocket_<digits>.sock` on Linux), the session-scoped stop
contract, Dart-side peer-PID verification on Windows and, on Unix, the Core socket that `plugins/rust_api` sets to
mode `0600` so only the owning user (and the root-effective Core) can connect. When the Helper service itself shuts
down, it unconditionally stops the Core process it owns; under systemd the unit's control group does the same.
