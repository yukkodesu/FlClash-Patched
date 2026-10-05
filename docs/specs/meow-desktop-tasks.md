# FlClash-Meow implementation graph

Specification: [meow-desktop-client.md](meow-desktop-client.md). Product name: **FlClash-Meow**.

Client integration branch: `feat/meow-desktop`, based on `42ebfa1159da0828e30419323a489c1450e2fc0c`.
Core integration branch: `feat/flclash-meow-host`, based on `3c27aca92d64c7194c6b590e529da46465fbb7eb`.
Client repository: `yukkodesu/FlClash-Patched`. Core repository: `yukkodesu/meow-rs`.

GitHub tracker publication is pending write access (connector returns 403; local gh is unauthenticated). The identifiers below are local task identifiers, not GitHub issue numbers. No ticket is resolved until its acceptance evidence is recorded.

| Task | Dependencies | Acceptance | State |
|---|---|---|---|
| H1: Embedded Rust host | none | Single process, bounded framed IPC, typed errors and identity, empty idle initialization, resource ownership and shutdown; independently buildable CLI unchanged | pending |
| H2: Runtime and configuration | H1 | Strict compatibility diagnostics including nested fields and paths; real listener readiness; rollback; groups, delay, providers, connections, traffic, logs, DNS and TUN using existing meow capabilities | pending |
| B1: Product and builds | none | Independent desktop identifiers, fixed fork source, Rust host build/cache/hash/Helper ordering, six desktop architecture targets, installer/update isolation, no desktop Go dependency | pending |
| C1: Client control and configuration | H1 | CoreController handshake and real-host contract; only desktop backend; validated derived config and raw preservation; latest-intent controlled restarts and recovery, supported operations | pending |
| U1: Capability-aware desktop UI | C1 | Unsupported entry points removed, real statistics/TUN scope and configuration diagnostics exposed, usable supported proxy and provider workflows | pending |
| T1: Privilege and platform integration | H2, B1, C1 | Fixed host/hash/session/peer ownership preserved; ordinary proxy fallback; TUN cleanup and product separation | pending |
| V1: Delivery and review | H2, B1, C1, U1, T1 | Meaningful CoreController e2e, existing regression checks, Rust fmt/clippy/tests, six-target build/smoke and actual platform/TUN acceptance evidence; independent reviews addressed | pending |

## Testing seams

User-approved primary seam: existing CoreController, including calls, configuration application, start/stop, proxy operations and events. Necessary independent contracts: framing/IPC, lifecycle leases and privileged Helper. Rust host tests exercise its public request boundary or executable, not private handler structure. Native system changes require corresponding platform records; no ordinary unit test changes host network settings.

## Shared product contract

- Display name: `FlClash-Meow`; executable base: `FlClashMeow`; core: `FlClashMeowCore`; Helper: `FlClashMeowHelperService`.
- Bundle/application identifier: `com.yukko.flclashmeow`; URI scheme and Linux package: `flclash-meow`.
- Desktop IPC prefixes: `FlClashMeowCore_` on Windows and `FlClashMeowSocket_` on Unix.
- Helper uses an independent Windows loopback port and Linux `/run/flclash-meow/helper.sock`; preserve protocol version 6 unless its wire contract changes.
- Rust host crate/binary: `flclash-meow-host` / `flclash-meow-host`, embedded in the meow workspace; installed artifact renamed to the product core name.
- Host protocol version: 1, retaining the existing `{id,method,arguments}` / `{id,result,error}` envelope and four-byte little-endian framing, maximum 64 MiB.
- Add identity/capability handshake through `getCoreInfo`. Main existing methods remain only where supported; structured arguments/results remain single-encoded JSON.
- Fork host branch is pushed only to the user's meow-rs fork. Client pins the resulting commit as its build input, never the sibling development checkout.

## Evidence

No implementation or platform acceptance is claimed yet. Update this section and task state with concrete commits, commands and results as work lands. Missing native platform evidence keeps V1 open.
