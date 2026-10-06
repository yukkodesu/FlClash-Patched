# Rules

These are repository coding and testing conventions. Codex command permission rules belong in `.codex/rules/*.rules`; see `.agents/agent-config.md` before adding those.

## Dart and Flutter Style

The lint set lives in `lint_options.yaml` at the repo root. The root `analysis_options.yaml` and every local plugin under
`plugins/*` include it, so application and plugin code are held to the same rules. Add or change a rule there, not in an
individual `analysis_options.yaml`; those files carry only their own `analyzer.exclude` entries.

`lint_options.yaml` enforces these non-default rules:

- `prefer_single_quotes: true`: always use single quotes.
- `require_trailing_commas: true`: use trailing commas in multi-line argument lists.
- `sort_child_properties_last: true`: `child:` must be the last named parameter.
- `avoid_print: true`: do not use `print()` calls.
- `prefer_const_constructors: true` and `prefer_const_declarations: true`.
- `prefer_final_locals: true` and `prefer_final_in_for_each: true`.
- `always_declare_return_types: true`.
- `only_throw_errors: true`: throw an `Exception` or `Error`, never a bare `String`.

Failures whose whole content is a message meant for the user throw
`MessageException` from `lib/common/exception.dart`. Its `toString()` is the bare
message, which is what `globalState.safeRun` surfaces in the dialog, so the
user-facing text is unchanged from the older `throw someMessage` idiom while the
throw stays catchable as an `Exception` and carries a stack trace. Assert on it
with `isA<MessageException>().having((e) => e.message, 'message', ...)`, not on a
raw string.

### Corner Radius

Rounded corners are superellipses everywhere, not circular arcs. Use the superellipse API at each layer:

- Shapes: `RoundedSuperellipseBorder` instead of `RoundedRectangleBorder`.
- Clips: `ClipRSuperellipse` instead of `ClipRRect`.
- Container decorations: `ShapeDecoration(shape: RoundedSuperellipseBorder(...))` instead of
  `BoxDecoration(borderRadius: ...)`; borders move to the shape's `side`, and a `Container` with
  `clipBehavior` still clips to the shape path.
- Canvas: `canvas.drawRSuperellipse(RSuperellipse.fromRectAndRadius(...))` instead of `drawRRect`.

Passing `BorderRadius.circular(x)` as the `borderRadius` argument of these APIs is expected — it only
carries the corner magnitude; the rendered geometry stays a superellipse.

APIs that accept only `BorderRadius` keep circular corners, with the superellipse supplied by an
enclosing clip or shape where one is needed: `InkWell.borderRadius`, `OutlineInputBorder`,
`ScrollbarThemeData.radius`, and `smooth_sheets`' `MaterialSheetDecoration`. Fully round pills
(`BorderRadius.circular(999)` or half the shortest side) may stay circular — both geometries coincide
there.

CI gates formatting: `dart format --output=none --set-exit-if-changed lib test
tool plugins setup.dart` runs before `flutter analyze`.

Generated directories are excluded from analysis:

- `build/**`
- `lib/l10n/intl/**`
- `lib/**/generated/**`
- `plugins/**`

## Comments

Comments are part of the code and some of them are load-bearing. What this repository limits is the useless and the
frequent. Every comment that restates the code devalues the ones carrying real information, until readers skim past all
of them — a file with three comments that matter is more readable than one with thirty.

The two halves are enforced differently, because only one of them can be counted. Whether a comment is useless is a
judgment, and it lives in the rules below and in review. Whether comments are too frequent is arithmetic, and
`comment-density` measures it.

### What a Comment Must Earn

- Write one when it carries something the code cannot: a non-obvious constraint, an upstream or platform behavior being
  worked around, a reason the next reader would otherwise get wrong, a coupling to a value defined somewhere else.
- Never restate what the code already says. If the comment and the line below it convey the same thing, the comment is
  noise.
- Never narrate. Not what this diff changed, not what the code used to be, not the order you did things in. Version
  history belongs in git and change rationale belongs in the commit message.
- Never annotate line by line or statement by statement. A block that seems to need a comment per step needs better
  names or a smaller decomposition instead — reach for structure before prose.
- Prefer encoding the intent in structure and naming. A named mixin, type, or method that makes the invariant hard to
  break beats a paragraph asking the next reader not to break it.
