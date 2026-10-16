#!/usr/bin/env python3
"""Actual target finalization/strict-qualifier and immutable shell CPU mocks."""
import ast,datetime,hashlib,json,os,stat,subprocess,tempfile,types,unittest
from pathlib import Path
from types import SimpleNamespace
ROOT=Path('/private/tmp/baton-tbx8711-next-runtime-20261007-41988bf2')
REPO=Path(__file__).resolve().parent.parent
class ExitOriginal(BaseException):pass

def functions(path,names,nested=False):
    tree=ast.parse(path.read_text());body=next(n.body for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main') if nested else tree.body
    selected=[n for n in body if isinstance(n,ast.FunctionDef) and n.name in names]
    if len(selected)!=len(names):raise ValueError('source selection refused')
    return compile(ast.fix_missing_locations(ast.Module(body=selected,type_ignores=[])),str(path),'exec')

class Finalization(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='baton-finalization-green-',dir='/private/tmp');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);os.chmod(self.root,0o700);self.packet=self.root/'packet';self.packet.mkdir(mode=0o700)
        self.exits=[];self.write_failure=None
        self.pins={}
        for i in range(64):
            p=self.root/('input-'+str(i));p.write_bytes(('synthetic-'+str(i)).encode());os.chmod(p,0o600);self.pins[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
        self.write(self.root,'input-pins.json',{'inputSHA256':self.pins})
        def require(value,*_):
            if not value:raise ValueError('mock qualification refused')
        env={'Path':Path,'ROOT':self.root,'os':os,'json':json,'stat':stat,'require':require,'digest':lambda p:hashlib.sha256(p.read_bytes()).hexdigest()}
        exec(functions(ROOT/'controller.py',['qualified_file','qualify_release']),env);self.qualifier=env['qualify_release']
        run=SimpleNamespace(f_globals={'datetime':datetime,'cancel_requested':lambda:False},f_locals={'start':0})
        self.env={'EXPECTED_NONCE':'synthetic-only','original':{'testExit':1,'timedOut':False,'errorClass':'PermissionError','cleanupComplete':False,'leaderReaped':False,'ownedGroupPending':True,'inspectionProcessPending':False},'original_report':{'startedAtUTC':'synthetic','SDKWindowSeconds':300,'deviceActions':0,'providerActions':0},'run':run,'time':SimpleNamespace(monotonic=lambda:1),'write_new':self.write,'read_owned':lambda path,owner,mode,bound:env['qualified_file'](str(path.relative_to(self.root)),bound),'root':self.root,'PACKET':self.packet,'require':require,'types':types,'mark_phase':lambda _:None,'qualifier':self.qualifier,'original_read':env['qualified_file'],'original_exit':self.exit_original}
        exec(functions(REPO/'scripts/original-controller-reconciliation-target.py',['receipts','qualify','commit'],nested=True),self.env)
    def write(self,directory,name,value):
        raw=value if type(value) is bytes else (json.dumps(value)+'\n').encode()
        if name=='driver-finished' and self.write_failure=='before':raise OSError('mock open failure')
        fd=os.open(directory/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as f:
            if name=='driver-finished' and self.write_failure=='partial':f.write(raw[:2]);raise OSError('mock partial-write failure')
            f.write(raw);f.flush();os.fsync(f.fileno())
            if name=='driver-finished' and self.write_failure=='after':raise OSError('mock fsync/close failure after publication')
    def exit_original(self,rc):self.exits.append(rc);raise ExitOriginal()
    def prepare(self):
        self.env['receipts']({'phase':'before'},{'phase':'after'})
        self.assertFalse((self.root/'driver-finished').exists())
        with self.assertRaises(FileNotFoundError):self.qualifier()
        before=dict(self.qualifier.__globals__)
        self.env['qualify']()
        self.assertEqual(self.qualifier.__globals__,before)
        self.assertFalse((self.root/'driver-finished').exists())
        self.assertTrue(json.loads((self.packet/'reconciliation-complete.json').read_bytes())['strictLogicPrevalidated'])
    def shell_release(self):
        shell=(ROOT/'compile-readiness.sh').read_text();self.assertEqual(hashlib.sha256(shell.encode()).hexdigest(),'728ff17c6fa61cd1542de4923d58d6a316c02b30d2d29bd78bfc5aa200c36677')
        fragment=shell[shell.index('while :; do\n  wait_interrupted=0'):shell.index("printf '%s\\n' 'BLOCKED:")]
        try:self.qualifier();qualifier_rc=0
        except (FileNotFoundError,ValueError):qualifier_rc=1
        # This fragment uses the real strict qualification result above. No guard.
        header='set -uo pipefail\ncontroller=synthetic\nwait(){ wait_interrupted=1; return 130; }\npython3(){ return '+str(qualifier_rc)+'; }\nprobe_lock_release(){ printf "probe-released\\n"; }\ngate_lock_release(){ printf "gate-released\\n"; }\n'
        # A missing marker + interrupted wait would legitimately retry forever;
        # test that branch with a noninterrupted completed wait to avoid a fake retry.
        if not (self.root/'driver-finished').exists():header=header.replace('wait_interrupted=1; return 130','wait_interrupted=0; return 1')
        p=subprocess.run(['/bin/bash','-c',header+'ROOT='+str(self.root)+'\n'+fragment+'\nexit 1\n'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False,env={'PATH':'/usr/bin:/bin','LC_ALL':'C'})
        self.assertEqual(p.stderr,b'');return p.stdout.decode()
    def test_precommit_changed_input_keeps_driver_absent_and_parent_uncommitted(self):
        self.env['receipts']({},{});Path(next(iter(self.pins))).write_bytes(b'changed')
        with self.assertRaises(ValueError):self.env['qualify']()
        self.assertFalse((self.root/'driver-finished').exists());self.assertFalse((self.packet/'reconciliation-complete.json').exists());self.assertEqual(self.exits,[])
    def test_precommit_completion_write_failure_keeps_driver_absent(self):
        self.env['receipts']({},{})
        original_write=self.env['write_new']
        def refused(directory,name,value):
            if name=='reconciliation-complete.json':raise OSError('mock precommit completion failure')
            return original_write(directory,name,value)
        self.env['write_new']=refused
        with self.assertRaises(OSError):self.env['qualify']()
        self.assertFalse((self.root/'driver-finished').exists());self.assertEqual(self.exits,[])
    def test_precommit_receipt_write_failure_keeps_driver_absent(self):
        original_write=self.env['write_new']
        def refused(directory,name,value):
            if name=='safe-run-receipt.json':raise OSError('mock precommit receipt failure')
            return original_write(directory,name,value)
        self.env['write_new']=refused
        with self.assertRaises(OSError):self.env['receipts']({},{})
        self.assertFalse((self.root/'driver-finished').exists());self.assertEqual(self.exits,[])
    def test_full_publication_commits_exit_before_any_fallible_followup(self):
        self.prepare()
        with self.assertRaises(ExitOriginal):self.env['commit']()
        self.assertEqual(self.exits,[1]);self.assertEqual(self.qualifier(),0);self.assertIn('gate-released',self.shell_release())
    def test_complete_marker_followed_by_write_failure_still_commits_exit(self):
        self.prepare();self.write_failure='after'
        with self.assertRaises(ExitOriginal):self.env['commit']()
        self.assertEqual(self.exits,[1]);self.assertEqual(self.qualifier(),0);self.assertIn('gate-released',self.shell_release())
    def test_partial_or_missing_marker_still_exits_and_strict_shell_keeps_guards(self):
        self.prepare();self.write_failure='partial'
        with self.assertRaises(ExitOriginal):self.env['commit']()
        self.assertEqual(self.exits,[1]);self.assertNotIn('gate-released',self.shell_release())
    def test_marker_open_failure_still_exits_and_strict_shell_keeps_guards(self):
        self.prepare();self.write_failure='before'
        with self.assertRaises(ExitOriginal):self.env['commit']()
        self.assertEqual(self.exits,[1]);self.assertNotIn('gate-released',self.shell_release())

if __name__=='__main__':unittest.main()
