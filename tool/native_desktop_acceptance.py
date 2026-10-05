import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(
        description='Run native TUN acceptance on a disposable GitHub-hosted runner.'
    )
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--mode', choices=['fake-ip', 'global'], default='fake-ip')
    options = parser.parse_args()
    if os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        parser.error('Native network changes require a disposable GitHub-hosted runner.')
    if os.name == 'nt' and not ctypes.windll.shell32.IsUserAnAdmin():
        parser.error('The Windows runner must already have an elevated token.')

    workspace = Path(__file__).resolve().parents[1] / 'core' / 'meow-rs'
    build = subprocess.run(
        [
            'cargo', 'test', '--locked', '-p', 'flclash-meow-host',
            '--test', 'native_desktop', '--no-run', '--message-format=json',
        ],
        cwd=workspace,
        stdout=subprocess.PIPE,
        text=True,
        check=True,
    )
    executables = []
    for line in build.stdout.splitlines():
        artifact = json.loads(line)
        if artifact.get('reason') == 'compiler-message':
            print(artifact['message'].get('rendered', ''), end='')
        if (
            artifact.get('reason') == 'compiler-artifact'
            and artifact['target']['name'] == 'native_desktop'
            and artifact.get('executable')
        ):
            executables.append(artifact['executable'])
    if len(executables) != 1 or not Path(executables[0]).is_file():
        raise RuntimeError('Cargo did not identify exactly one native acceptance executable.')

    native_environment = {
        'MEOW_DISPOSABLE_NATIVE_RUNNER': '1',
        'MEOW_NATIVE_ROUTE_MODE': options.mode,
    }
    command = [executables[0], '--ignored', '--nocapture', '--test-threads=1']
    if os.name != 'nt':
        command = [
            'sudo', '--non-interactive', 'env',
            *(f'{key}={value}' for key, value in native_environment.items()),
            *command,
        ]
    options.log.parent.mkdir(parents=True, exist_ok=True)
    with options.log.open('w', encoding='utf-8') as evidence:
        with subprocess.Popen(
            command,
            cwd=workspace,
            env={**os.environ, **native_environment},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8',
            errors='replace',
        ) as process:
            for line in process.stdout:
                evidence.write(line)
                evidence.flush()
                print(line, end='', flush=True)
            return process.wait()


if __name__ == '__main__':
    sys.exit(main())
