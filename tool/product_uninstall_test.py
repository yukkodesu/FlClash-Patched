import os
from pathlib import Path
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

    def test_inno_uninstall_has_path_guarded_current_user_registration_cleanup(self):
        template = (ROOT / 'windows/packaging/exe/inno_setup.iss').read_text()
        cleanup = template.split('procedure UnregisterProduct;', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn("RegQueryStringValue(HKCU, ProtocolKey + '\\shell\\open\\command', '', Command)", cleanup)
        self.assertIn("CompareText(Command, '\"' + Executable + '\" \"%1\"') = 0", cleanup)
        self.assertIn('RegDeleteKeyIncludingSubkeys(HKCU, ProtocolKey)', cleanup)
        self.assertIn("RegQueryStringValue(HKCU, RunKey, 'FlClash-Meow', Command)", cleanup)
        self.assertIn('CompareText(Command, Executable) = 0', cleanup)
        self.assertIn("RegDeleteValue(HKCU, RunKey, 'FlClash-Meow')", cleanup)
        uninstall = template.split('function InitializeUninstall(): Boolean;', 1)[1].split('[Languages]', 1)[0]
        self.assertIn('UnregisterProduct;', uninstall)


if __name__ == '__main__':
    unittest.main()
