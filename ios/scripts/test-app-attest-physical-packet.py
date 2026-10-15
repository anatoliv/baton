"""Coherent synthetic packet contracts, no real app, runtime or child."""
import importlib.util,json,os,plistlib,unittest
from pathlib import Path
from unittest.mock import patch
SCRIPTS=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('packet_fixture',SCRIPTS/'test-app-attest-next-attempt.py')
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
class PacketSafetyTests(unittest.TestCase):
    def setUp(self):
        previous=os.umask(0o077);self.addCleanup(os.umask,previous)
        self.fixture=f.NextAttemptTests('test_explicit_fresh_namespace_paths_and_complete_runtime')
        self.fixture.setUp();self.addCleanup(self.fixture.tearDown)
    def test_exact_generated_bytes_and_single_suite_inverse(self):
        x=self.fixture;x.run_prepare();m=json.loads((x.root/'attempt-plan/manifest.json').read_bytes())
        for a,b in [('run-physical-test.py','run-app-attest-physical-test.py'),('copy-probe-evidence.py','copy-app-attest-probe-evidence.py'),('app_attest_owned_controller.py','app_attest_owned_controller.py')]:
            self.assertEqual((x.root/a).read_bytes(),(SCRIPTS/b).read_bytes())
        self.assertEqual(m['runnerReplacementCount'],0);self.assertEqual(m['copyReplacementCount'],0);self.assertEqual(m['xctestrunSuiteReplacementCount'],1)
        x.prepare.qualify(x.config,x.repo,prepared=True)
        restored=plistlib.loads(Path(m['newXctestrunPath']).read_bytes());restored['BatonAppAttestPhysicalTests']['EnvironmentVariables']['baton.defaultsSuite']=x.original_suite
        self.assertEqual(restored,plistlib.loads(x.original.read_bytes()))
        self.assertEqual(m['executionInputSHA256'],x.prepare.execution_inputs(x.config,x.repo,Path(m['newXctestrunPath']),x.root,prepared=True))
        self.assertFalse(m['executionAdmitted']);self.assertEqual(m['physicalTestsRun'],0)
    def failed_finalization(self,metadata=False):
        x=self.fixture;before=x.prepare.tree_digest(x.app);real=Path.open
        def opened(path,*args,**kwargs):
            if path==x.root/'attempt-plan/manifest.json':raise OSError('synthetic final manifest fault')
            return real(path,*args,**kwargs)
        with patch.object(x.prepare.datetime,'datetime') as dt,patch.object(Path,'open',opened if not metadata else real):
            if metadata:dt.now.side_effect=OSError('synthetic final metadata fault')
            else:dt.now.return_value.isoformat.return_value='synthetic-time'
            with self.assertRaises(OSError):x.run_prepare()
        self.assertEqual(f.sha(x.original),x.before);self.assertEqual(x.prepare.tree_digest(x.app),before)
        self.assertTrue((x.root/'run-physical-test.py').is_file());self.assertFalse((x.root/'attempt-plan/manifest.json').exists())
        retained={str(p):p.read_bytes() for p in x.root.rglob('*') if p.is_file()}
        with self.assertRaises(ValueError):x.run_prepare()
        self.assertEqual({str(p):p.read_bytes() for p in x.root.rglob('*') if p.is_file()},retained)
    def test_final_metadata_fault_retains_unadmitted_partial_packet(self):self.failed_finalization(True)
    def test_final_write_fault_retains_unadmitted_partial_packet(self):self.failed_finalization(False)
    def test_external_test_bundle_drift_refused_before_preparation(self):
        x=self.fixture;f.write(x.test_bundle/'BatonAppAttestPhysicalTests',b'TAMPER')
        with self.assertRaises(ValueError):x.run_prepare()
        self.assertEqual(list(x.root.iterdir()),[]);self.assertEqual(f.sha(x.original),x.before)
    def test_prepared_suite_tamper_is_refused(self):
        x=self.fixture;x.run_prepare();m=json.loads((x.root/'attempt-plan/manifest.json').read_bytes());p=Path(m['newXctestrunPath'])
        v=plistlib.loads(p.read_bytes());v['BatonAppAttestPhysicalTests']['EnvironmentVariables']['baton.defaultsSuite']='wrong';f.write(p,plistlib.dumps(v))
        with self.assertRaises(ValueError):x.prepare.qualify(x.config,x.repo,prepared=True)
if __name__=='__main__':unittest.main(verbosity=2)