- Delete commented-out code, stale version notes, and comments that only restate the code, whenever you edit the file
  that contains them. This does not need approval.
- These are not comments and are exempt from every rule here, including the density count: analyzer and linter
  directives (`// ignore:`, `// ignore_for_file:`, `// coverage:ignore`), license and copyright headers,
  code-generation markers, and comments inside vendored upstream code such as `lib/widgets/open_container.dart`.

### Density

`tool/check_comment_density.sh` fails a file whose added lines are more than 5% standalone comment lines, ignoring
diffs under 20 added lines so small edits are never caught. The number is calibrated on this repository's own history:
healthy changes sit at or under 3.6%, while the core fix that prompted the gate ran 22.4%.

It is a ceiling on frequency, not a target to fill. Do not read `core/meow-rs/`'s inherited upstream density as a quota either —
it is forked upstream code, not a house style.

Three gates run the same script, and they do not have equal force. The `PostToolUse` hooks in `.claude/settings.json`
and `.codex/config.toml` run after the tool and hand offending lines back as feedback; neither can undo the completed
write. The `comment-density` pre-commit hook fails the commit, and it is the only hard gate that covers every tool.
Behavior is pinned by `tool/check_comment_density_test.sh`, which CI runs directly.

When a change genuinely warrants more, raise the ceiling for that run rather than working around it:
`COMMENT_DENSITY_MAX=20 git commit`, or `SKIP=comment-density git commit` to step past it entirely.

### Where Knowledge Belongs

A comment is one of three destinations, and often the weakest. Pick by where the constraint would be violated, not by
how important it feels.

- **Assertable behavior goes in a test.** A test is the only form that cannot drift, because it fails when the behavior
  it describes is broken. Prefer it over both a comment and a document whenever the fact can be checked in code.
- **Repository-wide defaults, ownership, and invariants go in `.agents/*.md` or a `.agents/skills/*/SKILL.md`.** They
  are violated from many files, so they must reach every future agent at session start. A comment in one file cannot do
  that.
- **A fact that is true only at one call site, and is not visible from that call site, is the one thing a comment does
  better than a test or a document.** Its value is being in the reader's line of sight at the moment of the edit.
  Keep a call-site platform workaround next to the operation that depends on it, with its constraint and reason.

Both failure directions are real. Moving a local constraint into `.agents/` hides it from the person editing the line;
leaving a repo-wide policy as a comment reaches only the reader of that one file.

## Core API Safety

FlClash-Meow ships one desktop engine: the pinned `core/meow-rs` fork. These rules apply to its embedded
`crates/flclash-meow-host` and the Flutter desktop integration. Retained mobile sources are outside build/release scope.

- Keep host-specific RPC, configuration translation and product identity in `flclash-meow-host`; separate engine fixes
  suitable for upstream from changes coupled to this client. Do not expand meow capabilities to match mihomo.
- Use `CoreController`/`CoreHandlerInterface` for application behavior. Negotiate `getCoreInfo` identity/protocol and
  capabilities before engine initialization. Keep host protocol 1 distinct from Helper HTTP protocol 6.
- `config.rs` validates imported fields, protocols and provider nodes before preparation. Preserve imported YAML and
  visible diagnostics; a retained Flutter option does not authorize silently ignoring an unsupported engine setting.
- Keep `CoreMethodCall`/`CoreMethodResponse` arguments, results and event batches as structured JSON across Dart and the
  Rust host. `protocol.rs` and `plugins/rust_api/rust/src/ipc/` own the four-byte little-endian framing; do not double-encode.
- Host `ipc.rs` bounds concurrent requests and retained payload bytes and separates response, state and bulk delivery.
  Logs/request floods must not evict state events. Keep cancellation effective under response backpressure, and retain
  ownership of reader, writer, log and RPC tasks until they finish.
- Host `lib.rs` retains staged, active and retired Runtime instances while applying a profile. Configuration preparation
  and startup observe newer intents; resource cleanup remains owned until confirmed. A failed replacement may restore
  the previous Runtime only after candidate cleanup succeeds. Do not substitute the removed Go wrapper's default rollback.
