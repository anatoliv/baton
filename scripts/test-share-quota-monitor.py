#!/usr/bin/env python3
"""Synthetic-only monitor checks: no server, token retrieval or outside notifier."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("share-quota-monitor.py")
spec = importlib.util.spec_from_file_location("quota_monitor", SCRIPT)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def test_transitions_are_quiet_until_warning_unknown_or_recovery(self):
        self.assertIsNone(monitor.transition(None, "ok", "ok"))
        self.assertIsNone(monitor.transition("warning", "warning", "still warning"))
        self.assertEqual(monitor.transition("ok", "warning", "warning")["event"], "alert")
        self.assertEqual(monitor.transition("warning", "unknown", "unknown")["level"], "unknown")
        self.assertEqual(monitor.transition("unknown", "ok", "ok")["event"], "recovered")

    def test_token_is_only_in_curl_stdin_and_no_shell(self):
        with tempfile.TemporaryDirectory() as folder:
            env = Path(folder) / "share.env"
            env.write_text("BATON_SHARE_ADMIN_TOKEN=" + "a" * 64 + "\n")
            env.chmod(0o600)
            def fake(argv, **kwargs):
                self.assertNotIn("a" * 64, " ".join(argv))
                self.assertFalse(kwargs.get("shell", False))
                self.assertNotIn("env", kwargs)
                self.assertIn("a" * 64, kwargs["input"])
                self.assertEqual(argv[argv.index("curl") + 1], "--disable")
                self.assertEqual(argv[argv.index("--noproxy") + 1], "*")
                self.assertIn("--config", argv)
                self.assertIn("-i", argv)
                return subprocess.CompletedProcess(argv, 0, '{"health":{"storedBytes":0,"quotaBytes":100}}')
            self.assertEqual(monitor.fetch_report(env, runner=fake)["health"]["quotaBytes"], 100)

    def test_insecure_or_injected_token_is_rejected_before_docker(self):
        with tempfile.TemporaryDirectory() as folder:
            env = Path(folder) / "share.env"
            env.write_text('BATON_SHARE_ADMIN_TOKEN=' + "a" * 32 + '\"\\nurl=evil\n')
            env.chmod(0o600)
            with patch.object(subprocess, "run") as runner:
                with self.assertRaises(ValueError): monitor.fetch_report(env, runner=runner)
                runner.assert_not_called()
            env.write_text("BATON_SHARE_ADMIN_TOKEN=" + "a" * 64 + "\n")
            env.chmod(0o644)
            with self.assertRaises(ValueError): monitor.fetch_report(env)

    def test_dry_run_has_no_side_effects(self):
        run = subprocess.run([sys.executable, str(SCRIPT), "--dry-run", "--report", "-"],
                             input='{"health":{"storedBytes":80,"quotaBytes":100}}', text=True, capture_output=True)
        self.assertEqual(run.returncode, 1)
        result = json.loads(run.stdout)
        self.assertTrue(result["dryRun"])
        self.assertEqual(result["event"]["level"], "warning")

    def test_activation_needs_existing_approved_notifier_even_when_healthy(self):
        with tempfile.TemporaryDirectory() as folder:
            run = subprocess.run([sys.executable, str(SCRIPT), "--activate", "--report", "-", "--state",
                                  folder + "/state.json", "--notify-command", folder + "/missing"],
                                 input='{"health":{"storedBytes":0,"quotaBytes":100}}', text=True, capture_output=True)
            self.assertEqual(run.returncode, 2)
            self.assertFalse((Path(folder) / "state.json").exists())

    def test_synthetic_warning_dedup_unknown_and_recovery_delivery(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            events = path / "events"
            hook = path / "notify"
            hook.write_text(f'#!{sys.executable}\nimport sys\nwith open({str(events)!r}, "a") as output: output.write(sys.stdin.read() + "\\n")\n')
            hook.chmod(0o700)
            state = path / "state.json"
            for used, expected in [(0, 0), (80, 1), (85, 1), (None, 2), (None, 2), (79, 0)]:
                report = {} if used is None else {"health": {"storedBytes": used, "quotaBytes": 100}}
                run = subprocess.run([sys.executable, str(SCRIPT), "--activate", "--report", "-", "--state", str(state),
                                      "--notify-command", str(hook)], input=json.dumps(report), text=True, capture_output=True)
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
            delivered = [json.loads(line) for line in events.read_text().splitlines()]
            self.assertEqual([event["level"] for event in delivered], ["warning", "unknown", "ok"])
            self.assertEqual(delivered[-1]["event"], "recovered")
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_notifier_failure_does_not_advance_state(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            hook = path / "notify"
            hook.write_text("#!/bin/sh\nexit 1\n")
            hook.chmod(0o700)
            run = subprocess.run([sys.executable, str(SCRIPT), "--activate", "--report", "-", "--state",
                                  str(path / "state.json"), "--notify-command", str(hook)],
                                 input='{"health":{"storedBytes":80,"quotaBytes":100}}', text=True, capture_output=True)
            self.assertEqual(run.returncode, 2)
            self.assertIsNone(json.loads((path / "state.json").read_text())["level"])

    def test_recovery_is_attempted_after_an_ambiguous_initial_warning_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            hook = path / "notify"
            hook.write_text("#!/usr/bin/env python3\nimport json,sys,pathlib\n"
                            "p=pathlib.Path(__file__).with_name('calls.json')\n"
                            "calls=json.loads(p.read_text()) if p.exists() else []\n"
                            "calls.append(json.load(sys.stdin)['level'])\n"
                            "p.write_text(json.dumps(calls))\n"
                            "sys.exit(1 if len(calls)==1 else 0)\n")
            hook.chmod(0o700)
            argv = [sys.executable, str(SCRIPT), "--activate", "--report", "-", "--state",
                    str(path / "state.json"), "--notify-command", str(hook)]
            first = subprocess.run(argv, input='{"health":{"storedBytes":80,"quotaBytes":100}}',
                                   text=True, capture_output=True)
            self.assertEqual(first.returncode, 2)
            second = subprocess.run(argv, input='{"health":{"storedBytes":0,"quotaBytes":100}}',
                                    text=True, capture_output=True)
            self.assertEqual(second.returncode, 0)
            self.assertEqual(json.loads((path / "calls.json").read_text()), ["warning", "ok"])


if __name__ == "__main__":
    unittest.main()
