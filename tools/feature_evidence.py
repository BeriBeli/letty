"""Verify M9/M10/M11 evidence within current complete application UI logs."""
import json
from pathlib import Path
import re
from verification import ROOT, STORE, sha


def partition(output, require):
    result, active = {}, None
    for line in output.splitlines():
        if line.startswith('BATCH_BEGIN '):
            name = line.removeprefix('BATCH_BEGIN ')
            require(active is None and name in ('M9', 'M10', 'M11', 'SIDEBAR', 'SETTINGS', 'PREVIEW') and name not in result,
                    'Duplicate/nested feature batch')
            active = name
            result[name] = []
        elif line.startswith('BATCH_END '):
            require(active == line.removeprefix('BATCH_END '), 'Unmatched feature completion')
            active = None
        elif line.startswith('PASS UI ') and active:
            result[active].append(line.removeprefix('PASS UI '))
    require(active is None and set(result) == {'M9', 'M10', 'M11', 'SIDEBAR', 'SETTINGS', 'PREVIEW'}
            and all(result.values()), 'Incomplete scoped feature regression')
    return result


def features(identity, material, read, require, equal):
    report = {'status': 'passed', 'code_sha256': identity, 'ui': {},
              'scope': 'current native/portable hidden application; external OS and target-machine acceptance pending'}
    images = []
    for prefix in ('native', 'native-portable'):
        build = read(STORE / ('build-' + prefix + '.json'))
        record = read(STORE / (prefix + '-ui.json'))
        log = material(STORE / (prefix + '-ui.log'))
        require(build.get('code_sha256') == record.get('code_sha256') == identity
                and record.get('status') == 'passed'
                and record.get('binary_sha256') == build['binaries']['letty']
                and record.get('log_sha256') == sha(log), 'Stale feature application evidence')
        output = log.read_text()
        screenshots = record.get('preview_screenshots', {})
        require(set(screenshots) == {str(ROOT / '.cache/test-logs' / ('preview-application-' + prefix + '-' + scene + '.png'))
                                    for scene in ('light', 'sidebar-narrow')}, 'Incomplete application preview screenshots')
        for name, digest in screenshots.items():
            require(sha(material(name)) == digest, 'Application preview screenshot changed')
        batches = partition(output, require)
        required = {'M9': ('incomplete direct chunk', '24 protocol revisions', 'independent window TextSystems'),
                    'M10': ('OSC52', 'Inspector', 'theme', 'native drop'),
                    'M11': ('Quick Terminal', 'Host service', 'AX'),
                    'SIDEBAR': ('sidebar', 'provider'), 'SETTINGS': ('Settings',), 'PREVIEW': ('Preview',)}
        for name, fragments in required.items():
            for fragment in fragments:
                require(any(fragment in line for line in batches[name]), 'Missing feature boundary: ' + name + '/' + fragment)
        rows = [json.loads(line.removeprefix('M9_UI ')) for line in output.splitlines() if line.startswith('M9_UI ')]
        require(len(rows) == 1 and rows[0].get('comparison_scene') == 'two-pane-red-green-384x120-bgra'
                and rows[0].get('pixels') == 'actual Tester.render'
                and rows[0].get('checks') == sum(line.startswith('M9 ') for line in batches['M9'])
                and re.fullmatch('[0-9a-f]+', rows[0].get('raster_wyhash', '')), 'Missing protocol pixel comparison')
        images.append(rows[0])
        material(ROOT / rows[0]['screenshot'])
        report['ui'][prefix] = {'log_sha256': sha(log), 'binary_sha256': record['binary_sha256'],
                                'batches': {name: {'checks': len(lines), 'assertions': lines} for name, lines in batches.items()},
                                'graphics': rows[0]}
    require(equal(images[0]['comparison_scene'], images[1]['comparison_scene'])
            and equal(images[0]['raster_wyhash'], images[1]['raster_wyhash']), 'Metal readback and CPU Kitty pixels differ')
    component_path = STORE / 'feature-components/report.json'
    component = read(component_path)
    require(component.get('status') == 'passed' and component.get('code_sha256') == identity
            and component.get('runner_sha256') == sha(material(ROOT / 'tools/verify-feature-components.py')),
            'Missing current native component execution')
    require(set(component.get('checks', {})) == {'image-sampler', 'config-edit', 'ax-appkit', 'ax-transaction', 'ax-adapter', 'navigation-provider', 'navigation-login', 'settings-native', 'settings-portable', 'preview-loader', 'preview-native', 'preview-portable'},
            'Incomplete native component set')
    for name, digest in component.get('sources', {}).items():
        require(sha(material(ROOT / name)) == digest, 'Component source changed')
    for name, digest in component.get('binaries', {}).items():
        require(sha(material(name)) == digest, 'Component binary changed')
    patterns = {'image-sampler': (r'All (\d+) tests passed\.', None),
                'config-edit': (r'All (\d+) native config edit checks passed\.', 'PASS CONFIG EDIT NATIVE '),
                'ax-appkit': (r'PASS AX APPKIT NATIVE (\d+) checks;', 'PASS AX AppKit: '),
                'ax-transaction': (r'All (\d+) tests passed\.', None),
                'ax-adapter': (r'All (\d+) tests passed\.', None),
                'navigation-provider': (r'NAV_PROVIDER_NATIVE \{"checks":(\d+),', 'PASS NAV_PROVIDER '),
                'navigation-login': (r'NAV_PROVIDER_LOGIN_NATIVE \{"checks":(\d+),', 'PASS NAV_PROVIDER_LOGIN '),
                'settings-native': (r'Settings acceptance: (\d+) checks passed', 'PASS settings '),
                'settings-portable': (r'Settings acceptance: (\d+) checks passed', 'PASS settings '),
                'preview-loader': (r'PREVIEW_LOADER_NATIVE \{"checks":(\d+),', 'PASS PREVIEW_LOADER '),
                'preview-native': (r'PREVIEW checks=(\d+)', 'PASS preview '),
                'preview-portable': (r'PREVIEW checks=(\d+)', 'PASS preview ')}
    observed = {}
    preview_pixels = []
    for command in component.get('commands', []):
        log = material(command['log'])
        require(command.get('returncode') == 0 and command.get('log_sha256') == sha(log), 'Component command/log mismatch')
        output = log.read_text()
        require(not re.search(r'^FAIL(?:\s|:)|panic:|leaked \[|error\(gpa\):', output, re.M), 'Component runtime failure')
        if command['label'] in ('preview-native', 'preview-portable'):
            pixels = [json.loads(line.removeprefix('PREVIEW_PIXEL ')) for line in output.splitlines() if line.startswith('PREVIEW_PIXEL ')]
            require(len(pixels) == 1 and pixels[0].get('scene') == 'opaque-png-64x32'
                    and pixels[0].get('width') == 80 and pixels[0].get('height') == 48
                    and re.fullmatch('[0-9a-f]{16}', pixels[0].get('hash', '')), 'Missing preview actual PNG pixel scene')
            preview_pixels.append(pixels[0])
        if command['label'] in patterns:
            pattern, prefix = patterns[command['label']]
            matches = re.findall(pattern, output)
            require(len(matches) == 1, 'Component completion missing')
            count = int(matches[0])
            require(not prefix or sum(line.startswith(prefix) for line in output.splitlines()) == count,
                    'Component assertion count mismatch')
            require(command['label'] not in observed, 'Duplicate component execution')
            observed[command['label']] = count
    require(equal(observed, component['checks']), 'Component summary differs from actual logs')
    screenshots = component.get('screenshots', {})
    expected = {str(STORE / 'feature-components' / ('preview-' + renderer + '-' + scene + '.png'))
                for renderer in ('native', 'portable') for scene in ('rendered', 'dark-narrow', 'local-image', 'stale-error')}
    require(set(screenshots) == expected, 'Incomplete preview component screenshots')
    for name, digest in screenshots.items():
        path = material(name)
        require(path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n') and sha(path) == digest,
                'Preview screenshot changed')
    require(len(preview_pixels) == 2 and equal(preview_pixels[0], preview_pixels[1]), 'Preview native/portable PNG pixels differ')
    report['preview_pixels'] = preview_pixels[0]
    report['components'] = {'report_sha256': sha(component_path), 'checks': observed,
                            'scope': component['scope']}
    return report
