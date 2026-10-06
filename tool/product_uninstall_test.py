import os
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def linux_cleanup(format_name):
    text = (ROOT / f'linux/packaging/{format_name}/make_config.yaml').read_text()
    marker = '  - |\n'
    block = text.split(marker, 1)[1].split('\n\n', 1)[0]
    return '\n'.join(line[6:] for line in block.splitlines()) + '\n'


class ProductUninstall(unittest.TestCase):
    @unittest.skipUnless(os.name == 'nt', 'Uses Windows PowerShell with only fixture task commands.')
    def test_inno_scheduled_task_cleanup_only_unregisters_the_installed_action(self):
        template = (ROOT / 'windows/packaging/exe/inno_setup.iss').read_text()
        constant = template.split('TaskCleanupScript =', 1)[1].split('\n\n', 1)[0]
        lines = re.findall(r"'((?:[^']|'')*)'", constant)
        payload = '\n'.join(line.replace("''", "'") for line in lines)
        executable = r'C:\Program Files\FlClash-Meow\FlClashMeow.exe'
        for action, arguments, action_count, should_remove in (
            (executable, '', 1, True),
            (r'C:\custom\FlClashMeow.exe', '', 1, False),
            (executable, '--foreign-writer', 1, False),
            (executable, '', 2, False),
        ):
            with self.subTest(action=action, arguments=arguments), tempfile.TemporaryDirectory() as temporary:
                fixture = Path(temporary) / 'tasks.ps1'
                task = json.dumps({'Actions': [{'Execute': action, 'Arguments': arguments}] * action_count})
                fixture.write_text('''
function Import-Module { param($Name, [switch]$Force) }
function Get-ScheduledTask {
  param($TaskPath, $TaskName, $ErrorAction)
  if ($TaskPath -ne '\\' -or $TaskName -ne 'FlClash-Meow') { throw 'Foreign task query' }
  return ConvertFrom-Json '%s'
}
function Unregister-ScheduledTask {
  param($TaskPath, $TaskName, $Confirm)
  if ($TaskPath -ne '\\' -or $TaskName -ne 'FlClash-Meow') { throw 'Foreign task deletion' }
  Write-Output 'owned task removed'
}
& {
%s
} -Executable '%s'
''' % (task.replace("'", "''"), payload, executable), encoding='utf-8')
                output = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-File', str(fixture)], text=True, capture_output=True)
                self.assertEqual(output.returncode, 0, output.stderr)
                self.assertEqual('owned task removed' in output.stdout, should_remove)

    @unittest.skipUnless(os.name == 'posix', 'Runs the actual postrm shell in temporary homes.')
    def test_linux_uninstall_removes_owned_registration_and_preserves_foreign_entries(self):
        for package in ('deb', 'pacman'):
            with self.subTest(package=package), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                home = root / 'home'
                autostart = home / '.config/autostart'
                applications = home / '.local/share/applications'
                autostart.mkdir(parents=True)
                applications.mkdir(parents=True)
                startup = autostart / 'FlClash-Meow.desktop'
                handler = applications / 'flclash-meow-url-handler.desktop'
                original = autostart / 'FlClash.desktop'
                original.write_text('Exec=/opt/FlClash/FlClash\n')
                mime = home / '.config/mimeapps.list'
                mime.write_text('[Default Applications]\nx-scheme-handler/flclash-meow=flclash-meow-url-handler.desktop;foreign.desktop;\nx-scheme-handler/clash=FlClash.desktop;\n')
                desktop_mime = home / '.config/gnome-mimeapps.list'
                desktop_mime.write_text('[Default Applications]\nx-scheme-handler/flclash-meow=flclash-meow-url-handler.desktop;\n')
                startup.write_text('Exec=/usr/share/FlClashMeow/FlClashMeow\n')
                handler.write_text('Exec="/usr/share/FlClashMeow/FlClashMeow" %u\n')
                commands = root / 'bin'
                commands.mkdir()
                for name, source in {
                    'getent': f'#!/bin/sh\nprintf "fixture:x:1000:1000::%s:/bin/sh\\n" "{home}"\n',
                    'runuser': '#!/bin/sh\nshift 3\nexec "$@"\n',
                }.items():
                    command = commands / name
                    command.write_text(source)
                    command.chmod(0o755)
                env = dict(os.environ, PATH=f'{commands}:{os.environ["PATH"]}')
                subprocess.run(['sh', '-c', linux_cleanup(package)], env=env, check=True)
                self.assertFalse(startup.exists())
                self.assertFalse(handler.exists())
                self.assertEqual(mime.read_text(), '[Default Applications]\nx-scheme-handler/flclash-meow=foreign.desktop;\nx-scheme-handler/clash=FlClash.desktop;\n')
                self.assertEqual(desktop_mime.read_text(), '[Default Applications]\n')
                self.assertEqual(original.read_text(), 'Exec=/opt/FlClash/FlClash\n')
                startup.write_text('Exec=/custom/FlClashMeow\n')
                handler.write_text('Exec="/custom/FlClashMeow" %u\n')
                before = mime.read_bytes()
                subprocess.run(['sh', '-c', linux_cleanup(package)], env=env, check=True)
                self.assertEqual(startup.read_text(), 'Exec=/custom/FlClashMeow\n')
                self.assertEqual(handler.read_text(), 'Exec="/custom/FlClashMeow" %u\n')
                self.assertEqual(mime.read_bytes(), before)
                startup.unlink()
                outside = root / 'outside.desktop'
                outside.write_text('Exec=/usr/share/FlClashMeow/FlClashMeow\n')
                startup.symlink_to(outside)
                handler.unlink()
                outside_handler = root / 'outside-handler.desktop'
                outside_handler.write_text('Exec="/usr/share/FlClashMeow/FlClashMeow" %u\n')
                handler.symlink_to(outside_handler)
                subprocess.run(['sh', '-c', linux_cleanup(package)], env=env, check=True)
                self.assertTrue(startup.is_symlink())
                self.assertTrue(handler.is_symlink())
                self.assertEqual(outside.read_text(), 'Exec=/usr/share/FlClashMeow/FlClashMeow\n')
                self.assertEqual(outside_handler.read_text(), 'Exec="/usr/share/FlClashMeow/FlClashMeow" %u\n')
                self.assertEqual(mime.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
