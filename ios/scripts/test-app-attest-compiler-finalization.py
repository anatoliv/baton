#!/usr/bin/env python3
"""Actual prepared compiler run fault checks; all compiler/custody operations mocked."""
import hashlib,importlib.util,json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
REPO=Path(__file__).resolve().parents[2]
SOURCE=REPO/'docs/evidence/tbx-8711/cached-compiler-preparation/controller.py'
if '--source' in sys.argv:
    index=sys.argv.index('--source');SOURCE=Path(sys.argv[index+1]);del sys.argv[index:index+2]
class Held(BaseException):pass
class Exited(BaseException):
    def __init__(self,code):self.code=code
class CompilerFinalization(unittest.TestCase):
    def setUp(self):
        self.umask=os.umask(0o077);os.umask(self.umask)
        spec=importlib.util.spec_from_file_location('prepared_compiler',SOURCE);self.m=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.m)
        self.temp=tempfile.TemporaryDirectory(prefix='baton-compiler-final-MOCK-',dir='/private/tmp');self.root=Path(self.temp.name);self.root.chmod(0o700);self.m.ROOT=self.root
        self.pins={str(REPO/'scripts'/(n+'.py')):hashlib.sha256((REPO/'scripts'/(n+'.py')).read_bytes()).hexdigest() for n in ['incoming_fixture_lifecycle','mixtape_owned_supervision','mixtape_owned_lifecycle']}
        p=self.root/'input-pins.json';p.write_text(json.dumps({'inputSHA256':self.pins}));p.chmod(0o600)
        self.calls=[];self.exit_calls=[];self.writer=self.m.private_file
    def tearDown(self):os.umask(self.umask);self.temp.cleanup()
    def fake_stage(self,name,argv,runner,environment,deadline,execution,outer,reserve,custody):
        self.calls.append((name,argv,deadline,execution,outer,reserve))
        safe={'result':'PASS','appleRootsLoaded':True,'malformedProofRejected':True,'physicalProofVerified':False} if name=='self-check' else {'result':'FAIL','authenticatedClassification':False,'privateDetailsWithheld':True}
        if name!='compile':self.writer(self.root/(name+'.log'),json.dumps(safe).encode())
        return {'phase':name,'testExit':1 if name=='malformed-refusal' else 0,'timedOut':False,'cleanupComplete':True,'leaderReaped':True,'ownedGroupPending':False,'inspectionProcessPending':False}
    def exited(self,code):self.exit_calls.append(code);raise Exited(code)
    def invoke(self,writer=None,precommit=False):
        m=self.m
        patches=[patch.object(m,'preflight',return_value={'inputSHA256':self.pins}),patch.object(m,'safe_environment',return_value={}),patch.object(m,'runtime_checks',return_value={'synthetic':'hash'}),patch.object(m,'stage',side_effect=self.fake_stage),patch.object(m,'retain_original',side_effect=Held()),patch.object(m.signal,'signal'),patch.object(m.time,'monotonic',return_value=100),patch.object(m,'private_file',side_effect=writer or self.writer)]
        if hasattr(m,'capture_exit'):patches.append(patch.object(m,'capture_exit',return_value=self.exited))
        if precommit:patches.append(patch.object(m,'qualify_release',side_effect=OSError('precommit refusal')))
        for p in patches:p.start()
        try:return m.run()
        finally:
            for p in reversed(patches):p.stop()
    def test_full_marker_close_fault_never_returns_to_hold(self):
        def write(path,data):
            self.writer(path,data)
            if path.name=='driver-finished':raise OSError('post-close metadata failure')
        with self.assertRaises(Exited) as result:self.invoke(write)
        self.assertEqual(result.exception.code,1);self.assertEqual(self.exit_calls,[1]);self.assertEqual(self.m.qualify_release(),0)
    def test_partial_marker_fault_exits_failed_and_strict_release_refuses(self):
        def write(path,data):
            if path.name=='driver-finished':self.writer(path,b'fin');raise OSError('partial write')
            self.writer(path,data)
        with self.assertRaises(Exited) as result:self.invoke(write)
        self.assertEqual(result.exception.code,1)
        with self.assertRaises(RuntimeError):self.m.qualify_release()
    def test_precommit_qualification_fault_keeps_marker_absent_and_original_hold(self):
        with self.assertRaises(Held):self.invoke(precommit=True)
        self.assertFalse((self.root/'driver-finished').exists());self.assertEqual(self.exit_calls,[])
    def test_actual_run_routes_accepted_helpers_and_preserves_phase_bounds(self):
        with self.assertRaises(Exited) as result:self.invoke()
        self.assertEqual(result.exception.code,0);self.assertEqual(self.m.qualify_release(),0)
        self.assertEqual([(n,d,e,o,r) for n,argv,d,e,o,r in self.calls],[('compile',395,240,255,35),('self-check',395,10,15,20),('malformed-refusal',395,10,15,5)])
        self.assertEqual(self.calls[0][1][2],str(REPO/'ios/scripts/prepare-app-attest-offline-verifier.py'))
        self.assertEqual(self.m.OWNED.SHARED,REPO/'scripts')
    def shell_boundary(self,qualification):
        shell=(SOURCE.parent/'compile-readiness.sh').read_text()
        start=shell.index('while :; do\n  wait_interrupted=0')
        end=shell.index("printf '%s\\n' 'BLOCKED:",start)
        fragment=shell[start:end]
        # Only this CPU bash child runs; all controller wait/qualification/releases
        # are functions, with the real strict qualification outcome supplied above.
        harness="ROOT="+str(self.root)+"\ncontroller=999999\nwait(){ wait_interrupted=1; return 130; }\npython3(){ return "+str(qualification)+"; }\nprobe_lock_release(){ printf 'probe-released\\n'; }\ngate_lock_release(){ printf 'gate-released\\n'; }\n"+fragment+"printf 'held\\n'\nexit 71\n"
        result=subprocess.run(['/bin/bash','--noprofile','--norc','-c',harness],capture_output=True,text=True)
        return result
    def test_actual_shell_interruption_after_full_marker_only_releases_qualified_absence(self):
        def write(path,data):
            self.writer(path,data)
            if path.name=='driver-finished':raise OSError('visible marker close fault')
        with self.assertRaises(Exited) as outcome:self.invoke(write)
        self.assertEqual(outcome.exception.code,1)
        result=self.shell_boundary(self.m.qualify_release())
        self.assertEqual(result.returncode,130)
        self.assertEqual(result.stdout,'probe-released\n gate-released\n'.replace('\n ','\n'))
    def test_actual_shell_partial_marker_refuses_both_releases(self):
        def write(path,data):
            if path.name=='driver-finished':self.writer(path,b'fin');raise OSError('partial marker')
            self.writer(path,data)
        with self.assertRaises(Exited) as outcome:self.invoke(write)
        self.assertEqual(outcome.exception.code,1)
        with self.assertRaises(RuntimeError):self.m.qualify_release()
        result=self.shell_boundary(1)
        self.assertEqual(result.returncode,71);self.assertEqual(result.stdout,'held\n')
    def test_runtime_exit_binding_is_exact_nonreturning_builtin(self):
        import posix,types
        exit=self.m.capture_exit();self.assertIs(exit,posix._exit);self.assertIs(type(exit),types.BuiltinFunctionType)
        with patch.object(self.m.os,'_exit',lambda code:None):
            with self.assertRaises(RuntimeError):self.m.capture_exit()
if __name__=='__main__':unittest.main()
