import argparse
import ctypes
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import time


PRODUCT = 'FlClash-Meow'
BUNDLE_ID = 'com.yukko.flclashmeow'
PLATFORM = {'win32': 'windows', 'linux': 'linux', 'darwin': 'macos'}.get(sys.platform)
SUFFIX = '.exe' if os.name == 'nt' else ''
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
WINDOWS_UIA_SETUP = '''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$providerName = [System.Windows.Automation.AutomationElement].Assembly.GetName()
$providerName.Name = 'UIAutomationClientsideProviders'
$providerAssembly = [System.Reflection.Assembly]::Load($providerName)
[System.Windows.Automation.ClientSettings]::RegisterClientSideProviderAssembly($providerAssembly.GetName())
'''


def require_runner():
    if (
        os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
        or os.environ.get('GITHUB_ACTIONS') != 'true'
        or not os.environ.get('GITHUB_RUN_ID', '').isdigit()
        or PLATFORM is None
    ):
        raise RuntimeError('Package acceptance requires a disposable GitHub-hosted native desktop runner.')
    if os.name == 'nt' and not ctypes.windll.shell32.IsUserAnAdmin():
        raise RuntimeError('The disposable Windows runner must already have administrator rights.')
    if PLATFORM == 'linux' and (not os.environ.get('DISPLAY') or not os.environ.get('DBUS_SESSION_BUS_ADDRESS')):
        raise RuntimeError('Linux package acceptance needs an X11 window manager and a D-Bus desktop session.')


def run(command, *, privileged=False, check=True, timeout=60):
    if privileged and os.name != 'nt':
        command = ['sudo', '--non-interactive', *command]
    return subprocess.run(command, check=check, capture_output=True, text=True, timeout=timeout)


def powershell(script):
    return run(['powershell', '-NoProfile', '-NonInteractive', '-Command', script]).stdout.strip()


