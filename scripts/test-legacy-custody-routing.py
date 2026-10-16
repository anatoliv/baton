#!/usr/bin/env python3
"""Observe actual caller deadlines with no process, timer or signal operation."""
import importlib.util
import signal
from pathlib import Path
import unittest
from unittest.mock import patch
import mixtape_owned_lifecycle as lifecycle

ROOT = Path(__file__).parent
CALLERS = ['probe-incoming-share-flow.py', 'probe-mixtape-composer-flow.py',
           'test-mixtape-native-stage.py', 'owned_fixture_cpu_support.py']

def load(name):
    spec = importlib.util.spec_from_file_location('routing_' + name.replace('-', '_'), ROOT / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

observer = load('test-custody-hold-setup.py')

class CallerCustodyRoutingTests(unittest.TestCase):
    def test_each_actual_caller_retains_unknown_custody_after_failed_disarm(self):
        for name in CALLERS:
            with self.subTest(caller=name):
                now = [0.0]
                deadline = load(name).Deadline(clock=lambda: now[0])
                with patch.object(lifecycle.signal, 'setitimer', side_effect=OSError('synthetic')), \
                     patch.object(lifecycle.os, '_exit', side_effect=observer.AutomaticExitObserved) as exit_call:
                    try:
                        observer.observe_hold(deadline)
                    except OSError:
                        pass
                    now[0] = deadline.hard_end
                    try:
                        deadline.alarm(signal.SIGALRM, None)
                    except observer.AutomaticExitObserved:
                        pass
                exit_call.assert_not_called()

    def test_each_actual_caller_preserves_normal_bounds_and_active_hard_exit(self):
        for name in CALLERS:
            with self.subTest(caller=name):
                now = [0.0]
                deadline = load(name).Deadline(clock=lambda: now[0])
                self.assertEqual((deadline.hard_end, deadline.reserve, deadline.remaining()), (900, 90, 810))
                now[0] = deadline.hard_end
                with patch.object(lifecycle.signal, 'setitimer'), \
                     patch.object(lifecycle.os, '_exit', side_effect=observer.AutomaticExitObserved) as exit_call:
                    with self.assertRaises(observer.AutomaticExitObserved):
                        deadline.alarm(signal.SIGALRM, None)
                exit_call.assert_called_once_with(124)

if __name__ == '__main__':
    unittest.main()
