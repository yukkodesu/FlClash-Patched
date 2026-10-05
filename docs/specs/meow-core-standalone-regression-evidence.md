# Standalone core regression evidence

Recorded 2026-10-06 from local Windows x64 and native Ubuntu x64 CI with Rust 1.98.1.
This supplements the [desktop acceptance record](meow-desktop-acceptance.md).
There is **no complete single-invocation Windows curated-suite pass**.
The pinned-source Linux standalone job passed, with the coverage limits below.

## Completed Linux CI

[Fifth-run standalone job](https://github.com/yukkodesu/FlClash-Patched/actions/runs/37363869604/job/111944437569)
completed successfully at `2026-10-05T19:54:18Z`. Its log verifies exact client
`72a997b1e63363f4886910e59d7bbf18cee5355b` and core
`3cf7d8da370958c03c87ef4384e9f9b2213014b4`.

The [sixth-run standalone job](https://github.com/yukkodesu/FlClash-Patched/actions/runs/37367220934/job/111955184966)
also passed at client `d64691e3b2a773d6b01f87ca3d1340e67230aed6` and core
`aceb484266401e72360347a9b1817f8e62f60543`. Its single curated command again
reported 2,792 passed / 0 failed / 4 ignored across 36 binaries, plus 3 UDP/53
and 114 isolated API tests. The same five missing-Country.mmdb early returns
remain a coverage limit.

Formatting, all three workspace Clippy variants, minimal standalone CLI Clippy,
and workspace rustdoc passed. UDP/53 passed 3 tests. One complete curated command
reported **2,792 passed, 0 failed, 4 ignored**, reaching all 21 CONTRIBUTING
integration targets. The separate no-TUN API command passed 114 tests. RAII's
3 tests and the proxy library's 693 tests passed on this platform.

The log confirms `shadowsocks 1.24.0`, APT plugin package `1.3.1-4`, and the
plugin's own `v2ray-plugin custom` / Go1.17.3 version text. Both
`test_ss_v2ray_plugin_websocket_mux` and `test_ss_v2ray_plugin_tls_websocket_mux`
passed with real local peers; no missing-ssserver skip occurred.

Four upstream tests were explicitly ignored: the DNS TCP burst-budget test and
three sing-box live-node probes. Five country-index tests returned early with
`Country.mmdb fixture not available`: building an allowlist, an empty allowlist,
sharing repeated range Arcs, duplicate GEOIP parser reuse, and case-insensitive
allowlists. Cargo includes these early returns in its pass count; their real MMDB
coverage remains unverified. The full log is retained locally as
`D:/Code/.worktrees/meow-tooling/ci-fifth-standalone-linux.log`.

This proves the documented standalone Linux regression gate at the pinned source,
not complete desktop acceptance. The fifth run's Plugins and macOS ARM jobs were
cancelled after about 15 minutes without acquiring a hosted runner, as their
check-run annotations confirm; they are not source test failures or passing cells.

## Local Windows source and checks

| Source | Check | Result |
| --- | --- | --- |
| `a91c0f25693cc2364aa1d66c230f94e114cff934` | Workspace all-target Clippy, default / no-default / all-features, `-D warnings` | All three passed |
| same | Workspace rustdoc, `RUSTDOCFLAGS=-D warnings`, `--no-deps` | Passed |
| same | Package `meow-app` no-default all-target Clippy | Passed |
| same | Listener all-features `udp_port_53` filter | 3 passed |
| same | Original CONTRIBUTING curated command | Stopped at config: 409 passed, 4 failed |
| `4c234d6954b951fe90def6bb22e853fc0049af55` | Config library, package feature graph | 408 passed; all four failures fixed |
| same | Config all-target strict Clippy, workspace fmt, diff-check | Passed |
| same | Original curated command rerun | Config 413 passed; later proxy logging fixture failed |
| same | Independent no-TUN API integration leg | 114 passed |
| `3cf7d8da370958c03c87ef4384e9f9b2213014b4` | Remaining workspace libraries, excluding already-executed proxy library | 1,479 passed, 1 ignored, no failures |

The merge `3cf7d8d` has the same tree as repair `4c234d6`. The repair restores
MMDB path and triggering-rule context for filesystem errors; managed storage
authorization and the CLI's mmap behavior remain intact.

## Remaining Windows limits

`mux::smux::tests::dropped_fin_distinguishes_a_dead_session_from_a_wedge`
captured an empty diagnostic in the full parallel proxy run: 691 passed,
1 failed, 3 ignored. The same binary then passed 692 tests with 3 ignored;
the individual diagnostic and all 27 smux tests also passed. Its source has
zero diff against upstream baseline `3c27aca92d64c7194c6b590e529da46465fbb7eb`.
This is intermittent shared-process log capture, not evidence of a mux change.

The unchanged baseline `raii_guard_test::close_connection_cancels_blocked_prefix_write`
assumes a 16 MiB loopback prefix remains blocked. Windows completed all
16,777,216 bytes before its pending-write assertion. That binary reported
2 passed / 1 failed. Production cancellation failure has not been demonstrated.
Neither fixture was weakened or production code changed to make these tests pass.

The other curated targets were executed separately after the interrupted run:

| Target | Passed |
| --- | ---: |
| CLI binary / API / common / config / DNS cache | 26 / 109 / 23 / 115 / 18 |
| Config persistence / publishing metadata / crate invariants | 22 / 2 / 14 |
| HTTP close / SOCKS UDP / pre-resolve / statistics / rules | 2 / 2 / 2 / 13 / 71 |
| Boring TLS / TLS / WS / Trojan / VLESS config / VLESS | 29 / 18 / 7 / 6 / 53 / 11 |
| systemd configuration | 0 (platform-gated on Windows) |
| v2ray plugin | 2 returned early: explicit `SKIP: ssserver not found in PATH` |

Three proxy live-node probes and one DNS burst-budget test remain explicitly
ignored by upstream. The plugin rows do not prove real-peer protocol coverage.

## Reproducibility and CI

Client workflow commits `77d5517f`, `b8af167f`, and `1b7a4987` add the standalone
package gate, local peers, and package-scoped CLI/API feature checks. Actionlint
and YAML comparison against all 21 CONTRIBUTING integration target names passed.

CI pins `shadowsocks-rust` ssserver 1.24.0 (`--locked`, stream-cipher and
aead-cipher-2022) and Ubuntu `shadowsocks-v2ray-plugin=1.3.1-4`, exposing its
`/usr/bin/ss-v2ray-plugin` as `v2ray-plugin`. The official Jammy amd64 package was
independently SHA256-verified as
`38e3124eb78b857fdb920c9c88848a625f974a03fa18f22268702047f6cc3658`.
The binary reports `v2ray-plugin custom`; the version pin refers to the package.
No Go build toolchain is required.

Local logs are retained under `D:/Code/.worktrees/meow-tooling/` with prefixes
`core-full-*`, `core-mmdb-context-*`, `core-curated-*`, `core-proxy-unified-repeat`,
and `core-api-no-tun-windows`. No workstation service, registry, or network
configuration was changed, and no public proxy nodes were used.
