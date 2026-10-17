"""Protected loader and real entry point refuse incomplete or unsafe activation."""
import json
import hashlib
from importlib.metadata import version as package_version
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from private_contact import Denied
from private_contact.runtime import INPUTS, SOURCE_FILES, build_runtime, validate_manifest


class ProtectedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='baton-contact-loader-', dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source'
        self.source.mkdir(mode=0o700)
        for name in SOURCE_FILES:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'abc')
        self.path = self.root / 'manifest.json'
        self.manifest = dict(version=1, enabled=False, enrollment_enabled=False, sending_enabled=False,
            source_digests={name: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' for name in SOURCE_FILES},
            source_revision=None, deployment_card=None, operational_approval=None, qualified=False,
            state_root=None, contact_directory=None, history_directory=None, authority_directory=None, socket_file=None, feedback_socket_file=None, feedback_group_gid=None, export_root=None, onedrive_root=None, public_mounts=[],
            inputs={name: None for name in INPUTS}, share_port=None, dns_resolver=None, sns={}, runtime_executable=None, runtime_digest=None, cryptography_version=None, iam=dict(principal_linkage_verified=False, recipient_amendment_verified=False,
                current_policy_digest=None, candidate_policy_digest=None, candidate_policy_file=None, rollback_policy_file=None),
            backup=dict(retention_days=30, destructive_expiry_enabled=False, remote_verified=False, held_cases_verified=False))
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.manifest))
        self.path.chmod(0o600)

    def test_default_off_reads_no_private_inputs_or_creates_state(self):
        manifest = validate_manifest(str(self.path), self.source)
        self.assertFalse(manifest['enabled'])
        with self.assertRaisesRegex(Denied, '^disabled$'):
            build_runtime(manifest)
        self.assertEqual(sorted(item.name for item in self.root.iterdir()), ['manifest.json', 'source'])

    def test_enable_with_missing_qualification_and_source_drift_refuses(self):
        self.manifest['enabled'] = True
        self.write()
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)
        self.manifest['enabled'] = False
        self.manifest['source_digests'][SOURCE_FILES[0]] = '0' * 64
        self.write()
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)

    def test_symlink_wide_mode_and_payload_errors_are_bounded(self):
        self.path.chmod(0o644)
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)
        self.path.chmod(0o600)
        alias = self.root / 'alias.json'
        alias.symlink_to(self.path)
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(alias), self.source)
        self.path.write_text('PUBLIC FIXTURE PAYLOAD NEVER ECHOED')
        process = subprocess.run([sys.executable, '-m', 'private_contact', '--manifest', str(self.path), '--check'],
                                 capture_output=True, text=True, timeout=5)
        self.assertEqual(process.returncode, 78)
        self.assertEqual(process.stdout, '')
        self.assertEqual(process.stderr, 'private-contact: configuration or execution refused\n')

    def enabled_fixture(self):
        for name in ('state', 'exports', 'onedrive', 'public-share', 'inputs', 'run'):
            (self.root / name).mkdir(mode=0o700)
        inputs = {}
        for name in INPUTS:
            file = self.root / 'inputs' / name
            file.write_bytes(b'PUBLIC FIXTURE ONLY')
            file.chmod(0o600)
            inputs[name] = str(file)
        runtime = Path(sys.executable).resolve()
        self.manifest.update(enabled=True, qualified=True, source_revision='1' * 40, deployment_card='TBX-0',
            operational_approval='PUBLIC FIXTURE ONLY', state_root=str(self.root / 'state'),
            contact_directory=str(self.root / 'state' / 'contact'), history_directory=str(self.root / 'state' / 'history'),
            authority_directory=str(self.root / 'state' / 'authority'), socket_file=str(self.root / 'run' / 'private.sock'),
            export_root=str(self.root / 'exports'), onedrive_root=str(self.root / 'onedrive'),
            public_mounts=[str(self.root / 'public-share')], inputs=inputs, share_port=12345, dns_resolver='127.0.0.1',
            runtime_executable=str(runtime), runtime_digest=hashlib.sha256(runtime.read_bytes()).hexdigest(),
            cryptography_version=package_version('cryptography'), sns=dict(certificate_url=None, fingerprint=None,
                topic=None, account=None, identity=None, configuration_set=None))
        self.write()

    def test_public_mount_overlap_input_modes_and_wrong_keys_refuse(self):
        self.enabled_fixture()
        manifest = validate_manifest(str(self.path), self.source)
        with self.assertRaisesRegex(Denied, '^configuration$'):
            build_runtime(manifest)
        self.assertEqual(list((self.root / 'state').iterdir()), [])

        self.manifest['public_mounts'] = [self.manifest['state_root']]
        self.write()
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)
        self.manifest['public_mounts'] = [str(self.root / 'public-share')]
        key_file = Path(self.manifest['inputs']['encryption_key_file'])
        key_file.chmod(0o644)
        self.write()
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)
        key_file.chmod(0o600)
        self.manifest['inputs']['journal_key_file'] = str(key_file)
        self.write()
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)
        self.assertEqual(list((self.root / 'state').iterdir()), [])

    def qualified_public_runtime_fixture(self):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.serialization import Encoding
        from private_contact.tests.test_feedback import public_fixture
        self.enabled_fixture()
        for field, value in zip(INPUTS[:4], (bytes(range(32)), bytes(reversed(range(32))), b'A' * 32, b'B' * 32)):
            Path(self.manifest['inputs'][field]).write_bytes(value)
        Path(self.manifest['inputs']['reader_token_file']).write_bytes(b'R' * 48)
        Path(self.manifest['inputs']['smtp_file']).write_text(json.dumps(dict(username='PUBLIC FIXTURE', password='PUBLIC FIXTURE ONLY')))
        _, certificate = public_fixture()
        Path(self.manifest['inputs']['sns_certificate_file']).write_bytes(certificate.public_bytes(Encoding.PEM))
        policy = self.root / 'inputs' / 'policy.json'
        policy.write_bytes(b'PUBLIC POLICY FIXTURE ONLY')
        policy.chmod(0o600)
        self.manifest['iam'] = dict(principal_linkage_verified=True, recipient_amendment_verified=True,
            current_policy_digest=hashlib.sha256(policy.read_bytes()).hexdigest(),
            candidate_policy_digest=hashlib.sha256(policy.read_bytes()).hexdigest(),
            candidate_policy_file=str(policy), rollback_policy_file=str(policy))
        self.manifest['backup'].update(remote_verified=True, held_cases_verified=True)
        self.manifest.update(sending_enabled=True,
            source_digests={name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in SOURCE_FILES},
            sns=dict(certificate_url='https://sns.us-east-1.amazonaws.com/SimpleNotificationService-abc123.pem',
                fingerprint=certificate.fingerprint(hashes.SHA256()).hex(),
                topic='arn:aws:sns:us-east-1:000000000000:public-fixture', account='000000000000',
                identity='arn:aws:ses:us-east-1:000000000000:identity/batonmusic.app',
                configuration_set='public-fixture-set'))
        self.write()

    def test_companion_dispatch_export_beside_server_and_guarded_restart(self):
        import http.client
        import socket
        import time
        from private_contact.bridge import signed
        self.qualified_public_runtime_fixture()
        endpoint = self.manifest['socket_file']
        def readback(nonce):
            now = int(time.time())
            proof = signed(b'B' * 32, dict(path='/operator/aggregates', body={}, issued=now, expires=now + 60, nonce=nonce))
            connection = http.client.HTTPConnection('localhost', timeout=3)
            connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.sock.settimeout(3)
            try:
                connection.sock.connect(endpoint)
                connection.request('POST', '/operator/aggregates', json.dumps({'authorization': proof}).encode(),
                                   {'Content-Type': 'application/json'})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.getheader('Cache-Control'), 'private, no-store')
                self.assertEqual(json.loads(response.read()), dict(contacts=0, pending=0, jobs=0, escalations=0))
            finally:
                connection.close()
        def start():
            process = subprocess.Popen([sys.executable, '-m', 'private_contact', '--manifest', str(self.path), '--serve'],
                env={'PATH': os.defpath}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.addCleanup(stop, process)
            for _ in range(30):
                if Path(endpoint).is_socket():
                    return process
                if process.poll() is not None:
                    break
                time.sleep(0.05)
            self.fail('owned fixture server did not bind')
        def stop(process):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        process = start()
        interrupted = None
        try:
            readback('public-fixture-start-readback')
            for index, operation in enumerate(('--dispatch-once', '--export')):
                command = subprocess.run([sys.executable, '-m', 'private_contact', '--manifest', str(self.path), operation],
                                         env={'PATH': os.defpath}, capture_output=True, text=True, timeout=5)
                self.assertEqual(command.returncode, 0, 'bounded companion command refused: ' + operation)
                self.assertEqual(command.stderr, '')
                self.assertIn('dispatch cycle completed' if index == 0 else 'encrypted export staged', command.stdout)
                readback('public-fixture-companion-' + str(index))
            second_server = subprocess.run([sys.executable, '-m', 'private_contact', '--manifest', str(self.path), '--serve'],
                                           env={'PATH': os.defpath}, capture_output=True, text=True, timeout=5)
            self.assertEqual(second_server.returncode, 78)
            self.assertEqual(second_server.stderr, 'private-contact: configuration or execution refused\n')
            interrupted = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            interrupted.connect(endpoint)
            interrupted.sendall(b'POST /status HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1024\r\n\r\n{')
            time.sleep(0.05)  # Allow the owned server to begin the incomplete body read.
        finally:
            stop(process)
            if interrupted is not None:
                interrupted.close()
        self.assertEqual(process.returncode, 0, 'SIGTERM must complete owned server cleanup')
        self.assertFalse(Path(endpoint).exists(), 'exact owned endpoint must be cleaned on normal close')
        restarted = start()
        try:
            readback('public-fixture-restart-readback')
        finally:
            stop(restarted)
        self.assertEqual(restarted.returncode, 0)
        self.assertFalse(Path(endpoint).exists())
        staged = list((self.root / 'exports').glob('*.sealed'))
        remote = list((self.root / 'onedrive').glob('*.sealed'))
        self.assertEqual(len(staged), 1)
        self.assertEqual(len(remote), 1)
        self.assertEqual(staged[0].read_bytes(), remote[0].read_bytes())
        self.assertEqual(staged[0].stat().st_mode & 0o777, 0o600)

    def test_socket_guards_and_close_preserve_an_unidentified_replacement(self):
        import socket
        from private_contact.runtime import private_server
        self.enabled_fixture()
        endpoint = Path(self.manifest['socket_file'])
        endpoint.touch(mode=0o600)
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)
        self.assertTrue(endpoint.is_file())
        endpoint.unlink()
        endpoint.symlink_to(self.path)
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(self.path), self.source)
        endpoint.unlink()
        replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            with private_server(None, str(endpoint)):
                endpoint.chmod(0o644)
                with self.assertRaisesRegex(Denied, '^configuration$'):
                    validate_manifest(str(self.path), self.source)
                endpoint.chmod(0o600)
                endpoint.parent.chmod(0o755)
                with self.assertRaisesRegex(Denied, '^configuration$'):
                    validate_manifest(str(self.path), self.source)
                endpoint.parent.chmod(0o700)
                endpoint.unlink()
                previous = os.umask(0o077)
                try:
                    replacement.bind(str(endpoint))
                finally:
                    os.umask(previous)
                endpoint.chmod(0o600)
                inode = endpoint.stat().st_ino
            self.assertTrue(endpoint.is_socket())
            self.assertEqual(endpoint.stat().st_ino, inode)
            validate_manifest(str(self.path), self.source)
        finally:
            replacement.close()
