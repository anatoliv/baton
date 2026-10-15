#!/usr/bin/env python3
"""Synthetic-only CLI protocol and secret-isolation regressions."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("share_enforce", Path(__file__).with_name("share-enforce.py"))
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
TOKEN = "synthetic_operator_" + "O" * 40
UUID = "01234567-1234-4234-8234-123456789abc"
ID = "A" * 22


def request():
    return dict(operationID=UUID, action="disable-share", shareID=ID, caseReference="case_fixture", reasonCode="review")


def plan():
    return dict(request=request(), plannedAt=100, validUntil=700, targetFingerprint="a" * 64,
                sharerRevision=0, affected=[dict(id=ID, revision=0, stateFingerprint="b" * 64, expiresAt=2000,
                retentionDeadline=1000, storedBytes=5000, restorable=False, restorationBlock="notDisabled")], signature="c" * 64)


def receipt():
    return dict(operationID=UUID, action="disable-share", caseReference="case_fixture", affectedCount=1, outcome="applied")


class OperatorCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="baton-operator-cli-")
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.env = self.root / "fixture.env"
        self.env.write_text("BATON_SHARE_ENFORCEMENT_ENABLED=1\nBATON_SHARE_OPERATOR_TOKEN=" + TOKEN + "\nBATON_SHARE_ADMIN_TOKEN=stats_only\n")
        self.env.chmod(0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def preservation_plan(self):
        candidate = plan()
        candidate['request'].update(reviewUntil=20 * cli.DAY, preservationDeadline=22 * cli.DAY)
        candidate['affected'][0].update(retentionDeadline=22 * cli.DAY,
            remainingLifetimeSeconds=6 * cli.DAY, preservationStartedAt=100,
            preservationCeiling=100 + 90 * cli.DAY, reviewUntil=20 * cli.DAY, courtReviewRequired=False)
        return candidate

    def test_consented_preservation_plan_can_exceed_calendar_expiry(self):
        candidate = self.preservation_plan()
        self.assertEqual(cli.validate_plan(candidate), candidate)
        for field in cli.PRESERVATION_METADATA:
            partial = copy.deepcopy(candidate); del partial['affected'][0][field]
            with self.assertRaises(ValueError): cli.validate_plan(partial)
        for key, value in [('preservationCeiling', 100 + 91 * cli.DAY),
                           ('retentionDeadline', 100 + 91 * cli.DAY),
                           ('remainingLifetimeSeconds', 31 * cli.DAY), ('courtReviewRequired', 1)]:
            invalid = copy.deepcopy(candidate); invalid['affected'][0][key] = value
            with self.assertRaises(ValueError): cli.validate_plan(invalid)

    def test_review_requires_exact_revision_court_state_and_buffer(self):
        candidate = self.preservation_plan()['request']
        candidate.update(action='review-preservation', expectedRevision=1, courtReviewRequired=True)
        self.assertEqual(cli.validate_request(candidate), candidate)
        for field in cli.PRESERVATION_FIELDS:
            partial = candidate.copy(); del partial[field]
            with self.assertRaises(ValueError): cli.validate_request(partial)
        for key, value in [('expectedRevision', True), ('reviewUntil', True),
                           ('preservationDeadline', 20 * cli.DAY), ('courtReviewRequired', 'cleared')]:
            invalid = candidate.copy(); invalid[key] = value
            with self.assertRaises(ValueError): cli.validate_request(invalid)
        candidate['action'] = 'restore-share'
        with self.assertRaises(ValueError): cli.validate_request(candidate)

    def test_review_flags_are_forwarded_then_only_exact_plan_can_apply(self):
        candidate = self.preservation_plan()
        candidate['request'].update(action='review-preservation', expectedRevision=1, courtReviewRequired=False)
        output = self.root / 'case-review.json'
        with patch.object(cli.uuid, 'uuid4', return_value=cli.uuid.UUID(UUID)), patch.object(cli, 'fetch', return_value=candidate) as fetch, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(['--env-file', str(self.env), '--output', str(output),
                '--action', 'review-preservation', '--share-id', ID, '--case-reference', 'case_fixture',
                '--reason-code', 'review', '--review-until', str(20 * cli.DAY),
                '--preservation-deadline', str(22 * cli.DAY), '--expected-revision', '1', '--court-review', 'cleared']), 0)
            self.assertEqual(fetch.call_args.args[2], candidate['request'])
        with patch.object(cli, 'apply') as apply, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(['--env-file', str(self.env), '--apply', '--plan', str(output), '--court-review', 'required']), 2)
            apply.assert_not_called()
        with patch.object(cli, 'apply', return_value=receipt()) as apply, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(['--env-file', str(self.env), '--apply', '--plan', str(output)]), 0)
            self.assertEqual(apply.call_args.args[1], candidate)

    def test_reference_reversal_is_forwarded_exactly_and_saved_privately(self):
        reversal = plan()
        reversal["request"] = dict(operationID=UUID, action="unsuspend-sharer", suspensionReference="AAAAAAAAAAAAAAAAAAAAAA",
                                   caseReference="case_fixture", reasonCode="review")
        reversal["affected"] = []
        output = self.root / "reversal.json"
        with patch.object(cli.uuid, "uuid4", return_value=cli.uuid.UUID(UUID)), patch.object(cli, "fetch", return_value=reversal) as fetch, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--env-file", str(self.env), "--output", str(output), "--action", "unsuspend-sharer",
                                       "--suspension-reference", "AAAAAAAAAAAAAAAAAAAAAA", "--case-reference", "case_fixture", "--reason-code", "review"]), 0)
        forwarded = fetch.call_args.args[2]
        self.assertEqual(set(forwarded), {"operationID", "action", "suspensionReference", "caseReference", "reasonCode"})
        self.assertEqual(forwarded["suspensionReference"], "AAAAAAAAAAAAAAAAAAAAAA")
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertEqual(json.loads(output.read_text()), reversal)
        with patch.object(cli, "apply", return_value={**receipt(), "action": "unsuspend-sharer", "affectedCount": 0}) as apply, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--env-file", str(self.env), "--apply", "--plan", str(output)]), 0)
            self.assertEqual(apply.call_args.args, (TOKEN, reversal))

    def test_server_plan_echo_must_match_requested_reference_and_operation(self):
        for override in [{"suspensionReference": "AQEBAQEBAQEBAQEBAQEBAQ"}, {"operationID": "abcdef01-1234-4234-8234-123456789abc"}]:
            reviewed = plan()
            reviewed["request"] = dict(operationID=UUID, action="unsuspend-sharer", suspensionReference="AAAAAAAAAAAAAAAAAAAAAA", caseReference="case_fixture", reasonCode="review")
            reviewed["request"].update(override)
            reviewed["affected"] = []
            output = self.root / "mismatch.json"
            with patch.object(cli.uuid, "uuid4", return_value=cli.uuid.UUID(UUID)), patch.object(cli, "fetch", return_value=reviewed), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["--env-file", str(self.env), "--output", str(output), "--action", "unsuspend-sharer",
                    "--suspension-reference", "AAAAAAAAAAAAAAAAAAAAAA", "--case-reference", "case_fixture", "--reason-code", "review"]), 2)
            self.assertFalse(output.exists())

    def test_inventory_cursor_refusal_and_minimal_response(self):
        reference = "AAAAAAAAAAAAAAAAAAAAAA"
        inventory = {"suspensions": [{"reference": reference, "revision": 7}], "nextCursor": reference}
        with patch.object(cli, "fetch", return_value=inventory) as fetch, contextlib.redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(cli.main(["--env-file", str(self.env), "--list-suspensions", "--cursor", reference]), 0)
        self.assertEqual(fetch.call_args.args, (TOKEN, "suspensions/AAAAAAAAAAAAAAAAAAAAAA"))
        self.assertEqual(json.loads(stdout.getvalue()), inventory)
        for options in [["--cursor", "bad"], ["--cursor", "A" * 21 + "B"], ["--share-id", ID],
                        ["--output", str(self.root / "no.json")], ["--action", "unsuspend-sharer"], ["--case-reference", "case_fixture"]]:
            with patch.object(cli, "fetch") as fetch, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["--env-file", str(self.env), "--list-suspensions", *options]), 2)
                fetch.assert_not_called()
        for unsafe in [{**inventory, "digest": "forbidden"}, {"suspensions": [{"reference": reference, "revision": 7, "digest": "forbidden"}]},
                       {"suspensions": inventory["suspensions"] * 201}, {"suspensions": [], "nextCursor": reference}]:
            with patch.object(cli, "fetch", return_value=unsafe), contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["--env-file", str(self.env), "--list-suspensions"]), 2)
                self.assertEqual(stdout.getvalue(), "")

    def test_reference_wrong_action_dual_target_and_scope_are_refused(self):
        reversal = dict(operationID=UUID, action="unsuspend-sharer", suspensionReference="AAAAAAAAAAAAAAAAAAAAAA", caseReference="case_fixture", reasonCode="review")
        for candidate in [{**reversal, "action": "restore-share"}, {**reversal, "shareID": ID},
                          {**reversal, "suspensionReference": "A" * 21 + "B"}]:
            with self.assertRaises(ValueError):
                cli.validate_request(candidate)
        reviewed = plan(); reviewed["request"] = reversal
        with self.assertRaises(ValueError):
            cli.validate_plan(reviewed)
        reviewed["affected"] = []
        calls = []
        expected = {**receipt(), "action": "unsuspend-sharer", "affectedCount": 0}
        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            if len(calls) < 3:
                raise subprocess.TimeoutExpired(argv, 15)
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(expected))
        self.assertEqual(cli.apply(TOKEN, reviewed, runner), expected)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0], calls[2])
        self.assertTrue(calls[1][0][-1].endswith("operations/" + UUID))
        self.assertIn("AAAAAAAAAAAAAAAAAAAAAA", calls[0][1]["input"])
        self.assertNotIn("AAAAAAAAAAAAAAAAAAAAAA", repr(calls[0][0]))

    def test_suspend_receipt_preserves_reference_for_private_case_custody(self):
        output = self.root / "plan.json"
        cli.save_plan(output, plan())
        expected = {**receipt(), "action": "suspend-sharer", "suspensionReference": "AAAAAAAAAAAAAAAAAAAAAA"}
        with patch.object(cli, "apply", return_value=expected), contextlib.redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(cli.main(["--env-file", str(self.env), "--apply", "--plan", str(output)]), 0)
            self.assertEqual(json.loads(stdout.getvalue()), expected)
        with patch.object(cli, "fetch", return_value={"receipt": expected, "cleanupPending": 0, "cleanupFailed": 0}), contextlib.redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(cli.main(["--env-file", str(self.env), "--recover", UUID]), 0)
            self.assertEqual(json.loads(stdout.getvalue())["suspensionReference"], "AAAAAAAAAAAAAAAAAAAAAA")

    def test_token_and_body_only_stdin_no_proxy_or_default_curl_config(self):
        calls = []
        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(plan()))
        self.assertEqual(cli.fetch(TOKEN, "plan", request(), runner), plan())
        argv, args = calls[0]
        self.assertEqual(argv[:8], ["docker", "exec", "-i", "baton-share", "curl", "--disable", "--noproxy", "*"])
        self.assertEqual(argv[-1], "http://127.0.0.1:8790/v1/share/admin/enforcement/plan")
        self.assertNotIn(TOKEN, repr(argv))
        self.assertNotIn("case_fixture", repr(argv))
        self.assertNotIn("env", args)
        self.assertNotIn("--location", argv)
        self.assertIn(TOKEN, args["input"])
        self.assertIn("case_fixture", args["input"])
        self.assertEqual(args["timeout"], 15)

    def test_private_modes_and_symlinks_fail_before_subprocess(self):
        for mode in [0o644, 0o640, 0o400]:
            self.env.chmod(mode)
            with patch.object(cli, "fetch") as fetch, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["--env-file", str(self.env), "--recover", UUID]), 2)
                fetch.assert_not_called()
        self.env.chmod(0o600)
        alias = self.root / "symlink.env"
        alias.symlink_to(self.env)
        with self.assertRaises(OSError):
            cli.private_read(alias)

    def test_disabled_duplicate_and_statistics_capability_rejected(self):
        for text in ["BATON_SHARE_OPERATOR_TOKEN=" + TOKEN,
                     "BATON_SHARE_ENFORCEMENT_ENABLED=1\nBATON_SHARE_OPERATOR_TOKEN=" + TOKEN + "\nBATON_SHARE_ADMIN_TOKEN=" + TOKEN,
                     "BATON_SHARE_ENFORCEMENT_ENABLED=1\nBATON_SHARE_OPERATOR_TOKEN=" + TOKEN + "\nBATON_SHARE_OPERATOR_TOKEN=" + TOKEN]:
            self.env.write_text(text)
            with self.assertRaises(ValueError):
                cli.capability(self.env)

    def test_default_cli_only_plans_and_saves_private_review_file(self):
        output = self.root / "review.json"
        with patch.object(cli.uuid, "uuid4", return_value=cli.uuid.UUID(UUID)), patch.object(cli, "fetch", return_value=plan()) as fetch, contextlib.redirect_stdout(io.StringIO()) as stdout:
            rc = cli.main(["--env-file", str(self.env), "--output", str(output), "--action", "disable-share",
                           "--share-id", ID, "--case-reference", "case_fixture", "--reason-code", "review"])
        self.assertEqual(rc, 0)
        self.assertEqual(fetch.call_args.args[1], "plan")
        self.assertEqual(fetch.call_count, 1)
        self.assertTrue(json.loads(stdout.getvalue())["dryRun"])
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertEqual(json.loads(output.read_text()), plan())
        self.assertNotIn(TOKEN, stdout.getvalue())

    def test_review_file_cannot_be_overwritten_or_saved_in_public_directory(self):
        output = self.root / "review.json"
        cli.save_plan(output, plan())
        with self.assertRaises(FileExistsError):
            cli.save_plan(output, plan())
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            cli.save_plan(self.root / "public.json", plan())

    def test_invalid_request_action_notice_url_and_uuid_rejected(self):
        for replacement in [{"action": "delete-everything"}, {"notice": "unrestricted notice"},
                            {"shareID": "https://batonmusic.app/s/" + ID + "#secret"}, {"operationID": UUID.upper()}]:
            candidate = request(); candidate.update(replacement)
            with self.assertRaises(ValueError):
                cli.validate_request(candidate)

    def test_malformed_plan_scope_time_and_fingerprints_rejected(self):
        candidates = []
        for key, value in [("affected", [plan()["affected"][0]] * 201), ("signature", "bad"),
                           ("sharerRevision", True), ("validUntil", 701)]:
            candidate = plan(); candidate[key] = value; candidates.append(candidate)
        for key, value in [("notice", "legal text"), ("retentionDeadline", 2001), ("restorable", 1), ("storedBytes", -1)]:
            candidate = plan(); candidate["affected"][0][key] = value; candidates.append(candidate)
        for candidate in candidates:
            with self.assertRaises(ValueError):
                cli.validate_plan(candidate)

    def test_response_and_body_size_bounded(self):
        def runner(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, stdout=" " * (cli.LIMIT + 1))
        with self.assertRaises(ValueError):
            cli.fetch(TOKEN, "plan", request(), runner)
        with self.assertRaises(ValueError):
            cli.fetch(TOKEN, "plan", {"large": "x" * cli.LIMIT}, runner)

    def test_lost_apply_response_recovers_receipt_without_new_apply(self):
        calls = []
        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            if len(calls) == 1:
                raise subprocess.TimeoutExpired(argv, 15)
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps({"receipt": receipt()}))
        self.assertEqual(cli.apply(TOKEN, plan(), runner), receipt())
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[1][0][-1].endswith("operations/" + UUID))
        self.assertNotIn('request = "POST"', calls[1][1]["input"])

    def test_retry_is_bounded_identical_and_never_changes_operation_uuid(self):
        calls = []
        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            raise subprocess.TimeoutExpired(argv, 15)
        with self.assertRaises(subprocess.TimeoutExpired):
            cli.apply(TOKEN, plan(), runner)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0], calls[2])

    def test_apply_requires_explicit_flag_exact_private_plan_and_no_new_action(self):
        output = self.root / "plan.json"
        cli.save_plan(output, plan())
        with patch.object(cli, "apply", return_value=receipt()) as apply, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--env-file", str(self.env), "--apply", "--plan", str(output)]), 0)
            self.assertEqual(apply.call_args.args, (TOKEN, plan()))
        with patch.object(cli, "apply") as apply, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(["--env-file", str(self.env), "--apply", "--plan", str(output), "--action", "disable-share"]), 2)
            apply.assert_not_called()
        output.chmod(0o644)
        with patch.object(cli, "apply") as apply, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(["--env-file", str(self.env), "--apply", "--plan", str(output)]), 2)
            apply.assert_not_called()

    def test_error_output_never_echoes_subprocess_secret_or_body(self):
        with patch.object(cli, "fetch", side_effect=subprocess.CalledProcessError(1, ["contains", TOKEN], stderr="case_fixture")), contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(cli.main(["--env-file", str(self.env), "--recover", UUID]), 2)
        self.assertNotIn(TOKEN, stderr.getvalue())
        self.assertNotIn("case_fixture", stderr.getvalue())
        self.assertIn("no success is confirmed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
