"""Retained legacy fault reproduction; every child/SDK call is mocked."""
import contextlib,hashlib,importlib.util,io,json,os,sys,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock,patch

SCRIPTS=Path('/private/tmp/baton-tbx8711-next-runtime-20261007-41988bf2/legacy-physical-source')
EXPECTED={'run-app-attest-physical-test.py':'66dab1e56a920435c18a82e9446d828f1dfd9e5430ef46aee64f8548c9e2bb60','copy-app-attest-probe-evidence.py':'6c246bbb06187ad0e3902a5591adaf4fb5e2e499c5eabf1ac11e1897354abf4b'}
class Held(BaseException):pass
CLEAN={'testExit':0,'timedOut':False,'restoreRequired':True,'cleanupComplete':True,'ownedGroupPending':False,'leaderReaped':True,'inspectionProcessPending':False}

def load(name):
    p=SCRIPTS/name
    assert hashlib.sha256(p.read_bytes()).hexdigest()==EXPECTED[name]
    spec=importlib.util.spec_from_file_location('legacy_physical',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

class LegacyFaultTests(unittest.TestCase):
    def invoke(self,unknown=False,birth=False,summary=False,verifier=False):
        m=load('run-app-attest-physical-test.py')
        with tempfile.TemporaryDirectory(dir='/private/tmp',prefix='attest-legacy-MOCK-') as temp:
            base=Path(temp);selection=base/'selection';selection.write_text('synthetic-device');selection.chmod(0o600)
            def path(value):
                if str(value)=='/private/tmp/baton-tbx8711-minimal-host-20261005':return base
                if str(value)=='/private/tmp/baton-tbx8711-physical-device-id':return selection
                return Path(value)
            data={'totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0}
            def run(argv,**kwargs):
                if 'xcresulttool' in argv:
                    if summary:raise m.subprocess.TimeoutExpired('synthetic-summary',10)
                    return SimpleNamespace(returncode=0,stdout=json.dumps(data).encode())
                if '--deployment' in argv:return SimpleNamespace(returncode=0)
                if verifier:raise m.subprocess.TimeoutExpired('synthetic-verifier',10)
                return SimpleNamespace(returncode=0)
            def popen(*args,**kwargs):
                if birth:raise OSError('synthetic uncertain birth')
                (base/'test-TBX-0000/physical.xcresult').mkdir()
                return SimpleNamespace(pid=8123)
            hold=Mock(side_effect=Held);held=False
            with patch.object(m.pathlib,'Path',side_effect=path),patch.object(sys,'argv',['runner','--deployment','TBX-0000']),patch.object(m.subprocess,'Popen',side_effect=popen),patch.object(m,'wait_owned',return_value={**CLEAN,'cleanupComplete':False} if unknown else CLEAN.copy()),patch.object(m.subprocess,'run',side_effect=run),patch.object(m,'retain_original',hold,create=True),contextlib.redirect_stdout(io.StringIO()):
                try:m.main()
                except Held:held=True
                except BaseException:pass
            return held,hold
    def test_unknown_cleanup_retains_original_parent(self):self.assertTrue(self.invoke(unknown=True)[0])
    def test_uncertain_birth_retains_original_parent(self):self.assertTrue(self.invoke(birth=True)[0])
    def test_unknown_summary_timeout_retains_original_parent(self):self.assertTrue(self.invoke(summary=True)[0])
    def test_unknown_verifier_timeout_retains_original_parent(self):self.assertTrue(self.invoke(verifier=True)[0])
    def test_standalone_copy_refuses_before_any_child(self):
        m=load('copy-app-attest-probe-evidence.py')
        with tempfile.TemporaryDirectory(dir='/private/tmp',prefix='attest-copy-MOCK-') as temp:
            base=Path(temp);selection=base/'selection';selection.write_text('synthetic-device');selection.chmod(0o600)
            def path(value):
                if str(value)=='/private/tmp/baton-tbx8711-next-20261006':return base
                if str(value)=='/private/tmp/baton-tbx8711-physical-device-id':return selection
                return Path(value)
            with patch.object(m.pathlib,'Path',side_effect=path),patch.object(sys,'argv',['copy','--deployment','TBX-0000']),patch.object(m.subprocess,'run',return_value=SimpleNamespace(returncode=0)) as child:
                try:m.main()
                except BaseException:pass
            child.assert_not_called()
if __name__=='__main__':unittest.main(verbosity=2)
