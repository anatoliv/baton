#!/usr/bin/env python3
"""Pure mocks of the actual native controller's final routing; no child or SDK."""
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from incoming_fixture_lifecycle import FixtureTimeout
from mixtape_owned_lifecycle import cleanup_qualified

REPO=Path(__file__).resolve().parent.parent
class ControllerHeld(BaseException): pass

def best_effort(action,*args):
    try: action(*args)
    except BaseException: pass

class ControllerCustodyTests(unittest.TestCase):
    def run_tail(self,cleanup=None,cleanup_error=None,receipt_error=None):
        # Execute the exact final routing under inert owned/deadline/receipt mocks,
        # preserving its exception semantics without importing or running main.
        source=(REPO/'scripts/test-mixtape-native-stage.py').read_text()
        tail=source.rsplit('    finally:\n',1)[1].split('\nif __name__',1)[0]
        owned=SimpleNamespace(cleanup=Mock(return_value=cleanup,side_effect=cleanup_error))
        deadline=SimpleNamespace(disarm=Mock())
        hold=Mock(side_effect=ControllerHeld)
        writer=Mock(side_effect=receipt_error)
        scope={'owned':owned,'deadline':deadline,'cleanup_qualified':cleanup_qualified,
            'retain_custody':hold,'best_effort':best_effort,'write_receipt':writer,
            'root':Path('/private/tmp/no-run-controller-custody-fixture'),
            'current':'0'*40,'result':1,'scope':'pure mock'}
        exec('def controller_tail():\n    try:\n        pass\n    finally:\n'+tail,scope)
        held=False
        with patch('builtins.print'):
            try: scope['controller_tail']()
            except ControllerHeld: held=True
            except BaseException: pass
        return held,hold,writer,deadline

    def test_unqualified_cleanup_keeps_original_controller(self):
        held,hold,writer,_=self.run_tail({'launchUncertain':True,'failures':['unknown']})
        self.assertTrue(held,'Unqualified cleanup must retain the original parent, not return into shell-only hold')
        hold.assert_called_once()
        writer.assert_not_called()
    def test_cleanup_exception_keeps_original_controller(self):
        held,hold,writer,_=self.run_tail(cleanup_error=FixtureTimeout())
        self.assertTrue(held,'Cleanup exception must retain the original parent')
        hold.assert_called_once()
        writer.assert_not_called()
    def test_receipt_failure_with_unknown_cleanup_keeps_original_controller(self):
        held,hold,writer,_=self.run_tail({'launchUncertain':True,'failures':['unknown']},receipt_error=OSError('mock'))
        self.assertTrue(held,'Diagnostic I/O must not discard original custody')
        hold.assert_called_once()
        writer.assert_not_called()
    def test_qualified_cleanup_can_return_and_publish_release(self):
        cleanup={'launchUncertain':False,'failures':[],'registeredGroupsAbsent':True,
            'schemeRestoredExactly':True,'simulatorAbsent':True,'containerAbsent':None}
        held,hold,writer,deadline=self.run_tail(cleanup)
        self.assertFalse(held);hold.assert_not_called();deadline.disarm.assert_called_once()
        self.assertTrue(any(call.args[0].name=='native-custody-release.json' for call in writer.call_args_list))
    def test_release_receipt_failure_keeps_controller_for_reconciliation(self):
        cleanup={'launchUncertain':False,'failures':[],'registeredGroupsAbsent':True,
            'schemeRestoredExactly':True,'simulatorAbsent':True,'containerAbsent':None}
        held,hold,_,_=self.run_tail(cleanup,receipt_error=OSError('mock'))
        self.assertTrue(held);hold.assert_called_once()

if __name__=='__main__': unittest.main()
