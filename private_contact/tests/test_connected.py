"""Real local Swift HTTP source → private Unix HTTP → captured SMTP → case access."""
import base64
from email import policy
from email.parser import BytesParser
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time
import unittest

from private_contact import ContactService
from private_contact.bridge import BridgeAuthority, KeyedSecrets, ShareSource, signed
from private_contact.custody import AESGCMCodec, JournaledCustody, SQLiteCustody
from private_contact.runtime import PrivateAPI, private_server, installation_server
from private_contact.ses_smtp import SESSMTP
from private_contact.tests.test_delivery import SyntheticFeedback

PUBLIC_KEY = bytes(range(32))
OPERATOR_KEY = bytes(reversed(range(32)))


class CapturedSMTP:
    production_ready = True
    def __init__(self):
        self.messages = []
    def __call__(self):
        return self
    def mail(self, address):
        return 250, b'accepted'
    def rcpt(self, address):
        return 250, b'accepted'
    def data(self, wire):
        self.messages.append(BytesParser(policy=policy.default).parsebytes(wire))
        return 250, ('Ok fixture-message-' + str(len(self.messages))).encode()
    def close(self):
        pass
    def code(self):
        return re.search(r'Code: ([A-Za-z0-9_-]+)', self.messages[-1].get_content()).group(1)


