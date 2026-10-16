#!/usr/bin/env python3
"""Actual complete sources() body; read-only retained inputs, disposable negatives."""
import ast,hashlib,json,os,stat,tempfile,types,unittest
from unittest.mock import Mock
from pathlib import Path
REPO=Path(__file__).resolve().parent.parent
TARGET=REPO/'scripts/original-controller-reconciliation-target.py'
ORIGINAL=Path('/private/tmp/baton-tbx8711-next-runtime-20261007-41988bf2')

def bind(env):
    tree=ast.parse(TARGET.read_text());main=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main')
    nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='read_owned']+[n for n in main.body if isinstance(n,ast.FunctionDef) and n.name=='sources']
    assert len(nodes)==2
    exec(compile(ast.fix_missing_locations(ast.Module(body=nodes,type_ignores=[])),str(TARGET),'exec'),env)
    return env['sources']

def require(value):
    if not value:raise ValueError('source admission refused')

def base(root,pins,plan):
    return {'Path':Path,'stat':stat,'os':os,'hashlib':hashlib,'require':require,'root':root,'pins':pins,'plan':plan,'adapter':str(root/'adapter.py'),'wait_owned':types.SimpleNamespace(__code__=types.SimpleNamespace(co_filename=str(root/'supervisor.py'))),'lengths':{name:Path(name).lstat().st_size for name in pins},'mark_phase':lambda _:None}

class SourceAdmission(unittest.TestCase):
    def test_complete_64_retained_inputs_accept_known_hashed_large_object(self):
        pins=json.loads((ORIGINAL/'input-pins.json').read_bytes())['inputSHA256'];self.assertEqual(len(pins),64)
        plan=json.loads(Path('/private/tmp/baton-original-parent-reconciliation-preparation-20261007-v2/plan.json').read_bytes())
        env=base(ORIGINAL,pins,plan);env['adapter']='/private/tmp/baton-tbx-8711-next-attempt/ios/scripts/app_attest_owned_controller.py';env['wait_owned'].__code__.co_filename='/private/tmp/baton-tbx-9312/scripts/mixtape_owned_supervision.py'
        large='/private/tmp/baton-sharing-attest-receipt/gateway/.build/out/Products/Debug/X509.o';self.assertEqual(env['lengths'][large],4804464)
        self.assertEqual(hashlib.sha256(Path(large).read_bytes()).hexdigest(),pins[large])
        bind(env)()
    def synthetic(self):
        temp=tempfile.TemporaryDirectory(prefix='baton-source-admission-',dir='/private/tmp');self.addCleanup(temp.cleanup);root=Path(temp.name);os.chmod(root,0o700)
        pins={}
        for i in range(64):
            p=root/('object-'+str(i));p.write_bytes(b'x'*(4*1024*1024+17) if i==0 else ('small-'+str(i)).encode());os.chmod(p,0o600);pins[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
        plan={}
        for name,key in [('controller.py','controllerSHA256'),('adapter.py','adapterSHA256'),('supervisor.py','supervisorSHA256'),('compile-readiness.sh','shellSHA256')]:
            p=root/name;p.write_bytes(name.encode());os.chmod(p,0o600);plan[key]=hashlib.sha256(p.read_bytes()).hexdigest()
        raw=(json.dumps({'inputSHA256':pins})+'\n').encode();(root/'input-pins.json').write_bytes(raw);os.chmod(root/'input-pins.json',0o600);plan['inputPinsSHA256']=hashlib.sha256(raw).hexdigest()
        return root,pins,base(root,pins,plan)
    def test_exact_length_map_loader_validates_hash_and_pin_set(self):
        pins=json.loads((ORIGINAL/'input-pins.json').read_bytes())['inputSHA256']
        env=base(ORIGINAL,pins,{})
        env.update(json=json,PACKET=Path('/private/tmp/baton-original-parent-reconciliation-preparation-20261007-v3'))
        tree=ast.parse(TARGET.read_text());main=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main')
        index=next(i for i,n in enumerate(main.body) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='length_raw' for t in n.targets))
        loader=compile(ast.fix_missing_locations(ast.Module(body=main.body[index:index+4],type_ignores=[])),str(TARGET),'exec')
        bind(env);exec(loader,env);self.assertEqual(set(env['lengths']),set(pins));self.assertEqual(sum(env['lengths'].values()),18157516)
        env['pins']=dict(pins);env['pins'].pop(next(iter(pins)))
        with self.assertRaises(ValueError):exec(loader,env)
        env['pins']=pins;env['read_owned']=lambda *_:b'changed map'
        with self.assertRaises(ValueError):exec(loader,env)
    def test_phase_diagnostics_are_bounded_nonsecret_and_nonthrowing(self):
        root,pins,env=self.synthetic();env.update(PACKET=root,CURRENT_PHASE='ADMISSION',PHASES={'ADMISSION','SOURCE_CLOSURE'},os=types.SimpleNamespace(getpid=lambda:70695,getuid=lambda:501),write_new=Mock())
        tree=ast.parse(TARGET.read_text());node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='mark_phase')
        exec(compile(ast.fix_missing_locations(ast.Module(body=[node],type_ignores=[])),str(TARGET),'exec'),env)
        env['mark_phase']('SOURCE_CLOSURE',ValueError('synthetic error message excluded'))
        value=env['write_new'].call_args.args[2]
        self.assertEqual(value,{'phase':'SOURCE_CLOSURE','errorClass':'ValueError','observationOnly':True,'releaseEstablished':False})
        env['write_new'].side_effect=BrokenPipeError;self.assertIsNone(env['mark_phase']('SOURCE_CLOSURE',OSError('not logged')))
    def test_waitid_refusal_is_classified_as_reservation_entry(self):
        tree=ast.parse(TARGET.read_text());phases=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='PHASES' for t in n.targets));self.assertIn('RESERVATION',phases)
        main=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main');node=next(n for n in main.body if isinstance(n,ast.FunctionDef) and n.name=='exited')
        marks=[];env={'require':require,'child':types.SimpleNamespace(returncode=None),'mark_phase':marks.append,'os':types.SimpleNamespace(P_PID=1,WEXITED=2,WNOHANG=4,WNOWAIT=8,waitid=Mock(side_effect=ChildProcessError))}
        exec(compile(ast.fix_missing_locations(ast.Module(body=[node],type_ignores=[])),str(TARGET),'exec'),env)
        with self.assertRaises(ChildProcessError):env['exited']()
        self.assertEqual(marks,['RESERVATION'])
    def test_same_length_tamper_refused(self):
        root,pins,env=self.synthetic();p=Path(next(iter(pins)));raw=bytearray(p.read_bytes());raw[-1]=ord('y');p.write_bytes(raw)
        with self.assertRaises(ValueError):bind(env)()
    def test_exact_measured_length_growth_refused(self):
        root,pins,env=self.synthetic();p=Path(next(iter(pins)))
        with p.open('ab') as f:f.write(b'one-extra-byte')
        with self.assertRaises(ValueError):bind(env)()
    def test_valid_synthetic_large_object_is_admitted(self):
        root,pins,env=self.synthetic();bind(env)()

if __name__=='__main__':unittest.main()