def failure_details(error):
    result = {'error': str(error)}
    if isinstance(error, (subprocess.CalledProcessError, subprocess.TimeoutExpired)):
        def decoded(value):
            return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else value or ''
        result.update(command=error.cmd, stdout=decoded(error.stdout), stderr=decoded(error.stderr))
        if isinstance(error, subprocess.CalledProcessError):
            result['returnCode'] = error.returncode
        else:
            result['timeoutSeconds'] = error.timeout
    if hasattr(error, 'tray_inventory'):
        result['trayInventory'] = error.tray_inventory
    return result


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(64 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def inspect_payload(root, target, staged=None):
    suffix = '.exe' if target == 'windows' else ''
    core = root / f'FlClashMeowCore{suffix}'
    helper = root / f'FlClashMeowHelperService{suffix}'
    manifest = root / 'manifest.json'
    legacy = {'mihomo', 'mihomo.exe', 'flclashcore', 'flclashcore.exe', 'libclash.dll', 'libclash.so', 'libclash.dylib', 'meow', 'meow.exe'}
    found = [str(path) for path in root.rglob('*') if path.name.lower() in legacy]
    if found:
        raise RuntimeError(f'Package contains legacy/second-core artifacts: {found}')
    if not core.is_file() or core.is_symlink():
        raise RuntimeError('Package has no ordinary Rust host file.')
    record = {'coreSha256': digest(core), 'core': str(core)}
    if target == 'macos':
        if helper.exists() or manifest.exists():
            raise RuntimeError('macOS must retain its no-Helper/no-Helper-manifest contract.')
        return record
    if not helper.is_file() or helper.is_symlink() or not manifest.is_file() or manifest.is_symlink():
        raise RuntimeError('Package is missing its fixed Helper or manifest.')
    if json.loads(manifest.read_text())['coreSha256'] != record['coreSha256']:
        raise RuntimeError('Packaged Core differs from its manifest.')
    record.update(helperSha256=digest(helper), manifestSha256=digest(manifest), helper=str(helper))
    if staged is not None:
        if digest(staged / core.name) != record['coreSha256']:
            raise RuntimeError('Packaged Core differs from staged production Core.')
        if digest(staged / helper.name) != record['helperSha256']:
            raise RuntimeError('Packaged Helper differs from staged production Helper.')
    return record


def native_arch(path, target):
    if target == 'macos':
        return run(['lipo', '-archs', str(path)]).stdout.strip().split()
    with path.open('rb') as stream:
        header = stream.read(64)
        if target == 'windows' and header[:2] == b'MZ':
            stream.seek(struct.unpack_from('<I', header, 60)[0])
            pe = stream.read(6)
            if pe[:4] != b'PE\0\0':
                raise RuntimeError(f'Invalid PE executable: {path}')
            machine = struct.unpack_from('<H', pe, 4)[0]
            return [{0x8664: 'amd64', 0xaa64: 'arm64'}.get(machine, f'unknown-{machine}')]
        if target == 'linux' and header[:4] == b'\x7fELF' and header[4:6] == b'\x02\x01':
            machine = struct.unpack_from('<H', header, 18)[0]
            return [{62: 'amd64', 183: 'arm64'}.get(machine, f'unknown-{machine}')]
    raise RuntimeError(f'Package file is not a native {target} executable: {path}')


def product_processes():
    if os.name == 'nt':
        value = powershell('''
@(Get-CimInstance Win32_Process | Where-Object {
  $_.Name -in @('FlClashMeow.exe','FlClashMeowCore.exe','FlClashMeowHelperService.exe')
} | Select-Object ProcessId,ParentProcessId,ExecutablePath,CommandLine) | ConvertTo-Json -Compress
''')
        parsed = json.loads(value or '[]')
        return parsed if isinstance(parsed, list) else [parsed]
    values = []
    for line in run(['ps', '-axo', 'pid=,ppid=,command=']).stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and Path(fields[2].split(' ', 1)[0]).name in ('FlClashMeow', 'FlClashMeowCore', 'FlClashMeowHelperService'):
            values.append({'ProcessId': int(fields[0]), 'ParentProcessId': int(fields[1]), 'CommandLine': fields[2]})
    return values


def owned_cores(root):
    expected = os.path.normcase(str(root / f'FlClashMeowCore{SUFFIX}'))
    return [process for process in product_processes()
            if os.path.normcase(process.get('ExecutablePath') or process['CommandLine'].split(' ', 1)[0]) == expected]


def wait_for(callback, description, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = callback()
        if result:
            return result
        time.sleep(0.3)
    raise RuntimeError(f'Timed out waiting for {description}.')


def visible_windows(pid):
    if os.name == 'nt':
        user32 = ctypes.windll.user32
        user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
        user32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
        result = []
        callback = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)

        @callback
        def visit(handle, _):
            owner = ctypes.c_ulong()
            user32.GetWindowThreadProcessId(handle, ctypes.byref(owner))
            title = ctypes.create_unicode_buffer(512)
            user32.GetWindowTextW(handle, title, len(title))
            if owner.value == pid and user32.IsWindowVisible(handle) and title.value:
                result.append({'handle': handle, 'title': title.value})
            return 1

        user32.EnumWindows(visit, None)
        return result
    if PLATFORM == 'linux':
        result = run(['xdotool', 'search', '--onlyvisible', '--pid', str(pid), '--name', PRODUCT], check=False)
        return result.stdout.split() if result.returncode == 0 else []
    source = '''import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let matching = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
print(String(data: try JSONSerialization.data(withJSONObject: matching), encoding: .utf8)!)'''
    return json.loads(run(['swift', '-e', source, str(pid)], timeout=40).stdout)


def shortcut(key):
    if os.name == 'nt':
        for code in (0x11, 0x12, 0x10, {'F11': 0x7a, 'F12': 0x7b}[key]):
            ctypes.windll.user32.keybd_event(code, 0, 0, 0)
        for code in ({'F11': 0x7a, 'F12': 0x7b}[key], 0x10, 0x12, 0x11):
            ctypes.windll.user32.keybd_event(code, 0, 2, 0)
    elif PLATFORM == 'linux':
        run(['xdotool', 'key', '--clearmodifiers', f'ctrl+alt+shift+{key}'])
    else:
        code = {'F11': 103, 'F12': 111}[key]
        run(['osascript', '-e', f'tell application "System Events" to key code {code} using {{control down, option down, shift down}}'])


def registrations():
    if os.name == 'nt':
        import winreg

        def value(path, name=''):
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path) as key:
                    return winreg.QueryValueEx(key, name)[0]
            except FileNotFoundError:
                return None

        return {
            'scheme': value(r'Software\Classes\flclash-meow\shell\open\command'),
            'autostart': value(r'Software\Microsoft\Windows\CurrentVersion\Run', PRODUCT),
            'oldScheme': value(r'Software\Classes\clash\shell\open\command'),
            'oldAutostart': value(r'Software\Microsoft\Windows\CurrentVersion\Run', 'FlClash'),
            'oldPatchedAutostart': value(r'Software\Microsoft\Windows\CurrentVersion\Run', 'FlClash-Patched'),
        }
    if PLATFORM == 'linux':
        startup = Path.home() / '.config/autostart/FlClash-Meow.desktop'
        handler = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'applications/flclash-meow-url-handler.desktop'
        return {
            'scheme': run(['xdg-mime', 'query', 'default', 'x-scheme-handler/flclash-meow'], check=False).stdout.strip(),
            'handler': handler.read_text() if handler.exists() else None,
            'autostart': startup.read_text() if startup.exists() else None,
            'oldScheme': run(['xdg-mime', 'query', 'default', 'x-scheme-handler/clash'], check=False).stdout.strip(),
            'oldAutostart': (Path.home() / '.config/autostart/FlClash.desktop').read_text() if (Path.home() / '.config/autostart/FlClash.desktop').exists() else None,
        }
    background = run(['sfltool', 'dumpbtm']).stdout
    entries = re.split(r'(?m)^\s*#\d+:', background)
    own = [entry for entry in entries if 'file:///Applications/FlClashMeow.app' in entry]
    source = '''import CoreServices
import Foundation
let schemes = ["flclash-meow", "clash"]
var values: [String: String] = [:]
for scheme in schemes { values[scheme] = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String? ?? "" }
print(String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)!)'''
    schemes = json.loads(run(['swift', '-e', source], timeout=40).stdout)
    return {'autostartRecords': own, 'autostartEnabled': any(re.search(r'Disposition:.*\benabled\b', entry) for entry in own),
            'scheme': schemes['flclash-meow'], 'oldScheme': schemes['clash'], 'backgroundItems': background}


