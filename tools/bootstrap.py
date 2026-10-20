#!/usr/bin/env python3
"""Fetch only locked archives. Host tools go in .cache; never touch system Zig."""
import argparse, hashlib, json, os, platform, shutil, subprocess, tarfile, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'deps.lock.json').read_text())
def fetch(url, sha, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists() or hashlib.sha256(dest.read_bytes()).hexdigest() != sha:
        tmp = dest.with_suffix('.download')
        print('Download', url, flush=True)
        with urllib.request.urlopen(url, timeout=120) as r, tmp.open('wb') as w:
            shutil.copyfileobj(r, w)
        if hashlib.sha256(tmp.read_bytes()).hexdigest() != sha:
            tmp.unlink(); raise SystemExit('SHA256 mismatch: ' + url)
        tmp.replace(dest)
def unpack(archive, dest, prefix):
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as t:
        for m in t.getmembers():
            parts = Path(m.name).parts
            if not parts or parts[0] != prefix or '..' in parts or Path(m.name).is_absolute():
                raise SystemExit('Unsafe archive member: ' + m.name)
        t.extractall(dest)
def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--sources-only', action='store_true'); args=ap.parse_args()
    (ROOT/'vendor').mkdir(exist_ok=True)
    for name,s in LOCK['sources'].items():
        dest=ROOT/'vendor'/name
        if dest.exists():
            marker=dest/'.letty-revision'
            if not marker.exists() or marker.read_text().strip()!=s['revision']:
                raise SystemExit('Unrecognized vendor directory: '+str(dest))
            continue
        archive=ROOT/'.cache/upstream'/(name+'.tar.gz'); fetch(s['url'],s['sha256'],archive)
        temp=ROOT/'.cache/unpack'/name
        if temp.exists(): shutil.rmtree(temp)
        unpack(archive,temp,name+'-'+s['revision'])
        shutil.move(str(temp/(name+'-'+s['revision'])),str(dest))
        (dest/'.letty-revision').write_text(s['revision']+'\n')
    subprocess.run(['python3',str(ROOT/'tools/patch_nanoui.py')],check=True)
    subprocess.run(['python3',str(ROOT/'tools/patch_ghostty.py')],check=True)
    from font_assets import prepare
    prepare(fetch)
    if args.sources_only: return
    host={'Darwin':'macos','Linux':'linux'}[platform.system()]
    arch={'arm64':'aarch64','aarch64':'aarch64','x86_64':'x86_64'}[platform.machine()]
    key=arch+'-'+host
    for v in ('0.17.0',):
        s=LOCK['zig'][v].get(key)
        if not s: raise SystemExit('Unsupported build host: '+key)
        name='zig-'+key+'-'+v; archive=ROOT/'.cache/tools'/(name+'.tar.xz'); dest=ROOT/'.cache/tools'/name
        if not dest.exists():
            fetch(s['tarball'],s['shasum'],archive); unpack(archive, dest.parent, name)
        actual=subprocess.check_output([str(dest/'zig'),'version'],text=True).strip()
        if actual!=v: raise SystemExit('Wrong Zig: '+actual)
        print('ZIG='+str(dest/'zig'))
if __name__=='__main__': main()
