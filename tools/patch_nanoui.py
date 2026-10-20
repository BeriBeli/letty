#!/usr/bin/env python3
"""Apply fixed diffs without patch(1)'s automatic reversal heuristics."""
from pathlib import Path
import subprocess,shutil,tempfile
root=Path(__file__).resolve().parents[1]
patches=sorted((root/'patches').glob('nanoui-*.patch'))
# Later diffs may intentionally modify a file introduced by an earlier diff.
# Verify the complete reverse chain on copies before deciding it is already applied.
with tempfile.TemporaryDirectory(prefix='letty-patch-check-') as name:
    check=Path(name)
    for patch in patches:
        for line in patch.read_text().splitlines():
            if not line.startswith('+++ b/'):continue
            relative=line[6:].split('\t',1)[0]
            source=root/'vendor/nanoui'/relative;target=check/relative
            if source.is_file() and not target.exists():
                target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
    complete=True
    for patch in reversed(patches):
        result=subprocess.run(['patch','--batch','--force','--reverse','-p1','-i',str(patch)],cwd=check,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if result.returncode!=0:complete=False;break
    if complete:raise SystemExit(0)
for patch in patches:
    base=['patch','--batch','-p1','-i',str(patch)]
    reverse=subprocess.run(base+['--force','--reverse','--dry-run'],cwd=root/'vendor/nanoui',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if reverse.returncode==0:
        continue
    forward=subprocess.run(base+['--forward','--dry-run'],cwd=root/'vendor/nanoui',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if forward.returncode!=0:
        raise SystemExit('Patch does not match the locked nanoui source: '+patch.name)
    subprocess.run(base+['--forward'],cwd=root/'vendor/nanoui',check=True)