def auto_enabled(record, client):
    if PLATFORM == 'macos':
        return record['autostartEnabled']
    return str(client) in (record.get('autostart') or '')


def scheme_open():
    uri = 'flclash-meow://acceptance'
    if os.name == 'nt':
        powershell(f"Start-Process '{uri}' -ErrorAction Stop")
    else:
        run(['open' if PLATFORM == 'macos' else 'xdg-open', uri])


def require_scheme(record, client):
    if PLATFORM == 'windows' and str(client).lower() not in (record['scheme'] or '').lower():
        raise RuntimeError('Product URL scheme is not registered to the installed executable.')
    if PLATFORM == 'linux' and (record['scheme'] != 'flclash-meow-url-handler.desktop' or str(client) not in (record['handler'] or '')):
        raise RuntimeError('Product URL scheme is not registered to the installed desktop executable.')
    if PLATFORM == 'macos' and record['scheme'] != BUNDLE_ID:
        raise RuntimeError('Product URL scheme is not registered to the installed bundle identifier.')


def core_controller_e2e(root, evidence_dir):
    library = {'windows': 'rust_api.dll', 'linux': 'librust_api.so', 'macos': 'librust_api.dylib'}[PLATFORM]
    bundle = root.parent.parent if PLATFORM == 'macos' else root
    libraries = list(bundle.rglob(library))
    if len(libraries) != 1:
        raise RuntimeError(f'Package must contain one real rust_api library: {libraries}.')
    environment = dict(os.environ, FLCLASH_MEOW_HOST=str(root / f'FlClashMeowCore{SUFFIX}'),
                       FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=str(libraries[0].parent))
    flutter = shutil.which('flutter')
    if flutter is None:
        raise RuntimeError('Flutter is required for the installed CoreController acceptance.')
    with (evidence_dir / 'installed-core-controller.log').open('w') as output:
        result = subprocess.run([flutter, 'test', 'test/core/meow_host_integration_test.dart', '--reporter', 'expanded'],
                                env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=900)
    if result.returncode != 0:
        raise RuntimeError('Installed-package CoreController acceptance failed; see installed-core-controller.log.')
    return {'rustApi': str(libraries[0]), 'rustApiSha256': digest(libraries[0]), 'core': environment['FLCLASH_MEOW_HOST']}


class OriginalProductFixture:
    def __init__(self):
        self.created = []
        self.registry = []
        self.parents = []

    def write(self, path, contents):
        if path.exists():
            raise RuntimeError(f'Refusing an existing original-product fixture file: {path}.')
        parents = []
        current = path.parent
        while not current.exists():
            parents.append(current)
            current = current.parent
        path.parent.mkdir(parents=True, exist_ok=True)
        self.parents.extend(reversed(parents))
        path.write_bytes(contents)
        self.created.append((path, contents))

    def install(self):
        data = (
            Path(os.environ['APPDATA']) / 'chenx-dust/flclash-patched' if os.name == 'nt'
            else Path.home() / 'Library/Application Support/com.follow.clash' if PLATFORM == 'macos'
            else Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'com.follow.clash'
        )
        self.write(data / '.meow-acceptance-original-profile.yaml', b'original product data must survive\n')
        if os.name == 'nt':
            import winreg
            scheme = r'Software\Classes\clash\shell\open\command'
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, scheme):
                    pass
            except FileNotFoundError:
                with winreg.CreateKey(winreg.HKEY_CURRENT_USER, scheme) as key:
                    winreg.SetValueEx(key, '', 0, winreg.REG_SZ, '"C:\\FlClash\\FlClash.exe" "%1"')
                self.registry.append((scheme, ''))
            path = r'Software\Microsoft\Windows\CurrentVersion\Run'
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, path) as key:
                for name in ('FlClash', 'FlClash-Patched'):
                    try:
                        winreg.QueryValueEx(key, name)
                    except FileNotFoundError:
                        winreg.SetValueEx(key, name, 0, winreg.REG_SZ, '"C:\\FlClash\\FlClash.exe"')
                        self.registry.append((path, name))
        elif PLATFORM == 'linux':
            self.write(Path.home() / '.config/autostart/FlClash.desktop', b'[Desktop Entry]\nType=Application\nName=FlClash\nExec=/bin/false\n')

    def verify(self):
        for path, contents in self.created:
            if path.read_bytes() != contents:
                raise RuntimeError(f'Installation/uninstallation changed original-product data: {path}.')
        return {str(path): digest(path) for path, _ in self.created}

    def remove(self):
        if os.name == 'nt':
            import winreg
            for path, name in reversed(self.registry):
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_SET_VALUE) as key:
                    winreg.DeleteValue(key, name)
        for path, _ in reversed(self.created):
            path.unlink()
        for path in reversed(self.parents):
            try:
                path.rmdir()
            except OSError:
                pass


def service_registration():
    if os.name == 'nt':
        return powershell("@(Get-CimInstance Win32_Service | Where-Object { $_.Name -in @('FlClashMeowHelperService','FlClashHelperService') } | Select-Object Name,State,PathName,ProcessId) | ConvertTo-Json -Compress")
    if PLATFORM == 'linux':
        return run(['systemctl', 'show', 'flclash-meow-helper.service', '--no-pager', '--property=LoadState,ActiveState,MainPID,ExecStart']).stdout
    return 'macOS has no Helper service'


