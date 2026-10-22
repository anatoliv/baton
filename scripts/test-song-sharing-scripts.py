#!/usr/bin/env python3
"""Offline report and origin-route regressions (TBX-8675, TBX-8676)."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import posixpath
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("adoption", ROOT / "scripts/adoption.py")
adoption = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adoption)


def empty_report():
    # Swift Codable omits optional nils, including EVERY rates key on an empty window.
    return {
        "window": {"since": "2026-09-26T00:00:00Z", "until": "2026-10-03T00:00:00Z", "days": 7},
        "sharers": {"active": 0, "new": 0, "repeating": 0, "byPlatform": {},
                    "topDecileShareFraction": 0, "sharesPerSharer": {}},
        "shares": {"created": 0, "finalized": 0, "liveNow": 0},
        "recipients": {"pageOpens": 0, "uniqueOpeners": 0, "openedInApp": 0,
                       "openedAfterEnd": {}, "unfurlsByApp": {}, "byDevice": {}},
        "listening": {"uniqueListeners": 0, "listened30s": 0, "decryptFailures": {}},
        "engagement": {"reactions": 0},
        "health": {"storedBytes": 0, "quotaBytes": 10737418240,
                   "failuresByReason": {}, "rateLimitedByScope": {}},
        "rates": {},
    }


class AdoptionTests(unittest.TestCase):
    def render(self, now, before, markdown=False):
        out = io.StringIO()
        with patch.object(adoption, "share_report", side_effect=[now, before]) as report, \
                contextlib.redirect_stdout(out):
            adoption.print_share(7, markdown)
        self.assertEqual(report.call_args_list[0].args, (7, 0))
        self.assertEqual(report.call_args_list[1].args, (7, 7))
        return out.getvalue()

    def test_empty_plain_report(self):
        out = self.render(empty_report(), empty_report())
        self.assertIn("open rate —   play —   listen ≥30 s —   completion —   reactions —   Get Baton —", out)
        self.assertIn("0 live shares", out)

    def test_empty_markdown_report(self):
        out = self.render(empty_report(), empty_report(), True)
        self.assertIn("| Open / play / listen / completion | — / — / — / — |", out)
        self.assertIn("| Get Baton click-through | — |", out)

    def test_partial_plain_rates_preserve_measured_zero(self):
        report = empty_report()
        report["rates"] = {"openRate": 0, "playRate": 0.5, "getBatonRate": 0.125}
        out = self.render(report, empty_report())
        self.assertIn("open rate 0%   play 50%   listen ≥30 s —   completion —   reactions —   Get Baton 12%", out)

    def test_partial_markdown_rates(self):
        report = empty_report()
        report["rates"] = {"completionRate": 0, "listenRate": 0.75}
        out = self.render(report, empty_report(), True)
        self.assertIn("| Open / play / listen / completion | — / — / 75% / 0% |", out)

    def test_populated_report_deltas_and_rates(self):
        before = empty_report()
        report = copy.deepcopy(before)
        report["sharers"]["active"] = 3
        report["rates"] = dict.fromkeys(("openRate", "playRate", "listenRate", "completionRate",
                                        "reactionRate", "getBatonRate"), 0.5)
        out = self.render(report, before, True)
        self.assertIn("| Active sharers | **3** (+3) |", out)
        self.assertIn("50% / 50% / 50% / 50%", out)

    def test_previous_window_unavailable_still_reports_current(self):
        out = self.render(empty_report(), {"error": "unavailable"})
        self.assertIn("0 live shares", out)
        self.assertNotIn("(+", out)

    def test_empty_report_cli_succeeds_in_both_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            ssh = Path(directory) / "ssh"
            ssh.write_text("#!/usr/bin/env python3\nprint(" + repr(json.dumps(empty_report())) + ")\n")
            ssh.chmod(0o755)
            for mode in ([], ["--markdown"]):
                with self.subTest(mode=mode):
                    result = subprocess.run(["python3", str(ROOT / "scripts/adoption.py"), "share", *mode],
                                            env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                                                 "SHARE_ADMIN_URL": ""},
                                            capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("Song sharing", result.stdout)
                    self.assertIn("—", result.stdout)
                    self.assertNotIn("not measured", result.stdout)

    def test_remote_token_travels_on_stdin_not_argv(self):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory)
            # No real token, environment file, Docker, SSH or network is accessed.
            token = "fake-token-for-an-offline-test"
            sed = bin_dir / "sed"
            sed.write_text(f"#!/bin/sh\nprintf '%s\\n' '{token}'\n")
            docker = bin_dir / "docker"
            docker.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                              f"assert '{token}' not in ' '.join(sys.argv)\n"
                              "assert sys.argv[1:4] == ['exec', '-i', 'baton-share']\n"
                              "assert sys.argv[4:11] == ['curl', '--disable', '--noproxy', '*', '-sf', '-H', '@-']\n"
                              f"assert sys.stdin.read() == 'Authorization: Bearer {token}\\n'\n"
                              "print('{}')\n")
            sed.chmod(0o755)
            docker.chmod(0o755)
            real_run = subprocess.run

            def remote_run(args, **kwargs):
                self.assertNotIn(token, " ".join(args))
                return real_run(["sh", "-c", args[-1]],
                                env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}"}, **kwargs)

            with patch.dict(os.environ, {}, clear=True), patch.object(adoption.subprocess, "run", side_effect=remote_run):
                # Stubs need the normal interpreter PATH, retained solely for this fake Docker.
                with patch.dict(os.environ, {"PATH": os.defpath}):
                    self.assertEqual(adoption.share_report(7, 0), {})


class OriginTests(unittest.TestCase):
    # The stub ssh answers the routing probe (BATON_SITE_STATUS), and the edge-gate pair
    # a request carrying a forged CF-Connecting-IP gets PROBE_FORGED, the
    # plain one PROBE_PLAIN, each as the bare status curl -w prints.
    def probe(self, response="Conduct <em>your</em> music\nBATON_SITE_STATUS:200", binding="192.0.2.10", rc=0,
              forged="403", plain="200", script="scripts/publish-site.sh", env=None):
        with tempfile.TemporaryDirectory() as directory:
            ssh = Path(directory) / "ssh"
            calls = Path(directory) / "calls.jsonl"
            ssh.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                           "with open(os.environ['PROBE_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                           "command = sys.argv[-1]\n"
                           "if 'docker inspect' in command:\n"
                           "    print(os.environ['PROBE_BINDING'])\n"
                           "elif 'CF-Connecting-IP' in command:\n"
                           "    sys.stdout.write(os.environ['PROBE_FORGED'])\n"
                           "elif 'BATON_SITE_STATUS' not in command:\n"
                           "    sys.stdout.write(os.environ['PROBE_PLAIN'])\n"
                           "else:\n"
                           "    print(os.environ['PROBE_RESPONSE'])\n"
                           "    sys.exit(int(os.environ['PROBE_RC']))\n")
            ssh.chmod(0o755)
            out = subprocess.run(["bash", str(ROOT / script)],
                                 env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                                      "ORIGIN_CHECK_ONLY": "1", "PROBE_CALLS": str(calls),
                                      "PROBE_BINDING": binding, "PROBE_RESPONSE": response, "PROBE_RC": str(rc),
                                      "PROBE_FORGED": forged, "PROBE_PLAIN": plain, **(env or {})},
                                 capture_output=True, text=True, timeout=15)
            recorded = [json.loads(line) for line in calls.read_text().splitlines()]
            if script == "scripts/publish-site.sh":
                # Routing: one binding read and one request per host. Gate: another binding read
                # and two requests per host.
                self.assertEqual(len(recorded), 8 if binding else 2)
            self.assertTrue(all("docker inspect" in row[-1] or "curl " in row[-1] for row in recorded))
            return out, recorded

    def gate_calls(self, calls):
        return [row[-1] for row in calls if "curl " in row[-1] and "BATON_SITE_STATUS" not in row[-1]]

    def test_edge_gate_refusing_a_forged_address_passes(self):
        out, calls = self.probe()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.count("the edge gate is on"), 2)
        gate = self.gate_calls(calls)
        self.assertEqual(len(gate), 4)
        forged = [command for command in gate if "CF-Connecting-IP" in command]
        self.assertEqual(len(forged), 2, "one forged request per host")
        self.assertTrue(all("CF-Connecting-IP: 192.0.2.1" in command for command in forged))
        self.assertTrue(all("--resolve 'batonmusic.app:443:192.0.2.10'" in command
                            or "--resolve 'baton.tonebox.io:443:192.0.2.10'" in command for command in gate))
        self.assertFalse(any("X-Edge-Auth" in command or "edge-auth" in command for command in gate),
                         "the probe never carries or reads the gate's secret")

    def test_edge_gate_serving_a_forged_address_fails(self):
        # The control: the same probe with the gate rolled back (the forged request is served).
        out, _ = self.probe(forged="200")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("The estate edge gate is off; E-9 is open", out.stderr)

    def test_edge_gate_refusing_everything_is_unmeasured_not_a_pass(self):
        # A 403 for both requests (an access list, an outage page) proves nothing about the gate.
        out, _ = self.probe(forged="403", plain="403")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("the edge gate is unmeasured", out.stderr)
        out, _ = self.probe(forged="000", plain="000")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("the edge gate is unmeasured", out.stderr)

    def subnet_guard(self, live, rc=0):
        """The real proxy_net subnet guard from publish-site.sh, run against a stub ssh."""
        site = (ROOT / "scripts/publish-site.sh").read_text()
        start = site.index('want_subnet="$(sed')
        end = site.index('before deploying."', start) + len('before deploying."')
        with tempfile.TemporaryDirectory() as directory:
            ssh = Path(directory) / "ssh"
            ssh.write_text("#!/bin/sh\nprintf '%s\\n' \"$PROBE_SUBNET\"\nexit $PROBE_RC\n")
            ssh.chmod(0o755)
            script = Path(directory) / "guard.sh"
            script.write_text("set -euo pipefail\nfail() { echo \"FAIL: $*\" >&2; exit 1; }\nWEB01=stub-host\n"
                              + site[start:end] + "\necho GUARD_PASSED\n")
            return subprocess.run(["bash", str(script)], cwd=ROOT, capture_output=True, text=True, timeout=10,
                                  env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                                       "PROBE_SUBNET": live, "PROBE_RC": str(rc)})

    def test_trusted_subnet_must_be_proxy_nets(self):
        # An internal task A3: default.conf trusts X-Real-IP from one subnet, which must be the live
        # proxy_net's, or every visitor would become NPM's one address.
        configured = re.findall(r"^\s*([0-9.]+/[0-9]+)\s+1;\s+# proxy_net$", (ROOT / "deploy/nginx/default.conf").read_text(), re.M)
        self.assertEqual(len(configured), 1)
        self.assertIn("GUARD_PASSED", self.subnet_guard(configured[0] + " ").stdout)
        for live, rc in [("10.9.0.0/16", 0), ("", 0), (configured[0], 255)]:
            out = self.subnet_guard(live, rc)
            self.assertNotEqual(out.returncode, 0, (live, rc))
            self.assertNotIn("GUARD_PASSED", out.stdout)
            self.assertIn("proxy_net on stub-host is", out.stderr)

    def test_published_binding_and_both_hosts(self):
        out, calls = self.probe()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.count("is served through the edge"), 2)
        self.assertIn("batonmusic.app:443:192.0.2.10", calls[1][-1])
        self.assertIn("baton.tonebox.io:443:192.0.2.10", calls[2][-1])

    def test_wrong_page_is_rejected_despite_200(self):
        out, _ = self.probe("NPM welcome page\nBATON_SITE_STATUS:200")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("without the expected Baton page", out.stderr)

    def test_wrong_status_is_rejected_despite_right_body(self):
        out, _ = self.probe("Conduct <em>your</em> music\nBATON_SITE_STATUS:404")
        self.assertNotEqual(out.returncode, 0)

    def test_connection_failure_is_unmeasured(self):
        out, _ = self.probe("BATON_SITE_STATUS:000", rc=7)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("routing is unmeasured", out.stderr)

    def test_missing_binding_is_unmeasured(self):
        out, _ = self.probe(binding="")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("No usable published HTTPS address", out.stderr)

    def test_wildcard_binding_uses_loopback(self):
        out, calls = self.probe(binding="0.0.0.0")
        self.assertEqual(out.returncode, 0)
        self.assertIn("batonmusic.app:443:127.0.0.1", calls[1][-1])

    def test_ipv6_binding_is_bracketed(self):
        out, calls = self.probe(binding="2001:db8::1")
        self.assertEqual(out.returncode, 0)
        self.assertIn("batonmusic.app:443:[2001:db8::1]", calls[1][-1])


class ShareDeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix="baton-share-archive-")
        cls.fixture = Path(cls.work.name) / "source"
        cls.fixture.mkdir()
        cls.source_revision = subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
        cls.archive_receipts = []

        def pinned(path):
            return subprocess.check_output(
                ["git", "-C", str(ROOT), "show", f"{cls.source_revision}:{path}"])

        # Traverse the committed manifests, not the lint's copy-command parser.
        cls.packages = set()
        pending = ["gateway"]
        for directory in pending:
            manifest = pinned(f"{directory}/Package.swift").decode()
            for match in re.finditer(r'\.package\(\s*path:\s*"([^"]+)"', manifest):
                package = posixpath.normpath(f"{directory}/{match.group(1)}")
                if package not in cls.packages:
                    cls.packages.add(package)
                    pending.append(package)
        cls.declared = re.findall(r'\.package\(path: "\.\./(Packages/[^\"]+)"\)',
                                  pinned("gateway/Package.swift").decode())
        cls.expected = {}
        files = subprocess.check_output(
            ["git", "-C", str(ROOT), "ls-tree", "-r", "--name-only", cls.source_revision,
             "--", "gateway", *sorted(cls.packages)], text=True).splitlines()
        for name in files:
            data = pinned(name)
            cls.expected[name] = data
            path = cls.fixture / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        subprocess.run(["git", "-c", "init.templateDir=", "init", "-q", "-b", "main",
                        str(cls.fixture)], check=True)
        subprocess.run(["git", "-C", str(cls.fixture), "add", "gateway", "Packages"], check=True)
        subprocess.run(["git", "-C", str(cls.fixture), "-c", "user.name=fixture",
                        "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                        "-c", "core.hooksPath=/dev/null", "commit", "-qm", "archive fixture"], check=True)
        cls.fixture_revision = subprocess.check_output(
            ["git", "-C", str(cls.fixture), "rev-parse", "HEAD"], text=True).strip()
        deploy = (ROOT / "gateway/deploy/deploy-share.sh").read_text()
        start = deploy.index('git -C "$REPO" archive "$REVISION"')
        end = deploy.index('  | ssh ', start)
        # Execute only the reviewed archive statement, replacing the SSH sink with
        # a local output file. No deployment step or shell-parser reimplementation.
        cls.archive_command = deploy[start:end] + '  > "$ARCHIVE"\n'

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def archive(self, missing=None):
        command = self.archive_command
        if missing:
            command, count = re.subn(r'(?<!\S)' + re.escape(missing) + r'(?=\s)',
                                    "", command, count=1)
            self.assertEqual(count, 1, "fixture must remove an actual archive input")
        with tempfile.TemporaryDirectory(prefix="baton-share-tar-") as work:
            output = Path(work) / "source.tar"
            subprocess.run(["/bin/bash", "-eu", "-c", command], check=True,
                           env={"PATH": os.defpath, "REPO": str(self.fixture),
                                "REVISION": self.fixture_revision, "ARCHIVE": str(output)})
            with tarfile.open(output) as archive:
                files = {member.name: archive.extractfile(member).read()
                         for member in archive.getmembers() if member.isfile()}
            self.archive_receipts.append({
                "omittedInput": missing, "bytes": output.stat().st_size,
                "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                "regularFiles": len(files), "expectedSourceFiles": len(self.expected),
                "sourceRevision": self.source_revision,
                "sourceIdentities": {name: hashlib.sha256(data).hexdigest()
                                     for name, data in sorted(self.expected.items())},
            })
            return files

    def assert_source_closure(self, files):
        for package in sorted(self.packages):
            self.assertIn(f"{package}/Package.swift", files)
        for name, expected in self.expected.items():
            self.assertIn(name, files)
            self.assertEqual(files[name], expected, f"archive bytes differ for {name}")

    def test_every_declared_path_dependency_reaches_docker_build(self):
        declared = re.findall(r'\.package\(path: "\.\./(Packages/[^\"]+)"\)',
                              (ROOT / "gateway/Package.swift").read_text())
        self.assertGreaterEqual(len(declared), 6)
        self.assert_source_closure(self.archive())
        dockerfile = (ROOT / "gateway/deploy/share.Dockerfile").read_text()
        for package in declared:
            with self.subTest(package=package):
                self.assertRegex(dockerfile, rf'(?m)^COPY {re.escape(package)}\s+{re.escape(package)}$')

    def test_archive_missing_direct_package_is_rejected(self):
        package = "Packages/BatonAgentKit"
        self.assertIn(package, self.declared)
        with self.assertRaisesRegex(AssertionError, re.escape(f"{package}/Package.swift")):
            self.assert_source_closure(self.archive(missing=package))

    def test_archive_missing_transitive_package_is_rejected(self):
        package = "Packages/BatonSubsonicModels"
        self.assertIn('.package(path: "../BatonSubsonicModels")',
                      self.expected["Packages/BatonAgentKit/Package.swift"].decode())
        with self.assertRaisesRegex(AssertionError, re.escape(f"{package}/Package.swift")):
            self.assert_source_closure(self.archive(missing=package))

    def test_ignored_generated_file_is_not_archived(self):
        marker = "gateway/.build/synthetic-ignored-marker"
        (self.fixture / ".git/info").mkdir(exist_ok=True)
        (self.fixture / ".git/info/exclude").write_text("gateway/.build/\n")
        path = self.fixture / marker
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("synthetic ignored fixture\n")
        try:
            subprocess.run(["git", "-C", str(self.fixture), "check-ignore", "-q", marker], check=True)
            files = self.archive()
            self.assert_source_closure(files)
            self.assertNotIn(marker, files)
        finally:
            path.unlink()


if __name__ == "__main__":
    unittest.main()
