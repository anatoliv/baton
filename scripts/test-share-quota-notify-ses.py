#!/usr/bin/env python3
"""Offline SES notifier acceptance and privacy checks; no outside mail."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import smtplib
import ssl
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).with_name("share-quota-notify-ses.py")
spec = importlib.util.spec_from_file_location("quota_ses", SCRIPT)
notifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notifier)


def event(level="warning"):
    messages = {"warning": "WARNING share quota: 80 of 100 bytes (80.0%); threshold 80%",
                "unknown": "UNKNOWN share quota: admin report unavailable or missing health",
                "ok": "OK share quota: 79 of 100 bytes (79.0%); threshold 80%"}
    return {"service": "baton-share", "event": "recovered" if level == "ok" else "alert",
            "previous": "unknown" if level == "ok" else "ok", "level": level,
            "message": messages[level]}


class NotifierTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.config = Path(self.folder.name) / "private.json"
        self.config.write_text(json.dumps({"username": "fixture-user", "password": "fixture-password"}))
        self.config.chmod(0o600)

    def invoke(self, payload, client=None, extra=()):
        output, errors = io.StringIO(), io.StringIO()
        client = client or Mock()
        client.send_message.return_value = {}
        with (patch.object(sys, "argv", [str(SCRIPT), "--config", str(self.config), *extra]),
              patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(payload))),
              patch.object(notifier.smtplib, "SMTP_SSL", return_value=client) as factory,
              contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors)):
            code = notifier.main()
        return code, output.getvalue(), errors.getvalue(), factory

    def test_warning_unknown_recovery_send_only_approved_route_and_aggregate(self):
        for level in ("warning", "unknown", "ok"):
            with self.subTest(level=level):
                client = Mock()
                code, output, errors, factory = self.invoke(json.dumps(event(level)).encode(), client)
                self.assertEqual(code, 0, errors)
                self.assertIn("inbox receipt unverified", output)
                args, options = factory.call_args
                self.assertEqual(args, ("email-smtp.us-east-1.amazonaws.com", 465))
                self.assertEqual(options["context"].verify_mode, ssl.CERT_REQUIRED)
                self.assertTrue(options["context"].check_hostname)
                self.assertLessEqual(options["timeout"], 4)
                client.login.assert_called_once_with("fixture-user", "fixture-password")
                mail = client.send_message.call_args.args[0]
                self.assertEqual(mail["To"], "notify@batonmusic.app")
                self.assertEqual(mail["Auto-Submitted"], "auto-generated")
                self.assertIn(event(level)["message"], mail.get_content())
                self.assertEqual(client.send_message.call_args.kwargs,
                                 {"from_addr": "notify@batonmusic.app", "to_addrs": ["notify@batonmusic.app"]})
                self.assertNotIn("fixture-password", mail.as_string() + output + errors)
                client.close.assert_called_once()
                client.quit.assert_not_called()

    def test_arbitrary_text_recipient_and_private_fields_rejected_before_network(self):
        variants = []
        for changes in ({"message": "Bearer private-token 192.0.2.1"},
                        {"to": "other@example.test"}, {"shareID": "private-share"},
                        {"service": "other-service"}, {"level": "ok"},
                        {"event": "recovered"}, {"message": "WARNING share quota: 80 of 100 bytes (80.0%); threshold 80%\nsecret"}):
            variants.append({**event(), **changes})
        for payload in variants:
            with self.subTest(payload=payload):
                code, output, errors, factory = self.invoke(json.dumps(payload).encode())
                self.assertEqual(code, 1)
                factory.assert_not_called()
                self.assertEqual(output, "")
                self.assertNotIn("private-token", errors)

    def test_bad_and_oversized_json_rejected_without_network(self):
        for raw in (b"{", b"[]", b"\xff", b" " * 4097):
            code, _, _, factory = self.invoke(raw)
            self.assertEqual(code, 1)
            factory.assert_not_called()

    def test_missing_private_config_is_safe_failure(self):
        self.config.unlink()
        code, _, errors, factory = self.invoke(json.dumps(event()).encode())
        self.assertEqual(code, 1)
        self.assertNotIn(str(self.config), errors)
        factory.assert_not_called()

    def test_world_readable_config_rejected_before_network(self):
        self.config.chmod(0o644)
        code, _, _, factory = self.invoke(json.dumps(event()).encode())
        self.assertEqual(code, 1)
        factory.assert_not_called()

    def test_symlink_relative_path_and_nonregular_file_rejected(self):
        link = Path(self.folder.name) / "link"
        link.symlink_to(self.config)
        for path in (link, Path("relative.json"), Path(self.folder.name)):
            with self.subTest(path=path):
                with self.assertRaises((OSError, ValueError)):
                    notifier.load_private_config(path)

    def test_config_other_owner_rejected(self):
        with patch.object(notifier.os, "geteuid", return_value=self.config.stat().st_uid + 1):
            with self.assertRaises(ValueError):
                notifier.load_private_config(self.config)

    def test_config_extra_keys_bad_values_and_oversize_rejected(self):
        for config in ({"username": "u", "password": "p", "host": "evil.test"},
                       {"username": "u", "password": "p\nsecret"},
                       {"username": "u", "password": 42},
                       {"username": "u", "password": ""},
                       {"username": "u", "password": "p" * 5000}):
            self.config.write_text(json.dumps(config))
            with self.assertRaises(ValueError):
                notifier.load_private_config(self.config)

    def test_check_config_never_reads_stdin_or_contacts_provider(self):
        code, output, _, factory = self.invoke(b"invalid", extra=("--check-config",))
        self.assertEqual(code, 0)
        self.assertIn("send permission unverified", output)
        factory.assert_not_called()

    def test_auth_and_data_errors_hide_provider_details_and_fail_for_retry(self):
        for method, error in (("login", smtplib.SMTPAuthenticationError(535, b"fixture-password")),
                              ("send_message", smtplib.SMTPDataError(554, b"private-server-info"))):
            client = Mock()
            getattr(client, method).side_effect = error
            code, output, errors, _ = self.invoke(json.dumps(event()).encode(), client)
            self.assertEqual(code, 1)
            self.assertEqual(output, "")
            self.assertNotIn("fixture-password", errors)
            self.assertNotIn("private-server-info", errors)
            client.close.assert_called_once()

    def test_refused_recipient_is_failure(self):
        client = Mock()
        client.send_message.return_value = {"notify@batonmusic.app": (550, b"refused")}
        with self.assertRaises(ValueError):
            notifier.send(notifier.build_message(event()), {"username": "u", "password": "p"},
                          smtp_factory=Mock(return_value=client))
        client.close.assert_called_once()

    def test_close_error_after_data_acceptance_does_not_retry_accepted_mail(self):
        client = Mock()
        client.close.side_effect = OSError("private-server-info")
        code, output, errors, _ = self.invoke(json.dumps(event()).encode(), client)
        self.assertEqual(code, 0)
        self.assertIn("SES accepted", output)
        self.assertEqual(errors, "")

    def test_monitor_exec_hook_delivers_only_warning_unknown_and_recovery(self):
        folder = Path(self.folder.name)
        delivered = folder / "delivered.jsonl"
        hook = folder / "notify"
        hook.write_text(f'''#!{sys.executable}
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("notifier", {str(SCRIPT)!r})
notifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notifier)
class OfflineSMTP:
    def __init__(self, *args, **kwargs): pass
    def login(self, *args): pass
    def close(self): pass
    def send_message(self, message, **kwargs):
        with open({str(delivered)!r}, "a") as output:
            output.write(json.dumps({{"to": message["To"], "subject": message["Subject"],
                                     "body": message.get_content()}}) + "\\n")
        return {{}}
notifier.smtplib.SMTP_SSL = OfflineSMTP
sys.argv = [sys.argv[0], "--config", {str(self.config)!r}]
raise SystemExit(notifier.main())
''')
        hook.chmod(0o700)
        for used, expected in ((0, 0), (80, 1), (85, 1), (None, 2), (None, 2), (79, 0)):
            report = {} if used is None else {"health": {"storedBytes": used, "quotaBytes": 100}}
            run = subprocess.run([sys.executable, str(SCRIPT.with_name("share-quota-monitor.py")),
                                  "--activate", "--report", "-", "--state", str(folder / "state.json"),
                                  "--notify-command", str(hook)], input=json.dumps(report),
                                 text=True, capture_output=True, timeout=5)
            self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
        receipts = [json.loads(line) for line in delivered.read_text().splitlines()]
        self.assertEqual([item["subject"] for item in receipts],
                         ["Baton share quota: warning", "Baton share quota: unknown", "Baton share quota: ok"])
        self.assertTrue(all(item["to"] == "notify@batonmusic.app" for item in receipts))
        self.assertNotIn("fixture-password", delivered.read_text())


if __name__ == "__main__":
    unittest.main()
