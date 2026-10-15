"""Real Linux UID isolation acceptance; synthetic state in an owned tmpfs only.

Run in a cached read-only, network-none container as root. Child roles drop to
fixture UIDs before importing sources. No host accounts, credentials or network.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import unittest

OWNER, CLIENT, GROUP = 11036, 1000, 11037


def sources(runtime, tonebox):
    sys.path.insert(0, runtime)
    sys.path.insert(1, str(Path(tonebox) / 'backend'))


def drop(uid, groups):
    os.setgroups(groups)
    os.setgid(uid)
    os.setuid(uid)


def worker(root, grouped):
    drop(OWNER, [GROUP])
    fixture = Path(__file__).with_name('test_feedback_integration.py')
    spec = importlib.util.spec_from_file_location('reserved_fixtures', fixture)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ConnectedFeedbackTests.setUpClass()
    case = module.ConnectedFeedbackTests('test_actual_signed_receiver_unix_journal_restart_and_duplicate')
    case.root = root / 'private'
    case.capture, case.authority = module.CapturedSMTP(), module.FixtureAuthority()
    case.restart()
    case.service.enroll('reserved-proof', 'sharer@recipient.invalid', 'contact-v1')
    case.service.verify('reserved-proof', case.capture.code())
    case.job = case.service.queue(review='reserved-review', installation='reserved-installation',
        case='reserved-case', operation='reserved-operation', revision=1, share='reserved-share',
        created=case.now + 1, notice={'instructions': 'RESERVED PRIVATE CASE TEXT'})
    case.service.dispatch()
    case.ses_id = 'reserved-ses-2'
    (root / 'public' / 'notification.json').write_bytes(case.signed())
    from private_contact.feedback_ingress import feedback_server
    from private_contact.runtime import private_server
    import threading
    endpoint = root / 'feedback' / 'feedback.sock'
    server = (feedback_server(case.api, str(endpoint), group_gid=GROUP) if grouped
              else feedback_server(case.api, str(endpoint)))
    operator = private_server(case.api, str(root / 'operator' / 'operator.sock'))
    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.01})
    thread.start()
    print('ready', flush=True)
    try:
        if sys.stdin.readline().strip() != 'stop':
            raise AssertionError('stop missing')
        if grouped:
            assert case.job_info()['state'] == 'mailServerDelivered'
    finally:
        server.shutdown()
        thread.join(3)
        server.server_close()
        operator.server_close()
        assert not thread.is_alive()
        assert not endpoint.exists()
        assert not (root / 'operator' / 'operator.sock').exists()
    print('closed', flush=True)


def client(root, action):
    drop(CLIENT, [] if action == 'unauthorized' else [GROUP])
    from app.services.baton_ses_relay import _socket_path, forward, RelayUnavailable
    endpoint = str(root / 'feedback' / 'feedback.sock')
    raw = (root / 'public' / 'notification.json').read_bytes()
    for target in (root / 'private', root / 'operator', root / 'keys'):
        try:
            list(target.iterdir())
        except PermissionError:
            pass
        else:
            raise AssertionError('private namespace exposed')
    if action == 'baseline':
        try:
            _socket_path(endpoint)
        except RelayUnavailable:
            pass
        else:
            raise AssertionError('different owner admitted by default')
        sock = socket.socket(socket.AF_UNIX)
        try:
            try:
                sock.connect(endpoint)
            except PermissionError:
                pass
            else:
                raise AssertionError('kernel granted old owner-only socket')
        finally:
            sock.close()
    elif action == 'accepted':
        forward(raw, endpoint, owner_uid=OWNER, group_gid=GROUP)
        forward(raw, endpoint, owner_uid=OWNER, group_gid=GROUP)  # Durable duplicate.
        # No operator traversal or private-state access is granted by this group.
        for target in (root / 'private', root / 'operator', root / 'keys'):
            try:
                list(target.iterdir())
            except PermissionError:
                pass
            else:
                raise AssertionError('private namespace exposed')
        directory = root / 'feedback'
        for operation in (lambda: list(directory.iterdir()),
                          lambda: (directory / 'new.sock').touch(),
                          lambda: Path(endpoint).unlink()):
            try:
                operation()
            except PermissionError:
                pass
            else:
                raise AssertionError('peer can enumerate or mutate feedback directory')
        import httpx
        with httpx.Client(transport=httpx.HTTPTransport(uds=endpoint), timeout=2, trust_env=False) as transport:
            assert transport.post('http://localhost/command', content=b'{}').status_code == 404
    else:
        uid, gid = OWNER, GROUP
        if action == 'wrong-owner':
            uid += 1
        if action == 'wrong-group':
            gid += 1
        try:
            _socket_path(endpoint, owner_uid=uid, group_gid=gid)
        except RelayUnavailable as error:
            assert str(error) == 'unavailable' and error.__context__ is None
        else:
            raise AssertionError('unsafe identity/mode/member admitted')
        if action == 'unauthorized':
            sock = socket.socket(socket.AF_UNIX)
            try:
                try:
                    sock.connect(endpoint)
                except PermissionError:
                    pass
                else:
                    raise AssertionError('kernel admitted nonmember')
            finally:
                sock.close()
    print('passed', flush=True)


class LinuxIsolationTests(unittest.TestCase):
    def scenario(self, grouped):
        self.assertEqual(os.geteuid(), 0, 'run only in an isolated Linux container')
        self.assertEqual(sys.platform, 'linux')
        with tempfile.TemporaryDirectory(prefix='feedback-isolation-', dir='/tmp') as temporary:
            root = Path(temporary)
            root.chmod(0o755)
            for name, mode in (('private', 0o700), ('public', 0o755), ('operator', 0o700), ('keys', 0o700),
                               ('feedback', 0o710 if grouped else 0o700)):
                directory = root / name
                directory.mkdir(mode=mode)
                os.chown(directory, OWNER, GROUP if name == 'feedback' else OWNER)
            command = [sys.executable, '-I', str(Path(__file__).resolve()),
                '--staged-runtime', RUNTIME, '--tonebox-source', TONEBOX,
                '--root', str(root)]
            process = subprocess.Popen(command + ['--role', 'worker', '--action', 'group' if grouped else 'baseline'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={}, text=True)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 8)[0], 'worker readiness timeout')
                self.assertEqual(process.stdout.readline().strip(), 'ready')
                actions = ('accepted', 'wrong-owner', 'wrong-group', 'unauthorized') if grouped else ('baseline',)
                for action in actions:
                    with self.subTest(action=action):
                        result = subprocess.run(command + ['--role', 'client', '--action', action],
                            capture_output=True, env={}, text=True, timeout=5)
                        self.assertEqual(result.returncode, 0, 'bounded client role failed')
                        self.assertEqual(result.stdout.strip(), 'passed')
                        self.assertEqual(result.stderr, '')
                if grouped:
                    endpoint = root / 'feedback' / 'feedback.sock'
                    for target in (endpoint, endpoint.parent):
                        original = target.stat()
                        for uid, gid in ((OWNER + 1, GROUP), (OWNER, GROUP + 1)):
                            with self.subTest(inode=target.name, uid=uid, gid=gid):
                                os.chown(target, uid, gid)
                                result = subprocess.run(command + ['--role', 'client', '--action', 'mode'],
                                    capture_output=True, env={}, text=True, timeout=5)
                                self.assertEqual(result.returncode, 0, 'unsafe inode identity admitted')
                                os.chown(target, original.st_uid, original.st_gid)
                    for mode in (0o600, 0o666):
                        with self.subTest(socket_mode=mode):
                            endpoint.chmod(mode)
                            result = subprocess.run(command + ['--role', 'client', '--action', 'mode'],
                                capture_output=True, env={}, text=True, timeout=5)
                            self.assertEqual(result.returncode, 0, 'unsafe socket mode admitted')
                    endpoint.chmod(0o660)
                    directory = root / 'feedback'
                    for mode in (0o700, 0o730, 0o711):
                        with self.subTest(directory_mode=mode):
                            directory.chmod(mode)
                            result = subprocess.run(command + ['--role', 'client', '--action', 'mode'],
                                capture_output=True, env={}, text=True, timeout=5)
                            self.assertEqual(result.returncode, 0, 'unsafe directory mode admitted')
                    directory.chmod(0o710)
            finally:
                if process.poll() is None:
                    process.stdin.write('stop\n')
                    process.stdin.flush()
                try:
                    output, errors = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        output, errors = process.communicate(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        output, errors = process.communicate(timeout=2)
                    self.fail('worker failed bounded owned shutdown')
                self.assertEqual(process.returncode, 0, 'bounded worker role failed')
                self.assertEqual(output.strip(), 'closed')
                self.assertEqual(errors, '')

    def test_existing_default_refuses_different_uid_in_code_and_kernel(self):
        self.scenario(False)

    def test_designated_group_connects_different_uid_and_refuses_unsafe_access(self):
        self.scenario(True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--staged-runtime', required=True)
    parser.add_argument('--tonebox-source', required=True)
    parser.add_argument('--test', action='append', default=[])
    parser.add_argument('--role', choices=('worker', 'client'))
    parser.add_argument('--action')
    parser.add_argument('--root')
    arguments = parser.parse_args()
    RUNTIME, TONEBOX = arguments.staged_runtime, arguments.tonebox_source
    sources(RUNTIME, TONEBOX)
    if arguments.role == 'worker':
        worker(Path(arguments.root), arguments.action == 'group')
    elif arguments.role == 'client':
        client(Path(arguments.root), arguments.action)
    else:
        unittest.main(argv=[sys.argv[0], *arguments.test], verbosity=2)
