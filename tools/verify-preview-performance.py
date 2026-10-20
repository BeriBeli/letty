#!/usr/bin/env python3
"""Measure production preview workers and offscreen readers; excludes real windows, PTYs, GPU/VDI and PSS."""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
from verification import ROOT, STORE, code_hash, sha


def main():
    identity = code_hash()
    sources = [ROOT / 'src/preview_check.zig', ROOT / 'tools/preview-check/build.zig',
               ROOT / 'tools/preview-check/build.zig.zon', Path(__file__).resolve()]
    sources += sorted((ROOT / 'src/preview').glob('*.zig'))
    guards = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    directory = STORE / 'preview-performance'
    directory.mkdir(parents=True, exist_ok=True)
    report = {'status': 'failed', 'code_sha256': identity, 'sources': guards,
              'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': __doc__, 'measurements': [], 'binaries': {}}
    try:
        component = json.loads((STORE / 'feature-components/report.json').read_text())
        if component.get('status') != 'passed' or component.get('code_sha256') != identity:
            raise RuntimeError('Current preview component build required')
        for renderer in ('native', 'portable'):
            binary = STORE / 'feature-components' / ('preview-' + renderer) / 'bin/letty-preview-check'
            digest = sha(binary)
            if component['binaries'].get(str(binary)) != digest:
                raise RuntimeError('Component executable changed')
            report['binaries'][renderer] = {'path': str(binary), 'sha256': digest}
            for repetition in range(1, 4):
                command = ['/usr/bin/time', '-lp', str(binary), '--perf']
                result = subprocess.run(command, cwd=ROOT, env=dict(os.environ), stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=90)
                log = directory / f'{renderer}-{repetition}.log'
                log.write_bytes(result.stdout)
                output = result.stdout.decode()
                if result.returncode or re.search(r'^FAIL(?:\s|:)|panic:|leaked \[|error\(gpa\):', output, re.M):
                    raise RuntimeError('Preview performance failed: ' + str(log))
                rows = [json.loads(s.removeprefix('PREVIEW_PERF ')) for s in output.splitlines() if s.startswith('PREVIEW_PERF ')]
                if {r['case'] for r in rows} != {'plain_utf8_10000', 'markdown_gfm_1000'} or len(rows) != 2:
                    raise RuntimeError('Missing preview measurements')
                for row in rows:
                    if (row['scope'] != 'tester_without_window' or row['warm_frames'] != 100 or row['scroll_frames'] != 60
                            or row['idle_frame_count'] != 0 or row['idle_draw_count'] != 0
                            or row['idle_wall_us'] < 2_000_000 or row['prepare_calls'] != 1
                            or row['file_bytes'] != row['source_bytes'] or row['scroll_y'] <= 0):
                        raise RuntimeError('Incomplete preview workload')
                rss = re.findall(r'^\s*(\d+)\s+maximum resident set size\s*$', output, re.M)
                if len(rss) != 1 or int(rss[0]) <= 0:
                    raise RuntimeError('Missing process RSS')
                report['measurements'].append({'renderer': renderer, 'repetition': repetition,
                    'command': command, 'returncode': result.returncode, 'log': str(log), 'log_sha256': sha(log),
                    'process_peak_rss_bytes': int(rss[0]), 'rows': rows})
                print('PASS PREVIEW PERF', renderer, repetition, 'RSS', rss[0], flush=True)
        if code_hash() != identity or any(sha(ROOT / p) != digest for p, digest in guards.items()):
            raise RuntimeError('Preview source changed while measuring')
        if any(sha(Path(item['path'])) != item['sha256'] for item in report['binaries'].values()):
            raise RuntimeError('Preview executable changed while measuring')
        report['status'] = 'passed'
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        (directory / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
