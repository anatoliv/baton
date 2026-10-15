#!/usr/bin/env python3
"""Actual adapter configuration selects and executes accepted checkout custody."""
import hashlib,importlib.util,json,os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
REPO=Path(__file__).resolve().parents[2]

class IntegratedRouting(unittest.TestCase):
    def test_actual_configuration_imports_checkout_pinned_helpers_without_child_actions(self):
        spec=importlib.util.spec_from_file_location('integrated_attest_adapter',REPO/'ios/scripts/app_attest_owned_controller.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='baton-attest-routing-',dir='/private/tmp') as temp:
            root=Path(temp);os.chmod(root,0o700)
            names=['incoming_fixture_lifecycle','mixtape_owned_supervision','mixtape_owned_lifecycle'];pins={str(REPO/'scripts'/(name+'.py')):hashlib.sha256((REPO/'scripts'/(name+'.py')).read_bytes()).hexdigest() for name in names}
            p=root/'input-pins.json';p.write_text(json.dumps({'inputSHA256':pins}));os.chmod(p,0o600)
            module.configure(root,REPO)
            with patch.object(module.subprocess,'Popen',side_effect=AssertionError('No process admission')) as birth,patch.object(module.os,'waitid',side_effect=AssertionError('No waitid admission')) as waitid,patch.object(module.os,'killpg',side_effect=AssertionError('No signal admission')) as signal:
                runner=module.supervisor()
            # Returned behavior comes from these imported, hash-qualified actual modules.
            self.assertEqual(runner.wait_owned.__code__.co_filename,str(REPO/'scripts/mixtape_owned_supervision.py'))
            self.assertEqual(runner.retain_custody.__code__.co_filename,str(REPO/'scripts/mixtape_owned_lifecycle.py'))
            held=runner.retain_custody.__globals__['CustodyDeadline'](clock=lambda:0)
            self.assertEqual((held.hard_end,held.reserve,held.remaining()),(900,90,810))
            held.custody_retained=True
            with patch.object(runner.retain_custody.__globals__['os'],'_exit',side_effect=AssertionError('No exit admission')) as exit_call:
                self.assertIsNone(held.alarm(14,None))
            exit_call.assert_not_called();birth.assert_not_called();waitid.assert_not_called();signal.assert_not_called()

    def test_actual_retained_host_generator_accepts_short_suite_and_refuses_old_long_suite(self):
        retained=Path('/private/tmp/baton-tbx-8711-physical/ios')
        spec=importlib.util.spec_from_file_location('retained_host_generator',retained/'scripts/prepare-app-attest-physical-probe.py');generator=importlib.util.module_from_spec(spec);spec.loader.exec_module(generator)
        storage=(retained/'Tests/BatonAppAttestPhysicalHost/PhysicalAttestProbeStorage.swift').read_text()
        self.assertIn('(14...53).contains(suite.count)',storage)
        with tempfile.TemporaryDirectory(prefix='baton-host-grammar-MOCK-',dir='/private/tmp') as temp:
            root=Path(temp);root.chmod(0o700);template=root/'spec.json'
            targets={name:{'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':identifier},'configs':{'Debug':{'CODE_SIGN_STYLE':'Manual','PROVISIONING_PROFILE_SPECIFIER':'synthetic-profile'}}}} for name,identifier in [('BatonMobile','io.tonebox.baton'),('BatonWidgets','io.tonebox.baton.widgets')]}
            targets['BatonMobileTests']={};template.write_text(json.dumps({'targets':targets,'schemes':{}}));template.chmod(0o600)
            suite='probe-attest-'+'0'*32
            result=generator.prepare(template,root/'short',suite)
            emitted=json.loads(Path(result['spec']).read_text())
            self.assertEqual(emitted['schemes']['BatonAppAttestPhysical']['test']['environmentVariables']['baton.defaultsSuite'],suite)
            self.assertEqual(len(suite),45);self.assertFalse(result['installed']);self.assertFalse(result['launched'])
            long='probe-attest-minimal-20261007-8711-'+'0'*32
            self.assertEqual(len(long),67)
            with self.assertRaises(ValueError):generator.prepare(template,root/'long',long)
            self.assertFalse((root/'long').exists())

if __name__=='__main__':unittest.main()
