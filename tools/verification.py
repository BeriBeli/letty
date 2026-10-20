"""Evidence bound to tested code and executable; package counts are never constants."""
import datetime,hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
STORE=ROOT/'.cache/verification'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def code_paths():
    # Only reachable modules / linked C inputs belong to this build; parallel
    # agents may stage unrelated modules which are not integrated yet.
    paths=set([ROOT/'build.zig',ROOT/'build.zig.zon',ROOT/'deps.lock.json'])
    paths.update(ROOT/name for name in ('tools/build-shaper.py','tools/verify-cpu-damage.py','tools/shaper-dependency.json','src/portable_shaper.c','src/portable_shaper.h'))
    pending=[ROOT/'src'/name for name in ['app.zig','check.zig','probe.zig','unit_tests.zig','vt_replay.zig','vt_native_boundary.zig','vt_protocol_replay.zig','vt_n2_replay.zig','vt_graphics_check.zig']]
    pending.extend(ROOT/name for name in re.findall(r'"(src/[^"\n]+\.c)"',(ROOT/'build.zig').read_text()))
    while pending:
        p=pending.pop()
        if p in paths or not p.is_file():continue
        paths.add(p)
        if p.suffix not in ('.zig', '.c', '.h'): continue
        text=p.read_text()
        imports=re.findall(r'@(?:import|embedFile)\("([^"\n]+)"\)',text) if p.suffix=='.zig' else re.findall(r'#include\s+"([^"\n]+)"',text)
        pending.extend((p.parent/name).resolve() for name in imports if (p.parent/name).is_file())
    # Vendor code can change before its managed patch is refreshed. Include
    # actual framework and engine inputs so concurrent raw edits invalidate every guard.
    for folder in ['src/platform','vendor/nanoui/src','vendor/ghostty/src','patches','config','assets','tests/vt-golden','src/ui_icons']:
        paths.update(p for p in (ROOT/folder).rglob('*') if p.is_file())
    return paths
def code_hash():
    h=hashlib.sha256()
    for p in sorted(code_paths()):h.update(p.relative_to(ROOT).as_posix().encode());h.update(p.read_bytes())
    return h.hexdigest()
