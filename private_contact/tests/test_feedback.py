"""Published RSA constants only; no real SNS certificate, key, account or mail."""
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import unittest
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.serialization import Encoding
from cryptography.x509.oid import NameOID
from private_contact.feedback import SNSFeedback


def public_fixture():
    numbers = {key: int(value, 16) for key, value in
               json.loads(Path(__file__).with_name('public-rsa-vector.json').read_text())['public_test_numbers'].items()}
    public = rsa.RSAPublicNumbers(numbers.pop('e'), numbers.pop('n'))
    key = rsa.RSAPrivateNumbers(public_numbers=public, **numbers).private_key()
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'PUBLIC SYNTHETIC TEST FIXTURE')])
    certificate = x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(public.public_key()).serial_number(1)
    certificate = certificate.not_valid_before(datetime(2020, 1, 1, tzinfo=timezone.utc))
    certificate = certificate.not_valid_after(datetime(2030, 1, 1, tzinfo=timezone.utc)).sign(key, hashes.SHA256())
    return key, certificate


class SNSBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.key, self.certificate = public_fixture()
        self.account = '000000000000'
        self.topic = 'arn:aws:sns:us-east-1:000000000000:public-fixture'
        self.identity = 'arn:aws:ses:us-east-1:000000000000:identity/batonmusic.app'
        self.url = 'https://sns.us-east-1.amazonaws.com/SimpleNotificationService-abc123.pem'
        self.now = datetime(2026, 10, 7, tzinfo=timezone.utc).timestamp()
        # Main's adapter keeps the raw SNS message UUID as the event identity.
        self.event_id = '00000000-0000-4000-8000-000000000000'
        self.adapter = SNSFeedback(certificate=self.certificate.public_bytes(Encoding.PEM), certificate_url=self.url,
            fingerprint=self.certificate.fingerprint(hashes.SHA256()).hex(), topic=self.topic,
            account=self.account, identity=self.identity, configuration_set='public-fixture-set', clock=lambda: self.now)

    def envelope(self, **changes):
        event = dict(eventType='Delivery', mail=dict(source='notify@batonmusic.app', sendingAccountId=self.account,
                     sourceArn=self.identity, messageId='fixture-message', destination=['sharer@recipient.invalid'],
                     tags={'ses:configuration-set': ['public-fixture-set']},
                     headers=[{'name': 'private', 'value': 'PUBLIC FIXTURE CONTENT STRIPPED'}]))
        event.update(changes.pop('event_changes', {}))
        message = dict(Type='Notification', MessageId=self.event_id, TopicArn=self.topic,
                       Timestamp='2026-10-07T00:00:00Z', Message=json.dumps(event), Subject='Public fixture subject',
                       SignatureVersion='2', SigningCertURL=self.url)
        message.update(changes)
        fields = ['Message', 'MessageId', 'Subject', 'Timestamp', 'TopicArn', 'Type']
        canonical = ''.join(field + '\n' + message[field] + '\n' for field in fields).encode()
        message['Signature'] = base64.b64encode(self.key.sign(canonical, padding.PKCS1v15(), hashes.SHA256())).decode()
        return message

    def test_signature_verification_returns_only_scoped_minimal_event(self):
        body = json.dumps(self.envelope()).encode()
        self.assertEqual(self.adapter.admit(body), dict(event=self.event_id, message='fixture-message', outcome='delivered'))
        tampered = self.envelope()
        tampered['Message'] = '{}'
        self.assertIsNone(self.adapter.admit(json.dumps(tampered).encode()))

    def test_foreign_topic_account_certificate_url_and_stale_event_refuse(self):
        for changes in ({'TopicArn': self.topic + '-foreign'}, {'SigningCertURL': 'https://recipient.invalid/secret'},
                        {'Timestamp': '2020-01-01T00:00:00Z'}, {'Type': 'SubscriptionConfirmation'},
                        {'event_changes': {'mail': dict(source='notify@batonmusic.app', sendingAccountId='111111111111',
                         sourceArn=self.identity, messageId='fixture-message')}},
                        {'event_changes': {'mail': dict(source='notify@batonmusic.app', sendingAccountId=self.account,
                         sourceArn=self.identity, messageId='fixture-message',
                         tags={'ses:configuration-set': ['foreign-set']})}}):
            self.assertIsNone(self.adapter.admit(json.dumps(self.envelope(**changes)).encode()))
        self.assertIsNone(self.adapter.admit(b'x' * 65537))
        self.assertIsNone(self.adapter.admit({'authenticated': True}))
