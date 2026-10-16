#!/usr/bin/env python3
"""Pure-mock reserved-child qualification; no process, guard or SDK actions."""
import os
from types import SimpleNamespace
import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
from mixtape_owned_supervision import wait_owned
from mixtape_owned_lifecycle import ReservedOwnedFixture
from incoming_fixture_lifecycle import Deadline, FixtureDiagnosticFailure

class ReservationTests(unittest.TestCase):
    def test_incomplete_stopped_birth_never_supplies_exited_session_proof(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            owned=ReservedOwnedFixture(temporary,{},Deadline())
            class Child:
                pid=77; returncode=None
                def wait(self,timeout): raise AssertionError('Unqualified child must not be reaped')
            exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED)
            with patch('mixtape_owned_lifecycle.subprocess.Popen',return_value=Child()), \
                 patch('os.getpgid',return_value=77), patch('os.waitid',return_value=exited), patch('os.killpg') as signals:
                with self.assertRaises(FixtureDiagnosticFailure): owned.start(['mocked-child'])
            signals.assert_not_called()
            entry=json.loads((Path(temporary)/'ownership.json').read_bytes())['groups'][0]
            self.assertNotEqual(entry.get('sessionVerified'),True)
            for proof in [None,False]:
                with self.subTest(proof=proof):
                    if proof is None: owned.groups[0].pop('sessionVerified',None)
                    else: owned.groups[0]['sessionVerified']=False
                    with patch('os.getpgid',side_effect=ProcessLookupError), patch('os.waitid',return_value=exited), patch('os.killpg') as signals:
                        with self.assertRaises(FixtureDiagnosticFailure): owned.wait(owned.processes[0],cap=1)
                    signals.assert_not_called()

    def test_every_group_signal_precedes_original_leader_reap(self):
        events=[]
        class Child:
            pid=77
            def wait(self,timeout): events.append('reap'); return 0
        exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED)
        with patch('mixtape_owned_supervision.os.getpgid',return_value=77), \
             patch('mixtape_owned_supervision.os.waitid',return_value=exited), \
             patch('mixtape_owned_supervision.group_present',side_effect=[True,False,False]), \
             patch('mixtape_owned_supervision.os.killpg',side_effect=lambda pid,sig:events.append('signal')):
            outcome=wait_owned(Child(),execution_seconds=1,outer_seconds=2,term_seconds=0)
        self.assertEqual(events,['signal','signal','reap'])
        self.assertTrue(outcome['cleanupComplete'])

    def refusal(self, registered, observed):
        class Child:
            pid=77
            def wait(self,timeout): raise AssertionError('Unqualified child must not be reaped')
        with patch('mixtape_owned_supervision.os.getpgid',side_effect=ProcessLookupError), \
             patch('mixtape_owned_supervision.os.waitid',return_value=observed), \
             patch('mixtape_owned_supervision.os.killpg') as signals, \
             patch('mixtape_owned_supervision.group_present') as inspect:
            outcome=wait_owned(Child(),execution_seconds=1,outer_seconds=2,registered_group=registered)
        signals.assert_not_called(); inspect.assert_not_called()
        self.assertFalse(outcome['cleanupComplete'])
        self.assertFalse(outcome['leaderReaped'])

    def test_unknown_stopped_birth_never_authorizes_exited_group(self):
        self.refusal(None,SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED))

    def test_mismatched_child_identity_never_authorizes_group(self):
        self.refusal(77,SimpleNamespace(si_pid=78,si_code=os.CLD_EXITED))

    def test_absence_without_direct_child_exit_never_authorizes_group(self):
        self.refusal(77,None)

    def test_lost_reservation_during_wait_never_signals_reused_group(self):
        class Reaped:
            pid=77
            def wait(self,timeout): raise ChildProcessError()
        observations=iter([None,ChildProcessError(),ChildProcessError()])
        def observe(*args):
            value=next(observations)
            if isinstance(value,Exception): raise value
            return value
        with patch('mixtape_owned_supervision.os.getpgid',return_value=77), \
             patch('mixtape_owned_supervision.os.waitid',side_effect=observe), \
             patch('mixtape_owned_supervision.group_present',return_value=True), \
             patch('mixtape_owned_supervision.os.killpg') as signals:
            outcome=wait_owned(Reaped(),execution_seconds=1,outer_seconds=2)
        signals.assert_not_called()
        self.assertFalse(outcome['cleanupComplete'])

    def test_verified_exited_direct_child_retains_reservation_when_getpgid_refuses(self):
        class Child:
            pid=77
            def wait(self,timeout): return 0
        exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED)
        with patch('mixtape_owned_supervision.os.getpgid',side_effect=ProcessLookupError), \
             patch('mixtape_owned_supervision.os.waitid',return_value=exited), \
             patch('mixtape_owned_supervision.group_present',return_value=False), \
             patch('mixtape_owned_supervision.os.killpg') as signals:
            # Class passes a group that was verified at its stopped launch.
            # Predecessor has no reservation argument; its existing path refuses.
            import inspect
            kwargs={'registered_group':77} if 'registered_group' in inspect.signature(wait_owned).parameters else {}
            outcome=wait_owned(Child(),execution_seconds=1,outer_seconds=2,**kwargs)
        self.assertTrue(outcome['cleanupComplete'])
        self.assertTrue(outcome['leaderReaped'])
        signals.assert_not_called()

    def test_nonchild_reused_group_cannot_be_signalled_by_supervisor(self):
        class Reaped:
            pid=77
            def wait(self,timeout): raise ChildProcessError()
        with patch('mixtape_owned_supervision.os.getpgid',return_value=77), \
             patch('mixtape_owned_supervision.os.waitid',side_effect=ChildProcessError), \
             patch('mixtape_owned_supervision.group_present',return_value=True), \
             patch('mixtape_owned_supervision.os.killpg') as signals:
            outcome=wait_owned(Reaped(),execution_seconds=1,outer_seconds=2)
        signals.assert_not_called()
        self.assertFalse(outcome['cleanupComplete'])

if __name__=='__main__': unittest.main()
