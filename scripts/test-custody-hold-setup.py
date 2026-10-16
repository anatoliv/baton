#!/usr/bin/env python3
"""No-child fault regressions for retaining the original controller on uncertainty."""
import ast
import inspect
import signal
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import mixtape_owned_lifecycle as lifecycle
from incoming_fixture_lifecycle import Deadline

class HoldObserved(BaseException):
    """External bounded observer, never raised by a production hold dependency."""

class AutomaticExitObserved(BaseException):
    pass


def observe_hold(deadline, *, handler_error=None, io_error=None, sleep_errors=(), after_tick=None, print_error=None):
    events=[]
    source,start=inspect.getsourcelines(lifecycle.retain_custody)
    tree=ast.parse(''.join(source))
    boundary=start+next(node.lineno for node in ast.walk(tree) if isinstance(node,ast.While))-1
    errors=list(sleep_errors)
    def sleep(_seconds):
        events.append('tick')
        if after_tick is not None:
            after_tick(handlers)
        if errors:
            raise errors.pop(0)
    def trace(frame,event,_arg):
        # Stop at the next loop boundary OUTSIDE the production exception handler,
        # after observing two ticks. Dependencies cannot use this escape.
        if frame.f_code is lifecycle.retain_custody.__code__ and event=='line' and frame.f_lineno==boundary and len(events)>=2:
            raise HoldObserved()
        return trace
    prior=sys.gettrace()
    with patch.object(lifecycle.signal,'signal',side_effect=handler_error) as handlers, \
         patch.object(lifecycle,'write_receipt',side_effect=io_error), \
         patch('builtins.print',side_effect=io_error if print_error is None else print_error), \
         patch.object(lifecycle.time,'sleep',side_effect=sleep):
        sys.settrace(trace)
        try:
            try: lifecycle.retain_custody('/unopened/mock-custody',deadline)
            except HoldObserved: pass
            else: raise AssertionError('Unknown custody returned')
        finally:
            sys.settrace(prior)
    if len(events)<2:
        raise AssertionError('Original controller did not reach its live hold')
    return handlers

class CustodySetupTests(unittest.TestCase):
    def test_failed_disarm_keeps_original_controller_in_hold(self):
        deadline=SimpleNamespace(disarm=Mock(side_effect=OSError('synthetic')))
        observe_hold(deadline)
        deadline.disarm.assert_called_once()

    def test_handler_setup_baseexception_keeps_original_controller_in_hold(self):
        observe_hold(SimpleNamespace(disarm=lambda:None),handler_error=SystemExit(7))

    def test_io_and_baseexception_sleep_faults_cannot_escape_hold(self):
        observe_hold(SimpleNamespace(disarm=lambda:None),io_error=SystemExit(8),sleep_errors=[SystemExit(9),KeyboardInterrupt()])

    def test_failed_disarm_cannot_leave_automatic_alarm_exit_on_unknown_custody(self):
        now=[0.0]
        # Before the opt-in class exists, this is the exact old caller Deadline.
        deadline=getattr(lifecycle,'CustodyDeadline',Deadline)(clock=lambda:now[0])
        with patch.object(lifecycle.signal,'setitimer',side_effect=OSError('synthetic')), \
             patch.object(lifecycle.os,'_exit',side_effect=AutomaticExitObserved) as automatic:
            try: observe_hold(deadline)
            except OSError: pass  # Observe the old setup failure, then its live alarm.
            now[0]=deadline.hard_end
            try: deadline.alarm(signal.SIGALRM,None)
            except AutomaticExitObserved: pass
        automatic.assert_not_called()

    def test_active_deadline_still_exits_at_original_hard_bound(self):
        now=[0.0]
        deadline=getattr(lifecycle,'CustodyDeadline',Deadline)(clock=lambda:now[0])
        now[0]=deadline.hard_end
        with patch.object(lifecycle.os,'_exit',side_effect=AutomaticExitObserved) as automatic, \
             patch.object(lifecycle.signal,'setitimer') as timer:
            with self.assertRaises(AutomaticExitObserved): deadline.alarm(signal.SIGALRM,None)
        automatic.assert_called_once_with(124)
        timer.assert_not_called()

    def test_normal_active_and_cleanup_bounds_remain_900_810_90(self):
        now=[0.0]
        deadline=getattr(lifecycle,'CustodyDeadline',Deadline)(clock=lambda:now[0])
        self.assertEqual(deadline.remaining(),810)
        self.assertEqual((deadline.hard_end,deadline.reserve),(900,90))
        with patch.object(lifecycle.signal,'setitimer'):
            now[0]=10; deadline.enter_cleanup()
        self.assertEqual(deadline.remaining(),90)
        self.assertEqual(deadline.hard_end,900)

if __name__=='__main__': unittest.main()