class ConnectedBoundaryTests(unittest.TestCase):
    def test_actual_share_owner_private_transport_and_captured_smtp_notice(self):
        binary = Path('gateway/.build/debug/baton-share').resolve()
        self.assertTrue(binary.is_file(), 'build the actual local baton-share executable first')
        with tempfile.TemporaryDirectory(prefix='baton-contact-connected-', dir='/private/tmp') as temporary:
            root = Path(temporary)
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                relay_port = reservation.getsockname()[1]
            reader = 'R' * 48  # PUBLIC fixture capability, never a production input.
            owner = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('=')
            foreign = base64.urlsafe_b64encode(bytes(reversed(range(32)))).decode().rstrip('=')
            environment = dict(PATH=os.defpath, BATON_SHARE_DATA=str(root / 'public-share'),
                BATON_SHARE_PUBLIC_BASE='http://127.0.0.1:' + str(port), BATON_SHARE_PORT=str(port),
                BATON_SHARE_BIND='127.0.0.1', BATON_SHARE_BLOB_DELIVERY='direct',
                BATON_SHARE_CONTACT_RELAY_PORT=str(relay_port),
                BATON_SHARE_CONTACT_READER_DIGEST=hashlib.sha256(b'baton-share secret v1\0' + reader.encode()).hexdigest(),
                BATON_SHARE_ENFORCEMENT_ENABLED='1', BATON_SHARE_OPERATOR_TOKEN='O' * 48,
                BATON_SHARE_ENFORCEMENT_RETENTION_SECONDS='3600', BATON_SHARE_ENFORCEMENT_AUDIT_SECONDS='7200',
                BATON_SHARE_ENFORCEMENT_REASON_CODES='review')
            process = subprocess.Popen([str(binary)], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            def public(path, body=None, bearer=None):
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
                try:
                    headers = {'Content-Type': 'application/json'}
                    if bearer:
                        headers['Authorization'] = 'Bearer ' + bearer
                    connection.request('GET' if body is None else 'POST', path,
                                       None if body is None else json.dumps(body).encode(), headers)
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()
            try:
                started = False
                for _ in range(30):
                    try:
                        started = public('/health')[0] == 200
                        break
                    except OSError:
                        if process.poll() is not None:
                            break
                        threading.Event().wait(0.05)
                self.assertTrue(started, 'owned local share process did not start')
                status, created = public('/v1/share/shares', dict(expiresInSeconds=86400, playCap=5,
                    audioBytes=4096, audioSHA256=hashlib.sha256(b'x' * 4096).hexdigest(),
                    preview=dict(title='PUBLIC SYNTHETIC SONG', durationSeconds=40),
                    client=dict(platform='ios', appVersion='fixture')), owner)
                self.assertEqual(status, 201)
                share = created['id']
                def proof(purpose, bearer=owner, include=()):
                    status, result = public('/v1/share/contact/authorization', dict(purpose=purpose, include=list(include)), bearer)
                    self.assertEqual(status, 200)
                    return result['authorization']
                self.assertEqual(public('/v1/share/contact/authorization', dict(purpose='enroll', include=[share]), foreign)[0], 404)
                primary = SQLiteCustody(root / 'primary', codec=AESGCMCodec(PUBLIC_KEY))
                journal = SQLiteCustody(root / 'journal', codec=AESGCMCodec(OPERATOR_KEY))
                custody = JournaledCustody(primary=primary, journal=journal)
                authority = BridgeAuthority(key=PUBLIC_KEY,
                    ledger=SQLiteCustody(root / 'authority', codec=AESGCMCodec(OPERATOR_KEY)),
                    source=ShareSource(port=port, reader=reader), recipient=lambda value: value.endswith('@recipient.invalid'))
                capture = CapturedSMTP()
                feedback = SyntheticFeedback()
                feedback.production_ready = True
                service = ContactService(custody=custody, authority=authority, secrets=KeyedSecrets(PUBLIC_KEY),
                    mail=SESSMTP(connect=capture, mode='production'), feedback=feedback, clock=time.time, mode='local')
                api = PrivateAPI(service=service, authority=authority, operator_key=OPERATOR_KEY, clock=time.time, custody=custody)
                endpoint = str(root / 'private.sock')
                with private_server(api, endpoint) as server, installation_server(api, relay_port) as ingress:
                    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.05})
                    thread.start()
                    ingress_thread = threading.Thread(target=ingress.serve_forever, kwargs={'poll_interval': 0.05})
                    ingress_thread.start()
                    def private(path, body):
                        connection = http.client.HTTPConnection('localhost', timeout=3)
                        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        connection.sock.settimeout(3)
                        connection.sock.connect(endpoint)
                        try:
                            connection.request('POST', path, json.dumps(body).encode(), {'Content-Type': 'application/json'})
                            response = connection.getresponse()
                            self.assertEqual(response.getheader('Cache-Control'), 'private, no-store')
                            return response.status, json.loads(response.read())
                        finally:
                            connection.close()
                    def direct_installation(path, body):
                        connection = http.client.HTTPConnection('127.0.0.1', relay_port, timeout=3)
                        try:
                            connection.request('POST', path, json.dumps(body).encode(), {'Content-Type': 'application/json'})
                            response = connection.getresponse()
                            return response.status, json.loads(response.read())
                        finally:
                            connection.close()
                    def installation(path, body):
                        return public('/v1/share/contact/private' + path, body, owner)
                    try:
                        self.assertEqual(installation('/enroll', dict(authorization=proof('enroll', include=[share]),
                            address='sharer@recipient.invalid', consent='contact-v1', include=[share])), (200, {'status': 'pending'}))
                        self.assertEqual(installation('/verify', dict(authorization=proof('verify', foreign), code=capture.code())),
                                         (404, {'code': 'not_found', 'error': 'No such route.'}))
                        self.assertEqual(installation('/verify', dict(authorization=proof('verify'), code=capture.code())),
                                         (200, {'status': 'verified'}))
                        operation = '00000000-0000-0000-0000-000000000001'
                        status, plan = public('/v1/share/admin/enforcement/plan', dict(operationID=operation, action='disable-share',
                            shareID=share, caseReference='case_123', reasonCode='review'), 'O' * 48)
                        self.assertEqual(status, 200)
                        self.assertEqual(public('/v1/share/admin/enforcement/apply', plan, 'O' * 48)[0], 200)
                        now = int(time.time())
                        reconcile = signed(OPERATOR_KEY, dict(path='/operator/reconcile-actions', body={'after': ''},
                            issued=now, expires=now + 60, nonce='public-fixture-reconcile-before'))
                        self.assertEqual(private('/operator/reconcile-actions', {'authorization': reconcile}),
                                         (200, {'missing': 1, 'next': operation}))
                        scope = authority.source.action(operation, share, now)
                        scope['installation'] = authority.handle(scope['installation'])
                        scope.pop('action')
                        scope['notice'] = dict(instructions='SYNTHETIC reviewed case instructions', location='/s/' + share, action='disable-share')
                        operator = signed(OPERATOR_KEY, dict(path='/operator/review-and-queue', body=scope,
                            issued=now, expires=now + 60, nonce='public-fixture-operator-nonce'))
                        status, queued = private('/operator/review-and-queue', {'authorization': operator})
                        self.assertEqual(status, 200)
                        self.assertIn('job', queued)
                        reconcile = signed(OPERATOR_KEY, dict(path='/operator/reconcile-actions', body={'after': ''},
                            issued=now, expires=now + 60, nonce='public-fixture-reconcile-after'))
                        self.assertEqual(private('/operator/reconcile-actions', {'authorization': reconcile}),
                                         (200, {'missing': 0, 'next': operation}))
                        self.assertEqual(service.dispatch(), {'dispatched': 1})
                        self.assertEqual(len(capture.messages), 2)
                        self.assertNotIn('reviewed case', capture.messages[-1].get_content())
                        self.assertEqual(installation('/access', dict(authorization=proof('caseAccess'), code=capture.code())),
                                         (200, scope['notice']))
                        self.assertEqual(installation('/withdraw', dict(authorization=proof('withdraw'))), (200, {'status': 'disconnected'}))
                        self.assertNotEqual(installation('/access', dict(authorization=proof('caseAccess'), code=capture.code()))[0], 200)
                        self.assertEqual(service.dispatch(), {'dispatched': 0})
                        self.assertEqual(public('/v1/share/contact/private/operator/job', {'authorization': operator}, owner)[0], 404)
                        self.assertEqual(direct_installation('/operator/job', {'authorization': operator}), (400, {'error': 'invalid'}))
                        replay = proof('status')
                        self.assertEqual(installation('/status', {'authorization': replay}), (200, {'status': 'disconnected'}))
                        self.assertEqual(installation('/status', {'authorization': replay})[0], 404)
                    finally:
                        ingress.shutdown()
                        ingress_thread.join(timeout=3)
                        self.assertFalse(ingress_thread.is_alive(), 'owned installation server thread did not stop')
                        server.shutdown()
                        thread.join(timeout=3)
                        self.assertFalse(thread.is_alive(), 'owned private server thread did not stop')
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
