"""Only reserved synthetic data; adapter observations are the acceptance boundary."""
import copy
import hashlib
import hmac
import itertools
import threading
import unittest
from private_contact import ContactService, Denied

class SyntheticCustody:
    synthetic = True
    def __init__(self):
        self.value = None
        self.lock = threading.RLock()
        self.fail = False
        self.ready = True
    def submission(self):
        return self.lock
    def reconciled(self):
        return self.ready
    def transact(self, operation):
        with self.lock:
            if self.fail:
                raise RuntimeError('SYNTHETIC PRIVATE PAYLOAD MUST NOT ESCAPE')
            state = copy.deepcopy(self.value)
            result, state = operation(state)
            self.value = copy.deepcopy(state)
            return result

class SyntheticAuthority:
    synthetic = True
    def installation(self, proof, purpose, now):
        return {'install-a': 'synthetic-a', 'install-b': 'synthetic-b'}.get(proof)
    def owned(self, proof, shares, now):
        return proof == 'install-a' and set(shares) <= {'synthetic-share-a'}
    def case(self, review, now, scope=None):
        return review == 'synthetic-reviewed'
    def current_case(self, scope, now):
        return getattr(self, 'case_live', True)
    def recipient(self, address):
        return address.endswith('@recipient.invalid')

class SyntheticSecrets:
    synthetic = True
    def __init__(self):
        self.counter = itertools.count()
    def random(self):
        return f'synthetic-code-{next(self.counter)}'
    def verifier(self, purpose, value):
        # Public fixture bytes, deliberately not a credential or production key.
        return hmac.new(b'SYNTHETIC TEST ONLY', (purpose + value).encode(), hashlib.sha256).hexdigest()

class CapturedMail:
    synthetic = True
    def __init__(self):
        self.messages = []
        self.outcomes = []
        self.on_send = None
    def send(self, message):
        self.messages.append(copy.deepcopy(message))
        if self.on_send:
            self.on_send()
        return self.outcomes.pop(0) if self.outcomes else ('accepted', f'synthetic-message-{len(self.messages)}')

class SyntheticFeedback:
    synthetic = True
    def admit(self, envelope):
        if envelope.get('scope') != 'synthetic-approved' or envelope.get('authenticated') is not True:
            return None
        return {key: envelope[key] for key in ('event', 'message', 'outcome')}

class DeliveryBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000
        self.custody = SyntheticCustody()
        self.authority = SyntheticAuthority()
        self.secrets = SyntheticSecrets()
        self.mail = CapturedMail()
        self.feedback = SyntheticFeedback()
        self.service = self.restart()
    def restart(self, mode='synthetic'):
        return ContactService(custody=self.custody, authority=self.authority,
                              secrets=self.secrets, mail=self.mail, feedback=self.feedback,
                              clock=lambda: self.now, mode=mode)
    def route(self, proof='install-a', address='sharer@recipient.invalid', include=()):
        self.service.enroll(proof, address, 'synthetic-consent-v1', include)
        self.assertEqual(self.service.verify(proof, self.mail.messages[-1]['code']), {'status': 'verified'})
    def queue(self, **changes):
        fields = dict(review='synthetic-reviewed', installation='synthetic-a',
                      case='synthetic-case', operation='synthetic-operation', revision=1,
                      share='synthetic-share-new', created=1001,
                      notice={'instructions': 'SYNTHETIC counter-notice instructions',
                              'location': '/s/synthetic-share-new', 'action': 'disabled'})
        fields.update(changes)
        return self.service.queue(**fields)
    def event(self, message, outcome, event='synthetic-event', **changes):
        data = dict(authenticated=True, scope='synthetic-approved', event=event,
                    message=message, outcome=outcome)
        data.update(changes)
        return self.service.feedback_event(data)
    def test_captured_mail_plus_authenticated_case_access_proves_distinct_observations(self):
        self.route()
        job = self.queue()
        self.service.dispatch()
        message = self.mail.messages[-1]
        self.assertEqual(message['kind'], 'notice')
        self.assertNotIn('SYNTHETIC counter-notice', str(message))
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'providerAccepted')
        self.event('synthetic-message-2', 'delivered')
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'mailServerDelivered')
        notice = self.service.access('install-a', message['code'])
        self.assertEqual(notice['instructions'], 'SYNTHETIC counter-notice instructions')
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'noticeViewed')

    def test_disabled_and_unqualified_modes_reject_before_any_adapter_call(self):
        for mode in ('disabled', 'production'):
            with self.assertRaisesRegex(Denied, '^disabled$'):
                self.restart(mode).enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.authority.synthetic = False
        with self.assertRaisesRegex(Denied, '^disabled$'):
            self.restart().enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.assertEqual(self.mail.messages, [])

    def test_public_possession_missing_or_foreign_installation_cannot_verify_or_access(self):
        self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        code = self.mail.messages[-1]['code']
        for proof in (None, 'public-share#fragment', 'synthetic-reviewed'):
            with self.assertRaisesRegex(Denied, '^unauthorized$'):
                self.service.verify(proof, code)
        self.assertEqual(self.service.verify('install-b', code), {'status': 'invalid'})
        self.assertEqual(self.service.status('install-a'), {'status': 'disconnected'})
        self.assertEqual(self.service.verify('install-a', code), {'status': 'verified'})
        self.assertEqual(self.service.verify('install-a', code), {'status': 'invalid'})
        self.queue()
        self.service.dispatch()
        grant = self.mail.messages[-1]['code']
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-b', grant)
        with self.assertRaisesRegex(Denied, '^unauthorized$'):
            self.service.access('public-share#fragment', grant)

    def test_challenge_expiry_guess_limit_resend_and_restart(self):
        self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        old = self.mail.messages[-1]['code']
        self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        replacement = self.mail.messages[-1]['code']
        self.service = self.restart()
        self.assertEqual(self.service.verify('install-a', old), {'status': 'invalid'})
        for _ in range(4):
            self.assertEqual(self.service.verify('install-a', 'wrong'), {'status': 'invalid'})
        self.assertEqual(self.service.verify('install-a', replacement), {'status': 'invalid'})
        self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        code = self.mail.messages[-1]['code']
        self.now += 900
        self.service = self.restart()
        self.assertEqual(self.service.verify('install-a', code), {'status': 'invalid'})
        self.assertEqual(self.service.aggregates()['pending'], 0)

    def test_explicit_consent_recipient_domain_and_owned_history_are_required(self):
        for address, consent, include in (
            ('sharer@recipient.invalid', 'no-consent', ()),
            ('sharer@example.com', 'synthetic-consent-v1', ()),
            ('sharer\r\nBcc:other@recipient.invalid', 'synthetic-consent-v1', ()),
            ('sharer@recipient.invalid', 'synthetic-consent-v1', ('foreign-share',)),
        ):
            with self.assertRaisesRegex(Denied, '^invalid$'):
                self.service.enroll('install-a', address, consent, include)
        self.assertEqual(self.mail.messages, [])
        self.route(include=('synthetic-share-a',))
        job = self.queue(share='synthetic-share-a', created=999)
        self.service.dispatch()
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'providerAccepted')

    def test_mailbox_equality_does_not_merge_installations_or_old_share_coverage(self):
        self.route()
        self.route('install-b')
        historical = self.queue(created=999, operation='synthetic-historical')
        self.service.dispatch()
        self.assertEqual(self.service.private_job('synthetic-reviewed', historical)['state'], 'escalated')
        job = self.queue()
        self.service.dispatch()
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-b', self.mail.messages[-1]['code'])
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'providerAccepted')

    def test_per_installation_and_mailbox_rates_survive_restart(self):
        for _ in range(3):
            self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.service = self.restart()
        for proof, address in (('install-a', 'other@recipient.invalid'), ('install-b', 'sharer@recipient.invalid')):
            with self.assertRaisesRegex(Denied, '^rateLimited$'):
                self.service.enroll(proof, address, 'synthetic-consent-v1')
        self.assertEqual(len(self.mail.messages), 3)
        self.now += 3600
        self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.assertEqual(len(self.mail.messages), 4)

    def test_unknown_verification_submission_does_not_automatically_resend(self):
        self.mail.outcomes = [('unknown', None)]
        self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.service = self.restart()
        with self.assertRaisesRegex(Denied, '^reviewRequired$'):
            self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.assertEqual(len(self.mail.messages), 1)
        self.assertEqual(self.service.verify('install-a', self.mail.messages[-1]['code']), {'status': 'verified'})

    def test_verified_replacement_cancels_stale_outbox_and_grants(self):
        self.route()
        queued = self.queue()
        self.service.dispatch()
        grant = self.mail.messages[-1]['code']
        self.service.enroll('install-a', 'replacement@recipient.invalid', 'synthetic-consent-v1')
        # The existing route remains current until replacement is proved.
        self.assertEqual(self.service.status('install-a'), {'status': 'verified'})
        self.assertEqual(self.service.verify('install-a', self.mail.messages[-1]['code']), {'status': 'verified'})
        self.service = self.restart()
        self.assertEqual(self.service.private_job('synthetic-reviewed', queued)['state'], 'cancelled')
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-a', grant)
        next_job = self.queue()
        self.assertNotEqual(queued, next_job)
        self.service.dispatch()
        self.assertEqual(self.mail.messages[-1]['recipient'], 'replacement@recipient.invalid')

    def test_withdrawal_cancels_queued_delivery_and_access_across_restart(self):
        self.route()
        first = self.queue()
        self.service.dispatch()
        grant = self.mail.messages[-1]['code']
        queued = self.queue(operation='synthetic-operation-two')
        self.service.withdraw('install-a')
        self.service = self.restart()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(len(self.mail.messages), 2)
        for job in (first, queued):
            info = self.service.private_job('synthetic-reviewed', job)
            self.assertEqual(info['state'], 'cancelled')
            self.assertIn('withdrawn', info['escalations'])
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-a', grant)
        self.assertEqual(self.service.status('install-a'), {'status': 'disconnected'})

    def test_unknown_provider_submission_escalates_without_blind_retry(self):
        self.route()
        job = self.queue()
        self.mail.outcomes = [('unknown', None)]
        self.service.dispatch()
        self.now += 1000
        self.service = self.restart()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        info = self.service.private_job('synthetic-reviewed', job)
        self.assertEqual(info['state'], 'outcomeUnknown')
        self.assertIn('outcomeUnknown', info['escalations'])
        self.assertEqual(len(self.mail.messages), 2)

    def test_confirmed_transient_submission_retries_are_persisted_and_bounded(self):
        self.route()
        job = self.queue()
        self.mail.outcomes = [('transient', None)] * 3
        self.service.dispatch()
        self.now += 59
        self.service = self.restart()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.now += 1
        self.service.dispatch()
        self.now += 599
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.now += 1
        self.service.dispatch()
        self.now += 1000
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        info = self.service.private_job('synthetic-reviewed', job)
        self.assertEqual(info['attempts'], 3)
        self.assertEqual(info['state'], 'permanentFailure')
        self.assertEqual(len(self.mail.messages), 4)

    def test_crash_during_submission_recovers_unknown_and_fences_late_worker(self):
        self.route()
        job = self.queue()
        def recovery():
            self.now += 121
            restarted = self.restart()
            self.assertEqual(restarted.dispatch(), {'dispatched': 0})
        self.mail.on_send = recovery
        self.service.dispatch()
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'outcomeUnknown')
        self.assertEqual(len(self.mail.messages), 2)

    def test_two_workers_do_not_dispatch_same_private_job(self):
        self.route()
        job = self.queue()
        results = []
        barrier = threading.Barrier(2)
        def run():
            barrier.wait()
            results.append(self.restart().dispatch()['dispatched'])
        threads = [threading.Thread(target=run) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(sorted(results), [0, 1])
        self.assertEqual(len(self.mail.messages), 2)
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['attempts'], 1)

    def test_private_queue_is_idempotent_and_conflicting_notice_is_refused(self):
        self.route()
        first = self.queue()
        self.assertEqual(self.queue(), first)
        with self.assertRaisesRegex(Denied, '^conflict$'):
            self.queue(notice={'instructions': 'changed'})
        with self.assertRaisesRegex(Denied, '^unauthorized$'):
            self.queue(review='public-share')
        self.service.dispatch()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(len(self.mail.messages), 2)

    def test_feedback_requires_authenticated_scope_expected_message_and_deduplicates(self):
        self.route()
        job = self.queue()
        self.service.dispatch()
        for changes in ({'authenticated': False}, {'scope': 'foreign'}):
            self.assertEqual(self.event('synthetic-message-2', 'delivered', **changes), {'accepted': False})
        self.assertEqual(self.event('orphan', 'delivered'), {'accepted': False})
        self.assertEqual(self.event('synthetic-message-2', 'delivered'), {'accepted': True})
        self.assertEqual(self.event('synthetic-message-2', 'delivered'), {'accepted': True})
        info = self.service.private_job('synthetic-reviewed', job)
        self.assertEqual(info['history'].count(('mailServerDelivered', self.now)), 1)
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})

    def test_late_failure_disables_only_matching_contact_revision_and_preserves_history(self):
        self.route()
        old = self.queue()
        self.service.dispatch()
        self.service.enroll('install-a', 'replacement@recipient.invalid', 'synthetic-consent-v1')
        self.service.verify('install-a', self.mail.messages[-1]['code'])
        self.event('synthetic-message-2', 'bounce')
        self.assertEqual(self.service.status('install-a'), {'status': 'verified'})
        self.assertIn('bounce', self.service.private_job('synthetic-reviewed', old)['escalations'])
        new = self.queue()
        self.service.dispatch()
        self.event('synthetic-message-4', 'complaint', event='synthetic-complaint')
        self.assertEqual(self.service.status('install-a'), {'status': 'disconnected'})
        self.assertEqual(self.service.private_job('synthetic-reviewed', new)['state'], 'cancelled')
        self.event('synthetic-message-4', 'delivered', event='synthetic-late-delivery')
        self.assertEqual(self.service.private_job('synthetic-reviewed', new)['state'], 'cancelled')
        self.assertIn('complaint', self.service.private_job('synthetic-reviewed', new)['escalations'])

    def test_delay_and_overdue_access_escalate_without_duplicate_submission(self):
        self.route()
        job = self.queue()
        self.service.dispatch()
        self.event('synthetic-message-2', 'delay')
        self.now += 1800
        self.service = self.restart()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertIn('receiptOverdue', self.service.private_job('synthetic-reviewed', job)['escalations'])
        self.event('synthetic-message-2', 'delivered', event='synthetic-later')
        self.now += 12600
        info = self.service.private_job('synthetic-reviewed', job)
        self.assertIn('providerDelay', info['escalations'])
        self.assertIn('receiptOverdue', info['escalations'])
        self.assertIn('accessOverdue', info['escalations'])
        self.assertEqual(len(self.mail.messages), 2)

    def test_grant_expiry_and_contact_review_expiry_prevent_send_or_access(self):
        self.route()
        job = self.queue()
        self.service.dispatch()
        code = self.mail.messages[-1]['code']
        self.now += 86400
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-a', code)
        self.now += 90 * 86400
        self.assertEqual(self.service.status('install-a'), {'status': 'disconnected'})
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(len(self.mail.messages), 2)

    def test_unenrolled_case_and_cross_store_missing_notice_escalation(self):
        job = self.queue()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'escalated')
        required = [('synthetic-case', 'synthetic-operation', 1), ('synthetic-other-case', 'synthetic-other-action', 1)]
        self.assertEqual(self.service.reconcile_actions('synthetic-reviewed', required), {'missing': 1})
        self.assertEqual(self.service.reconcile_actions('synthetic-reviewed', required), {'missing': 1})
        self.assertEqual(self.service.aggregates()['escalations'], 2)
        self.assertEqual(self.mail.messages, [])

    def test_custody_and_transport_errors_are_bounded_and_emit_no_payload(self):
        self.custody.fail = True
        with self.assertRaisesRegex(Denied, '^unavailable$') as error:
            self.service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        self.assertIsNone(error.exception.__cause__)
        self.assertEqual(self.mail.messages, [])
        self.custody.fail = False
        self.route()
        job = self.queue()
        def broken():
            raise RuntimeError('SYNTHETIC PRIVATE NOTICE MUST NOT ESCAPE')
        self.mail.on_send = broken
        self.service.dispatch()
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'outcomeUnknown')
        summary = self.service.aggregates()
        self.assertEqual(set(summary), {'contacts', 'pending', 'jobs', 'escalations'})
        self.assertTrue(all(type(value) is int for value in summary.values()))
        self.assertNotIn('synthetic-', str(summary))

    def test_unreconciled_restored_custody_fails_closed_before_sending(self):
        self.route()
        self.queue()
        self.custody.ready = False
        self.service = self.restart()
        with self.assertRaisesRegex(Denied, '^custodyReviewRequired$'):
            self.service.dispatch()
        self.assertEqual(len(self.mail.messages), 1)

    def test_current_case_revocation_prevents_send_and_private_access(self):
        self.route()
        first = self.queue()
        self.service.dispatch()
        grant = self.mail.messages[-1]['code']
        queued = self.queue(operation='synthetic-second')
        self.authority.case_live = False
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-a', grant)
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(self.service.private_job('synthetic-reviewed', queued)['state'], 'cancelled')
        self.assertEqual(len(self.mail.messages), 2)

    def test_failed_access_guesses_are_rate_bounded_across_service_restart(self):
        self.route()
        self.queue()
        self.service.dispatch()
        code = self.mail.messages[-1]['code']
        for _ in range(20):
            with self.assertRaisesRegex(Denied, '^notFound$'):
                self.service.access('install-a', 'wrong-grant')
        self.service = self.restart()
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-a', code)
        self.now += 3600
        self.assertEqual(self.service.access('install-a', code)['action'], 'disabled')

    def test_withdrawal_during_inflight_generic_mail_prevents_case_access_and_late_completion(self):
        self.route()
        job = self.queue()
        self.mail.on_send = lambda: self.restart().withdraw('install-a')
        self.service.dispatch()
        grant = self.mail.messages[-1]['code']
        self.assertEqual(len(self.mail.messages), 2)
        self.assertEqual(self.service.private_job('synthetic-reviewed', job)['state'], 'cancelled')
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('install-a', grant)
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})

    def test_transient_retry_at_four_hour_deadline_sends_nothing(self):
        self.route()
        job = self.queue()
        self.mail.outcomes = [('transient', None)]
        self.service.dispatch()
        observed = len(self.mail.messages)
        self.now += 14400
        self.service = self.restart()
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(len(self.mail.messages), observed)
        info = self.service.private_job('synthetic-reviewed', job)
        self.assertIn('accessOverdue', info['escalations'])

    def test_adapter_denial_is_sanitized_at_public_boundary(self):
        def fail(*args):
            raise Denied('SYNTHETIC PRIVATE ADAPTER PAYLOAD')
        self.authority.installation = fail
        with self.assertRaisesRegex(Denied, '^unavailable$'):
            self.service.status('install-a')
        self.assertEqual(self.mail.messages, [])

    def test_retry_deadline_crossed_between_lease_and_prepare_sends_nothing(self):
        self.route()
        self.queue()
        self.mail.outcomes = [('transient', None)]
        self.service.dispatch()
        observed = len(self.mail.messages)
        self.now += 14399
        self.service = self.restart()
        ticks = iter([self.now, self.now + 1, self.now + 1])
        self.service.clock = lambda: next(ticks)
        self.assertEqual(self.service.dispatch(), {'dispatched': 0})
        self.assertEqual(len(self.mail.messages), observed)

if __name__ == '__main__':
    unittest.main()
