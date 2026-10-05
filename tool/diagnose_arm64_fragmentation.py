import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import platform
import subprocess
import time
import uuid

import desktop_package_acceptance as package
from diagnose_arm64_cold_start import CLIENT, CORE, CORE_SHA, INSTALLER_SHA

TAG = '[DEBUG-arm64-readcancel]'


class Overlapped(ctypes.Structure):
    _fields_ = [('internal', ctypes.c_size_t), ('internal_high', ctypes.c_size_t),
                ('offset', wintypes.DWORD), ('offset_high', wintypes.DWORD),
                ('event', wintypes.HANDLE)]


class Pipe:
    def __init__(self, name):
        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        self.api.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                            wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                                            wintypes.DWORD, ctypes.c_void_p]
        self.api.CreateNamedPipeW.restype = wintypes.HANDLE
        self.api.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
        self.api.CreateEventW.restype = wintypes.HANDLE
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.api.GetOverlappedResult.argtypes = [wintypes.HANDLE, ctypes.POINTER(Overlapped),
                                               ctypes.POINTER(wintypes.DWORD), wintypes.BOOL]
        self.api.CancelIoEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(Overlapped)]
        self.api.ConnectNamedPipe.argtypes = [wintypes.HANDLE, ctypes.POINTER(Overlapped)]
        for operation in (self.api.ReadFile, self.api.WriteFile):
            operation.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                  ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(Overlapped)]
        self.handle = self.api.CreateNamedPipeW(name, 3 | 0x40000000, 0, 1, 65536, 65536, 0, None)
        if self.handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())

    def perform(self, operation, buffer=None, size=0):
        event = self.api.CreateEventW(None, True, False, None)
        if not event:
            raise ctypes.WinError(ctypes.get_last_error())
        pending = Overlapped(event=event)
        transferred = wintypes.DWORD()
        try:
            if operation == 'connect':
                result = self.api.ConnectNamedPipe(self.handle, ctypes.byref(pending))
            else:
                result = getattr(self.api, operation)(self.handle, buffer, size,
                                                      ctypes.byref(transferred), ctypes.byref(pending))
            if not result:
                error = ctypes.get_last_error()
                if operation == 'connect' and error == 535:
                    return 0
                if error != 997:
                    raise ctypes.WinError(error)
                if self.api.WaitForSingleObject(event, 3000) != 0:
                    self.api.CancelIoEx(self.handle, ctypes.byref(pending))
                    self.api.GetOverlappedResult(self.handle, ctypes.byref(pending),
                                                 ctypes.byref(transferred), True)
                    raise TimeoutError(f'{operation} did not complete in 3 seconds')
            if not self.api.GetOverlappedResult(self.handle, ctypes.byref(pending),
                                               ctypes.byref(transferred), False):
                raise ctypes.WinError(ctypes.get_last_error())
            return transferred.value
        finally:
            self.api.CloseHandle(event)

    def write(self, data):
        buffer = ctypes.create_string_buffer(data)
        count = self.perform('WriteFile', buffer, len(data))
        if count != len(data):
            raise RuntimeError(f'Probe write was partial: {count}/{len(data)}')

    def read(self, size):
        result = bytearray()
        while len(result) < size:
            buffer = ctypes.create_string_buffer(size - len(result))
            count = self.perform('ReadFile', buffer, len(buffer))
            if count == 0:
                raise EOFError('Host closed IPC')
            result.extend(buffer.raw[:count])
        return bytes(result)

    def response(self, request_id):
        for _ in range(32):
            size = int.from_bytes(self.read(4), 'little')
            if not 0 < size <= 64 * 1024 * 1024:
                raise RuntimeError(f'Host response frame length invalid: {size}')
            response = json.loads(self.read(size))
            if response.get('id') == request_id:
                return response
        raise RuntimeError('Probe received too many unrelated frames')

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def request(identifier):
    payload = json.dumps({'id': identifier, 'method': 'getCoreInfo', 'arguments': None},
                         separators=(',', ':')).encode()
    return len(payload).to_bytes(4, 'little') + payload


