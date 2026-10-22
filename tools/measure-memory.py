#!/usr/bin/env python3
"""Measure owned PTYs and portable offscreen frames with isolated user state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--manifest', type=Path, required=True, help='Build manifest matching this executable, including preserved baselines')
    parser.add_argument('--shell', default='/bin/sh')
    parser.add_argument('--interactive-shell', action='store_true', help='Launch the isolated interactive shell without a command override')
    args = parser.parse_args()
    binary = args.binary.resolve()
    manifest = json.loads(args.manifest.read_text())
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    if manifest['binaries']['letty'] != digest:
        raise SystemExit('Build manifest does not match executable')
    if not 1 <= args.runs <= 10:
        raise SystemExit('Runs must be between 1 and 10')
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    logs = []
    for run in range(args.runs):
        with tempfile.TemporaryDirectory(prefix='letty-memory-') as name:
            home = Path(name).resolve()
            config = home / 'config'
            config.write_text(json.dumps({'shell': args.shell, 'restore_layout': False,
                                          'cursor_blink': False, 'shell_integration': 'none'}) + '\n')
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home), ZDOTDIR=str(home),
                       HISTFILE='/dev/null', LC_ALL='en_US.UTF-8' if platform.system() == 'Darwin' else 'C.UTF-8')
            command = [str(binary), '--memory-checks', '--nanoui-hidden', '--hold',
                       '--config=' + str(config), '--cwd=' + str(home)]
            if not args.interactive_shell:
                command.append('--command=printf "Ready\\n"; exec /bin/sh')
            result = subprocess.run(command,
                                    cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=120)
            (args.output / f'run-{run}.log').write_text(result.stdout)
            logs.append(result.stdout)
            if result.returncode or 'Memory checks completed.' not in result.stdout:
                raise RuntimeError(f'Memory run {run} failed: {result.stdout[-4000:]}')
            memory = [json.loads(line[7:]) for line in result.stdout.splitlines() if line.startswith('MEMORY ')]
            timing = [json.loads(line[14:]) for line in result.stdout.splitlines() if line.startswith('MEMORY_TIMING ')]
            if len(memory) != 7 or len(timing) != 3:
                raise RuntimeError('Incomplete memory/timing records')
            expected = {'one_tab': 1, 'sixteen_tabs_idle': 16, 'sixteen_tabs_history': 16,
                        'four_windows': 19, 'closed_to_one_tab': 1,
                        'transient_frame_32mib': 1, 'recovered_frame': 1}
            if {row['phase']: row['sessions'] for row in memory} != expected:
                raise RuntimeError('Workload session counts differ from the comparison fixture')
            if any(row['rss'] <= 0 or row['font_loaded_faces'] == 0 for row in memory):
                raise RuntimeError('Missing process/font measurements')
            if {row['operation']: row['samples'] for row in timing} != {
                    'new_tab_first_frame': 15, 'switch_tab': 120, 'switch_after_peak': 120}:
                raise RuntimeError('Incomplete latency samples')
            records.append({'run': run, 'memory': memory, 'timing': timing})
    summary = {}
    for phase in [row['phase'] for row in records[0]['memory']]:
        rows = [next(row for row in run['memory'] if row['phase'] == phase) for run in records]
        summary[phase] = {key: statistics.median(row[key] for row in rows)
                          for key in rows[0] if key != 'phase' and rows[0][key] is not None}
    timings = {}
    for operation in [row['operation'] for row in records[0]['timing']]:
        rows = [next(row for row in run['timing'] if row['operation'] == operation) for run in records]
        timings[operation] = {key: {'median': statistics.median(row[key] for row in rows),
                                   'min': min(row[key] for row in rows), 'max': max(row[key] for row in rows)}
                             for key in ('median_us', 'p95_us', 'max_us')}
    report = {'host': platform.platform(), 'binary': str(binary),
              'binary_sha256': digest, 'source_sha256': manifest['code_sha256'],
              'build_configuration': manifest['configuration'],
              'launch_shell': args.shell, 'interactive_shell': args.interactive_shell,
              'tool_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'runs': records,
              'summary_bytes': summary, 'timing_us': timings,
              'scope': 'Real VT/PTYS, offscreen portable UI and persistent CPU raster; excludes GTK/X11/presentation and child shell RSS. PSS is Linux-only. Categories are requested/live buffer bytes and do not sum to RSS; page residency is an engine estimate. Peak recovery uses a controlled synthetic 32 MiB transient frame allocation.'}
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'memory': summary, 'timing': timings}, indent=2))


if __name__ == '__main__':
    main()
