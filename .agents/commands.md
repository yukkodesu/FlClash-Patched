# Commands

## Building

Initialize the pinned `yukkodesu/meow-rs` submodule:

```bash
git submodule update --init --recursive
```

`setup.dart` packages FlClash-Meow for desktop only, with `amd64|arm64` architecture values. Windows/Linux require a
matching native host; macOS can build a requested Xcode slice, while CI runs both natively.

```bash
dart setup.dart windows --arch amd64
dart setup.dart linux --arch arm64
dart setup.dart macos --arch amd64
dart setup.dart macos --arch arm64
```

Flutter runs `plugins/setup/hook/build.dart` during native builds and tests. The pure Dart harness builds the embedded
Rust host first, then embeds its final SHA256 in the Windows/Linux Helper and writes `manifest.json`. Artifacts land in
`libclash/<platform>/`. To build these artifacts directly:

```bash
cd plugins/setup/setup_hooks
dart pub get
dart run bin/build_desktop.dart windows amd64
```

The cache lives in `.dart_tool/setup_build_cache/` at the repository root. Deleting it forces the harness to invoke
Cargo again; Cargo keeps its own dependency cache. Hooks mirror output into `.dart_tool/setup_build_cache/hook.log`.

Both hooks need their Rust toolchains even on a cache hit. For a Dart-only test loop, temporarily disable them:

```yaml
hooks:
  user_defines:
    setup:
      build_assets: false
    rust_api:
      build_assets: false
```

Restore both to `true` before committing or packaging. `setup.dart` refuses to package with either disabled.
Tests using the editor/IPC library need `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` pointing at the directory
containing `rust_api.dll`, `librust_api.so`, or `librust_api.dylib`. Native CI builds that library and the real host
explicitly and runs CoreController E2E with both paths set. Ordinary unit shards may skip that test when
`FLCLASH_MEOW_HOST` is absent.

## Flutter Development

Use the default Flutter SDK directly:

```bash
flutter pub get
flutter run
flutter test
```

Use `flutter test`, not `dart test`, because models pull in Flutter types.

## Code Generation

Run code generation after modifying models, providers, or database schema:

```bash
dart run build_runner build --delete-conflicting-outputs
dart run build_runner watch
```

Code generation covers:

- Riverpod providers through `riverpod_generator`.
- Models through `freezed` and `json_serializable`.
- Database tables through `drift_dev`.

Generated output paths, configured in `build.yaml`:

- `lib/models/generated/*.g.dart`, `*.freezed.dart`.
- `lib/providers/generated/*.g.dart`.
- `lib/database/generated/*.g.dart`.

Tray and Windows app icons are generated, not hand-edited. `assets_source/images/icon/*.svg` is
the source of truth; the script needs `rsvg-convert` (librsvg) on `PATH`:

```bash
dart run tool/generate_status_icons.dart
```

It writes the tray PNGs with Flutter `2.0x/`–`4.0x/` resolution variants to `assets/images/tray/unix/`,
multi-size tray `.ico` files to `assets/images/tray/windows/`, and `windows/runner/resources/app_icon.ico`
from `assets/images/icon.svg`. `pubspec.yaml` declares the two tray directories with `platforms:` so each
build only bundles the format its tray loads; a new status icon needs a source SVG and an entry in the
script's `statusIconNames`, nothing in `pubspec.yaml`.

## Testing

Tests use `package:test/test.dart` for pure Dart logic and `flutter_test` for provider and widget tests. `mocktail` is the mocking framework.

```bash
flutter test test/models/
flutter test test/core/
flutter test test/core/desktop/
flutter test test/providers/
flutter test test/common/
flutter test test/database/
flutter test test/widgets/
flutter test test/setup_test.dart
flutter test plugins/proxy/test/proxy_test.dart
```

`plugins/setup/setup_hooks/` is a pure Dart package and is tested with `dart test` from its own directory, which is
also what CI runs; `tool/check_plugins.sh` does not descend into it. It must stay out of `flutter test`, because a test
run of `plugins/setup` would execute the build hook itself.

Root `flutter test` only discovers the root package's `test/` directory by default. Include bundled plugin Dart tests by passing paths explicitly, or run `flutter test` from that plugin package directory, or run `bash tool/check_plugins.sh` to analyze and test every plugin package the way CI does. Native plugin tests under platform folders are not run by `flutter test`.

For the current Core/service architecture, useful focused checks are:

```bash
flutter test test/core/desktop/
flutter test test/core/service_test.dart
flutter test test/core/protocol_contract_test.dart
flutter test test/manager/core_manager_test.dart
flutter test test/providers/action_test.dart test/providers/system_action_test.dart
flutter test test/widgets/core_status_button_test.dart
```

What those suites own:

- `test/core/desktop/`: replaceable IPC transport, RPC request correlation/failure, direct/Helper process leases, and
  latest-intent desktop lifecycle convergence.
- `test/core/service_test.dart`: `CoreService` composition and terminal close behavior.
- `test/core/protocol_contract_test.dart`: Dart method and event-envelope compatibility, including event batches.
- `test/providers/action_test.dart`: Core start/restart orchestration and overlapping restart requests.
- `test/providers/system_action_test.dart`: ordered, idempotent exit cleanup and watchdog behavior.
- `test/widgets/core_status_button_test.dart`: 600-millisecond connecting presentation hold, immediate failure display,
  long-running connecting state, and disconnected restart.

## Native Component Verification

Run host checks from the submodule so its pinned Rust toolchain applies:

```bash
cd core/meow-rs
cargo fmt --all -- --check
cargo clippy --locked -p flclash-meow-host --all-targets -- -D warnings
cargo test --locked -p flclash-meow-host
cargo build --locked --release -p flclash-meow-host
```

