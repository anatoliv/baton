#!/usr/bin/env python3
"""Exercise the development CLI with disposable build/open/process boundaries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent


class DevelopmentLaunchIsolation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="baton-devrun-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.home),
                    "FIXTURE_LOG": str(self.log), "FIXTURE_ROOT": str(self.root)}
        self.install("xcodegen", "pass")
        self.install("xcodebuild", '''
args = sys.argv[1:]
path = pathlib.Path(args[args.index("-derivedDataPath") + 1])
# The old CLI names /tmp/baton-build: record it but never touch shared owner output.
if path.is_relative_to(pathlib.Path(os.environ["FIXTURE_ROOT"])):
    app = path / "Build/Products/Debug/Baton.app"
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (app / "fixture-build.txt").write_text(str(pathlib.Path.cwd()))
''')
        self.install("open", "pass")
        self.install("pgrep", "sys.exit(1)")
        self.install("pkill", "pass")

    def install(self, name, body):
        file = self.bin / name
        file.write_text(f"#!{shutil.which('python3')}\nimport json, os, pathlib, signal, sys\n"
                        "with open(os.environ['FIXTURE_LOG'], 'a') as log:\n"
                        "    log.write(json.dumps({'command': pathlib.Path(sys.argv[0]).name, 'args': sys.argv[1:]}) + '\\n')\n"
                        + body + "\n")
        file.chmod(0o755)

    def lane(self, name):
        lane = self.root / name
        (lane / "scripts").mkdir(parents=True)
        (lane / "app").mkdir()
        for file in ("devrun.sh", "dev-processes.sh"):
            if (SOURCE / file).exists():
                shutil.copy2(SOURCE / file, lane / "scripts" / file)
        subprocess.run(["git", "init", "-q", str(lane)], check=True, env=self.env)
        return lane

    def run_lane(self, lane, overrides=None, *args):
        return subprocess.run(["bash", str(lane / "scripts/devrun.sh"), *args],
                              env=self.env | (overrides or {}), capture_output=True, text=True, timeout=20)

    def calls(self, name):
        return [x["args"] for x in map(json.loads, self.log.read_text().splitlines()) if x["command"] == name]

    def test_worktrees_get_distinct_artifacts_and_keep_their_own_build(self):
        a, b = self.lane("first lane"), self.lane("second lane")
        first, second = self.run_lane(a), self.run_lane(b)
        builds = self.calls("xcodebuild")
        paths = [Path(x[x.index("-derivedDataPath") + 1]) for x in builds]
        self.assertNotEqual(paths[0], paths[1], "two worktrees overwrite the same build output")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((paths[0] / "Build/Products/Debug/Baton.app/fixture-build.txt").read_text(), str(a / "app"))
        self.assertEqual((paths[1] / "Build/Products/Debug/Baton.app/fixture-build.txt").read_text(), str(b / "app"))
        ids = [next(x for x in build if x.startswith("PRODUCT_BUNDLE_IDENTIFIER=")) for build in builds]
        self.assertNotEqual(ids[0], ids[1])
        self.assertTrue(all(x.startswith("PRODUCT_BUNDLE_IDENTIFIER=io.tonebox.baton.dev.") for x in ids))
        self.assertEqual(self.run_lane(a).returncode, 0)
        repeat = self.calls("xcodebuild")[-1]
        self.assertEqual(repeat[repeat.index("-derivedDataPath") + 1], str(paths[0]))
        launches = self.calls("open")
        suites = [x[x.index("-baton.defaultsSuite") + 1] for x in launches[:2]]
        dirs = [x[x.index("-baton.supportDirectory") + 1] for x in launches[:2]]
        self.assertNotEqual(suites[0], suites[1])
        self.assertNotEqual(dirs[0], dirs[1])
        self.assertTrue(all(suite != identifier.split("=", 1)[1] for suite, identifier in zip(suites, ids)))

    def test_relaunch_stops_only_its_exact_executable_and_preserves_other_lane(self):
        lane = self.lane("owned lane")
        owned = subprocess.Popen(["/bin/sleep", "60"])
        other = subprocess.Popen(["/bin/sleep", "60"])
        for process in (owned, other):
            def cleanup(process=process):
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
            self.addCleanup(cleanup)
        self.env.update(FIXTURE_OWN_PID=str(owned.pid), FIXTURE_OTHER_PID=str(other.pid))
        self.install("pgrep", 'print(os.environ["FIXTURE_OWN_PID"]); print(os.environ["FIXTURE_OTHER_PID"])')
        self.install("pkill", 'os.kill(int(os.environ["FIXTURE_OWN_PID"]), signal.SIGTERM); os.kill(int(os.environ["FIXTURE_OTHER_PID"]), signal.SIGTERM)')
        self.install("lsof", '\nargs = sys.argv[1:]\npid = args[args.index("-p") + 1]\nif pid == os.environ["FIXTURE_OWN_PID"]:\n    builds = [json.loads(x)["args"] for x in pathlib.Path(os.environ["FIXTURE_LOG"]).read_text().splitlines() if json.loads(x)["command"] == "xcodebuild"]\n    build = builds[-1]\n    app = pathlib.Path(build[build.index("-derivedDataPath") + 1]) / "Build/Products/Debug/Baton.app/Contents/MacOS/Baton"\n    print("p" + pid); print("n" + str(app))\nelse:\n    print("p" + pid); print("n/Applications/Baton.app/Contents/MacOS/Baton")\n')
        result = self.run_lane(lane)
        self.assertEqual(result.returncode, 0, result.stderr)
        try:
            owned.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.fail("relaunch did not terminate this checkout's old executable")
        self.assertIsNone(other.poll(), "relaunch terminated a different Baton installation")
        self.assertEqual(self.calls("pkill"), [])
        self.assertEqual(len(self.calls("open")), 1)

    def test_explicit_overrides_are_forwarded_and_build_only_never_launches(self):
        lane = self.lane("override lane")
        overrides = {"BATON_BUILD_DIR": str(self.root / "explicit build"),
                     "BATON_DEV_BUNDLE_ID": "io.tonebox.baton.dev.fixture",
                     "BATON_DEV_SUITE": "baton.fixture.defaults",
                     "BATON_DEV_SUPPORT_DIR": str(self.root / "explicit support"),
                     "SIGN_ID": "Apple Development: Fixture"}
        result = self.run_lane(lane, overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        build = self.calls("xcodebuild")[0]
        self.assertEqual(build[build.index("-derivedDataPath") + 1], overrides["BATON_BUILD_DIR"])
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=io.tonebox.baton.dev.fixture", build)
        self.assertIn("CODE_SIGN_IDENTITY=Apple Development: Fixture", build)
        launch = self.calls("open")[0]
        self.assertEqual(launch[0], "-n")
        self.assertEqual(launch[launch.index("-baton.defaultsSuite") + 1], "baton.fixture.defaults")
        self.assertEqual(launch[launch.index("-baton.supportDirectory") + 1], overrides["BATON_DEV_SUPPORT_DIR"])
        self.log.unlink()
        result = self.run_lane(lane, overrides, "--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("open"), [])
        self.assertEqual(self.calls("pgrep"), [])

    def test_invalid_overrides_fail_before_build_or_process_inventory(self):
        lane = self.lane("invalid lane")
        for override in ({"BATON_DEV_BUNDLE_ID": "io.tonebox.baton"},
                         {"BATON_DEV_SUITE": "io.tonebox.baton"},
                         {"BATON_DEV_SUITE": "suite/escape"},
                         {"BATON_DEV_SUITE": "x" * 65},
                         {"BATON_BUILD_DIR": "relative"},
                         {"BATON_DEV_SUPPORT_DIR": "relative"}):
            with self.subTest(override=override):
                result = self.run_lane(lane, override)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("error:", result.stderr)
                self.assertFalse(self.log.exists(), "invalid overrides reached build/process commands")

    def test_unreadable_process_identity_never_authorizes_termination(self):
        lane = self.lane("unknown identity lane")
        other = subprocess.Popen(["/bin/sleep", "60"])
        def cleanup():
            if other.poll() is None:
                other.terminate()
            other.wait(timeout=5)
        self.addCleanup(cleanup)
        self.install("pgrep", f"print({other.pid})")
        self.install("lsof", "sys.exit(1)")
        result = self.run_lane(lane)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(other.poll())


if __name__ == "__main__":
    unittest.main()
