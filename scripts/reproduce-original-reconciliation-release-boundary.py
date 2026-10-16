#!/usr/bin/env python3
"""Inert CPU harness: actual target finalization and immutable shell fragment.

No live controller, native guard, signal, process inspection or SDK operation.
The mocked shell wait returns a handled interruption; its mocked qualifier uses
an already verified actual qualifier result on a disposable synthetic directory.
"""
import ast,datetime,hashlib,json,os,subprocess,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
ROOT=Path('/private/tmp/baton-tbx8711-next-runtime-20261007-41988bf2')
REPO=Path(__file__).resolve().parent.parent

def functions(path,names,nested=False):
    tree=ast.parse(path.read_text());body=next(n.body for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main') if nested else tree.body
    selected=[n for n in body if isinstance(n,ast.FunctionDef) and n.name in names]
    if len(selected)!=len(names):raise ValueError('source function selection refused')
    return compile(ast.fix_missing_locations(ast.Module(body=selected,type_ignores=[])),str(path),'exec')

class ReleaseBoundary(unittest.TestCase):
    def test_finalization_and_handled_wait_must_not_release_while_parent_alive(self):
        shell=(ROOT/'compile-readiness.sh').read_text()
        self.assertEqual(hashlib.sha256(shell.encode()).hexdigest(),'728ff17c6fa61cd1542de4923d58d6a316c02b30d2d29bd78bfc5aa200c36677')
        fragment=shell[shell.index('while :; do\n  wait_interrupted=0'):shell.index("printf '%s\\n' 'BLOCKED:")]
        observations=[]
        with tempfile.TemporaryDirectory(prefix='baton-finalization-mock-',dir='/private/tmp') as temp:
            root=Path(temp);os.chmod(root,0o700)
            def write_new(directory,name,value):
                raw=value if type(value) is bytes else (json.dumps(value)+'\n').encode()
                fd=os.open(directory/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                with os.fdopen(fd,'wb') as f:f.write(raw)
            (root/'input-pins.json').write_text('{"inputSHA256":{}}');os.chmod(root/'input-pins.json',0o600)
            def require(value,*_):
                if not value:raise ValueError('synthetic qualification refused')
            qualifier_env={'ROOT':root,'os':os,'json':json,'stat':__import__('stat'),'require':require,'digest':lambda p:hashlib.sha256(p.read_bytes()).hexdigest()}
            exec(functions(ROOT/'controller.py',['qualified_file','qualify_release']),qualifier_env)
            run=SimpleNamespace(f_globals={'datetime':datetime,'cancel_requested':lambda:False},f_locals={'start':0})
            env={'EXPECTED_NONCE':'synthetic-only','original':{'testExit':1,'timedOut':False,'errorClass':'PermissionError','cleanupComplete':False,'leaderReaped':False,'ownedGroupPending':True,'inspectionProcessPending':False},'original_report':{'startedAtUTC':'synthetic','SDKWindowSeconds':300,'deviceActions':0,'providerActions':0},'run':run,'time':SimpleNamespace(monotonic=lambda:1),'write_new':write_new,'root':root,'PACKET':root,'require':require}
            exec(functions(REPO/'scripts/original-controller-reconciliation-target.py',['receipts','qualify'],nested=True),env)
            env['receipts']({'phase':'before'},{'phase':'after'})
            # Exact original strict qualifier confirms these mock receipts qualify.
            self.assertEqual(qualifier_env['qualify_release'](),0)
            def refused():raise OSError('synthetic fallible final qualification')
            env['qualifier']=refused
            with self.assertRaises(OSError):env['qualify']()
            self.assertFalse((root/'reconciliation-complete.json').exists())
            # Both scenarios leave the original parent alive at marker visibility:
            # (1) final qualifier refusal, (2) successful receipt publication before exit.
            header='''set -uo pipefail
controller=synthetic-only
wait(){ wait_interrupted=1; return 130; }
python3(){ return 0; }
probe_lock_release(){ printf 'probe-released\\n'; }
gate_lock_release(){ printf 'gate-released\\n'; }
'''
            # A disposable bash child executes the actual immutable fragment twice.
            script=header+'ROOT='+str(root)+'\n'+"(\n"+fragment+")\nprintf 'scenario-2\\n'\n(\n"+fragment+")\n"
            result=subprocess.run(['/bin/bash','-c',script],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False,env={'PATH':'/usr/bin:/bin','LC_ALL':'C'})
            self.assertEqual(result.returncode,130)
            output=result.stdout.decode();self.assertEqual(result.stderr,b'')
            self.assertEqual(output.count('gate-released'),2)
            print(json.dumps({'actualShellReleaseCount':2,'originalParentAliveAtBothObservations':True,'originalTargetFinalQualifierRefused':True,'completionAbsent':True,'actualTargetOperations':0,'mockBashChildren':1,'scenarios':['qualifier-refusal-after-marker','marker-visible-before-successful-exit']}))
            for scenario in ['qualifier-refusal-after-marker','marker-visible-before-successful-exit']:
                with self.subTest(scenario=scenario):self.assertNotIn('gate-released',output,'immutable shell releases while original parent remains alive')

if __name__=='__main__':unittest.main()