def run_suite(command,suite,env=None,binary=None):
    before=code_hash()
    result=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print(result.stdout,end='',flush=True)
    STORE.mkdir(parents=True,exist_ok=True)
    log=STORE/(suite+'.log');log.write_text(result.stdout)
    if "leaked [" in result.stdout or " panic:" in result.stdout or any(x.startswith("FAIL ") for x in result.stdout.splitlines()):raise RuntimeError("Runtime failure in "+suite)
    if result.returncode:raise subprocess.CalledProcessError(result.returncode,command)
    if before!=code_hash():raise RuntimeError('Code changed while verifying; rerun '+suite)
    if suite.endswith('unit'):
        matched=re.search(r'All (\d+) tests passed\.',result.stdout)
        if not matched:raise RuntimeError('Missing unit completion')
        count=int(matched[1])
    elif suite.endswith('graphics'):
        matched=re.search(r'All (\d+) native graphics Context checks passed\.',result.stdout)
        count=sum(line.startswith('PASS NATIVE BOUNDARY ') for line in result.stdout.splitlines())
        if not matched or count!=int(matched[1]):raise RuntimeError('Incomplete native graphics checks')
    elif suite.endswith('boundary'):
        matched=re.search(r'All (\d+) native VT boundary checks passed\.',result.stdout)
        if not matched:raise RuntimeError('Missing native boundary completion')
        count=sum(line.startswith(('PASS NATIVE BOUNDARY ', 'PASS PROMPT CLEAR ')) for line in result.stdout.splitlines())
        if count!=int(matched[1]):raise RuntimeError('Boundary count mismatch')
    elif suite.endswith('replay'):
        if 'All VT facade replay checks passed (backend=' not in result.stdout:raise RuntimeError('Missing replay completion')
        count=sum(line.startswith('PASS REPLAY ') for line in result.stdout.splitlines())
    elif suite.endswith('n2'):
        matched=re.search(r'All N2 VT facade replay checks passed \(backend=(?:c|zig), checks=(\d+), records=(\d+)\)\.',result.stdout)
        count=sum(line.startswith('PASS N2 REPLAY ') for line in result.stdout.splitlines())
        if not matched or count!=int(matched[1]) or sum(line.startswith('N2RESULT ') for line in result.stdout.splitlines())!=int(matched[2]):raise RuntimeError('Incomplete N2 replay')
    elif suite.endswith('protocol'):
        matched=re.search(r'All (\d+) public-facade protocol query fixtures passed\.',result.stdout)
        count=sum(line.startswith('PROTOCOL ') for line in result.stdout.splitlines())
        if not matched or count!=int(matched[1]):raise RuntimeError('Incomplete protocol replay')
    else:
        marker='All UI checks passed.' if suite.endswith('ui') else 'All core checks passed'
        if marker not in result.stdout:raise RuntimeError('Missing completion marker')
        count=sum(line.startswith('PASS UI ' if suite.endswith('ui') else 'PASS ') for line in result.stdout.splitlines())
    record={'suite':suite,'count':count,'status':'passed','code_sha256':before,'binary_sha256':sha(Path(binary or command[0])),'log_sha256':sha(log),'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (STORE/(suite+'.json')).write_text(json.dumps(record,indent=2)+'\n')
    return record

def build_manifest(prefix,backend='zig',configuration=None):
    files={p.name:sha(p) for p in (ROOT/'zig-out'/prefix/'bin').iterdir() if p.is_file()}
    STORE.mkdir(parents=True,exist_ok=True)
    (STORE/('build-'+prefix+'.json')).write_text(json.dumps({'code_sha256':code_hash(),'vt_backend':backend,'configuration':configuration,'binaries':files},indent=2)+'\n')

def release_evidence(prefix):
    import platform
    gate=STORE/'native-release-gate.json'
    accepted=json.loads(gate.read_text())
    linux_ci = accepted.get('gate_kind') == 'linux-ci-release'
    if accepted.get('status')!='passed' or accepted.get('code_sha256')!=code_hash() or (not linux_ci and accepted.get('n4_developer_cleanup') is not True):
        raise RuntimeError('Complete the current native release gate before packaging')
    if linux_ci:
        import os
        commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        if (not prefix.startswith('linux') or platform.system()!='Linux' or os.environ.get('GITHUB_ACTIONS')!='true'
                or accepted.get('git_commit')!=commit or commit!=os.environ.get('GITHUB_SHA')
                or accepted.get('github_run')!=os.environ.get('GITHUB_RUN_ID')):
            raise RuntimeError('Linux release gate belongs to a different runner, commit or target')
    if accepted.get('verifier_sha256')!=sha(ROOT/'tools/verify-native-release.py'):
        raise RuntimeError('Release verifier changed; rerun the gate')
    for path,digest in accepted.get('materials_sha256',{}).items():
        if not Path(path).is_file() or sha(Path(path))!=digest:
            raise RuntimeError('Release material changed: '+path)
    manifest=json.loads((STORE/('build-'+prefix+'.json')).read_text())
    if manifest.get('vt_backend')!='zig' or manifest.get('code_sha256')!=code_hash():
        raise RuntimeError('Rebuild '+prefix+' for the current native source')
    expected=accepted['linux']['binaries'] if prefix.startswith('linux') else accepted['backends']['zig']['binaries']
    if manifest['binaries']!=expected:
        raise RuntimeError('Build differs from the accepted native application')
    directory=ROOT/'zig-out'/prefix/'bin'
    if {p.name:sha(p) for p in directory.iterdir() if p.is_file()}!=expected:
        raise RuntimeError('Missing, extra or changed native executable')
    test_prefix='native' if platform.system()=='Darwin' and prefix.startswith('linux') else prefix
    checks={}
    for kind,exe in [('unit','letty-unit-tests'),('core','letty-check'),('ui','letty'),('replay','letty-vt-replay'),('n2','letty-vt-n2'),('protocol','letty-vt-protocol'),('boundary','letty-vt-boundary'),('graphics','letty-vt-graphics')]:
        suite=test_prefix+'-'+kind
        record=json.loads((STORE/(suite+'.json')).read_text())
        if record.get('status')!='passed' or record['code_sha256']!=code_hash() or record['binary_sha256']!=sha(ROOT/'zig-out'/test_prefix/'bin'/exe) or record['log_sha256']!=sha(STORE/(suite+'.log')):
            raise RuntimeError('Stale verification: '+suite)
        checks[suite]=record
    return {'code_sha256':code_hash(),'vt_backend':'zig','checks':checks,'host':platform.platform(),
            'feature_acceptance':accepted.get('features',{}),
            'target_execution':'GitHub Linux runner; oldest supported kernel/libraries, VDI and IME pending' if linux_ci else 'local host tests; CentOS/VDI/IME pending',
            'native_release_gate':{'sha256':sha(gate),'status':'passed','basis':accepted['basis'],
                'kind':accepted.get('gate_kind','developer'),
                'target_acceptance':'pending','c_recovery':accepted.get('cleanup',{}).get('recovery') or accepted.get('developer_recovery')}}

def feature_batches():
    return json.loads((ROOT/'docs/milestones.json').read_text())['completed']


def dependency_notices():
    # Zig 0.17 installs dependency sources for this root build here.
    active=ROOT/'zig-pkg'
    if not active.is_dir():
        raise RuntimeError('Missing active Zig package sources: build before packaging')
    notices=[]
    for package in sorted(active.iterdir()):
        if not package.is_dir():continue
        for pattern in ('LICENSE*','COPYING*','NOTICE*'):
            notices.extend((p,Path(package.name)/p.name) for p in sorted(package.glob(pattern)) if p.is_file())
    if not notices:
        raise RuntimeError('No dependency notices found in actual Zig package sources')
    harfbuzz = ROOT/'vendor/harfbuzz/COPYING'
    lock = json.loads((ROOT/'tools/shaper-dependency.json').read_text())
    if not harfbuzz.is_file() or sha(harfbuzz) != lock['license_sha256']:
        raise RuntimeError('Missing or altered pinned HarfBuzz notice')
    notices.append((harfbuzz, Path('harfbuzz')/'COPYING'))
    notices.append((ROOT/'src/ui_icons/assets/LICENSE', Path('lucide')/'LICENSE'))
    notices.append((ROOT/'src/ui_icons/languages/LICENSE', Path('material-icon-theme')/'LICENSE'))
    return notices


def local_preview_evidence():
    # A developer Run needs current local tests, while release packages keep
    # the full Linux/recovery/stability/performance gate above.
    manifest=json.loads((STORE/'build-native.json').read_text())
    identity=code_hash()
    if manifest.get('code_sha256')!=identity or manifest.get('vt_backend')!='zig':
        raise RuntimeError('Build the current native source before local preview')
    expected=manifest.get('binaries',{})
    if {p.name:sha(p) for p in (ROOT/'zig-out/native/bin').iterdir() if p.is_file()}!=expected:
        raise RuntimeError('Native preview binaries differ from manifest')
    checks={}
    for kind,exe in [('unit','letty-unit-tests'),('core','letty-check'),('ui','letty'),('replay','letty-vt-replay'),('n2','letty-vt-n2'),('protocol','letty-vt-protocol'),('boundary','letty-vt-boundary'),('graphics','letty-vt-graphics')]:
        name='native-'+kind
        value=json.loads((STORE/(name+'.json')).read_text())
        if (value.get('status')!='passed' or value.get('code_sha256')!=identity or
                value.get('binary_sha256')!=expected.get(exe) or
                value.get('log_sha256')!=sha(STORE/(name+'.log'))):
            raise RuntimeError('Local preview lacks current verification: '+name)
        checks[name]=value
    symbols=subprocess.check_output(['nm',str(ROOT/'zig-out/native/bin/letty')],text=True)
    if re.search(r'\b_?ghostty_terminal_[A-Za-z0-9_]+\b',symbols):
        raise RuntimeError('Native preview contains a C terminal engine')
    return {'code_sha256':identity,'vt_backend':'zig','checks':checks,
            'scope':'local macOS developer preview; full native release gate not applied',
            'target_execution':'CentOS/VDI/IME pending','release_gate_applied':False}
