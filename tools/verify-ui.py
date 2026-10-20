#!/usr/bin/env python3
"""Run the real hidden UI suite against isolated config/clipboard fixtures."""
import argparse
import json
import os
import platform
import shutil
import tempfile
from pathlib import Path
from verification import ROOT, STORE, run_suite, sha
parser = argparse.ArgumentParser()
parser.add_argument('--prefix', default='native' if platform.system() == 'Darwin' else 'linux')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='letty-ui-') as name:
    config = Path(name) / 'config'
    config.write_text('{"shell":"/bin/sh","restore_layout":false}\n')
    env = dict(os.environ, XDG_CONFIG_HOME=name)
    record = run_suite([ROOT / 'zig-out' / args.prefix / 'bin/letty', '--ui-checks', '--nanoui-hidden', '--hold',
                        f'--config={config}', '--command=printf "Ready\\n"; exec /bin/sh'], args.prefix + '-ui', env)
    images = {}
    for scene in ('light', 'sidebar-narrow'):
        source = ROOT / '.cache/test-logs' / ('preview-application-' + scene + '.png')
        if not source.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Missing application preview screenshot')
        target = source.with_name('preview-application-' + args.prefix + '-' + scene + '.png')
        shutil.copy2(source, target)
        images[str(target)] = sha(target)
    record['preview_screenshots'] = images
    (STORE / (args.prefix + '-ui.json')).write_text(json.dumps(record, indent=2) + '\n')
