#!/usr/bin/env python3
"""Run one independently selectable hidden application feature regression."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from verification import ROOT, STORE, code_hash, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', default='native')
    parser.add_argument('--batch', choices=('M9', 'M10', 'M11', 'SIDEBAR', 'SETTINGS', 'PREVIEW'), required=True)
    args = parser.parse_args()
    binary = ROOT / 'zig-out' / args.prefix / 'bin/letty'
    identity, digest = code_hash(), sha(binary)
    manifest = json.loads((STORE / ('build-' + args.prefix + '.json')).read_text())
    if manifest.get('code_sha256') != identity or manifest['binaries'].get('letty') != digest:
        raise RuntimeError('Build the current source before standalone feature acceptance')
    with tempfile.TemporaryDirectory(prefix='letty-feature-') as directory:
        config = Path(directory) / 'config'
        config.write_text('shell = /bin/sh\nrestore-layout = false\ncopy-on-select = none\n')
        env = dict(os.environ, XDG_CONFIG_HOME=directory)
        command = [str(binary), '--feature-checks=' + args.batch, '--nanoui-hidden', '--hold',
                   '--config=' + str(config), '--command=printf "Ready\\n"; exec /bin/sh']
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
    output = result.stdout.decode()
    suite = args.prefix + '-feature-' + args.batch
    log = STORE / (suite + '.log')
    log.write_text(output)
    print(output, end='')
    if (result.returncode or re.search(r'^FAIL(?:\s|:)|panic:|leaked \[|error\(gpa\):', output, re.M)
            or output.splitlines().count('Feature checks passed: ' + args.batch) != 1
            or output.splitlines().count('BATCH_BEGIN ' + args.batch) != 1
            or output.splitlines().count('BATCH_END ' + args.batch) != 1):
        raise RuntimeError('Feature regression failed: ' + args.batch)
    if code_hash() != identity or sha(binary) != digest:
        raise RuntimeError('Source or binary changed during feature acceptance')
    checks = [line.removeprefix('PASS UI ') for line in output.splitlines() if line.startswith('PASS UI ')]
    if not checks:
        raise RuntimeError('Empty feature regression')
    record = {'status': 'passed', 'code_sha256': identity, 'binary_sha256': digest, 'batch': args.batch,
              'count': len(checks), 'assertions': checks, 'command': command,
              'log_sha256': sha(log), 'runner_sha256': sha(Path(__file__)),
              'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'hidden local application; external OS services/target-machine acceptance pending'}
    (STORE / (suite + '.json')).write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
