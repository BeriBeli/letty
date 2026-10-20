#!/usr/bin/env python3
"""Package source-bound scoped acceptance for the shared integrated release."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
from verification import ROOT, STORE, code_hash, release_evidence, sha


def main():
    evidence = release_evidence('native')
    identity = code_hash()
    gate_path = STORE / 'native-release-gate.json'
    gate = json.loads(gate_path.read_text())
    runtime_refs = []
    mac_archive = ROOT / 'dist' / ('Letty-macos-arm64-native-zig-' + identity[:12] + '.zip')
    if mac_archive.is_file():
        runtime_refs.append({'file': mac_archive.name, 'sha256': sha(mac_archive)})
    for info_path in (ROOT / 'dist').glob('letty-linux-x86_64-el7-zig-*/build-info.json'):
        info = json.loads(info_path.read_text())
        if info.get('verification', {}).get('code_sha256') == identity:
            for archive in (info_path.parent.with_suffix('.tar.gz'), ROOT / 'dist' / ('letty-source-' + info['source_sha256'][:12] + '.tar.gz')):
                if not archive.is_file():
                    raise RuntimeError('Missing shared runtime/source archive: ' + str(archive))
                runtime_refs.append({'file': archive.name, 'sha256': sha(archive)})
    if len(runtime_refs) != 3:
        raise RuntimeError('Package the current macOS, Linux and source archives first')
    source = ROOT / 'dist' / ('letty-feature-evidence-' + identity[:12])
    source.mkdir(parents=True, exist_ok=True)
    for name in ('native-release-gate.json', 'build-native.json', 'build-native-portable.json', 'build-linux.json',
                 'native-ui.log', 'native-portable-ui.log'):
        shutil.copy2(STORE / name, source / name)
    for directory in ('feature-components',):
        shutil.copytree(STORE / directory, source / directory, dirs_exist_ok=True)
    # Preserve raw measurements as well as their hashes. Executables and source
    # remain in the referenced runtime/source archives rather than duplicated.
    material_index = []
    for name, digest in sorted(gate['materials_sha256'].items()):
        path = Path(name)
        item = {'original_path': name, 'sha256': digest}
        if path.is_relative_to(ROOT) and path.suffix in ('.json', '.log', '.png', '.txt', '.sha256'):
            relative = Path('gate-materials') / path.relative_to(ROOT)
            target = source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            item['bundled_path'] = relative.as_posix()
        else:
            item['basis'] = 'source/runtime archives or original toolchain/recovery executable; see original path and digest'
        material_index.append(item)
    (source / 'materials-index.json').write_text(json.dumps(material_index, indent=2) + '\n')
    shutil.copy2(STORE / 'nanoui-final-patch-replay.json', source / 'nanoui-patch-replay.json')
    for batch in ('M9', 'M10', 'M11', 'SIDEBAR', 'SETTINGS', 'PREVIEW'):
        scoped = {'status': 'passed', 'batch': batch, 'code_sha256': identity,
                  'release': 'same frozen integrated binary for every batch; no separate historical builds',
                  'shared_runtime_archives': runtime_refs,
                  'gate_sha256': sha(gate_path), 'target_acceptance': 'pending',
                  'native_binary_sha256': gate['backends']['zig']['binaries']['letty'],
                  'portable_binary_sha256': gate['rendering']['portable_binary_sha256'],
                  'linux_binary_sha256': gate['linux']['binaries']['letty'],
                  'application': {prefix: result['batches'][batch] for prefix, result in evidence['feature_acceptance']['ui'].items()},
                  'components': evidence['feature_acceptance']['components'],
                  'capability_document': 'docs/' + (batch.lower() + '-capabilities.md' if batch.startswith('M') else 'sidebar-validation.md' if batch == 'SIDEBAR' else 'file-markdown-preview.md' if batch == 'PREVIEW' else 'settings-window.md')}
        (source / (batch + '.json')).write_text(json.dumps(scoped, indent=2) + '\n')
        if batch.startswith('M') or batch == 'PREVIEW':
            review = ROOT / 'dist' / ('letty-' + batch + '-review-' + identity[:12])
            review.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / (batch + '.json'), review / 'acceptance.json')
            shutil.copy2(ROOT / scoped['capability_document'], review / 'capabilities.md')
            for prefix in ('native', 'native-portable'):
                output = (STORE / (prefix + '-ui.log')).read_text()
                start = output.index('BATCH_BEGIN ' + batch + '\n')
                marker = 'Feature checks passed: ' + batch + '\n'
                end = output.index(marker, start) + len(marker)
                (review / (prefix + '.log')).write_text(output[start:end])
            (review / 'README.txt').write_text('Scoped review bundle. Use the shared integrated runtime archives listed in acceptance.json. All batches use the same frozen binary. Target OS services and CentOS/VDI remain pending.\n')
            (review / 'SHA256SUMS').write_text(''.join(sha(path) + '  ' + path.name + '\n' for path in sorted(review.iterdir()) if path.name != 'SHA256SUMS'))
            archive = review.with_suffix('.tar.gz')
            with tarfile.open(archive, 'w:gz') as out:
                out.add(review, arcname=review.name)
            archive.with_name(archive.name + '.sha256').write_text(sha(archive) + '  ' + archive.name + '\n')
    sums = [sha(path) + '  ' + path.relative_to(source).as_posix() for path in sorted(source.rglob('*')) if path.is_file() and path.name != 'SHA256SUMS']
    (source / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')
    archive = source.with_suffix('.tar.gz')
    with tarfile.open(archive, 'w:gz') as out:
        out.add(source, arcname=source.name)
    archive.with_name(archive.name + '.sha256').write_text(sha(archive) + '  ' + archive.name + '\n')
    print(archive)


if __name__ == '__main__':
    main()
