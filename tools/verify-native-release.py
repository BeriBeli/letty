#!/usr/bin/env python3
"""Verify native-only developer release evidence without building or running Letty.

Local mode checks native/macOS execution plus Linux cross-build ABI and an
intact recovery archive. --ci accepts a source-bound developer receipt and then
checks this Linux job's own binaries, suites, goldens and ABI. Neither path is
CentOS, VDI or IME acceptance. Historical comparators are never imported/run.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import statistics
import subprocess
import tarfile

from verification import ROOT, STORE, code_hash, code_paths, sha

GATE = STORE / 'native-release-gate.json'
MATERIALS = {}
SUITES = {'unit': ('letty-unit-tests', 209), 'core': ('letty-check', 46),
          'ui': ('letty', 723), 'replay': ('letty-vt-replay', 9),
          'boundary': ('letty-vt-boundary', 21), 'n2': ('letty-vt-n2', 24),
          'protocol': ('letty-vt-protocol', 56), 'graphics': ('letty-vt-graphics', 13)}
# Linux count is a static branch expectation until its own complete UI log passes.
UI_EXPECTED = {'macos': 723, 'macos-portable': 719, 'linux': 679}
GOLDENS = {'replay': ('RESULT ', 11), 'n2': ('N2RESULT ', 21), 'protocol': ('PROTOCOL ', 56)}
HEX = re.compile(r'[0-9a-f]{64}')
VALIDATION_FILES = (
    'tools/verify-native-release.py', 'tools/verify-vt-goldens.py',
    'tools/verify-login-startup.py', 'tools/verify-native-stability.py',
    'tools/verify-native-startup.py', 'tools/compare-native-versions.py',
    'tools/verification.py', 'tools/audit-elf.py', 'tools/build.py',
    'tools/verify-config-cli.py', 'tools/verify-cpu-damage.py', 'tools/rendering_evidence.py',
    'tools/feature_evidence.py', 'tools/verify-feature-components.py', 'tools/verify-features.py',
    'tools/verify-ui.py',
    'tools/preview_evidence.py', 'tools/verify-preview-performance.py',
    'tools/verify-appearance.py', 'src/appearance_native_check.zig',
    'tools/package.py', 'tools/package-macos.py', 'tools/package-feature-evidence.py', '.github/workflows/linux.yml',
    'tests/vt-golden/replay.json', 'tests/vt-golden/n2.json', 'tests/vt-golden/protocol.json',
)
SOURCE_DIRS = ('src', 'tools', 'script', 'docs', 'patches', 'config', 'assets',
               'tests', '.github', '.codex/environments')
EXCLUDED = {'.cache', '.zig-cache', 'zig-cache', 'zig-out', 'zig-pkg', '__pycache__',
            'node_modules', 'generated', '.DS_Store'}
GENERATED = {'.pyc', '.pyo', '.o', '.obj', '.a', '.so', '.dylib', '.exe'}



def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def save(value):
    STORE.mkdir(parents=True, exist_ok=True)
    temporary = GATE.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    temporary.replace(GATE)


def material(path):
    path = Path(path).resolve()
    require(path.is_file(), 'Missing material: ' + str(path))
    digest = sha(path)
    require(str(path) not in MATERIALS or MATERIALS[str(path)] == digest,
            'Material changed during verification: ' + str(path))
    MATERIALS[str(path)] = digest
    return path


def unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'Duplicate JSON key: ' + key)
        value[key] = item
    return value


def invalid_number(value):
    raise ValueError('Non-finite JSON number: ' + value)


def parse(value):
    return json.loads(value, object_pairs_hook=unique, parse_constant=invalid_number)


def read(path):
    return parse(material(path).read_text())


def log_text(path):
    value = material(path).read_text()
    require(not re.search(r'^FAIL(?:\s|:)| panic:|leaked \[|error\(gpa\):', value, re.M),
            'Failure or allocator leak: ' + str(path))
    return value


def equal(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(equal(value, b[key]) for key, value in a.items())
    if isinstance(a, list):
        return len(a) == len(b) and all(equal(x, y) for x, y in zip(a, b))
    return a == b


def current(path, identity):
    value = read(path)
    require(value.get('status') == 'passed' and value.get('code_sha256') == identity,
            'Failed/stale source-bound report: ' + str(path))
    return value


def prefix_path(value):
    value = Path(value)
    return (value if value.is_absolute() else ROOT / 'zig-out' / value).resolve()


def manifest(prefix, identity, linux=False):
    value = read(STORE / ('build-' + prefix.name + '.json'))
    require(value.get('vt_backend') == 'zig' and value.get('code_sha256') == identity,
            'Manifest is not current native Zig: ' + prefix.name)
    config = value.get('configuration', {})
    require(config.get('zig') == '0.17.0' and config.get('optimize') == 'ReleaseSafe'
            and config.get('simd') is False, 'Unverified toolchain/optimization configuration')
    if linux:
        require(config.get('target') == 'x86_64-linux.3.10-gnu.2.17' and config.get('cpu') == 'baseline',
                'Linux target must retain EL7 ABI and baseline CPU')
    else:
        machine = 'aarch64' if platform.machine() in ('arm64', 'aarch64') else 'x86_64'
        target = machine + ('-macos' if platform.system() == 'Darwin' else '-linux')
        require(config.get('target') == target and config.get('cpu') == 'host', 'Wrong native host target')
    binaries = value.get('binaries', {})
    require(isinstance(binaries, dict) and set(x[0] for x in SUITES.values()) <= set(binaries),
            'Manifest lacks full native suite executables')
    require({p.name for p in (prefix / 'bin').iterdir() if p.is_file()} == set(binaries),
            'Bin directory differs from manifest')
    for name, digest in binaries.items():
        require(Path(name).name == name and sha(material(prefix / 'bin' / name)) == digest,
                'Changed executable: ' + name)
    return value


def completion(output, kind, backend='zig'):
    lines = output.splitlines()
    if kind == 'unit':
        markers = re.findall(r'^All (\d+) tests passed\.$', output, re.M)
        require(len(markers) == 1, 'Missing unit completion')
        return int(markers[0])
    if kind == 'protocol':
        require(lines.count('All 56 public-facade protocol query fixtures passed.') == 1
                and lines.count('Protocol query fixtures: 56; byte-split checks: 596; known size-callback gaps: 5') == 1,
                'Protocol assertions/split checks incomplete')
        return sum(line.startswith('PROTOCOL ') for line in lines)
    if kind == 'boundary':
        require(lines.count('All 21 native VT boundary checks passed.') == 1, 'Boundary completion missing')
        return sum(line.startswith(('PASS NATIVE BOUNDARY ', 'PASS PROMPT CLEAR ')) for line in lines)
    if kind == 'graphics':
        require(lines.count('All 13 native graphics Context checks passed.') == 1, 'Graphics completion missing')
        return sum(line.startswith('PASS NATIVE BOUNDARY ') for line in lines)
    if kind == 'n2':
        require(lines.count(f'All N2 VT facade replay checks passed (backend={backend}, checks=24, records=21).') == 1,
                'N2 backend/count mismatch')
        return sum(line.startswith('PASS N2 REPLAY ') for line in lines)
    if kind == 'replay':
        require(lines.count(f'All VT facade replay checks passed (backend={backend}).') == 1, 'Wrong replay backend')
        return sum(line.startswith('PASS REPLAY ') for line in lines)
    marker, start = ('All UI checks passed.', 'PASS UI ') if kind == 'ui' else ('All core checks passed', 'PASS ')
    require(sum(line.startswith(marker) for line in lines) == 1, 'Missing suite completion')
    return sum(line.startswith(start) for line in lines)


def suites(prefix, build, identity):
    result = {}
    for kind, (binary, expected) in SUITES.items():
        if kind == 'ui':
            target = build['configuration']['target']
            key = ('macos-portable' if build['configuration'].get('portable') else 'macos') if target.endswith('-macos') else 'linux'
            expected = UI_EXPECTED[key]
        name = prefix.name + '-' + kind
        record = current(STORE / (name + '.json'), identity)
        log = STORE / (name + '.log')
        output = log_text(log)
        require(record.get('suite') == name and record.get('log_sha256') == sha(log)
                and record.get('binary_sha256') == build['binaries'][binary], 'Suite hash/identity mismatch: ' + name)
        require(type(record.get('count')) is int and record['count'] == expected
                and completion(output, kind) == expected, 'Incomplete assertion count: ' + name)
        result[kind] = {'checks': expected, 'binary_sha256': record['binary_sha256'], 'log_sha256': record['log_sha256']}
    return result


def golden_records(output, marker, count):
    rows = [parse(line[len(marker):]) for line in output.splitlines() if line.startswith(marker)]
    names = [row.get('fixture') for row in rows]
    require(len(rows) == count and len(set(names)) == count and all(type(name) is str and name for name in names),
            'Incomplete/duplicate golden fixture output')
    return rows


def config_cli(prefix, build, identity):
    report = current(STORE / (prefix.name + '-config-cli.json'), identity)
    require(report.get('count') == 15 and report.get('binary_sha256') == build['binaries']['letty']
            and report.get('verifier_sha256') == sha(material(ROOT / 'tools/verify-config-cli.py')),
            'Missing current M7 configuration CLI acceptance')
    rows = report.get('checks', [])
    names = [row.get('name') for row in rows]
    require(len(rows) == 15 and len(set(names)) == 15, 'Incomplete M7 CLI fixtures')
    for index, row in enumerate(rows, 1):
        path = material(row['log'])
        command = row.get('command', [])
        require(row.get('status') == 'passed' and row.get('log_sha256') == sha(path)
                and row['name'].startswith(f'{index:02d}-')
                and len(command) == (2 if index >= 13 else 3)
                and (index >= 13 or command[2].startswith('--config='))
                and Path(command[0]).resolve() == prefix / 'bin/letty'
                and command[1] == '--check-config' and row.get('timeout_seconds') == 5
                and (row.get('returncode') == 0 if index in (1, 2, 9, 15) else 0 < row.get('returncode', 0) < 256)
                and 0 <= row.get('elapsed_seconds', -1) < 5, 'Invalid configuration CLI runtime evidence')
        log_text(path)
    return {'checks': 15, 'report_sha256': sha(STORE / (prefix.name + '-config-cli.json')),
            'scope': 'Actual isolated CLI reads, includes, both theme branches and FIFO refusal'}


def native_appearance(identity):
    path = STORE / 'native-appearance.json'
    report = current(path, identity)
    require(report.get('count') == 6
            and report.get('verifier_sha256') == sha(material(ROOT / 'tools/verify-appearance.py'))
            and report.get('source_sha256') == sha(material(ROOT / 'src/appearance_native_check.zig'))
            and report.get('binary_sha256') == sha(material(report['binary']))
            and report.get('build_log_sha256') == sha(material(report['build_log']))
            and report.get('log_sha256') == sha(material(report['log'])), 'Invalid native appearance evidence')
    output = log_text(report['log'])
    require(output.count('PASS APPEARANCE ') == 6
            and 'All 6 native appearance checks passed.' in output, 'Incomplete native appearance checks')
    return {'checks': 6, 'report_sha256': sha(path), 'scope': report['scope']}


def goldens(prefix, build, identity):
    report = current(STORE / 'vt-goldens.json', identity)
    require(report.get('schema_version') == 1 and report.get('backend') == 'zig'
            and Path(report.get('prefix', '')).resolve() == prefix
            and report.get('runner_sha256') == sha(material(ROOT / 'tools/verify-vt-goldens.py')),
            'Wrong golden runner/backend/prefix')
    require(set(report.get('suites', {})) == set(GOLDENS), 'Missing native golden suites')
    result = {}
    for kind, (marker, minimum) in GOLDENS.items():
        item = report['suites'][kind]
        binary, checks = SUITES[kind]
        require(item.get('status') == 'passed' and type(item.get('records')) is int and item['records'] >= minimum
                and item.get('checks') == checks and Path(item.get('binary', '')).resolve() == prefix / 'bin' / binary
                and item.get('binary_sha256') == build['binaries'][binary], 'Golden runtime binding mismatch')
        for file_key, sha_key in [('log', 'log_sha256'), ('actual_json', 'actual_sha256'), ('golden', 'golden_sha256')]:
            require(item.get(sha_key) == sha(material(item[file_key])), 'Golden material hash mismatch')
        require(Path(item['golden']).resolve() == ROOT / 'tests/vt-golden' / (kind + '.json'), 'Unexpected golden source')
        expected = read(item['golden'])
        actual = read(item['actual_json'])
        output = log_text(item['log'])
        require(expected.get('schema_version') == 1 and expected.get('suite') == kind
                and expected.get('record_count') == item['records'] and expected.get('checks') == checks
                and equal(expected.get('records'), actual)
                and equal(actual, golden_records(output, marker, item['records']))
                and completion(output, kind) == checks, 'Native values differ from fixed golden: ' + kind)
        if kind == 'protocol':
            require(item.get('byte_split_checks') == 596 and item.get('historical_size_callback_records') == 5,
                    'Missing protocol split/provenance metadata')
        result[kind] = {'records': item['records'], 'checks': checks, 'golden_sha256': item['golden_sha256']}
    return result


def abi(prefix, build, path):
    report = read(path)
    require(report.get('target') == 'x86_64-linux.3.10-gnu.2.17', 'Wrong static ABI target')
    entries = report.get('files', [])
    names = [entry.get('file') for entry in entries]
    require(len(names) == len(set(names)) and set(names) == set(build['binaries']), 'ABI must cover every bin exactly once')
    allowed = {'libc.so.6', 'ld-linux-x86-64.so.2', 'libpthread.so.0', 'libdl.so.2',
               'libutil.so.1', 'libm.so.6', 'librt.so.1'}
    for item in entries:
        binary = prefix / 'bin' / item['file']
        require(item.get('status') == 'pass' and item.get('sha256') == build['binaries'][item['file']]
                and binary.read_bytes()[:4] == b'\x7fELF', 'Stale/non-ELF ABI entry')
        require(item.get('interpreter') in (None, '/lib64/ld-linux-x86-64.so.2')
                and isinstance(item.get('needed'), list) and not set(item['needed']) - allowed, 'Invalid ABI dependencies')
        version = item.get('max_glibc')
        require(version is None or (re.fullmatch(r'\d+\.\d+(?:\.\d+)*', version)
                and tuple(map(int, version.split('.'))) <= (2, 17)), 'GLIBC exceeds 2.17')
    return {'target': report['target'], 'files': len(entries), 'scope': 'static ABI only'}


def no_c_symbols(prefix, build):
    nm = shutil.which('nm')
    require(nm is not None, 'nm is required for engine symbol audit')
    result = {}
    for name in build['binaries']:
        child = subprocess.run([nm, str(prefix / 'bin' / name)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, check=True, timeout=30)
        names = [line.split()[-1] for line in child.stdout.decode().splitlines() if line.split()]
        found = [name for name in names if re.match(r'^_?ghostty_', name)]
        require(not found, 'C API symbol linked into native binary: ' + repr(found[:5]))
        result[name] = hashlib.sha256(child.stdout).hexdigest()
    return result


def stability(prefix, build, identity):
    report = current(STORE / (prefix.name + '-stability.json'), identity)
    path = STORE / (prefix.name + '-stability.log')
    output = log_text(path)
    rows = [parse(line[10:]) for line in output.splitlines() if line.startswith('STABILITY ')]
    done = [parse(line[15:]) for line in output.splitlines() if line.startswith('STABILITY_DONE ')]
    require(report.get('binary_sha256') == build['binaries']['letty'] and report.get('log_sha256') == sha(path)
            and len(done) == 1 and equal(report.get('summary'), done[0]), 'Stability binary/log mismatch')
    require(done[0].get('backend') == 'zig' and done[0].get('cycles') == 256 and len(rows) == 256
            and [row.get('cycle') for row in rows] == list(range(1, 257))
            and all(row.get('active_ptys') == 1 for row in rows)
            and report.get('retired_children_reaped') == 257, 'Incomplete 256-cycle/257-child stability proof')
    retired = [row.get('retired_pid') for row in rows] + [done[0].get('survivor_pid')]
    require(all(type(pid) is int and pid > 0 for pid in retired), 'Invalid owned child identity')
    return {'cycles': 256, 'retired_children_reaped': 257, 'log_sha256': sha(path)}


def startup(prefix, build, identity):
    report = current(STORE / (prefix.name + '-startup.json'), identity)
    require(report.get('binary_sha256') == build['binaries']['letty'] and 'vt-backend=zig' in report.get('version', ''),
            'Startup app/backend mismatch')
    runs = report.get('runs', [])
    require(len(runs) == 20, 'Startup requires 20 real runs')
    expected = [(index, restored) for index in range(1, 11) for restored in (False, True)]
    for row, key in zip(runs, expected):
        require((row.get('iteration'), row.get('restored')) == key and type(row.get('restored')) is bool
                and type(row.get('children_reaped')) is int and row['children_reaped'] > 0
                and type(row.get('wall_seconds')) in (int, float) and 0 < row['wall_seconds'] < 15
                and HEX.fullmatch(row.get('workspace_sha256', '')), 'Startup lifecycle proof incomplete')
        path = STORE / f'{prefix.name}-startup-{key[0] - 1:02d}-{int(key[1])}.log'
        log_text(path)
        require(row.get('log_sha256') == sha(path), 'Startup raw log changed')
    return {'runs': 20, 'binary_sha256': report['binary_sha256']}



def validation_sources():
    return {name: sha(material(ROOT / name)) for name in VALIDATION_FILES}


def login_startup(prefix, build, identity):
    report = current(STORE / (prefix.name + '-login-startup.json'), identity)
    require(report.get('binary_sha256') == build['binaries']['letty']
            and report.get('runner_sha256') == sha(material(ROOT / 'tools/verify-login-startup.py')),
            'Login startup app/runner changed')
    runs = report.get('runs', [])
    require(len(runs) == 20, 'Login startup requires 20 actual runs')
    for index, row in enumerate(runs, 1):
        require(row.get('iteration') == index and row.get('initial_directory_verified') is True
                and all(type(row.get(key)) is int and row[key] > 0 for key in
                        ('shell_pid', 'foreground_group', 'watched_pid', 'children_reaped'))
                and type(row.get('wall_seconds')) in (int, float) and 0 < row['wall_seconds'] < 15,
                'Login/foreground/cwd/reaping proof incomplete')
        path = STORE / f'{prefix.name}-login-startup-{index - 1:02d}.log'
        log_text(path)
        require(row.get('log_sha256') == sha(path), 'Login startup raw log changed')
    return {'runs': 20, 'binary_sha256': report['binary_sha256'], 'runner_sha256': report['runner_sha256']}

def performance(path, review_path, build, identity):
    report, review = read(path), read(review_path)
    require(report.get('status') in ('measured_requires_review', 'regressions_require_review')
            and report.get('completed_utc') and report.get('repetitions') == 3
            and report.get('panes') == [1, 4, 16], 'Incomplete native version performance report')
    require(report.get('source', {}).get('code_sha256') == identity
            and report['source'].get('runner_sha256') == sha(material(ROOT / 'tools/compare-native-versions.py')),
            'Performance source/runner is stale')
    require(review.get('status') == 'accepted' and review.get('report_sha256') == sha(Path(path))
            and isinstance(review.get('rationale'), str) and review['rationale'].strip(), 'Missing independent accepted review')
    for role in ('baseline', 'candidate'):
        item = report.get('binaries', {}).get(role, {})
        require(item.get('vt_backend') == 'zig' and 'vt-backend=zig' in item.get('version', '')
                and HEX.fullmatch(item.get('sha256', '')), 'Performance baseline/candidate must both be native')
        require(item.get('size_log_sha256') == sha(material(item['size_log'])), 'Performance size log changed')
    require(report['binaries']['candidate']['sha256'] == build['binaries']['letty'], 'Performance candidate is not current app')
    rows, seen, matches = report.get('measurements', []), set(), set()
    require(len(rows) == 18, 'Expected 18 native version performance runs')
    for index, row in enumerate(rows, 1):
        key = row.get('backend'), row.get('panes'), row.get('repetition')
        require(key[0] in ('baseline', 'candidate') and key[1] in (1, 4, 16) and key[2] in (1, 2, 3)
                and key not in seen and row.get('order') == index, 'Invalid performance schedule')
        seen.add(key)
        require(type(row.get('returncode')) is int and row['returncode'] == 0 and row.get('timed_out') is False
                and row.get('timeout_seconds') == 60, 'Invalid performance execution')
        out, err = log_text(row['stdout_log']), log_text(row['stderr_log'])
        require(row.get('stdout_sha256') == sha(Path(row['stdout_log']))
                and row.get('stderr_sha256') == sha(Path(row['stderr_log'])), 'Performance raw logs changed')
        actual = [parse(line[5:]) for line in (out + '\n' + err).splitlines() if line.startswith('PERF ')]
        require(len(actual) == 1 and equal(actual[0], row.get('perf')), 'Raw PERF differs from report')
        perf = row['perf']
        keys = {'panes', 'startup_ms', 'producer_complete_us', 'frame_mean_us', 'frame_p95_us',
                'idle_cpu_us', 'idle_wall_us', 'history_feed_us', 'search_us', 'search_tick_max_us',
                'search_slices', 'matches', 'scroll_60_frames_us'}
        require(set(perf) == keys and all(type(v) is int and v >= 0 for v in perf.values()) and perf.get('panes') == key[1]
                and perf.get('matches', 0) > 0 and perf.get('idle_wall_us', 0) > 0
                and 'search_tick_max_us' in perf and 'startup_ms' in perf, 'Missing/invalid native performance metrics')
        matches.add(perf['matches'])
        measured = {}
        for name, suffix in [('wall_seconds', 'real'), ('user_seconds', 'user'), ('system_seconds', 'sys')]:
            values = re.findall(r'^\s*' + suffix + r'\s+(\d+(?:\.\d+)?)\s*$', err, re.M)
            require(len(values) == 1, 'Invalid time accounting')
            measured[name] = float(values[0])
        rss = re.findall(r'^\s*(\d+)\s+maximum resident set size\s*$', err, re.M)
        require(len(rss) == 1, 'Missing peak RSS')
        measured.update(peak_rss_bytes=int(rss[0]), cpu_seconds=measured['user_seconds'] + measured['system_seconds'])
        require(equal(measured, row.get('process')) and measured['peak_rss_bytes'] > 0, 'Raw resource accounting mismatch')
    require(len(matches) == 1, 'Performance workload matches differ')
    medians, ratios, regressions = {}, {}, []
    threshold = report.get('regression_ratio')
    require(type(threshold) in (int, float) and math.isfinite(threshold) and threshold >= 1, 'Invalid regression threshold')
    for panes in (1, 4, 16):
        medians[str(panes)], ratios[str(panes)] = {}, {}
        for role in ('baseline', 'candidate'):
            group = [row for row in rows if row['backend'] == role and row['panes'] == panes]
            medians[str(panes)][role] = {category: {key: statistics.median(row[category][key] for row in group)
                for key in group[0][category] if key != 'panes'} for category in ('perf', 'process')}
        for category in ('perf', 'process'):
            ratios[str(panes)][category] = {}
            for key, baseline in medians[str(panes)]['baseline'][category].items():
                candidate = medians[str(panes)]['candidate'][category][key]
                ratio = candidate / baseline if baseline else (1.0 if not candidate else None)
                ratios[str(panes)][category][key] = ratio
                if key not in ('matches', 'search_slices', 'idle_wall_us') and (
                        (ratio is None and candidate > 0) or (ratio is not None and ratio > threshold)):
                    regressions.append({'panes': panes, 'metric': category + '.' + key,
                        'baseline_median': baseline, 'candidate_median': candidate,
                        'candidate_over_baseline': ratio, 'threshold': threshold})
    require(equal(medians, report.get('medians')) and equal(ratios, report.get('candidate_over_baseline'))
            and equal(regressions, report.get('regressions')), 'Performance summary calculation mismatch')
    require(report['status'] == ('regressions_require_review' if regressions else 'measured_requires_review'), 'Wrong performance status')
    return {'runs': 18, 'report_sha256': sha(Path(path)), 'review_sha256': sha(Path(review_path)),
            'rationale': review['rationale'], 'scope': 'ui.Tester; GPU/X11/VDI/PSS excluded'}


def recovery_archive(entry):
    archive = material(entry['path'])
    sidecar = material(entry.get('sidecar_path') or str(archive) + '.wholearchive.sha256')
    parts = sidecar.read_text().split()
    require(parts and HEX.fullmatch(parts[0]) and parts[0] == entry.get('sha256') == sha(archive), 'Recovery whole archive hash mismatch')
    with tarfile.open(archive, 'r:*') as package:
        members, regular = package.getmembers(), {}
        roots = set()
        for member in members:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and '..' not in path.parts and path.parts, 'Unsafe recovery member name')
            roots.add(path.parts[0])
            require(member.isdir() or member.isfile(), 'Recovery archive contains unaccounted link/special file')
            if member.isfile():
                relative = '/'.join(path.parts[1:])
                require(relative and relative not in regular, 'Duplicate recovery archive member')
                regular[relative] = member
        require(len(roots) == 1 and 'SHA256SUMS' in regular and 'recovery.json' in regular, 'Missing recovery archive inventory')
        sums = package.extractfile(regular['SHA256SUMS']).read().decode()
        expected = {}
        for line in sums.splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
            require(match is not None and match[2] not in expected, 'Malformed/duplicate recovery checksum')
            expected[match[2]] = match[1]
        require(set(expected) == set(regular) - {'SHA256SUMS'}, 'Recovery SHA256SUMS must cover every regular file')
        for name, digest in expected.items():
            stream, hasher = package.extractfile(regular[name]), hashlib.sha256()
            with stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    hasher.update(chunk)
            require(hasher.hexdigest() == digest, 'Corrupted recovery payload: ' + name)
        info = parse(package.extractfile(regular['recovery.json']).read().decode())
        require(info.get('schema') == 1 and info.get('vt_backend') == 'c'
                and set(info.get('platforms', {})) == {'macos', 'linux'}
                and info.get('source_files') and info.get('payload_files'), 'Recovery must include source and both platform baselines')
    return ({'path': str(archive), 'sha256': sha(archive), 'sidecar_sha256': sha(sidecar),
             'regular_files_verified': len(expected), 'historical_code_sha256': info.get('code_sha256')}, info)



def restored_inventory(root):
    paths = {path for path in root.iterdir() if path.is_file() and
             (path.name in {'.gitignore', 'build.zig', 'build.zig.zon'} or path.suffix == '.md' or 'lock' in path.name)}
    for name in SOURCE_DIRS:
        for directory, dirs, files in os.walk(root / name, followlinks=False):
            dirs[:] = sorted(name for name in dirs if name not in EXCLUDED)
            require(not any((Path(directory) / name).is_symlink() for name in dirs), 'Restored source directory is a symlink')
            for name in files:
                path = Path(directory) / name
                if not EXCLUDED.intersection(path.relative_to(root).parts) and path.suffix not in GENERATED:
                    paths.add(path)
    result = {}
    for path in sorted(paths):
        require(not path.is_symlink(), 'Restored source file is a symlink')
        stat = path.stat()
        result[path.relative_to(root).as_posix()] = {'sha256': sha(material(path)),
                                                   'size': stat.st_size, 'mode': stat.st_mode & 0o777}
    return result


def restored_source(path, archive, archived):
    report = read(path)
    identity, source = archived['code_sha256'], archived['source_sha256']
    require(report.get('schema') == 1 and report.get('status') == 'passed'
            and report.get('archive', {}).get('sha256') == archive['sha256']
            and report['archive'].get('code_sha256') == identity and report['archive'].get('source_sha256') == source
            and report.get('restored_code_sha256') == identity and report.get('restored_source_sha256') == source,
            'Restored source report is not bound to exact recovery archive')
    root = Path(report['restore_root']).resolve()
    require(root != ROOT and root.is_dir(), 'Recovery must build in an independent restored directory')
    inventory = restored_inventory(root)
    digest = hashlib.sha256((json.dumps(inventory, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()).hexdigest()
    require(equal(inventory, archived['source_files']) and digest == source, 'Restored complete authored source inventory differs')
    source_inventory = report.get('source_inventory', {})
    require(source_inventory.get('sha256') == sha(material(source_inventory['path']))
            and equal(read(source_inventory['path']), archived), 'Extracted recovery inventory changed')
    runner = report.get('runner', {})
    require(runner.get('sha256') == sha(material(runner['path'])), 'Restore runner changed')
    build = report.get('build', {})
    require(build.get('prefix') == 'native-c' and Path(build['manifest']).resolve()
            == root / '.cache/verification/build-native-c.json'
            and build.get('manifest_sha256') == sha(material(build['manifest'])), 'Restored build manifest changed')
    manifest_value = read(build['manifest'])
    require(manifest_value.get('code_sha256') == identity and manifest_value.get('vt_backend') == 'c'
            and equal(manifest_value.get('binaries'), build.get('binaries')), 'Restored build is not archived C source')
    configuration = manifest_value.get('configuration', {})
    require(configuration.get('zig') == '0.17.0' and configuration.get('optimize') == 'ReleaseSafe'
            and configuration.get('simd') is False and configuration.get('target', '').endswith('-macos'),
            'Restored C build target/toolchain changed')
    binaries = build['binaries']
    bindir = root / 'zig-out/native-c/bin'
    require({item.name for item in bindir.iterdir() if item.is_file()} == set(binaries), 'Restored bin directory differs')
    for name, binary_sha in binaries.items():
        require(Path(name).name == name and binary_sha == sha(material(bindir / name)), 'Restored binary changed')
    expected = {'unit': 26, 'core': 46, 'ui': 161, 'replay': 9, 'n2': 24, 'protocol': 56}
    require(set(report.get('checks', {})) == set(expected), 'Missing restored C acceptance suites')
    for kind, count in expected.items():
        item = report['checks'][kind]
        binary = SUITES[kind][0]
        require(Path(item['record']).resolve() == root / '.cache/verification' / ('native-c-' + kind + '.json')
                and item.get('record_sha256') == sha(material(item['record']))
                and item.get('log_sha256') == sha(material(item['log']))
                and item.get('binary_sha256') == binaries[binary] and item.get('count') == count,
                'Restored suite material mismatch: ' + kind)
        record = read(item['record'])
        require(record.get('suite') == 'native-c-' + kind and record.get('status') == 'passed'
                and record.get('code_sha256') == identity and record.get('count') == count
                and record.get('binary_sha256') == binaries[binary] and record.get('log_sha256') == item['log_sha256']
                and completion(log_text(item['log']), kind, backend='c') == count, 'Restored C suite incomplete: ' + kind)
    nm = shutil.which('nm')
    require(nm is not None, 'nm is required for restored engine proof')
    output = subprocess.check_output([nm, str(bindir / 'letty')], timeout=30).decode()
    require(any(line.split()[-1:] == ['_ghostty_terminal_new'] for line in output.splitlines()), 'Restored app lacks actual C engine')
    commands = report.get('commands', [])
    require(commands and all(type(item.get('returncode')) is int and item['returncode'] == 0
                            for item in commands), 'Restored build command failed or missing')
    compile_steps = []
    for item in commands:
        require(item.get('log_sha256') == sha(material(item['log'])), 'Restored command log changed')
        output = log_text(item['log'])
        if item.get('label') == 'c-source-build-and-five-suites':
            argv = item.get('command', [])
            require(isinstance(argv, list) and len(argv) >= 3 and argv[1] == 'tools/build.py'
                    and {'--native', '--skip-bootstrap', '--vt-backend=c'} <= set(argv)
                    and any(argument.startswith('--zig=') for argument in argv)
                    and Path(item['cwd']).resolve() == root
                    and '-Demit-lib-vt=true' in output and '-Dvt-backend=c' in output and 'Built:' in output,
                    'Missing actual C engine/application source build command')
            compile_steps.append(item)
    require(len(compile_steps) == 1, 'Expected one independent C source build')
    cache = report.get('cache_inputs', {})
    upstream = {name: value['sha256'] for name, value in archived['dependencies']['sources'].items()}
    require(cache.get('compiled_cache_copied') is False and cache.get('zig_version') == '0.17.0'
            and equal(cache.get('upstream_sha256'), upstream) and HEX.fullmatch(cache.get('package_tree_sha256', ''))
            and type(cache.get('package_files')) is int and cache['package_files'] > 0,
            'Recovery did not use verified source-only dependencies')
    materials = report.get('materials_sha256', {})
    require(materials, 'Restored build must preserve actual execution materials')
    for name, digest in materials.items():
        require(digest == sha(material(name)), 'Restored execution material changed: ' + name)
    return {'status': 'passed', 'report_sha256': sha(Path(path)), 'archive_sha256': archive['sha256'],
            'source_sha256': source, 'restored_code_sha256': identity, 'source_files': len(inventory),
            'checks': expected, 'manifest_sha256': build['manifest_sha256'], 'runner_sha256': runner['sha256'],
            'scope': 'macOS C source rebuild executed; CentOS/VDI/IME pending'}

def cleanup(identity, restore_report):
    report = current(STORE / 'n4-cleanup-inventory.json', identity)
    require(report.get('no_active_c_refs') is True and isinstance(report.get('deleted_files'), list)
            and report['deleted_files'], 'Missing cleanup inventory')
    for name in report['deleted_files']:
        path = PurePosixPath(name)
        require(not path.is_absolute() and '..' not in path.parts and not (ROOT / name).exists(), 'Deleted file still exists: ' + name)
    forbidden = re.compile(r'\bghostty_terminal_[A-Za-z0-9_]+\b|\bvt_c\.zig\b|\bvt_bridge\.(?:c|h)\b|\bvt_internal\.h\b')
    for path in code_paths():
        # The locked Ghostty tree also ships its unused C API implementation.
        # Audit our integration and framework; linked binaries are independently
        # checked for every C terminal symbol by no_c_symbols().
        if path.is_relative_to(ROOT / 'vendor/ghostty'):
            continue
        if path.suffix in ('.zig', '.c', '.h') and path.is_file():
            require(not forbidden.search(path.read_text()), 'Active source retains C engine reference: ' + str(path))
    require(not re.search(r'\bvt_backend\s*=\s*"c"|backend\s*==\s*\.c', (ROOT / 'build.zig').read_text()),
            'Active C build branch remains')
    recovery, archived = recovery_archive(report['c_recovery'])
    recovery['source_rebuild'] = restored_source(restore_report, recovery, archived)
    return {'deleted_files': report['deleted_files'], 'no_active_c_refs': True, 'recovery': recovery}


def clean_build(identity):
    path = STORE / 'n4-default-clean.json'
    if not path.exists():
        return {'status': 'not_present', 'required': False, 'scope': 'normal current source-bound build still required'}
    report = current(path, identity)
    require(report.get('backend_flag', 'missing') is None and report.get('no_C_engine') is True
            and isinstance(report.get('clean_cache'), str) and report['clean_cache'], 'Invalid default clean build proof')
    prefix = ROOT / 'zig-out/native-clean'
    build = manifest(prefix, identity)
    require(report.get('binary_sha256') == build['binaries']['letty'], 'Default clean build app changed')
    return {'status': 'passed', 'checks': suites(prefix, build, identity), 'symbols': no_c_symbols(prefix, build)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-prefix', default='native')
    parser.add_argument('--linux-prefix', default='linux')
    parser.add_argument('--performance', type=Path)
    parser.add_argument('--review', type=Path)
    parser.add_argument('--ci', action='store_true')
    parser.add_argument('--receipt', type=Path, default=ROOT / 'docs/native-release-acceptance.json')
    parser.add_argument('--abi', type=Path)
    parser.add_argument('--recovery-restore', type=Path, default=STORE / 'n4-c-recovery-restore.json')
    report = {'status': 'failed', 'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'native-only developer release gate', 'target_acceptance': 'pending',
              'unaccepted': ['CentOS runtime', 'VDI', 'IME'], 'n4_developer_cleanup': True,
              'ui_expected_by_target': UI_EXPECTED,
              'linux_ui_basis': 'Static branch expectation; actual complete source-bound Linux CI log required before accepting',
              'error': 'Verification not complete'}
    save(report)
    try:
        args = parser.parse_args()
        identity = code_hash()
        report.update(code_sha256=identity, verifier_sha256=sha(material(Path(__file__))),
                      validation_sources=validation_sources())
        linux = prefix_path(args.linux_prefix)
        linux_build = manifest(linux, identity, linux=True)
        abi_path = args.abi or (ROOT / '.cache/test-logs/abi-audit.json' if args.ci else STORE / 'n3-linux-abi.json')
        report['linux'] = {'prefix': str(linux), 'binaries': linux_build['binaries'], 'abi': abi(linux, linux_build, abi_path)}
        if args.ci:
            require(os.environ.get('GITHUB_ACTIONS') == 'true' and platform.system() == 'Linux', 'Receipt mode is only for Linux CI')
            receipt = current(args.receipt, identity)
            require(receipt.get('n4_developer_cleanup') is True and receipt.get('target_acceptance') == 'pending'
                    and receipt.get('cleanup', {}).get('no_active_c_refs') is True
                    and equal(receipt.get('validation_sources'), report['validation_sources'])
                    and receipt.get('cleanup', {}).get('recovery', {}).get('source_rebuild', {}).get('status') == 'passed'
                    and receipt.get('login_startup', {}).get('runs') == 20
                    and receipt.get('appearance', {}).get('checks') == 6
                    and receipt.get('rendering', {}).get('status') == 'passed'
                    and receipt.get('rendering', {}).get('cpu_comparisons') == 288
                    and receipt.get('features', {}).get('status') == 'passed'
                    and receipt['features'].get('code_sha256') == identity
                    and receipt['login_startup'].get('runner_sha256') == report['validation_sources']['tools/verify-login-startup.py']
                    and equal(receipt['cleanup']['recovery']['source_rebuild'].get('checks'),
                              {'unit': 26, 'core': 46, 'ui': 161, 'replay': 9, 'n2': 24, 'protocol': 56}),
                    'Invalid source-bound developer release receipt')
            report.update(basis='source-bound developer receipt plus current own Linux execution and ABI',
                          developer_receipt_sha256=sha(args.receipt),
                          developer_appearance={**receipt['appearance'], 'executed_in_current_ci_job': False},
                          developer_rendering={**receipt['rendering'], 'executed_in_current_ci_job': False},
                          features={**receipt['features'], 'executed_in_current_ci_job': False,
                                    'provenance': 'source-bound local developer receipt; own Linux UI checked separately'},
                          developer_recovery={**receipt['cleanup']['recovery'], 'provenance': {
                              'basis': 'source-bound developer receipt; recovery is historical developer evidence',
                              'developer_receipt_sha256': sha(args.receipt),
                              'executed_in_current_ci_job': False, 'source_rebuild_host': 'macOS'}},
                          suites=suites(linux, linux_build, identity),
                          config_cli=config_cli(linux, linux_build, identity),
                          goldens=goldens(linux, linux_build, identity), symbols=no_c_symbols(linux, linux_build))
        else:
            require(args.performance is not None and args.review is not None, 'Local mode requires --performance and --review')
            native = prefix_path(args.native_prefix)
            require(native != linux, 'Native and Linux prefixes must differ')
            build = manifest(native, identity)
            report.update(basis='current local developer execution plus Linux static cross-build ABI',
                          backends={'zig': {'prefix': str(native), 'binaries': build['binaries']}},
                          suites=suites(native, build, identity), goldens=goldens(native, build, identity),
                          config_cli=config_cli(native, build, identity),
                          appearance=native_appearance(identity),
                          symbols=no_c_symbols(native, build), stability=stability(native, build, identity),
                          startup=startup(native, build, identity), login_startup=login_startup(native, build, identity),
                          cleanup=cleanup(identity, args.recovery_restore),
                          performance=performance(args.performance, args.review, build, identity),
                          default_clean_build=clean_build(identity))
            from rendering_evidence import rendering
            report['rendering'] = rendering(identity, manifest, suites, material, read, require, equal)
            from feature_evidence import features
            report['features'] = features(identity, material, read, require, equal)
            from preview_evidence import preview_performance
            report['preview_performance'] = preview_performance(identity, material, read, require, equal)
        require(code_hash() == identity, 'Source changed during release verification')
        for path, digest in list(MATERIALS.items()):
            require(sha(Path(path)) == digest, 'Material changed during release verification: ' + path)
        report.update(status='passed', materials_sha256=MATERIALS,
                      completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        report.pop('error', None)
        save(report)
        print('PASS native developer release gate; target CentOS/VDI/IME pending:', GATE)
    except BaseException as error:
        report.update(status='failed', error=str(error), materials_sha256=MATERIALS,
                      completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        save(report)
        raise


if __name__ == '__main__':
    main()
