#!/usr/bin/env python3
"""Safety boundaries for disposable sharing fixture setup; no live app/services."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("probe-share-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FixtureSafety(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sharing-setup-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = fixture.clean_environment(self.root)

    def test_owner_provider_proxy_docker_git_environment_not_inherited(self):
        with patch.dict(os.environ, {"BATON_SHARE_PUBLIC_BASE": "https://owner.example", "HTTP_PROXY": "secret",
                                     "DOCKER_HOST": "tcp://production:2376", "CRASH_REPORTING_DSN": "secret",
                                     "GIT_CONFIG_GLOBAL": "/owner/private"}):
            root = self.root / "other"
            root.mkdir()
            env = fixture.clean_environment(root)
        self.assertNotIn("BATON_SHARE_PUBLIC_BASE", env)
        self.assertNotIn("HTTP_PROXY", env)
        self.assertNotIn("CRASH_REPORTING_DSN", env)
        self.assertEqual(env["DOCKER_HOST"], "unix:///var/run/docker.sock")
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(Path(env["HOME"]), root / "home")

    def test_build_username_comes_from_os_metadata_without_restoring_account_home(self):
        root = self.root / "clean-build"
        root.mkdir()
        with patch.dict(os.environ, {"USER": "inherited-user", "LOGNAME": "inherited-login", "HOME": "/owner/private", "HTTP_PROXY": "secret"}):
            with patch.object(fixture.pwd, "getpwuid") as account:
                account.return_value.pw_name = "fixture-os-account"
                account.return_value.pw_dir = "/os-account/private-home"
                env = fixture.clean_environment(root)
                account.assert_called_once_with(os.getuid())
        self.assertEqual(env["USER"], "fixture-os-account")
        self.assertEqual(env["LOGNAME"], "fixture-os-account")
        self.assertEqual(Path(env["HOME"]), root / "home")
        self.assertNotIn("HTTP_PROXY", env)
        self.assertNotIn("/os-account/private-home", env.values())

    def test_source_build_uses_only_owned_unsigned_override_and_removes_it(self):
        calls = []
        def run(argv, env, payload=None, timeout=60):
            calls.append((argv, env))
            if Path(argv[0]).name == "probe-build.sh":
                config = Path(env["XCODE_XCCONFIG_FILE"])
                self.assertEqual(config.parent, self.root)
                self.assertEqual(config.read_text(), "CODE_SIGNING_ALLOWED = NO\nCODE_SIGNING_REQUIRED = NO\n")
                self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                self.assertEqual(env["HOME"], self.env["HOME"])
            return b""
        with patch.object(fixture, "command", side_effect=run), patch.object(fixture, "safe_export"):
            app = fixture.build_app(self.root, self.env)
        self.assertEqual(app, self.root / "build/dd-worktree/Build/Products/Debug/Baton.app")
        self.assertNotIn("XCODE_XCCONFIG_FILE", self.env)
        self.assertFalse((self.root / "unsigned-debug-build.xcconfig").exists())
        self.assertEqual(len(calls), 5)

    def test_native_home_comes_only_from_os_metadata(self):
        with patch.dict(os.environ, {"HOME": "/owner/inherited", "HTTP_PROXY": "secret"}):
            with patch.object(fixture.pwd, "getpwuid") as user:
                user.return_value.pw_dir = "/os-account/home"
                runtime = fixture.native_environment(self.env, "http://127.0.0.1:4602")
        self.assertEqual(runtime["HOME"], "/os-account/home")
        self.assertNotIn("HTTP_PROXY", runtime)
        self.assertEqual(runtime["baton.share.baseURL"], "http://127.0.0.1:4602")
        self.assertEqual(Path(self.env["HOME"]), self.root / "home")

    def test_redirect_and_public_requests_refused_before_network(self):
        with patch.object(fixture.OPENER, "open") as network:
            for url in ("https://127.0.0.1:4", "http://localhost:4", "http://owner.example:4", "http://127.0.0.1"):
                with self.subTest(url=url), self.assertRaises(fixture.FixtureFailure):
                    fixture.request(url)
            network.assert_not_called()
        with self.assertRaises(fixture.FixtureFailure):
            fixture.NoRedirect().redirect_request(None, None, 302, "", {}, "http://owner.example")

    def archive(self, name, kind=tarfile.REGTYPE):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.size = 1 if kind == tarfile.REGTYPE else 0
            member.linkname = "/owner/private"
            archive.addfile(member, io.BytesIO(b"x") if member.size else None)
        return data.getvalue()

    def test_source_export_refuses_traversal_and_links(self):
        for name, kind in (("../owner", tarfile.REGTYPE), ("/owner", tarfile.REGTYPE),
                           ("link", tarfile.SYMTYPE), ("hard", tarfile.LNKTYPE)):
            with self.subTest(name=name), self.assertRaises(fixture.FixtureFailure):
                fixture.safe_export(self.archive(name, kind), self.root)

    def test_source_export_drops_private_crash_config(self):
        fixture.safe_export(self.archive("app/Config/Crashbox.local.xcconfig"), self.root)
        self.assertFalse((self.root / "app/Config/Crashbox.local.xcconfig").exists())

    def test_service_wildcard_and_extra_listener_refused(self):
        for rows in ("*:4602", "127.0.0.1:4602\n127.0.0.1:4603"):
            text = "COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME\n" + "\n".join("app 7 u 1 TCP a 0 TCP " + row + " (LISTEN)" for row in rows.splitlines())
            with patch.object(fixture, "command", return_value=text.encode()), self.assertRaises(fixture.FixtureFailure):
                fixture.verify_listener(7, 4602, self.env)

    def test_keychain_cleanup_drains_only_generated_service_and_proves_absence(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        results = [subprocess.CompletedProcess([], code, b'private attributes', b'private diagnostics')
                   for code in (0, 0, 44)]
        with patch.object(fixture.subprocess, "run", side_effect=results) as call:
            supervisor.keychain("remove")
        self.assertEqual(call.call_count, 3)
        for invocation in call.call_args_list:
            self.assertEqual(invocation.args[0], ["/usr/bin/security", "delete-generic-password", "-s",
                                                 "io.tonebox.secrets.probe." + supervisor.suite])
            self.assertEqual(invocation.kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(invocation.kwargs['stdout'], subprocess.PIPE)
            self.assertEqual(invocation.kwargs['stderr'], subprocess.PIPE)
            self.assertEqual(invocation.kwargs['timeout'], 5)
            self.assertEqual(invocation.kwargs['env']['HOME'], fixture.pwd.getpwuid(os.getuid()).pw_dir)
            self.assertNotIn('HTTP_PROXY', invocation.kwargs['env'])
        self.assertRegex(supervisor.suite, r"^probe-sharing-[a-f0-9]{24}$")

    def test_already_absent_keychain_is_idempotent_and_does_not_read_or_change_acl(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        with patch.object(fixture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 44)) as call:
            supervisor.keychain('remove')
            supervisor.keychain('remove')
        self.assertEqual(call.call_count, 2)
        self.assertTrue(all(c.args[0][1] == 'delete-generic-password' for c in call.call_args_list))

    def test_keychain_rejects_wrong_operation_and_any_other_suite_before_command(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        with patch.object(fixture.subprocess, 'run') as call:
            with self.assertRaises(fixture.FixtureFailure):
                supervisor.keychain('find')
            for suite in ['io.tonebox.secrets', 'probe-sharing-' + 'b' * 24,
                          'probe-sharing-' + 'g' * 24, supervisor.suite + '\n', 'probe-sharing-']:
                supervisor.suite = suite
                with self.subTest(suite=suite), self.assertRaises(fixture.FixtureFailure):
                    supervisor.keychain('remove')
            call.assert_not_called()

    def test_keychain_error_and_timeout_never_expose_item_attributes(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        secret = 'private item attributes and password'
        for outcome in [subprocess.CompletedProcess([], 1, secret.encode(), secret.encode()),
                        subprocess.TimeoutExpired(secret, 5, output=secret, stderr=secret)]:
            kwargs = {'side_effect': outcome} if isinstance(outcome, Exception) else {'return_value': outcome}
            with patch.object(fixture.subprocess, 'run', **kwargs), self.assertRaises(fixture.FixtureFailure) as error:
                supervisor.keychain('remove')
            self.assertNotIn(secret, str(error.exception))
            self.assertIn('output withheld', str(error.exception))

    def test_keychain_loop_is_bounded_and_success_requires_absence(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        with patch.object(fixture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as call:
            with self.assertRaisesRegex(fixture.FixtureFailure, 'did not establish absence'):
                supervisor.keychain('remove')
        self.assertEqual(call.call_count, 32)

    def test_keychain_total_deadline_is_bounded(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        with patch.object(fixture.time, 'monotonic', side_effect=[0, 14, 16]), \
                patch.object(fixture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as call:
            with self.assertRaisesRegex(fixture.FixtureFailure, 'timed out'):
                supervisor.keychain('remove')
        call.assert_called_once()
        self.assertEqual(call.call_args.kwargs['timeout'], 1)

    def test_keychain_failure_is_recorded_without_stopping_other_cleanup(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        supervisor.keychain_attempted = True
        supervisor.defaults_created = True
        with patch.object(fixture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                patch.object(fixture, 'command') as command, patch('sys.stderr', new=io.StringIO()):
            self.assertEqual(supervisor.cleanup(), ['own probe Keychain items'])
        command.assert_called_once()
        self.assertEqual(command.call_args.args[0], ['defaults', 'delete', supervisor.suite])
        self.assertEqual(json.loads((self.root / 'cleanup.json').read_text()),
                         {'failures': ['own probe Keychain items'], 'childrenStopped': True})

    def test_keychain_successful_cleanup_records_no_failure(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        supervisor.keychain_attempted = True
        with patch.object(fixture.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0),
                                                               subprocess.CompletedProcess([], 44)]):
            self.assertEqual(supervisor.cleanup(), [])
        self.assertEqual(json.loads((self.root / 'cleanup.json').read_text())['failures'], [])

    def test_cleanup_uses_exact_owned_container_id_and_suite(self):
        supervisor = fixture.Supervisor(self.root, self.env)
        supervisor.container_id = "f" * 64
        supervisor.defaults_created = True
        with patch.object(fixture, "command") as call:
            supervisor.cleanup()
        self.assertEqual(call.call_args_list[0].args[0], ["docker", "rm", "-f", "f" * 64])
        self.assertEqual(call.call_args_list[1].args[0], ["defaults", "delete", supervisor.suite])

    def test_interrupt_stops_own_command_process_group(self):
        process = unittest.mock.Mock(pid=12345)
        process.communicate.side_effect = KeyboardInterrupt
        with patch.object(fixture.subprocess, "Popen", return_value=process), patch.object(fixture.os, "killpg") as kill:
            with self.assertRaises(KeyboardInterrupt):
                fixture.command(["build"], self.env)
        kill.assert_called_once_with(12345, fixture.signal.SIGTERM)
        process.wait.assert_called_once()



if __name__ == "__main__":
    unittest.main(verbosity=2)