- `runtime.rs` owns listeners, DNS, TUN and background work. Successful `shutdown` means cleanup succeeded; `ipc.rs` flushes
  its correlated acknowledgement before EOF. `resources_release_unconfirmed` stays visible and blocks successors.
- TUN recovery in host `native.rs` uses protected product journals separate from user caches. Restore only resources still
  equal to the recorded installed value, preserve later writers, and do not treat process exit as restoration evidence.
  A `needsPrivilege`/`failed` recovery warning permits ordinary proxy initialization; new TUN requires confirmed recovery.
- Derive file authority from the connected peer: host `main.rs`/`peer.rs` authenticate Windows pipe-server identity and Unix
  UID/GID. `meow-common/src/managed_files.rs` confines product-home I/O to that authority. Do not bypass retained handles,
  impersonate across an await, recursively change ownership, or expose arbitrary filesystem deletion through Core/Helper IPC.
- Preserve the desktop transport's own peer checks: `plugins/rust_api` admits only the app UID or root on Unix, and Dart
  compares the Windows pipe peer PID to its process lease. Host caller authentication does not replace these checks.
- `ProxiesAction` owns bounded delay work, generation cancellation and `pendingDelayTestsProvider` progress. Core/channel
  availability errors cancel the run; transport failure must not become a successful proxy measurement. Read the current
  Rust delay adapter and provider logic before changing budgets; removed Go semaphore constants are not an authority.
- Verify application behavior through the real-host CoreController seam and retain independent IPC, Helper and native
  contracts. Record actual platform evidence in `https://github.com/yukkodesu/FlClash-Patched/issues/8`; skipped native tests are not proof.

### Retained Mobile API Rules

Apply these only when a separate task explicitly changes legacy mobile code. The retained JNI source still describes its
old Go ABI; the removed desktop Go wrapper and mihomo submodule are not desktop extension points or build dependencies.

- `jni_get_string` in `android/core/src/main/cpp/jni_helper.cpp` `malloc`s and hands ownership to Go, which frees through
  `free_string_func`. `quickSetup` relies on that: it reads its `*C.char` arguments inside a goroutine, after the JNI
  wrapper has already returned. Switching the wrapper to `GetStringUTFChars`/`ReleaseStringUTFChars`, or freeing on the
  C side, turns that read into a use-after-free.
- Go goroutines reach Java through `ATTACH_JNI()`, which attaches once with `AttachCurrentThreadAsDaemon` and detaches
  from a `pthread_key` destructor at thread death. Do not restore a detach-per-call: `protect` runs once per outbound
  socket and `onResult` once per event batch, and attach/detach takes ART's thread-list lock each time.
- Every JNI call into Kotlin must be followed by `jni_clear_exception`. A pending exception left in place aborts the
  process on the next JNI call on that thread, so a throw in `protect`/`resolveUid`/`resolvePackage`/`onResult` becomes a
  crash in unrelated code. For the same reason every one of those wrappers checks its `tun_interface`/`invoke_interface`
  for `nullptr` first: ART aborts on a call through a null object, and a callback released by `TunHandler.clear` while a
  connection is still resolving is exactly that.
- The Android bridge resolves an owner in two steps — `resolve_uid` then `resolve_package` — because mihomo fills
  `metadata.Uid` from a procfs lookup that Android Q closed off. Collapsing them back into one call that returns only a
  package name is what left every connection reporting uid 0, so `UID` rules matched nothing.

## Lifecycle Rules

Desktop ownership rules govern this product. Android/JNI/service notes apply only to separately requested work on retained
mobile sources and do not add mobile build or release support.

- Desktop process ownership belongs to `DesktopCoreLifecycle`; do not start/kill `FlClashMeowCore` from providers, widgets,
  managers, or ad hoc exit callbacks. Acquire and release it through a `CoreProcessLease`.
- `CoreController.close()` and platform `close()` implementations are terminal and idempotent. Application shutdown must
  stay centralized in `SystemAction`/`SystemExitCoordinator`.
- Android start/stop MethodChannel calls are optimistic UI commands. Keep latest-wins arbitration in native
  `ServiceState`; do not add a Flutter completion callback that creates a second lifecycle owner.
- Android service callbacks are not automatically user intent. Route explicit Quick Settings, Always-on VPN, and revoke
  actions through `ServiceState` and keep `ServiceController` as the sole binding/run-time owner.
