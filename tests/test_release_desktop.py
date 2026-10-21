"""Exercise desktop integration across install, rollback and uninstall."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def desktop_value(value):
    """Decode the Desktop Entry string layer before parsing Exec quoting."""
    escapes = {'s': ' ', 'n': '\n', 'r': '\r', 't': '\t', '\\': '\\'}
    result = ''
    chars = iter(value)
    for char in chars:
        result += escapes[next(chars)] if char == '\\' else char
    return result


class DesktopInstallation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='letty-desktop-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / 'home with spaces'
        self.home.mkdir()
        self.package = self.base / 'package'
        (self.package / 'tools').mkdir(parents=True)
        (self.package / 'bin').mkdir()
        for name in ('install-user.sh', 'rollback-user.sh', 'uninstall-user.sh'):
            shutil.copy2(ROOT / 'tools' / name, self.package / 'tools' / name)
        icon = self.package / 'share/icons/hicolor/256x256/apps/letty.png'
        icon.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'assets/icons/hicolor/256x256/apps/letty.png', icon)
        self.env = dict(os.environ, HOME=str(self.home), XDG_DATA_HOME=str(self.home / 'xdg data'))
        # These scripts target Linux/GNU mv. On macOS only, model mv -fT with
        # rename so the installation lifecycle can still run in isolated fixtures.
        if sys.platform == 'darwin':
            helpers = self.base / 'helpers'
            helpers.mkdir()
            mv = helpers / 'mv'
            mv.write_text('#!/usr/bin/env python3\nimport os, sys\n'
                          'assert sys.argv[1] == "-fT"\nos.replace(sys.argv[2], sys.argv[3])\n')
            mv.chmod(0o755)
            self.env['PATH'] = str(helpers) + ':' + self.env['PATH']
        self.prefix = self.home / '.local/share/letty'
        self.desktop = Path(self.env['XDG_DATA_HOME']) / 'applications/letty.desktop'
        self.version('1.0.0')

    def version(self, name):
        (self.package / 'build-info.json').write_text(json.dumps({'package_id': name}))
        binary = self.package / 'bin/letty'
        binary.write_text('#!/bin/sh\nprintf "%s\\n" "' + name + '"\n')
        binary.chmod(0o755)

    def run_script(self, name, *args, success=True):
        result = subprocess.run(['bash', str(self.package / 'tools' / name), *map(str, args)],
                                cwd=self.home, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def entry(self):
        return dict(line.split('=', 1) for line in self.desktop.read_text().splitlines() if '=' in line)

    def test_menu_follows_upgrade_rollback_and_uninstall(self):
        self.run_script('install-user.sh')
        self.assertEqual(os.readlink(self.desktop), str(self.prefix / 'letty.desktop'))
        fields = self.entry()
        self.assertEqual(fields['StartupWMClass'], 'Letty')
        self.assertTrue(Path(desktop_value(fields['Icon'])).is_file())
        command = shlex.split(desktop_value(fields['Exec']))
        self.assertEqual(command, [str(self.prefix / 'current/bin/letty')])
        self.assertEqual(subprocess.check_output(command, text=True).strip(), '1.0.0')
        self.version('2.0.0')
        self.run_script('install-user.sh')
        self.assertEqual(subprocess.check_output(command, text=True).strip(), '2.0.0')
        self.run_script('rollback-user.sh')
        self.assertEqual(subprocess.check_output(command, text=True).strip(), '1.0.0')
        self.run_script('uninstall-user.sh')
        self.assertFalse(self.desktop.is_symlink())
        self.assertFalse(self.prefix.exists())

    def test_custom_prefix_desktop_escaping(self):
        prefix = self.home / 'custom "quote" \\ dollar$ backtick` percent% directory'
        self.run_script('install-user.sh', prefix)
        fields = self.entry()
        # shlex preserves dollar/backtick escapes; desktop Exec removes them.
        executable = shlex.split(desktop_value(fields['Exec']))[0]
        executable = executable.replace('\\$', '$').replace('\\`', '`').replace('%%', '%')
        self.assertEqual(executable, str(prefix / 'current/bin/letty'))
        self.assertEqual(subprocess.check_output([executable], text=True).strip(), '1.0.0')
        self.assertTrue(Path(desktop_value(fields['Icon'])).is_file())
        self.run_script('uninstall-user.sh', prefix)
        self.assertFalse(self.desktop.is_symlink())

    def test_existing_desktop_file_is_preserved(self):
        self.desktop.parent.mkdir(parents=True)
        self.desktop.write_text('keep me')
        self.run_script('install-user.sh', success=False)
        self.assertEqual(self.desktop.read_text(), 'keep me')
        self.assertFalse(self.prefix.exists())

    def test_uninstall_keeps_other_installation_menu(self):
        self.run_script('install-user.sh')
        self.desktop.unlink()
        self.desktop.symlink_to('/another/installation/letty.desktop')
        self.run_script('uninstall-user.sh')
        self.assertEqual(os.readlink(self.desktop), '/another/installation/letty.desktop')

    def test_relative_xdg_path_uses_default(self):
        self.env['XDG_DATA_HOME'] = 'relative'
        self.desktop = self.home / '.local/share/applications/letty.desktop'
        self.run_script('install-user.sh')
        self.assertTrue(self.desktop.is_symlink())
        self.run_script('uninstall-user.sh')
        self.assertFalse(self.desktop.is_symlink())


if __name__ == '__main__':
    unittest.main()
