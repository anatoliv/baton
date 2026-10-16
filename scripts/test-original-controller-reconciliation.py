#!/usr/bin/env python3
"""Mock-only reservation/witness/receipt refusals; no syscall or process action."""
import unittest
from types import SimpleNamespace
from unittest.mock import Mock
import original_controller_reconciliation as protocol

class OriginalExit(BaseException): pass

class ReconciliationTests(unittest.TestCase):
    def actions(self):
        events=[]
        def event(name,value=None):
            events.append(name);return value
        a=SimpleNamespace(sources=Mock(side_effect=lambda:event('sources')),exited_reserved_child=Mock(side_effect=lambda:event('reserved')),witness=Mock(side_effect=lambda phase:event(phase,{'phase':phase})),reap_original=Mock(side_effect=lambda:event('reap',1)),partial_reap_notice=Mock(side_effect=lambda:event('partial')),pending_empty=Mock(side_effect=lambda:event('pending')),failed_receipts=Mock(side_effect=lambda *_:event('failed-receipts')),qualify_original_release=Mock(side_effect=lambda:event('strict-qualifier')),exit_original_failed=Mock(side_effect=OriginalExit))
        return a,events
    def test_positive_failed_child_uses_reservation_then_two_witnesses_before_exit(self):
        a,events=self.actions()
        with self.assertRaises(OriginalExit):protocol.reconcile(a)
        self.assertEqual(events,['sources','reserved','before','reserved','reap','partial','after','pending','sources','failed-receipts','strict-qualifier'])
        a.exit_original_failed.assert_called_once()
    def test_missing_reservation_cannot_reap_or_write_release(self):
        a,_=self.actions();a.exited_reserved_child.side_effect=ChildProcessError
        with self.assertRaises(ChildProcessError):protocol.reconcile(a)
        a.reap_original.assert_not_called();a.failed_receipts.assert_not_called();a.exit_original_failed.assert_not_called()
    def test_pre_reap_witness_refusal_cannot_reap(self):
        a,_=self.actions();a.witness.side_effect=PermissionError
        with self.assertRaises(PermissionError):protocol.reconcile(a)
        a.reap_original.assert_not_called();a.exit_original_failed.assert_not_called()
    def test_post_reap_failure_keeps_partial_reap_without_release(self):
        a,_=self.actions();a.witness.side_effect=[{},PermissionError()]
        with self.assertRaises(PermissionError):protocol.reconcile(a)
        a.reap_original.assert_called_once();a.partial_reap_notice.assert_called_once();a.failed_receipts.assert_not_called();a.exit_original_failed.assert_not_called()
    def test_receipt_or_strict_qualifier_failure_cannot_exit_parent(self):
        for field in ['failed_receipts','qualify_original_release']:
            with self.subTest(field=field):
                a,_=self.actions();getattr(a,field).side_effect=OSError
                with self.assertRaises(OSError):protocol.reconcile(a)
                a.exit_original_failed.assert_not_called()
    def test_source_drift_after_reap_cannot_write_release(self):
        a,_=self.actions();a.sources.side_effect=[None,ValueError()]
        with self.assertRaises(ValueError):protocol.reconcile(a)
        a.reap_original.assert_called_once();a.failed_receipts.assert_not_called();a.exit_original_failed.assert_not_called()
    def test_witness_requires_fresh_nonce_root_provenance_and_only_original_zombie(self):
        req={'nonce':'fixed-synthetic-nonce','phase':'before','sha256':'synthetic-digest','requestedAtNs':100}
        good={'nonce':req['nonce'],'phase':'before','requestSHA256':req['sha256'],'requestedAtNs':100,'observedAtNs':200,'clientUID':0,'controllerIdentityVerified':True,'groupRows':[{'pid':70700,'ppid':70695,'pgid':70700,'stat':'Z'}]}
        self.assertEqual(protocol.validate_witness(good,req,300),good)
        for key,bad in [('nonce','other'),('clientUID',501),('observedAtNs',-1),('groupRows',[]),('groupRows',[{'pid':70700,'ppid':1,'pgid':70700,'stat':'Z'}]),('groupRows',[{'pid':70700,'ppid':70695,'pgid':70700,'stat':'S'}])]:
            with self.subTest(key=key,bad=bad):
                with self.assertRaises(ValueError):protocol.validate_witness({**good,key:bad},req,300)
        with self.assertRaises(ValueError):protocol.validate_witness(good,req,3_000_000_201)
    def test_post_reap_reused_group_is_refused_without_signal_operation(self):
        req={'nonce':'n','phase':'after','sha256':'d','requestedAtNs':100}
        value={'nonce':'n','phase':'after','requestSHA256':'d','requestedAtNs':100,'observedAtNs':200,'clientUID':0,'controllerIdentityVerified':True,'groupRows':[{'pid':1,'ppid':1,'pgid':70700,'stat':'S'}]}
        with self.assertRaises(ValueError):protocol.validate_witness(value,req,300)
        value['groupRows']=[];protocol.validate_witness(value,req,300)

if __name__=='__main__':unittest.main()
