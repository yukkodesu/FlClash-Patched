import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name('desktop_package_acceptance.py')


class PackageAcceptanceContract(unittest.TestCase):
    @unittest.skipUnless(os.name == 'nt', 'Windows framework assembly registration')
    def test_windows_accessibility_provider_registers_in_a_powershell_child(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source = module.WINDOWS_UIA_SETUP + "@{client=[System.Windows.Automation.AutomationElement].Assembly.FullName;provider=$providerAssembly.FullName} | ConvertTo-Json -Compress"
        result = module.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', source], timeout=20)
        metadata = json.loads(result.stdout)
        self.assertEqual(metadata['client'].split(',')[1:], metadata['provider'].split(',')[1:])
        self.assertTrue(metadata['provider'].startswith('UIAutomationClientsideProviders,'))

    def test_packaged_update_identity_reads_each_platform_aot_snapshot(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            for target, relative in (('windows', 'data/app.so'), ('linux', 'lib/libapp.so'), ('macos', '../Frameworks/App.framework/App')):
                with self.subTest(platform=target), mock.patch.object(module, 'PLATFORM', target):
                    root = base / target / 'client'
                    snapshot = root / relative
                    snapshot.parent.mkdir(parents=True)
                    snapshot.write_bytes(b'fixture AOT yukkodesu/FlClash-Patched')
                    identity = module.embedded_update_identity(root)
                    self.assertEqual(identity['repository'], 'yukkodesu/FlClash-Patched')
                    self.assertEqual(identity['snapshotSha256'], module.digest(snapshot))
                    snapshot.write_bytes(b'fixture AOT original/FlClash')
                    with self.assertRaisesRegex(RuntimeError, 'independent product update repository identity'):
                        module.embedded_update_identity(root)

    def test_installed_debian_payload_selects_file_inside_same_named_directory(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'product.deb').write_bytes(b'fixture package')
            installed = root / 'FlClashMeow'
            installed.mkdir()
            client = installed / 'FlClashMeow'
            client.write_bytes(b'ordinary client')
            responses = [subprocess.CompletedProcess([], 0, value, '') for value in (
                'flclash-meow', 'amd64', 'not-installed', '', f'{installed}\n{client}\n',
            )]
            with mock.patch.object(module, 'PLATFORM', 'linux'), mock.patch.object(module, 'run', side_effect=responses):
                installation = module.Installation(root, 'amd64')
                installation.install()
            self.assertEqual(installation.client, client)
            self.assertEqual(installation.root, installed)

    def test_installed_debian_payload_still_rejects_multiple_client_files(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'product.deb').write_bytes(b'fixture package')
            files = []
            for name in ('first', 'second'):
                directory = root / name
                directory.mkdir()
                client = directory / 'FlClashMeow'
                client.write_bytes(b'ordinary client')
                files.append(str(client))
            responses = [subprocess.CompletedProcess([], 0, value, '') for value in (
                'flclash-meow', 'amd64', 'not-installed', '', '\n'.join(files),
            )]
            with mock.patch.object(module, 'PLATFORM', 'linux'), mock.patch.object(module, 'run', side_effect=responses):
                installation = module.Installation(root, 'amd64')
                with self.assertRaisesRegex(RuntimeError, 'Unexpected packaged client executables'):
                    installation.install()

    def test_failed_child_retains_stdout_stderr_and_exit_code(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            module.run([sys.executable, '-c', "import sys; print('child stdout'); print('child stderr', file=sys.stderr); sys.exit(7)"])
        details = module.failure_details(raised.exception)
        self.assertEqual(details['returnCode'], 7)
        self.assertIn('child stdout', details['stdout'])
        self.assertIn('child stderr', details['stderr'])

    def test_timed_out_child_retains_partial_output(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with self.assertRaises(subprocess.TimeoutExpired) as raised:
            module.run([sys.executable, '-c', "import sys, time; print('before timeout', flush=True); time.sleep(10)"], timeout=1)
        details = module.failure_details(raised.exception)
        self.assertEqual(details['timeoutSeconds'], 1)
        self.assertIn('before timeout', details['stdout'])
        json.dumps(details)

    def test_tray_failure_keeps_original_error_and_bounded_read_only_inventory(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        failure = subprocess.CalledProcessError(1, ['powershell'], output='activation output', stderr='actual UIA error')
        inventory = {'clientPid': 123, 'items': [{'name': 'Notification Chevron', 'class': 'TrayButton'}]}
        with mock.patch.object(module, 'PLATFORM', 'windows'), mock.patch.object(module, 'run', side_effect=[failure, subprocess.CompletedProcess([], 0, json.dumps(inventory), '')]) as runner:
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                module.activate_tray(123)
        self.assertIs(raised.exception, failure)
        details = module.failure_details(failure)
        self.assertEqual(details['stderr'], 'actual UIA error')
        self.assertEqual(details['trayInventory'], inventory)
        command = runner.call_args_list[1]
        self.assertEqual(command.kwargs['timeout'], 20)
        script = command.args[0][-1]
        self.assertIn('Shell_TrayWnd', script)
        self.assertIn('NotifyIconOverflowWindow', script)
        self.assertIn('256', script)
        self.assertNotIn('Invoke()', script)
        self.assertNotIn('mouse_event', script)

    def test_tray_inventory_timeout_does_not_replace_activation_failure(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        failure = subprocess.CalledProcessError(1, ['powershell'], stderr='activation failed')
        timeout = subprocess.TimeoutExpired(['powershell'], 20, output=b'partial inventory')
        with mock.patch.object(module, 'PLATFORM', 'windows'), mock.patch.object(module, 'run', side_effect=[failure, timeout]):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                module.activate_tray(123)
        self.assertIs(raised.exception, failure)
        details = module.failure_details(failure)
        self.assertEqual(details['trayInventory']['timeoutSeconds'], 20)
        self.assertEqual(details['trayInventory']['stdout'], 'partial inventory')

    def test_package_digest_accepts_standard_vectors_without_python311_helper(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cases = [
            (b'', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'),
            (b'hello', '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'),
            (b'a' * 1_000_000, 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0'),
        ]
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(module.hashlib.__dict__):
            module.hashlib.__dict__.pop('file_digest', None)
            path = Path(temporary) / 'artifact'
            for payload, expected in cases:
                with self.subTest(size=len(payload)):
                    path.write_bytes(payload)
                    self.assertEqual(module.digest(path), expected)

    def test_workstation_cli_refuses_before_creating_evidence_or_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'evidence.jsonl'
            environment = dict(os.environ)
            environment.pop('GITHUB_ACTIONS', None)
            environment.pop('RUNNER_ENVIRONMENT', None)
            output = subprocess.run(
                [sys.executable, str(SCRIPT), '--dist', temporary, '--arch', 'amd64', '--log', str(log)],
                env=environment, text=True, capture_output=True,
            )
            self.assertNotEqual(output.returncode, 0)
            self.assertIn('disposable GitHub-hosted', output.stderr)
            self.assertFalse(log.exists())

    def test_packaged_core_manifest_and_helper_must_match_staged_production_bytes(self):
        spec = importlib.util.spec_from_file_location('package_acceptance', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            installed = root / 'installed'
            staged = root / 'staged'
            installed.mkdir()
            staged.mkdir()
            for directory in (installed, staged):
                (directory / 'FlClashMeowCore.exe').write_bytes(b'hello')
                (directory / 'FlClashMeowHelperService.exe').write_bytes(b'helper')
                (directory / 'manifest.json').write_text(json.dumps({
                    'coreSha256': '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
                }))
            record = module.inspect_payload(installed, 'windows', staged)
            self.assertEqual(record['coreSha256'], '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824')
            (installed / 'FlClashMeowHelperService.exe').write_bytes(b'old helper')
            with self.assertRaisesRegex(RuntimeError, 'Helper'):
                module.inspect_payload(installed, 'windows', staged)
            (installed / 'FlClashMeowHelperService.exe').write_bytes(b'helper')
            (installed / 'manifest.json').write_text('{"coreSha256":"old"}')
            with self.assertRaisesRegex(RuntimeError, 'manifest'):
                module.inspect_payload(installed, 'windows', staged)
            (installed / 'manifest.json').write_text((staged / 'manifest.json').read_text())
            (installed / 'mihomo.exe').write_bytes(b'legacy core')
            with self.assertRaisesRegex(RuntimeError, 'legacy'):
                module.inspect_payload(installed, 'windows', staged)


if __name__ == '__main__':
    unittest.main()
