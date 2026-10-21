"""Exercise the release archive and checksums without a compiler or GitHub."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import font_assets
spec = importlib.util.spec_from_file_location('package', ROOT / 'tools/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class RuntimeArchive(unittest.TestCase):
    def test_tagged_archive_contains_only_runtime_and_valid_checksums(self):
        with tempfile.TemporaryDirectory(prefix='letty-release-') as directory:
            root = Path(directory)
            files = {
                'deps.lock.json': json.dumps({'app_version': '0.2.0', 'sources': {}, 'bundled_font': {}}),
                'docs/runtime-package.md': '# Letty @VERSION@\n',
                'docs/assets/history.png': 'historical screenshot',
                'config/config.example': '# configuration\n',
                'assets/icons/hicolor/256x256/apps/letty.png': 'icon',
                'assets/shell-integration/bash/letty.bash': '# integration',
                'THIRD_PARTY_NOTICES.md': 'notices',
                'vendor/ghostty/LICENSE': 'ghostty license',
                'vendor/nanoui/LICENSE': 'nanoui license',
                '.cache/shaper/linux/build-info.json': '{}',
                '.cache/fonts/Regular.ttf': 'font',
                '.cache/fonts/LICENSE.txt': 'font license',
                'tools/install-user.sh': '#!/bin/bash\n',
                'tools/rollback-user.sh': '#!/bin/bash\n',
                'tools/uninstall-user.sh': '#!/bin/bash\n',
                'tools/test-centos.sh': '#!/bin/bash\n',
                'zig-out/linux/bin/letty': 'application',
                'zig-out/linux/bin/letty-check': 'test binary',
            }
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
                if name.endswith('.sh') or '/bin/' in name:
                    path.chmod(0o755)
            evidence = {'vt_backend': 'zig', 'code_sha256': 'code', 'feature_acceptance': {'full': 'evidence'},
                        'native_release_gate': {'kind': 'linux-ci-release', 'sha256': 'gate'}}

            def command(argv, **kwargs):
                if str(argv[0]) == 'python3':
                    Path(argv[-1]).write_text('{"passed":true}\n')

            env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REF_TYPE': 'tag',
                   'GITHUB_REF_NAME': 'v0.2.0', 'GITHUB_SHA': 'commit',
                   'GITHUB_REPOSITORY': 'BeriBeli/letty', 'GITHUB_RUN_ID': '123'}
            with patch.object(package, 'ROOT', root), \
                    patch.object(package, 'release_evidence', return_value=evidence), \
                    patch.object(package, 'source_files', return_value=[root / 'deps.lock.json']), \
                    patch.object(package, 'feature_batches', return_value={}), \
                    patch.object(package.platform, 'platform', return_value='test-host'), \
                    patch.object(package, 'dependency_notices', return_value=[]), \
                    patch.object(package.shutil, 'which', return_value='/tools/strip'), \
                    patch.object(package.subprocess, 'run', side_effect=command), \
                    patch.object(package.subprocess, 'check_output', return_value='Letty 0.2.0; Zig 0.17.0'), \
                    patch.object(font_assets, 'verify', return_value=list((root / '.cache/fonts').iterdir())), \
                    patch.dict(os.environ, env), \
                    patch.object(sys, 'argv', ['package.py', '--ci', '--version=0.2.0']):
                package.main()
            dist = root / 'dist'
            archives = list(dist.glob('*.tar.gz'))
            self.assertEqual([p.name for p in archives], ['letty-0.2.0-linux-x86_64.tar.gz'])
            archive = archives[0]
            self.assertEqual((dist / 'SHA256SUMS').read_text(),
                             hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
            with tarfile.open(archive) as tar:
                members = {m.name.split('/', 1)[1]: m for m in tar.getmembers() if m.isfile()}
                self.assertEqual({n for n in members if n.startswith('bin/')}, {'bin/letty'})
                self.assertEqual({n for n in members if n.startswith('tools/')},
                                 {'tools/install-user.sh', 'tools/rollback-user.sh', 'tools/uninstall-user.sh'})
                self.assertFalse(any(n.startswith('docs/') for n in members))
                self.assertNotIn('native-release-gate.json', members)
                self.assertNotIn('feature-acceptance.json', members)
                self.assertIn('share/letty/fonts/Regular.ttf', members)
                self.assertIn('share/icons/hicolor/256x256/apps/letty.png', members)
                self.assertIn('share/letty/fonts/LICENSE.txt', members)
                self.assertIn('share/letty/shell-integration/bash/letty.bash', members)
                self.assertIn('licenses/ghostty-LICENSE', members)
                for name in ['bin/letty', 'tools/install-user.sh', 'tools/rollback-user.sh', 'tools/uninstall-user.sh']:
                    self.assertTrue(members[name].mode & 0o111)
                self.assertIn(b'Letty 0.2.0', tar.extractfile(members['README.md']).read())
                info = json.load(tar.extractfile(members['build-info.json']))
                self.assertEqual(info['package_id'], '0.2.0')
                self.assertEqual(info['git_commit'], 'commit')
                self.assertEqual(info['verification']['workflow_url'],
                                 'https://github.com/BeriBeli/letty/actions/runs/123')
                sums = tar.extractfile(members['SHA256SUMS']).read().decode().splitlines()
                self.assertEqual(len(sums), len(members) - 1)
                for line in sums:
                    digest, name = line.split('  ', 1)
                    self.assertEqual(digest, hashlib.sha256(tar.extractfile(members[name]).read()).hexdigest())


if __name__ == '__main__':
    unittest.main()
