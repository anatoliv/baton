#!/usr/bin/env python3
"""Mock-only non-reaping observation and synchronous callback regressions."""
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from incoming_fixture_lifecycle import Deadline, FixtureDiagnosticFailure
from incoming_fixture_delivery import DeliveryControl
from mixtape_owned_lifecycle import ReservedOwnedFixture
from mixtape_owned_supervision import wait_owned

class CallbackSafetyTests(unittest.TestCase):
    def owned(self, root):
        owned=ReservedOwnedFixture(root,{},Deadline())
        class Child:
            pid=77; returncode=None
            def wait(self,timeout): self.returncode=0; return 0
            def poll(self): raise AssertionError('Observation must not reap')
        child=Child(); owned.processes=[child]
        owned.groups=[dict(pid=77,pgid=77,closed=False,started=True,reservedLeader=True,sessionVerified=True)]
        return owned,child

    def test_running_observes_exit_without_reaping_original_child(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as root:
            owned,child=self.owned(root)
            exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED)
            with patch('os.waitid',side_effect=[None,exited]) as observation,patch('os.killpg') as signals:
                self.assertTrue(owned.running(child)); self.assertFalse(owned.running(child))
            self.assertIsNone(child.returncode); signals.assert_not_called()
            self.assertTrue(all(c.args[2]&os.WNOWAIT for c in observation.call_args_list))
            self.assertTrue(owned.groups[0]['reservedLeader'])

    def test_running_unknown_reservation_refuses_without_numeric_signal(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as root:
            owned,child=self.owned(root)
            with patch('os.waitid',side_effect=ChildProcessError),patch('os.killpg') as signals:
                with self.assertRaises(FixtureDiagnosticFailure): owned.running(child)
            signals.assert_not_called(); self.assertTrue(owned.groups[0]['ownershipUncertain'])

    def supervise(self, child, callback, cancelled=None, observations=None):
        exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED)
        with patch('os.getpgid',return_value=77),patch('os.waitid',side_effect=observations or [None,exited]), \
             patch('mixtape_owned_supervision.group_present',return_value=False),patch('os.killpg') as signals:
            result=wait_owned(child,execution_seconds=1,outer_seconds=2,on_tick=callback,cancelled=cancelled)
        return result,signals

    def test_delivery_callback_serves_synchronously_before_child_exit(self):
        events=[]
        class Child:
            pid=77
            def wait(self,timeout): events.append('reap'); return 0
        delivery=DeliveryControl.__new__(DeliveryControl); delivery.deadline=Deadline()
        delivery.server=SimpleNamespace(handle_request=lambda:events.append('authenticated-delivery'))
        result,signals=self.supervise(Child(),delivery.serve_one)
        self.assertEqual(events,['authenticated-delivery','reap'])
        self.assertTrue(result['cleanupComplete']); signals.assert_not_called()

    def test_callback_refusal_fails_phase_and_keeps_cleanup_qualified(self):
        class Child:
            pid=77
            def wait(self,timeout): return 0
        def refuse(): raise RuntimeError('synthetic no-fetch refusal')
        result,signals=self.supervise(Child(),refuse,observations=[None,None])
        self.assertNotEqual(result['testExit'],0); self.assertEqual(result['errorClass'],'RuntimeError')
        self.assertTrue(result['cleanupComplete']); self.assertTrue(result['leaderReaped'])
        signals.assert_called_once()

    def test_cancellation_skips_callback_and_reserves_cleanup(self):
        calls=[]
        class Child:
            pid=77
            def wait(self,timeout): return 0
        result,signals=self.supervise(Child(),lambda:calls.append('delivered'),cancelled=lambda:True,observations=[None])
        self.assertEqual(calls,[]); self.assertTrue(result['cancelled']); self.assertTrue(result['cleanupComplete'])
        signals.assert_not_called()

    def test_callback_lost_child_reservation_cannot_signal_reused_group(self):
        class Child:
            pid=77
            def wait(self,timeout): raise AssertionError('No unqualified reap')
        def lost(*args):
            if not observations: raise ChildProcessError()
            return observations.pop()
        observations=[None]
        with patch('os.getpgid',return_value=77),patch('os.waitid',side_effect=lost), \
             patch('mixtape_owned_supervision.group_present',return_value=True),patch('os.killpg') as signals:
            result=wait_owned(Child(),execution_seconds=1,outer_seconds=2,on_tick=lambda:None)
        signals.assert_not_called(); self.assertFalse(result['cleanupComplete']); self.assertFalse(result['leaderReaped'])

