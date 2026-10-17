"""Local application boundaries; published key bytes and reserved addresses only."""
from pathlib import Path
import tempfile
import unittest

from private_contact import ContactService, Denied
from private_contact.bridge import BridgeAuthority, KeyedSecrets
from private_contact.custody import AESGCMCodec, SQLiteCustody
from private_contact.tests.test_delivery import CapturedMail, SyntheticFeedback

PUBLIC_KEY = bytes(range(32))
DIGEST = 'a' * 64
SHARE = 'a' * 22
OPERATION = '00000000-0000-0000-0000-000000000001'


class CapturedShareSource:
    def __init__(self):
        self.grants = {}
        self.serial = 0
        self.scope = dict(installation=DIGEST, case='case_123', operation=OPERATION,
                          revision=1000000, share=SHARE, created=900, action='disable-share')

    def authorization(self, purpose, include=(), digest=DIGEST):
        self.serial += 1
        token = str(self.serial).zfill(43)
        self.grants[token] = (purpose, dict(installation=digest, shares=list(include)))
        return token

    def installation(self, proof, purpose, now):
        if self.grants.get(proof, (None,))[0] != purpose:
            raise Denied('unauthorized')
        return dict(self.grants.pop(proof)[1], issued=1000, expires=1060)

    def action(self, operation, share, now):
        if operation != self.scope['operation'] or share != self.scope['share']:
            raise Denied('notFound')
        return dict(self.scope)


class BridgeBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='baton-contact-bridge-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.now = 1000
        self.source = CapturedShareSource()
        self.mail = CapturedMail()
        self.mail.production_ready = True
        self.feedback = SyntheticFeedback()
        self.feedback.production_ready = True
        self.custody = SQLiteCustody(self.root / 'state', codec=AESGCMCodec(PUBLIC_KEY))
        self.custody.production_ready = True
        self.authority = BridgeAuthority(key=PUBLIC_KEY,
            ledger=SQLiteCustody(self.root / 'ledger', codec=AESGCMCodec(PUBLIC_KEY)),
            source=self.source, recipient=lambda address: address.endswith('@recipient.invalid'))
        self.service = ContactService(custody=self.custody, authority=self.authority,
            secrets=KeyedSecrets(PUBLIC_KEY), mail=self.mail, feedback=self.feedback,
            clock=lambda: self.now, mode='local')

    def proof(self, purpose, include=(), digest=DIGEST):
        return self.source.authorization(purpose, include, digest)

    def test_sending_disabled_also_prevents_verification_mail(self):
        from private_contact.runtime import Admission
        service = ContactService(custody=self.custody, authority=self.authority,
            secrets=KeyedSecrets(PUBLIC_KEY), mail=self.mail, feedback=self.feedback,
            clock=lambda: self.now, mode='production', admission=Admission(True, True, False))
        with self.assertRaisesRegex(Denied, '^disabled$'):
            service.enroll(self.proof('enroll'), 'sharer@recipient.invalid', 'contact-v1')
        with self.assertRaisesRegex(Denied, '^disabled$'):
            service.dispatch()
        self.assertEqual(self.mail.messages, [])

    def test_sibling_shares_dispatch_and_access_with_independent_current_scope(self):
        second = 'b' * 22
        scopes = {SHARE: dict(self.source.scope), second: dict(self.source.scope, share=second, created=901)}
        def action(operation, share, now):
            if operation != OPERATION or share not in scopes:
                raise Denied('notFound')
            return dict(scopes[share])
        self.source.action = action
        self.service.enroll(self.proof('enroll', [SHARE, second]), 'sharer@recipient.invalid',
                            'contact-v1', [SHARE, second])
        self.service.verify(self.proof('verify'), self.mail.messages[-1]['code'])
        jobs, notices = [], []
        for share in (SHARE, second):
            scope = dict(scopes[share])
            scope['installation'] = self.authority.handle(DIGEST)
            scope.pop('action')
            scope['notice'] = dict(instructions='SYNTHETIC reviewed instructions for ' + share,
                                   location='/s/' + share, action='disable-share')
            notices.append(scope['notice'])
            jobs.append(self.service.queue(review=self.authority.review(scope, self.now), **scope))
        self.assertNotEqual(jobs[0], jobs[1])
        grants = []
        for _ in jobs:
            self.assertEqual(self.service.dispatch(), {'dispatched': 1})
            grants.append(self.mail.messages[-1]['code'])
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        for grant, notice in zip(grants, notices):
            self.assertEqual(self.service.access(self.proof('caseAccess'), grant), notice)
        scopes[SHARE]['revision'] += 1
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access(self.proof('caseAccess'), grants[0])
        self.assertEqual(self.service.access(self.proof('caseAccess'), grants[1]), notices[1])
        for job in jobs:
            self.assertEqual(self.service.private_job(self.authority.operator_readback(), job)['state'], 'noticeViewed')

    def test_authenticated_bridge_enroll_review_dispatch_access_and_withdraw(self):
        self.assertEqual(self.service.enroll(self.proof('enroll', [SHARE]), 'sharer@recipient.invalid',
                         'contact-v1', [SHARE]), {'status': 'pending'})
        self.assertEqual(self.service.verify(self.proof('verify'), self.mail.messages[-1]['code']), {'status': 'verified'})
        scope = dict(self.source.scope)
        scope['installation'] = self.authority.handle(DIGEST)
        scope.pop('action')
        scope['notice'] = dict(instructions='SYNTHETIC reviewed counter-notice instructions',
                               location='/s/' + SHARE, action='disable-share')
        review = self.authority.review(scope, self.now)
        job = self.service.queue(review=review, **scope)
        self.assertEqual(self.service.dispatch(), {'dispatched': 1})
        grant = self.mail.messages[-1]['code']
        self.assertNotIn('instructions', self.mail.messages[-1])
        self.assertEqual(self.service.access(self.proof('caseAccess'), grant), scope['notice'])
        self.assertEqual(self.service.withdraw(self.proof('withdraw')), {'status': 'disconnected'})
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access(self.proof('caseAccess'), grant)
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertIsInstance(job, str)

    def test_private_api_authorizes_operator_scope_and_cross_installation(self):
        import json
        from private_contact.bridge import signed
        from private_contact.runtime import PrivateAPI
        api = PrivateAPI(service=self.service, authority=self.authority, operator_key=bytes(reversed(range(32))),
                         clock=lambda: self.now, custody=self.custody)
        def call(path, body):
            return api.handle(path, json.dumps(body).encode())
        self.assertEqual(call('/enroll', dict(authorization=self.proof('enroll', [SHARE]),
            address='sharer@recipient.invalid', consent='contact-v1', include=[SHARE])), (200, {'status': 'pending'}))
        challenge = self.mail.messages[-1]['code']
        self.assertEqual(call('/verify', dict(authorization=self.proof('verify', digest='b' * 64), code=challenge)),
                         (200, {'status': 'invalid'}))
        self.assertEqual(call('/verify', dict(authorization=self.proof('verify'), code=challenge)),
                         (200, {'status': 'verified'}))
        scope = dict(self.source.scope)
        scope['installation'] = self.authority.handle(DIGEST)
        scope.pop('action')
        scope['notice'] = dict(instructions='SYNTHETIC reviewed instructions', location='/s/' + SHARE, action='disable-share')
        self.assertEqual(call('/operator/review-and-queue', {'authorization': 'public-fragment'})[0], 403)
        proof = signed(bytes(reversed(range(32))), dict(path='/operator/review-and-queue', body=scope,
                       issued=1000, expires=1060, nonce='operator-fixture-nonce-1'))
        status, result = call('/operator/review-and-queue', {'authorization': proof})
        self.assertEqual(status, 200)
        self.assertIn('job', result)
        self.assertNotEqual(call('/operator/review-and-queue', {'authorization': proof})[0], 200)
        self.assertEqual(self.service.dispatch(), {'dispatched': 1})
        grant = self.mail.messages[-1]['code']
        self.assertNotEqual(call('/access', dict(authorization=self.proof('caseAccess', digest='b' * 64), code=grant))[0], 200)
        self.assertEqual(call('/access', dict(authorization=self.proof('caseAccess'), code=grant)), (200, scope['notice']))
        # A subsequent server revision invalidates access and cannot be disguised by the caller.
        self.source.scope['revision'] = 2000000
        self.assertNotEqual(call('/access', dict(authorization=self.proof('caseAccess'), code=grant))[0], 200)
        foreign = dict(scope, installation=self.authority.handle('b' * 64))
        foreign_proof = signed(bytes(reversed(range(32))), dict(path='/operator/review-and-queue', body=foreign,
            issued=1000, expires=1060, nonce='operator-fixture-nonce-2'))
        self.assertNotEqual(call('/operator/review-and-queue', {'authorization': foreign_proof})[0], 200)
        self.assertEqual(len(self.mail.messages), 2)

    def test_replayed_or_wrong_purpose_grant_cannot_enroll_after_restart(self):
        proof = self.proof('enroll')
        self.service.enroll(proof, 'sharer@recipient.invalid', 'contact-v1')
        # Simulate an older public grant-store restore; private history still fences reuse.
        self.source.grants[proof] = ('enroll', dict(installation=DIGEST, shares=[]))
        authority = BridgeAuthority(key=PUBLIC_KEY,
            ledger=SQLiteCustody(self.root / 'ledger', codec=AESGCMCodec(PUBLIC_KEY)),
            source=self.source, recipient=lambda address: address.endswith('@recipient.invalid'))
        service = ContactService(custody=self.custody, authority=authority, secrets=KeyedSecrets(PUBLIC_KEY),
            mail=self.mail, feedback=self.feedback, clock=lambda: self.now, mode='local')
        with self.assertRaisesRegex(Denied, '^unauthorized$'):
            service.enroll(proof, 'sharer@recipient.invalid', 'contact-v1')
        with self.assertRaisesRegex(Denied, '^unauthorized$'):
            service.verify(self.proof('enroll'), self.mail.messages[-1]['code'])
        self.assertEqual(len(self.mail.messages), 1)
