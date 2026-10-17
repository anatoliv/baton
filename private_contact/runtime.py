"""Protected construction and private Unix HTTP entry point, disabled by default."""
from __future__ import annotations
from dataclasses import dataclass
import hashlib
from importlib.metadata import version as package_version
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import signal
import socketserver
import stat
import time

from .bridge import BridgeAuthority, KeyedSecrets, ShareSource, admitted
from .backup import CaseBackups
from .custody import AESGCMCodec, JournaledCustody, SQLiteCustody
from .feedback import SNSFeedback
from .recipient import RecipientPolicy
from .service import ContactService, Denied
from .ses_smtp import SMTPConnect, SESSMTP

SOURCE_FILES = ('private_contact/backup.py', 'private_contact/backup_job.py', 'private_contact/onedrive.py', 'private_contact/__init__.py', 'private_contact/service.py', 'private_contact/custody.py',
                'private_contact/bridge.py', 'private_contact/runtime.py', 'private_contact/__main__.py',
                'private_contact/feedback.py', 'private_contact/recipient.py', 'private_contact/ses_smtp.py',
                'private_contact/sns_feedback.py', 'private_contact/feedback_ingress.py',
                'gateway/Sources/BatonShareServer/ShareContactBridge.swift',
                'gateway/Sources/BatonShareServer/ShareConfiguration.swift',
                'gateway/Sources/BatonShareServer/ShareEnforcementStore.swift',
                'gateway/Sources/BatonShareServer/ShareService.swift',
                'gateway/Sources/BatonShareServer/ShareContactRelay.swift',
                'gateway/Sources/baton-share/main.swift')
INPUTS = ('encryption_key_file', 'journal_key_file', 'verifier_key_file', 'operator_key_file',
          'reader_token_file', 'smtp_file', 'sns_certificate_file')
FIELDS = {'version', 'enabled', 'enrollment_enabled', 'sending_enabled', 'source_digests', 'source_revision',
          'deployment_card', 'operational_approval', 'qualified', 'state_root', 'contact_directory', 'history_directory', 'authority_directory', 'socket_file', 'feedback_socket_file', 'feedback_group_gid', 'export_root',
          'onedrive_root', 'public_mounts', 'inputs', 'share_port', 'dns_resolver', 'sns',
          'runtime_executable', 'runtime_digest', 'cryptography_version', 'iam', 'backup'}


def protected_path(value: str, *, directory: bool = False) -> Path:
    if not isinstance(value, str):
        raise Denied('configuration')
    path = Path(value)
    if not path.is_absolute() or path.resolve() != path:
        raise Denied('configuration')
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
            or not directory and info.st_nlink != 1):
        raise Denied('configuration')
    if not directory:
        protected_path(str(path.parent), directory=True)
    return path


def protected_read(value: str, limit: int = 65536) -> bytes:
    path = protected_path(value)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or info.st_size > limit:
            raise Denied('configuration')
        return os.read(descriptor, limit + 1)
    finally:
        os.close(descriptor)


@dataclass(frozen=True)
class Admission:
    allow_service: bool
    allow_enrollment: bool
    allow_sending: bool


