#!/usr/bin/env python3
"""Package only a source-verified development port, preserving existing releases."""
import datetime, json, pathlib, plistlib, shutil, subprocess, tempfile
from verification import ROOT, STORE, code_hash, sha

def main():
    identity=code_hash()
    manifest=json.loads((STORE/'build-native.json').read_text())
    if manifest.get('code_sha256')!=identity:
        raise RuntimeError('Build the current native source before making a port preview')
    for kind, binary in [('unit','letty-unit-tests'),('core','letty-local-check'),('ui','letty')]:
        record=json.loads((STORE/('native-'+kind+'.json')).read_text())
        digest=sha(ROOT/'zig-out/native/bin'/binary)
        if (record.get('status')!='passed' or record.get('code_sha256')!=identity
                or record.get('binary_sha256')!=digest or manifest.get('binaries',{}).get(binary)!=digest
                or record.get('log_sha256')!=sha(STORE/('native-'+kind+'.log'))):
            raise RuntimeError('Run fresh native '+kind+' checks before making a port preview')
    document_record=json.loads((STORE/'native-document-unit.json').read_text())
    if (document_record.get('status')!='passed' or document_record.get('code_sha256')!=identity
            or document_record.get('binary_sha256')!=sha(ROOT/'zig-out/document-native/bin/test')
            or document_record.get('log_sha256')!=sha(STORE/'native-document-unit.log')):
        raise RuntimeError('Run fresh native document checks before making a port preview')
    output=ROOT/'dist';output.mkdir(exist_ok=True)
    target=output/'LettyPort.app'
    with tempfile.TemporaryDirectory(prefix='.port-preview-',dir=output) as name:
        bundle=pathlib.Path(name)/'LettyPort.app';contents=bundle/'Contents';mac=contents/'MacOS';resources=contents/'Resources';mac.mkdir(parents=True);resources.mkdir()
        shutil.copy2(ROOT/'zig-out/native/bin/letty',mac/'LettyPort')
        shutil.copytree(ROOT/'assets/terminal',resources/'terminal')
        shutil.copy2(ROOT/'THIRD_PARTY_NOTICES.md',resources/'THIRD_PARTY_NOTICES.md')
        notices=resources/'licenses';notices.mkdir()
        shutil.copytree(ROOT/'assets/licenses',notices/'ui-assets')
        for folder in (ROOT/'zig-pkg').iterdir():
            if not folder.is_dir():continue
            for pattern in ('LICENSE*','COPYING*','NOTICE*'):
                for license in folder.glob(pattern):
                    if not license.is_file():continue
                    destination=notices/folder.name/license.name
                    destination.parent.mkdir(exist_ok=True)
                    shutil.copy2(license,destination)
        for project,license in [('nanoui','LICENSE'),('ghostty','LICENSE'),('harfbuzz','COPYING')]:
            destination=notices/project/license
            destination.parent.mkdir(exist_ok=True)
            shutil.copy2(ROOT/'vendor'/project/license,destination)
        icon=ROOT/'assets/icons/Letty.icns'
        if icon.exists():shutil.copy2(icon,resources/'Letty.icns')
        info={'CFBundleName':'Letty Port Preview','CFBundleDisplayName':'Letty Port Preview','CFBundleExecutable':'LettyPort','CFBundleIdentifier':'dev.letty.port-preview','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.3.0','CFBundleVersion':'0.3.0','LSMinimumSystemVersion':'13.0','NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,'CFBundleIconFile':'Letty.icns'}
        (contents/'Info.plist').write_bytes(plistlib.dumps(info))
        (resources/'development-port.json').write_text(json.dumps({'source_sha256':identity,'status':'incomplete development port','architecture':'local PTY + native libghostty-vt + native GUI; no daemon or Mirror'},indent=2)+'\n')
        if code_hash()!=identity or sha(mac/'LettyPort')!=manifest['binaries']['letty']:
            raise RuntimeError('Source or executable changed while packaging; rerun verification')
        subprocess.run(['codesign','--force','--deep','--sign','-',str(bundle)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True)
        if target.exists():
            backup=output/('LettyPort.previous-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.app')
            if backup.exists():raise RuntimeError('Existing preview backup retained; choose a fresh output directory')
            target.rename(backup)
        bundle.rename(target)
    print(target)

if __name__=='__main__':main()
