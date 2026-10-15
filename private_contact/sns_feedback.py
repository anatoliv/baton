"""Standalone SNS admission; no service activation, persistence or payload logging.

The certificate is trusted through HTTPS to the configured SNS region, never
through a key, certificate or hostname supplied by an arbitrary event publisher.
"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import http.client
import json
import math
import re
import ssl
import subprocess
import sys
import time
import uuid
from urllib.parse import urlsplit

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

BODY_LIMIT = 256 * 1024
CERT_LIMIT = 16 * 1024
FETCH_TIMEOUT = 3.0
DEPTH_LIMIT = 32


class SNSFeedbackDenied(Exception):
    """Only a fixed category crosses the boundary, without private error text."""


class _Invalid(Exception):
    pass


def _certificate_path(url, region):
    # Exact spelling also refuses port overrides, userinfo, query, fragments,
    # percent escapes, Unicode, whitespace and alternate hostname normalization.
    host = 'sns.' + region + '.amazonaws.com'
    if not isinstance(url, str) or not re.fullmatch(
            r'https://' + re.escape(host) +
            r'/SimpleNotificationService-[A-Za-z0-9_-]{1,128}\.pem', url):
        raise _Invalid('certificateURL')
    return urlsplit(url).path


class PublicSigningCertificateTransport:
    """AWS public certificate GET only; HTTPS verifies the server, no redirects.

    No proxy/environment discovery, credentials, automatic retries or cookies.
    Byte and elapsed-time bounds cover headers and streamed body reads. The
    socket timeout also bounds each connection/TLS operation. A short-lived
    isolated worker enforces the wall-clock deadline, including system DNS.
    """
    def __init__(self, region):
        if not isinstance(region, str) or not re.fullmatch(r'[a-z]{2}-[a-z]+-\d', region):
            raise ValueError('configuration')
        self.region = region

    def __call__(self, url, *, timeout, max_bytes):
        category = 'unavailable'
        try:
            _certificate_path(url, self.region)
            if timeout != FETCH_TIMEOUT or max_bytes != CERT_LIMIT:
                raise _Invalid('configuration')
            # No shell, inherited private environment, credentials or URL in
            # argv. Worker output is bounded by _fetch; stderr is discarded.
            result = subprocess.run(
                [sys.executable, '-I', __file__, '--public-certificate'],
                input=json.dumps({'region': self.region, 'url': url}).encode(),
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env={}, timeout=timeout, check=False)
            if result.returncode != 0 or not 1 <= len(result.stdout) <= max_bytes:
                raise _Invalid('unavailable')
            return result.stdout
        except _Invalid as error:
            category = str(error)
        except Exception:
            pass
        raise SNSFeedbackDenied(category) from None

    def _fetch(self, url, *, timeout, max_bytes):
        """Runs only inside the bounded worker (or mocked offline tests)."""
        category = 'unavailable'
        try:
            path = _certificate_path(url, self.region)
            if timeout != FETCH_TIMEOUT or max_bytes != CERT_LIMIT:
                raise _Invalid('configuration')
            deadline = time.monotonic() + timeout
            connection = http.client.HTTPSConnection(
                'sns.' + self.region + '.amazonaws.com', timeout=timeout,
                context=ssl.create_default_context())
            try:
                connection.request('GET', path, headers={'Accept': 'application/x-pem-file'})
                _remaining(connection, deadline)
                response = connection.getresponse()
                if response.status != 200:
                    raise _Invalid('unavailable')
                length = response.getheader('Content-Length')
                if length is not None and (not length.isdecimal() or int(length) > max_bytes):
                    raise _Invalid('unavailable')
                chunks, size = [], 0
                while True:
                    _remaining(connection, deadline)
                    chunk = response.read1(min(4096, max_bytes + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                    if size > max_bytes:
                        raise _Invalid('unavailable')
                _remaining(connection, deadline)
                return b''.join(chunks)
            finally:
                connection.close()
        except _Invalid as error:
            category = str(error)
        except Exception:
            pass
        raise SNSFeedbackDenied(category) from None


def _remaining(connection, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise _Invalid('unavailable')
    if connection.sock is not None:
        connection.sock.settimeout(remaining)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _Invalid('invalid')
        result[key] = value
    return result


def _constant(_):
    raise _Invalid('invalid')


def _integer(value):
    if len(value) > 128:
        raise _Invalid('invalid')
    return int(value)


def _float(value):
    result = float(value)
    if not math.isfinite(result):
        raise _Invalid('invalid')
    return result


def _object(raw):
    if not isinstance(raw, bytes) or not 1 <= len(raw) <= BODY_LIMIT:
        raise _Invalid('invalid')
    text = raw.decode('utf-8', errors='strict')
    # Check nesting before the parser, including containers in ignored fields.
    depth, quoted, escaped = 0, False, False
    for character in text:
        if quoted:
            if escaped:
                escaped = False
            elif character == '\\':
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        elif character in '[{':
            depth += 1
            if depth > DEPTH_LIMIT:
                raise _Invalid('invalid')
        elif character in ']}':
            depth -= 1
    result = json.loads(text, object_pairs_hook=_pairs, parse_constant=_constant,
                        parse_int=_integer, parse_float=_float)
    if not isinstance(result, dict):
        raise _Invalid('invalid')
    return result


def _string(value, limit):
    if not isinstance(value, str) or not 1 <= len(value) <= limit:
        raise _Invalid('invalid')
    return value


class SNSFeedback:
    """Verify original raw Notification bytes before parsing SES claims.

    Configure exact approved values explicitly; this adapter reads no private
    files or environment. It intentionally has no synthetic marker. A transport
    override is for offline certificates in tests, not a production trust bypass.
    """
    def __init__(self, *, topic_arn, account_id, mail_from, configuration_set,
                 certificate_transport=None, clock=None, rendering_failure=False):
        match = re.fullmatch(
            r'arn:aws:sns:([a-z]{2}-[a-z]+-\d):([0-9]{12}):[A-Za-z0-9_-]{1,256}',
            topic_arn) if isinstance(topic_arn, str) else None
        if (not match or not isinstance(account_id, str)
                or not re.fullmatch(r'[0-9]{12}', account_id)
                or not isinstance(mail_from, str) or not 1 <= len(mail_from) <= 254
                or any(ord(c) < 33 or ord(c) > 126 for c in mail_from)
                or not isinstance(configuration_set, str)
                or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', configuration_set)):
            raise ValueError('configuration')
        self.topic_arn, self.account_id = topic_arn, account_id
        self.mail_from, self.configuration_set = mail_from, configuration_set
        self.region = match[1]
        self.transport = (PublicSigningCertificateTransport(self.region)
                          if certificate_transport is None else certificate_transport)
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self.rendering_failure = rendering_failure is True

    def admit(self, raw):
        category = 'invalid'
        try:
            return self._admit(raw)
        except _Invalid as error:
            category = str(error)
        except Exception:
            pass
        # Raising outside the handler avoids retaining private exception context.
        raise SNSFeedbackDenied(category) from None

    def _admit(self, raw):
        envelope = _object(raw)
        if envelope.get('Type') != 'Notification':
            raise _Invalid('invalid')
        if envelope.get('TopicArn') != self.topic_arn:
            raise _Invalid('scope')
        message = _string(envelope.get('Message'), BODY_LIMIT)
        message_id = _string(envelope.get('MessageId'), 36)
        if str(uuid.UUID(message_id)) != message_id:
            raise _Invalid('invalid')
        timestamp = _string(envelope.get('Timestamp'), 32)
        if not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z', timestamp):
            raise _Invalid('invalid')
        datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
        fields = ['Message', 'MessageId']
        if 'Subject' in envelope:
            _string(envelope['Subject'], 100)
            fields.append('Subject')
        fields += ['Timestamp', 'TopicArn', 'Type']
        canonical = ''.join(field + '\n' + envelope[field] + '\n' for field in fields).encode('utf-8')
        version = envelope.get('SignatureVersion')
        if version not in ('1', '2'):
            raise _Invalid('authentication')
        signature = base64.b64decode(_string(envelope.get('Signature'), 2048), validate=True)
        url = envelope.get('SigningCertURL')
        _certificate_path(url, self.region)
        try:
            pem = self.transport(url, timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT)
        except Exception:
            raise _Invalid('unavailable') from None
        if not isinstance(pem, bytes) or not 1 <= len(pem) <= CERT_LIMIT:
            raise _Invalid('unavailable')
        try:
            certificate = x509.load_pem_x509_certificate(pem)
            now = self.clock()
            if not certificate.not_valid_before_utc <= now <= certificate.not_valid_after_utc:
                raise _Invalid('authentication')
            key = certificate.public_key()
            if not isinstance(key, rsa.RSAPublicKey) or key.key_size < 2048:
                raise _Invalid('authentication')
            key.verify(signature, canonical, padding.PKCS1v15(),
                       hashes.SHA1() if version == '1' else hashes.SHA256())
        except Exception:
            raise _Invalid('authentication') from None
        # No SES field is parsed or relied on before this verification.
        event = _object(message.encode('utf-8'))
        mail = event.get('mail')
        if not isinstance(mail, dict):
            raise _Invalid('invalid')
        tags = mail.get('tags')
        if (mail.get('sendingAccountId') != self.account_id
                or mail.get('source') != self.mail_from
                or not isinstance(tags, dict)
                or tags.get('ses:configuration-set') != [self.configuration_set]):
            raise _Invalid('scope')
        identifier = _string(mail.get('messageId'), 256)
        if not re.fullmatch(r'[A-Za-z0-9_-]+', identifier):
            raise _Invalid('invalid')
        outcomes = {'Delivery': 'delivered', 'DeliveryDelay': 'delay',
                    'Bounce': 'bounce', 'Complaint': 'complaint', 'Reject': 'rejected'}
        if self.rendering_failure:
            outcomes['Rendering Failure'] = 'rejected'
        event_type = (event.get('eventType', event.get('notificationType'))
                      if self.rendering_failure else event.get('eventType'))
        if event_type not in outcomes:
            raise _Invalid('invalid')
        if 'notificationType' in event and event['notificationType'] != event_type:
            raise _Invalid('invalid')
        return {'event': 'sns:' + message_id, 'message': identifier,
                'outcome': outcomes[event_type]}


if __name__ == '__main__':
    # Internal worker, never a service launcher. It accepts only a public AWS
    # certificate URL and emits certificate bytes; no payload or error output.
    try:
        if sys.argv[1:] != ['--public-certificate']:
            raise ValueError('invalid')
        request = json.loads(sys.stdin.buffer.read(1024))
        pem = PublicSigningCertificateTransport(request['region'])._fetch(
            request['url'], timeout=FETCH_TIMEOUT, max_bytes=CERT_LIMIT)
        sys.stdout.buffer.write(pem)
    except Exception:
        sys.exit(1)
