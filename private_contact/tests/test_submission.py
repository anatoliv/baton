"""Public consent and captured SMTP submission boundaries; no worker launch."""
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from private_contact import ContactService, Denied
from private_contact.custody import AESGCMCodec, SQLiteCustody, JournaledCustody
from private_contact.ses_smtp import SESSMTP
from private_contact.tests.test_delivery import (SyntheticAuthority, SyntheticCustody,
    SyntheticFeedback, SyntheticSecrets)
from private_contact.tests.test_ses_smtp import CapturedConnection, CapturedFactory


class SubmissionBoundaryTests(unittest.TestCase):
    def service(self, factory, custody=None):
        return ContactService(custody=custody or SyntheticCustody(),
            authority=SyntheticAuthority(), secrets=SyntheticSecrets(),
            feedback=SyntheticFeedback(), mail=SESSMTP(connect=factory, mode='synthetic'),
            clock=lambda: 1000, mode='synthetic')

    def route(self, service, verification):
        service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        wire = next(value for stage, value in verification.calls if stage == 'data')
        code = re.search(rb'Code: ([A-Za-z0-9_-]+)', wire).group(1).decode('ascii')
        self.assertEqual(service.verify('install-a', code), {'status': 'verified'})
        return service.queue(review='synthetic-reviewed', installation='synthetic-a',
            case='synthetic-case', operation='synthetic-operation', revision=1,
            share='synthetic-share', created=1001, notice={'instructions': 'PRIVATE FIXTURE'})

    def test_completed_withdrawal_during_login_prevents_envelope_and_data(self):
        verification, notice = CapturedConnection(), CapturedConnection()
        service = self.service(CapturedFactory(verification))
        job = self.route(service, verification)
        class Login:
            synthetic = True
            def __call__(inner):
                self.assertEqual(service.withdraw('install-a'), {'status': 'disconnected'})
                self.assertEqual(service.status('install-a'), {'status': 'disconnected'})
                return notice
        service.mail = SESSMTP(connect=Login(), mode='synthetic')
        self.assertEqual(service.dispatch(), {'dispatched': 0})
        self.assertEqual([stage for stage, _ in notice.calls], ['close'])
        self.assertEqual(service.private_job('synthetic-reviewed', job)['state'], 'cancelled')
        self.assertEqual(service.dispatch(), {'dispatched': 0})

    def test_completed_withdrawal_in_envelope_prevents_later_data(self):
        for stage in ('mail', 'rcpt'):
            with self.subTest(stage=stage):
                verification, notice = CapturedConnection(), CapturedConnection()
                service = self.service(CapturedFactory(verification, notice))
                job = self.route(service, verification)
                command = getattr(notice, stage)
                def withdraw(value):
                    result = command(value)
                    self.assertEqual(service.withdraw('install-a'), {'status': 'disconnected'})
                    return result
                setattr(notice, stage, withdraw)
                self.assertEqual(service.dispatch(), {'dispatched': 0})
                self.assertNotIn('data', [name for name, _ in notice.calls])
                self.assertEqual(service.private_job('synthetic-reviewed', job)['state'], 'cancelled')

    def test_verification_withdrawal_before_data_prevents_body_and_challenge_revival(self):
        verification = CapturedConnection()
        service = self.service(CapturedFactory())
        class Login:
            synthetic = True
            def __call__(inner):
                self.assertEqual(service.withdraw('install-a'), {'status': 'disconnected'})
                return verification
        service.mail = SESSMTP(connect=Login(), mode='synthetic')
        self.assertEqual(service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1'),
                         {'status': 'disconnected'})
        self.assertEqual([stage for stage, _ in verification.calls], ['close'])
        self.assertEqual(service.verify('install-a', 'synthetic-code-0'), {'status': 'invalid'})

    def test_withdrawal_after_data_start_retains_provider_evidence_without_access(self):
        verification, notice = CapturedConnection(), CapturedConnection()
        service = self.service(CapturedFactory(verification, notice))
        job = self.route(service, verification)
        data = notice.data
        codes = []
        def started(wire):
            codes.append(re.search(rb'Code: ([A-Za-z0-9_-]+)', wire).group(1).decode('ascii'))
            result = data(wire)  # The irreversible boundary already occurred.
            service.withdraw('install-a')
            return result
        notice.data = started
        self.assertEqual(service.dispatch(), {'dispatched': 1})
        self.assertEqual(service.feedback_event(dict(authenticated=True, scope='synthetic-approved',
            event='after-withdrawal', message='synthetic-ses-reference', outcome='delivered')),
            {'accepted': True})
        info = service.private_job('synthetic-reviewed', job)
        self.assertEqual((info['state'], info['delivered']), ('cancelled', True))
        self.assertIn('submissionAccepted', [state for state, _ in info['history']])
        with self.assertRaisesRegex(Denied, '^notFound$'):
            service.access('install-a', codes[0])
        self.assertEqual(service.dispatch(), {'dispatched': 0})

    def test_verification_after_data_start_stays_disconnected_and_records_review(self):
        verification = CapturedConnection()
        service = self.service(CapturedFactory(verification))
        data = verification.data
        def started(wire):
            result = data(wire)
            service.withdraw('install-a')
            return result
        verification.data = started
        self.assertEqual(service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1'),
                         {'status': 'disconnected'})
        self.assertEqual(service.status('install-a'), {'status': 'disconnected'})
        self.assertEqual(service.verify('install-a', 'synthetic-code-0'), {'status': 'invalid'})
        self.assertGreater(service.aggregates()['escalations'], 0)

    def test_reopened_journal_wrappers_preserve_after_data_cancellation_and_receipt(self):
        with tempfile.TemporaryDirectory(prefix='baton-submission-') as directory:
            root = Path(directory)
            codec = AESGCMCodec(b'PUBLIC FIXTURE ONLY'.ljust(32, b'.'))
            primary = SQLiteCustody(root / 'primary', codec=codec, synthetic=True)
            journal = SQLiteCustody(root / 'journal', codec=codec, synthetic=True)
            verification, notice = CapturedConnection(), CapturedConnection()
            service = self.service(CapturedFactory(verification, notice),
                                   JournaledCustody(primary=primary, journal=journal))
            job = self.route(service, verification)
            reopened = self.service(CapturedFactory(), JournaledCustody(
                primary=SQLiteCustody(root / 'primary', codec=codec, synthetic=True),
                journal=SQLiteCustody(root / 'journal', codec=codec, synthetic=True)))
            data = notice.data
            def started(wire):
                result = data(wire)
                reopened.withdraw('install-a')
                return result
            notice.data = started
            service.dispatch()
            self.assertEqual(reopened.private_job('synthetic-reviewed', job)['state'], 'cancelled')
            self.assertEqual(reopened.feedback_event(dict(authenticated=True, scope='synthetic-approved',
                event='durable-after-withdrawal', message='synthetic-ses-reference', outcome='delivered')),
                {'accepted': True})
            self.assertEqual(reopened.status('install-a'), {'status': 'disconnected'})
            self.assertEqual(reopened.dispatch(), {'dispatched': 0})


class SubmissionLockBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='baton-submission-lock-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        codec = AESGCMCodec(b'PUBLIC FIXTURE ONLY'.ljust(32, b'.'))
        self.journal = SQLiteCustody(root / 'journal', codec=codec, synthetic=True)
        self.service = ContactService(
            custody=JournaledCustody(
                primary=SQLiteCustody(root / 'primary', codec=codec, synthetic=True),
                journal=self.journal),
            authority=SyntheticAuthority(), secrets=SyntheticSecrets(),
            feedback=SyntheticFeedback(), mail=SESSMTP(connect=CapturedFactory(), mode='synthetic'),
            clock=lambda: 1000, mode='synthetic')
        self.assertEqual(self.service.status('install-a'), {'status': 'disconnected'})
        self.lock = self.journal.directory / 'submission.lock'

    def assert_withdrawal_refused(self):
        with self.assertRaisesRegex(Denied, '^unavailable$'):
            self.service.withdraw('install-a')

    def test_wrong_mode_lock_cannot_acknowledge_withdrawal(self):
        self.lock.chmod(0o644)
        self.assert_withdrawal_refused()

    def test_symlink_lock_cannot_acknowledge_withdrawal(self):
        original = self.lock.with_name('original.lock')
        self.lock.rename(original)
        self.lock.symlink_to(original)
        self.assert_withdrawal_refused()

    def test_hard_link_lock_cannot_acknowledge_withdrawal(self):
        os.link(self.lock, self.lock.with_name('alias.lock'))
        self.assert_withdrawal_refused()

    def test_replaced_lock_after_acquisition_cannot_acknowledge_withdrawal(self):
        from private_contact.custody import fcntl
        acquire = fcntl.flock
        replaced = False

        def replace_owned_fixture(descriptor, operation):
            nonlocal replaced
            result = acquire(descriptor, operation)
            if not replaced:
                replaced = True
                self.lock.rename(self.lock.with_name('retained-original.lock'))
                replacement = os.open(self.lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                os.close(replacement)
            return result

        with patch.object(fcntl, 'flock', replace_owned_fixture):
            self.assert_withdrawal_refused()
        self.assertTrue(replaced)


if __name__ == '__main__':
    unittest.main(verbosity=2)