- Every `BroadcastReceiver.goAsync()` path must finish its `PendingResult` exactly once. A watchdog may release the
  broadcast lease, but must not cancel, reverse, or otherwise redefine the service operation.
- Presentation smoothing such as `CoreStatusButton`'s connecting hold must remain local display state. It must not delay or
  overwrite `coreStatusProvider`, and a real failure must bypass/cancel the hold immediately.
- `Tray.hide()` is idempotent on all three desktop platforms and returns native state to "`show` was never called".
  `AppTray.shutdown()` latches, so no later `update()`/`updateTitle()` can resurrect the icon once shutdown begins.
  Keep it that way; a resurrected icon outlives `exit(0)` as a Windows ghost icon, because `setPreventClose(true)`
  means `WM_DESTROY` never runs.
- The `tray` plugin owns call ordering, idempotency, serialization, and unchanged-payload suppression. Application code
  declares desired state through one `Tray.show(TraySpec)` call and must not add platform branches to work around
  ordering. Platform branches in `lib/common/tray.dart` are only for deliberate product differences (macOS speed title);
  proxy group submenus are shared across desktop platforms. Query `Tray.instance.capabilities` for ability differences.
- Every native `show` returns whether the tray now reflects the payload, and reports `false` instead of showing a broken
  icon. `Tray` caches the payload signature only on `true`, so a rejected `show` is retried by the next update rather
  than suppressed until restart. Any test that mocks the `tray` channel must return `true` from `show`.
- Reading the Wi-Fi SSID is opt-in work, not ambient state. `ConnectivityManager` reads it only while `excludeSSIDs` is
  non-empty, because that list is its only consumer through `suspendProvider`, and the read costs a blocking platform
  call plus a location permission on Android and macOS. A second consumer must widen that gate, not drop it.
- On Android the `wifi_ssid` permission is only `granted` once `ACCESS_BACKGROUND_LOCATION` is held too (Q+). Fine
  location alone reads the SSID in the foreground but returns `UNKNOWN_SSID` once the app is backgrounded, which is
  where on-demand spends most of its time. `getSsid` itself only needs fine location, so the split stays inside the
  plugin.
- No `wifi_ssid` implementation may answer `getSsid` on the platform thread. Android resolves through a network callback
  with a timeout, Linux through `g_task_run_in_thread`, and macOS through `ssidQueue` after checking the location
  authorization, because CoreWLAN reaches `wifid` over XPC and a wedged daemon would freeze the window. Windows is the
  outstanding exception: `WlanQueryInterface` still runs inline, since replying off-thread there needs a window-message
  hop that the plugin API does not provide.
- The delayed DNS re-check `NetworkObserveModule.onLosing` posts is deliberately left un-deduplicated. The runnable
  re-reads `networkInfos` and does nothing when `onLost` already dropped the network, `updateDns` returns early when the
  resolved list is unchanged, and `stop()` clears the handler queue, so a network that reports `onLosing` repeatedly
  costs one comparison per event. Holding the pending `Runnable` to `removeCallbacks` it changes no behaviour and adds
  state that has to stay in sync with the map.

## Testing Rules

The `core/` directory is excluded from automated coverage accounting. Do not add coverage instrumentation or coverage
collection for code under `core/`. Desktop CI checks the pinned Rust host with locked Cargo tests, fmt and Clippy on
each native target. Verify application behavior through CoreController in `test/core/`; retain independent IPC,
lifecycle and privileged Helper contract tests. Native TUN/DNS/route tests require a disposable elevated machine and
recorded cleanup evidence. See `.agents/commands.md` and `https://github.com/yukkodesu/FlClash-Patched/issues/8`.

Use `CoreController.test(mock)` to inject a mocked `CoreHandlerInterface`. Call `CoreController.resetInstance()` in `tearDown` to clean up the singleton between tests.

Register fallback values for freezed params used with `any()` matchers.

`tool/check_coverage.dart` enforces a total floor passed by CI plus per-group floors declared in `_groupFloors`. Raise a
group's floor when new tests lift it; do not lower one to make a run pass.

