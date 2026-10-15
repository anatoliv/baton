"""Protected-worker compatibility over the strict standalone SNS validator.

Retains the qualified worker's pinned certificate, identity, 900-second freshness,
64-KiB body ceiling and raw SNS event-id namespace. No network certificate fetch.
"""
from datetime import datetime, timezone
import re

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa

from .service import Denied
from .sns_feedback import SNSFeedback as StrictSNSFeedback, SNSFeedbackDenied, _object


class SNSFeedback:
    production_ready = True

    def __init__(self, *, certificate, certificate_url, fingerprint, topic, account,
                 identity, configuration_set, clock):
        try:
            parsed = x509.load_pem_x509_certificate(certificate)
            key = parsed.public_key()
            if (not re.fullmatch(r'\d{12}', account)
                    or not topic.startswith('arn:aws:sns:us-east-1:' + account + ':')
                    or identity != 'arn:aws:ses:us-east-1:' + account + ':identity/batonmusic.app'
                    or not re.fullmatch(r'https://sns\.us-east-1\.amazonaws\.com/'
                                        r'SimpleNotificationService-[a-f0-9]+\.pem', certificate_url)
                    or parsed.fingerprint(hashes.SHA256()).hex() != fingerprint
                    or not isinstance(key, rsa.RSAPublicKey) or key.key_size < 2048):
                raise ValueError()
            self.validator = StrictSNSFeedback(
                topic_arn=topic, account_id=account, mail_from='notify@batonmusic.app',
                configuration_set=configuration_set,
                certificate_transport=lambda url, **bounds: certificate,
                clock=lambda: datetime.fromtimestamp(clock(), timezone.utc), rendering_failure=True)
            self.url, self.identity, self.clock = certificate_url, identity, clock
            self.certificate = parsed
        except Exception:
            raise Denied('configuration') from None

    def admit(self, raw):
        try:
            if not isinstance(raw, bytes) or not 1 <= len(raw) <= 65536:
                return None
            envelope = _object(raw)
            required = {'Type', 'Message', 'MessageId', 'TopicArn', 'Timestamp',
                        'Signature', 'SignatureVersion', 'SigningCertURL'}
            if (not required <= set(envelope)
                    or not set(envelope) <= required | {'Subject', 'UnsubscribeURL'}
                    or not all(isinstance(value, str) for value in envelope.values())
                    or envelope['SigningCertURL'] != self.url):
                return None
            result = self.validator.admit(raw)
            # The standalone validator has authenticated the original Message.
            # These retained worker guards are additional, never replacements.
            stamp = datetime.fromisoformat(envelope['Timestamp'].replace('Z', '+00:00'))
            now = datetime.fromtimestamp(self.clock(), timezone.utc)
            if (abs((now - stamp).total_seconds()) > 900
                    or not self.certificate.not_valid_before_utc <= now < self.certificate.not_valid_after_utc):
                return None
            event = _object(envelope['Message'].encode())
            if event['mail'].get('sourceArn') != self.identity:
                return None
            result['event'] = envelope['MessageId']  # Keep existing durable dedup keys.
            return result
        except SNSFeedbackDenied as error:
            if str(error) == 'unavailable':
                raise Denied('unavailable') from None
            return None
        except Exception:
            return None