def old_service_registration():
    if os.name == 'nt':
        return powershell("@(Get-CimInstance Win32_Service | Where-Object { $_.Name -eq 'FlClashHelperService' } | Select-Object Name,State,PathName,ProcessId) | ConvertTo-Json -Compress")
    if PLATFORM == 'linux':
        return run(['systemctl', 'show', 'flclash-helper.service', '--no-pager', '--property=LoadState,ActiveState,MainPID,ExecStart']).stdout
    return 'no original-product Helper fixture installed'


def embedded_update_identity(root):
    candidates = [root / 'data/app.so'] if PLATFORM != 'macos' else [root.parent / 'Frameworks/App.framework/Versions/A/App', root.parent / 'Frameworks/App.framework/App']
    snapshot = next((path for path in candidates if path.is_file()), None)
    if snapshot is None or b'yukkodesu/FlClash-Patched' not in snapshot.read_bytes():
        raise RuntimeError('Packaged AOT snapshot has no independent product update repository identity.')
    return {'scope': 'static packaged identity; no update request/download is inferred', 'repository': 'yukkodesu/FlClash-Patched', 'snapshotSha256': digest(snapshot)}


def seed_settings(client, auto_launch):
    config = {
        'themeProps': {},
        'appSettingProps': {
            'locale': 'en', 'disclaimerAccepted': True, 'autoRun': False,
            'autoCheckUpdate': False, 'autoLaunch': auto_launch, 'minimizeOnExit': False,
        },
        'networkProps': {'systemProxy': False, 'autoSetSystemDns': False},
        'patchClashConfig': {'tun': {'enable': False}},
        'hotKeyActions': [
            {'action': 'view', 'key': 0x00070044, 'modifiers': ['control', 'alt', 'shift']},
            {'action': 'exit', 'key': 0x00070045, 'modifiers': ['control', 'alt', 'shift']},
        ],
    }
    encoded = json.dumps(config)
    if PLATFORM == 'macos':
        run(['defaults', 'write', BUNDLE_ID, 'flutter.version', '-int', '2'])
        run(['defaults', 'write', BUNDLE_ID, 'flutter.config', '-string', encoded])
        return Path.home() / 'Library/Application Support' / BUNDLE_ID
    home = (
        Path(os.environ['APPDATA']) / 'yukkodesu/flclash-meow'
        if os.name == 'nt' else Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / BUNDLE_ID
    )
    home.mkdir(parents=True, exist_ok=True)
    (home / 'shared_preferences.json').write_text(json.dumps({'flutter.version': 2, 'flutter.config': encoded}))
    return home


