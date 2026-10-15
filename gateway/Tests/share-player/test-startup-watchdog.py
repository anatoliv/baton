#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('startup_run', HERE/'startup-run.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='share-watchdog-test-'))
        self.docker = self.root/'fake-docker.py'
        self.docker.write_text('#!/usr/bin/env python3\nimport os,sys,time\n'
            'with open(os.environ["TEST_DOCKER_LOG"],"a") as f: f.write(" ".join(sys.argv[1:])+"\\n")\n'
            'if os.environ.get("TEST_DOCKER_HANG"): time.sleep(30)\n'
            'if sys.argv[1]=="network" and os.environ.get("TEST_NETWORK_RETAIN"): print("network still exists");sys.exit(1 if sys.argv[2]=="rm" else 0)\n'
            'if sys.argv[2]=="inspect": print("Error: No such "+("network" if sys.argv[1]=="network" else "container"));sys.exit(1)\n')
        self.docker.chmod(0o700)
        self.env = {'PATH':'/usr/bin:/bin','TEST_DOCKER_LOG':str(self.root/'docker.log')}
        self.runner = None

    def tearDown(self):
        identity_path=self.root/'detached-test-identity.json'
        if identity_path.exists():
            identity=json.loads(identity_path.read_text())
            result=subprocess.run(['ps','-p',str(identity['pid']),'-o','pid=,pgid=,uid=,lstart=,comm='],capture_output=True,text=True)
            current=result.stdout.strip().split(None,8)
            expected=[str(identity['pid']),str(identity['group']),str(identity['uid']),*identity['started'].split(),identity['executable']]
            if current==expected:
                state=subprocess.run(['ps','-p',str(identity['pid']),'-o','stat='],capture_output=True,text=True).stdout.strip()
                if state and not state.startswith('Z'):
                    os.killpg(identity['group'],__import__('signal').SIGKILL)
        if self.runner and self.runner.workspace.exists():
            shutil.rmtree(self.runner.workspace)
        shutil.rmtree(self.root)

    def registry_code(self, register=True, survives=False):
        self.env.update(TEST_RUN_ID=self.runner.nonce,TEST_REGISTRY=str(self.root/'evidence/startup-process-registry.json'),
                        TEST_IDENTITY=str(self.root/'detached-test-identity.json'))
        return """
import subprocess,sys,time,os,json
p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
line=subprocess.check_output(['ps','-p',str(p.pid),'-o','pid=,pgid=,uid=,lstart=,comm='],text=True).strip().split(None,8)
entry={'pid':int(line[0]),'group':int(line[1]),'uid':int(line[2]),'started':' '.join(line[3:8]),'executable':line[8]}
open(os.environ['TEST_IDENTITY'],'w').write(json.dumps(entry))
""" + ("""
open(os.environ['TEST_REGISTRY'],'w').write(json.dumps({'runID':os.environ['TEST_RUN_ID'],'browserGroup':p.pid,'uid':os.getuid(),'expectedExecutable':entry['executable'],'entries':[entry]}))
""" if register else '') + ('' if survives else 'p.terminate();p.wait()\n')

    def run_child(self, code, budget=8, verified=False, registry=False, survives=False):
        self.runner = module.FixtureRunner(self.root/'evidence', budget=budget)
        if registry:
            code=self.registry_code(survives=survives)+code
        rc = self.runner.run([sys.executable,'-c',code], self.env, str(self.docker))
        receipt = json.loads((self.root/'evidence/run-status.json').read_text())
        self.assertEqual(receipt['cleanup']['verified'],verified)
        self.assertEqual(self.runner.workspace.exists(),not verified)
        self.assertEqual((self.root/'docker.log').read_text().splitlines(),[
            'container rm -f '+self.runner.container,'container inspect '+self.runner.container,
            'network rm '+self.runner.container,'network inspect '+self.runner.container])
        return rc, receipt

    def test_success_preserves_log_and_exact_owned_cleanup(self):
        rc, receipt = self.run_child('print("measured fixture finished",flush=True)',registry=True,verified=True)
        self.assertEqual(rc,0)
        self.assertEqual(receipt['fixtureExitCode'],0)
        self.assertIn('measured fixture finished',(self.root/'evidence/run.log').read_text())

    def test_original_failure_is_not_changed_to_success(self):
        rc, receipt = self.run_child('import sys; print("original failure",flush=True);sys.exit(7)')
        self.assertEqual(rc,7)
        self.assertEqual(receipt['fixtureExitCode'],7)

    def test_stuck_sampling_finally_is_killed_with_cleanup_reserved(self):
        started = time.monotonic()
        rc, receipt = self.run_child('import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print("partial failure evidence",flush=True);time.sleep(30)')
        self.assertEqual(rc,124)
        self.assertEqual(receipt['fixtureExitCode'],124)
        self.assertLess(time.monotonic()-started,8.2)
        self.assertIn('partial failure evidence',(self.root/'evidence/run.log').read_text())

    def test_detached_browser_equivalent_is_also_killed(self):
        pidfile=self.root/'detached.pid'
        code=('import subprocess,sys,time,signal;signal.signal(signal.SIGTERM,signal.SIG_IGN);'
              'p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"],start_new_session=True);'
              f'open({str(pidfile)!r},"w").write(str(p.pid));time.sleep(30)')
        rc,receipt=self.run_child(code,budget=8)
        self.assertEqual(rc,124)
        pid=int(pidfile.read_text())
        self.assertIn(pid,receipt['ownedDetachedGroupsSignalled'])
        state=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
        self.assertTrue(not state.stdout.strip() or state.stdout.strip().startswith('Z'))

    def test_abrupt_parent_exit_without_registry_keeps_unknown_detached_child_honest(self):
        self.runner=module.FixtureRunner(self.root/'evidence',budget=8)
        code=self.registry_code(register=False,survives=True)+'os._exit(7)'
        rc=self.runner.run([sys.executable,'-c',code],self.env,str(self.docker))
        receipt=json.loads((self.root/'evidence/run-status.json').read_text())
        self.assertEqual(rc,7)
        self.assertFalse(receipt['cleanup']['verified'])
        self.assertIn('Abnormal fixture exit',receipt['cleanup']['processUncertainty'])
        self.assertTrue(self.runner.workspace.exists())
        identity=json.loads((self.root/'detached-test-identity.json').read_text())
        os.kill(identity['pid'],0) # alive/reparented; supervisor explicitly retained uncertainty

    def test_abrupt_parent_exit_with_registry_retains_recovery_identity(self):
        rc,receipt=self.run_child('os._exit(7)',registry=True,survives=True)
        self.assertEqual(rc,7)
        self.assertFalse(receipt['cleanup']['ownedProcessAbsenceVerified'])
        self.assertTrue((self.root/'evidence/startup-process-registry.json').exists())

    def test_zero_exit_with_live_registered_browser_is_not_clean(self):
        rc,receipt=self.run_child('print("parent done")',registry=True,survives=True)
        self.assertEqual(rc,1)
        self.assertEqual(receipt['fixtureExitCode'],0)
        identity=json.loads((self.root/'detached-test-identity.json').read_text())
        self.assertIn({'pid':identity['pid'],'group':identity['group']},receipt['cleanup']['remainingRegisteredGroupProcesses'])
        os.kill(identity['pid'],0)

    def test_zero_exit_without_registry_is_not_clean(self):
        rc,receipt=self.run_child('print("parent done without handoff")')
        self.assertEqual(rc,1)
        self.assertEqual(receipt['fixtureExitCode'],0)
        self.assertFalse(receipt['cleanup']['ownedProcessAbsenceVerified'])

    def test_interrupt_still_removes_and_independently_checks_exact_network(self):
        rc,receipt=self.run_child('import os,signal,time;os.kill(os.getppid(),signal.SIGTERM);time.sleep(1)',registry=True)
        self.assertEqual(rc,143)
        self.assertEqual(receipt['failureCategory'],'interrupted')
        self.assertTrue(receipt['cleanup']['containerAbsent'])
        self.assertTrue(receipt['cleanup']['networkAbsent'])
        self.assertFalse(receipt['cleanup']['verified'])
        self.assertEqual(receipt['network'],receipt['container'])

    def test_retained_network_is_not_claimed_clean_even_if_container_is_gone(self):
        self.env['TEST_NETWORK_RETAIN']='1'
        rc,receipt=self.run_child('print("measurement finished")',registry=True)
        self.assertEqual(rc,1)
        self.assertEqual(receipt['fixtureExitCode'],0)
        self.assertTrue(receipt['cleanup']['containerAbsent'])
        self.assertFalse(receipt['cleanup']['networkAbsent'])
        self.assertTrue(self.runner.workspace.exists())
        self.assertIn('network',receipt['cleanup']['workspaceRetainedReason'])

    def test_hard_deadline_bounds_stuck_cleanup_and_reports_uncertainty(self):
        # The hard exit is exercised in a separate supervisor process, never the
        # unittest process or a native/audio runner. The fake Docker does no I/O.
        code = ('import importlib.util,os,sys;from pathlib import Path;'
            f's=importlib.util.spec_from_file_location("r",{str(HERE/"startup-run.py")!r});'
            'm=importlib.util.module_from_spec(s);s.loader.exec_module(m);'
            f'r=m.FixtureRunner({str(self.root/"evidence")!r},budget=1);'
            f'r.run([sys.executable,"-c","print(123)"],{dict(self.env,TEST_DOCKER_HANG="1")!r},{str(self.docker)!r})')
        started=time.monotonic()
        process=subprocess.run([sys.executable,'-c',code],timeout=3,capture_output=True)
        self.assertEqual(process.returncode,124)
        self.assertLess(time.monotonic()-started,1.5)
        receipt=json.loads((self.root/'evidence/run-status.json').read_text())
        self.assertTrue(receipt['hardDeadline'])
        self.assertFalse(receipt['cleanup']['verified'])
        workspace=Path(receipt['cleanup']['workspace'])
        self.assertTrue(workspace.name.startswith('share-startup-'))
        shutil.rmtree(workspace)

    def test_unavailable_process_inspection_never_claims_clean_cleanup(self):
        self.runner=module.FixtureRunner(self.root/'evidence',budget=8)
        code=self.registry_code()+'print("done")'
        with patch.object(module.subprocess,'run',side_effect=OSError('metadata unavailable')):
            rc=self.runner.run([sys.executable,'-c',code],self.env,str(self.docker))
        receipt=json.loads((self.root/'evidence/run-status.json').read_text())
        self.assertEqual(rc,1)
        self.assertEqual(receipt['fixtureExitCode'],0)
        self.assertFalse(receipt['cleanup']['verified'])
        self.assertEqual(receipt['cleanup']['processUncertainty'],'OSError')
        self.assertTrue(self.runner.workspace.exists())

    def test_runtime_environment_never_inherits_owner_service_or_credentials(self):
        self.runner=module.FixtureRunner(self.root/'evidence')
        prior=os.environ.get('SHARE_E2E_SERVICE')
        os.environ['SHARE_E2E_SERVICE']='https://example.invalid'
        try:
            env=module.clean_environment(self.runner.workspace,self.runner.nonce,Path('/synthetic/playwright'),Path('/synthetic/browsers'))
            self.assertNotIn('SHARE_E2E_SERVICE',env)
            self.assertNotIn('SHARE_E2E_ADMIN',env)
            self.assertEqual(env['BATON_SHARE_BIND'],'127.0.0.1')
            self.assertEqual(env['TMPDIR'],str(self.runner.workspace))
        finally:
            if prior is None: os.environ.pop('SHARE_E2E_SERVICE',None)
            else: os.environ['SHARE_E2E_SERVICE']=prior


if __name__=='__main__':
    unittest.main()
