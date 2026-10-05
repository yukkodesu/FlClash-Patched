# FlClash-Meow implementation graph

Specification: [meow-desktop-client.md](meow-desktop-client.md). Product name: **FlClash-Meow**.

Client integration branch: `feat/meow-desktop`, based on `42ebfa1159da0828e30419323a489c1450e2fc0c`.
Core integration branch: `feat/flclash-meow-host`, based on `3c27aca92d64c7194c6b590e529da46465fbb7eb`.
Client repository: `yukkodesu/FlClash-Patched`. Core repository: `yukkodesu/meow-rs`.

GitHub tracker: https://github.com/yukkodesu/FlClash-Patched/issues/1. The user authenticated gh; Issues was enabled for the client fork and the spec received `ready-for-agent`. Tickets H1/H2/B1/C1/U1/T1/V1 are respectively #2/#3/#4/#5/#6/#7/#8. No ticket is resolved until its acceptance evidence is recorded.

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

- Client commit `7411736b`: desktop-only CoreController selection, validated host identity/protocol, structured compatibility diagnostics and runtime state, ordered configuration-before-listener setup. Raw profile queries preserve an existing `rules` field. Method logging omits arguments to avoid logging profile credentials.
- Flutter 3.47.6 / Dart 3.13.5: 32 controller and metadata tests passed; 118 existing desktop IPC/lifecycle/Helper/service/protocol tests passed. Native build hooks were disabled only during these Dart checks and restored afterward. These checks do not prove that the Rust host is connected yet.
- Existing shared Flutter 3.47.1 cannot resolve this baseline's Dart ^3.13.2 dependencies. A separate SDK checkout at tag 3.47.6 supplies the CI-pinned toolchain without changing the shared checkout.
- Rust host and build/UI implementation are in independent worktrees. Windows libclang tooling was supplied from a PyPI wheel with its published SHA256 verified. Native proxy, TUN and package acceptance remains pending.
- Missing native TUN and package evidence keeps V1 open. Ordinary proxy acceptance for each verified native target is recorded separately in the acceptance matrix.
- Host checkpoint `d5c9563ffcf90c62b35bde22b055eed80b48e691` is pushed to the user's `feat/flclash-meow-host` branch. Initial public Rust tests passed for framing, idle initialization, nested compatibility errors, real HTTP relay/readiness/stop and failed listener replacement rollback. Native cleanup/error ownership remains in progress.
- Windows real CoreController e2e passed through the production rust_api named-pipe transport and an actual host executable: identity, idle initialization, strict diagnostics, raw profile query, supported proxy-group DTO conversion, HTTP relay, cumulative traffic, delay and listener shutdown. It uses only local sockets and a temporary product data directory, with no TUN/system-proxy changes.
- Product/build checkpoint merged at `cb5deed3`: isolated identities, six desktop target declarations, Rust host/cache/final SHA/Helper pipeline and packaging. Source pin, actual bundled build and cross-platform acceptance remain outstanding; declaration is not runtime validation.
- A held TCP CONNECT fixture initially failed on numeric meow ports at the real Dart DTO boundary. The host now converts them to strings; the same CoreController e2e passes connection snapshot decoding, actual socket closure through closeConnection and subsequent removal from the snapshot.
- `915f235d` removes the desktop Go wrapper and pins the fork's Rust host submodule. The old initialized checkout was preserved outside the client at `D:/Code/.worktrees/meow-tooling/legacy-mihomo-checkout`; the separate sibling mihomo fork was untouched.
- `b405f526` exposes native recovery status at CoreController, TUN settings and About, with a localized initialization warning. A recovery warning leaves ordinary proxy available and does not claim TUN is active.
- Endpoint metadata now includes actual listener, DNS and controller bindings; production CoreController E2E verifies a real DNS response at the reported address.
- `a357f8ad` advances the source pin to ordinary-host checkpoint `75b3d420`; final native cleanup/storage integration remains pending. macOS uses Xcode libclang without overriding process-wide C++ library lookup.
- Detailed current checks and CI links live in [meow-desktop-acceptance.md](meow-desktop-acceptance.md). All task tickets remain open until the corresponding acceptance is complete.