class Installation:
    def __init__(self, dist, arch):
        extension = {'windows': '.exe', 'linux': '.deb', 'macos': '.dmg'}[PLATFORM]
        artifacts = [path for path in dist.rglob(f'*{extension}') if path.is_file()]
        if len(artifacts) != 1:
            raise RuntimeError(f'Expected one {extension} production package, found {artifacts}.')
        self.artifact = artifacts[0].resolve()
        self.arch = arch
        self.root = None
        self.client = None
        self.mounted = None
        self.bundle = None
        self.installed = False

    def install(self):
        if PLATFORM == 'windows':
            self.root = Path(os.environ['ProgramFiles']) / 'FlClash-Meow-Package-Acceptance'
            if self.root.exists():
                raise RuntimeError('Refusing an existing package acceptance installation.')
            self.installed = True
            self.client = self.root / 'FlClashMeow.exe'
            run([str(self.artifact), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', f'/DIR={self.root}'], timeout=180)
        elif PLATFORM == 'linux':
            package = run(['dpkg-deb', '-f', str(self.artifact), 'Package']).stdout.strip()
            arch = run(['dpkg-deb', '-f', str(self.artifact), 'Architecture']).stdout.strip()
            if package != 'flclash-meow' or arch != self.arch:
                raise RuntimeError(f'Unexpected Debian package identity: {package}/{arch}.')
            if run(['dpkg-query', '-W', '-f=${db:Status-Status}', package], check=False).stdout.strip() == 'installed':
                raise RuntimeError('Refusing to replace an existing product Debian installation.')
            self.installed = True
            run(['apt-get', 'install', '-y', str(self.artifact)], privileged=True, timeout=240)
            files = run(['dpkg-query', '-L', package]).stdout.splitlines()
            clients = [Path(path) for path in files if Path(path).name == 'FlClashMeow' and Path(path).is_file() and not Path(path).is_symlink()]
            if len(clients) != 1:
                raise RuntimeError(f'Unexpected packaged client executables: {clients}.')
            self.client = clients[0]
            self.root = self.client.parent
        else:
            self.root = Path('/Applications/FlClashMeow.app')
            self.bundle = self.root
            if self.root.exists():
                raise RuntimeError('Refusing to replace an existing product application bundle.')
            image = plistlib.loads(run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(self.artifact)]).stdout.encode())
            mounts = [Path(entity['mount-point']) for entity in image['system-entities'] if 'mount-point' in entity]
            if len(mounts) != 1:
                raise RuntimeError(f'Unexpected DMG mounts: {mounts}.')
            self.mounted = mounts[0]
            source = self.mounted / 'FlClashMeow.app'
            self.installed = True
            run(['ditto', str(source), str(self.root)], privileged=True)
            self.client = self.root / 'Contents/MacOS/FlClashMeow'
            info = plistlib.loads((self.root / 'Contents/Info.plist').read_bytes())
            if info['CFBundleIdentifier'] != BUNDLE_ID:
                raise RuntimeError('Wrong macOS package bundle identifier.')
            run(['codesign', '--verify', '--deep', '--strict', str(self.root)])
            run([LSREGISTER, '-f', str(self.root)])
            core = 'Contents/MacOS/FlClashMeowCore'
            if digest(source / core) != digest(self.root / core):
                raise RuntimeError('Installed signed Core differs from the actual DMG payload.')
            self.root = self.client.parent

    def uninstall(self):
        if not self.installed:
            return
        if PLATFORM == 'windows':
            uninstall = self.root / 'unins000.exe'
            if not uninstall.is_file():
                raise RuntimeError('Installed Inno package has no uninstaller.')
            run([str(uninstall), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'], timeout=180)
            wait_for(lambda: not self.client.exists(), 'Inno uninstall completion')
        elif PLATFORM == 'linux':
            run(['apt-get', 'purge', '-y', 'flclash-meow'], privileged=True, timeout=180)
            if self.client is not None and self.client.exists():
                raise RuntimeError('Debian uninstall left its client executable.')
        else:
            app = self.bundle
            if app != Path('/Applications/FlClashMeow.app'):
                raise RuntimeError('Refusing unexpected macOS uninstall path.')
            run([LSREGISTER, '-u', str(app)], check=False)
            run(['rm', '-rf', '--', str(app)], privileged=True)
        self.installed = False

    def detach(self):
        if self.mounted is not None:
            run(['hdiutil', 'detach', str(self.mounted)])
            self.mounted = None


class UnixHttpConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect('/run/flclash-meow/helper.sock')


def helper_probe(root, expected):
    helper = root / f'FlClashMeowHelperService{SUFFIX}'
    try:
        run([str(helper), 'install'], privileged=True)
        def ping(sha):
            connection = http.client.HTTPConnection('127.0.0.1', 47891, timeout=3) if os.name == 'nt' else UnixHttpConnection('local', timeout=3)
            try:
                connection.request('GET', f'/ping?coreSha256={sha}')
                response = connection.getresponse()
                return response.status, response.getheader('x-flclash-helper-protocol'), response.read().decode()
            finally:
                connection.close()

        def ready():
            try:
                response = ping(expected)
                return response if response[0] == 200 else None
            except OSError:
                return None

        good = wait_for(ready, 'packaged Helper verification')
        bad = ping('0' * 64)
        running_helper = os.path.normcase(str(Path(good[2]).resolve()))
        if (good[1] != '6' or running_helper != os.path.normcase(str(helper.resolve()))
                or bad[0] != 409 or bad[1] != '6' or 'coreSha256Mismatch' not in bad[2]):
            raise RuntimeError(f'Packaged Helper integrity contract failed: {good}, {bad}.')
        return {'matchingCore': good, 'wrongCore': bad}
    finally:
        run([str(helper), 'uninstall'], privileged=True)


def windows_tray_inventory(pid):
    source = WINDOWS_UIA_SETUP + '''
$rootElement = [System.Windows.Automation.AutomationElement]::RootElement
$walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
$queue = New-Object 'System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]'
$windows = $rootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
foreach ($window in $windows) {
  if ($window.Current.ClassName -in @('Shell_TrayWnd','Shell_SecondaryTrayWnd','NotifyIconOverflowWindow')) { $queue.Enqueue($window) }
}
$items = @()
$truncated = $false
while ($queue.Count -gt 0 -and $items.Count -lt 256) {
  $item = $queue.Dequeue()
  try {
    $current = $item.Current
    $items += @{name=$current.Name;class=$current.ClassName;automationId=$current.AutomationId;ownerPid=$current.ProcessId;offscreen=$current.IsOffscreen;controlType=$current.ControlType.ProgrammaticName}
    $child = $walker.GetFirstChild($item)
    while ($null -ne $child -and ($items.Count + $queue.Count) -lt 256) {
      $queue.Enqueue($child)
      $child = $walker.GetNextSibling($child)
    }
    if ($null -ne $child) { $truncated = $true }
  } catch { $items += @{error=$_.Exception.Message} }
}
@{items=@($items);truncated=($truncated -or $queue.Count -gt 0);providerAssembly=$providerAssembly.FullName} | ConvertTo-Json -Depth 5 -Compress
'''
    value = json.loads(run(['powershell', '-NoProfile', '-NonInteractive', '-Command', source], timeout=20).stdout)
    value['clientPid'] = pid
    return value


def activate_tray(pid):
    if PLATFORM == 'linux':
        panel_pid = os.environ.get('MEOW_PACKAGE_PANEL_PID', '')
        if not panel_pid.isdigit() or int(panel_pid) <= 1:
            raise RuntimeError('Linux tray acceptance requires its native Xfce panel PID.')
        panels = wait_for(lambda: run(['xdotool', 'search', '--onlyvisible', '--pid', panel_pid, '--class', 'xfce4-panel'], check=False).stdout.split(), 'visible native desktop tray panel')
        source = '''import json, sys
from pathlib import Path
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
def call(name, path, interface, member, signature=None, values=()):
    arguments = GLib.Variant(signature, values) if signature else None
    return bus.call_sync(name, path, interface, member, arguments, None, Gio.DBusCallFlags.NONE, 3000, None).unpack()
names = call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ListNames')[0]
for name in names:
    if not name.startswith(':'):
        continue
    try:
        owner = call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetConnectionUnixProcessID', '(s)', (name,))[0]
        if owner != int(sys.argv[1]):
            continue
        title = call(name, '/StatusNotifierItem', 'org.freedesktop.DBus.Properties', 'Get', '(ss)', ('org.kde.StatusNotifierItem', 'Title'))[0]
        if title != 'FlClash-Meow':
            continue
        watcher = 'org.kde.StatusNotifierWatcher'
        state = call(watcher, '/StatusNotifierWatcher', 'org.freedesktop.DBus.Properties', 'GetAll', '(s)', ('org.kde.StatusNotifierWatcher',))[0]
        if not state.get('IsStatusNotifierHostRegistered'):
            raise RuntimeError('No registered native StatusNotifier host')
        registered = []
        for item in state.get('RegisteredStatusNotifierItems', []):
            service, separator, path = item.partition('/')
            if separator and call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetConnectionUnixProcessID', '(s)', (service,))[0] == owner:
                registered.append(item)
        if not registered:
            raise RuntimeError('Product StatusNotifier item is not registered in the desktop host')
        watcher_pid = call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetConnectionUnixProcessID', '(s)', (watcher,))[0]
        panel_pid = int(sys.argv[2])
        if Path(f'/proc/{panel_pid}/comm').read_text().strip() != 'xfce4-panel':
            raise RuntimeError('Unexpected native tray panel process')
        ancestry = []
        current = watcher_pid
        while current > 1 and current not in ancestry:
            ancestry.append(current)
            if current == panel_pid:
                break
            fields = dict(line.split(':', 1) for line in Path(f'/proc/{current}/status').read_text().splitlines() if ':' in line)
            current = int(fields['PPid'].strip())
        if panel_pid not in ancestry:
            raise RuntimeError('StatusNotifier watcher is not owned by the disposable panel')
        icon = call(name, '/StatusNotifierItem', 'org.freedesktop.DBus.Properties', 'GetAll', '(s)', ('org.kde.StatusNotifierItem',))[0]
        if icon.get('Status') != 'Active':
            raise RuntimeError('Product native tray icon is not active')
        menu = call(name, '/StatusNotifierItem', 'org.freedesktop.DBus.Properties', 'Get', '(ss)', ('org.kde.StatusNotifierItem', 'Menu'))[0]
        revision, layout = call(name, menu, 'com.canonical.dbusmenu', 'GetLayout', '(iias)', (0, -1, []))
        def find(item):
            identity, properties, children = item
            label = properties.get('label', '').replace('_', '').replace('&', '')
            if label.startswith('Show') and properties.get('enabled', True):
                return identity, label
            for child in children:
                found = find(child)
                if found:
                    return found
        found = find(layout)
        if found is None:
            raise RuntimeError('Published tray has no Show menu item')
        call(name, menu, 'com.canonical.dbusmenu', 'Event', '(isvu)', (found[0], 'clicked', GLib.Variant('i', 0), 0))
        print(json.dumps({'scope': 'native Xfce StatusNotifier host and DBusMenu Show activation; screenshot awaits image review', 'ownerPid': owner, 'busName': name, 'menu': menu, 'item': found, 'watcherPid': watcher_pid, 'panelAncestry': ancestry, 'registeredItems': registered, 'title': title, 'iconName': icon.get('IconName'), 'status': icon.get('Status')}))
        break
    except GLib.Error:
        continue
else:
    raise RuntimeError('No product-owned native StatusNotifierItem')
'''
        result = json.loads(run(['/usr/bin/python3', '-c', source, str(pid), panel_pid]).stdout)
        result['panelWindows'] = [{'id': window, 'geometry': run(['xdotool', 'getwindowgeometry', '--shell', window]).stdout} for window in panels]
        return result
    if PLATFORM == 'macos':
        source = f'''tell application "System Events"
set targetProcess to first application process whose unix id is {pid}
repeat with bar in menu bars of targetProcess
repeat with item in menu bar items of bar
set labelText to ""
try
set labelText to labelText & (name of item as text)
end try
try
set labelText to labelText & (description of item as text)
end try
try
set labelText to labelText & (help of item as text)
end try
if labelText contains "FlClash-Meow" then
perform action "AXPress" of item
return labelText
end if
end repeat
end repeat
error "No product-owned accessible status item"
end tell'''
        return {'scope': 'native accessible product status item activation', 'ownerPid': pid,
                'item': run(['osascript', '-e', source]).stdout.strip()}
    source = WINDOWS_UIA_SETUP + '''
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TrayInput {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr info);
}
'@
$rootElement = [System.Windows.Automation.AutomationElement]::RootElement
$scope = [System.Windows.Automation.TreeScope]::Descendants
$button = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Button)
function Find-ProductTray {
  foreach ($item in $rootElement.FindAll($scope,$button)) {
    if ($item.Current.Name -eq 'FlClash-Meow' -and -not $item.Current.IsOffscreen) { return $item }
  }
  return $null
}
$trayItem = Find-ProductTray
if ($null -eq $trayItem) {
  foreach ($item in $rootElement.FindAll($scope,$button)) {
    if ($item.Current.Name -in @('Notification Chevron','Show hidden icons','Hidden icons menu') -and -not $item.Current.IsOffscreen) {
      $invoke = $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $invoke.Invoke()
      Start-Sleep -Milliseconds 500
      break
    }
  }
  $trayItem = Find-ProductTray
}
if ($null -eq $trayItem) { throw 'No accessible product notification-area icon' }
$point = $trayItem.GetClickablePoint()
if (-not [TrayInput]::SetCursorPos([int]$point.X,[int]$point.Y)) { throw 'Cannot position pointer on tray icon' }
[TrayInput]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
[TrayInput]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
@{scope='native notification-area pointer activation';name=$trayItem.Current.Name;ownerPid=$trayItem.Current.ProcessId;x=$point.X;y=$point.Y;providerAssembly=$providerAssembly.FullName} | ConvertTo-Json -Compress
'''
    try:
        return json.loads(powershell(source))
    except Exception as error:
        try:
            error.tray_inventory = windows_tray_inventory(pid)
        except Exception as inventory_error:
            error.tray_inventory = failure_details(inventory_error)
        raise


def screenshot(path):
    if PLATFORM == 'linux':
        run(['scrot', str(path)])
    elif PLATFORM == 'macos':
        run(['screencapture', '-x', str(path)])
    else:
        os.environ['MEOW_PACKAGE_SCREENSHOT'] = str(path.resolve())
        powershell('''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$image = New-Object System.Drawing.Bitmap $bounds.Width,$bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($image)
$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bounds.Size)
$image.Save($env:MEOW_PACKAGE_SCREENSHOT,[System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $image.Dispose()
''')


def linux_watcher_items():
    source = '''import json
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
result = bus.call_sync('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.freedesktop.DBus.Properties', 'Get', GLib.Variant('(ss)', ('org.kde.StatusNotifierWatcher', 'RegisteredStatusNotifierItems')), None, Gio.DBusCallFlags.NONE, 3000, None)
print(json.dumps(result.unpack()[0]))
'''
    return json.loads(run(['/usr/bin/python3', '-c', source]).stdout)


def main():
    require_runner()
    parser = argparse.ArgumentParser(description='Install and cold-start actual desktop packages on disposable native CI.')
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--arch', choices=['amd64', 'arm64'], required=True)
    parser.add_argument('--source-client', required=True)
    parser.add_argument('--source-core', required=True)
    parser.add_argument('--build-run-id', type=int)
    parser.add_argument('--log', type=Path, required=True)
    options = parser.parse_args()
    machine = platform.machine().lower()
    native = 'arm64' if machine in ('arm64', 'aarch64') else 'amd64' if machine in ('amd64', 'x86_64') else None
    if native != options.arch:
        raise RuntimeError('Package acceptance must run on the artifact architecture natively.')
    source_client = run(['git', 'rev-parse', '--verify', f'{options.source_client}^{{commit}}']).stdout.strip()
    source_core = run(['git', 'rev-parse', f'{source_client}:core/meow-rs']).stdout.strip()
    if source_core != options.source_core:
        raise RuntimeError('Supplied source client and pinned core commits disagree.')
    if product_processes():
        raise RuntimeError('Refusing a runner with existing product processes.')
    installation = Installation(options.dist.resolve(), options.arch)
    options.log.parent.mkdir(parents=True, exist_ok=True)
    with options.log.open('w', encoding='utf-8') as log:
        def record(phase, **fields):
            value = {'phase': phase, 'platform': PLATFORM, 'arch': options.arch, **fields}
            log.write(json.dumps(value) + '\n')
            log.flush()
            print(json.dumps(value), flush=True)

        record('source', buildClientCommit=source_client, coreCommit=options.source_core,
               harnessCommit=run(['git', 'rev-parse', 'HEAD']).stdout.strip(), runId=os.environ['GITHUB_RUN_ID'],
               buildRunId=options.build_run_id or os.environ['GITHUB_RUN_ID'],
               artifact=str(installation.artifact), artifactSha256=digest(installation.artifact))
        original = OriginalProductFixture()
        client = None
        try:
            original.install()
            previous = registrations()
            original_service = old_service_registration()
            record('before-install', registrations=previous, processes=product_processes(), services=service_registration(), originalProduct=original.verify())
            service = service_registration()
            if (PLATFORM == 'windows' and 'FlClashMeowHelperService' in service) or (PLATFORM == 'linux' and 'LoadState=not-found' not in service):
                raise RuntimeError('Refusing a pre-existing product Helper registration.')
            installation.install()
            payload = inspect_payload(installation.root, PLATFORM)
            executables = [installation.client, installation.root / f'FlClashMeowCore{SUFFIX}']
            if PLATFORM != 'macos':
                executables.append(installation.root / f'FlClashMeowHelperService{SUFFIX}')
            expected_arch = ('x86_64' if options.arch == 'amd64' else 'arm64') if PLATFORM == 'macos' else options.arch
            for executable in executables:
                if native_arch(executable, PLATFORM) != [expected_arch]:
                    raise RuntimeError(f'Packaged architecture mismatch: {executable}.')
            version = run([str(executables[1]), '--version']).stdout.strip()
            if options.source_core not in version or 'flclash-meow-host' not in version or 'meow-rs' not in version:
                raise RuntimeError(f'Installed host has wrong source/version: {version}.')
            record('installed-payload', **payload, version=version,
                   registrations=registrations(), clientSha256=digest(installation.client), updateIdentity=embedded_update_identity(installation.root))
            record('installed-core-controller', **core_controller_e2e(installation.root, options.log.parent))
            if PLATFORM != 'macos':
                record('packaged-helper-integrity', **helper_probe(installation.root, payload['coreSha256']))
            for index, auto_launch in enumerate((True, False, True)):
                data_home = seed_settings(installation.client, auto_launch)
                with (options.log.parent / f'cold-start-{index}.log').open('w') as output:
                    client = subprocess.Popen([str(installation.client)], stdout=output, stderr=subprocess.STDOUT)
                    windows = wait_for(lambda: visible_windows(client.pid), 'actual packaged UI window')
                    wait_for(lambda: len(owned_cores(installation.root)) == 1, 'one installed-package Rust host cold start')
                    def converged():
                        value = registrations()
                        return value if auto_enabled(value, installation.client) == auto_launch else None
                    registration = wait_for(converged, 'product autostart convergence')
                    require_scheme(registration, installation.client)
                    record('cold-start', autoLaunch=auto_launch, dataHome=str(data_home), windows=windows,
                           processes=product_processes(), registrations=registration)
                    screenshot(options.log.parent / f'cold-start-{index}.png')
                    shortcut('F11')
                    wait_for(lambda: not visible_windows(client.pid), 'global shortcut hiding the packaged UI')
                    scheme_open()
                    wait_for(lambda: visible_windows(client.pid), 'installed URL handler restoring the packaged UI')
                    wait_for(lambda: len(owned_cores(installation.root)) == 1, 'single host after URL activation')
                    record('scheme-activation', processes=product_processes(), windows=visible_windows(client.pid))
                    shortcut('F11')
                    wait_for(lambda: not visible_windows(client.pid), 'global shortcut hiding the packaged UI')
                    tray = activate_tray(client.pid)
                    wait_for(lambda: visible_windows(client.pid), 'native tray restoring the packaged UI')
                    wait_for(lambda: len(owned_cores(installation.root)) == 1, 'single host after tray activation')
                    record('tray-activation', **tray, windows=visible_windows(client.pid), processes=product_processes())
                    screenshot(options.log.parent / f'tray-activation-{index}.png')
                    shortcut('F11')
                    wait_for(lambda: not visible_windows(client.pid), 'global shortcut hiding the packaged UI')
                    shortcut('F11')
                    wait_for(lambda: visible_windows(client.pid), 'global shortcut restoring the packaged UI')
                    shortcut('F12')
                    client.wait(timeout=75)
                    if client.returncode != 0:
                        raise RuntimeError(f'Packaged application did not exit normally: {client.returncode}.')
                    client = None
                    wait_for(lambda: not product_processes(), 'terminal application/Core process cleanup')
                    record('normal-exit', autoLaunch=auto_launch, processes=product_processes())
                    if PLATFORM == 'linux':
                        wait_for(lambda: not set(tray['registeredItems']).intersection(linux_watcher_items()), 'native tray removing the exited application icon')
                        record('tray-unregistered', remainingItems=linux_watcher_items(), imageReview='pending native screenshot review')
                        screenshot(options.log.parent / f'tray-after-exit-{index}.png')
            installation.uninstall()
            record('after-uninstall', registrations=registrations(), processes=product_processes(), services=service_registration(), originalProduct=original.verify())
            if product_processes() or installation.client.exists():
                raise RuntimeError('Uninstall left product processes or executable files.')
            service = service_registration()
            if (PLATFORM == 'windows' and 'FlClashMeowHelperService' in service) or (PLATFORM == 'linux' and 'LoadState=not-found' not in service):
                raise RuntimeError('Uninstall left the product Helper service registered.')
            if original_service != old_service_registration():
                raise RuntimeError('Installation/uninstallation changed the original-product Helper service.')
            after = registrations()
            for key in ('oldScheme', 'oldAutostart', 'oldPatchedAutostart'):
                if previous.get(key) != after.get(key):
                    raise RuntimeError(f'Installation/uninstallation changed old-product {key}.')
            if PLATFORM != 'macos' and (after.get('scheme') or after.get('handler') or after.get('autostart')):
                raise RuntimeError('Uninstall left product URL/autostart registration pointing to removed files.')
            if PLATFORM == 'macos' and after['autostartEnabled']:
                raise RuntimeError('Removing the macOS application left an enabled product background item.')
            record('passed', originalProduct=original.verify(),
                   unverified=['release updater network/download behavior', 'TUN acceptance is a separate native suite', *(['Linux rendered tray screenshots await image review'] if PLATFORM == 'linux' else [])])
        except Exception as error:
            record('failed', **failure_details(error), processes=product_processes())
            raise
        finally:
            if client is not None and client.poll() is None:
                client.terminate()
                try:
                    client.wait(timeout=75)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=10)
            installation.uninstall()
            installation.detach()
            original.remove()
    return 0


if __name__ == '__main__':
    sys.exit(main())
