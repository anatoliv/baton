"""Offline actual Tonebox receiver → Unix ingress → journaled worker acceptance.

Run this file with --staged-runtime and --tonebox-source. Staging applies the
tracked patch to exactly the allowlisted qualified source, before these imports.
No real configuration or provider transport is imported or discovered.
"""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from email import policy
from email.parser import BytesParser
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch
import uuid


def load_sources(runtime, tonebox):
    sys.path.insert(0, str(Path(runtime).resolve()))
    sys.path.insert(1, str(Path(tonebox).resolve() / 'backend'))
    configuration = types.ModuleType('app.core.config')
    configuration.settings = types.SimpleNamespace(
        SES_SNS_TOPIC_ARN='arn:aws:sns:us-east-1:000000000000:reserved-test-topic',
        BATON_SES_FROM_ADDRESS='notify@batonmusic.app', BATON_SES_FEEDBACK_SOCKET=None,
        BATON_SES_FEEDBACK_OWNER_UID=None, BATON_SES_FEEDBACK_GROUP_GID=None,
        SUPPORT_FROM_ADDRESS='support@tonebox.invalid', SUPPORT_ADMIN_ADDRESS=None)
    database = types.ModuleType('app.core.database')
    def never_connect():
        raise AssertionError('offline database transport was not replaced')
    database.SessionLocal = never_connect
    sys.modules['app.core.config'], sys.modules['app.core.database'] = configuration, database


class FixtureAuthority:
    production_ready = True  # Only a reserved local fixture, never runtime authorization.
    def installation(self, proof, purpose, now):
        return 'reserved-installation' if proof == 'reserved-proof' else None
    def owned(self, proof, shares, now):
        return False
    def case(self, review, now, scope=None):
        return review == 'reserved-review'
    def current_case(self, scope, now):
        return True
    def recipient(self, address):
        return address.endswith('@recipient.invalid')


class CapturedSMTP:
    production_ready = True
    def __init__(self):
        self.messages = []
    def __call__(self):
        return self
    def mail(self, address):
        return 250, b'accepted'
    def rcpt(self, address):
        if not address.endswith('@recipient.invalid'):
            raise AssertionError('nonreserved recipient')
        return 250, b'accepted'
    def data(self, wire):
        self.messages.append(BytesParser(policy=policy.default).parsebytes(wire))
        return 250, ('Ok reserved-ses-' + str(len(self.messages))).encode()
    def close(self):
        pass
    def code(self):
        return re.search(r'Code: ([A-Za-z0-9_-]+)', self.messages[-1].get_content()).group(1)


class ConnectedFeedbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        cls.now = int(datetime(2026, 10, 9, 21, 15, tzinfo=timezone.utc).timestamp())
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'reserved.invalid')])
        moment = datetime.fromtimestamp(cls.now, timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                       .public_key(cls.key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(moment - timedelta(days=1)).not_valid_after(moment + timedelta(days=1))
                       .sign(cls.key, hashes.SHA256()))
        cls.pem = certificate.public_bytes(serialization.Encoding.PEM)
        cls.fingerprint = certificate.fingerprint(hashes.SHA256()).hex()
        cls.topic = 'arn:aws:sns:us-east-1:000000000000:reserved-test-topic'
        cls.cert_url = 'https://sns.us-east-1.amazonaws.com/SimpleNotificationService-abc123.pem'
        cls.identity = 'arn:aws:ses:us-east-1:000000000000:identity/batonmusic.app'
    def setUp(self):
        from app.services import ses_events
        from app.core.config import settings
        self.settings, self.tonebox = settings, ses_events
        self.temporary = tempfile.TemporaryDirectory(prefix='feedback-acceptance-', dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.endpoint = str(self.root / 'feedback.sock')
        self.settings.BATON_SES_FEEDBACK_SOCKET = self.endpoint
        self.cert_patch = patch.object(ses_events, '_fetch_cert', return_value=self.pem)
        self.cert_patch.start()
        self.addCleanup(self.cert_patch.stop)
        self.capture = CapturedSMTP()
        self.authority = FixtureAuthority()
        self.restart()
        self.service.enroll('reserved-proof', 'sharer@recipient.invalid', 'contact-v1')
        self.service.verify('reserved-proof', self.capture.code())
        self.job = self.service.queue(review='reserved-review', installation='reserved-installation',
            case='reserved-case', operation='reserved-operation', revision=1,
            share='reserved-share', created=self.now + 1,
            notice={'instructions': 'RESERVED PRIVATE CASE TEXT'})
        self.service.dispatch()
        self.ses_id = 'reserved-ses-2'
        self.grant = self.capture.code()
    def restart(self):
        from private_contact import ContactService
        from private_contact.bridge import KeyedSecrets
        from private_contact.custody import AESGCMCodec, JournaledCustody, SQLiteCustody
        from private_contact.feedback import SNSFeedback
        from private_contact.runtime import PrivateAPI
        from private_contact.ses_smtp import SESSMTP
        self.custody = JournaledCustody(
            primary=SQLiteCustody(self.root / 'primary', codec=AESGCMCodec(bytes(range(32)))),
            journal=SQLiteCustody(self.root / 'history', codec=AESGCMCodec(bytes(reversed(range(32))))))
        self.feedback = SNSFeedback(certificate=self.pem, certificate_url=self.cert_url,
            fingerprint=self.fingerprint, topic=self.topic, account='000000000000',
            identity=self.identity, configuration_set='reserved-configuration', clock=lambda: self.now)
        self.service = ContactService(custody=self.custody, authority=self.authority,
            secrets=KeyedSecrets(b'V' * 32), mail=SESSMTP(connect=self.capture, mode='production'),
            feedback=self.feedback, clock=lambda: self.now, mode='local')
        self.api = PrivateAPI(service=self.service, authority=self.authority,
            operator_key=b'O' * 32, clock=lambda: self.now, custody=self.custody)
    def event(self, kind='Delivery', **mail_changes):
        mail = dict(source='notify@batonmusic.app', sendingAccountId='000000000000',
                    sourceArn=self.identity, messageId=self.ses_id,
                    tags={'ses:configuration-set': ['reserved-configuration']},
                    destination=['sharer@recipient.invalid'],
                    headers=[{'name': 'Subject', 'value': 'RESERVED PRIVATE CASE TEXT'}])
        mail.update(mail_changes)
        return dict(eventType=kind, mail=mail)
    def signed(self, event=None, **changes):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding
        envelope = dict(Type='Notification', Message=json.dumps(event or self.event()),
                        MessageId=str(uuid.uuid4()), TopicArn=self.topic,
                        Timestamp=datetime.fromtimestamp(self.now, timezone.utc).isoformat().replace('+00:00', 'Z'),
                        SignatureVersion='2', SigningCertURL=self.cert_url)
        envelope.update(changes)
        # Independent AWS field-name sort, not either implementation's helper.
        fields = {'Type', 'TopicArn', 'Timestamp', 'MessageId', 'Message'}
        if 'Subject' in envelope:
            fields.add('Subject')
        canonical = '\n'.join(part for field in sorted(fields) for part in (field, envelope[field])) + '\n'
        envelope['Signature'] = base64.b64encode(self.key.sign(canonical.encode(), padding.PKCS1v15(), hashes.SHA256())).decode()
        return json.dumps(envelope).encode()
    @contextmanager
    def server(self):
        from private_contact.feedback_ingress import feedback_server
        server = feedback_server(self.api, self.endpoint)
        self.assertEqual(Path(self.endpoint).stat().st_mode & 0o777, 0o600)
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.01})
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()
            self.assertFalse(thread.is_alive(), 'owned feedback server thread did not stop')
            self.assertFalse(Path(self.endpoint).exists(), 'owned feedback socket did not close')
    def private(self, path, raw):
        connection = http.client.HTTPConnection('localhost', timeout=3)
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.settimeout(3)
        connection.sock.connect(self.endpoint)
        try:
            connection.request('POST', path, raw, {'Content-Type': 'application/json'})
            response = connection.getresponse()
            self.assertEqual(response.getheader('Cache-Control'), 'private, no-store')
            return response.status, json.loads(response.read())
        finally:
            connection.close()
    def receiver(self, raw):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        from app.api.v1.ses_events import router
        app = FastAPI()
        app.include_router(router, prefix='/api/v1')
        with TestClient(app) as client:
            response = client.post('/api/v1/ses/events', content=raw, headers={'Content-Type': 'application/json'})
        return response.status_code, response.json()
    def job_info(self):
        return self.service.private_job('reserved-review', self.job)

    def test_actual_signed_receiver_unix_journal_restart_and_duplicate(self):
        raw = self.signed()
        with self.server():
            self.assertEqual(self.receiver(raw), (200, {'status': 'baton', 'detail': 'accepted'}))
        first = self.job_info()
        self.assertEqual(first['state'], 'mailServerDelivered')
        self.restart()
        self.assertEqual(self.job_info(), first)
        with self.server():
            self.assertEqual(self.receiver(raw)[0], 200)
        self.assertEqual(self.job_info(), first)
        self.assertEqual(len(self.capture.messages), 2)
        self.assertEqual(self.feedback.admit(raw)['event'], json.loads(raw)['MessageId'])

    def test_rendering_failure_retains_qualified_rejected_policy(self):
        with self.server():
            self.assertEqual(self.receiver(self.signed(self.event('Rendering Failure')))[0], 200)
        self.assertEqual(self.job_info()['state'], 'cancelled')
        self.assertIn('rejected', self.job_info()['escalations'])

    def test_all_feedback_outcomes_use_actual_signed_ingress(self):
        for kind, outcome in (('Delivery', 'delivered'), ('DeliveryDelay', 'delay'), ('Bounce', 'bounce'),
                              ('Complaint', 'complaint'), ('Reject', 'rejected')):
            with self.subTest(kind=kind):
                raw = self.signed(self.event(kind))
                self.assertEqual(self.feedback.admit(raw)['outcome'], outcome)
                with self.server():
                    self.assertEqual(self.receiver(raw)[0], 200)

    def test_foreign_scope_orphans_forgery_and_freshness_are_refused(self):
        changes = ({'sendingAccountId': '111111111111'}, {'sourceArn': self.identity + '-foreign'},
                   {'tags': {'ses:configuration-set': ['foreign']}}, {'messageId': 'reserved-orphan'})
        with self.server():
            for fields in changes:
                self.assertEqual(self.receiver(self.signed(self.event(**fields)))[0], 400)
            stale = datetime.fromtimestamp(self.now - 901, timezone.utc).isoformat().replace('+00:00', 'Z')
            self.assertEqual(self.receiver(self.signed(Timestamp=stale))[0], 400)
            forged = json.loads(self.signed())
            forged['Message'] += 'tampered'
            self.assertEqual(self.receiver(json.dumps(forged).encode())[0], 400)
        self.assertEqual(self.job_info()['state'], 'providerAccepted')

    def test_bounce_or_withdrawal_cannot_be_resurrected_after_restart(self):
        with self.server():
            self.assertEqual(self.receiver(self.signed(self.event('Bounce')))[0], 200)
        self.restart()
        with self.server():
            self.assertEqual(self.receiver(self.signed())[0], 200)
        self.assertEqual(self.job_info()['state'], 'cancelled')
        self.assertIn('bounce', self.job_info()['escalations'])
        from private_contact import Denied
        with self.assertRaisesRegex(Denied, '^notFound$'):
            self.service.access('reserved-proof', self.grant)

    def test_withdrawal_stays_cancelled_after_late_delivery_and_restart(self):
        self.service.withdraw('reserved-proof')
        self.restart()
        with self.server():
            self.assertEqual(self.receiver(self.signed())[0], 200)
        self.assertEqual(self.job_info()['state'], 'cancelled')
        self.assertIn('withdrawn', self.job_info()['escalations'])

    def test_only_boolean_true_durable_admission_is_acknowledged(self):
        with self.server():
            for value in (1, False, None, 'true'):
                with patch.object(self.api, 'handle', return_value=(200, {'accepted': value})):
                    self.assertEqual(self.receiver(self.signed())[0], 400)
        self.assertEqual(self.job_info()['state'], 'providerAccepted')

    def test_legacy_notification_type_and_freshness_boundary_are_preserved(self):
        event = self.event()
        event['notificationType'] = event.pop('eventType')
        boundary = datetime.fromtimestamp(self.now - 900, timezone.utc).isoformat().replace('+00:00', 'Z')
        with self.server():
            self.assertEqual(self.receiver(self.signed(event, Timestamp=boundary))[0], 200)

    def test_disconnected_peer_emits_no_private_server_traceback(self):
        import io
        from contextlib import redirect_stderr
        entered, release = threading.Event(), threading.Event()
        original = self.api.handle
        def before_reply(path, raw):
            result = original(path, raw)
            entered.set()
            release.wait(timeout=1)
            return result
        output = io.StringIO()
        with redirect_stderr(output), patch.object(self.api, 'handle', side_effect=before_reply):
            with self.server() as server:
                quiet = server.handle_error
                errors = []
                def observe_error(request, client_address):
                    errors.append(True)
                    quiet(request, client_address)
                server.handle_error = observe_error
                raw = self.signed()
                peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    peer.connect(self.endpoint)
                    peer.sendall(b'POST /feedback HTTP/1.1\r\nHost: localhost\r\nContent-Length: '
                                 + str(len(raw)).encode() + b'\r\n\r\n' + raw)
                    self.assertTrue(entered.wait(timeout=1))
                finally:
                    peer.close()
                    release.set()
            self.assertEqual(len(errors), 1)
        self.assertEqual(output.getvalue(), '')

    def test_feedback_listener_cannot_invoke_operator_or_installation_routes(self):
        with self.server():
            for path in ('/operator/job', '/operator/review-and-queue', '/operator/aggregates',
                         '/enroll', '/withdraw', '/access', '/status', '/feedback?private=1'):
                self.assertNotEqual(self.private(path, b'{}')[0], 200)
        self.assertEqual(self.job_info()['state'], 'providerAccepted')

    def test_down_private_transport_returns_503_and_redelivery_succeeds(self):
        raw = self.signed()
        self.assertEqual(self.receiver(raw)[0], 503)
        with self.server():
            self.assertEqual(self.receiver(raw)[0], 200)

    def test_failed_journal_commit_returns_503_and_redelivery_succeeds(self):
        raw = self.signed()
        with self.server():
            with patch.object(self.custody.journal, 'transact', side_effect=RuntimeError('RESERVED PRIVATE ERROR')):
                self.assertEqual(self.receiver(raw)[0], 503)
            self.assertEqual(self.receiver(raw)[0], 200)
        self.restart()
        self.assertEqual(self.job_info()['state'], 'mailServerDelivered')

    def test_certificate_unavailable_returns_503_without_private_error_logs(self):
        import structlog
        with structlog.testing.capture_logs() as logs:
            with patch.object(self.tonebox, '_fetch_cert', side_effect=self.tonebox.SnsTransientError('RESERVED PRIVATE ERROR')):
                self.assertEqual(self.receiver(self.signed())[0], 503)
        self.assertNotIn('RESERVED PRIVATE', str(logs))
        self.assertNotIn('feedback.sock', str(logs))
        self.assertNotIn('sharer@', str(logs))

    def test_baton_bypasses_tonebox_suppression_and_ordinary_delivery_is_preserved(self):
        with self.server(), patch.object(self.tonebox, 'apply_event', wraps=self.tonebox.apply_event) as apply:
            self.assertEqual(self.receiver(self.signed())[0], 200)
            apply.assert_not_called()
            with patch.object(self.tonebox, '_touch_outbox', return_value=True) as touch:
                ordinary = self.event(source='support@tonebox.invalid')
                self.assertEqual(self.receiver(self.signed(ordinary)), (200, {'status': 'event', 'detail': 'delivery'}))
                touch.assert_called_once_with(self.ses_id, status='delivered')
            self.assertEqual(apply.call_count, 1)

    def test_source_is_exact_envelope_sender_not_a_header_or_domain_match(self):
        with patch.object(self.tonebox, 'apply_event', return_value='ignored-foreign') as apply:
            for source in ('Display Name <notify@batonmusic.app>', 'foreign@batonmusic.app',
                           'notify@batonmusic.app.evil.invalid'):
                self.assertEqual(self.receiver(self.signed(self.event(source=source)))[0], 200)
            self.assertEqual(apply.call_count, 3)

    def test_unsafe_socket_mode_refused_then_recovers(self):
        raw = self.signed()
        with self.server():
            Path(self.endpoint).chmod(0o644)
            self.assertEqual(self.receiver(raw)[0], 503)
            Path(self.endpoint).chmod(0o600)
            self.assertEqual(self.receiver(raw)[0], 200)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--staged-runtime', required=True)
    parser.add_argument('--tonebox-source', required=True)
    parser.add_argument('--test', action='append', default=[])
    arguments = parser.parse_args()
    load_sources(arguments.staged_runtime, arguments.tonebox_source)
    unittest.main(argv=[sys.argv[0], *arguments.test], verbosity=2)
