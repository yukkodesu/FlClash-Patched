# Provider and group public acceptance

The original CoreController real-host test exercised a select group and ordinary listener traffic, but did not switch group selections, release automatic fixation or refresh providers. The embedded host already had genuine public RPC coverage:

- `tests/host.rs::provider_members_can_be_selected_probed_and_refreshed_without_losing_valid_data`: file-provider members, selection, actual local HTTP node probing, invalid document refresh preserving old nodes, and successful refresh replacing members.
- `tests/runtime.rs::stopping_cancels_pending_provider_preparation`: a local HTTP provider held during setup, a later stop superseding the request, remote TCP EOF and no committed configuration/cache.

The added CoreController fixtures use the production desktop lifecycle, framed IPC, authenticated native peer and real meow host. Their only HTTP origin is a temporary local server. No subscription, public proxy node, service install, TUN or OS network configuration change is required.

`CoreController restores group selections and releases automatic fixation` observes restored select/URL-test selections, a missing member rejected without losing the current selection, successful selection, and releasing a URL-test group's fixed REJECT choice back to automatic DIRECT. It exposed a real client error: `changeProxy(proxyName: '')`, used by the UI's reset operation, sent an ordinary selection update. The fix routes that existing facade operation to the host's existing `unfixProxy` RPC, preserving the optional close-connections request. Engine capabilities and the core pin are unchanged.

`CoreController refreshes providers and cancels stale updates across sessions` loads a local HTTP provider, queries its public metadata/members, restores a provider-member selection, returns a 503 refresh error while preserving the last good set, then successfully replaces the set and selects the new member. A held refresh is cancelled by stop with `request_cancelled`; its late response cannot replace the good set. After a complete host restart, a normal file-provider configuration reads the previously maintained provider cache and still exposes the good set, proving that the late refresh did not corrupt a subsequent session.

## Recorded verification

Windows x64 used the actual release `FlClashMeowCore.exe` reporting core commit `604e72e16d67922be390a4ae98823e56f4ee59f9` and its packaged `rust_api.dll`. The automatic-unfix fixture failed before the facade fix with `runtime_error: proxy not exist`, then passed. Both added fixtures, the existing traffic/authentication/DNS E2E and the protocol contract tests passed: 12 tests total.

```powershell
$env:FLCLASH_MEOW_HOST = 'D:/Code/FlClash-Patched/build/windows/x64/runner/Release/FlClashMeowCore.exe'
$env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = 'D:/Code/FlClash-Patched/build/windows/x64/runner/Release'
$env:MEOW_HOST_COMMIT = '604e72e16d67922be390a4ae98823e56f4ee59f9'
flutter test test/core/meow_host_integration_test.dart test/core/protocol_contract_test.dart --reporter expanded
```

Build hooks were disabled only in the fixture worktree during verification and restored before committing. The logs are `provider-unfix-red.log`, `provider-unfix-green.log`, `provider-refresh-check.log`, and `provider-public-green.log` under `D:/Code/.worktrees/meow-tooling/`.

This proves the updated Dart CoreController against the packaged Windows host, not a rebuilt AOT UI containing this facade fix. Package rebuilds must use the updated client source. Linux/macOS and ARM64 need their corresponding native jobs; the existing mandatory E2E job and package harness select this same test file and will include the new fixtures.
