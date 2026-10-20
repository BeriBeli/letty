#!/usr/bin/env python3
"""Measure existing native Zig application versions in interleaved, isolated macOS headless runs.

This does not build, open an OS window, access the OS clipboard, or grant native
GUI acceptance. It requires current build manifests. ui.Tester measures frame
construction; GPU draw/present, GTK/X11/VDI and PSS are outside this experiment.
A regression produces a report and exit 2; it is never automatically accepted.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import tempfile

from verification import ROOT, STORE, code_hash, sha

PANES = (1, 4, 16)
REPETITIONS = 3
TIMEOUT_SECONDS = 60
PERF_KEYS = {
    'panes', 'startup_ms', 'producer_complete_us', 'frame_mean_us', 'frame_p95_us',
    'idle_cpu_us', 'idle_wall_us', 'history_feed_us', 'search_us',
    'search_tick_max_us', 'search_slices', 'matches', 'scroll_60_frames_us',
}
# An idle child is bounded independently of parent cleanup on timeout. Its 45s
# sleep begins only after the same 1000-line PTY producer and bell in each pane.
PRODUCER = (
    "/bin/sleep 0.2; /usr/bin/awk 'BEGIN {for(i=0;i<1000;i++) print "
    "i,\"log 中文 payload abcdefghijklmnopqrstuvwxyz\"}'; "
    "printf '\\a'; exec /bin/sleep 45"
)
CONFIG = ('shell = /bin/sh\nrestore-layout = false\ncopy-on-select = none\n'
          'scrollback-lines = 100000\n')
FAILURE = re.compile(r'\b(?:FAIL(?:ED|URE)?|panic|leak(?:ed|s)?)\b', re.I)


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2,
                               allow_nan=False) + '\n')


def source_identity():
    # Match the project's build-manifest source guard, and separately guard
    # actual vendor source contents (not caches or generated build products).
    digest = hashlib.sha256()
    paths = set()
    for dependency in ('ghostty', 'nanoui'):
        base = ROOT / 'vendor' / dependency
        for folder in ('src', 'include', 'build'):
            paths.update(p for p in (base / folder).rglob('*') if p.is_file())
        paths.update(p for p in (base / 'build.zig', base / 'build.zig.zon')
                     if p.is_file())
    if not paths:
        raise RuntimeError('Missing fixed vendor source trees')
    for path in sorted(paths):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b'\0')
        digest.update(path.read_bytes())
    return {'code_sha256': code_hash(), 'vendor_source_sha256': digest.hexdigest(),
            'runner_sha256': sha(Path(__file__).resolve())}


def identify(path, backend, manifest_override, identity):
    path = path.resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError('Missing executable: ' + str(path))
    manifest_path = (manifest_override or
                     STORE / ('build-' + path.parent.parent.name + '.json')).resolve()
    manifest = json.loads(manifest_path.read_text())
    digest = sha(path)
    if (manifest.get('vt_backend') != 'zig' or
            (backend == 'candidate' and manifest.get('code_sha256') != identity['code_sha256']) or
            manifest.get('binaries', {}).get(path.name) != digest):
        raise RuntimeError('Stale or incorrect build manifest: ' + str(manifest_path))
    version = subprocess.check_output([str(path), '--version'], cwd=ROOT, text=True, stderr=subprocess.STDOUT)
    if 'vt-backend=zig' not in version:
        raise RuntimeError('Both compared executables must be native Zig versions')
    return {'path': str(path), 'sha256': digest, 'vt_backend': 'zig', 'source_code_sha256': manifest['code_sha256'], 'version': version.strip(), 'manifest': str(manifest_path),
            'manifest_sha256': sha(manifest_path), 'disk_bytes': path.stat().st_size,
            'allocated_disk_bytes': path.stat().st_blocks * 512}


def guard(identity, binaries):
    if source_identity() != identity:
        raise RuntimeError('Source or runner changed during measurement')
    for item in binaries.values():
        if (sha(Path(item['path'])) != item['sha256'] or
                sha(Path(item['manifest'])) != item['manifest_sha256']):
            raise RuntimeError('Executable or build manifest changed during measurement')


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Duplicate PERF JSON field: ' + key)
        value[key] = item
    return value


def invalid_constant(value):
    raise ValueError('Invalid JSON numeric constant: ' + value)


def parse_perf(output, panes):
    if FAILURE.search(output):
        raise RuntimeError('Runtime FAIL/panic/leak marker; see raw logs')
    lines = [line[5:] for line in output.splitlines() if line.startswith('PERF ')]
    if len(lines) != 1:
        raise RuntimeError('Expected exactly one PERF JSON record')
    value = json.loads(lines[0], object_pairs_hook=unique_object,
                       parse_constant=invalid_constant)
    if (not isinstance(value, dict) or set(value) != PERF_KEYS or
            any(type(item) is not int or item < 0 for item in value.values()) or
            value['panes'] != panes or value['matches'] <= 0 or
            value['idle_wall_us'] <= 0):
        raise RuntimeError('Invalid, incomplete or wrong-pane PERF record')
    return value


def parse_time(stderr):
    values = {}
    for line in stderr.splitlines():
        match = re.fullmatch(r'\s*(real|user|sys)\s+(\d+(?:\.\d+)?)\s*', line)
        if match:
            key = {'real': 'wall_seconds', 'user': 'user_seconds',
                   'sys': 'system_seconds'}[match[1]]
            if key in values:
                raise RuntimeError('Duplicate /usr/bin/time field')
            values[key] = float(match[2])
        match = re.fullmatch(r'\s*(\d+)\s+maximum resident set size\s*', line)
        if match:
            if 'peak_rss_bytes' in values:
                raise RuntimeError('Duplicate RSS field')
            # macOS time -l reports bytes; Linux time -v reports KiB and is
            # deliberately unsupported by this runner instead of mislabelled.
            values['peak_rss_bytes'] = int(match[1])
    if set(values) != {'wall_seconds', 'user_seconds', 'system_seconds', 'peak_rss_bytes'}:
        raise RuntimeError('Missing /usr/bin/time -lp wall/CPU/peak RSS fields')
    if values['wall_seconds'] <= 0 or values['peak_rss_bytes'] <= 0:
        raise RuntimeError('Invalid wall/RSS measurement')
    values['cpu_seconds'] = values['user_seconds'] + values['system_seconds']
    return values


def execute(item, panes, repetition, index, output):
    stem = f'{index:02d}-{item[0]}-{panes}panes-r{repetition + 1}'
    stdout_path, stderr_path = output / (stem + '.stdout.log'), output / (stem + '.stderr.log')
    record = {'backend': item[0], 'panes': panes, 'repetition': repetition + 1,
              'order': index, 'timeout_seconds': TIMEOUT_SECONDS,
              'stdout_log': str(stdout_path), 'stderr_log': str(stderr_path)}
    # Fresh state for every repetition. No inherited shell initialization,
    # restoration, config discovery or existing instance IPC is used.
    with tempfile.TemporaryDirectory(prefix='letty-native-version-performance-') as directory:
        scratch = Path(directory)
        overrides = {name: str(scratch / name.lower()) for name in
                     ('HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME',
                      'XDG_STATE_HOME', 'XDG_RUNTIME_DIR')}
        for path in overrides.values():
            Path(path).mkdir(mode=0o700)
        config = scratch / 'performance.config'
        config.write_text(CONFIG)
        environment = dict(os.environ, **overrides, TMPDIR=str(scratch),
                           ENV='/dev/null', BASH_ENV='/dev/null', HISTFILE='/dev/null',
                           LC_ALL='en_US.UTF-8')
        command = ['/usr/bin/time', '-lp', item[1]['path'], f'--perf-checks={panes}',
                   '--nanoui-hidden', '--hold', '--no-restore',
                   '--cwd=' + str(scratch), '--config=' + str(config),
                   '--command=' + PRODUCER]
        record['command'] = command
        process = subprocess.Popen(command, cwd=ROOT, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Only this run's new process group is signalled. PTY children that
            # create their own sessions are independently bounded by sleep 45.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                stdout, stderr = process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stdout, stderr = process.communicate()
        stdout_path.write_bytes(stdout)
        stderr_path.write_bytes(stderr)
        record.update(returncode=process.returncode, timed_out=timed_out,
                      stdout_sha256=sha(stdout_path), stderr_sha256=sha(stderr_path))
        dump(output / (stem + '.json'), record)
        if timed_out or process.returncode != 0:
            raise RuntimeError(f'{stem}: timeout/nonzero exit; see {stderr_path}')
        text = stdout.decode('utf-8', errors='strict') + '\n' + stderr.decode('utf-8', errors='strict')
        record['perf'] = parse_perf(text, panes)
        record['process'] = parse_time(stderr.decode('utf-8', errors='strict'))
        dump(output / (stem + '.json'), record)
        return record


def summarize(rows, threshold):
    if len({row['perf']['matches'] for row in rows}) != 1:
        raise RuntimeError('Independent history workload matches differ across runs')
    medians, ratios, regressions = {}, {}, []
    for panes in PANES:
        groups = {backend: [row for row in rows if row['backend'] == backend and row['panes'] == panes]
                  for backend in ('baseline', 'candidate')}
        if any(len(group) != REPETITIONS for group in groups.values()):
            raise RuntimeError('Missing repetitions')
        matches = {row['perf']['matches'] for group in groups.values() for row in group}
        if len(matches) != 1:
            raise RuntimeError(f'{panes} panes: backend/repetition matches differ')
        medians[str(panes)] = {}
        for backend, group in groups.items():
            medians[str(panes)][backend] = {
                category: {key: statistics.median(row[category][key] for row in group)
                           for key in group[0][category] if key != 'panes'}
                for category in ('perf', 'process')}
        ratios[str(panes)] = {}
        for category in ('perf', 'process'):
            ratios[str(panes)][category] = {}
            for key, baseline in medians[str(panes)]['baseline'][category].items():
                candidate = medians[str(panes)]['candidate'][category][key]
                # A nonzero measurement above a zero baseline has no finite
                # ratio. Emit null and an explicit comparison, never infinity.
                ratio = candidate / baseline if baseline else (1.0 if not candidate else None)
                ratios[str(panes)][category][key] = ratio
                if key not in ('matches', 'search_slices', 'idle_wall_us') and (
                        (ratio is None and candidate > 0) or
                        (ratio is not None and ratio > threshold)):
                    regressions.append({'panes': panes, 'metric': category + '.' + key,
                                        'baseline_median': baseline, 'candidate_median': candidate,
                                        'candidate_over_baseline': ratio, 'threshold': threshold})
    return medians, ratios, regressions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, default=ROOT / '.cache/n4-before-cleanup/bin/letty')
    parser.add_argument('--candidate', type=Path, default=ROOT / 'zig-out/native/bin/letty')
    parser.add_argument('--baseline-manifest', type=Path, default=ROOT / '.cache/n4-before-cleanup/build-native.json')
    parser.add_argument('--candidate-manifest', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--regression-ratio', type=float, default=1.10,
                        help='report thresholds only; no automatic acceptance (default 1.10)')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Requires macOS /usr/bin/time -lp; GTK/X11 and Linux PSS are unmeasured')
    if not math.isfinite(args.regression_ratio) or args.regression_ratio < 1:
        parser.error('--regression-ratio must be finite and at least 1')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    output = (args.output or STORE / ('native-version-performance-' + stamp)).resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'status': 'incomplete', 'acceptance': 'not_granted', 'created_utc': stamp,
              'host': platform.platform(), 'machine': platform.machine(),
              'repetitions': REPETITIONS, 'panes': PANES,
              'regression_ratio': args.regression_ratio, 'measurements': [],
              'scope': {'ui': 'ui.Tester frame construction, 1000x680; macOS CoreText',
                        'pty': '1000 lines/pane; 200ms delay; bounded idle sleep child',
                        'history': '100000 lines in separate 80x24 VT; 64MiB budget',
                        'idle': '2 seconds event loop; child process idle',
                        'peak_rss': 'macOS time -l bytes; peak for measured app process, not PSS',
                        'cpu': 'time -p user+sys, tool OS accounting; not attributed per component',
                        'excluded': ['GPU draw/present', 'OS window/compositor', 'GTK/X11',
                                     'VDI', 'PSS', 'Linux runtime', 'clipboard operations']}}
    report_path = output / 'report.json'
    dump(report_path, report)
    try:
        identity = source_identity()
        binaries = {'baseline': identify(args.baseline, 'baseline', args.baseline_manifest, identity),
                    'candidate': identify(args.candidate, 'candidate', args.candidate_manifest, identity)}
        report.update(source=identity, binaries=binaries)
        for backend, item in binaries.items():
            size = subprocess.run(['/usr/bin/size', '-m', item['path']], cwd=ROOT,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  timeout=10, check=True)
            size_path = output / (backend + '-size.log')
            size_path.write_bytes(size.stdout)
            item.update(size_log=str(size_path), size_log_sha256=sha(size_path))
        report['binary_size_candidate_over_baseline'] = binaries['candidate']['disk_bytes'] / binaries['baseline']['disk_bytes']
        # Each pair is adjacent; reverse backend order on the second repetition
        # and rotate pane order to reduce a persistent startup/thermal bias.
        orders = ((1, 4, 16), (16, 4, 1), (4, 16, 1))
        schedule = [(backend, panes, repetition)
                    for repetition, order in enumerate(orders)
                    for panes in order
                    for backend in (('baseline', 'candidate') if repetition % 2 == 0 else ('candidate', 'baseline'))]
        report['schedule'] = schedule
        dump(report_path, report)
        for index, (backend, panes, repetition) in enumerate(schedule, 1):
            guard(identity, binaries)
            print(f'MEASURE {index}/18 {backend} panes={panes} repetition={repetition + 1}', flush=True)
            row = execute((backend, binaries[backend]), panes, repetition, index, output)
            report['measurements'].append(row)
            guard(identity, binaries)
            dump(report_path, report)
        medians, ratios, regressions = summarize(report['measurements'], args.regression_ratio)
        report.update(medians=medians, candidate_over_baseline=ratios, regressions=regressions,
                      status='regressions_require_review' if regressions else 'measured_requires_review',
                      completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        guard(identity, binaries)
        dump(report_path, report)
        print(f'MEASURED: 18 valid runs; {len(regressions)} threshold regressions; acceptance not granted; {report_path}')
        return 2 if regressions else 0
    except Exception as error:
        report.update(status='rejected', error=str(error),
                      completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        dump(report_path, report)
        raise


if __name__ == '__main__':
    raise SystemExit(main())
