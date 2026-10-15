"""Reserved fixtures signed with ephemeral test keys; zero network or AWS auth.

Fixture signing uses sorted AWS-required field names independently of the
adapter's explicit field sequence, and pins that order to AWS's public example.
"""
import base64
import copy
from datetime import datetime, timedelta, timezone
import json
import traceback
import unittest
from unittest.mock import patch
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

from private_contact import ContactService, Denied
from private_contact.sns_feedback import (
    SNSFeedback, SNSFeedbackDenied, PublicSigningCertificateTransport,
    BODY_LIMIT, CERT_LIMIT, FETCH_TIMEOUT,
)
from private_contact.tests.test_delivery import (
    SyntheticCustody, SyntheticAuthority, SyntheticSecrets, CapturedMail,
)

TOPIC = 'arn:aws:sns:us-east-1:000000000000:reserved-test-topic'
SOURCE = 'sender@sender.invalid'
CONFIG = 'reserved-test-configuration'
CERT_URL = 'https://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem'
NOW = datetime(2026, 10, 9, 20, 0, tzinfo=timezone.utc)
PRIVATE_SENTINEL = 'RESERVED PRIVATE RECIPIENT AND CASE TEXT'


def fixture_string(envelope):
    required = {'Type', 'Timestamp', 'TopicArn', 'MessageId', 'Message'}
    if 'Subject' in envelope:
        required.add('Subject')
    return '\n'.join(part for field in sorted(required)
                     for part in (field, envelope[field])) + '\n'


def fixture_certificate(key, before=NOW - timedelta(days=1), after=NOW + timedelta(days=1)):
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'reserved.invalid')])
    return (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(before).not_valid_after(after).sign(key, hashes.SHA256())
            .public_bytes(serialization.Encoding.PEM))


class PublicCertificateFixture:
    def __init__(self, certificate):
        self.certificate, self.calls = certificate, []
    def __call__(self, url, *, timeout, max_bytes):
        self.calls.append((url, timeout, max_bytes))
        return self.certificate


class SignedFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.pem = fixture_certificate(cls.key)
    def setUp(self):
        self.transport = PublicCertificateFixture(self.pem)
        self.adapter = self.make_adapter()
    def make_adapter(self, **changes):
        fields = dict(topic_arn=TOPIC, account_id='000000000000', mail_from=SOURCE,
                      configuration_set=CONFIG, certificate_transport=self.transport,
                      clock=lambda: NOW)
        fields.update(changes)
        return SNSFeedback(**fields)
    def event(self, event_type='Delivery', message='synthetic-message-2'):
        return dict(eventType=event_type,
                    mail=dict(source=SOURCE, sendingAccountId='000000000000',
                              messageId=message, tags={'ses:configuration-set': [CONFIG]},
                              destination=['sharer@recipient.invalid'],
                              headers=[{'name': 'Subject', 'value': PRIVATE_SENTINEL}]),
                    delivery={'smtpResponse': PRIVATE_SENTINEL})
    def envelope(self, event=None, version='2', **changes):
        data = dict(Type='Notification', TopicArn=TOPIC,
                    Message=json.dumps(self.event() if event is None else event),
                    MessageId='4d4dc071-ddbf-465d-bba8-08f81c89da64',
                    Timestamp='2026-10-09T20:00:00.321Z',
                    SignatureVersion=version, SigningCertURL=CERT_URL)
        data.update(changes)
        return self.sign(data)
    def sign(self, envelope, key=None, canonical=None):
        envelope = copy.deepcopy(envelope)
        text = fixture_string(envelope) if canonical is None else canonical
        signature = (key or self.key).sign(
            text.encode(), padding.PKCS1v15(),
            hashes.SHA1() if envelope['SignatureVersion'] == '1' else hashes.SHA256())
        envelope['Signature'] = base64.b64encode(signature).decode()
        return envelope
    def raw(self, envelope):
        return json.dumps(envelope).encode()
    def refused(self, raw, category=None, adapter=None):
        with self.assertRaises(SNSFeedbackDenied) as captured:
            (adapter or self.adapter).admit(raw)
        error = captured.exception
        if category:
            self.assertEqual(str(error), category)
        self.assertNotIn(PRIVATE_SENTINEL, ''.join(traceback.format_exception(error)))
        self.assertIsNone(error.__context__)
        return error

    def test_authoritative_aws_example_field_order_and_trailing_newline(self):
        example = dict(Message='My Test Message',
                       MessageId='4d4dc071-ddbf-465d-bba8-08f81c89da64',
                       Subject='My subject', Timestamp='2019-01-31T04:37:04.321Z',
                       TopicArn='arn:aws:sns:us-east-2:123456789012:s4-MySNSTopic-1G1WEFCOXTC0P',
                       Type='Notification')
        self.assertEqual(fixture_string(example),
            'Message\nMy Test Message\nMessageId\n4d4dc071-ddbf-465d-bba8-08f81c89da64\n'
            'Subject\nMy subject\nTimestamp\n2019-01-31T04:37:04.321Z\n'
            'TopicArn\narn:aws:sns:us-east-2:123456789012:s4-MySNSTopic-1G1WEFCOXTC0P\n'
            'Type\nNotification\n')

    def test_sha1_and_sha256_optional_subject_and_escaped_values(self):
        for version in ('1', '2'):
            for subject in ({}, {'Subject': 'Reserved subject\nUnicode π'}):
                with self.subTest(version=version, subject=bool(subject)):
                    result = self.adapter.admit(self.raw(self.envelope(version=version, **subject)))
                    self.assertEqual(result, dict(event='sns:4d4dc071-ddbf-465d-bba8-08f81c89da64',
                                                  message='synthetic-message-2', outcome='delivered'))
        self.assertTrue(all(call == (CERT_URL, FETCH_TIMEOUT, CERT_LIMIT)
                            for call in self.transport.calls))

    def test_only_bounded_opaque_feedback_leaves_the_adapter(self):
        for kind, outcome in (('Delivery', 'delivered'), ('DeliveryDelay', 'delay'),
                              ('Bounce', 'bounce'), ('Complaint', 'complaint'), ('Reject', 'rejected')):
            result = self.adapter.admit(self.raw(self.envelope(self.event(kind))))
            self.assertEqual(set(result), {'event', 'message', 'outcome'})
            self.assertEqual(result['outcome'], outcome)
            self.assertNotIn(PRIVATE_SENTINEL, str(result))
            self.assertNotIn('recipient', str(result))
        self.refused(self.raw(self.envelope(self.event('Open'))), 'invalid')

    def test_raw_bytes_malformed_duplicate_nonfinite_and_deep_json(self):
        for raw in (None, {}, b'', b'\xff', b'[]', b'{', b'{"Type":1,"Type":2}',
                    b'{"ignored":NaN}', b'{"ignored":Infinity}', b'{"ignored":1e999}',
                    b'{"ignored":' + b'[' * 33 + b'0' + b']' * 33 + b'}'):
            self.refused(raw, 'invalid')
        self.assertEqual(self.transport.calls, [])

    def test_oversized_envelope_rejected_before_certificate_transport(self):
        self.refused(b' ' * (BODY_LIMIT + 1), 'invalid')
        self.assertEqual(self.transport.calls, [])

    def test_inner_json_is_not_parsed_before_authentication(self):
        data = self.envelope(Message='{"secret":' + PRIVATE_SENTINEL)
        data['Message'] += 'tampered'
        self.refused(self.raw(data), 'authentication')
        self.assertEqual(len(self.transport.calls), 1)

    def test_inner_duplicate_and_nonfinite_and_depth_rejected_after_signature(self):
        for text in ('{"mail":{},"mail":{}}', '{"x":NaN}', '{"x":1e999}',
                     '{"x":' + '[' * 33 + '0' + ']' * 33 + '}'):
            self.refused(self.raw(self.envelope(Message=text)), 'invalid')
        self.assertEqual(len(self.transport.calls), 4)

    def test_subscription_and_wrong_topic_rejected_without_certificate_fetch(self):
        for kind in ('SubscriptionConfirmation', 'UnsubscribeConfirmation', 'Other'):
            self.refused(self.raw(self.envelope(Type=kind)), 'invalid')
        self.refused(self.raw(self.envelope(TopicArn=TOPIC + '-foreign')), 'scope')
        self.assertEqual(self.transport.calls, [])

    def test_certificate_ssrf_guards_run_before_injected_transport(self):
        for url in ('http://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem',
                    'https://127.0.0.1/SimpleNotificationService-test.pem',
                    'https://sns.us-east-1.amazonaws.com.evil.invalid/SimpleNotificationService-test.pem',
                    'https://sns.us-east-2.amazonaws.com/SimpleNotificationService-test.pem',
                    CERT_URL + '?secret=' + PRIVATE_SENTINEL, CERT_URL + '#fragment',
                    CERT_URL.replace('https://', 'https://user@'),
                    CERT_URL.replace('.com/', '.com:443/'),
                    CERT_URL.replace('SimpleNotificationService-test.pem', '../test.pem'),
                    CERT_URL.replace('SimpleNotificationService-test.pem', '%2fSimpleNotificationService-test.pem'),
                    CERT_URL + '\n', 'https://sns.us-east-1.amazonaws.com/not-a-certificate.pem'):
            self.refused(self.raw(self.envelope(SigningCertURL=url)), 'certificateURL')
        self.assertEqual(self.transport.calls, [])

    def test_signature_tamper_wrong_key_algorithm_and_missing_trailing_newline(self):
        envelope = self.envelope()
        envelope['MessageId'] = str(uuid.uuid4())
        self.refused(self.raw(envelope), 'authentication')
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.refused(self.raw(self.sign(self.envelope(), key=other)), 'authentication')
        self.refused(self.raw(self.sign(self.envelope(), canonical=fixture_string(self.envelope()).rstrip('\n'))),
                     'authentication')
        self.refused(self.raw(self.envelope(SignatureVersion='3')), 'authentication')
        mismatched_algorithm = self.envelope()
        mismatched_algorithm['SignatureVersion'] = '1'
        self.refused(self.raw(mismatched_algorithm), 'authentication')

    def test_missing_and_invalid_authentication_fields(self):
        for field in ('Signature', 'SignatureVersion', 'SigningCertURL', 'Timestamp', 'MessageId', 'Message'):
            data = self.envelope()
            del data[field]
            self.refused(self.raw(data))
        for field, value in (('Signature', 'not-base64'), ('Subject', None), ('Timestamp', '2026-13-00T00:00:00Z'),
                             ('MessageId', 'private@recipient.invalid')):
            data = self.envelope()
            data[field] = value
            self.refused(self.raw(data))

    def test_certificate_validity_malformed_oversized_and_transport_privacy(self):
        for pem in (fixture_certificate(self.key, after=NOW - timedelta(seconds=1)),
                    fixture_certificate(self.key, before=NOW + timedelta(seconds=1)),
                    b'invalid certificate ' + PRIVATE_SENTINEL.encode(), b'x' * (CERT_LIMIT + 1)):
            self.transport.certificate = pem
            self.refused(self.raw(self.envelope()))
        def failing(*args, **kwargs):
            raise RuntimeError(PRIVATE_SENTINEL)
        self.refused(self.raw(self.envelope()), 'unavailable', self.make_adapter(certificate_transport=failing))

    def test_signed_wrong_account_source_configuration_and_conflicting_type(self):
        for field, value in (('sendingAccountId', '111111111111'), ('source', 'foreign@sender.invalid'),
                             ('source', 'Display Name <' + SOURCE + '>'),
                             ('tags', {}), ('tags', {'ses:configuration-set': ['foreign']}),
                             ('tags', {'ses:configuration-set': [CONFIG, 'foreign']})):
            event = self.event()
            event['mail'][field] = value
            self.refused(self.raw(self.envelope(event)), 'scope')
        event = self.event()
        event['notificationType'] = 'Complaint'
        self.refused(self.raw(self.envelope(event)), 'invalid')

    def test_untrusted_identifiers_cannot_return_recipient_or_header_data(self):
        for value in (PRIVATE_SENTINEL, 'sharer@recipient.invalid', 'id\ncase', '', 'x' * 257, None):
            self.refused(self.raw(self.envelope(self.event(message=value))), 'invalid')

    def test_no_production_or_synthetic_activation_marker(self):
        self.assertFalse(getattr(self.adapter, 'synthetic', False))
        service = ContactService(custody=SyntheticCustody(), authority=SyntheticAuthority(),
                                 secrets=SyntheticSecrets(), mail=CapturedMail(), feedback=self.adapter,
                                 clock=lambda: 1000, mode='synthetic')
        with self.assertRaisesRegex(Denied, '^disabled$'):
            service.status('install-a')

    def test_signed_known_send_correlation_dedup_foreign_and_orphan_refusal(self):
        service, job, _ = self.service_with_test_only_marker()
        good = self.raw(self.envelope())
        self.assertEqual(service.feedback_event(good), {'accepted': True})
        before = service.private_job('synthetic-reviewed', job)
        self.assertEqual(before['state'], 'mailServerDelivered')
        self.assertEqual(service.feedback_event(good), {'accepted': True})
        self.assertEqual(service.private_job('synthetic-reviewed', job), before)
        self.assertEqual(service.feedback_event(self.raw(self.envelope(
            self.event(message='synthetic-orphan'), MessageId=str(uuid.uuid4())))),
                         {'accepted': False})
        with self.assertRaisesRegex(Denied, '^unavailable$'):
            service.feedback_event(self.raw(self.envelope(TopicArn=TOPIC + '-foreign')))
        self.assertEqual(service.private_job('synthetic-reviewed', job), before)

    def test_signed_bounce_and_withdrawal_cannot_be_resurrected_by_delivery(self):
        for action in ('bounce', 'withdraw'):
            with self.subTest(action=action):
                service, job, grant = self.service_with_test_only_marker()
                if action == 'bounce':
                    service.feedback_event(self.raw(self.envelope(self.event('Bounce'))))
                else:
                    service.withdraw('install-a')
                service.feedback_event(self.raw(self.envelope(MessageId=str(uuid.uuid4()))))
                state = service.private_job('synthetic-reviewed', job)
                self.assertEqual(state['state'], 'cancelled')
                self.assertIn('bounce' if action == 'bounce' else 'withdrawn', state['escalations'])
                self.assertEqual(service.status('install-a'), {'status': 'disconnected'})
                with self.assertRaisesRegex(Denied, '^notFound$'):
                    service.access('install-a', grant)

    def service_with_test_only_marker(self):
        class ReservedOfflineFeedback(SNSFeedback):
            synthetic = True  # Only this test class may combine real validation with fixtures.
        feedback = ReservedOfflineFeedback(topic_arn=TOPIC, account_id='000000000000',
                                           mail_from=SOURCE, configuration_set=CONFIG,
                                           certificate_transport=self.transport, clock=lambda: NOW)
        mail = CapturedMail()
        service = ContactService(custody=SyntheticCustody(), authority=SyntheticAuthority(),
                                 secrets=SyntheticSecrets(), mail=mail, feedback=feedback,
                                 clock=lambda: 1000, mode='synthetic')
        service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        service.verify('install-a', mail.messages[-1]['code'])
        job = service.queue(review='synthetic-reviewed', installation='synthetic-a',
                            case='synthetic-case', operation='synthetic-operation', revision=1,
                            share='synthetic-share-new', created=1001,
                            notice={'instructions': PRIVATE_SENTINEL})
        service.dispatch()
        return service, job, mail.messages[-1]['code']