def trial(executable, directory, index, fragmented):
    name = r'\\.\pipe\FlClashMeowCore_' + uuid.uuid4().hex
    pipe = Pipe(name)
    mode = 'fragmented' if fragmented else 'uninterrupted'
    log = directory / f'{mode}-{index:03d}.stderr.log'
    first, second = request('first'), request('second')
    result = {'tag': TAG, 'mode': mode, 'trial': index, 'secondHeaderHex': second[:4].hex(),
              'allInputBytesHex': (first + second).hex(), 'firstResponse': None, 'secondResponse': None}
    started = time.monotonic()
    with log.open('w', encoding='utf-8') as stderr:
        child = subprocess.Popen([str(executable), name], stdout=subprocess.DEVNULL, stderr=stderr)
        result['pid'] = child.pid
        try:
            pipe.perform('connect')
            pipe.write(first + (second[:1] if fragmented else second))
            result['firstResponse'] = pipe.response('first')
            time.sleep(0.02)
            if fragmented:
                pipe.write(second[1:])
            result['secondResponse'] = pipe.response('second')
            result['aliveAfterBothResponses'] = child.poll() is None
        except Exception as error:
            result['probeError'] = f'{type(error).__name__}: {error}'
        finally:
            pipe.close()
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
                result['forcedOwnedChildExit'] = True
    text = log.read_text(encoding='utf-8', errors='replace')
    result.update(exitCode=child.returncode, elapsedSeconds=round(time.monotonic() - started, 3),
                  stderr=text[-16384:])
    result['verdict'] = ('RED_EXACT_HOST_FRAME_ERROR' if result['firstResponse'] and
                         'invalid IPC frame size' in text and child.returncode != 0 else
                         'GREEN_BOTH_VALID_RESPONSES' if result['secondResponse'] and
                         not result['firstResponse'].get('error') and
                         not result['secondResponse'].get('error') and
                         result.get('aliveAfterBothResponses') and child.returncode == 0 else
                         'INCONCLUSIVE')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=20)
    args = parser.parse_args()
    package.require_runner()
    if package.PLATFORM != 'windows' or platform.machine().lower() != 'arm64':
        raise RuntimeError('Requires disposable native Windows ARM64 CI.')
    if package.product_processes():
        raise RuntimeError('Refusing existing product processes.')
    if os.environ['BUILD_CLIENT_SHA'] != CLIENT or os.environ['BUILD_RUN_ID'] != '37374536042':
        raise RuntimeError('Rejecting inputs other than frozen B5 producer.')
    installation = package.Installation(args.dist.resolve(), 'arm64')
    if package.digest(installation.artifact) != INSTALLER_SHA:
        raise RuntimeError('Installer differs from failing run.')
    args.log.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with args.log.open('w', encoding='utf-8') as output:
        def record(row):
            encoded = json.dumps(row)
            output.write(encoded + '\n'); output.flush()
            print(encoded, flush=True)
        try:
            installation.install()
            executable = installation.root / 'FlClashMeowCore.exe'
            if package.digest(executable) != CORE_SHA or package.native_arch(executable, 'windows') != ['arm64']:
                raise RuntimeError('Installed Core differs from frozen native ARM64 payload.')
            record(dict(tag=TAG, phase='source', client=CLIENT, core=CORE, coreSha256=CORE_SHA,
                        installerSha256=INSTALLER_SHA, runId=os.environ['GITHUB_RUN_ID']))
            for index in range(args.iterations):
                for fragmented in (False, True):
                    row = trial(executable, args.log.parent, index, fragmented)
                    rows.append(row)
                    record(row)
            record(dict(tag=TAG, phase='summary', iterations=args.iterations,
                        counts={mode: {verdict: sum(r['mode'] == mode and r['verdict'] == verdict for r in rows)
                                       for verdict in ('RED_EXACT_HOST_FRAME_ERROR', 'GREEN_BOTH_VALID_RESPONSES', 'INCONCLUSIVE')}
                                for mode in ('uninterrupted', 'fragmented')}))
        finally:
            installation.uninstall()
    return 1 if any(r['verdict'].startswith('RED_') for r in rows) else 2 if any(r['verdict'] == 'INCONCLUSIVE' for r in rows) else 0


if __name__ == '__main__':
    raise SystemExit(main())