def protected_socket(value: str, *, binding: bool = False) -> Path:
    """Companions admit only a qualified socket; binding requires an absent target."""
    try:
        endpoint = Path(value)
        if not endpoint.is_absolute() or endpoint.resolve() != endpoint:
            raise ValueError()
        protected_path(str(endpoint.parent), directory=True)
        try:
            info = endpoint.lstat()
        except FileNotFoundError:
            return endpoint
        if (binding or not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise ValueError()
        return endpoint
    except Exception:
        raise Denied('configuration') from None


def validate_manifest(path: str, source_root: Path, *, binding_socket: bool = False, binding_feedback: bool = False) -> dict:
    try:
        manifest = json.loads(protected_read(path))
        if (set(manifest) != FIELDS or manifest['version'] != 1
                or any(type(manifest[field]) is not bool for field in
                       ('enabled', 'enrollment_enabled', 'sending_enabled', 'qualified'))
                or set(manifest['source_digests']) != set(SOURCE_FILES)):
            raise ValueError()
        for name, digest in manifest['source_digests'].items():
            if (not isinstance(digest, str) or not re.fullmatch(r'[a-f0-9]{64}', digest)
                    or hashlib.sha256((source_root / name).read_bytes()).hexdigest() != digest):
                raise ValueError()
        if (set(manifest['backup']) != {'retention_days', 'destructive_expiry_enabled', 'remote_verified', 'held_cases_verified'}
                or manifest['backup']['retention_days'] != 30
                or manifest['backup']['destructive_expiry_enabled'] is not False
                or any(type(manifest['backup'][field]) is not bool for field in ('remote_verified', 'held_cases_verified'))):
            raise ValueError()
        group_gid = manifest['feedback_group_gid']
        if (group_gid is not None and (type(group_gid) is not int or not 0 < group_gid <= 2147483647
                or manifest['feedback_socket_file'] is None)):
            raise ValueError()
        if not manifest['enabled']:
            if manifest['enrollment_enabled'] or manifest['sending_enabled']:
                raise ValueError()
            return manifest  # No private inputs are read or state/socket created.
        if (not manifest['qualified'] or not re.fullmatch(r'[a-f0-9]{40}', manifest['source_revision'] or '')
                or not re.fullmatch(r'TBX-\d+', manifest['deployment_card'] or '')
                or not isinstance(manifest['operational_approval'], str) or not manifest['operational_approval']
                or set(manifest['inputs']) != set(INPUTS)
                or type(manifest['share_port']) is not int or not 1 <= manifest['share_port'] <= 65535
                or not isinstance(manifest['public_mounts'], list) or not manifest['public_mounts']):
            raise ValueError()
        if set(manifest['iam']) != {'principal_linkage_verified', 'recipient_amendment_verified', 'current_policy_digest',
                                  'candidate_policy_digest', 'candidate_policy_file', 'rollback_policy_file'}:
            raise ValueError()
        if manifest['enrollment_enabled'] or manifest['sending_enabled']:
            if (manifest['iam']['principal_linkage_verified'] is not True or manifest['iam']['recipient_amendment_verified'] is not True
                    or manifest['backup']['remote_verified'] is not True or manifest['backup']['held_cases_verified'] is not True):
                raise ValueError()
            for name, digest in (('candidate_policy_file', 'candidate_policy_digest'), ('rollback_policy_file', 'current_policy_digest')):
                policy = protected_read(manifest['iam'][name])
                if hashlib.sha256(policy).hexdigest() != manifest['iam'][digest]:
                    raise ValueError()
        runtime = Path(manifest['runtime_executable'])
        if (not runtime.is_absolute() or runtime.resolve() != Path(sys.executable).resolve()
                or hashlib.sha256(runtime.read_bytes()).hexdigest() != manifest['runtime_digest']
                or package_version('cryptography') != manifest['cryptography_version']):
            raise ValueError()
        private = [protected_path(manifest[name], directory=True) for name in ('state_root', 'export_root', 'onedrive_root')]
        private += [protected_path(value) for value in manifest['inputs'].values()]
        socket_path = protected_socket(manifest['socket_file'], binding=binding_socket)
        socket_parents = [socket_path.parent]
        if manifest['feedback_socket_file'] is not None:
            from .feedback_ingress import feedback_socket
            feedback_path = feedback_socket(manifest['feedback_socket_file'], group_gid=group_gid, binding=binding_feedback)
            if feedback_path == socket_path or feedback_path.parent == socket_path.parent:
                raise ValueError()
            if any(feedback_path.parent == item or feedback_path.parent in item.parents
                   or item in feedback_path.parent.parents for item in private + socket_parents):
                raise ValueError()
            socket_parents.append(feedback_path.parent)
        elif binding_feedback:
            raise ValueError()
        private.extend(socket_parents)
        public = [Path(value) for value in manifest['public_mounts']]
        if any(not item.is_absolute() or item.resolve() != item or not item.is_dir() for item in public):
            raise ValueError()
        if any(a == b or a in b.parents or b in a.parents for a in private for b in public):
            raise ValueError()
        public_inodes = {(item.stat().st_dev, item.stat().st_ino) for item in public}
        if any((ancestor.stat().st_dev, ancestor.stat().st_ino) in public_inodes
               for item in private for ancestor in (item, *item.parents) if ancestor.exists()):
            raise ValueError()
        roots = private[:3]
        children = [Path(manifest[name]) for name in ('contact_directory', 'history_directory', 'authority_directory')]
        if any(not child.is_absolute() or child.resolve() != child or child.parent != roots[0] for child in children):
            raise ValueError()
        if len(set(children)) != 3:
            raise ValueError()
        for child in children:
            if child.exists():
                protected_path(str(child), directory=True)
        if any(a == b or a in b.parents or b in a.parents for i, a in enumerate(roots) for b in roots[i + 1:]):
            raise ValueError()
        if len(set(manifest['inputs'].values())) != len(INPUTS):
            raise ValueError()
        # Key/sender material must be outside state and all export namespaces.
        if any(root in item.parents for root in roots for item in private[3:-len(socket_parents)]):
            raise ValueError()
        if set(manifest['sns']) != {'certificate_url', 'fingerprint', 'topic', 'account', 'identity', 'configuration_set'}:
            raise ValueError()
        return manifest
    except Exception:
        raise Denied('configuration') from None


class PrivateAPI:
    def __init__(self, *, service, authority, operator_key: bytes, clock, custody):
        self.service, self.authority, self.operator_key, self.clock, self.custody = service, authority, operator_key, clock, custody

    def _operator(self, envelope: dict, path: str) -> dict:
        claims = admitted(self.operator_key, envelope.get('authorization'))
        now = int(self.clock())
        if (set(claims) != {'path', 'body', 'issued', 'expires', 'nonce'} or claims['path'] != path
                or type(claims['issued']) is not int or type(claims['expires']) is not int
                or claims['expires'] != claims['issued'] + 60 or not claims['issued'] <= now < claims['expires']
                or not isinstance(claims['nonce'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{22,64}', claims['nonce'])
                or not isinstance(claims['body'], dict)):
            raise Denied('unauthorized')
        def consume(state):
            state = state or {'replays': {}, 'cases': {}}
            replays = {value: expiry for value, expiry in state.get('operator_replays', {}).items() if expiry > now}
            if claims['nonce'] in replays or len(replays) >= 10000:
                raise Denied('unauthorized')
            replays[claims['nonce']] = claims['expires']
            state['operator_replays'] = replays
            return claims['body'], state
        return self.authority.ledger.transact(consume)

    def handle(self, path: str, raw: bytes) -> tuple[int, dict]:
        try:
            if not isinstance(raw, bytes) or not 1 <= len(raw) <= 65536:
                raise Denied('invalid')
            if path == '/feedback':
                return 200, self.service.feedback_event(raw)
            body = json.loads(raw)
            if not isinstance(body, dict):
                raise Denied('invalid')
            if path.startswith('/operator/'):
                if set(body) != {'authorization'}:
                    raise Denied('invalid')
                command = self._operator(body, path)
                if path == '/operator/review-and-queue':
                    if set(command) != {'installation', 'case', 'operation', 'revision', 'share', 'created', 'notice'}:
                        raise Denied('invalid')
                    review = self.authority.review(command, int(self.clock()))
                    return 200, {'job': self.service.queue(review=review, **command)}
                if path == '/operator/reconcile-restore' and not command:
                    self.custody.reconcile_restore()
                    return 200, {'status': 'reconciled'}
                if path == '/operator/reconcile-actions' and set(command) == {'after'} and isinstance(command['after'], str):
                    required, proof, next_cursor = self.authority.required_actions(command['after'])
                    result = self.service.reconcile_actions(proof, required)
                    result['next'] = next_cursor
                    return 200, result
                if path == '/operator/job' and set(command) == {'job'}:
                    return 200, self.service.private_job(self.authority.operator_readback(), command['job'])
                if path == '/operator/aggregates' and not command:
                    return 200, self.service.aggregates()
                raise Denied('invalid')
            schemas = {'/enroll': {'authorization', 'address', 'consent', 'include'},
                       '/verify': {'authorization', 'code'}, '/withdraw': {'authorization'},
                       '/status': {'authorization'}, '/access': {'authorization', 'code'}}
            if path not in schemas or set(body) != schemas[path]:
                raise Denied('invalid')
            proof = body['authorization']
            if path == '/enroll':
                if not isinstance(body['include'], list):
                    raise Denied('invalid')
                result = self.service.enroll(proof, body['address'], body['consent'], body['include'])
            elif path == '/verify':
                result = self.service.verify(proof, body['code'])
            elif path == '/withdraw':
                result = self.service.withdraw(proof)
            elif path == '/status':
                result = self.service.status(proof)
            else:
                result = self.service.access(proof, body['code'])
            return 200, result
        except Denied as failure:
            category = str(failure)
            allowed = {'disabled', 'invalid', 'unauthorized', 'notFound', 'conflict', 'rateLimited',
                       'configuration', 'custodyReviewRequired', 'reviewRequired', 'stateLimit', 'sourceUnavailable'}
            return (403 if category == 'unauthorized' else 503 if category not in {'invalid', 'notFound'} else 400), {'error': category if category in allowed else 'unavailable'}
        except Exception:
            return 503, {'error': 'unavailable'}


def build_runtime(manifest: dict, clock=time.time, backup: bytes | None = None) -> PrivateAPI:
    if not manifest['enabled']:
        raise Denied('disabled')
    try:
        inputs = manifest['inputs']
        keys = [protected_read(inputs[field], 32) for field in INPUTS[:4]]
        if any(len(key) != 32 for key in keys) or len(set(keys)) != 4:
            raise ValueError()
        primary_key, journal_key, verifier_key, operator_key = keys
        reader = protected_read(inputs['reader_token_file'], 256).decode('ascii').strip()
        if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', reader):
            raise ValueError()
        smtp = json.loads(protected_read(inputs['smtp_file'], 4096))
        if set(smtp) != {'username', 'password'} or not all(isinstance(value, str) for value in smtp.values()):
            raise ValueError()
        recipient = RecipientPolicy(manifest['dns_resolver'])
        feedback = SNSFeedback(certificate=protected_read(inputs['sns_certificate_file']),
                               clock=clock, **manifest['sns'])
        mail = SESSMTP(connect=SMTPConnect(**smtp), mode='production')
        # Validate all non-state inputs before any store initialization.
        primary = (SQLiteCustody.restore(manifest['contact_directory'], backup=backup, codec=AESGCMCodec(primary_key))
                   if backup is not None else SQLiteCustody(manifest['contact_directory'], codec=AESGCMCodec(primary_key)))
        journal = SQLiteCustody(manifest['history_directory'], codec=AESGCMCodec(journal_key))
        custody = JournaledCustody(primary=primary, journal=journal)
        ledger = SQLiteCustody(manifest['authority_directory'], codec=AESGCMCodec(journal_key))
        if not ledger.reconciled():
            raise ValueError()
        authority = BridgeAuthority(key=verifier_key, ledger=ledger,
            source=ShareSource(port=manifest['share_port'], reader=reader), recipient=recipient)
        admission = Admission(True, manifest['enrollment_enabled'], manifest['sending_enabled'])
        service = ContactService(custody=custody, authority=authority, secrets=KeyedSecrets(verifier_key),
                                 mail=mail, feedback=feedback, clock=clock, mode='production', admission=admission)
        return CaseBackups(PrivateAPI(service=service, authority=authority, operator_key=operator_key, clock=clock, custody=custody))
    except Exception:
        raise Denied('configuration') from None


def private_handler(api: PrivateAPI, *, installation_only: bool = False):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # No request paths, recipients, authorizations or payloads enter logs.
        def do_POST(self):
            try:
                if (self.headers.get('Transfer-Encoding') or self.path.split('?', 1)[0] != self.path
                        or installation_only and self.path not in {'/enroll', '/verify', '/withdraw', '/status', '/access'}):
                    raise ValueError()
                size = int(self.headers.get('Content-Length', '0'))
                if not 1 <= size <= 65536:
                    raise ValueError()
                status, response = api.handle(self.path, self.rfile.read(size))
            except Exception:
                status, response = 400, {'error': 'invalid'}
            body = json.dumps(response, separators=(',', ':')).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'private, no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    return Handler


def installation_server(api: PrivateAPI, port: int):
    """Installation-only loopback entry, never operator/feedback routes or payload logs."""
    if type(port) is not int or not 1 <= port <= 65535:
        raise Denied('configuration')
    class Server(HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(5)
            return connection, address
    return Server(('127.0.0.1', port), private_handler(api, installation_only=True))


def private_server(api: PrivateAPI, socket_file: str):
    endpoint = protected_socket(socket_file, binding=True)
    Handler = private_handler(api)
    class Server(socketserver.UnixStreamServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(5)
            return connection, address
        def server_close(self):
            super().server_close()
            identity = getattr(self, 'endpoint_identity', None)
            if identity is None:
                return  # Bind/initialization never qualified this endpoint.
            try:
                protected_socket(str(endpoint))
                parent = endpoint.parent.stat()
                info = endpoint.lstat()
                if ((parent.st_dev, parent.st_ino) == self.parent_identity
                        and (info.st_dev, info.st_ino) == identity):
                    endpoint.unlink()
            except (Denied, FileNotFoundError):
                pass  # Keep changed, unsafe or unidentified endpoints.
    # Bind remains exclusive. Normal close removes only this exact qualified inode.
    previous = os.umask(0o077)
    try:
        server = Server(str(endpoint), Handler)
        os.chmod(endpoint, 0o600)
        info, parent = endpoint.lstat(), endpoint.parent.stat()
        server.endpoint_identity = (info.st_dev, info.st_ino)
        server.parent_identity = (parent.st_dev, parent.st_ino)
        return server
    finally:
        os.umask(previous)


def serve(api: PrivateAPI, socket_file: str, *, installation_port: int | None = None) -> None:
    server = (private_server(api, socket_file) if installation_port is None
              else installation_server(api, installation_port))
    with server:
        class StopServing(BaseException):
            # Request/adapter error sanitizers must not swallow owned shutdown.
            pass
        def stop(signum, frame):
            raise StopServing()
        previous = signal.signal(signal.SIGTERM, stop)
        try:
            server.serve_forever(poll_interval=0.5)
        except (StopServing, KeyboardInterrupt):
            pass
        finally:
            signal.signal(signal.SIGTERM, previous)
