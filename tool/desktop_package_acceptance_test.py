import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('desktop_package_acceptance.py')


class PackageAcceptanceContract(unittest.TestCase):
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
