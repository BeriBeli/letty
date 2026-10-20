#!/usr/bin/env python3
"""Native-only facade regression against reviewed, fixed JSON goldens.

Golden updates are deliberately not a runner option. Review a changed value
before editing tests/vt-golden; this tool never learns new expected output.
"""
import argparse
import datetime
import json
import os
import platform
import re
import subprocess
from pathlib import Path
from verification import ROOT, STORE, code_hash, sha

SUITES = {
    'replay': ('letty-vt-replay', 'RESULT ', 11, 9),
    'n2': ('letty-vt-n2', 'N2RESULT ', 21, 24),
    'protocol': ('letty-vt-protocol', 'PROTOCOL ', 56, 56),
}
HISTORICAL_SIZE_RECORDS = {
    'size-text-area-pixels', 'size-cell-pixels', 'size-text-area-cells',
    'size-screen-cells', 'size-mode2048-enable',
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def load_json(text):
    def invalid_constant(value):
        raise ValueError('Non-JSON numeric constant: ' + value)
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=invalid_constant)


def difference(expected, actual, path='$'):
    """JSON types are exact: bool != int, and 1 != 1.0; objects ignore key order."""
    if type(expected) is not type(actual):
        return {'path': path, 'reason': 'JSON type differs',
                'expected_type': type(expected).__name__, 'actual_type': type(actual).__name__}
    if isinstance(expected, dict):
        if expected.keys() != actual.keys():
            return {'path': path, 'reason': 'Object keys differ',
                    'missing': sorted(expected.keys() - actual.keys()),
                    'unexpected': sorted(actual.keys() - expected.keys())}
        for key, value in expected.items():
            if found := difference(value, actual[key], path + '.' + key):
                return found
    elif isinstance(expected, list):
        if len(expected) != len(actual):
            return {'path': path, 'reason': 'Array length differs',
                    'expected': len(expected), 'actual': len(actual)}
        for index, (left, right) in enumerate(zip(expected, actual)):
            if found := difference(left, right, f'{path}[{index}]'):
                return found
    elif expected != actual:
        return {'path': path, 'reason': 'Value differs', 'expected': expected, 'actual': actual}
    return None


def records_for(output, prefix, count):
    records = [load_json(line[len(prefix):]) for line in output.splitlines() if line.startswith(prefix)]
    if len(records) != count:
        raise RuntimeError(f'Expected {count} records, received {len(records)}')
    names = [record.get('fixture') if isinstance(record, dict) else None for record in records]
    if any(type(name) is not str or not name for name in names) or len(set(names)) != count:
        raise RuntimeError('Missing, invalid or duplicate fixture name')
    return records


def completion(output, suite):
    lines = output.splitlines()
    if suite == 'replay':
        if lines.count('All VT facade replay checks passed (backend=zig).') != 1:
            raise RuntimeError('Missing native replay completion')
        checks = sum(line.startswith('PASS REPLAY ') for line in lines)
    elif suite == 'n2':
        matches = re.findall(r'All N2 VT facade replay checks passed \(backend=zig, checks=(\d+), records=(\d+)\)\.', output)
        checks = sum(line.startswith('PASS N2 REPLAY ') for line in lines)
        if len(matches) != 1 or tuple(map(int, matches[0])) != (checks, 21):
            raise RuntimeError('Missing or incomplete native N2 completion')
    else:
        matches = re.findall(r'Protocol query fixtures: (\d+); byte-split checks: (\d+); known size-callback gaps: (\d+)', output)
        if len(matches) != 1 or tuple(map(int, matches[0])) != (56, 596, 5):
            raise RuntimeError('Protocol fixtures/split checks/historical metadata changed')
        if lines.count('All 56 public-facade protocol query fixtures passed.') != 1:
            raise RuntimeError('Missing protocol completion')
        checks = 56
    if checks != SUITES[suite][3]:
        raise RuntimeError(f'{suite} hard assertion count changed: {checks}')
    return checks


