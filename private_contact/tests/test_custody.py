"""Disk/process acceptance with reserved data and a PUBLIC fixture key only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from private_contact import ContactService, Denied
from private_contact.tests.test_delivery import (
    CapturedMail, DeliveryBoundaryTests, SyntheticAuthority, SyntheticFeedback,
    SyntheticSecrets,
)

# Published test bytes, not a credential or a newly created private key.
PUBLIC_FIXTURE_KEY = bytes(range(32))


def custody_at(directory, key=PUBLIC_FIXTURE_KEY):
    from private_contact.custody import AESGCMCodec, SQLiteCustody
    return SQLiteCustody(Path(directory), codec=AESGCMCodec(key), synthetic=True)


def service_at(directory, now=1000, *, secrets=None, mail=None, key=PUBLIC_FIXTURE_KEY):
    return ContactService(custody=custody_at(directory, key), authority=SyntheticAuthority(),
                          secrets=secrets or SyntheticSecrets(), mail=mail or CapturedMail(),
                          feedback=SyntheticFeedback(), clock=lambda: now, mode='synthetic')


class DurableCustodyTests(unittest.TestCase):
    route = DeliveryBoundaryTests.route
    queue = DeliveryBoundaryTests.queue

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='baton-contact-synthetic-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / 'custody'
        self.now = 1000
        self.mail = CapturedMail()
        self.secrets = SyntheticSecrets()
        self.service = service_at(self.directory, self.now, secrets=self.secrets, mail=self.mail)

    def restart(self):
        self.service = service_at(self.directory, self.now, secrets=self.secrets, mail=self.mail)

    def test_verified_route_and_accepted_send_survive_new_process(self):
        self.route()
        job = self.queue()
        self.service.dispatch()
        self.restart()
        self.assertEqual(self.service.status('install-a'), {'status': 'verified'})
        child = subprocess.run([
            sys.executable, '-c',
            'import json,sys; from private_contact.tests.test_custody import service_at; '
            's=service_at(sys.argv[1]); '
            'print(json.dumps([s.status("install-a"),s.private_job("synthetic-reviewed",sys.argv[2])["state"]]))',
            str(self.directory), job], capture_output=True, text=True, timeout=10)
        self.assertEqual(child.returncode, 0, 'synthetic child readback failed')
        self.assertEqual(json.loads(child.stdout), [{'status': 'verified'}, 'providerAccepted'])
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(len(self.mail.messages), 2)

    def test_restored_backup_denies_send_access_and_route_readback_until_review(self):
        from private_contact.custody import AESGCMCodec, SQLiteCustody
        self.route()
        self.queue()
        self.service.dispatch()
        grant = self.mail.messages[-1]['code']
        backup = self.service.custody.export()
        restored = Path(self.temporary.name) / 'restored'
        SQLiteCustody.restore(restored, backup=backup, codec=AESGCMCodec(PUBLIC_FIXTURE_KEY), synthetic=True)
        service = service_at(restored, mail=self.mail, secrets=self.secrets)
        for call in (service.dispatch, lambda: service.access('install-a', grant),
                     lambda: service.status('install-a')):
            with self.assertRaisesRegex(Denied, '^custodyReviewRequired$'):
                call()
        self.assertEqual(len(self.mail.messages), 2)
        # Reopening with ordinary constructor defaults cannot clear the block.
        with self.assertRaisesRegex(Denied, '^custodyReviewRequired$'):
            service_at(restored).dispatch()

    def test_tampered_export_and_wrong_key_fail_without_private_payload(self):
        from private_contact.custody import AESGCMCodec, CustodyError, SQLiteCustody
        self.route()
        backup = self.service.custody.export()
        tampered = backup[:-1] + bytes([backup[-1] ^ 1])
        for index, (payload, key) in enumerate(((tampered, PUBLIC_FIXTURE_KEY),
                                               (backup, bytes(reversed(range(32)))))):
            target = Path(self.temporary.name) / ('restore-' + str(index))
            with self.assertRaisesRegex(CustodyError, '^unavailable$'):
                SQLiteCustody.restore(target, backup=payload, codec=AESGCMCodec(key), synthetic=True)
            # Even a failed import keeps its new directory unreconciled.
            with self.assertRaisesRegex(Denied, '^custodyReviewRequired$'):
                service_at(target, key=key).dispatch()
        with self.assertRaisesRegex(CustodyError, '^unavailable$'):
            SQLiteCustody(self.directory, codec=AESGCMCodec(bytes(reversed(range(32)))), synthetic=True)
        self.assertEqual(self.service.status('install-a'), {'status': 'verified'})

    def test_private_modes_symlinks_existing_restore_and_other_directory_are_isolated(self):
        from private_contact.custody import AESGCMCodec, CustodyError, SQLiteCustody
        self.route()
        other = Path(self.temporary.name) / 'other'
        self.assertEqual(service_at(other).status('install-a'), {'status': 'disconnected'})
        with self.assertRaisesRegex(CustodyError, '^unavailable$'):
            SQLiteCustody.restore(self.directory, backup=self.service.custody.export(),
                                  codec=AESGCMCodec(PUBLIC_FIXTURE_KEY), synthetic=True)
        alias = Path(self.temporary.name) / 'alias'
        alias.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaisesRegex(CustodyError, '^unavailable$'):
            custody_at(alias)
        os.chmod(self.directory, 0o755)
        with self.assertRaisesRegex(Denied, '^unavailable$'):
            self.service.status('install-a')
        os.chmod(self.directory, 0o700)
        self.assertEqual(self.service.status('install-a'), {'status': 'verified'})

    def test_fault_before_commit_rolls_back_rate_and_sends_nothing(self):
        class FailingSecrets(SyntheticSecrets):
            def random(self):
                raise RuntimeError('SYNTHETIC PRIVATE PAYLOAD MUST NOT ESCAPE')
        failing = service_at(self.directory, secrets=FailingSecrets(), mail=self.mail)
        with self.assertRaisesRegex(Denied, '^unavailable$'):
            failing.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.assertEqual(self.mail.messages, [])
        self.restart()
        for _ in range(3):
            self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        with self.assertRaisesRegex(Denied, '^rateLimited$'):
            self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.assertEqual(len(self.mail.messages), 3)

    def test_process_exit_before_commit_recovers_original_rate_and_pending_state(self):
        child = subprocess.run([
            sys.executable, '-c',
            'import os,sys; from private_contact.custody import AESGCMCodec; '
            'from private_contact.tests.test_custody import service_at; '
            's=service_at(sys.argv[1]); '
            's.custody.codec.seal=lambda payload: os._exit(73); '
            's.enroll("install-a","sharer@recipient.invalid","synthetic-consent-v1")',
            str(self.directory)], capture_output=True, timeout=10)
        self.assertEqual(child.returncode, 73)
        self.restart()
        self.assertEqual(self.service.aggregates()['pending'], 0)
        for _ in range(3):
            self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.assertEqual(len(self.mail.messages), 3)

    def test_process_exit_during_send_recovers_unknown_without_resubmission(self):
        self.route()
        job = self.queue()
        child = subprocess.run([
            sys.executable, '-c',
            'import os,sys; from private_contact.tests.test_custody import service_at; '
            's=service_at(sys.argv[1]); s.mail.send=lambda message: os._exit(74); s.dispatch()',
            str(self.directory)], capture_output=True, timeout=10)
        self.assertEqual(child.returncode, 74)
        self.now += 121
        self.restart()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        observed = self.service.private_job('synthetic-reviewed', job)
        self.assertEqual(observed['state'], 'outcomeUnknown')
        self.assertEqual(observed['attempts'], 1)
        self.assertIn('outcomeUnknown', observed['escalations'])
        self.assertEqual(len(self.mail.messages), 1)

    def test_independent_process_workers_submit_one_persisted_lease(self):
        self.route()
        job = self.queue()
        command = [sys.executable, '-c',
                   'import json,sys; from private_contact.tests.test_custody import service_at; '
                   'print(json.dumps(service_at(sys.argv[1]).dispatch()))', str(self.directory)]
        children = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    for _ in range(2)]
        results = []
        try:
            for child in children:
                stdout, _ = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, 'synthetic dispatch child failed')
                results.append(json.loads(stdout)['dispatched'])
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.communicate()
        self.assertEqual(sorted(results), [0, 1])
        self.restart()
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['attempts'], 1)

    def test_restore_race_refuses_and_preserves_competing_enrollment(self):
        from private_contact.custody import AESGCMCodec, CustodyError, SQLiteCustody
        self.route()
        backup = self.service.custody.export()
        target = Path(self.temporary.name) / 'competing-target'
        competing_mail = CapturedMail()
        mkdir = Path.mkdir
        interleaved = False

        def competing_create(path, *args, **kwargs):
            nonlocal interleaved
            if path == target and not interleaved:
                interleaved = True
                competing = service_at(target, mail=competing_mail)
                competing.enroll('install-b', 'other@recipient.invalid', 'synthetic-consent-v1')
            return mkdir(path, *args, **kwargs)

        with patch.object(Path, 'mkdir', competing_create):
            with self.assertRaisesRegex(CustodyError, '^unavailable$'):
                SQLiteCustody.restore(target, backup=backup,
                                      codec=AESGCMCodec(PUBLIC_FIXTURE_KEY), synthetic=True)
        self.assertTrue(interleaved)
        retained = service_at(target)
        self.assertEqual(retained.verify('install-b', competing_mail.messages[-1]['code']),
                         {'status': 'verified'})
        self.assertEqual(retained.status('install-a'), {'status': 'disconnected'})

    def test_restore_initialization_never_exposes_a_ready_empty_store(self):
        from private_contact.custody import AESGCMCodec, CustodyError, SQLiteCustody
        self.route()
        backup = self.service.custody.export()
        target = Path(self.temporary.name) / 'initializing-target'
        open_file = os.open
        observations = []
        interleaved = False

        def concurrent_open(path, flags, *args, **kwargs):
            nonlocal interleaved
            descriptor = open_file(path, flags, *args, **kwargs)
            if Path(path) == target / 'custody.sqlite' and flags & os.O_CREAT and not interleaved:
                interleaved = True
                try:
                    observations.append(service_at(target).status('install-a'))
                except CustodyError:
                    observations.append('blocked')
            return descriptor

        with patch.object(os, 'open', concurrent_open):
            SQLiteCustody.restore(target, backup=backup,
                                  codec=AESGCMCodec(PUBLIC_FIXTURE_KEY), synthetic=True)
        self.assertEqual(observations, ['blocked'])
        with self.assertRaisesRegex(Denied, '^custodyReviewRequired$'):
            service_at(target).dispatch()


if __name__ == '__main__':
    unittest.main()
