#!/usr/bin/env python3
"""Apply fixed diffs without patch(1)'s automatic reversal heuristics."""
from pathlib import Path
import subprocess,shutil,tempfile
root=Path(__file__).resolve().parents[1]
patches=sorted((root/'patches').glob('nanoui-*.patch'))
# Later diffs can overlap earlier ones. Find the complete applied prefix on
# copies, then validate every remaining patch there before touching vendor.
with tempfile.TemporaryDirectory(prefix='letty-patch-check-') as name:
    snapshot=Path(name)/'snapshot'
    snapshot.mkdir()
    for patch in patches:
        for line in patch.read_text().splitlines():
            if not line.startswith('+++ b/'):continue
            relative=line[6:].split('\t',1)[0]
            source=root/'vendor/nanoui'/relative;target=snapshot/relative
            if source.is_file() and not target.exists():
                target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
    applied=None
    for count in range(len(patches),-1,-1):
        check=Path(name)/str(count)
        shutil.copytree(snapshot,check)
        commands=[(p,'--reverse') for p in reversed(patches[:count])]
        # Starting from the recovered upstream, replay the complete chain.
        commands.extend((p,'--forward') for p in patches)
        for patch,direction in commands:
            result=subprocess.run(['patch','--batch','--force',direction,'-p1','-i',str(patch)],cwd=check,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if result.returncode!=0:break
        else:
            applied=count
            break
        shutil.rmtree(check)
    if applied is None:
        raise SystemExit('Patch chain does not match the locked nanoui source; vendor was not modified')
for patch in patches[applied:]:
    subprocess.run(['patch','--batch','--forward','-p1','-i',str(patch)],cwd=root/'vendor/nanoui',check=True)
