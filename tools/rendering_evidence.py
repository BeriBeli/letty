"""M8 rendering proof: current portable binary, font UI, real CPU pixels."""
import json
from pathlib import Path
from verification import ROOT, STORE, sha


def rendering(identity, manifest, suites, material, read, require, equal):
    prefix = ROOT / 'zig-out/native-portable'
    build = manifest(prefix, identity)
    require(build.get('configuration', {}).get('portable') is True, 'Missing real portable renderer build')
    checked = suites(prefix, build, identity)
    modes, fonts, screenshots = {}, {}, {}
    for name, backend in [('native', 'standard'), ('native-portable', 'portable')]:
        output = material(STORE / (name + '-ui.log')).read_text()
        require('FONT_MODE upstream-default-no-2027-sequence ' in output and 'FONT_MODE 2027-explicitly-enabled ' in output,
                'Missing actual grapheme mode coverage: ' + name)
        require('FONT_CAPABILITY Maple-calt actual-glyph-substitution-covered' in output,
                'Missing actual installed Maple glyph substitution: ' + name)
        rows = [line for line in output.splitlines() if line.startswith('FONT_CAPABILITY ')]
        for label in ('ASCII', 'CJK', 'combining', 'Nerd', 'bold-italic', 'box', 'ZWJ', 'VS'):
            require(sum(line.startswith('FONT_CAPABILITY ' + label + ' ') for line in rows) == 1,
                    'Missing explicit font capability: ' + name + '/' + label)
        modes[name] = [line for line in output.splitlines() if line.startswith('FONT_MODE ')]
        fonts[name] = rows
        for scene in ('default-mode', 'scene', 'cursor-boundary', 'sgr', 'reload-scale', 'feature-on', 'feature-off'):
            image = material(ROOT / '.cache/test-logs' / ('font-' + scene + '-' + backend + '.png'))
            require(image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid font image')
            screenshots[image.name] = sha(image)
    report = read(STORE / 'm8-cpu-damage/report.json')
    require(report.get('status') == 'passed' and report.get('code_sha256') == identity
            and report.get('binary_sha256') == build['binaries']['letty']
            and report.get('verifier_sha256') == sha(material(ROOT / 'tools/verify-cpu-damage.py'))
            and report.get('comparisons') == 288, 'Stale or incomplete CPU rendering proof')
    records = report.get('records', [])
    phases = ('idle_before', 'output', 'scroll', 'search', 'selection', 'cursor', 'overlay', 'idle_after')
    require(len(records) == 24 and len(report.get('commands', [])) == 3, 'Missing CPU pane/phase records')
    for index, panes in enumerate((1, 4, 16)):
        log = material(STORE / 'm8-cpu-damage' / (str(panes) + '-panes.log'))
        command = report['commands'][index]
        require(command.get('log_sha256') == sha(log) and command.get('exit_code') == 0, 'CPU log identity mismatch')
        actual = [json.loads(line.removeprefix('CPU_DAMAGE_PERF ')) for line in log.read_text().splitlines() if line.startswith('CPU_DAMAGE_PERF ')]
        expected = records[index * 8:(index + 1) * 8]
        require(equal(actual, expected) and tuple(row.get('phase') for row in actual) == phases, 'CPU log/report differs')
        for row in actual:
            require(row.get('panes') == panes and row.get('status') == 'passed' and row.get('frames') == 12
                    and row.get('pixels_equal') is True and row.get('x11_presentation') == 'not measured'
                    and sum(row.get(name, -100) for name in ('none_frames', 'full_frames', 'rect_frames')) == 12,
                    'Incomplete real CPU sample')
            if row['phase'] == 'cursor':
                require(row.get('cursor_visible_frames') == 12 and row['none_frames'] == 0, 'CPU cursor phase was not visible')
            if row['phase'].startswith('idle_'):
                require(row['none_frames'] == 12 and row.get('dirty_cleared_pixels') == 0, 'Static CPU pixels changed')
    return {'status': 'passed', 'portable_binary_sha256': build['binaries']['letty'], 'portable_suites': checked,
            'cpu_comparisons': 288, 'cpu_report_sha256': sha(material(STORE / 'm8-cpu-damage/report.json')),
            'font_modes': modes, 'font_capabilities': fonts, 'screenshots': screenshots,
            'scope': 'actual offscreen font and full/damage CPU pixels; GTK/X11/VDI presentation pending'}
