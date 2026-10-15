"""Private domain preparation, disconnected from public sharing and production.

Adapters are trusted boundaries, not implemented security mechanisms. `synthetic`
mode exists only for reserved-data acceptance; no production enable mode exists.
Custody.transact must atomically commit a deep-isolated private state and result,
serializing writers across processes and surviving restarts. No file store is
provided because encryption, key custody and backup reconciliation are unqualified.
"""
from __future__ import annotations

import copy
import hmac
import re


class Denied(Exception):
    """Only bounded categories cross the caller boundary; never adapter payloads."""


class _Refusal(Exception):
    """Internal bounded refusal, distinct from exceptions raised by adapters."""


class ContactService:
    def __init__(self, *, custody, authority, secrets, mail, feedback, clock, mode='disabled'):
        self.custody, self.authority, self.secrets = custody, authority, secrets
        self.mail, self.feedback, self.clock = mail, feedback, clock
        self.enabled = mode == 'synthetic' and all(
            getattr(adapter, 'synthetic', False) is True
            for adapter in (custody, authority, secrets, mail, feedback))

    def _call(self, operation):
        if not self.enabled:
            raise Denied('disabled')
        try:
            def transaction(state):
                if self.custody.reconciled() is not True:
                    raise _Refusal('custodyReviewRequired')
                if state is None:
                    state = dict(contacts={}, challenges={}, rates={}, jobs={}, events={}, escalations=[], time=0)
                now = max(state['time'], int(self.clock()))
                state['time'] = now
                self._reconcile(state, now)
                return operation(state, now), state
            return self.custody.transact(transaction)
        except _Refusal as refusal:
            raise Denied(str(refusal)) from None
        except Exception:
            raise Denied('unavailable') from None

    def _installation(self, proof, purpose, now):
        installation = self.authority.installation(proof, purpose, now)
        if not installation:
            raise _Refusal('unauthorized')
        return installation

    def _review(self, proof, now, scope=None):
        if not self.authority.case(proof, now, scope):
            raise _Refusal('unauthorized')

    def _verify(self, purpose, value):
        return self.secrets.verifier(purpose, value)

    @staticmethod
    def _transition(job, state, now):
        job['state'] = state
        job['history'].append((state, now))

    @staticmethod
    def _escalate(state, job, reason, now):
        # This list is PRIVATE custody, including even its opaque identifiers.
        if reason not in job['escalations']:
            job['escalations'].append(reason)
            state['escalations'].append(dict(job=job['id'], reason=reason, at=now))

    def _invalidate(self, state, installation, revision, reason, now):
        for job in state['jobs'].values():
            if job['installation'] == installation and job['contact_revision'] == revision:
                if job['state'] != 'cancelled':
                    self._transition(job, 'cancelled', now)
                    self._escalate(state, job, reason, now)
                job['grant'] = None
                job['code'] = None

    def _reconcile(self, state, now):
        for installation, pending in list(state['challenges'].items()):
            if pending['expires'] <= now:
                del state['challenges'][installation]
        for key, stamps in list(state['rates'].items()):
            remaining = [stamp for stamp in stamps if stamp > now - 3600]
            if remaining:
                state['rates'][key] = remaining
            else:
                del state['rates'][key]
        for installation, contact in state['contacts'].items():
            if contact['active'] and contact['expires'] <= now:
                contact['active'], contact['delete_at'] = False, now + 86400
                self._invalidate(state, installation, contact['revision'], 'contactExpired', now)
            if not contact['active'] and contact['delete_at'] <= now:
                contact['address'] = None
                contact['coverage'] = []
        for job in state['jobs'].values():
            if job['state'] == 'dispatching' and job['lease_until'] <= now:
                self._transition(job, 'outcomeUnknown', now)
                self._escalate(state, job, 'outcomeUnknown', now)
            if job['grant_until'] <= now:
                job['grant'], job['code'] = None, None
            if job['state'] not in ('cancelled', 'noticeViewed'):
                if now - job['created'] >= 1800 and not job['delivered']:
                    self._escalate(state, job, 'receiptOverdue', now)
                if now - job['created'] >= 14400:
                    self._escalate(state, job, 'accessOverdue', now)

    def enroll(self, proof, address, consent, include=()):
        """Explicit opt-in; responses contain neither address, code nor pseudonym."""
        def prepare(state, now):
            installation = self._installation(proof, 'enroll', now)
            if (not isinstance(address, str) or len(address) > 254
                    or not re.fullmatch(r'[A-Za-z0-9.!#$%&\'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+', address)
                    or consent != 'synthetic-consent-v1' or len(include) > 200
                    or not self.authority.recipient(address)):
                raise _Refusal('invalid')
            if include and not self.authority.owned(proof, include, now):
                raise _Refusal('invalid')
            pending = state['challenges'].get(installation)
            if pending and pending['delivery'] in ('dispatching', 'unknown'):
                raise _Refusal('reviewRequired')
            pseudonym = self._verify('mailbox:', address.lower())
            keys = ('installation:' + installation, 'mailbox:' + pseudonym, 'global')
            if any(len(state['rates'].get(key, [])) >= (100 if key == 'global' else 3) for key in keys):
                raise _Refusal('rateLimited')
            for key in keys:
                state['rates'].setdefault(key, []).append(now)
            code = self.secrets.random()
            challenge = self.secrets.random()
            state['challenges'][installation] = dict(
                id=challenge, address=address, verifier=self._verify(installation + ':challenge:', code),
                expires=now + 900, guesses=0, consent=consent, coverage=list(include),
                delivery='dispatching')
            return installation, challenge, dict(kind='verification', recipient=address, code=code)
        installation, challenge, message = self._call(prepare)
        outcome, _ = self._send(message)
        def complete(state, now):
            pending = state['challenges'].get(installation)
            if pending and pending['id'] == challenge:
                pending['delivery'] = outcome
                if outcome in ('unknown', 'permanent'):
                    state['escalations'].append(dict(job=None, reason='enrollmentDeliveryReview', at=now))
            return {'status': 'pending'}
        return self._call(complete)

    def _send(self, message):
        try:
            outcome, identifier = self.mail.send(message)
            if outcome not in ('accepted', 'transient', 'permanent', 'unknown'):
                return 'unknown', None
            if outcome == 'accepted' and (not isinstance(identifier, str) or not 1 <= len(identifier) <= 256):
                return 'unknown', None
            return outcome, identifier
        except Exception:
            return 'unknown', None

    def verify(self, proof, code):
        def operation(state, now):
            installation = self._installation(proof, 'verify', now)
            pending = state['challenges'].get(installation)
            if not pending or not isinstance(code, str) or len(code) > 256:
                return {'status': 'invalid'}
            pending['guesses'] += 1
            if not hmac.compare_digest(pending['verifier'], self._verify(installation + ':challenge:', code)):
                if pending['guesses'] >= 5:
                    del state['challenges'][installation]
                return {'status': 'invalid'}
            old = state['contacts'].get(installation)
            revision = old['revision'] + 1 if old else 1
            if old:
                self._invalidate(state, installation, old['revision'], 'contactChanged', now)
            state['contacts'][installation] = dict(
                address=pending['address'], active=True, revision=revision, since=now,
                expires=now + 90 * 86400, coverage=pending['coverage'], consent=pending['consent'],
                delete_at=now + 90 * 86400 + 86400)
            del state['challenges'][installation]
            return {'status': 'verified'}
        return self._call(operation)

    def status(self, proof):
        def operation(state, now):
            installation = self._installation(proof, 'status', now)
            contact = state['contacts'].get(installation)
            return {'status': 'verified' if contact and contact['active'] else 'disconnected'}
        return self._call(operation)

    def withdraw(self, proof):
        def operation(state, now):
            installation = self._installation(proof, 'withdraw', now)
            state['challenges'].pop(installation, None)
            contact = state['contacts'].get(installation)
            if contact:
                contact['active'], contact['delete_at'] = False, now + 86400
                self._invalidate(state, installation, contact['revision'], 'withdrawn', now)
            return {'status': 'disconnected'}
        return self._call(operation)

    def queue(self, *, review, installation, case, operation, revision, share, created, notice):
        """Trusted private reviewed-action bridge, not an enforcement/public API."""
        def enqueue(state, now):
            scope = dict(installation=installation, case=case, operation=operation, revision=revision,
                         share=share, created=created, notice=notice)
            self._review(review, now, scope)
            if (not all(isinstance(value, str) and 1 <= len(value) <= 128
                        for value in (installation, case, operation, share))
                    or type(revision) is not int or revision < 1 or type(created) is not int
                    or not isinstance(notice, dict) or len(repr(notice)) > 16384):
                raise _Refusal('invalid')
            contact = state['contacts'].get(installation)
            contact_revision = contact['revision'] if contact else 0
            identity = (case, operation, revision, contact_revision)
            for job in state['jobs'].values():
                if tuple(job['identity']) == identity:
                    if job['notice'] != notice or job['installation'] != installation or job['share'] != share or job['share_created'] != created:
                        raise _Refusal('conflict')
                    return job['id']
            identifier, code = self.secrets.random(), self.secrets.random()
            job = dict(id=identifier, identity=identity, installation=installation,
                       contact_revision=contact_revision, share=share, share_created=created, notice=copy.deepcopy(notice),
                       state='queued', created=now, grant_until=now + 86400,
                       grant=self._verify(installation + ':grant:', code), code=code,
                       next_at=now, attempts=0, messages=[], delivered=False,
                       history=[('queued', now)], escalations=[], lease=None, lease_until=0)
            state['jobs'][identifier] = job
            if not contact or not contact['active'] or (share not in contact['coverage'] and created <= contact['since']):
                self._transition(job, 'escalated', now)
                self._escalate(state, job, 'unreachable', now)
                job['grant'], job['code'] = None, None
            return identifier
        return self._call(enqueue)

    def _eligible(self, state, job, now):
        contact = state['contacts'].get(job['installation'])
        return (contact and contact['active'] and contact['revision'] == job['contact_revision']
                and contact['expires'] > now and job['grant_until'] > now
                and self.authority.current_case(dict(installation=job['installation'],
                    case=job['identity'][0], operation=job['identity'][1], revision=job['identity'][2]), now))

    def _submission_window(self, state, job, now):
        if now - job['created'] < 14400:
            return True
        self._transition(job, 'escalated', now)
        self._escalate(state, job, 'retryWindowExpired', now)
        return False

    def dispatch(self):
        def lease(state, now):
            for job in state['jobs'].values():
                if job['state'] not in ('queued', 'transientFailure'):
                    continue
                if not self._submission_window(state, job, now) or job['next_at'] > now:
                    continue
                if not self._eligible(state, job, now):
                    self._transition(job, 'cancelled', now)
                    self._escalate(state, job, 'unreachable', now)
                    continue
                job['attempts'] += 1
                job['lease'], job['lease_until'] = self.secrets.random(), now + 120
                self._transition(job, 'dispatching', now)
                return job['id'], job['lease']
            return None
        leased = self._call(lease)
        if not leased:
            return {'dispatched': 0}
        identifier, token = leased
        def prepare(state, now):
            job = state['jobs'][identifier]
            if job['state'] != 'dispatching' or job['lease'] != token:
                return None
            if not self._submission_window(state, job, now) or not self._eligible(state, job, now):
                return None
            contact = state['contacts'][job['installation']]
            return dict(kind='notice', recipient=contact['address'], code=job['code'])
        message = self._call(prepare)
        if message is None:
            return {'dispatched': 0}
        outcome, provider = self._send(message)
        def finish(state, now):
            job = state['jobs'][identifier]
            # Unknown lease recovery never resubmits. A late worker cannot overwrite it.
            if job['lease'] != token or job['state'] != 'dispatching' or job['lease_until'] <= now:
                return {'dispatched': 1}
            if outcome == 'accepted':
                job['messages'].append(provider)
                self._transition(job, 'providerAccepted', now)
            elif outcome == 'transient' and job['attempts'] < 3 and now - job['created'] < 14400:
                job['next_at'] = now + (60 if job['attempts'] == 1 else 600)
                self._transition(job, 'transientFailure', now)
            else:
                final = 'permanentFailure' if outcome in ('transient', 'permanent') else 'outcomeUnknown'
                self._transition(job, final, now)
                self._escalate(state, job, final, now)
            return {'dispatched': 1}
        return self._call(finish)

    def feedback_event(self, envelope):
        def operation(state, now):
            event = self.feedback.admit(envelope)
            if not isinstance(event, dict) or set(event) != {'event', 'message', 'outcome'}:
                return {'accepted': False}
            if (not all(isinstance(value, str) and 1 <= len(value) <= 256 for value in event.values())
                    or event['outcome'] not in ('delivered', 'delay', 'bounce', 'complaint', 'rejected')):
                return {'accepted': False}
            if event['event'] in state['events']:
                return {'accepted': True}
            job = next((job for job in state['jobs'].values() if event['message'] in job['messages']), None)
            if not job:
                return {'accepted': False}
            state['events'][event['event']] = now
            if event['outcome'] == 'delivered':
                job['delivered'] = True
                if job['state'] == 'providerAccepted':
                    self._transition(job, 'mailServerDelivered', now)
            elif event['outcome'] == 'delay':
                self._escalate(state, job, 'providerDelay', now)
            else:
                self._escalate(state, job, event['outcome'], now)
                contact = state['contacts'].get(job['installation'])
                if contact and contact['revision'] == job['contact_revision']:
                    contact['active'], contact['delete_at'] = False, now + 86400
                    self._invalidate(state, job['installation'], contact['revision'], event['outcome'], now)
            return {'accepted': True}
        return self._call(operation)

    def access(self, proof, code):
        def operation(state, now):
            installation = self._installation(proof, 'caseAccess', now)
            if not isinstance(code, str) or len(code) > 256:
                raise _Refusal('notFound')
            rate = 'access:' + installation
            if len(state['rates'].get(rate, [])) >= 20:
                return None
            state['rates'].setdefault(rate, []).append(now)
            verifier = self._verify(installation + ':grant:', code)
            for job in state['jobs'].values():
                if (job['installation'] == installation and job['grant']
                        and hmac.compare_digest(job['grant'], verifier)
                        and self._eligible(state, job, now)
                        and job['state'] in ('providerAccepted', 'mailServerDelivered', 'noticeViewed')):
                    self._transition(job, 'noticeViewed', now)
                    return copy.deepcopy(job['notice'])
            return None
        result = self._call(operation)
        if result is None:
            raise Denied('notFound')
        return result

    def reconcile_actions(self, review, required):
        """Private action receipts supply authoritative scope; no public DB scan."""
        def operation(state, now):
            self._review(review, now, {'required': required})
            missing = 0
            for case, operation, revision in required:
                if not any(tuple(job['identity'][:3]) == (case, operation, revision)
                           for job in state['jobs'].values()):
                    record = dict(job=None, reason='missingNotice', at=now, required=(case, operation, revision))
                    if not any(item.get('required') == record['required'] for item in state['escalations']):
                        state['escalations'].append(record)
                    missing += 1
            return {'missing': missing}
        return self._call(operation)

    def private_job(self, review, identifier):
        def operation(state, now):
            self._review(review, now)
            job = state['jobs'].get(identifier)
            if not job:
                raise _Refusal('notFound')
            # Restricted operator readback only; omit grant and clear code even here.
            return {key: copy.deepcopy(job[key]) for key in ('state', 'attempts', 'history', 'escalations', 'delivered')}
        return self._call(operation)

    def aggregates(self):
        return self._call(lambda state, now: dict(
            contacts=sum(bool(contact['active']) for contact in state['contacts'].values()),
            pending=len(state['challenges']), jobs=len(state['jobs']), escalations=len(state['escalations'])))