The privileged Helper has separate protocol, process ownership, and integrity tests:

```bash
cargo fmt --manifest-path services/helper/Cargo.toml -- --check
cargo test --locked --manifest-path services/helper/Cargo.toml
cargo test --locked --manifest-path services/helper/Cargo.toml --features windows-service
```

The last command needs Windows to cover its service implementation. Helper/TUN installation and routing need a
disposable elevated native machine; ordinary local tests must not change the developer's DNS or routes.

Build `rust_api` from `plugins/rust_api/rust` with its own toolchain, then run CoreController E2E from the root.
For Windows PowerShell, with native hooks temporarily disabled:

```powershell
$env:FLCLASH_MEOW_HOST = "$PWD/libclash/windows/FlClashMeowCore.exe"
$env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = "$PWD/plugins/rust_api/rust/target/release"
flutter test test/core/meow_host_integration_test.dart --reporter expanded
```

For Unix shells (adjust the host artifact for macOS):

```bash
FLCLASH_MEOW_HOST="$PWD/libclash/linux/FlClashMeowCore" \
FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$PWD/plugins/rust_api/rust/target/release" \
flutter test test/core/meow_host_integration_test.dart --reporter expanded
```

This is the main application boundary for identity/capabilities, config rejection and application, listener start/stop,
proxy selection, proxied traffic, connection events, delay tests, and terminal shutdown. IPC/Helper contracts remain
independent. Native CI explicitly sets paths and checks the host exists before invoking the test.

## Changelog And Release

The changelog is derived from Conventional Commits by `tool/changelog.dart` and written to two committed files:
`CHANGELOG.md` for readers and `changelog.json` for the renderers. See `.agents/rules.md` for the `Changelog:` trailers
that decide the wording.

The app ships no changelog of its own. `render release` appends the released version as JSON inside an HTML comment
(`<!-- flclash:changelog:json … -->`), so the release body GitHub already returns to `checkForUpdate` carries the
notes shown in the update dialog. `parseReleaseChangelog` reads that block and falls back to the English
bullets when a release predates it.

```bash
dart run tool/changelog.dart verify                  # what CI checks
dart run tool/changelog.dart release --version 0.8.96
dart run tool/changelog.dart build --unreleased      # changelog.json only, includes untagged work
dart run tool/changelog.dart render release --out release.md
dart run tool/changelog.dart render telegram --out telegram.md
```

Releasing a stable version, in order:

```bash
tool/bump_version.sh all
dart run tool/changelog.dart release --version 0.8.96
git commit -am "chore(release): v0.8.96"
git tag v0.8.96
git push origin main && git push origin v0.8.96
```

Push the tag by name. Every release tag here is lightweight, and `--follow-tags` carries annotated tags only: it skips a
lightweight one silently, so the branch lands, the tag does not, and the release workflow never fires.

`tool/release.sh` drives both paths so the ordering below cannot be got wrong by hand. It resolves the version (bumping
the patch when pubspec still names an already tagged one), prints the notes the tag would ship, and only pushes with
`--push`:

```bash
tool/release.sh pre --dry-run     # plan and notes, changes nothing
tool/release.sh pre --push        # bump, tag vX.Y.Z-pre.N, push
tool/release.sh stable --push     # changelog, chore(release) commit, tag, push
```

The release commit comes before the tag on purpose: the generated wording is reviewable in the diff before it ships, and
the tag is what `render release` reads. CI never writes back to the repository; it only runs `verify`. Wording in
`changelog.json` may be edited by hand as long as no derivable entry disappears and every entry still points at a commit
inside that version's range.

Entries at or below `v0.8.96` are frozen: they predate the pipeline, live under the `<!-- changelog:frozen -->` marker
in `CHANGELOG.md`, and are never regenerated.

`verify` compares a version only when its tag is reachable from `HEAD`, because that is the same scope the builder walks
(`git tag --merged`). A branch cut before the newest release cannot derive that version at all, so `verify` names it as
skipped and moves on instead of reporting drift that does not exist. Checking mere tag existence is what made every such
branch fail on an unrelated release.

Prerelease tags (`v0.8.96-pre.N`) skip the release commit, and CI renders their notes with `build --unreleased` for the
Telegram post. They publish no GitHub release, so the update dialog never sees them. `build --unreleased` reads the
version from `pubspec.yaml` rather than the tag, so the patch has to be bumped before the first `-pre.N` of a cycle:
while `v<pubspec version>` is still tagged it refuses to collect anything and the release job fails.

## Verify

Every branch push runs formatting/analysis, eight root Flutter test shards, plugin gates, Helper/Rust API checks,
and six native host jobs. Reproduce root checks with:

```bash
bash tool/check_commit_msg_test.sh
bash tool/check_comment_density_test.sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool plugins setup.dart
flutter analyze --no-fatal-infos
flutter test --reporter expanded
```

The pure Dart setup harness uses `dart analyze` and `dart test` from its package directory. Its build-boundary tests
compile real Cargo fixtures and verify caching, Core/Helper hash coupling, and failure preservation.
`bash tool/check_plugins.sh` discovers local Flutter packages and runs their analysis/tests.

The `meow-host` matrix executes CoreController E2E with native host and Rust API artifacts on Windows/Linux/macOS x64
and ARM64. Manual `workflow_dispatch` runs all gates plus six desktop package builds and staged Core smoke checks, and
uploads artifacts without creating a release. A `v*` tag push additionally publishes the release. A green build does not
prove elevated TUN installation or package uninstall: record native acceptance in `docs/specs/meow-desktop-acceptance.md`.

## Worktree Tooling

```bash
bash tool/worktrees.sh list       # every worktree with owner tool and dirty/clean state
bash tool/worktrees.sh prune      # remove clean worktrees; add --force to drop dirty ones too
```
