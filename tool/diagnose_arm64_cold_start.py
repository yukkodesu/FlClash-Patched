import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

import desktop_package_acceptance as package

CLIENT = 'd675cea604e7535f025169da46a7457b54c1376e'
CORE = 'b5ae8471d1d79ad0e82026f1da9060458abcfa23'
INSTALLER_SHA = 'fa97f6b845e2ea7eac8a7db4c780993b587eb038fe62bd3df93d62dc79996375'
CORE_SHA = '4160b217a6d2b8a33a1785fdb4b03581032da36b987782f2cfa98d707b1b9c46'
RUST_API_SHA = '46d0708fd76888324edc1b47582d90086d3499b968877359de38119f78eeec85'


def verdict(text, processes, root):
    connected = [int(pid) for pid in re.findall(r'IPC Connected: (\d+)', text)]
    owned = [row for row in processes if os.path.normcase(row.get('ExecutablePath') or '') == os.path.normcase(str(root / 'FlClashMeowCore.exe'))]
    invalid = 'invalid IPC frame size' in text
    if invalid and connected and not owned:
        return 'RED_INVALID_FRAME_AND_LOST_CORE'
    if invalid:
        return 'INCONCLUSIVE_FRAME_ERROR_WITH_LIVE_CORE'
    if len(owned) == 1 and connected and owned[0]['ProcessId'] == connected[-1]:
        return 'GREEN_CONNECTED_OWNED_CORE'
    return 'INCONCLUSIVE_STARTUP'


def kill_owned_core(client_pid, root):
    for row in package.owned_cores(root):
        if row['ParentProcessId'] == client_pid:
            package.powershell(f"Stop-Process -Id {int(row['ProcessId'])} -Force -ErrorAction Stop")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=25)
    parser.add_argument('--seconds', type=float, default=8)
    parser.add_argument('--skip-controller-prelude', action='store_true')
    parser.add_argument('--skip-helper-prelude', action='store_true')
    parser.add_argument('--skip-original-fixture', action='store_true')
    args = parser.parse_args()
    package.require_runner()
    if package.PLATFORM != 'windows' or platform.machine().lower() != 'arm64':
        raise RuntimeError('Requires disposable native Windows ARM64 CI.')
    if package.product_processes():
        raise RuntimeError('Refusing existing product processes.')
    actual_client = package.run(['git', 'rev-parse', os.environ['BUILD_CLIENT_SHA']]).stdout.strip()
    actual_core = package.run(['git', 'rev-parse', f'{actual_client}:core/meow-rs']).stdout.strip()
    if (actual_client, actual_core, os.environ['BUILD_RUN_ID']) != (CLIENT, CORE, '37374536042'):
        raise RuntimeError('Rejecting inputs other than frozen B5 producer.')
    installation = package.Installation(args.dist.resolve(), 'arm64')
    if package.digest(installation.artifact) != INSTALLER_SHA:
        raise RuntimeError('Installer differs from failing run.')
    args.log.parent.mkdir(parents=True, exist_ok=True)
    fixture = package.OriginalProductFixture()
    client = None
    reds = inconclusive = 0
    with args.log.open('w', encoding='utf-8') as output:
        def record(phase, **values):
            encoded = json.dumps(dict(phase=phase, runId=os.environ['GITHUB_RUN_ID'], **values))
            output.write(encoded + '\n'); output.flush()
            print(encoded, flush=True)
        record('source', sourceClient=CLIENT, sourceCore=CORE, buildRunId=37374536042,
               harness=package.run(['git', 'rev-parse', 'HEAD']).stdout.strip(), installerSha256=INSTALLER_SHA)
        try:
            if args.skip_original_fixture:
                record('original-fixture-omitted', reason='single-variable minimisation')
            else:
                fixture.install()
            installation.install()
            payload = package.inspect_payload(installation.root, 'windows')
            libraries = list(installation.root.rglob('rust_api.dll'))
            if payload['coreSha256'] != CORE_SHA or len(libraries) != 1 or package.digest(libraries[0]) != RUST_API_SHA:
                raise RuntimeError('Installed Core/library differs from failing run.')
            for exe in (installation.client, installation.root / 'FlClashMeowCore.exe'):
                if package.native_arch(exe, 'windows') != ['arm64']:
                    raise RuntimeError('Payload is not native ARM64.')
            version = package.run([str(installation.root / 'FlClashMeowCore.exe'), '--version']).stdout.strip()
            if CORE not in version:
                raise RuntimeError('Installed source mismatch.')
            record('payload', **payload, rustApiSha256=RUST_API_SHA, version=version, clientSha256=package.digest(installation.client))
            if args.skip_controller_prelude:
                record('core-controller-prelude-omitted', reason='single-variable minimisation')
            else:
                record('core-controller-prelude', **package.core_controller_e2e(installation.root, args.log.parent))
            if args.skip_helper_prelude:
                record('helper-prelude-omitted', reason='single-variable minimisation')
            else:
                record('helper-prelude', **package.helper_probe(installation.root, CORE_SHA))
            for index in range(args.iterations):
                if package.product_processes():
                    raise RuntimeError('Previous trial retains product processes.')
                data_home = package.seed_settings(installation.client, True)
                path = args.log.parent / f'trial-{index:03d}.log'
                started = time.monotonic()
                with path.open('w', encoding='utf-8') as stream:
                    client = subprocess.Popen([str(installation.client)], stdout=stream, stderr=subprocess.STDOUT)
                    while time.monotonic() - started < args.seconds and client.poll() is None:
                        text = path.read_text(encoding='utf-8', errors='replace')
                        if 'invalid IPC frame size' in text: break
                        time.sleep(0.1)
                    text = path.read_text(encoding='utf-8', errors='replace')
                    processes = package.product_processes()
                    status = verdict(text, processes, installation.root)
                    deadline = time.monotonic() + 3
                    while status == 'INCONCLUSIVE_FRAME_ERROR_WITH_LIVE_CORE' and time.monotonic() < deadline:
                        processes = package.product_processes()
                        status = verdict(text, processes, installation.root)
                    reds += status.startswith('RED_'); inconclusive += status.startswith('INCONCLUSIVE_')
                    record('trial', trial=index, verdict=status, elapsedSeconds=round(time.monotonic() - started, 3),
                           clientPid=client.pid, returnCode=client.poll(), dataHome=str(data_home), processes=processes,
                           windows=package.visible_windows(client.pid), errorLines=[line for line in text.splitlines()
                           if any(token in line for token in ('invalid IPC frame size', 'IPC Connected:', 'IPC Disconnected', 'timed out', 'Config loaded:'))])
                    if index == 0 or status.startswith('RED_'): package.screenshot(args.log.parent / f'trial-{index:03d}.png')
                    package.shortcut('F12')
                    try: client.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        client.terminate(); client.wait(timeout=10)
                    kill_owned_core(client.pid, installation.root)
                    client = None
                package.wait_for(lambda: not package.product_processes(), 'diagnostic-owned process cleanup', timeout=10)
            record('summary', iterations=args.iterations, exactRed=reds, inconclusive=inconclusive,
                   loopCommand=f'python tool/diagnose_arm64_cold_start.py --dist dist --log {args.log} --iterations {args.iterations} --seconds {args.seconds}')
        finally:
            if client is not None:
                if client.poll() is None: client.terminate(); client.wait(timeout=10)
                kill_owned_core(client.pid, installation.root)
            installation.uninstall()
            fixture.remove()
    return 1 if reds else 2 if inconclusive else 0


if __name__ == '__main__':
    sys.exit(main())
