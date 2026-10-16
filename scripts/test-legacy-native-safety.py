#!/usr/bin/env python3
"""CPU-only legacy caller custody regressions; never acquire native guards."""
import importlib.util
import json
from pathlib import Path
import subprocess
import os
import sys
import time
import tempfile
import unittest
from unittest.mock import patch
from incoming_fixture_lifecycle import Deadline
from incoming_fixture_delivery import DeliveryControl
from owned_fixture_cpu_support import finish_cpu_fixture

REPO = Path(__file__).resolve().parent.parent

def caller(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), REPO/'scripts'/name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def controller(name):
    shell = (REPO/'scripts'/name).read_text()
    marker = '# BEGIN_OWNED_NATIVE_CONTROLLER\n'
    return shell.split(marker, 1)[1] if marker in shell else shell.split('probe_lock_acquire 0\n', 1)[1]

class LegacyNativeSafetyTests(unittest.TestCase):
    def cpu_root(self):
        # Keep ownership/cleanup evidence even when qualification fails.
        evidence=Path(os.environ.get('BATON_CPU_EVIDENCE_ROOT','/private/tmp'))
        root=Path(tempfile.mkdtemp(prefix='baton-legacy-cpu-',dir=evidence))
        root.chmod(0o700)
        print('Owned CPU evidence:',root,flush=True)
        return root

    def cleanup_cpu(self, owned):
        finish_cpu_fixture(owned)

    def reaped_group(self, name):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            owned = caller(name).OwnedFixture(temporary, {}, Deadline())
            class Reaped:
                pid=77; returncode=0; stdin=None; stdout=None; stderr=None
                def poll(self): return 0
            owned.processes=[Reaped()]
            owned.groups=[{'pid':77,'pgid':77,'closed':False,'started':True}]
            # Reappearing numeric group does not identify the original child.
            observations=iter([True,False,False,False])
            with patch('incoming_fixture_lifecycle.group_exists', side_effect=lambda _:next(observations,False)), patch('os.killpg') as signals:
                failures=owned.stop_groups()
            signals.assert_not_called()
            self.assertTrue(failures)

    def driver_death(self, name):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            prefix='''set +e
OUTPUT="$1/run"
SCRIPT_DIR=/no-real-native-script
probe_lock_release(){ printf 'released-probe\n'; }
gate_lock_release(){ printf 'released-gate\n'; }
python3(){ if [ "$3" = --qualify-release ]; then return 1; fi; return 137; }
sleep(){ printf 'held\n'; exit 0; }
'''
            result=subprocess.run(['/bin/bash','-c',prefix+controller(name),'fixture',temporary],capture_output=True,timeout=2)
            self.assertIn(b'held',result.stdout)
            self.assertNotIn(b'released',result.stdout)

    def test_incoming_reaped_group_is_not_signalled(self):
        self.reaped_group('probe-incoming-share-flow.py')

    def test_composer_reaped_group_is_not_signalled(self):
        self.reaped_group('probe-mixtape-composer-flow.py')

    def test_incoming_driver_death_retains_custody(self):
        self.driver_death('probe-incoming-share-flow.sh')

    def test_composer_driver_death_retains_custody(self):
        self.driver_death('probe-mixtape-composer-flow.sh')

    def test_exited_cpu_child_remains_reserved_until_group_supervision(self):
        owned=caller('probe-incoming-share-flow.py').OwnedFixture(self.cpu_root(),{'PATH':'/usr/bin:/bin'},Deadline())
        try:
            child=owned.start([sys.executable,'-c','pass'])
            end=time.monotonic()+2
            while owned.running(child) and time.monotonic()<end: time.sleep(.005)
            self.assertFalse(owned.running(child))
            self.assertIsNone(child.returncode)
            self.assertIsNotNone(os.waitid(os.P_PID,child.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT))
            self.assertEqual(owned.wait(child,cap=2),0)
            self.assertTrue(owned.groups[0]['supervision']['leaderReaped'])
            self.assertFalse(owned.running(child))
        finally: self.cleanup_cpu(owned)

    def test_synchronous_delivery_callback_can_launch_nested_owned_command(self):
        root=self.cpu_root(); done=root/'cpu-delivery-complete'
        owned=caller('probe-incoming-share-flow.py').OwnedFixture(root,{'PATH':'/usr/bin:/bin'},Deadline())
        delivered=[]
        class Server:
            def handle_request(self):
                if delivered: return
                data,rc=owned.command([sys.executable,'-c','print("owned-delivery")'],cap=2)
                delivered.append((data,rc)); done.touch()
        delivery=DeliveryControl.__new__(DeliveryControl)
        delivery.deadline=owned.deadline; delivery.server=Server()
        try:
            child=owned.start([sys.executable,'-c',
                'import pathlib,sys,time\np=pathlib.Path(sys.argv[1])\nwhile not p.exists(): time.sleep(.005)',str(done)])
            self.assertEqual(owned.wait(child,cap=3,on_tick=delivery.serve_one),0)
            self.assertEqual(delivered,[(b'owned-delivery\n',0)])
            self.assertEqual(len(owned.groups),2)
            self.assertTrue(all(e['closed'] and e['supervision']['leaderReaped'] for e in owned.groups))
        finally:
            self.cleanup_cpu(owned)

    def test_monitoring_refusal_fails_phase_and_cleans_reserved_cpu_group(self):
        owned=caller('probe-incoming-share-flow.py').OwnedFixture(self.cpu_root(),{'PATH':'/usr/bin:/bin'},Deadline())
        def refuse(): raise RuntimeError('synthetic no-fetch refusal')
        try:
            child=owned.start([sys.executable,'-c','import time;time.sleep(2)'])
            self.assertNotEqual(owned.wait(child,cap=3,on_tick=refuse),0)
            self.assertTrue(owned.groups[0]['closed'])
            self.assertTrue(owned.groups[0]['supervision']['leaderReaped'])
            self.assertEqual(owned.stop_groups(),[])
        finally:
            self.cleanup_cpu(owned)

    def test_wrapper_output_refuses_alias_nonempty_and_public_directory(self):
        module=caller('probe-incoming-share-flow.py')
        with tempfile.TemporaryDirectory(prefix='baton-incoming-ui-',dir='/private/tmp') as temporary:
            root=Path(temporary)
            self.assertEqual(module.wrapper_output(str(root)),root)
            with self.assertRaises(module.f.FixtureFailure): module.wrapper_output('/tmp/'+root.name)
            root.chmod(0o755)
            with self.assertRaises(module.f.FixtureFailure): module.wrapper_output(str(root))
            root.chmod(0o700); (root/'existing').touch()
            with self.assertRaises(module.f.FixtureFailure): module.wrapper_output(str(root))

    def test_handled_interruption_releases_only_each_callers_qualified_guard_set(self):
        for name,expected_gate in [('probe-incoming-share-flow.sh',False),('probe-mixtape-composer-flow.sh',True)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
                prefix='''set +e
OUTPUT="$1/run"
SCRIPT_DIR=/no-real-native-script
calls=0
probe_lock_release(){ printf 'released-probe\n'; }
gate_lock_release(){ printf 'released-gate\n'; }
python3(){ return 0; }
kill(){ printf 'numeric-signal\n'; }
wait(){ calls=$((calls+1)); if [ "$calls" -eq 1 ]; then request_cancel; return 143; fi; return 0; }
sleep(){ printf 'held\n'; exit 0; }
'''
                result=subprocess.run(['/bin/bash','-c',prefix+controller(name),'fixture',temporary],capture_output=True,timeout=2)
                self.assertEqual(result.returncode,0)
                self.assertIn(b'released-probe',result.stdout)
                self.assertEqual(b'released-gate' in result.stdout,expected_gate)
                self.assertNotIn(b'numeric-signal',result.stdout)
                self.assertNotIn(b'held',result.stdout)
                self.assertTrue((Path(temporary)/'run.cancel-requested').is_file())

if __name__=='__main__': unittest.main()