Every measured group needs a floor. A group the report measures but `_groupFloors` does not declare fails the run, so
adding a top-level directory under `lib/` means adding its floor in the same change. Set a new floor at or just below
the coverage the directory actually has; the point is to stop a slide, not to backfill tests before the directory can
land.

Prefer `coreHandlerProvider.overrideWithValue(CoreController.scoped(fake))` over `CoreController.test(fake)` in new and
touched tests. `CoreController.test` claims the process-wide singleton, which makes a global read and a provider read
resolve to the same fake, so it cannot fail on a call site that still reaches for the global.

Construct the Android lib handler with `CoreLib.scoped(fakeService)`. The `service` global is gated on `Platform.isAndroid`
and is therefore null on every test host, so a `CoreLib()` built from it silently takes the null-service fallback on every
path. `CoreLib.scoped` binds an explicit `Service` instead; reset the singleton with `CoreLib.resetInstance()` in `tearDown`.

Three globals in `lib/common` reach real host state and carry a `@visibleForTesting` seam to stand in front of it:
`AutoLaunch.launcher`, `listNetworkInterfaces` and `LinkManager.uriLinkStream`. Replace the launcher in particular — every
`enable`/`disable`/`isEnabled` writes the actual autostart entry (a LaunchAgents plist, a `.desktop` file or a registry
key), so a test that skips the seam registers the test binary on the machine that ran it. `updateStatus` returns early
under `kDebugMode`, which is always true beneath `flutter test`, so its remaining branches cannot be reached from a test
at all; `test/common/launch_test.dart` pins the early return instead.

`pumpAndSettle` never returns on a page holding `EditorPage`: the code editor blinks its caret forever, so frames keep
being scheduled. Pump explicitly instead. `encodeYamlTask` and its neighbours in `common/task.dart` hand work to a real
isolate through `compute`, which only runs outside the fake-async zone, so a test awaiting one needs
`tester.runAsync(...)` between the pumps — see `test/views/profile_preview_test.dart`.

The `@visibleForTesting` `database` setter in `lib/database/database.dart` deliberately does not close the instance it
replaces. Tests inject `NativeDatabase.memory()`, which holds no file handle, and `Database.close()` is async while the
setter is not, so closing there would either be unawaited or force the seam to become async for no gain. A test that
does open a file-backed database owns closing it.

`system.isAndroid` / `isMacOS` / `isWindows` / `isLinux` read `dart:io` `Platform` and cannot be overridden, unlike
`debugDefaultTargetPlatformOverride`. A branch behind one of them is only ever exercised on a host that matches it, so CI
(`ubuntu-latest`) and a macOS working copy measure different coverage for the same test. Assert host-agnostic behavior,
and leave headroom under a group floor that covers such a branch.

A platform decision that drives layout takes `isDesktop`/`isMacOS` as parameters and reads `system` only at the call site,
so every platform's outcome is reachable from one host. `getWindowHeaderHeight` and `showsWindowHeader` in
`lib/common/layout.dart` own the window header rule for both `WindowHeaderContainer` and `overlayTopOffset` — they must
agree, or the content is offset by a header that is not there. `WindowHeaderBar` takes its height and slots as arguments,
which is what lets `test/manager/window_header_test.dart` measure the Windows caption bar on a macOS host.

A `Stack` under loose constraints sizes to its non-positioned children, and falls back to `constraints.biggest` only when
it has none — so a bar that fills the window must keep every slot positioned. One non-positioned child is enough to
collapse `WindowHeaderBar` to that child's width: the macOS title did exactly that, leaving the app name over the traffic
lights and the raw window painted black beside it, while Windows, whose slots are all positioned, stayed correct.
`WindowHeaderLayout` positions the header across the top for the same reason, and the macOS group asserts the bar's
width, not just its height — a height-only assertion cannot see this.

The same seam carries the two other places a platform decision changed what was built: `AppTray` holds `isMacOS`/
`isWindows` as state — `AppTray()` fills them from `system`, `AppTray.forPlatform` is the test seam — and `OnDemandView`
takes nullable `isAndroid`/`isMacOS` that fall back to the host. Every test names the platform it means, because
`debugDefaultTargetPlatformOverride` does not move `system` and a suite that leaves it to the host asserts the macOS
shape on a developer machine and the Linux one on CI. `WindowHeaderContainer` builds the caption buttons on every
non-macOS host, so a test mounting it needs `TestApp` for `AppLocalizations` and a `window_manager` channel mock that
answers `isMaximized`/`isAlwaysOnTop` with a bool.

