"""Exercise destructive uninstall boundaries using isolated user directories."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'tools/uninstall-user.sh'


class UserUninstall(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='letty-uninstall-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve() / 'home with spaces'
        self.prefix = self.home / '.local/share/letty'
        self.launcher = self.home / '.local/bin/letty'
        self.launcher.parent.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home), XDG_DATA_HOME=str(self.home / '.local/share'))

    def install(self, prefix=None):
        prefix = prefix or self.prefix
        for name in ('1.0.0', '2.0.0'):
            version = prefix / 'versions' / name
            (version / 'bin').mkdir(parents=True)
            (version / 'bin/letty').write_text('application fixture')
            (version / 'build-info.json').write_text(json.dumps({'package_id': name}))
            (version / 'tools').mkdir()
            shutil.copy2(SCRIPT, version / 'tools/uninstall-user.sh')
        (prefix / 'current').symlink_to('versions/2.0.0')
        (prefix / 'previous').symlink_to('versions/1.0.0')
        self.launcher.symlink_to(prefix / 'current/bin/letty')

    def run_script(self, *args, script=SCRIPT, success=True):
        result = subprocess.run(['bash', str(script), *map(str, args)],
                                env=self.env, cwd=self.home,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_installed_script_removes_all_versions_but_preserves_user_data(self):
        self.install()
        config = self.home / '.config/letty'
        config.mkdir(parents=True)
        for name in ('config', 'layout.json'):
            (config / name).write_text('keep me')
        self.run_script(script=self.prefix / 'current/tools/uninstall-user.sh')
        self.assertFalse(self.prefix.exists())
        self.assertFalse(self.launcher.is_symlink())
        for name in ('config', 'layout.json'):
            self.assertEqual((config / name).read_text(), 'keep me')
        self.run_script()  # A repeated uninstall is harmless.

    def test_other_root_files_and_unrelated_launcher_are_preserved(self):
        self.install()
        (self.prefix / 'notes').write_text('keep me')
        self.launcher.unlink()
        self.launcher.symlink_to('/unrelated/missing/letty')
        self.run_script()
        self.assertEqual((self.prefix / 'notes').read_text(), 'keep me')
        self.assertEqual(os.readlink(self.launcher), '/unrelated/missing/letty')
        self.assertFalse((self.prefix / 'versions').exists())

    def test_relative_custom_and_legacy_prefixes(self):
        for relative in ('custom directory', '.local/opt/letty'):
            with self.subTest(relative=relative):
                prefix = self.home / relative
                self.install(prefix)
                self.run_script(relative)
                self.assertFalse(prefix.exists())
                self.assertFalse(self.launcher.is_symlink())

    def test_unrecognized_version_prevents_any_deletion(self):
        self.install()
        (self.prefix / 'versions/2.0.0/build-info.json').write_text('{"package_id":"wrong"}')
        self.run_script(success=False)
        self.assertTrue(self.launcher.is_symlink())
        self.assertTrue((self.prefix / 'current').is_symlink())
        self.assertTrue((self.prefix / 'versions/1.0.0/bin/letty').exists())

    def test_external_version_symlink_is_not_followed(self):
        self.install()
        outside = self.home / 'outside'
        outside.mkdir()
        (outside / 'important').write_text('keep me')
        (self.prefix / 'versions/3.0.0').symlink_to(outside)
        self.run_script(success=False)
        self.assertEqual((outside / 'important').read_text(), 'keep me')
        self.assertTrue(self.launcher.is_symlink())

    def test_invalid_current_link_prevents_any_deletion(self):
        self.install()
        (self.prefix / 'current').unlink()
        (self.prefix / 'current').symlink_to('versions/..')
        self.run_script(success=False)
        self.assertTrue(self.launcher.is_symlink())
        self.assertTrue((self.prefix / 'versions/1.0.0/bin/letty').exists())

    def test_regular_launcher_is_preserved(self):
        self.install()
        self.launcher.unlink()
        self.launcher.write_text('keep me')
        self.run_script()
        self.assertEqual(self.launcher.read_text(), 'keep me')


if __name__ == '__main__':
    unittest.main()
