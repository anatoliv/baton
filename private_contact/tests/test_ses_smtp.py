"""Captured SMTP boundaries only; no socket, provider or real mailbox access."""
import re
import smtplib
import unittest

from private_contact import ContactService, Denied
from private_contact.ses_smtp import SESSMTP
from private_contact.tests.test_delivery import (
    SyntheticAuthority, SyntheticCustody, SyntheticFeedback, SyntheticSecrets)


class CapturedConnection:
    def __init__(self, *, mail=(250, b'Ok'), rcpt=(250, b'Ok'),
                 data=(250, b'Ok synthetic-ses-reference'), close_error=False):
        self.replies = dict(mail=mail, rcpt=rcpt, data=data)
        self.calls = []
        self.close_error = close_error

    def reply(self, stage, value):
        self.calls.append((stage, value))
        result = self.replies[stage]
        if isinstance(result, Exception):
            raise result
        return result

    def mail(self, value):
        return self.reply('mail', value)

    def rcpt(self, value):
        return self.reply('rcpt', value)

    def data(self, value):
        return self.reply('data', value)

    def close(self):
        self.calls.append(('close', None))
        if self.close_error:
            raise OSError('SYNTHETIC PRIVATE DIAGNOSTIC')


class CapturedFactory:
    synthetic = True
    def __init__(self, *connections):
        self.connections = list(connections)
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return self.connections.pop(0)


class SMTPSubmissionTests(unittest.TestCase):
    message = dict(kind='notice', recipient='sharer@recipient.invalid', code='synthetic-code')

    def adapter(self, *connections, mode='synthetic'):
        self.factory = CapturedFactory(*connections)
        return SESSMTP(connect=self.factory, mode=mode)

    def test_confirmed_envelope_refusal_never_enters_data(self):
        for stage, code, outcome in [('mail', 451, 'transient'), ('rcpt', 554, 'permanent')]:
            with self.subTest(stage=stage):
                connection = CapturedConnection(**{stage: (code, b'SYNTHETIC PRIVATE DIAGNOSTIC')})
                self.assertEqual(self.adapter(connection).send(self.message), (outcome, None))
                self.assertNotIn('data', [call[0] for call in connection.calls])
                self.assertEqual(connection.calls[-1], ('close', None))

    def service(self, factory):
        return ContactService(custody=SyntheticCustody(), authority=SyntheticAuthority(),
                              secrets=SyntheticSecrets(), feedback=SyntheticFeedback(),
                              mail=SESSMTP(connect=factory, mode='synthetic'),
                              clock=lambda: self.now, mode='synthetic')

    def verified_job(self, service, verification):
        service.enroll('install-a', 'sharer@recipient.invalid', 'synthetic-consent-v1')
        wire = next(value for stage, value in verification.calls if stage == 'data')
        code = re.search(rb'Code: ([A-Za-z0-9_-]+)', wire).group(1).decode('ascii')
        self.assertEqual(service.verify('install-a', code), {'status': 'verified'})
        return service.queue(review='synthetic-reviewed', installation='synthetic-a',
                             case='synthetic-case', operation='synthetic-operation', revision=1,
                             share='synthetic-share', created=self.now + 1,
                             notice={'instructions': 'SYNTHETIC PRIVATE NOTICE', 'location': '/s/private'})

    def test_confirmed_refusal_retries_only_after_persisted_delay(self):
        self.now = 1000
        verification, refused, accepted = (CapturedConnection(),
            CapturedConnection(rcpt=(451, b'Temporary refusal')), CapturedConnection())
        factory = CapturedFactory(verification, refused, accepted)
        service = self.service(factory)
        job = self.verified_job(service, verification)
        service.dispatch()
        self.assertEqual(service.private_job('synthetic-reviewed', job)['state'], 'transientFailure')
        self.assertEqual(service.dispatch(), {'dispatched': 0})
        self.now += 60
        service.dispatch()
        self.assertEqual(factory.calls, 3)
        info = service.private_job('synthetic-reviewed', job)
        self.assertEqual((info['state'], info['attempts'], info['delivered']), ('providerAccepted', 2, False))
        wire = next(value for stage, value in accepted.calls if stage == 'data')
        self.assertNotIn(b'SYNTHETIC PRIVATE NOTICE', wire)
        self.assertNotIn(b'/s/private', wire)
        self.assertEqual(service.feedback_event(dict(authenticated=True, scope='synthetic-approved',
            event='synthetic-feedback', message='synthetic-ses-reference', outcome='delivered')), {'accepted': True})

    def test_lost_data_response_escalates_without_blind_retry(self):
        self.now = 1000
        verification = CapturedConnection()
        uncertain = CapturedConnection(data=OSError('SYNTHETIC PRIVATE DIAGNOSTIC'))
        factory = CapturedFactory(verification, uncertain)
        service = self.service(factory)
        job = self.verified_job(service, verification)
        service.dispatch()
        self.now += 600
        self.assertEqual(service.dispatch(), {'dispatched': 0})
        info = service.private_job('synthetic-reviewed', job)
        self.assertEqual((info['state'], info['attempts']), ('outcomeUnknown', 1))
        self.assertIn('outcomeUnknown', info['escalations'])
        self.assertEqual(factory.calls, 2)
        self.assertEqual([s for s, _ in uncertain.calls], ['mail', 'rcpt', 'data', 'close'])

    def test_response_classification_and_cleanup_preserve_acceptance(self):
        for response, expected in [((451, b'Refused'), ('transient', None)),
                                  ((554, b'Refused'), ('permanent', None)),
                                  (smtplib.SMTPDataError(554, b'Refused'), ('permanent', None)),
                                  ((250, b'Ok'), ('unknown', None)),
                                  ((250.0, b'Ok synthetic-reference'), ('unknown', None)),
                                  ((250, b'Ok unsafe\r\nreference'), ('unknown', None)),
                                  ((250, b'Ok synthetic-reference'), ('accepted', 'synthetic-reference'))]:
            with self.subTest(expected=expected):
                connection = CapturedConnection(data=response, close_error=True)
                self.assertEqual(self.adapter(connection).send(self.message), expected)
                self.assertEqual(connection.calls[-1], ('close', None))

    def test_connection_or_envelope_disconnect_is_confirmed_before_data(self):
        for stage in ('mail', 'rcpt'):
            with self.subTest(stage=stage):
                connection = CapturedConnection(**{stage: smtplib.SMTPServerDisconnected('PRIVATE')})
                self.assertEqual(self.adapter(connection).send(self.message), ('transient', None))
                self.assertNotIn('data', [s for s, _ in connection.calls])
                self.assertEqual(connection.calls[-1], ('close', None))
        class UnavailableFactory:
            synthetic = True
            def __call__(self):
                raise OSError('SYNTHETIC PRIVATE DIAGNOSTIC')
        self.assertEqual(SESSMTP(connect=UnavailableFactory(), mode='synthetic').send(self.message),
                         ('transient', None))

    def test_disabled_or_invalid_inputs_refuse_before_connection(self):
        factory = CapturedFactory()
        factory.synthetic = False
        self.assertEqual(SESSMTP(connect=factory, mode='synthetic').send(self.message), ('permanent', None))
        self.assertEqual(factory.calls, 0)
        for mode in ('disabled', 'production'):
            adapter = self.adapter(mode=mode)
            self.assertEqual(adapter.send(self.message), ('permanent', None))
            self.assertEqual(self.factory.calls, 0)
            with self.assertRaisesRegex(Denied, '^disabled$'):
                ContactService(custody=SyntheticCustody(), authority=SyntheticAuthority(),
                    secrets=SyntheticSecrets(), feedback=SyntheticFeedback(), mail=adapter,
                    clock=lambda: 1000, mode='synthetic').status('install-a')
        for changes in (dict(recipient='someone@example.com'), dict(code='injected\r\nBcc: bad'),
                        dict(notice='SYNTHETIC PRIVATE NOTICE'), dict(kind='unsupported')):
            adapter = self.adapter()
            self.assertEqual(adapter.send(dict(self.message, **changes)), ('permanent', None))
            self.assertEqual(self.factory.calls, 0)

