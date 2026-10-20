"""Validate source-bound preview measurements from their raw runtime logs."""
import re
from pathlib import Path
from verification import ROOT, STORE, sha


def preview_performance(identity, material, read, require, equal):
    path = STORE / 'preview-performance/report.json'
    report = read(path)
    component = read(STORE / 'feature-components/report.json')
    require(report.get('status') == 'passed' and report.get('code_sha256') == identity,
            'Missing current preview performance execution')
    expected = {'src/preview_check.zig', 'tools/preview-check/build.zig',
                'tools/preview-check/build.zig.zon', 'tools/verify-preview-performance.py'}
    expected.update(p.relative_to(ROOT).as_posix() for p in (ROOT / 'src/preview').glob('*.zig'))
    require(set(report.get('sources', {})) == expected, 'Incomplete preview measurement source guard')
    for name, digest in report['sources'].items():
        require(sha(material(ROOT / name)) == digest, 'Preview measurement source changed')
    require(set(report.get('binaries', {})) == {'native', 'portable'}, 'Missing preview renderer measurements')
    for item in report['binaries'].values():
        require(sha(material(item['path'])) == item['sha256'] == component['binaries'].get(item['path']),
                'Preview measurement executable differs from component execution')
    measurements, seen = report.get('measurements', []), set()
    require(len(measurements) == 6, 'Expected six complete preview performance processes')
    for measurement in measurements:
        key = measurement.get('renderer'), measurement.get('repetition')
        require(key[0] in ('native', 'portable') and key[1] in (1, 2, 3) and key not in seen
                and measurement.get('returncode') == 0, 'Invalid preview performance schedule')
        seen.add(key)
        log = material(measurement['log'])
        require(sha(log) == measurement['log_sha256'], 'Preview performance log changed')
        output = log.read_text()
        require(not re.search(r'^FAIL(?:\s|:)|panic:|leaked \[|error\(gpa\):', output, re.M),
                'Preview performance runtime failure')
        import json
        rows = [json.loads(s.removeprefix('PREVIEW_PERF ')) for s in output.splitlines() if s.startswith('PREVIEW_PERF ')]
        require(equal(rows, measurement.get('rows')) and len(rows) == 2
                and {r['case'] for r in rows} == {'plain_utf8_10000', 'markdown_gfm_1000'},
                'Preview raw measurements differ from report')
        for row in rows:
            require(row['scope'] == 'tester_without_window' and row['warm_frames'] == 100 and row['scroll_frames'] == 60
                    and row['prepare_calls'] == 1 and row['idle_wall_us'] >= 2_000_000
                    and row['idle_frame_count'] == row['idle_draw_count'] == 0
                    and row['file_bytes'] == row['source_bytes'] and row['scroll_y'] > 0,
                    'Incomplete preview performance workload')
        rss = re.findall(r'^\s*(\d+)\s+maximum resident set size\s*$', output, re.M)
        require(len(rss) == 1 and int(rss[0]) == measurement['process_peak_rss_bytes'] > 0,
                'Preview raw RSS differs from report')
    return {'status': 'passed', 'processes': 6, 'document_measurements': 12, 'report_sha256': sha(path),
            'scope': 'production file worker and offscreen Tester; process peak RSS includes both sequential cases; no PTY/GPU/window/VDI/PSS claim'}
