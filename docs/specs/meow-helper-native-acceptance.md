# Actual privileged Helper acceptance

This is an opt-in service lifetime check for disposable GitHub-hosted Windows
and Linux runners. It does not run on a developer workstation or self-hosted
runner. The ordinary case leaves network settings unchanged; a separate guarded
TUN case verifies DNS/routes, fake-IP traffic and restoration on disposable runners.
macOS privileged launch has a separate host acceptance path.

The driver runs ordinary and TUN cases separately. The TUN case uses the actual
CoreController/HelperLauncher/IPC path, two listener generations and the unchanged
30-second graceful cleanup/two-second exit budgets. It records baseline, running,
stopped, terminal-close and final DNS/routes/journals and confirms managed Core exit.

[Seventh CI](https://github.com/yukkodesu/FlClash-Patched/actions/runs/37371601020)
at client `6b955d61`/core `b5ae8471` passed both real cases on Linux x64/ARM64 and
Windows x64. Terminal close took 80 ms/70 ms/5274 ms respectively; original
DNS/routes returned, journals were empty and no managed Core remained. Windows
ARM64 did not acquire a runner. These production Release results do not resolve
the independent Windows Debug TUN IPC EOF. Linux direct Core DNS traffic does
not establish sustained OS resolver redirection. Package installation remains a
separate acceptance requirement; the harness stages protected test installations.

Build the production artifacts with `dart run bin/build_desktop.dart <platform>
<amd64|arm64>` from `plugins/setup/setup_hooks`. Keep the native `rust_api` library
available through `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR`, then invoke
from the client root:

```sh
python tool/privileged_helper_acceptance.py \
  --bundle libclash/linux --log .dart_tool/native-evidence/helper-linux-amd64.log
```

Use `libclash/windows` for Windows. `--bundle` can also point to an extracted final
package's executable directory: it must contain `FlClashMeowCore`,
`FlClashMeowHelperService` (both with `.exe` on Windows), and `manifest.json`.
The harness checks the actual Core SHA256 before staging. It copies these exact
files into a protected test installation, invokes the production Helper's
`install` command and runs the real CoreController/HelperLauncher/IPC path.
Linux's installer learns the runner's UID through sudo; the Flutter test itself
stays unelevated. Windows requires an administrator token and uses the actual
SCM service running as LocalSystem.

The acceptance test verifies:

- A matching manifest and embedded Helper hash permit the fixed Core; a wrong
  manifest hash, an executable override field and a modified Core are rejected.
- Only the active session can stop its Core. Restart leaves one owned Core and
  confirms the prior PID exited. Named-pipe peer PID matches the Core PID returned
  by the Helper.
- The privileged Core applies an ordinary proxy configuration and transfers a
  known response from a local origin before restart and Helper crash. TUN stays
  disabled throughout the service lifetime check.
- Linux Core real UID matches the caller, effective UID is root, and its process
  belongs to the Helper's actual systemd cgroup. A root peer is rejected by the
  user-scoped Helper socket before HTTP dispatch.
- Client IPC loss, clean service stop and forced Helper termination leave no
  managed Core. The forced termination exercises Windows Job Object closure
  and Linux cgroup cleanup. Service recovery permits a fresh single Core.
- Terminal close and production uninstall leave no owned process or registered
  product service. Snapshots are recorded before/after installation and each
  lifetime transition, including the final staged hash and native process data.

The runner refuses an existing product service or test installation. Cleanup
runs in `finally`; evidence remains available even when an assertion fails.
The Linux crash command uses the option supported by
[systemd 249](https://github.com/systemd/systemd/blob/v249/src/systemctl/systemctl.c),
as shipped on the Ubuntu 22.04 CI target.

Local format, analysis, Python syntax and runner rejection checks only validate
the harness. A locally skipped Flutter test is not service acceptance. T1/V1
remain pending until this check passes on each native Windows/Linux architecture
and the uploaded evidence records exact client/core commits. Staged artifact
acceptance also does not establish UI installation, upgrade or uninstall behavior
of every package format.
