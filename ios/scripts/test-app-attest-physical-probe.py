#!/usr/bin/env python3
"""The physical probe spec embeds only the qualified widget, never BatonShare (TBX-10944).

Synthetic templates only: no device, profile, keychain or project generation.
"""
import copy,importlib.util,json,tempfile,unittest
from pathlib import Path

SCRIPT=Path(__file__).resolve().parent/'prepare-app-attest-physical-probe.py'
spec=importlib.util.spec_from_file_location('physical_probe_generator',SCRIPT);generator=importlib.util.module_from_spec(spec);spec.loader.exec_module(generator)
SUITE='probe-attest-'+'0'*32

def manual(identifier):
    return {'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':identifier},
        'configs':{'Debug':{'CODE_SIGN_STYLE':'Manual','PROVISIONING_PROFILE_SPECIFIER':'synthetic-profile'}}}}

def current_shape():
    # Mirrors ios/project.yml: the app embeds both extensions; BatonShare has no Debug profile.
    targets={'BatonMobile':manual('io.tonebox.baton'),'BatonWidgets':manual('io.tonebox.baton.widgets'),
        'BatonShare':{'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'io.tonebox.baton.share'}}},
        'BatonMobileTests':{'dependencies':[{'target':'BatonMobile'}]}}
    targets['BatonMobile']['dependencies']=[{'target':'BatonWidgets'},{'target':'BatonShare'},{'package':'BatonShareKit'}]
    return {'targets':targets,'schemes':{}}

class PhysicalProbeShare(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(prefix='baton-probe-share-');self.addCleanup(temp.cleanup)
        self.root=Path(temp.name);self.root.chmod(0o700)

    def prepare(self,shape,label):
        template=self.root/(label+'.json');template.write_text(json.dumps(shape));template.chmod(0o600)
        return generator.prepare(template,self.root/label,SUITE)

    def test_current_project_shape_keeps_share_out_of_the_probe_build(self):
        result=self.prepare(current_shape(),'current')
        emitted=json.loads(Path(result['spec']).read_text());targets=emitted['targets']
        self.assertEqual(targets['BatonAppAttestPhysicalHost']['dependencies'],[{'target':'BatonWidgets'}])
        self.assertEqual(targets['BatonAppAttestPhysicalTests']['dependencies'],[{'target':'BatonAppAttestPhysicalHost'}])
        self.assertEqual(set(emitted['schemes']['BatonAppAttestPhysical']['build']['targets']),
            {'BatonAppAttestPhysicalHost','BatonAppAttestPhysicalTests'})
        self.assertEqual(targets['BatonShare'],current_shape()['targets']['BatonShare'])
        self.assertFalse(result['installed']);self.assertFalse(result['launched'])

    def test_widget_reaching_share_is_refused_before_any_output(self):
        shape=current_shape();shape['targets']['BatonWidgets']['dependencies']=[{'target':'BatonShare'}]
        with self.assertRaises(ValueError):self.prepare(shape,'reaches-share')
        self.assertFalse((self.root/'reaches-share').exists())

    def test_widget_without_manual_profile_is_refused(self):
        shape=current_shape();del shape['targets']['BatonWidgets']['settings']['configs']['Debug']['PROVISIONING_PROFILE_SPECIFIER']
        with self.assertRaises(ValueError):self.prepare(shape,'unsigned-widget')
        self.assertFalse((self.root/'unsigned-widget').exists())

    def test_share_identity_cannot_stand_in_for_the_widget(self):
        shape=current_shape();shape['targets']['BatonWidgets']=copy.deepcopy(manual('io.tonebox.baton.share'))
        with self.assertRaises(ValueError):self.prepare(shape,'wrong-identity')

if __name__=='__main__':unittest.main(verbosity=2)
