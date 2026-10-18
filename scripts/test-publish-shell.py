#!/usr/bin/env python3
"""Run the publisher's actual signing and cleanup blocks under macOS Bash."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SUBJECT = Path(os.environ.get("BATON_PUBLISH_SUBJECT", ROOT / "scripts/publish.sh"))
SOURCE = SUBJECT.read_text()


class PublisherShellTests(unittest.TestCase):
    def run_shell(self, script, **env):
        return subprocess.run(
            ["/bin/bash", "-c", script], text=True, capture_output=True,
            env={**os.environ, **env}, timeout=10,
        )

    def signing(self, mode, fail=False):
        block = "# 2. Sign (opt-in)" + SOURCE.split("# 2. Sign (opt-in)", 1)[1].split("# 3. Notarize", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Baton.app/Contents/Frameworks/Example.framework").mkdir(parents=True)
            (root / "entitlements").write_text("synthetic")
            setup = r'''
set -euo pipefail
APP="$FIXTURE/Baton.app"
MAC_RELEASE_ENTITLEMENTS="$FIXTURE/entitlements"
MAC_ASSOCIATION_WORK="$FIXTURE"
SIGN_ID=synthetic
step(){ :; }
warn(){ :; }
python3(){ :; }
mac_association_verify(){ :; }
codesign(){
  if [ "$1" = -d ]; then
    printf 'com.apple.security.app-sandbox\ncom.apple.security.network.server\n'
    return 0
  fi
  printf '%s\n' "$*" >>"$FIXTURE/calls"
  [ "$FAIL_SIGN" = 0 ] || return 17
}
'''
            result = self.run_shell(setup + block, FIXTURE=directory,
                                    MAC_ASSOCIATION_MODE=mode, FAIL_SIGN=str(int(fail)))
            calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
            return result, calls

    def test_associated_main_omits_deep_nested_keeps_it(self):
        result, calls = self.signing("associated")
        self.assertEqual(result.returncode, 0, result.stderr)
        signing = [line.split() for line in calls if line.startswith("--force")]
        self.assertEqual(len(signing), 2)
        self.assertIn("--deep", signing[0])
        self.assertNotIn("--deep", signing[1])
        self.assertIn("--entitlements", signing[1])

    def test_core_main_keeps_deep(self):
        result, calls = self.signing("core")
        self.assertEqual(result.returncode, 0, result.stderr)
        signing = [line.split() for line in calls if line.startswith("--force")]
        self.assertEqual(len(signing), 1)
        self.assertIn("--deep", signing[0])

    def test_signing_failure_stops(self):
        result, calls = self.signing("associated", fail=True)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(len(calls), 1)

    def cleanup(self, ending):
        block = SOURCE.split("publish_cleanup() {", 1)[1].split('if [ -z "${BATON_ALLOW_CONCURRENT_GATE:-}" ]; then', 1)[0]
        setup = r'''
set -euo pipefail
TMP_DL=""
MAC_ASSOCIATION_WORK=""
PUBLISH_COMPLETE=0
gate_lock_release(){ printf 'host released\n'; }
native_lock_release_all(){ printf 'resources released\n'; }
'''
        return self.run_shell(setup + "publish_cleanup() {" + block + ending)

    def assert_cleanup(self, ending, status):
        result = self.cleanup(ending)
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["host released", "resources released"])

    def test_cleanup_preserves_success(self):
        self.assert_cleanup("PUBLISH_COMPLETE=1; exit 0\n", 0)

    def test_cleanup_refuses_unfinished_zero_exit(self):
        self.assert_cleanup("exit 0\n", 1)

    def test_cleanup_preserves_explicit_failure(self):
        self.assert_cleanup("exit 23\n", 23)

    def test_cleanup_preserves_nounset_failure(self):
        self.assert_cleanup('unset absent; printf "%s" "$absent"\n', 1)

    def test_cleanup_preserves_signal_status(self):
        for name, status in (("INT", 130), ("TERM", 143)):
            with self.subTest(signal=name):
                self.assert_cleanup('kill -' + name + ' $$\n', status)


if __name__ == "__main__":
    unittest.main()