class PublicTransportTests(unittest.TestCase):
    def connection(self, status=200, data=b'public certificate', length=None):
        class Response:
            def __init__(self):
                self.status, self.remaining = status, data
            def getheader(self, name):
                return length
            def read1(self, amount):
                chunk, self.remaining = self.remaining[:amount], self.remaining[amount:]
                return chunk
        class Connection:
            sock = None
            closed = False
            calls = []
            def request(self, *args, **kwargs):
                self.calls.append((args, kwargs))
            def getresponse(self):
                return Response()
            def close(self):
                self.closed = True
        return Connection()
    def fetch(self):
        return PublicSigningCertificateTransport('us-east-1')._fetch(
            CERT_URL, timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT)
    def test_default_public_https_transport_fixed_host_path_and_closes(self):
        connection = self.connection()
        with patch('private_contact.sns_feedback.http.client.HTTPSConnection', return_value=connection) as factory:
            self.assertEqual(self.fetch(), b'public certificate')
        self.assertEqual(factory.call_args.args, ('sns.us-east-1.amazonaws.com',))
        self.assertEqual(factory.call_args.kwargs['timeout'], FETCH_TIMEOUT)
        self.assertEqual(connection.calls[0][0], ('GET', '/SimpleNotificationService-test.pem'))
        self.assertTrue(connection.closed)
    def test_redirect_status_and_declared_or_streamed_oversize_refused(self):
        for connection in (self.connection(status=302), self.connection(status=404),
                           self.connection(length=str(CERT_LIMIT + 1)),
                           self.connection(length='invalid'), self.connection(data=b'x' * (CERT_LIMIT + 1))):
            with patch('private_contact.sns_feedback.http.client.HTTPSConnection', return_value=connection):
                with self.assertRaisesRegex(SNSFeedbackDenied, '^unavailable$'):
                    self.fetch()
            self.assertTrue(connection.closed)
            self.assertEqual(len(connection.calls), 1)
    def test_elapsed_timeout_and_transport_errors_have_bounded_categories(self):
        connection = self.connection()
        with patch('private_contact.sns_feedback.http.client.HTTPSConnection', return_value=connection), \
             patch('private_contact.sns_feedback.time.monotonic', side_effect=[0, FETCH_TIMEOUT + 1]):
            with self.assertRaisesRegex(SNSFeedbackDenied, '^unavailable$'):
                self.fetch()
        self.assertTrue(connection.closed)
        with patch('private_contact.sns_feedback.http.client.HTTPSConnection', side_effect=RuntimeError(PRIVATE_SENTINEL)):
            with self.assertRaises(SNSFeedbackDenied) as captured:
                self.fetch()
        self.assertEqual(str(captured.exception), 'unavailable')
        self.assertIsNone(captured.exception.__context__)
    def test_transport_itself_refuses_ssrf_before_connection(self):
        with patch('private_contact.sns_feedback.http.client.HTTPSConnection') as factory:
            with self.assertRaisesRegex(SNSFeedbackDenied, '^certificateURL$'):
                PublicSigningCertificateTransport('us-east-1')(
                    'https://localhost/private', timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT)
        factory.assert_not_called()

    def test_public_worker_has_hard_deadline_and_no_inherited_private_environment(self):
        from types import SimpleNamespace
        with patch('private_contact.sns_feedback.subprocess.run',
                   return_value=SimpleNamespace(returncode=0, stdout=b'public certificate')) as run:
            self.assertEqual(PublicSigningCertificateTransport('us-east-1')(
                CERT_URL, timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT), b'public certificate')
        self.assertEqual(run.call_args.kwargs['timeout'], FETCH_TIMEOUT)
        self.assertEqual(run.call_args.kwargs['env'], {})
        self.assertNotIn(CERT_URL, str(run.call_args.args))
        self.assertEqual(json.loads(run.call_args.kwargs['input']), {'region': 'us-east-1', 'url': CERT_URL})

    def test_public_worker_timeout_nonzero_and_oversized_output_fail_closed(self):
        import subprocess
        from types import SimpleNamespace
        for result in (SimpleNamespace(returncode=1, stdout=b''),
                       SimpleNamespace(returncode=0, stdout=b'x' * (CERT_LIMIT + 1))):
            with patch('private_contact.sns_feedback.subprocess.run', return_value=result):
                with self.assertRaisesRegex(SNSFeedbackDenied, '^unavailable$'):
                    PublicSigningCertificateTransport('us-east-1')(
                        CERT_URL, timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT)
        with patch('private_contact.sns_feedback.subprocess.run',
                   side_effect=subprocess.TimeoutExpired(PRIVATE_SENTINEL, FETCH_TIMEOUT)):
            with self.assertRaisesRegex(SNSFeedbackDenied, '^unavailable$') as captured:
                PublicSigningCertificateTransport('us-east-1')(
                    CERT_URL, timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT)
        self.assertIsNone(captured.exception.__context__)

    def test_real_worker_refuses_private_url_without_network_or_error_output(self):
        import subprocess
        import sys
        import private_contact.sns_feedback as module
        # Execute only the real worker's pre-network URL refusal. This also
        # checks that the bundled interpreter imports cryptography with env={}.
        result = subprocess.run([sys.executable, '-I', module.__file__, '--public-certificate'],
                                input=json.dumps({'region': 'us-east-1',
                                                  'url': 'https://localhost/private'}).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env={}, timeout=FETCH_TIMEOUT, check=False)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (1, b'', b''))

    def test_timed_out_real_offline_child_is_killed_and_reaped(self):
        import subprocess
        import sys
        import time
        actual_run, actual_popen = subprocess.run, subprocess.Popen
        children = []
        def record_child(*args, **kwargs):
            child = actual_popen(*args, **kwargs)
            children.append(child)
            return child
        def offline_timeout(*args, **kwargs):
            # The fresh child only sleeps; it cannot perform DNS or HTTPS and
            # receives neither an SNS envelope nor provider configuration.
            return actual_run([sys.executable, '-I', '-c', 'import time; time.sleep(60)'],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              env={}, timeout=0.05, check=False)
        started = time.monotonic()
        with patch('private_contact.sns_feedback.subprocess.run', side_effect=offline_timeout), \
             patch('private_contact.sns_feedback.subprocess.Popen', side_effect=record_child):
            with self.assertRaisesRegex(SNSFeedbackDenied, '^unavailable$'):
                PublicSigningCertificateTransport('us-east-1')(
                    CERT_URL, timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT)
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].returncode)
        self.assertEqual(children[0].poll(), children[0].returncode)
        self.assertNotEqual(children[0].returncode, 0)


if __name__ == '__main__':
    unittest.main()
