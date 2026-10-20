#!/usr/bin/env python3
"""Real VT/portable CPU rendering, full versus incremental pixel equality.

No OS window, synthetic desktop input, clipboard, X11, or VDI measurements.
Each run uses a temporary config and an owned, short-lived idle PTY child.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
from verification import ROOT, STORE, code_hash, sha

PHASES = ('idle_before', 'output', 'scroll', 'search', 'selection', 'cursor', 'overlay', 'idle_after')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', default='native-portable')
    parser.add_argument('--timeout', type=int, default=90)
    args = parser.parse_args()
    binary = ROOT / 'zig-out' / args.prefix / 'bin/letty'
    identity, executable = code_hash(), sha(binary)
    manifest = json.loads((STORE / ('build-' + args.prefix + '.json')).read_text())
    if manifest.get('code_sha256') != identity or manifest.get('binaries', {}).get('letty') != executable or manifest.get('configuration', {}).get('portable') is not True:
        raise RuntimeError('Build current portable application first')
    dest = STORE / 'm8-cpu-damage'
    dest.mkdir(exist_ok=True, parents=True)
    records = []
    commands = []
    for panes in (1, 4, 16):
        with tempfile.TemporaryDirectory(prefix='letty-cpu-damage-') as directory:
            config = Path(directory) / 'config'
            config.write_text('shell=/bin/sh\nrestore-layout=false\ncopy-on-select=none\n')
            command = [str(binary), '--cpu-damage-perf=' + str(panes), '--nanoui-hidden', '--hold', '--config=' + str(config), '--command=exec /bin/sleep 80']
            result = subprocess.run(command, cwd=ROOT, env=dict(os.environ, XDG_CONFIG_HOME=directory), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=args.timeout)
            log = dest / (str(panes) + '-panes.log')
            log.write_text(result.stdout)
            print(result.stdout, end='', flush=True)
            result.check_returncode()
            if any(word in result.stdout for word in ('FAIL UI ', 'panic:', 'leaked [')):
                raise RuntimeError('CPU renderer fixture failed')
            rows = [json.loads(line.removeprefix('CPU_DAMAGE_PERF ')) for line in result.stdout.splitlines() if line.startswith('CPU_DAMAGE_PERF ')]
            if tuple(row.get('phase') for row in rows) != PHASES:
                raise RuntimeError('Missing real portable CPU phases')
            for row in rows:
                if row.get('status') != 'passed' or row.get('panes') != panes or row.get('frames') != 12 or row.get('pixels_equal') is not True or row.get('x11_presentation') != 'not measured':
                    raise RuntimeError('Incomplete CPU equality/performance evidence')
                if sum(row[name] for name in ('none_frames', 'full_frames', 'rect_frames')) != 12:
                    raise RuntimeError('Incomplete frame accounting')
                if row['phase'] == 'cursor' and (row.get('cursor_visible_frames') != 12 or row['none_frames'] != 0):
                    raise RuntimeError('Cursor benchmark did not move visible pixels')
                if row['phase'].startswith('idle_') and row['none_frames'] != 12:
                    raise RuntimeError('Static frames still redraw CPU pixels')
            records.extend(rows)
            commands.append({'argv': command, 'log_sha256': sha(log), 'exit_code': result.returncode, 'timeout_seconds': args.timeout})
    if code_hash() != identity or sha(binary) != executable:
        raise RuntimeError('Source or binary changed while measuring')
    report = {'schema': 1, 'status': 'passed', 'code_sha256': identity, 'binary_sha256': executable,
              'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'verifier_sha256': sha(Path(__file__)), 'commands': commands, 'records': records,
              'comparisons': 3 * 8 * 12, 'panes': 'owned native VT instances; idle host PTY only',
              'scope': 'actual VT mutation, UI frame, TrueType atlas, CPU full/damage draws',
              'excluded': ['PTY transport timings', 'GPU present', 'GTK/X11 presentation', 'VDI', 'PSS', 'RSS']}
    path = dest / 'report.json'
    path.write_text(json.dumps(report, indent=2) + '\n')
    print('Report:', path)


if __name__ == '__main__':
    main()
