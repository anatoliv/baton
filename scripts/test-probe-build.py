#!/usr/bin/env python3
"""scripts/probe-build.sh with stubbed xcodegen/xcodebuild: the opt-in PROBE_BUNDLE_ID (TBX-1000000034).

Run: python3 scripts/test-probe-build.py
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent


class ProbeBuildBundleID(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="baton-probe-build-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.root / "home"),
                    "FIXTURE_LOG": str(self.log),
                    "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.install("xcodegen", "pass")
        self.install("xcodebuild", '''
args = sys.argv[1:]
app = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Debug/Baton.app"
(app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
''')
        # A copy of the repo's scripts with no Crashbox config, so crash reporting is disabled.
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "app").mkdir()
        for name in ("probe-build.sh", "prepare-crash-reporting.sh"):
            shutil.copy2(SOURCE / name, self.repo / "scripts" / name)
        for argv in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "fixture"]):
            subprocess.run(["git", "-C", str(self.repo), *argv], check=True, env=self.env)

    def install(self, name, body):
        file = self.bin / name
        file.write_text(f"#!{shutil.which('python3')}\nimport json, os, pathlib, sys\n"
                        "with open(os.environ['FIXTURE_LOG'], 'a') as log:\n"
                        "    log.write(json.dumps({'command': pathlib.Path(sys.argv[0]).name, 'args': sys.argv[1:]}) + '\\n')\n"
                        + body + "\n")
        file.chmod(0o755)

    def build(self, bundle_id=None):
        env = dict(self.env)
        if bundle_id is not None:
            env["PROBE_BUNDLE_ID"] = bundle_id
        return subprocess.run(["/bin/bash", str(self.repo / "scripts/probe-build.sh"), str(self.root / "out")],
                              env=env, capture_output=True, text=True, timeout=30)

    def builds(self):
        if not self.log.exists():
            return []
        return [x["args"] for x in map(json.loads, self.log.read_text().splitlines()) if x["command"] == "xcodebuild"]

    def test_default_build_keeps_the_project_bundle_id(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip().endswith("/Build/Products/Debug/Baton.app"), result.stdout)
        [build] = self.builds()
        self.assertFalse(any(a.startswith("PRODUCT_BUNDLE_IDENTIFIER=") for a in build), build)

    def test_a_development_bundle_id_is_passed_to_xcodebuild(self):
        result = self.build("io.tonebox.baton.dev.svcprobe")
        self.assertEqual(result.returncode, 0, result.stderr)
        [build] = self.builds()
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=io.tonebox.baton.dev.svcprobe", build)
        self.assertLess(build.index("PRODUCT_BUNDLE_IDENTIFIER=io.tonebox.baton.dev.svcprobe"), build.index("build"))
        self.assertIn("as io.tonebox.baton.dev.svcprobe", result.stderr)

    def test_the_release_id_and_malformed_ids_are_refused_before_building(self):
        for bad in ("io.tonebox.baton", "io.tonebox.baton.dev.", "com.example.baton", "io.tonebox.baton.dev.a b",
                    "io.tonebox.baton.dev.x;touch"):
            with self.subTest(bad=bad):
                result = self.build(bad)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("PROBE_BUNDLE_ID must begin io.tonebox.baton.dev.", result.stderr)
                self.assertEqual(self.builds(), [])
                self.assertFalse((self.root / "out").exists(), "a refused build must not create its output directory")

    def test_an_empty_override_is_the_default(self):
        result = self.build("")
        self.assertEqual(result.returncode, 0, result.stderr)
        [build] = self.builds()
        self.assertFalse(any(a.startswith("PRODUCT_BUNDLE_IDENTIFIER=") for a in build), build)


if __name__ == "__main__":
    unittest.main(verbosity=2)
