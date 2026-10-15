"""Narrow staged worker/custody acceptance without Tonebox/web dependencies."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


class WorkerFeedbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = Path(__file__).with_name('test_feedback_integration.py')
        spec = importlib.util.spec_from_file_location('reserved_feedback_fixtures', fixture)
        cls.fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.fixtures)
        cls.fixtures.ConnectedFeedbackTests.setUpClass()
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='worker-feedback-', dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.case = self.fixtures.ConnectedFeedbackTests('test_actual_signed_receiver_unix_journal_restart_and_duplicate')
        self.case.root = Path(self.temporary.name).resolve()
        self.case.capture = self.fixtures.CapturedSMTP()
        self.case.authority = self.fixtures.FixtureAuthority()
        self.case.restart()
        service = self.case.service
        service.enroll('reserved-proof', 'sharer@recipient.invalid', 'contact-v1')
        service.verify('reserved-proof', self.case.capture.code())
        self.case.job = service.queue(review='reserved-review', installation='reserved-installation',
            case='reserved-case', operation='reserved-operation', revision=1,
            share='reserved-share', created=self.case.now + 1, notice={'instructions': 'RESERVED PRIVATE CASE TEXT'})
        service.dispatch()
        self.case.ses_id, self.case.grant = 'reserved-ses-2', self.case.capture.code()

    def test_actual_journal_worker_restart_and_duplicate_under_selected_crypto(self):
        raw = self.case.signed()
        self.assertEqual(self.case.api.handle('/feedback', raw), (200, {'accepted': True}))
        before = self.case.job_info()
        self.case.restart()
        self.assertEqual(self.case.job_info(), before)
        self.assertEqual(self.case.api.handle('/feedback', raw), (200, {'accepted': True}))
        self.assertEqual(self.case.job_info(), before)

    def test_retained_freshness_source_arn_and_configset_guards(self):
        foreign = self.case.signed(self.case.event(sourceArn=self.case.identity + '-foreign'))
        wrong_set = self.case.signed(self.case.event(tags={'ses:configuration-set': ['foreign']}))
        stale = self.case.signed(Timestamp=datetime.fromtimestamp(self.case.now - 901, timezone.utc).isoformat().replace('+00:00', 'Z'))
        for raw in (foreign, wrong_set, stale):
            self.assertEqual(self.case.api.handle('/feedback', raw), (200, {'accepted': False}))
        self.assertEqual(self.case.job_info()['state'], 'providerAccepted')

    def test_renderer_rejection_and_raw_uuid_namespace(self):
        raw = self.case.signed(self.case.event('Rendering Failure'))
        self.assertEqual(self.case.feedback.admit(raw)['event'], json.loads(raw)['MessageId'])
        self.assertEqual(self.case.api.handle('/feedback', raw), (200, {'accepted': True}))
        self.assertIn('rejected', self.case.job_info()['escalations'])

    def test_actual_manifest_default_off_creates_no_other_inputs_or_state(self):
        from private_contact.runtime import FIELDS, INPUTS, SOURCE_FILES, validate_manifest, build_runtime
        from private_contact import Denied
        import hashlib
        source = Path(sys.modules['private_contact'].__file__).resolve().parent.parent
        manifest = {field: None for field in FIELDS}
        manifest.update(version=1, enabled=False, enrollment_enabled=False, sending_enabled=False, qualified=False,
                        source_digests={name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in SOURCE_FILES},
                        inputs={name: None for name in INPUTS}, public_mounts=[],
                        backup={'retention_days': 30, 'destructive_expiry_enabled': False,
                                'remote_verified': False, 'held_cases_verified': False})
        path = self.case.root / 'manifest.json'
        path.write_text(json.dumps(manifest))
        path.chmod(0o600)
        admitted = validate_manifest(str(path), source)
        self.assertFalse(admitted['enabled'])
        with self.assertRaisesRegex(Denied, '^disabled$'):
            build_runtime(admitted)
        manifest['source_digests'][SOURCE_FILES[0]] = '0' * 64
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(path), source)

    def test_failed_journal_remains_retryable_under_worker_runtime(self):
        raw = self.case.signed()
        with patch.object(self.case.custody.journal, 'transact', side_effect=RuntimeError('RESERVED PRIVATE ERROR')):
            self.assertEqual(self.case.api.handle('/feedback', raw), (503, {'error': 'unavailable'}))
        self.assertEqual(self.case.api.handle('/feedback', raw), (200, {'accepted': True}))

    def test_enabled_manifest_requires_a_separate_feedback_socket_directory(self):
        from private_contact.runtime import FIELDS, INPUTS, SOURCE_FILES, validate_manifest
        from private_contact import Denied
        from importlib.metadata import version
        import hashlib
        source = Path(sys.modules['private_contact'].__file__).resolve().parent.parent
        for name in ('state', 'export', 'remote', 'public', 'inputs', 'operator-run', 'feedback-run'):
            (self.case.root / name).mkdir(mode=0o700)
        inputs = {}
        for name in INPUTS:
            path = self.case.root / 'inputs' / name
            path.write_bytes(b'RESERVED TEST INPUT ONLY')
            path.chmod(0o600)
            inputs[name] = str(path)
        manifest = {field: None for field in FIELDS}
        executable = Path(sys.executable).resolve()
        manifest.update(version=1, enabled=True, enrollment_enabled=False, sending_enabled=False, qualified=True,
            source_digests={name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in SOURCE_FILES},
            source_revision='0' * 40, deployment_card='TBX-0', operational_approval='RESERVED FIXTURE ONLY',
            state_root=str(self.case.root / 'state'), export_root=str(self.case.root / 'export'),
            onedrive_root=str(self.case.root / 'remote'), public_mounts=[str(self.case.root / 'public')],
            inputs=inputs, share_port=12345, runtime_executable=str(executable),
            runtime_digest=hashlib.sha256(executable.read_bytes()).hexdigest(), cryptography_version=version('cryptography'),
            socket_file=str(self.case.root / 'operator-run' / 'operator.sock'),
            feedback_socket_file=str(self.case.root / 'feedback-run' / 'feedback.sock'),
            contact_directory=str(self.case.root / 'state' / 'contact'),
            history_directory=str(self.case.root / 'state' / 'history'),
            authority_directory=str(self.case.root / 'state' / 'authority'),
            sns={field: None for field in ('certificate_url', 'fingerprint', 'topic', 'account', 'identity', 'configuration_set')},
            iam={field: None for field in ('principal_linkage_verified', 'recipient_amendment_verified',
                'current_policy_digest', 'candidate_policy_digest', 'candidate_policy_file', 'rollback_policy_file')},
            backup={'retention_days': 30, 'destructive_expiry_enabled': False,
                    'remote_verified': False, 'held_cases_verified': False})
        path = self.case.root / 'enabled-fixture.json'
        path.write_text(json.dumps(manifest))
        path.chmod(0o600)
        validate_manifest(str(path), source, binding_socket=True, binding_feedback=True)
        manifest['feedback_socket_file'] = str(self.case.root / 'operator-run' / 'feedback.sock')
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(path), source, binding_socket=True, binding_feedback=True)
        self.manifest_fixture = manifest, path, source

    def test_enabled_manifest_feedback_group_is_explicit_and_separate(self):
        from private_contact.runtime import validate_manifest
        from private_contact import Denied
        self.test_enabled_manifest_requires_a_separate_feedback_socket_directory()
        manifest, path, source = self.manifest_fixture
        manifest['feedback_socket_file'] = str(self.case.root / 'feedback-run' / 'feedback.sock')
        manifest['feedback_group_gid'] = 11037
        directory = self.case.root / 'feedback-run'
        os.chown(directory, -1, 11037)
        directory.chmod(0o710)
        path.write_text(json.dumps(manifest))
        validate_manifest(str(path), source, binding_socket=True, binding_feedback=True)
        for value in (True, 0, -1, '11037', 2147483648):
            manifest['feedback_group_gid'] = value
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(Denied, '^configuration$'):
                validate_manifest(str(path), source, binding_feedback=True)
        manifest['feedback_group_gid'] = 11037
        for name in ('state', 'inputs', 'operator-run'):
            # The separate group boundary cannot enclose or share private roots.
            manifest['feedback_socket_file'] = str(self.case.root / name / 'feedback.sock')
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(Denied, '^configuration$'):
                validate_manifest(str(path), source, binding_feedback=True)
        boundary = self.case.root / 'shared-boundary'
        boundary.mkdir(mode=0o710)
        os.chown(boundary, -1, 11037)
        state = boundary / 'private-state'
        state.mkdir(mode=0o700)
        manifest.update(state_root=str(state), feedback_socket_file=str(boundary / 'feedback.sock'),
                        contact_directory=str(state / 'contact'), history_directory=str(state / 'history'),
                        authority_directory=str(state / 'authority'))
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(Denied, '^configuration$'):
            validate_manifest(str(path), source, binding_feedback=True)

    def test_feedback_group_binding_keeps_operator_policy_and_owned_inode_cleanup(self):
        from private_contact.feedback_ingress import feedback_server, feedback_socket
        from private_contact.runtime import protected_socket
        from private_contact import Denied
        import socket
        directory = self.case.root / 'group-feedback'
        directory.mkdir(mode=0o710)
        os.chown(directory, -1, 11037)
        endpoint = directory / 'feedback.sock'
        with self.assertRaisesRegex(Denied, '^configuration$'):
            protected_socket(str(endpoint), binding=True)
        with patch('os.getgroups', return_value=[]), patch('os.getegid', return_value=11036):
            with self.assertRaisesRegex(Denied, '^configuration$'):
                feedback_server(self.case.api, str(endpoint), group_gid=11037)
        self.assertFalse(endpoint.exists())
        with feedback_server(self.case.api, str(endpoint), group_gid=11037) as server:
            self.assertEqual(endpoint.stat().st_gid, 11037)
            self.assertEqual(endpoint.stat().st_mode & 0o777, 0o660)
            self.assertEqual(feedback_socket(str(endpoint), group_gid=11037), endpoint)
            with self.assertRaisesRegex(Denied, '^configuration$'):
                protected_socket(str(endpoint))
            with self.assertRaisesRegex(Denied, '^configuration$'):
                feedback_server(self.case.api, str(endpoint), group_gid=11037)
            alias = self.case.root / 'socket-alias'
            alias.symlink_to(endpoint)
            with self.assertRaisesRegex(Denied, '^configuration$'):
                feedback_socket(str(alias), group_gid=11037)
        self.assertFalse(endpoint.exists())
        server = feedback_server(self.case.api, str(endpoint), group_gid=11037)
        endpoint.unlink()
        replacement = socket.socket(socket.AF_UNIX)
        try:
            replacement.bind(str(endpoint))
            os.chown(endpoint, -1, 11037)
            endpoint.chmod(0o660)
            server.server_close()
            self.assertTrue(endpoint.exists(), 'changed inode must be retained')
        finally:
            replacement.close()
            endpoint.unlink()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--staged-runtime', required=True)
    parser.add_argument('--test', action='append', default=[])
    arguments = parser.parse_args()
    sys.path.insert(0, str(Path(arguments.staged_runtime).resolve()))
    unittest.main(argv=[sys.argv[0], *arguments.test], verbosity=2)
