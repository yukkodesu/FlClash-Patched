---
name: core-platform
description: Use when changing FlClash-Meow Rust host integration, desktop lifecycle/process ownership, IPC/events, platform managers, TUN, or Helper flow; retained mobile sources are out of scope unless explicitly requested.
---

# Core And Platform

## When To Use

Use this for changes touching `lib/core/`, `lib/manager/`, `core/meow-rs/`, `services/helper/`, native build hooks,
system proxy, tray, desktop TUN, or privileged launch. FlClash-Meow is a desktop-only, single-meow product;
do not add a second core or expand engine capabilities to match mihomo.

## Workflow

1. Identify the authoritative owner before changing behavior:
   - Shared facade/protocol: `lib/core/controller.dart`, `lib/core/interface.dart`, and `lib/core/method.dart`.
   - Desktop composition: `lib/core/service.dart`; lifecycle/process ownership: `lib/core/desktop/lifecycle.dart`.
   - Desktop IPC/RPC: `lib/core/desktop/transport.dart` and `lib/core/desktop/rpc_client.dart`.
   - Desktop launch ownership: `lib/core/desktop/launcher.dart`; Windows Helper HTTP contract:
     `lib/core/desktop/helper_client.dart` and `services/helper/`.
   - Flutter orchestration: `lib/providers/actions/core.dart` and `system.dart`; UI/event observation: `lib/manager/`.
   - Embedded engine/configuration: `core/meow-rs/crates/flclash-meow-host/src/lib.rs`, `config.rs`, and `runtime.rs`.
   - Host framing/events/shutdown: that crate's `protocol.rs`, `ipc.rs`, and `main.rs`; caller file authority: `peer.rs`
     and `core/meow-rs/crates/meow-common/src/managed_files.rs`; privileged product recovery: host `native.rs`.
2. Trace UI/provider intents, application exit, process/IPC failure and native residue recovery into their owner.
   Lifecycle callbacks are not implicit user intent. Keep retained mobile paths outside the desktop change.
3. Preserve latest-intent semantics:
   - Desktop revisions converge to running/restarted/stopped/closed and report applied/coalesced/superseded outcomes.
   - Host configuration/startup generations retain staged and retired resources until cleanup is confirmed.
4. Route feature calls through `CoreController` and `CoreHandlerInterface`. Do not bypass desktop process leases.
   Negotiate identity/capabilities before engine initialization; control readiness does not imply listener/TUN readiness.
5. Keep Dart/Rust request IDs, structured JSON envelopes, four-byte little-endian framing and event batches compatible.
   Preserve bounded request work and separate state/bulk streams in host `ipc.rs`; logs must not evict state events.
6. Keep shutdown single-owned and terminal. `SystemExitCoordinator` sequences resource cleanup, window close, Core close,
   and process exit; widget/manager disposal must not race it.
7. Add or update focused tests at the narrowest layer, then run the matching commands from `.agents/commands.md`:
   - Desktop lifecycle/transport/RPC: `test/core/desktop/` plus `test/core/service_test.dart`.
   - Envelopes/events: `test/core/protocol_contract_test.dart` and host `tests/protocol.rs`.
   - Host public boundary: from `core/meow-rs`, run `cargo test --locked -p flclash-meow-host --tests`,
     `cargo fmt --all --check`, and `cargo clippy --locked -p flclash-meow-host --all-targets -- -D warnings`.
   - Real application behavior: `test/core/meow_host_integration_test.dart`, with the actual host and Rust runtime library
     paths set as documented in `.agents/commands.md`. A skipped E2E is not native acceptance.
   - Provider/exit convergence: `test/providers/action_test.dart` and `test/providers/system_action_test.dart`.
   - Windows Helper: Cargo format/tests; run the `windows-service` feature on Windows.
8. Record native evidence in `docs/specs/meow-desktop-acceptance.md`. Named-pipe caller identity, Unix UID/file ownership,
   SCM/cgroup/Job Object, TUN traffic, DNS/routes restoration and install isolation require their real platform.
   Privileged tests run only in explicitly disposable environments; portable checks do not complete those cells.

## Reference Files

Read `.agents/architecture.md` for the current core modes, manager stack, build hooks, local plugins, and Windows helper notes.

## Pitfalls

- Keep the Windows Helper protocol and Core SHA256 validation identical across
  Flutter build modes; the Helper owns executable integrity checks.
- Host `getCoreInfo` declares protocol version 1; this is independent of the Helper HTTP protocol.
- Helper protocol version 6 uses a 32-character lowercase-hex session ID. `/start` must return the submitted session and PID;
  `/stop` must never terminate a different session; Dart must verify the connected named-pipe peer PID.
- `/start` must release the previously managed Core before it verifies, so no `/start` outcome leaves a Helper-managed
  Core behind for the caller's direct-launch fallback to race.
- The Helper owns a managed Core until its exit is confirmed. A `200` from `/stop` means the Core is gone; when
  termination cannot be confirmed the Helper keeps the child and answers `coreStopFailed`, and `/start` reports the same
  code instead of spawning a replacement. Keep that code out of the Dart pre-spawn fallback set in
  `helper_client.dart`, or the direct launch will race a Core the Helper still owns.
- Ordinary proxy can use an allowed direct-launch fallback only after confirming there is no Helper-owned child.
  A requested TUN start must not silently report success after privilege is lost; expose actual capability and failure.
- Successful `shutdown` acknowledges confirmed runtime cleanup before IPC EOF. Process exit alone cannot prove native
  restoration; retain sticky cleanup failure and block replacement when resource release is unconfirmed.
- Managed profile/provider/resource I/O uses the authenticated peer's product-home authority. Do not bypass checked
  handles, impersonate across an await, recursively rewrite ownership, or mix user caches with privileged TUN journals.
- A desktop process lease with unconfirmed exit must remain owned until cleanup succeeds. Do not discard it and start a
  replacement Core.
- `CoreController.close()` is terminal. Do not call it from a reusable manager lifecycle or recover by starting it again.
- Keep log/request floods from evicting state-bearing Core events. Each queue may evict only its own oldest item.
- Do not expose direct filesystem deletion APIs through Core or helper IPC; use
  a scope-specific cleanup API instead.
- `plugins/setup/` is a build harness, not a Dart API plugin.
- Flutter hooks build the pinned Rust host, the independent `rust_api` library and Helper artifacts. Keep source identity,
  manifest and embedded host hash consistent; there is no desktop Go wrapper build.

## Retained Mobile Sources (Outside Product Scope)

Only apply this guidance when a separate task explicitly touches legacy mobile code. Android Core binding remains owned
by `lib/core/lib.dart`, `lib/plugins/service.dart` and `ServicePlugin`; `ServiceState` arbitrates latest `RunRequest`
intent while `ServiceController` owns binding/time bookkeeping. Do not create a second binding owner.
Flutter commands remain optimistic; service creation/destruction are not user intent. Always-on startup uses
`VPN_START_REQUESTED`, and revoke uses `VPN_REVOKED`. `ServiceBroadcastReceiver.goAsync()` finishes once even on timeout;
its watchdog releases the broadcast rather than imposing a service timeout. Kotlin verification requires the matching
Gradle module and JDK 17. These sources and checks do not add mobile build/release support to FlClash-Meow.
