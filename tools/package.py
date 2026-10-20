#!/usr/bin/env python3
import argparse,datetime,hashlib,json,os,platform,shutil,subprocess,tarfile,io
from pathlib import Path
from verification import release_evidence,feature_batches,dependency_notices,local_preview_evidence,STORE
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def source_files():
    files=[ROOT/'build.zig',ROOT/'build.zig.zon',ROOT/'deps.lock.json',ROOT/'README.md',ROOT/'terminal-development-plan.md',ROOT/'.gitignore']
    for d in ['src','tools','script','docs','patches','config','assets','tests','.github','.codex/environments']:
        # Preserve staged authored modules too. Their presence is not a claim
        # of GUI integration; tested reachability remains bound by code_sha256.
        files.extend(p for p in (ROOT/d).rglob('*') if p.is_file() and not {'__pycache__','zig-pkg','.zig-cache','.cache','zig-out','.DS_Store'}.intersection(p.parts) and not p.name.endswith('.pyc'))
    return sorted(files)
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--ci',action='store_true');ap.add_argument('--local-preview',action='store_true');args=ap.parse_args()
    if args.ci and args.local_preview:raise SystemExit('CI distribution and local preview are separate modes')
    if args.ci and os.environ.get('GITHUB_ACTIONS')!='true':raise SystemExit('--ci is reserved for a successful GitHub Actions job')
    evidence=local_preview_evidence() if args.local_preview else release_evidence("linux")
    if args.local_preview:
        manifest=json.loads((STORE/'build-linux.json').read_text())
        actual={p.name:sha(p) for p in (ROOT/'zig-out/linux/bin').iterdir() if p.is_file()}
        if manifest.get('code_sha256')!=evidence['code_sha256'] or manifest.get('vt_backend')!='zig' or manifest.get('binaries')!=actual:raise RuntimeError('Build current Linux preview binaries first')
        evidence['feature_acceptance']={'status':'local-preview','scope':'current native application tests; complete release gate not applied','application_ui':evidence['checks']['native-ui']}
    files=source_files();snapshot={p:p.read_bytes() for p in files};digest=hashlib.sha256()
    for p in files:digest.update(str(p.relative_to(ROOT)).encode());digest.update(snapshot[p])
    source_hash=digest.hexdigest()
    commit=os.environ.get('GITHUB_SHA')
    if not commit:
        r=subprocess.run(['git','rev-parse','HEAD'],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        commit=r.stdout.strip() if r.returncode==0 else None
    package_id='0.1.0-dev-'+source_hash[:12]
    name='letty-linux-x86_64-el7-'+evidence['vt_backend']+'-'+source_hash[:12]
    dist=ROOT/'dist';dist.mkdir(exist_ok=True);dest=dist/name
    if dest.exists():shutil.rmtree(dest)
    (dest/'bin').mkdir(parents=True)
    binaries=ROOT/'zig-out/linux/bin'
    strip=shutil.which('llvm-strip') or shutil.which('strip')
    if not strip:raise SystemExit('llvm-strip or strip required')
    executables=['letty','letty-check','letty-probe','letty-unit-tests','letty-vt-replay','letty-vt-n2','letty-vt-protocol']
    if evidence['vt_backend']=='zig':executables.extend(['letty-vt-boundary','letty-vt-graphics'])
    for exe in executables:
        shutil.copy2(binaries/exe,dest/'bin'/exe)
        subprocess.run([strip,'--strip-debug',str(dest/'bin'/exe)],check=True)
    for folder in ['config','docs']:shutil.copytree(ROOT/folder,dest/folder)
    shutil.copytree(ROOT/'assets/icons/hicolor',dest/'share/icons/hicolor')
    shutil.copytree(ROOT/'assets/shell-integration',dest/'share/letty/shell-integration')
    (dest/'tools').mkdir()
    for script in ['test-centos.sh','memory-sample.sh','workload.sh','install-user.sh','rollback-user.sh']:shutil.copy2(ROOT/'tools'/script,dest/'tools'/script)
    shutil.copy2(ROOT/'README.md',dest/'README.md')
    shutil.copy2(ROOT/'deps.lock.json',dest/'deps.lock.json')
    (dest/'licenses').mkdir()
    for vendor in ['nanoui','ghostty']:
        for p in (ROOT/'vendor'/vendor).glob('LICENSE*'):
            if p.is_file():shutil.copy2(p,dest/'licenses'/(vendor+'-'+p.name))
    for notice,relative in dependency_notices():
        target=dest/'licenses'/relative
        target.parent.mkdir(exist_ok=True);shutil.copy2(notice,target)
    subprocess.run(['python3',str(ROOT/'tools/audit-elf.py'),str(dest),'--output',str(dest/'abi-audit.json')],check=True)
    info={'package_id':package_id,'vt_backend':evidence['vt_backend'],'feature_batches':feature_batches(),'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_sha256':source_hash,'git_commit':commit,'target':'x86_64-linux.3.10-gnu.2.17','cpu':'baseline','zig':'0.17.0','optimize':'ReleaseSafe','simd':False,'build_host':platform.platform(),'github_run':os.environ.get('GITHUB_RUN_ID'),'runner_image':os.environ.get('ImageVersion'),'dependencies':json.loads((ROOT/'deps.lock.json').read_text())['sources'],'verification':dict(evidence,static_abi='passed',ci='passed' if args.ci else 'not_run',centos='not_run',vdi_ime='not_run',performance_comparison='not_measured')}
    info['shaping'] = json.loads((ROOT/'.cache/shaper/linux/build-info.json').read_text())
    shutil.copy2(ROOT/'tools/shaper-dependency.json', dest/'shaper-dependency.json')
    (dest/'feature-acceptance.json').write_text(json.dumps(evidence['feature_acceptance'],indent=2)+'\n')
    (dest/'build-info.json').write_text(json.dumps(info,indent=2)+'\n')
    if evidence['vt_backend']=='zig' and not args.local_preview:
        gate=ROOT/'.cache/verification/native-release-gate.json'
        shutil.copy2(gate if gate.exists() else ROOT/'docs/native-release-acceptance.json',dest/'native-release-gate.json')
        info['verification']['performance_comparison']='measured and reviewed on macOS; target Linux unmeasured'
        (dest/'build-info.json').write_text(json.dumps(info,indent=2)+'\n')
    manifest=[]
    for p in sorted(dest.rglob('*')):
        if p.is_file():manifest.append(sha(p)+'  '+p.relative_to(dest).as_posix())
    (dest/'SHA256SUMS').write_text('\n'.join(manifest)+'\n')
    archive=dist/(name+'.tar.gz')
    with tarfile.open(archive,'w:gz') as t:t.add(dest,arcname=name)
    # Clean authored source, lock, patches and CI; bootstrap rehydrates upstream.
    source=dist/('letty-source-'+source_hash[:12]+'.tar.gz')
    with tarfile.open(source,'w:gz') as t:
        for p in files:
            info=tarfile.TarInfo('letty-source/'+p.relative_to(ROOT).as_posix());info.size=len(snapshot[p]);info.mode=p.stat().st_mode & 0o777;info.mtime=int(p.stat().st_mtime);t.addfile(info,io.BytesIO(snapshot[p]))
    (dist/'SHA256SUMS').write_text(sha(archive)+'  '+archive.name+'\n'+sha(source)+'  '+source.name+'\n')
    for item in [archive,source]:item.with_name(item.name+'.sha256').write_text(sha(item)+'  '+item.name+'\n')
    print('Runtime:',archive);print('Source:',source)
if __name__=='__main__':main()