class ProductionTemplateTests(unittest.TestCase):
    def test_captured_connection_requires_verified_tls_before_login(self):
        import ssl
        from unittest.mock import patch
        from private_contact.ses_smtp import SMTPConnect
        events = []
        class Connection:
            def ehlo(self):
                events.append('ehlo')
            def starttls(self, *, context):
                events.append('tls')
                self.context = context
            def login(self, username, password):
                events.append('login')
                self.credentials = (username, password)
            def close(self):
                events.append('close')
        connection = Connection()
        with patch('private_contact.ses_smtp.smtplib.SMTP', return_value=connection) as transport:
            self.assertIs(SMTPConnect(username='PUBLIC FIXTURE', password='PUBLIC FIXTURE ONLY')(), connection)
        transport.assert_called_once_with('email-smtp.us-east-1.amazonaws.com', 587, timeout=8)
        self.assertEqual(events, ['ehlo', 'tls', 'ehlo', 'login'])
        self.assertTrue(connection.context.check_hostname)
        self.assertEqual(connection.context.verify_mode, ssl.CERT_REQUIRED)
        self.assertEqual(connection.credentials, ('PUBLIC FIXTURE', 'PUBLIC FIXTURE ONLY'))

    def test_qualified_adapter_uses_approved_template_and_captured_transport(self):
        from private_contact.ses_smtp import SESSMTP
        class Captured:
            production_ready = True
            def __init__(self):
                self.wire = None
            def __call__(self):
                return self
            def mail(self, address):
                return 250, b'accepted'
            def rcpt(self, address):
                return 250, b'accepted'
            def data(self, wire):
                self.wire = wire
                return 250, b'Ok fixture-message'
            def close(self):
                pass
        capture = Captured()
        adapter = SESSMTP(connect=capture, mode='production')
        self.assertEqual(adapter.send(dict(kind='notice', recipient='sharer@recipient.invalid',
                         code='public-fixture-code')), ('accepted', 'fixture-message'))
        self.assertIn(b'Reply-To: notify@batonmusic.app', capture.wire)
        self.assertIn(b'4 hours', capture.wire)
        self.assertNotIn(b'SYNTHETIC LOCAL', capture.wire)
        self.assertNotIn(b'counter-notice', capture.wire)
