import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


SERVICE = 'FlClashMeowHelperService' if os.name == 'nt' else 'flclash-meow-helper'
STAGE = (
    Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'FlClash-Meow-Acceptance'
    if os.name == 'nt' else Path('/opt/flclash-meow-acceptance')
)
SUFFIX = '.exe' if os.name == 'nt' else ''
CORE = STAGE / f'FlClashMeowCore{SUFFIX}'
HELPER = STAGE / f'FlClashMeowHelperService{SUFFIX}'
MANIFEST = STAGE / 'manifest.json'
ORIGINAL = STAGE / 'FlClashMeowCore.original'


def require_runner():
    if (
        os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
        or os.environ.get('GITHUB_ACTIONS') != 'true'
        or not os.environ.get('GITHUB_RUN_ID', '').isdigit()
        or sys.platform not in ('win32', 'linux')
    ):
        raise RuntimeError('Helper service acceptance requires a disposable GitHub-hosted Windows/Linux runner.')
    if os.name == 'nt' and not ctypes.windll.shell32.IsUserAnAdmin():
        raise RuntimeError('Windows service acceptance requires the runner administrator token.')


def run(command, *, privileged=False, check=True):
    if privileged and os.name != 'nt':
        command = ['sudo', '--non-interactive', *command]
    return subprocess.run(command, check=check, text=True, capture_output=True, timeout=40)


def powershell(script):
    return run(['powershell', '-NoProfile', '-NonInteractive', '-Command', script]).stdout.strip()


def snapshot():
    if os.name == 'nt':
        value = powershell('''
$ErrorActionPreference = 'Stop'
$service = Get-CimInstance Win32_Service -Filter "Name='FlClashMeowHelperService'"
$cores = @(Get-CimInstance Win32_Process -Filter "Name='FlClashMeowCore.exe'" |
    Where-Object { $_.ExecutablePath -eq $env:FLCLASH_MEOW_ACCEPTANCE_CORE } |
    Select-Object ProcessId, ParentProcessId, ExecutablePath, CommandLine)
@{ service = $service | Select-Object State, ProcessId, PathName, StartName; cores = $cores } |
    ConvertTo-Json -Depth 4 -Compress
''')
        return json.loads(value)
    service = run([
        'systemctl', 'show', f'{SERVICE}.service', '--no-pager',
        '--property=LoadState,ActiveState,SubState,MainPID,ControlGroup,ExecStart',
    ]).stdout
    values = dict(line.split('=', 1) for line in service.splitlines() if '=' in line)
    processes = run(['ps', '-eo', 'pid=,ruid=,euid=,rgid=,egid=,args='], privileged=True).stdout
    cores = []
    for line in processes.splitlines():
        parts = line.split(None, 5)
        if len(parts) != 6 or parts[5].split(None, 1)[0] != str(CORE):
            continue
        pid = int(parts[0])
        try:
            cgroup = Path(f'/proc/{pid}/cgroup').read_text()
        except FileNotFoundError:
            continue
        cores.append({
            'ProcessId': pid, 'realUid': int(parts[1]), 'effectiveUid': int(parts[2]),
            'realGid': int(parts[3]), 'effectiveGid': int(parts[4]),
            'CommandLine': parts[5], 'cgroup': cgroup,
        })
    return {'service': values, 'cores': cores}


def service_action(action):
    if action in ('install', 'uninstall'):
        run([str(HELPER), action], privileged=True)
    elif os.name == 'nt':
        if action == 'start':
            powershell("Start-Service -Name FlClashMeowHelperService -ErrorAction Stop")
        elif action == 'stop':
            powershell("Stop-Service -Name FlClashMeowHelperService -ErrorAction Stop")
        else:
            powershell('''
$ErrorActionPreference = 'Stop'
$service = Get-CimInstance Win32_Service -Filter "Name='FlClashMeowHelperService'"
if ($service.ProcessId -le 0) { throw 'Helper is not running' }
Stop-Process -Id $service.ProcessId -Force -ErrorAction Stop
''')
    else:
        command = (
            ['systemctl', 'kill', '--kill-who=main', '--signal=SIGKILL', f'{SERVICE}.service']
            if action == 'crash' else ['systemctl', action, f'{SERVICE}.service']
        )
        run(command, privileged=True)


def reject_foreign_peer():
    if os.name == 'nt':
        raise RuntimeError('Unix peer credential check is Linux-only.')
    script = '''
import socket
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
s.connect('/run/flclash-meow/helper.sock')
try:
    s.sendall(b'GET /ping?coreSha256=' + b'0' * 64 + b' HTTP/1.1\\r\\nHost: local\\r\\nConnection: close\\r\\n\\r\\n')
    reply = s.recv(4096)
except (ConnectionResetError, BrokenPipeError):
    reply = b''
finally:
    s.close()
if reply.startswith(b'HTTP/'):
    raise SystemExit('Root peer unexpectedly reached the user-owned Helper HTTP API')
print('foreign UID rejected before HTTP dispatch')
'''
    result = run([sys.executable, '-c', script], privileged=True)
    return {'foreignPeer': result.stdout.strip()}


def core_digest(path):
    digest = hashlib.sha256()
    with path.open('rb') as binary:
        for block in iter(lambda: binary.read(65536), b''):
            digest.update(block)
    return digest.hexdigest()


