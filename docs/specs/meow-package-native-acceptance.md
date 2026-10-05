# Desktop package acceptance

This B1/V1 fixture exercises the production Inno installer, Debian package, or signed DMG on a disposable native GitHub-hosted runner. It refuses local execution before creating evidence. Run it separately for Windows amd64/arm64, Linux amd64/arm64 and macOS amd64/arm64; a passing architecture cannot stand in for another one.

The harness is `tool/desktop_package_acceptance.py`. It accepts a directory containing one native installer, including downloaded `artifact-<platform>-<arch>` artifacts. It reads the installed package, not a staging directory. Supply the actual build's client SHA and core submodule SHA; the source record includes both, the installer digest, the build run ID, and the independent harness commit. For an artifact-only job, first verify the build run's `head_sha` through GitHub's Actions API and use that SHA as `--source-client`.

```sh
python tool/desktop_package_acceptance.py --dist dist --arch amd64 \
  --source-client "$BUILD_CLIENT_SHA" --source-core "$BUILD_CORE_SHA" \
  --build-run-id "$BUILD_RUN_ID" --log build/package-acceptance/acceptance.jsonl
```

Windows requires an already elevated disposable runner. Linux requires a D-Bus session and X11 window manager, with `xdotool`, `scrot`, and system Python's `python3-gi`/Gio available. macOS requires its native GUI session, permission for System Events accessibility, and screen capture. Missing desktop access fails the test; it does not create a synthetic passing UI record. Flutter matching the build is required for the existing CoreController integration fixture.

The JSONL, per-start stdout logs, installed CoreController log and native screenshots record:

- Actual install, native executable architecture, exact host `--version` source commit, no Go/mihomo/second core artifacts, and package-owned `rust_api` library.
- Windows/Linux installed Core digest matching the installed manifest and the actual packaged Helper's protocol 6 hash verification. The running Helper must report its fixed installed path, and an incorrect Core digest must be rejected. macOS retains its no-Helper/no-Helper-manifest contract; its signature is verified and the copied signed Core must match the DMG's signed Core.
- The existing real CoreController acceptance against the installed Core and packaged editor library, including configuration, HTTP/SOCKS listeners, authentication and shutdown. The test is selected from the harness checkout; the source record explicitly identifies the separately built payload.
- Three real application cold starts, with autostart enabled, disabled, then enabled. TUN, system proxy, automatic DNS and update downloads are disabled through normal persisted preferences. The application must show a native window and own exactly one installed Rust Core.
- The installed product URL scheme restoring a hidden application without spawning a second Core, global view/exit shortcuts, and terminal process cleanup after normal exit.
- Native tray activation restoring a hidden window. Windows clicks the publicly exposed notification-area icon through UI Automation and real pointer input; macOS presses the product-owned accessible status item; Linux selects Show through the app-owned StatusNotifierItem/DBusMenu protocol. Linux screenshots without a desktop tray watcher do not establish rendered tray appearance.
- Actual uninstall/removal, no remaining client/Core/Helper processes, no product Helper service, no dangling Windows/Linux product URL/autostart registration, and no enabled macOS product background item. DMG removal uses LaunchServices unregister followed by removing only `/Applications/FlClashMeow.app`; this is the platform's copy/remove installation model.
- Original-product data sentinel bytes, URL/autostart values and existing Helper registration unchanged. Fixtures create only missing test data/registration in the original product's namespace, preserve existing registry values, and remove their own fixtures afterward.

The final AOT snapshot must contain the fork's update repository identity. This is static packaged update routing evidence, not an update request, download, signature or replacement test. Runtime updater download/replacement and Linux rendered tray presentation need separate evidence. TUN and privileged crash recovery remain separate native acceptance suites; this test does not enable them or claim they passed.

The CoreController test must load the installed package's `rust_api` library using `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR`. Artifact-only CI disables setup/rust_api build hooks in its disposable checkout after `flutter pub get`, so it cannot silently replace the downloaded package with freshly built native libraries. No workstation SDK or production pubspec is changed by the fixture.

## Existing build workflow entry

The registered `.github/workflows/build.yaml` accepts `acceptance_build_run`. Its empty default preserves normal validation and the existing `packages` option. A nonempty value runs only the six native `package-acceptance` jobs; ordinary tests, compilation and release jobs are skipped. It does not rebuild the downloaded installer or use staged `libclash` files.

Run this entry from a separate CI ref containing the harness/workflow checkpoint, so its concurrency group cannot cancel an active integration build. For example, after that ref has been pushed:

```sh
gh workflow run 343794887 --repo yukkodesu/FlClash-Patched \
  --ref ci/meow-package-acceptance \
  -f acceptance_build_run=37357154622 -f packages=false
```

The chosen run must already be completed. Before downloading, the job requires a positive decimal run ID and verifies the authenticated Actions API response: matching run ID, both repositories matching this fork, the expected build workflow path, a push/manual event, completed status and a full source SHA. It fetches that commit and verifies `core/meow-rs` is a submodule with a full core SHA. The run can contain other failed jobs, but each architecture must have its own named installer artifact; a missing artifact fails that job. `build-run.json` preserves the API provenance with the native JSONL and screenshots.

`buildClientCommit` and `coreCommit` identify the installed payload's build source. `harnessCommit` identifies the different checkout running the acceptance fixture; `buildRunId` identifies the artifact-producing run, and `runId` identifies the acceptance run. These values must not be conflated when reporting results.

## Verification state

The workstation-safe guard and package-integrity public boundary tests passed with Python. A read-only inspection of a real Windows x64 release payload found its Core/manifest/Helper coherent and its AOT update identity present. No workstation package install, service install, UI action or network configuration change was performed. Native install/tray/uninstall acceptance remains pending the six architecture jobs and their recorded JSONL/screenshots; this document is not a claim that those jobs passed.

```sh
python tool/desktop_package_acceptance_test.py
python -m py_compile tool/desktop_package_acceptance.py tool/desktop_package_acceptance_test.py
```

Uninstall is a strict gate: if a production installer leaves runtime-created URL or autostart registration, the fixture fails and reports it. Cleanup in the fixture must not erase those registrations before asserting the production uninstall result.
