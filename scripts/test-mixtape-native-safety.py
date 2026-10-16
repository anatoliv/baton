#!/usr/bin/env python3
"""CPU-only harness regressions: isolated shell fragments and mocked ownership."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from incoming_fixture_lifecycle import Deadline, FixtureTimeout, write_receipt
from mixtape_owned_lifecycle import ReservedOwnedFixture as OwnedFixture, release_qualified, cleanup_qualified

REPO = Path(__file__).resolve().parent.parent

class NativeSafetyTests(unittest.TestCase):
    def test_interrupted_popen_cannot_qualify_empty_group_cleanup(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root=Path(temporary); owned=OwnedFixture(root,{},Deadline())
            # Popen may have created a child before its constructor is interrupted;
            # do not actually launch one in this ownership-loss regression.
            try:
                with patch('mixtape_owned_lifecycle.subprocess.Popen',side_effect=FixtureTimeout), patch('os.killpg') as signals:
                    with self.assertRaises(FixtureTimeout): owned.start(['mocked-unregistered-child'])
                    cleanup=owned.cleanup()
                signals.assert_not_called()
                self.assertFalse(cleanup_qualified(cleanup))
                self.assertTrue(json.loads((root/'ownership.json').read_bytes())['launchUncertain'])
            finally: owned.deadline.disarm()

    def test_interrupted_registration_cannot_qualify_empty_group_cleanup(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root=Path(temporary); owned=OwnedFixture(root,{},Deadline())
            class InterruptedList(list):
                def append(self,process): raise FixtureTimeout()
            class Born:
                pid=77; returncode=None
            owned.processes=InterruptedList()
            try:
                with patch('mixtape_owned_lifecycle.subprocess.Popen',return_value=Born()), patch('os.killpg') as signals:
                    with self.assertRaises(FixtureTimeout): owned.start(['mocked-unregistered-child'])
                    cleanup=owned.cleanup()
                signals.assert_not_called()
                self.assertFalse(cleanup_qualified(cleanup))
                self.assertTrue(json.loads((root/'ownership.json').read_bytes())['launchUncertain'])
            finally: owned.deadline.disarm()

    def test_cancellation_during_registration_cannot_resume_owned_group(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root=Path(temporary)/'run'; root.mkdir(mode=0o700)
            owned=OwnedFixture(root,{},Deadline())
            original_receipt=owned.receipt
            def cancelled_before_resume():
                original_receipt()
                if owned.groups and owned.groups[0]['started']:
                    write_receipt(root.with_name(root.name+'.cancel-requested'),{'requested':True})
            class Born:
                pid=77; returncode=None
            class Stopped:
                si_code=os.CLD_STOPPED
            with patch('mixtape_owned_lifecycle.subprocess.Popen',return_value=Born()), \
                 patch('mixtape_owned_lifecycle.os.getpgid',return_value=77), \
                 patch('mixtape_owned_lifecycle.os.waitid',return_value=Stopped()), \
                 patch.object(owned,'receipt',side_effect=cancelled_before_resume), patch('os.killpg') as signals:
                with self.assertRaisesRegex(RuntimeError,'before owned group resume'): owned.start(['mocked-stopped-child'])
            signals.assert_not_called()
            self.assertEqual(len(owned.groups),1)
            self.assertFalse(owned.launch_uncertain)
            self.assertTrue(owned.groups[0]['reservedLeader'])
            self.assertFalse(owned.groups[0]['closed'])

    def test_controller_death_cannot_release_unknown_guard_custody(self):
        shell = (REPO/'scripts/test-mixtape-native-stage.sh').read_text()
        tail = shell.split('# BEGIN_OWNED_NATIVE_CONTROLLER\n',1)[1]
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            # Execute only the controller/hold tail, never wrapper/guard acquisition.
            prefix = '''set +e
OUTPUT="$1"
SCRIPT_DIR=/no-real-native-script
probe_lock_release(){ printf released-probe\\n; }
gate_lock_release(){ printf released-gate\\n; }
python3(){ return 137; }
sleep(){ printf held\\n; exit 0; }
'''
            result = subprocess.run(['/bin/bash','-c',prefix+tail,'fixture',temporary],
                                    capture_output=True, timeout=2)
            self.assertIn(b'held', result.stdout)
            self.assertNotIn(b'released', result.stdout)

    def test_reaped_open_group_is_never_signalled_if_number_reappears(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            owned = OwnedFixture(temporary, {}, Deadline())
            # Leader was already reaped by communicate/wait. A new unrelated group
            # now has that number; existence is not ownership authorization.
            owned.groups = [{'pid':77,'pgid':77,'closed':False,'started':True}]
            class Reaped:
                pid=77; returncode=0; stdin=None; stdout=None; stderr=None
                def poll(self): return 0
            owned.processes=[Reaped()]
            observations=iter([True])
            with patch('incoming_fixture_lifecycle.group_exists', side_effect=lambda _: next(observations,False)), \
                 patch('os.killpg') as signals:
                owned.stop_groups()
            signals.assert_not_called()

    def test_handled_shell_interruption_retries_without_signalling_child(self):
        shell=(REPO/'scripts/test-mixtape-native-stage.sh').read_text()
        tail=shell.split('# BEGIN_OWNED_NATIVE_CONTROLLER\n',1)[1]
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            prefix='''set +e
OUTPUT="$1/run"
SCRIPT_DIR=/no-real-native-script
calls=0
probe_lock_release(){ printf 'released-probe\\n'; }
gate_lock_release(){ printf 'released-gate calls=%s\\n' "$calls"; }
python3(){ return 0; }
wait(){ calls=$((calls+1)); if [ "$calls" -eq 1 ]; then request_cancel; return 143; fi; return 0; }
sleep(){ printf held\\n; exit 0; }
'''
            result=subprocess.run(['/bin/bash','-c',prefix+tail,'fixture',temporary],capture_output=True,timeout=2)
            self.assertEqual(result.returncode,0)
            self.assertIn(b'calls=2',result.stdout)
            self.assertNotIn(b'held',result.stdout)
            self.assertTrue((Path(temporary)/'run.cancel-requested').exists())

    def test_successful_driver_with_incomplete_cleanup_cannot_release(self):
        tail=(REPO/'scripts/test-mixtape-native-stage.sh').read_text().split('# BEGIN_OWNED_NATIVE_CONTROLLER\n',1)[1]
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            prefix='''set +e
OUTPUT="$1/run"
SCRIPT_DIR=/no-real-native-script
probe_lock_release(){ printf released-probe\\n; }
gate_lock_release(){ printf released-gate\\n; }
python3(){ if [ "$3" = --qualify-release ]; then return 1; fi; return 0; }
sleep(){ printf held\\n; exit 0; }
'''
            result=subprocess.run(['/bin/bash','-c',prefix+tail,'fixture',temporary],capture_output=True,timeout=2)
            self.assertIn(b'held',result.stdout)
            self.assertNotIn(b'released',result.stdout)

    def test_release_requires_complete_private_receipts_and_created_resource_absence(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root=Path(temporary); root.chmod(0o700)
            cleanup={'launchUncertain':False,'failures':[],'registeredGroupsAbsent':True,'schemeRestoredExactly':True,
                     'simulatorAbsent':None,'containerAbsent':None}
            write_receipt(root/'incoming-cleanup.json',cleanup)
            write_receipt(root/'native-custody-release.json',{'qualified':True})
            ownership={'launchUncertain':False,'cleanup':'qualified','groups':[],'simulatorName':'created-own-simulator'}
            write_receipt(root/'ownership.json',ownership)
            self.assertFalse(release_qualified(root))
            cleanup['simulatorAbsent']=True; write_receipt(root/'incoming-cleanup.json',cleanup)
            self.assertTrue(release_qualified(root))
            ownership['launchUncertain']=True; write_receipt(root/'ownership.json',ownership)
            self.assertFalse(release_qualified(root))
            ownership['launchUncertain']=False; write_receipt(root/'ownership.json',ownership)
            cleanup['launchUncertain']=True; write_receipt(root/'incoming-cleanup.json',cleanup)
            self.assertFalse(release_qualified(root))
            cleanup['launchUncertain']=False
            cleanup['registeredGroupsAbsent']=False; write_receipt(root/'incoming-cleanup.json',cleanup)
            self.assertFalse(release_qualified(root))

    def test_pending_inspection_or_unreaped_supervision_keeps_custody(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root=Path(temporary); root.chmod(0o700)
            cleanup={'launchUncertain':False,'failures':[],'registeredGroupsAbsent':True,'schemeRestoredExactly':True,
                     'simulatorAbsent':None,'containerAbsent':None}
            write_receipt(root/'incoming-cleanup.json',cleanup)
            write_receipt(root/'native-custody-release.json',{'qualified':True})
            entry={'closed':True,'reservedLeader':False,'supervision':{'cleanupComplete':True,
                'leaderReaped':True,'ownedGroupPending':False,'inspectionProcessPending':True}}
            ownership={'launchUncertain':False,'cleanup':'qualified','groups':[entry]}; write_receipt(root/'ownership.json',ownership)
            self.assertFalse(release_qualified(root))
            entry['supervision']['inspectionProcessPending']=False
            entry['supervision']['leaderReaped']=False; write_receipt(root/'ownership.json',ownership)
            self.assertFalse(release_qualified(root))

    def test_real_cpu_command_reserves_leader_until_descendant_cleanup(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root=Path(temporary); owned=OwnedFixture(root,{'PATH':'/usr/bin:/bin'},Deadline())
            code="import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time;time.sleep(2)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print('cpu-fixture')"
            try:
                output,rc=owned.command([sys.executable,'-c',code],cap=3)
                self.assertEqual(rc,0); self.assertEqual(output,b'cpu-fixture\n')
                entry=owned.groups[0]; self.assertTrue(entry['closed'])
                self.assertFalse(entry['reservedLeader'])
                self.assertTrue(entry['supervision']['leaderReaped'])
                self.assertFalse(entry['supervision']['ownedGroupPending'])
                self.assertEqual(owned.stop_groups(),[])
            finally: owned.deadline.disarm()

    def test_real_cpu_timeout_reaps_only_reserved_group_and_retains_diagnostic(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            owned=OwnedFixture(temporary,{'PATH':'/usr/bin:/bin'},Deadline())
            try:
                with self.assertRaisesRegex(RuntimeError,'timed out'):
                    owned.command([sys.executable,'-c','import time;time.sleep(2)'],cap=.05)
                entry=owned.groups[0]; self.assertTrue(entry['closed'])
                self.assertTrue(entry['supervision']['timedOut'])
                self.assertTrue(entry['supervision']['leaderReaped'])
                self.assertFalse(entry['supervision']['ownedGroupPending'])
                self.assertEqual(owned.stop_groups(),[])
            finally: owned.deadline.disarm()

    def test_real_cpu_cancellation_cleans_reserved_group_without_next_launch(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root=Path(temporary)/'run';root.mkdir(mode=0o700)
            owned=OwnedFixture(root,{'PATH':'/usr/bin:/bin'},Deadline())
            marker=root.with_name(root.name+'.cancel-requested')
            timer=threading.Timer(.05,lambda:write_receipt(marker,{'requested':True}))
            try:
                timer.start()
                with self.assertRaises(RuntimeError):
                    owned.command([sys.executable,'-c','import time;time.sleep(2)'],cap=3)
                self.assertTrue(owned.groups[0]['closed'])
                self.assertTrue(owned.groups[0]['supervision']['cancelled'])
                self.assertTrue(owned.groups[0]['supervision']['leaderReaped'])
                self.assertEqual(owned.stop_groups(),[])
                with patch('mixtape_owned_lifecycle.subprocess.Popen') as launch:
                    with self.assertRaises(RuntimeError): owned.start(['unopened-next-command'])
                    launch.assert_not_called()
            finally:
                timer.cancel();timer.join(1);owned.deadline.disarm()

if __name__ == '__main__': unittest.main()
