#!/usr/bin/env python3
"""Safety boundaries for the attach-only song-sharing probe; no app or network."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("probe_share", Path(__file__).with_name("probe-share-e2e.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class AttachSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="probe-share-safety-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for name in ("support", "data"):
            (self.root / name).mkdir()
        self.config = {"suite": "probe-sharing-test", "supportDirectory": str(self.root / "support"),
                       "dataDirectory": str(self.root / "data"), "shareBase": "http://127.0.0.1:4602",
                       "navidromeBase": "http://127.0.0.1:4601", "query": "Synthetic Tone"}

    def test_literal_loopback_origins(self):
        for url in ("http://127.0.0.1:4602", "http://[::1]:4602"):
            self.assertEqual(probe.loopback_url(url), url)

    def test_refuses_public_dns_credentials_and_ambiguous_bases(self):
        for url in ("https://batonmusic.app", "http://localhost:4602", "http://127.0.0.1", "http://user:secret@127.0.0.1:4602",
                    "http://127.0.0.1:4602?token=test", "http://127.0.0.1:4602/s/test", "http://127.0.0.1:4602#key"):
            with self.subTest(url=url), self.assertRaises(probe.ProbeFailure):
                probe.loopback_url(url)

    def test_refuses_owner_suite(self):
        self.config["suite"] = "io.tonebox.baton"
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_config(self.config)

    def test_refuses_owner_storage_through_symlink(self):
        link = self.root / "owner"
        link.symlink_to(Path.home(), target_is_directory=True)
        with self.assertRaises(probe.ProbeFailure):
            probe.temporary_path(link)

    def test_private_json_mode(self):
        path = self.root / "fixture.json"
        path.write_text("{}")
        path.chmod(0o644)
        with self.assertRaises(probe.ProbeFailure):
            probe.private_json(path)
        path.chmod(0o600)
        self.assertEqual(probe.private_json(path), {})

    def test_invalid_json_does_not_echo_contents(self):
        path = self.root / "fixture.json"
        path.write_text('{"secret":"private-fixture", BROKEN')
        path.chmod(0o600)
        with self.assertRaises(probe.ProbeFailure) as result:
            probe.private_json(path)
        self.assertNotIn("private-fixture", str(result.exception))

    def test_optional_credentials_must_be_scoped(self):
        credential = self.root / "secret.json"
        probe.save_private(credential, {"secret": "A" * 43})
        self.config["sharerCredentialFile"] = str(credential)
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_config(self.config)

    def fake_attach(self, consent=True, suite="probe-sharing-test", navidrome="http://127.0.0.1:4601"):
        support = self.root / "support"
        probe.save_private(support / "mcp.json", {"app": {"bundleId": "io.tonebox.baton"}, "pid": 12345,
                            "url": "http://127.0.0.1:8788/mcp", "token": "A" * 43})
        executable = self.root / "Debug/Baton.app/Contents/MacOS/Baton"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.touch()
        command = f'{executable} -baton.defaultsSuite {suite} -baton.supportDirectory {support}'
        prefs = {"tonebox.navidrome.servers": json.dumps([{"urlString": navidrome}]).encode(), "baton.share.disclosureSeen": consent}
        return [SimpleNamespace(returncode=0, stdout=command),
                SimpleNamespace(returncode=0, stdout=command + " baton.share.baseURL=http://127.0.0.1:4602"),
                SimpleNamespace(returncode=0, stdout=plistlib.dumps(prefs))]

    def test_wrong_live_suite_is_refused(self):
        outputs = self.fake_attach(suite="probe-another-instance")
        with patch.object(probe.subprocess, "run", side_effect=outputs), self.assertRaises(probe.ProbeFailure):
            probe.attach(probe.validate_config(self.config))

    def test_missing_manual_consent_is_refused_without_network(self):
        outputs = self.fake_attach(consent=False)
        with patch.object(probe.subprocess, "run", side_effect=outputs), patch.object(probe.OPENER, "open") as network:
            with self.assertRaisesRegex(probe.ProbeFailure, "Manual first-share consent is absent"):
                probe.attach(probe.validate_config(self.config))
            network.assert_not_called()

    def test_mismatched_navidrome_is_refused_without_network(self):
        outputs = self.fake_attach(navidrome="http://127.0.0.1:4603")
        with patch.object(probe.subprocess, "run", side_effect=outputs), patch.object(probe.OPENER, "open") as network:
            with self.assertRaises(probe.ProbeFailure):
                probe.attach(probe.validate_config(self.config))
            network.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