Auto-dispose providers need a container-level hold before a test reads them back. `proxyGroupProvider`, `ruleProvider`,
`itemsProvider` and friends mix in `AutoDisposeNotifierMixin`, so a `container.read` that no widget is currently watching
rebuilds the provider from its override and silently discards whatever the code under test wrote. Add
`container.listen(theProvider, (_, _) {})` in the harness, as `overwrite_stage_flow_test.dart` does. The staging flow also
re-arms its debounce when it clears the stage, so drain it (`pump` past the duration, then unmount) or the binding fails
the test on a pending timer.

A field that constructs its own `ValueNotifier`, `TextEditingController`, `ScrollController`, `FocusNode`, `TabController`,
`PageController`, `AnimationController` or `StreamController` must be released in the same file.
`test/lint/disposable_field_test.dart` enforces this by scanning `lib/`, because no lint covers it: `close_sinks` only sees
sinks, and nothing in the standard set tracks `ChangeNotifier` disposal. A field that genuinely outlives its owner goes in
that test's `_allowed` set with the reason, not left bare. Controllers received as widget parameters belong to the caller
and are out of scope.

An `IconButton` whose icon is an icon needs a `tooltip`. It is the button's only accessible name — without it TalkBack and
VoiceOver announce nothing and the desktop build shows no hover hint. `test/lint/icon_button_tooltip_test.dart` enforces
it and skips exactly two shapes: an `icon:` holding a `Text`, which is already a visible label, and
`views/dashboard/widgets/core_status_button.dart`, which takes its label from an enclosing `Tooltip` (a second test fails
if that wrapper disappears). Reuse an existing string before adding one; a label that depends on state goes on the button
inside the `ValueListenableBuilder`, not outside it, or the tooltip cannot follow the icon. A row of window buttons hidden
behind `system.isMacOS` is unreachable from a macOS test host, so extract it — `WindowHeaderActions` is the pattern.

A tooltip needs an `Overlay` ancestor at build time, not at hover time: `RawTooltip` builds an `OverlayPortal`, so a
button whose `tooltip` has nowhere to go throws "No Overlay widget found" and takes its whole subtree down with it.
Everything `buildManagerStack` wraps around `MaterialApp.builder`'s child sits *above* the app Navigator and therefore
above the only Overlay in the tree. A manager that renders a tooltip — `WindowHeaderLayout` and its caption buttons are
the case that broke Windows while macOS, which renders a bare title there, stayed clean — hosts its own with
`Overlay.wrap`, spanning the window so the tooltip is not clipped to the widget that owns it. A test only reproduces this
by mirroring that topology: build the widget from `MaterialApp.builder`, never from `home:`.

A public top-level declaration that nothing outside its own file references is dead, and no lint catches it:
`unused_element` covers only private ones, and a barrel `export` keeps a dead file compiling and off every
"unused import" report. `test/lint/dead_file_test.dart` scans `lib/` for files whose declared names — types plus the
`final appPath = AppPath()` singletons next to them — appear nowhere else, counting generated code as a consumer (a
riverpod notifier is reached through its generated provider) and barrels as neither. Files publishing only extensions or
typedefs are skipped: those are reached through the types they attach to, never by name.

A `State.dispose()` override must not await before `super.dispose()`. `StatefulElement.unmount` calls `dispose()` and then
immediately asserts that `super.dispose()` already ran, so an `await` defers the call past the assert and every teardown
throws "`…State.dispose failed to call super.dispose.`" in debug and profile builds. Declare the override as `void
dispose()` and hand async teardown to `unawaited(...)`; `Future<void> dispose() async` compiles and is the shape that
invites the bug.

Use `ProviderContainer` directly for simple Riverpod provider tests. The generated Riverpod `update()` method takes a callback:

```dart
notifier.update((state) => newValue);
```

When testing freezed models with nested objects, always round-trip through `jsonEncode` and `jsonDecode`. Direct `fromJson(toJson())` fails for nested freezed types because `toJson()` stores child objects directly instead of maps.

