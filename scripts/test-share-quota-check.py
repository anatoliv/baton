#!/usr/bin/env python3
"""Boundary and unavailable-measurement checks for the quota monitor."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).with_name("share-quota-check.py")
spec = importlib.util.spec_from_file_location("share_quota", SCRIPT)
quota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quota)


class QuotaTests(unittest.TestCase):
    def report(self, used, total=100):
        return {"health": {"storedBytes": used, "quotaBytes": total}}

    def test_below_boundary(self):
        self.assertEqual(quota.assess(self.report(79))[0], 0)

    def test_exact_boundary(self):
        self.assertEqual(quota.assess(self.report(80))[0], 1)

    def test_over_and_zero_usage(self):
        self.assertEqual(quota.assess(self.report(101))[0], 1)
        self.assertEqual(quota.assess(self.report(0))[0], 0)

    def test_default_twenty_gib_boundary(self):
        total = 21474836480
        boundary = total * 80 // 100
        self.assertEqual(quota.assess(self.report(boundary - 1, total))[0], 0)
        self.assertEqual(quota.assess(self.report(boundary, total))[0], 1)

    def test_bad_or_missing_measurement_is_unknown(self):
        for report in ({"error": "unavailable"}, {}, [], None, self.report(-1),
                       self.report(0, 0), self.report(True), self.report("80"),
                       {"health": {"storedBytes": 80}}):
            with self.subTest(report=report):
                self.assertEqual(quota.assess(report)[0], 2)

    def test_custom_threshold(self):
        self.assertEqual(quota.assess(self.report(79), 75)[0], 1)
        for threshold in (0, 101, True, 80.5):
            self.assertEqual(quota.assess(self.report(79), threshold)[0], 2)

    def test_cli_exit_codes_and_no_payload_output(self):
        for payload, expected in [('{"health":{"storedBytes":80,"quotaBytes":100},"private":"DO_NOT_PRINT"}', 1),
                                  ('{"health":{"storedBytes":0,"quotaBytes":100}}', 0),
                                  ('invalid JSON', 2)]:
            run = subprocess.run([sys.executable, str(SCRIPT)], input=payload,
                                 text=True, capture_output=True)
            self.assertEqual(run.returncode, expected)
            self.assertNotIn("DO_NOT_PRINT", run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