class CustodyHoldTests(unittest.TestCase):
    def test_legacy_diagnostic_unknown_cleanup_retains_original_controller(self):
        import importlib.util
        import owned_fixture_cpu_support as support
        diagnostic=Path(os.environ.get('BATON_CPU_DIAGNOSTIC_SOURCE',
            str(Path(__file__).with_name('test-incoming-fixture-diagnostics.py'))))
        spec=importlib.util.spec_from_file_location('mocked_legacy_diagnostic',diagnostic)
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        class HoldObserved(BaseException): pass
        class FakeOwned:
            def __init__(self,root,env,deadline): self.root=Path(root); self.deadline=deadline
            def command(self,*args,**kwargs): return b'response\ndiagnostic\n',0
            def cleanup(self): return {'launchUncertain':True,'failures':['synthetic unknown'],'registeredGroupsAbsent':False}
        with patch.object(support,'ReservedOwnedFixture',FakeOwned), \
             patch.object(module,'OwnedFixture',FakeOwned,create=True), \
             patch.object(support,'retain_custody',side_effect=HoldObserved) as hold, \
             patch('signal.setitimer'),patch('subprocess.Popen',side_effect=AssertionError('No child permitted')):
            try: module.DiagnosticTests().test_owned_default_capture_preserves_existing_merged_response()
            except (Exception,HoldObserved): pass
        hold.assert_called_once()

    def test_unknown_cpu_cleanup_never_returns_or_disarms_without_hold(self):
        import owned_fixture_cpu_support as support
        class HoldObserved(BaseException): pass
        deadline=SimpleNamespace(disarm=lambda:None)
        owned=SimpleNamespace(root=Path('/unopened/cpu'),deadline=deadline,
                              cleanup=lambda:{'launchUncertain':True})
        with patch.object(support,'retain_custody',side_effect=HoldObserved) as hold:
            with self.assertRaises(HoldObserved): support.finish_cpu_fixture(owned)
        hold.assert_called_once_with(owned.root,deadline)

    def test_positive_cpu_cleanup_disarms_and_returns(self):
        import owned_fixture_cpu_support as support
        from unittest.mock import Mock
        cleanup={'launchUncertain':False,'failures':[],'registeredGroupsAbsent':True,
                 'schemeRestoredExactly':True,'containerAbsent':None,'simulatorAbsent':None}
        deadline=SimpleNamespace(disarm=Mock())
        owned=SimpleNamespace(root=Path('/unopened/cpu'),deadline=deadline,cleanup=lambda:cleanup)
        with patch.object(support,'retain_custody') as hold: support.finish_cpu_fixture(owned)
        hold.assert_not_called(); deadline.disarm.assert_called_once()

    def test_hold_survives_failed_receipts_broken_output_and_handled_signals(self):
        import importlib.util
        import mixtape_owned_lifecycle as lifecycle
        path=Path(__file__).with_name('test-custody-hold-setup.py')
        spec=importlib.util.spec_from_file_location('bounded_hold_observer',path)
        observer=importlib.util.module_from_spec(spec);spec.loader.exec_module(observer)
        events=[]
        deadline=SimpleNamespace(disarm=lambda:events.append('disarmed'))
        def failed_receipt(*args):
            self.assertEqual(events[0],'disarmed');events.append('receipt-failed');raise OSError('synthetic')
        def handled_signals(handlers):
            if 'signals-observed' not in events:
                for call in handlers.call_args_list: call.args[1](None,None)
                events.append('signals-observed')
        handlers=observer.observe_hold(deadline,io_error=failed_receipt,
            print_error=BrokenPipeError,after_tick=handled_signals)
        self.assertEqual(handlers.call_count,3)
        self.assertIn('signals-observed',events)
        self.assertEqual(events.count('receipt-failed'),4)

    def test_cleanup_exception_and_failed_diagnostic_cannot_escape_hold(self):
        import owned_fixture_cpu_support as support
        class HoldObserved(BaseException): pass
        owned=SimpleNamespace(root=Path('/unopened/cpu'),deadline=object())
        def refused(): raise OSError('synthetic cleanup refusal')
        owned.cleanup=refused
        with patch.object(support,'write_receipt',side_effect=OSError), \
             patch.object(support,'retain_custody',side_effect=HoldObserved) as hold:
            with self.assertRaises(HoldObserved): support.finish_cpu_fixture(owned)
        hold.assert_called_once_with(owned.root,owned.deadline)

if __name__=='__main__': unittest.main()
