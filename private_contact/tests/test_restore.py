"""Authoritative history across exported snapshots and fresh processes."""
from pathlib import Path
import tempfile
import json
import subprocess
import sys
import unittest
from private_contact import ContactService, Denied
from private_contact.custody import AESGCMCodec, SQLiteCustody
from private_contact.tests.test_delivery import CapturedMail, SyntheticAuthority, SyntheticSecrets, SyntheticFeedback

PUBLIC_KEY = bytes(range(32))
JOURNAL_KEY = bytes(reversed(range(32)))


class RestoreBoundaryTests(unittest.TestCase):
    def test_authoritative_withdrawal_reconciles_old_export_without_resurrection(self):
        from private_contact.custody import JournaledCustody
        with tempfile.TemporaryDirectory(prefix='baton-contact-restore-') as temporary:
            root = Path(temporary)
            primary = SQLiteCustody(root / 'primary', codec=AESGCMCodec(PUBLIC_KEY), synthetic=True)
            journal = SQLiteCustody(root / 'journal', codec=AESGCMCodec(JOURNAL_KEY), synthetic=True)
            custody = JournaledCustody(primary=primary, journal=journal)
            mail = CapturedMail()
            def service(store):
                return ContactService(custody=store, authority=SyntheticAuthority(), secrets=SyntheticSecrets(),
                                      mail=mail, feedback=SyntheticFeedback(), clock=lambda: 1000, mode='synthetic')
            active = service(custody)
            active.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
            active.verify('install-a', mail.messages[-1]['code'])
            job = active.queue(review='synthetic-reviewed', installation='synthetic-a', case='synthetic-case',
                operation='synthetic-operation', revision=1, share='synthetic-share-new', created=1001,
                notice={'instructions': 'SYNTHETIC instructions'})
            backup = primary.export()
            active.dispatch()
            grant = mail.messages[-1]['code']
            active.withdraw('install-a')
            restored_primary = SQLiteCustody.restore(root / 'restored', backup=backup,
                codec=AESGCMCodec(PUBLIC_KEY), synthetic=True)
            restored = JournaledCustody(primary=restored_primary, journal=journal)
            with self.assertRaisesRegex(Denied, '^custodyReviewRequired$'):
                service(restored).dispatch()
            restored.reconcile_restore()
            self.assertEqual(service(restored).status('install-a'), {'status': 'disconnected'})
            self.assertEqual(service(restored).dispatch(), {'dispatched': 0})
            with self.assertRaisesRegex(Denied, '^notFound$'):
                service(restored).access('install-a', grant)
            self.assertEqual(len(mail.messages), 2)
            child = subprocess.run([sys.executable, '-c',
                'import json,sys; from private_contact.custody import AESGCMCodec,SQLiteCustody,JournaledCustody; '
                'from private_contact import ContactService,Denied; '
                'from private_contact.tests.test_delivery import SyntheticAuthority,SyntheticSecrets,CapturedMail,SyntheticFeedback; '
                'c=JournaledCustody(primary=SQLiteCustody(sys.argv[1],codec=AESGCMCodec(bytes(range(32))),synthetic=True), '
                'journal=SQLiteCustody(sys.argv[2],codec=AESGCMCodec(bytes(reversed(range(32)))),synthetic=True)); '
                's=ContactService(custody=c,authority=SyntheticAuthority(),secrets=SyntheticSecrets(),mail=CapturedMail(),'
                'feedback=SyntheticFeedback(),clock=lambda:1000,mode="synthetic"); '
                'print(json.dumps([s.status("install-a"),s.dispatch(),s.private_job("synthetic-reviewed",sys.argv[3])["state"]]))',
                str(root / 'restored'), str(root / 'journal'), job], capture_output=True, text=True, timeout=5)
            self.assertEqual(child.returncode, 0, 'synthetic child failed')
            self.assertEqual(json.loads(child.stdout), [{'status': 'disconnected'}, {'dispatched': 0}, 'cancelled'])
            # A second independent process is covered in the next vertical seam.

    def test_journal_committed_withdrawal_survives_primary_commit_failure(self):
        from private_contact.custody import JournaledCustody
        with tempfile.TemporaryDirectory(prefix='baton-contact-journal-fault-') as temporary:
            root = Path(temporary)
            primary = SQLiteCustody(root / 'primary', codec=AESGCMCodec(PUBLIC_KEY), synthetic=True)
            journal = SQLiteCustody(root / 'journal', codec=AESGCMCodec(JOURNAL_KEY), synthetic=True)
            custody = JournaledCustody(primary=primary, journal=journal)
            mail = CapturedMail()
            active = ContactService(custody=custody, authority=SyntheticAuthority(), secrets=SyntheticSecrets(),
                mail=mail, feedback=SyntheticFeedback(), clock=lambda: 1000, mode='synthetic')
            active.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
            active.verify('install-a', mail.messages[-1]['code'])
            class CommitFault:
                def open(self, envelope):
                    return AESGCMCodec(PUBLIC_KEY).open(envelope)
                def seal(self, plaintext):
                    raise OSError('PUBLIC synthetic commit fault')
            primary.codec = CommitFault()
            with self.assertRaisesRegex(Denied, '^unavailable$'):
                active.withdraw('install-a')
            reopened = JournaledCustody(
                primary=SQLiteCustody(root / 'primary', codec=AESGCMCodec(PUBLIC_KEY), synthetic=True),
                journal=SQLiteCustody(root / 'journal', codec=AESGCMCodec(JOURNAL_KEY), synthetic=True))
            service = ContactService(custody=reopened, authority=SyntheticAuthority(), secrets=SyntheticSecrets(),
                mail=mail, feedback=SyntheticFeedback(), clock=lambda: 1000, mode='synthetic')
            self.assertEqual(service.status('install-a'), {'status': 'disconnected'})
            self.assertEqual(service.dispatch(), {'dispatched': 0})
            self.assertEqual(len(mail.messages), 1)

    def test_restore_without_live_authoritative_history_cannot_be_reconciled(self):
        from private_contact.custody import CustodyError, JournaledCustody
        with tempfile.TemporaryDirectory(prefix='baton-contact-no-history-') as temporary:
            root = Path(temporary)
            primary = SQLiteCustody(root / 'primary', codec=AESGCMCodec(PUBLIC_KEY), synthetic=True)
            backup = primary.export()
            restored = SQLiteCustody.restore(root / 'restored', backup=backup, codec=AESGCMCodec(PUBLIC_KEY), synthetic=True)
            journal = SQLiteCustody(root / 'empty-journal', codec=AESGCMCodec(JOURNAL_KEY), synthetic=True)
            wrapper = JournaledCustody(primary=restored, journal=journal)
            with self.assertRaisesRegex(CustodyError, '^unavailable$'):
                wrapper.reconcile_restore()
            service = ContactService(custody=wrapper, authority=SyntheticAuthority(), secrets=SyntheticSecrets(),
                mail=CapturedMail(), feedback=SyntheticFeedback(), clock=lambda: 1000, mode='synthetic')
            with self.assertRaisesRegex(Denied, '^custodyReviewRequired$'):
                service.dispatch()
