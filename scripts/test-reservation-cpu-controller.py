#!/usr/bin/env python3
"""Pure-mock qualification-controller tests; no real child or guard launch."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('qualification',ROOT/'scripts/test-owned-fixture-reservation-cpu.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class Held(BaseException): pass

class ControllerTests(unittest.TestCase):
    def fault_case(self,fault):
        with tempfile.TemporaryDirectory(prefix='baton-tbx9312-mock-',dir='/private/tmp') as temporary:
            root=Path(temporary);root.rmdir();handlers={}
            class Owned:
                def __init__(self,*args): self.groups=[{'sessionVerified':True}]
                def start(self,*args): return SimpleNamespace(pid=77,returncode=None)
                def wait(self,*args,**kwargs): raise RuntimeError('synthetic supervision refusal')
                def cleanup(self):
                    if fault=='cleanup-failure': raise RuntimeError('synthetic cleanup refusal')
                    return {'launchUncertain':False,'failures':['unknown owned cleanup'],
                        'registeredGroupsAbsent':False,'schemeRestoredExactly':True,'simulatorAbsent':None,'containerAbsent':None}
            original=module.write_receipt
            def receipt(path,value):
                if Path(path).name=={'result':'cpu-result.json','hold':'cpu-custody-hold.json',
                    'signal':'cpu-holder-interruption.json'}.get(fault): raise OSError('synthetic storage refusal')
                return original(path,value)
            def registration(sig,handler): handlers[sig]=handler
            def observation(seconds):
                if fault=='signal':
                    for sig in [module.signal.SIGINT,module.signal.SIGTERM,module.signal.SIGHUP]: handlers[sig](sig,None)
                raise Held()
            exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED,si_status=0)
            with patch('sys.argv',['qualification','--source','a'*40,'--output',str(root)]), \
                 patch.object(module.subprocess,'check_output',return_value=('a'*40+'\n').encode()), \
                 patch.object(module.subprocess,'run',return_value=SimpleNamespace(returncode=0)), \
                 patch.object(module,'ReservedOwnedFixture',Owned), \
                 patch.object(module.os,'waitid',return_value=exited), \
                 patch.object(module,'write_receipt',side_effect=receipt), \
                 patch('signal.setitimer'),patch('signal.signal',side_effect=registration), \
                 patch.object(module.time,'sleep',side_effect=observation):
                failure_patch=patch.object(module,'write_failure',side_effect=OSError('synthetic failure receipt')) if fault in ['cleanup-failure','failure'] else patch.object(module,'write_failure',wraps=module.write_failure)
                output_patch=patch.object(module,'print',side_effect=BrokenPipeError('synthetic closed output'),create=True) if fault=='output' else patch.object(module,'print',wraps=print,create=True)
                with failure_patch,output_patch:
                    escaped=None
                    try: module.main()
                    except BaseException as error: escaped=error
                    self.assertIsInstance(escaped,Held,'Unqualified controller escaped instead of staying in custody')

    def test_result_receipt_failure_cannot_exit_unknown_custody(self): self.fault_case('result')
    def test_hold_receipt_failure_cannot_exit_unknown_custody(self): self.fault_case('hold')
    def test_broken_output_cannot_exit_unknown_custody(self): self.fault_case('output')
    def test_all_handled_signal_receipt_failures_preserve_unknown_custody(self): self.fault_case('signal')
    def test_cleanup_failure_receipt_failure_cannot_exit_unknown_custody(self): self.fault_case('cleanup-failure')
    def test_active_failure_receipt_failure_preserves_unknown_custody(self): self.fault_case('failure')

    def test_unknown_cleanup_retains_live_controller_instead_of_returning(self):
        with tempfile.TemporaryDirectory(prefix='baton-tbx9312-mock-',dir='/private/tmp') as temporary:
            root=Path(temporary); root.rmdir()  # Empty mocked fixture; runner recreates it.
            class Owned:
                def __init__(self,*args): self.groups=[{'sessionVerified':True}]
                def start(self,*args): return SimpleNamespace(pid=77,returncode=None)
                def wait(self,*args,**kwargs): raise RuntimeError('synthetic supervision refusal')
                def cleanup(self): return {'launchUncertain':False,'failures':['unknown owned cleanup'],
                    'registeredGroupsAbsent':False,'schemeRestoredExactly':True,'simulatorAbsent':None,'containerAbsent':None}
            exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED,si_status=0)
            with patch('sys.argv',['qualification','--source','a'*40,'--output',str(root)]), \
                 patch.object(module.subprocess,'check_output',return_value=('a'*40+'\n').encode()), \
                 patch.object(module.subprocess,'run',return_value=SimpleNamespace(returncode=0)), \
                 patch.object(module,'ReservedOwnedFixture',Owned), \
                 patch.object(module.os,'waitid',return_value=exited), \
                 patch('signal.setitimer'), patch('signal.signal'), \
                 patch.object(module.time,'sleep',side_effect=Held):
                with self.assertRaises(Held): module.main()
            receipt=json.loads((root/'cpu-custody-hold.json').read_bytes())
            self.assertFalse(receipt['qualified'])
            self.assertTrue(receipt['controllerRemainsAlive'])

    def test_dirty_runner_refuses_before_any_child_or_output_launch(self):
        with tempfile.TemporaryDirectory(prefix='baton-tbx9312-mock-',dir='/private/tmp') as temporary:
            root=Path(temporary); root.rmdir()
            class Owned:
                def __init__(self,*args):
                    self.groups=[{'sessionVerified':True,'closed':True,'reservedLeader':False,
                        'supervision':{'leaderReaped':True,'ownedGroupPending':False,'inspectionProcessPending':False}}]
                def start(self,*args): self.child=SimpleNamespace(pid=77,returncode=None); return self.child
                def wait(self,*args,**kwargs): self.child.returncode=0; return 0
                def cleanup(self): return {'launchUncertain':False,'failures':[],
                    'registeredGroupsAbsent':True,'schemeRestoredExactly':True,'simulatorAbsent':None,'containerAbsent':None}
            def dirty(argv,**kwargs):
                return SimpleNamespace(returncode=1 if 'scripts/test-owned-fixture-reservation-cpu.py' in argv else 0)
            exited=SimpleNamespace(si_pid=77,si_code=os.CLD_EXITED,si_status=0)
            with patch('sys.argv',['qualification','--source','a'*40,'--output',str(root)]), \
                 patch.object(module.subprocess,'check_output',return_value=('a'*40+'\n').encode()), \
                 patch.object(module.subprocess,'run',side_effect=dirty), \
                 patch.object(module,'ReservedOwnedFixture',side_effect=Owned) as launch, \
                 patch.object(module.os,'waitid',return_value=exited), patch('signal.setitimer'), patch('signal.signal'):
                with self.assertRaises(SystemExit): module.main()
                launch.assert_not_called()
            self.assertFalse(root.exists())

if __name__=='__main__': unittest.main()