def integrity_action(action):
    if snapshot()['cores']:
        raise RuntimeError('The integrity fixture may only change a stopped Core.')
    if action == 'corrupt-core':
        if ORIGINAL.exists():
            raise RuntimeError('A previous integrity fixture was not restored.')
        if os.name == 'nt':
            shutil.copy2(CORE, ORIGINAL)
            with CORE.open('ab') as binary:
                binary.write(b'\x00')
        else:
            run(['cp', '--', str(CORE), str(ORIGINAL)], privileged=True)
            run([sys.executable, '-c', "with open('/opt/flclash-meow-acceptance/FlClashMeowCore', 'ab') as core: core.write(b'\\x00')"], privileged=True)
    else:
        if os.name == 'nt':
            os.replace(ORIGINAL, CORE)
        else:
            run(['mv', '--', str(ORIGINAL), str(CORE)], privileged=True)
    return {'coreSha256': core_digest(CORE)}


def assert_bundle(bundle):
    names = [CORE.name, HELPER.name, MANIFEST.name]
    files = [bundle / name for name in names]
    if any(not path.is_file() or path.is_symlink() for path in files):
        raise RuntimeError('The bundle must contain the staged production Core, Helper and manifest.')
    expected = json.loads(files[2].read_text())['coreSha256']
    actual = core_digest(files[0])
    if expected != actual:
        raise RuntimeError('The final staged Core does not match the production manifest.')
    return files, actual


def stage_bundle(bundle):
    files, digest = assert_bundle(bundle)
    if STAGE.exists():
        raise RuntimeError(f'Refusing to replace a pre-existing acceptance installation: {STAGE}')
    if os.name == 'nt':
        STAGE.mkdir()
        for source in files:
            shutil.copy2(source, STAGE / source.name)
    else:
        run(['install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', str(STAGE)], privileged=True)
        for source in files:
            run([
                'install', '-o', 'root', '-g', 'root', '-m',
                '0644' if source.name == MANIFEST.name else '0755', str(source), str(STAGE / source.name),
            ], privileged=True)
    return digest


def main():
    parser = argparse.ArgumentParser(description='Exercise the actual privileged Helper on disposable native CI.')
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--log', type=Path)
    parser.add_argument('--action', choices=['snapshot', 'stop', 'start', 'crash', 'foreign-peer', 'corrupt-core', 'restore-core'])
    options = parser.parse_args()
    require_runner()
    os.environ['FLCLASH_MEOW_ACCEPTANCE_CORE'] = str(CORE)
    if options.action:
        if not HELPER.is_file() or not MANIFEST.is_file():
            raise RuntimeError('The protected acceptance bundle is not staged.')
        if options.action == 'foreign-peer':
            result = reject_foreign_peer()
        elif options.action in ('corrupt-core', 'restore-core'):
            result = integrity_action(options.action)
        elif options.action == 'snapshot':
            result = snapshot()
        else:
            service_action(options.action)
            result = {'action': options.action}
        print(json.dumps(result), flush=True)
        return 0
    if options.bundle is None or options.log is None:
        parser.error('--bundle and --log are required for a complete acceptance run.')
    options.log.parent.mkdir(parents=True, exist_ok=True)
    with options.log.open('w', encoding='utf-8') as evidence:
        def record(phase):
            value = {'phase': phase, **snapshot()}
            line = json.dumps(value)
            evidence.write(line + '\n')
            evidence.flush()
            print(line, flush=True)
            return value

        initial = record('before-install')
        service = initial['service']
        if initial['cores'] or (service and service.get('LoadState') != 'not-found'):
            raise RuntimeError('The product Helper or its Core already exists; refusing to replace it.')
        digest = stage_bundle(options.bundle.resolve())
        evidence.write(json.dumps({
            'coreSha256': digest, 'helperSha256': core_digest(HELPER),
            'manifestSha256': core_digest(MANIFEST), 'stage': str(STAGE),
            'clientCommit': run(['git', 'rev-parse', 'HEAD']).stdout.strip(),
            'coreCommit': run(['git', '-C', 'core/meow-rs', 'rev-parse', 'HEAD']).stdout.strip(),
            'runId': os.environ['GITHUB_RUN_ID'],
        }) + '\n')
        try:
            service_action('install')
            record('after-install')
            environment = {
                **os.environ,
                'FLCLASH_MEOW_PRIVILEGED_ACCEPTANCE': '1',
                'FLCLASH_MEOW_HELPER': str(HELPER),
                'FLCLASH_MEOW_HELPER_MANIFEST': str(MANIFEST),
                'FLCLASH_MEOW_ACCEPTANCE_PYTHON': sys.executable,
            }
            flutter = shutil.which('flutter')
            if flutter is None:
                raise RuntimeError('Flutter is unavailable.')
            command = [flutter, 'test', 'test/core/privileged_helper_integration_test.dart', '--reporter', 'expanded']
            try:
                result = subprocess.run(
                    command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding='utf-8', errors='replace', timeout=480,
                )
                output = result.stdout
                exit_code = result.returncode
            except subprocess.TimeoutExpired as error:
                output = error.stdout or b''
                if isinstance(output, bytes):
                    output = output.decode('utf-8', errors='replace')
                evidence.write(output)
                raise RuntimeError('Helper acceptance exceeded its eight-minute deadline.') from error
            evidence.write(output)
            evidence.flush()
            print(output, end='', flush=True)
            record('before-uninstall')
        finally:
            service_action('uninstall')
            final = record('after-uninstall')
            if final['cores'] or (
                final['service'] and final['service'].get('LoadState') != 'not-found'
            ):
                raise RuntimeError('Uninstall left the product service or a managed Core behind.')
            if STAGE.is_symlink() or STAGE.resolve() != STAGE.absolute():
                raise RuntimeError('The fixed acceptance installation path changed before cleanup.')
            if os.name == 'nt':
                shutil.rmtree(STAGE)
            else:
                for path in [CORE, HELPER, MANIFEST, ORIGINAL]:
                    if not path.exists():
                        continue
                    run(['rm', '--', str(path)], privileged=True)
                run(['rmdir', '--', str(STAGE)], privileged=True)
        return exit_code


if __name__ == '__main__':
    sys.exit(main())
