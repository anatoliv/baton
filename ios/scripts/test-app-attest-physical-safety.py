"""Actual controller/packet bodies with synthetic files and mocked child boundaries."""
import contextlib,importlib.util,io,json,os,subprocess,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock,patch

SCRIPTS=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('physical_packet_fixture',SCRIPTS/'test-app-attest-next-attempt.py')
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
class Held(BaseException):pass
CLEAN={'testExit':0,'timedOut':False,'cleanupComplete':True,'ownedGroupPending':False,'leaderReaped':True,'inspectionProcessPending':False}

def load(path,name):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def signed_output(packet):
    return {'result':'PASS','appleChainNonceAppIDAAGUIDReceiptVerified':True,'assertionVerified':True,
        'environment':'development','pinnedCaptureBuild':packet['captureBuild'],'pinnedCaptureSource':packet['captureSource'],
        'authenticatedCategories':[1],'attestationExtensionsPresent':True,'assertionExtensionsPresent':True,
        'assertionCounterPositive':True,'receiptFreshnessEnforced':True,'policyActivated':False}

class PhysicalSafetyTests(unittest.TestCase):
    def setUp(self):
        previous=os.umask(0o077);self.addCleanup(os.umask,previous)
        self.fixture=f.NextAttemptTests('test_explicit_fresh_namespace_paths_and_complete_runtime')
        self.fixture.setUp();self.addCleanup(self.fixture.tearDown);self.fixture.run_prepare()
        self.base=self.fixture.root;self.packet_path=self.base/'attempt-plan/manifest.json'
        self.packet=json.loads(self.packet_path.read_bytes());self.m=load(self.base/'run-physical-test.py','physical_controller')
        self.selection=self.fixture.base/'selection';f.write(self.selection,b'synthetic-device')
        self.binding=self.fixture.base/'admission.json'
        self.admitted={'schemaVersion':1,'deployment':'TBX-0000','restoreDeployment':'TBX-0001',
            'packetPath':str(self.packet_path),'packetSHA256':f.sha(self.packet_path),
            'selectionPath':str(self.selection),'selectionSHA256':f.sha(self.selection),
            'rootGO':True,'executionAdmitted':True,'unusedOnPhoneNamespaceQualified':True,'exclusiveContinuousCustodyQualified':True,'compiledCaptureNamespaceQualified':True}
        self.capture_evidence=self.fixture.base/'capture-namespace-evidence.json'
        source=self.fixture.repo/'ios/Tests/BatonAppAttestPhysicalTests/AppAttestIssuancePhysicalTests.swift'
        f.write(source,b'SYNTHETIC test-source association, not a native qualification')
        self.build_evidence=self.fixture.base/'capture-build-receipt.json';f.write(self.build_evidence,b'{"syntheticOnly":true,"actualBuilds":0}')
        evidence={'schemaVersion':1,'namespace':self.packet['suite'],'testIdentifier':self.m.TEST_IDENTIFIER,
            'appTreeSHA256':self.packet['appTreeSHA256'],'testBundleTreeSHA256':self.packet['testBundleTreeSHA256'],
            'newXctestrunSHA256':self.packet['newXctestrunSHA256'],'testSourceSHA256':f.sha(source),
            'buildReceiptSHA256':f.sha(self.build_evidence),'independentNamespaceAssociationQualified':True}
        build={key:evidence[key] for key in ['namespace','testIdentifier','testSourceSHA256','appTreeSHA256','testBundleTreeSHA256']}
        build.update(schemaVersion=1,sourceBuildAssociationQualified=True,syntheticOnly=True,actualBuilds=0)
        f.write(self.build_evidence,json.dumps(build).encode());evidence['buildReceiptSHA256']=f.sha(self.build_evidence)
        f.write(self.capture_evidence,json.dumps(evidence).encode())
        self.admitted.update(captureNamespaceEvidencePath=str(self.capture_evidence),captureNamespaceEvidenceSHA256=f.sha(self.capture_evidence))
        self.save_binding()
    def save_binding(self):f.write(self.binding,json.dumps(self.admitted).encode())
    def change_packet(self):
        f.write(self.packet_path,json.dumps(self.packet).encode());self.admitted['packetSHA256']=f.sha(self.packet_path);self.save_binding()
    def invoke(self,fault=None,summary=None,verify_exit=0,classification=None,writer_fault=False,print_fault=False,metadata_fault=False,copy_metadata_fault=False,elapsed_fault=None,late_cancel=False,sample_cancel=False,final_pin_refusal=False,clock_cancel=False):
        m=self.m;owned=load(self.base/'app_attest_owned_controller.py','physical_owned_mock');commands=[];held=False
        true_loader=m.load_pinned
        def loader(name,path,expected):
            if name=='physical_owned_adapter':return owned
            module=true_loader(name,path,expected)
            if name=='physical_copy_checks' and copy_metadata_fault:
                module.receipt=Mock(side_effect=OSError('synthetic copy metadata fault'))
            return module
        hold=Mock(side_effect=Held);old_writer=owned.private_file
        def writer(path,data):
            if writer_fault and path.name=='safe-test-receipt.json':raise OSError('synthetic final IO fault')
            return old_writer(path,data)
        def stage(name,command,runner,environment,deadline,execution,outer,reserve,custody):
            commands.append((name,command,execution,outer,reserve))
            custody.update(unknown=True,launchUncertain=True)
            if fault==name:raise RuntimeError('synthetic unqualified phase')
            custody.update(unknown=False,launchUncertain=False)
            if name=='summary':
                data=summary if summary is not None else {'totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0}
                f.write(owned.ROOT/'summary.log',data if isinstance(data,bytes) else json.dumps(data).encode())
            if name=='copy':f.write(self.base/'proof-TBX-0000/issuance.json',b'SYNTHETIC-only-not-Apple-proof')
            if name=='verify':f.write(owned.ROOT/'verify.log',json.dumps(classification if classification is not None else signed_output(self.packet)).encode())
            return {'phase':name,**CLEAN,'testExit':verify_exit if name=='verify' else 0}
        cancel_reads={'count':0,'clockCancelled':False}
        def cancelled():
            if len(commands)==4:
                cancel_reads['count']+=1
                if late_cancel or cancel_reads['clockCancelled'] or (sample_cancel and cancel_reads['count']>=2):return True
            if metadata_fault and len(commands)==4:raise OSError('synthetic final marker fault')
            return False
        clock={'now':100.0}
        def monotonic():
            if clock_cancel and len(commands)==4 and cancel_reads['count']>=1:cancel_reads['clockCancelled']=True
            if elapsed_fault=='copy' and len(commands)==3:clock['now']=121.0
            if elapsed_fault=='verify' and len(commands)==4:clock['now']=111.0
            return clock['now']
        actual_validate=m.validate_inputs
        def validate(packet):
            if final_pin_refusal and len(commands)==4:raise ValueError('synthetic final input refusal')
            return actual_validate(packet)
        output=io.StringIO()
        with patch.object(m,'validate_inputs',side_effect=validate),patch.object(m,'load_pinned',side_effect=loader),patch.object(m,'environment',return_value={}),patch.object(m.signal,'signal'),patch.object(m.time,'monotonic',side_effect=monotonic),\
             patch.object(owned,'supervisor',return_value=SimpleNamespace()),patch.object(owned,'stage',side_effect=stage),\
             patch.object(owned,'retain_original',hold),patch.object(owned,'private_file',side_effect=writer),\
             patch.object(owned,'cancel_requested',side_effect=cancelled),\
             patch.object(subprocess,'Popen',side_effect=AssertionError('real child forbidden')) as child,contextlib.redirect_stdout(output):
            if print_fault:
                with patch('builtins.print',side_effect=OSError('synthetic print fault')):
                    try:rc=m.run(self.binding,'TBX-0000')
                    except Held:held=True;rc=None
            else:
                try:rc=m.run(self.binding,'TBX-0000')
                except Held:held=True;rc=None
        child.assert_not_called()
        root=self.base/'test-TBX-0000';receipt=json.loads((root/'safe-test-receipt.json').read_bytes()) if (root/'safe-test-receipt.json').exists() else None
        return rc,held,hold,commands,receipt,root
    def final_refusal(self,**kwargs):
        rc,held,hold,commands,result,root=self.invoke(**kwargs)
        self.assertEqual(rc,1)
        self.assertFalse(held);hold.assert_not_called();self.assertEqual(len(commands),4)
        self.assertTrue(result['testsPassed']);self.assertTrue(result['authenticatedClassification'])
        self.assertTrue(result['allOwnedCleanupVerified']);self.assertTrue(result['restoreRequired'])
        self.assertFalse(result['acceptedSuccess']);self.assertTrue((root/'driver-finished').exists())
    def test_late_cancellation_is_terminal_failure_with_truthful_phase_facts(self):self.final_refusal(late_cancel=True)
    def test_final_input_refusal_is_terminal_failure_with_truthful_phase_facts(self):self.final_refusal(final_pin_refusal=True)
    def test_cancellation_between_final_check_and_metadata_sample_is_failure(self):self.final_refusal(sample_cancel=True)
    def test_cancellation_during_final_clock_is_sampled_as_failure(self):self.final_refusal(clock_cancel=True)
    def test_copy_metadata_fault_retains_before_diagnostic_io(self):
        _,held,hold,commands,_,root=self.invoke(copy_metadata_fault=True)
        self.assertTrue(held);hold.assert_called_once();self.assertEqual([c[0] for c in commands],['test','summary','copy'])
        self.assertFalse((root/'safe-test-receipt.json').exists());self.assertFalse((root/'driver-finished').exists())
    def test_copy_above_success_budget_does_not_verify(self):
        rc,held,_,commands,result,_=self.invoke(elapsed_fault='copy')
        self.assertEqual(rc,1);self.assertFalse(held);self.assertEqual(len(commands),3);self.assertFalse(result['authenticatedClassification'])
    def test_verify_above_success_budget_does_not_classify(self):
        rc,held,_,commands,result,_=self.invoke(elapsed_fault='verify')
        self.assertEqual(rc,1);self.assertFalse(held);self.assertEqual(len(commands),4);self.assertFalse(result['authenticatedClassification'])
    def test_tampered_external_test_bundle_refuses_before_output(self):
        f.write(self.fixture.test_bundle/'BatonAppAttestPhysicalTests',b'TAMPER')
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_omitted_external_test_bundle_pin_refuses_before_output(self):
        self.packet['executionInputSHA256'].pop(str(self.fixture.test_bundle/'BatonAppAttestPhysicalTests'));self.change_packet()
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_partial_source_set_cannot_be_rebound_into_admission(self):
        missing=next(iter(self.packet['qualificationConfig']['sourceSHA256']))
        self.packet['qualificationConfig']['sourceSHA256'].pop(missing)
        self.packet['executionInputSHA256'].pop(str(self.fixture.repo/missing));self.change_packet()
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_extra_private_classification_fields_are_not_exposed(self):
        data=signed_output(self.packet);data['unexpectedPrivateField']='SYNTHETIC'
        rc,_,_,_,result,_=self.invoke(classification=data)
        self.assertEqual(rc,1);self.assertFalse(result['authenticatedClassification']);self.assertNotIn('classification',result)
    def test_copy_custody_refuses_oversize_symlink_and_wrong_mode(self):
        m=load(SCRIPTS/'copy-app-attest-probe-evidence.py','pure_copy');root=self.fixture.base/'custody';root.mkdir(mode=0o700)
        p=root/'issuance.json';f.write(p,b'x'*65537)
        with self.assertRaises(ValueError):m.receipt(p)
        f.write(p,b'SYNTHETIC');p.chmod(0o644)
        with self.assertRaises(ValueError):m.receipt(p)
        p.unlink();p.symlink_to(self.selection)
        with self.assertRaises(ValueError):m.receipt(p)
    def test_normal_one_controller_routes_only_selected_test_summary_copy_verify(self):
        rc,held,_,commands,result,_=self.invoke();self.assertEqual(rc,0);self.assertFalse(held)
        self.assertEqual([x[0] for x in commands],['test','summary','copy','verify'])
        self.assertEqual([x[2:] for x in commands],[(220,230,55),(10,10,40),(20,25,15),(10,10,5)])
        self.assertEqual(commands[0][1][commands[0][1].index('-maximum-test-execution-time-allowance')+1],'180')
        self.assertEqual(commands[0][1][commands[0][1].index('-collect-test-diagnostics')+1],'never')
        self.assertEqual(commands[2][1][commands[2][1].index('--source')+1],'Library/Application Support/Baton Probes/'+self.packet['suite']+'/AppAttestPhysicalEvidence/issuance.json')
        self.assertEqual(result['counts'],{'totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0})
        self.assertTrue(result['authenticatedClassification']);self.assertTrue(result['acceptedSuccess']);self.assertFalse(result['policyActivated'])
    def unknown(self,phase):
        _,held,hold,commands,_,root=self.invoke(fault=phase)
        self.assertTrue(held);hold.assert_called_once();self.assertFalse((root/'safe-test-receipt.json').exists());self.assertFalse((root/'driver-finished').exists())
        self.assertEqual(commands[-1][0],phase)
    def test_unknown_test_birth_retains_original_before_io(self):self.unknown('test')
    def test_unknown_summary_retains_original_before_io(self):self.unknown('summary')
    def test_unknown_copy_retains_original_before_io(self):self.unknown('copy')
    def test_unknown_verifier_retains_original_before_io(self):self.unknown('verify')
    def test_final_metadata_fault_retains_original_before_receipt(self):
        _,held,hold,_,_,root=self.invoke(metadata_fault=True);self.assertTrue(held);hold.assert_called_once();self.assertFalse((root/'safe-test-receipt.json').exists())
    def test_final_receipt_fault_retains_original_without_finished(self):
        _,held,hold,_,_,root=self.invoke(writer_fault=True);self.assertTrue(held);hold.assert_called_once();self.assertFalse((root/'driver-finished').exists())
    def test_print_fault_retains_original_without_finished(self):
        _,held,hold,_,_,root=self.invoke(print_fault=True);self.assertTrue(held);hold.assert_called_once();self.assertFalse((root/'driver-finished').exists())
    def test_oversized_summary_refuses_before_copy(self):
        rc,held,_,commands,result,_=self.invoke(summary=b' '*65537);self.assertEqual(rc,1);self.assertFalse(held);self.assertEqual([x[0] for x in commands],['test','summary']);self.assertFalse(result['testsPassed'])
    def test_skipped_selected_test_refuses_copy(self):
        rc,_,_,commands,result,_=self.invoke(summary={'totalTestCount':1,'passedTests':0,'failedTests':0,'skippedTests':1});self.assertEqual(rc,1);self.assertEqual(len(commands),2);self.assertFalse(result['testsPassed'])
    def test_boolean_counts_are_not_executed_test_counts(self):
        rc,_,_,commands,_,_=self.invoke(summary={'totalTestCount':True,'passedTests':True,'failedTests':0,'skippedTests':0});self.assertEqual(rc,1);self.assertEqual(len(commands),2)
    def test_verifier_refusal_never_classifies_or_retries(self):
        rc,_,_,commands,result,_=self.invoke(verify_exit=1,classification={'result':'FAIL','authenticatedClassification':False,'privateDetailsWithheld':True});self.assertEqual(rc,1);self.assertEqual(len(commands),4);self.assertFalse(result['authenticatedClassification']);self.assertTrue(result['restoreRequired'])
    def test_exit_zero_without_full_authenticated_fields_does_not_classify(self):
        rc,_,_,_,result,_=self.invoke(classification={'result':'PASS'});self.assertEqual(rc,1);self.assertFalse(result['authenticatedClassification'])
    def test_wrong_authenticated_environment_fails_closed(self):
        data=signed_output(self.packet);data['environment']='production';rc,_,_,_,result,_=self.invoke(classification=data);self.assertEqual(rc,1);self.assertFalse(result['authenticatedClassification'])
    def test_tampered_runtime_refuses_before_any_output_or_child(self):
        f.write(Path(self.packet['runtimeDirectory'])/'libBatonShareKit.dylib',b'TAMPER')
        with patch.object(subprocess,'Popen') as child:
            with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        child.assert_not_called();self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_missing_execution_dependency_pin_refuses_before_mutation(self):
        self.packet['executionInputSHA256'].pop(str(self.base/'app_attest_owned_controller.py'));self.change_packet()
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_capture_build_class_mismatch_refuses_before_output(self):
        build=json.loads(self.build_evidence.read_bytes());build['testIdentifier']='unrelated-test'
        f.write(self.build_evidence,json.dumps(build).encode());evidence=json.loads(self.capture_evidence.read_bytes())
        evidence['buildReceiptSHA256']=f.sha(self.build_evidence);f.write(self.capture_evidence,json.dumps(evidence).encode())
        self.admitted['captureNamespaceEvidenceSHA256']=f.sha(self.capture_evidence);self.save_binding()
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_true_namespace_boolean_without_evidence_refuses(self):
        self.capture_evidence.unlink()
        with self.assertRaises(FileNotFoundError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_wrong_compiled_capture_namespace_association_refuses(self):
        evidence=json.loads(self.capture_evidence.read_bytes());evidence['namespace']='old-capture-suite'
        f.write(self.capture_evidence,json.dumps(evidence).encode());self.admitted['captureNamespaceEvidenceSHA256']=f.sha(self.capture_evidence);self.save_binding()
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_compiled_capture_namespace_unqualified_refuses_before_output(self):
        self.admitted['compiledCaptureNamespaceQualified']=False;self.save_binding()
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_unadmitted_source_packet_cannot_self_authorize(self):
        self.admitted['rootGO']=False;self.save_binding()
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertFalse((self.base/'test-TBX-0000').exists())
    def test_existing_attempt_refuses_without_overwrite(self):
        root=self.base/'test-TBX-0000';root.mkdir(mode=0o700);f.write(root/'retained',b'keep')
        with self.assertRaises(ValueError):self.m.run(self.binding,'TBX-0000')
        self.assertEqual((root/'retained').read_bytes(),b'keep')
    def test_copy_helper_has_no_independent_driver(self):
        m=load(SCRIPTS/'copy-app-attest-probe-evidence.py','pure_copy')
        with patch.object(subprocess,'Popen') as child:
            with self.assertRaises(ValueError):m.main()
        child.assert_not_called()
    def test_copy_rejects_non_private_proof_directory(self):
        m=load(SCRIPTS/'copy-app-attest-probe-evidence.py','pure_copy');root=self.fixture.base/'bad-copy';root.mkdir(mode=0o755);root.chmod(0o755)
        with self.assertRaises(ValueError):m.command('synthetic-device',self.packet['suite'],root/'issuance.json',root/'copy-raw.json')
    def test_copy_rejects_an_existing_destination(self):
        m=load(SCRIPTS/'copy-app-attest-probe-evidence.py','pure_copy');root=self.fixture.base/'retained-copy';root.mkdir(mode=0o700);f.write(root/'issuance.json',b'keep')
        with self.assertRaises(ValueError):m.command('synthetic-device',self.packet['suite'],root/'issuance.json',root/'copy-raw.json')
        self.assertEqual((root/'issuance.json').read_bytes(),b'keep')
    def test_positive_finished_receipts_qualify_release_without_child(self):
        self.invoke()
        with patch.object(subprocess,'Popen') as child:
            self.assertEqual(self.m.qualify_release(self.binding,'TBX-0000'),0)
        child.assert_not_called()
    def test_missing_finished_marker_blocks_release(self):
        *_,root=self.invoke();(root/'driver-finished').unlink()
        with self.assertRaises(FileNotFoundError):self.m.qualify_release(self.binding,'TBX-0000')
    def test_launch_uncertainty_blocks_release(self):
        *_,root=self.invoke();p=root/'safe-test-receipt.json';result=json.loads(p.read_bytes());result['ownedCleanupState']['launchUncertain']=True;f.write(p,json.dumps(result).encode())
        with self.assertRaises(ValueError):self.m.qualify_release(self.binding,'TBX-0000')
    def test_pending_inspection_blocks_release(self):
        *_,root=self.invoke();p=root/'safe-test-receipt.json';result=json.loads(p.read_bytes());result['phases'][-1]['inspectionProcessPending']=True;f.write(p,json.dumps(result).encode())
        with self.assertRaises(ValueError):self.m.qualify_release(self.binding,'TBX-0000')

if __name__=='__main__':unittest.main(verbosity=2)