def run_logged(command, log, env, timeout):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    try:
        result = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        log.write_bytes(error.stdout or b'')
        raise RuntimeError('Timed out; see ' + str(log)) from error
    log.write_bytes(result.stdout)
    output = result.stdout.decode('utf-8', errors='strict')
    if result.returncode:
        raise RuntimeError(f'Exit {result.returncode}; see {log}')
    if any(line.startswith('FAIL ') for line in output.splitlines()) or 'leaked [' in output or ' panic:' in output:
        raise RuntimeError('Runtime failure; see ' + str(log))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='/opt/homebrew/bin/zig')
    parser.add_argument('--prefix', type=Path, default=ROOT / 'zig-out/native')
    parser.add_argument('--skip-build', action='store_true', help='Require a current source-bound build manifest instead')
    parser.add_argument('--timeout', type=int, default=120, help='Maximum seconds for each executable')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    prefix = args.prefix.resolve()
    STORE.mkdir(parents=True, exist_ok=True)
    before = code_hash()
    report = {'schema_version': 1, 'stage': 'N4 native VT golden regression',
              'status': 'failed', 'backend': 'zig', 'code_sha256': before,
              'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'runner_sha256': sha(Path(__file__)), 'prefix': str(prefix), 'suites': {},
              'scope': 'Native host execution; historical C evidence is provenance only; no Linux/VDI claim'}
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'))
    try:
        if args.skip_build:
            manifest = load_json((STORE / ('build-' + prefix.name + '.json')).read_text())
            if manifest.get('vt_backend') != 'zig' or manifest.get('code_sha256') != before:
                raise RuntimeError('Prebuilt native manifest has stale source or wrong backend')
            for binary, _, _, _ in SUITES.values():
                if manifest.get('binaries', {}).get(binary) != sha(prefix / 'bin' / binary):
                    raise RuntimeError('Prebuilt native executable does not match manifest: ' + binary)
        else:
            if subprocess.check_output([args.zig, 'version'], text=True).strip() != '0.17.0':
                raise RuntimeError('Requires Zig 0.17.0')
            command = [args.zig, 'build', 'replay-bin', 'n2-replay-bin', 'protocol-bin',
                       '-Doptimize=ReleaseSafe', '--prefix', str(prefix), '-j2']
            report['build_command'] = command
            build_log = STORE / 'vt-goldens-build.log'
            run_logged(command, build_log, env, max(args.timeout, 600))
            report['build_log'] = str(build_log)
            report['build_log_sha256'] = sha(build_log)
        for suite, (binary_name, record_prefix, count, _) in SUITES.items():
            # Page-granular history retention depends on the target's page and
            # cache-line layout. Keep an explicit reviewed x86_64 Linux golden.
            golden_name = 'n2-linux-x86_64' if suite == 'n2' and platform.system() == 'Linux' and platform.machine() == 'x86_64' else suite
            golden_path = ROOT / 'tests/vt-golden' / (golden_name + '.json')
            golden_sha = sha(golden_path)
            golden = load_json(golden_path.read_text(encoding='utf-8'))
            if (type(golden.get('schema_version')) is not int or golden['schema_version'] != 1 or
                    type(golden.get('record_count')) is not int or golden['record_count'] != count or
                    golden.get('suite') != suite or type(golden.get('records')) is not list):
                raise RuntimeError('Invalid golden envelope: ' + suite)
            expected = golden['records']
            if len(expected) != count:
                raise RuntimeError('Incomplete golden records: ' + suite)
            binary = prefix / 'bin' / binary_name
            binary_sha = sha(binary)
            log = STORE / ('vt-golden-' + suite + '.log')
            output = run_logged([binary], log, env, args.timeout)
            actual = records_for(output, record_prefix, count)
            actual_path = STORE / ('vt-golden-' + suite + '-actual.json')
            actual_path.write_text(json.dumps(actual, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            checks = completion(output, suite)
            if mismatch := difference(expected, actual):
                diff = STORE / ('vt-golden-' + suite + '-difference.json')
                diff.write_text(json.dumps(mismatch, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
                raise RuntimeError('Golden mismatch; see ' + str(diff))
            if sha(golden_path) != golden_sha or sha(binary) != binary_sha:
                raise RuntimeError('Golden or executable changed during validation: ' + suite)
            item = {'status': 'passed', 'records': count, 'checks': checks,
                    'binary': str(binary), 'binary_sha256': binary_sha,
                    'log': str(log), 'log_sha256': sha(log),
                    'actual_json': str(actual_path), 'actual_sha256': sha(actual_path),
                    'golden': str(golden_path), 'golden_sha256': golden_sha}
            if suite == 'protocol':
                historical = {record['fixture'] for record in actual if record.get('legacy_size_callback') is True}
                if historical != HISTORICAL_SIZE_RECORDS:
                    raise RuntimeError('Five historical size callback markers changed')
                item.update(byte_split_checks=596, historical_size_callback_records=5)
            report['suites'][suite] = item
            print(f'PASS native {suite}: {count} strict golden records, {checks} checks', flush=True)
        if code_hash() != before or sha(Path(__file__)) != report['runner_sha256']:
            raise RuntimeError('Source changed during golden validation; rerun')
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        (STORE / 'vt-goldens.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