For async widgets, put visual cleanup in `finally` when the action may throw. Focused widget tests should cover success,
failure, disposal, and any timer boundary that changes visible state.

## Commit Messages

Subjects follow Conventional Commits and are enforced by the `commit-msg` hook in `.pre-commit-config.yaml`, which runs
`tool/check_commit_msg.sh`:

```text
<type>[(scope)][!]: <description>
```

- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Scope is optional and lower case; use a comma to list several, as in `fix(core,android)`.
- `!` before the colon marks a breaking change.
- Descriptions start in lower case, omit the trailing period, and keep the whole subject within 100 characters.
  Identifiers and acronyms keep their own casing, as in `fix(ui): AppBar text is truncated`.
- `Merge`/`Revert` subjects and `fixup!`/`squash!` commits are exempt.
- No `Co-authored-by` trailer crediting a coding agent, whatever that tool's own convention says. The history
  records who owns the change, not which tool typed it; human co-authors are still fine. The hook rejects the
  known agent identities.

Write what the change does, not that something changed: `perf(views): stop redoing per-frame work in build`, not
`Optimize more details`.

Install the hooks once with `pre-commit install --hook-type pre-commit --hook-type pre-push --hook-type commit-msg`.

### Changelog Trailers

`tool/changelog.dart` builds the user facing changelog from the commit history, so the trailers below are the copy that
ships to users. The subject stays the developer facing summary and is only the fallback.

```text
feat(profiles): support per-profile override script

Changelog: Per-profile override scripts
```

- `Changelog:` is the English entry. `Changelog: skip` drops the commit from the changelog entirely.
- The changelog is English only. Translation trailers were removed on purpose: they pushed release copy into the commit
  history, so any `Changelog-<locale>:` or `Breaking-<locale>:` now fails the hook. Translate after the fact if ever
  needed, not in the commit message.
- `Changelog-Type:` moves an entry into another group, for example to promote a `refactor` that users will notice. Valid
  values are `breaking`, `feat`, `fix`, `perf`, `revert`.
- `BREAKING CHANGE:` is required whenever the subject carries `!`, and its text becomes the breaking entry. A `!` commit
  therefore needs two lines of copy: the footer for the breaking entry and `Changelog:` for the normal one.

`feat`, `fix`, `perf`, `revert` and breaking commits are collected by default; every other type is dropped unless it
carries a `Changelog:` trailer. Commits missing a trailer reuse their subject, and the hook says so without blocking.

## Generated Code

Do not manually edit generated files under:

- `lib/l10n/l10n.dart`
- `lib/models/generated/`
- `lib/providers/generated/`
- `lib/database/generated/`
- `lib/l10n/intl/`

After schema, model, or provider changes, run build generation and include focused tests when behavior changes.

`lib/l10n/l10n.dart` is the one file that still imports `package:flutter/material.dart`.
`intl_utils` hardcodes that import in its own template, so regenerating rewrites it and
there is nothing to fix here; `test/lint/design_package_test.dart` exempts the generated
l10n paths for that reason. It is harmless because the file only needs `Locale`,
`BuildContext`, `Localizations` and `LocalizationsDelegate`, which the legacy library and
`material_ui` both re-export from the same `package:flutter/widgets.dart`. Everything a
human writes takes Material from `material_ui`; `cupertino_ui` is banned outright and
survives only as a transitive dependency of `material_ui`.

Strings live in `arb/intl_{en,zh_CN,ja,ru}.arb` — flat JSON, no `@` metadata. Add a key to all four, then regenerate with
`dart run intl_utils:generate`, which rewrites `lib/l10n/`. A key present in only some locales silently falls back to
English at runtime, so add the translation rather than leaving it out.

Some labels are not reached through the generated `AppLocalizations` getters at all. `Intl.message(<runtime string>)`
builds the key from an enum name or a stored string — `action_${HotAction.name}`, `${DynamicSchemeVariant.name}Scheme`,
`NavigationItem.description`. The analyzer sees nothing, and a failed lookup returns the key itself, so a stale key ships
as `routeMode_config` in the UI rather than throwing. `test/lint/dynamic_message_key_test.dart` expands those families
from the real enums and fails when a derived key is missing from any locale; every `Intl.message` site in `lib` must be
registered there, so a new dynamic key cannot be added without also declaring what builds it.
