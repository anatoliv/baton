#!/usr/bin/env python3
"""Synthetic signing/profile/control-flow regressions. No Apple, Keychain, signing or native build."""
import copy
import contextlib
import datetime as dt
import hashlib
import json
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import mac_association_signing as subject


class MacAssociationTests(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        self.temp = tempfile.TemporaryDirectory(prefix="baton-association-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"; self.work.mkdir(mode=0o700)
        self.now = dt.datetime.now(dt.timezone.utc)
        self.cert = b"synthetic-public-certificate-not-a-real-identity"
        self.signer = "Developer ID Application: Synthetic Owner (Q8822GNL2H)"
        self.source = {"com.apple.security.app-sandbox": False, "com.apple.security.network.client": True,
                       "com.apple.security.network.server": True, subject.DOMAIN_KEY: subject.DOMAINS}
        self.profile = {"UUID": "11111111-2222-3333-4444-555555555555", "Platform": ["OSX"],
                        "ProvisionsAllDevices": True, "CreationDate": (self.now - dt.timedelta(days=1)).replace(tzinfo=None),
                        "ExpirationDate": (self.now + dt.timedelta(days=1)).replace(tzinfo=None),
                        "ApplicationIdentifierPrefix": ["ZZZZZZZZZZ"], "TeamIdentifier": ["Q8822GNL2H"],
                        "DeveloperCertificates": [self.cert], "Entitlements": {
                            subject.APP_ID_KEY: "ZZZZZZZZZZ.io.tonebox.baton", subject.TEAM_KEY: "Q8822GNL2H",
                            subject.DOMAIN_KEY: ["*"], "get-task-allow": False}}
        self.aasa = {"applinks": {"details": [{"appIDs": [subject.PHONE_APP_ID, "ZZZZZZZZZZ.io.tonebox.baton"],
                                              "components": [{"?": {"web": "1"}, "exclude": True}, {"/": "/s/*"}, {"/": "/m/*"}]}]}}
        self.source_path = self.root / "source.entitlements"
        self.source_path.write_bytes(plistlib.dumps(self.source))
        self.aasa_path = self.root / "aasa.json"; self.aasa_path.write_text(json.dumps(self.aasa))
        self.profile_path = self.root / "approved.profile"; self.profile_path.write_bytes(b"synthetic-approved-cms")
        self.cert_path = self.root / "approved.cer"; self.cert_path.write_bytes(self.cert)
        self.env = {"MAC_ASSOCIATION_PROFILE_FILE": str(self.profile_path),
                    "MAC_ASSOCIATION_PROFILE_SHA256": subject.digest(self.profile_path.read_bytes()),
                    "MAC_ASSOCIATION_CERTIFICATE_FILE": str(self.cert_path),
                    "MAC_ASSOCIATION_CERTIFICATE_SHA256": subject.digest(self.cert),
                    "SIGN_ID": hashlib.sha1(self.cert).hexdigest()}

    def claims(self, profile=None, source=None):
        return subject.profile_claims(profile or self.profile, source or self.source, self.cert, self.now)

    def preflight(self, env=None):
        with patch.object(subject, "run", return_value=plistlib.dumps(self.profile)), \
                patch.object(subject, "check_certificate", return_value=self.signer):
            return subject.preflight(self.source_path, self.aasa_path, self.work, self.env if env is None else env)

    def testPrefixComesFromProfileNotTeamOrPhone(self):
        claims = self.claims()
        self.assertEqual(claims[subject.APP_ID_KEY], "ZZZZZZZZZZ.io.tonebox.baton")
        self.assertEqual(claims[subject.TEAM_KEY], "Q8822GNL2H")
        self.assertNotIn("get-task-allow", claims)

    def testProfileDomainWildcardAuthorizesOnlyExactSourceDomains(self):
        self.assertEqual(self.claims()[subject.DOMAIN_KEY], subject.DOMAINS)
        # The real "Baton Mac Developer ID" profile grants the capability as the string "*".
        self.profile["Entitlements"][subject.DOMAIN_KEY] = "*"
        self.assertEqual(self.claims()[subject.DOMAIN_KEY], subject.DOMAINS)
        for grant in ["applinks:batonmusic.app", "", ["applinks:batonmusic.app"]]:
            with self.subTest(grant=grant):
                self.profile["Entitlements"][subject.DOMAIN_KEY] = grant
                with self.assertRaises(subject.QualificationError): self.claims()
        self.profile["Entitlements"][subject.DOMAIN_KEY] = ["*"]
        changed = dict(self.source); changed[subject.DOMAIN_KEY] = ["applinks:foreign.example"]
        with self.assertRaises(subject.QualificationError): self.claims(source=changed)

    def testInvalidProfileFactsFailClosed(self):
        cases = {
            "phone": ("Platform", ["iOS"]), "mixed platform": ("Platform", ["OSX", "iOS"]),
            "development devices": ("ProvisionedDevices", ["SYNTHETIC-MAC"]),
            "development distribution": ("ProvisionsAllDevices", False),
            "expired": ("ExpirationDate", (self.now - dt.timedelta(seconds=1)).replace(tzinfo=None)),
            "future": ("CreationDate", (self.now + dt.timedelta(days=1)).replace(tzinfo=None)),
            "prefix": ("ApplicationIdentifierPrefix", ["Q8822GNL2H"]),
            "team": ("TeamIdentifier", ["ZZZZZZZZZZ"]), "certificate": ("DeveloperCertificates", [b"different"]),
            "uuid": ("UUID", "bad\nCODE_SIGNING_ALLOWED=NO")}
        for name, (key, value) in cases.items():
            with self.subTest(name=name):
                profile = copy.deepcopy(self.profile); profile[key] = value
                with self.assertRaises((subject.QualificationError, ValueError)): self.claims(profile)
        for name, key, value in [("wildcard app", subject.APP_ID_KEY, "ZZZZZZZZZZ.*"),
                                 ("other app", subject.APP_ID_KEY, "ZZZZZZZZZZ.io.tonebox.other"),
                                 ("debug", "get-task-allow", True),
                                 ("missing domain", subject.DOMAIN_KEY, []),
                                 ("wrong environment", subject.DOMAIN_KEY, ["applinks:batonmusic.app?mode=developer"])]:
            with self.subTest(name=name):
                profile = copy.deepcopy(self.profile); profile["Entitlements"][key] = value
                with self.assertRaises(subject.QualificationError): self.claims(profile)

    def testSourceIdentityConflictAndUnreviewedRestrictedClaimsFail(self):
        for key, value in [(subject.APP_ID_KEY, subject.PHONE_APP_ID),
                           ("keychain-access-groups", ["ZZZZZZZZZZ.unreviewed"]),
                           ("com.apple.security.get-task-allow", True)]:
            with self.subTest(key=key):
                source = dict(self.source); source[key] = value
                with self.assertRaises(subject.QualificationError): self.claims(source=source)

    def testCertificateInspectorRequiresDeveloperIDTeamOIDAndCurrentDates(self):
        valid_subject = "subject=\n CN = Developer ID Application: Synthetic Owner (Q8822GNL2H)\n OU = Q8822GNL2H\n"
        valid_dates = "notBefore=Jan  1 00:00:00 2020 GMT\nnotAfter=Jan  1 00:00:00 2040 GMT\n"
        valid_text = "1.2.840.113635.100.6.1.13: Developer ID Application"
        cases = [(valid_subject, valid_dates, valid_text, True),
                 (valid_subject.replace("Developer ID Application", "Developer ID Installer"), valid_dates, valid_text, False),
                 (valid_subject.replace("OU = Q8822GNL2H", "OU = OTHERTEAM1"), valid_dates, valid_text, False),
                 (valid_subject.replace("Owner (Q8822GNL2H)", "Owner (OTHERTEAM1)"), valid_dates, valid_text, False),
                 (valid_subject.replace("Synthetic Owner", "Synthetic // Owner"), valid_dates, valid_text, False),
                 (valid_subject, valid_dates.replace("2040", "2021"), valid_text, False),
                 (valid_subject, valid_dates.replace("2020", "2030"), valid_text, False),
                 (valid_subject, valid_dates, "other-extension", False)]
        for index, (cert_subject, cert_dates, text, accepted) in enumerate(cases):
            with self.subTest(case=index), patch.object(subject, "run", side_effect=[cert_subject.encode(), cert_dates.encode(), text.encode()]):
                if accepted:
                    self.assertEqual(subject.check_certificate(self.cert_path, "Q8822GNL2H", self.now),
                                     "Developer ID Application: Synthetic Owner (Q8822GNL2H)")
                else:
                    with self.assertRaises(subject.QualificationError): subject.check_certificate(self.cert_path, "Q8822GNL2H", self.now)

    def testMixtapeAssociationIsExactAndCannotBroadenTheReviewedRoutes(self):
        aasa = copy.deepcopy(self.aasa)
        rules = aasa["applinks"]["details"][0]["components"]
        rules[:] = [{"?": {"web": "1"}, "exclude": True}, {"/": "/s/*"}, {"/": "/m/*"}]
        subject.check_aasa(aasa, "ZZZZZZZZZZ.io.tonebox.baton")
        for name in ["broad", "query", "excluded", "extra", "reordered"]:
            with self.subTest(name=name):
                changed = copy.deepcopy(aasa)
                components = changed["applinks"]["details"][0]["components"]
                if name == "broad": components[2]["/"] = "/*"
                if name == "query": components[2]["?"] = {"key": "*"}
                if name == "excluded": components[2]["exclude"] = True
                if name == "extra": components.append({"/": "/unreviewed/*"})
                if name == "reordered": components[0], components[2] = components[2], components[0]
                with self.assertRaises(subject.QualificationError):
                    subject.check_aasa(changed, "ZZZZZZZZZZ.io.tonebox.baton")

    def testAASARequiresExactQualifiedIdentityAndBrowserExclusion(self):
        subject.check_aasa(self.aasa, "ZZZZZZZZZZ.io.tonebox.baton")
        for name in ["missing Mac", "unrelated app", "no exclusion", "wrong path", "fragment", "extra query"]:
            with self.subTest(name=name):
                aasa = copy.deepcopy(self.aasa); detail = aasa["applinks"]["details"][0]
                if name == "missing Mac": detail["appIDs"] = [subject.PHONE_APP_ID]
                if name == "unrelated app": detail["appIDs"].append("AAAAAAAAAA.io.tonebox.other")
                if name == "no exclusion": detail["components"][0]["exclude"] = False
                if name == "wrong path": detail["components"][1]["/"] = "/*"
                if name == "fragment": detail["components"][1]["#"] = "*"
                if name == "extra query": detail["components"][1]["?"] = {"unexpected": "1"}
                with self.assertRaises(subject.QualificationError): subject.check_aasa(aasa, "ZZZZZZZZZZ.io.tonebox.baton")

    def testMissingInputsStopBeforeAnyInspectorOrSnapshot(self):
        for name in set(self.env) - {"MAC_ASSOCIATION_CERTIFICATE_FILE"}:
            with self.subTest(name=name), patch.object(subject, "run") as inspector:
                env = dict(self.env); del env[name]
                with self.assertRaises(subject.QualificationError): self.preflight(env)
                inspector.assert_not_called()
                self.assertFalse((self.work / "state.json").exists())

    def testLeafComesFromTheApprovedProfileByPinnedHashWhenNoFileIsGiven(self):
        env = dict(self.env); del env["MAC_ASSOCIATION_CERTIFICATE_FILE"]
        state = self.preflight(env)
        self.assertEqual(Path(state["certificate"]).read_bytes(), self.cert)
        self.profile["DeveloperCertificates"] = [b"another-leaf"]
        with self.assertRaises(subject.QualificationError): self.preflight(env)

    def testWrongPinnedProfileHashFailsBeforeInspection(self):
        with patch.object(subject, "run") as inspector:
            env = dict(self.env); env["MAC_ASSOCIATION_PROFILE_SHA256"] = "0" * 64
            with self.assertRaises(subject.QualificationError): subject.preflight(self.source_path, self.aasa_path, self.work, env)
            inspector.assert_not_called()

    def testWrongCertificateOrSigningIdentityFailsClosed(self):
        for env_change in [{"MAC_ASSOCIATION_CERTIFICATE_SHA256": "0" * 64},
                           {"MAC_ASSOCIATION_CERTIFICATE_SHA256": "0" * 64, "MAC_ASSOCIATION_CERTIFICATE_FILE": ""},
                           {"SIGN_ID": "Developer ID Application: Someone Else (Q8822GNL2H)"},
                           {"SIGN_ID": "0" * 40}]:
            with self.subTest(change=env_change):
                env = dict(self.env); env.update(env_change)
                with self.assertRaises(subject.QualificationError): self.preflight(env)
                self.assertFalse((self.work / "state.json").exists())

    def testSigningIdentityMayBeTheLeafsFullNameAndBuildsWithIt(self):
        env = dict(self.env); env["SIGN_ID"] = self.signer
        self.preflight(env)
        self.assertIn("CODE_SIGN_IDENTITY = " + self.signer + "\n", (self.work / "association.xcconfig").read_text())

    def testCoreOnlySourceDoesNotReadProfileCertificateOrKeychain(self):
        core = dict(self.source); del core[subject.DOMAIN_KEY]
        self.source_path.write_bytes(plistlib.dumps(core))
        with patch.object(subject, "run") as inspector:
            state = subject.preflight(self.source_path, self.aasa_path, self.work, {})
            inspector.assert_not_called()
        self.assertFalse(state["associated"])
        self.assertEqual(state["claims"], core)
        self.assertFalse((self.work / "approved.provisionprofile").exists())

    def testEmptyAssociationIsNotASilentCoreOnlyBypass(self):
        self.source[subject.DOMAIN_KEY] = []
        self.source_path.write_bytes(plistlib.dumps(self.source))
        with self.assertRaises(subject.QualificationError): self.preflight({})

    def testPrivateSnapshotsPinApprovedBytesAndManualBuildIdentity(self):
        state = self.preflight()
        self.assertTrue(state["associated"])
        self.assertEqual((self.work / "approved.provisionprofile").read_bytes(), self.profile_path.read_bytes())
        claims = plistlib.loads((self.work / "signing.entitlements").read_bytes())
        self.assertEqual(claims, self.claims())
        settings = (self.work / "association.xcconfig").read_text()
        self.assertIn("CODE_SIGN_STYLE = Manual", settings)
        self.assertIn("BATON_MAC_RELEASE_PROFILE = " + self.profile["UUID"], settings)
        self.assertNotIn("PROVISIONING_PROFILE", settings)  # package targets refuse a profile
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO", settings)
        self.assertNotIn("CODE_SIGNING_ALLOWED", settings)
        self.assertEqual((self.work / "state.json").stat().st_mode & 0o777, 0o600)

    def testSnapshotsSourceAndAASACannotChangeAfterPreflight(self):
        state = self.preflight()
        targets = [self.source_path, self.aasa_path, Path(state["profile"]), Path(state["certificate"]),
                   self.work / "signing.entitlements", self.work / "association.xcconfig"]
        for target in targets:
            with self.subTest(target=target.name):
                original = target.read_bytes(); target.write_bytes(b"changed")
                with self.assertRaises((subject.QualificationError, plistlib.InvalidFileException)):
                    subject.load_state(self.work)
                target.write_bytes(original)

    def make_app(self, state):
        app = self.root / "Baton.app"; (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": subject.BUNDLE_ID}))
        (app / "Contents/embedded.provisionprofile").write_bytes(self.profile_path.read_bytes())
        return app

    def fake_inspector(self, claims, certificate=None):
        def inspect(arguments):
            if "--entitlements" in arguments: return plistlib.dumps(claims)
            extraction = next((argument for argument in arguments if argument.startswith("--extract-certificates=")), None)
            if extraction:
                prefix = extraction.split("=", 1)[1]
                Path(prefix + "0").write_bytes(self.cert if certificate is None else certificate)
            return b""
        return inspect

    def testActualSignedReadbackRequiresAppleAnchorAndExactLeaf(self):
        state = self.preflight(); app = self.make_app(state)
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "decode_profile", return_value=self.profile), patch.object(subject, "run", side_effect=self.fake_inspector(state["claims"])) as inspector:
            subject.verify_app(self.work, app)
            requirement = next(argument for call in inspector.call_args_list for argument in call.args[0] if argument.startswith("-R="))
            self.assertIn("anchor apple generic", requirement)
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "decode_profile", return_value=self.profile), patch.object(subject, "run", side_effect=self.fake_inspector(state["claims"], b"wrong-leaf")):
            with self.assertRaises(subject.QualificationError): subject.verify_app(self.work, app)

    def testDroppedIdentityWrongDomainsAndProfileReplacementRejectArtifact(self):
        state = self.preflight(); app = self.make_app(state)
        for key in [subject.APP_ID_KEY, subject.TEAM_KEY, subject.DOMAIN_KEY]:
            with self.subTest(key=key):
                actual = dict(state["claims"]); del actual[key]
                with patch.object(subject, "load_state", return_value=state), patch.object(subject, "run", side_effect=self.fake_inspector(actual)):
                    with self.assertRaises(subject.QualificationError): subject.verify_app(self.work, app)
        (app / "Contents/embedded.provisionprofile").write_bytes(b"replacement")
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "decode_profile", return_value=self.profile), patch.object(subject, "run", side_effect=self.fake_inspector(state["claims"])):
            with self.assertRaises(subject.QualificationError): subject.verify_app(self.work, app)

    def testResumeValidatesGeneratedClaimsWithoutPriorTemporaryState(self):
        self.profile["Entitlements"]["keychain-access-groups"] = ["ZZZZZZZZZZ.*"]
        state = self.preflight(); app = self.make_app(state)
        artifact_claims = dict(state["claims"])
        artifact_claims["keychain-access-groups"] = ["ZZZZZZZZZZ.io.tonebox.baton"]
        artifact_claims["com.apple.security.get-task-allow"] = False
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "decode_profile", return_value=self.profile), patch.object(subject, "run", side_effect=self.fake_inspector(artifact_claims)):
            subject.verify_app(self.work, app)
        self.assertNotIn("keychain-access-groups", state["claims"])

    def testPreparePreservesXcodeIdentityAndRejectsGeneratedClaimLoss(self):
        state = self.preflight(); app = self.make_app(state)
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "decode_profile", return_value=self.profile), patch.object(subject, "run", side_effect=self.fake_inspector(state["claims"])):
            subject.prepare_app(self.work, app)
        actual = dict(state["claims"]); del actual[subject.APP_ID_KEY]
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "run", side_effect=self.fake_inspector(actual)):
            with self.assertRaises(subject.QualificationError): subject.prepare_app(self.work, app)
        (app / "Contents/embedded.provisionprofile").write_bytes(b"wrong-generated-profile")
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "decode_profile", return_value=self.profile), patch.object(subject, "run", side_effect=self.fake_inspector(state["claims"])):
            with self.assertRaises(subject.QualificationError): subject.prepare_app(self.work, app)

    def testValidatedGeneratedSelfKeychainGroupAndFalseDebugClaimSurviveResign(self):
        self.profile["Entitlements"]["keychain-access-groups"] = ["ZZZZZZZZZZ.*"]
        state = self.preflight(); app = self.make_app(state)
        generated = dict(state["claims"])
        generated["keychain-access-groups"] = ["ZZZZZZZZZZ.io.tonebox.baton"]
        generated["com.apple.security.get-task-allow"] = False
        with patch.object(subject, "load_state", return_value=state), patch.object(subject, "decode_profile", return_value=self.profile), patch.object(subject, "run", side_effect=self.fake_inspector(generated)):
            subject.prepare_app(self.work, app)
        self.assertEqual(plistlib.loads((self.work / "signing.entitlements").read_bytes()), generated)
        self.assertEqual(json.loads((self.work / "state.json").read_bytes())["claims"], generated)
        for bad in [["OTHERTEAM1.io.tonebox.baton"], ["ZZZZZZZZZZ.*"], []]:
            changed = dict(generated); changed["keychain-access-groups"] = bad
            with self.subTest(group=bad), self.assertRaises(subject.QualificationError):
                subject.profile_claims(self.profile, changed, self.cert, self.now)
        new_state = dict(state); new_state["claims"] = self.claims()
        wrong_group = dict(generated); wrong_group["keychain-access-groups"] = ["ZZZZZZZZZZ.other-app"]
        with patch.object(subject, "load_state", return_value=new_state), patch.object(subject, "run", side_effect=self.fake_inspector(wrong_group)):
            with self.assertRaises(subject.QualificationError): subject.prepare_app(self.work, app)

    def testCLITrueNonzeroExitWithoutProfileInputs(self):
        result = subprocess.run(["python3", str(Path(subject.__file__)), "preflight", "--workspace", str(self.work),
                                 "--source-entitlements", str(self.source_path), "--aasa", str(self.aasa_path)],
                                env={"PATH": os.environ["PATH"]}, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"explicit approved profile", result.stderr)

    def testPublisherWiresPreflightSigningDMGAndBothResumeChecks(self):
        source = Path(__file__).with_name("publish.sh").read_text()
        self.assertLess(source.index("mac_association_signing.py preflight"), source.index('CLEAN=1 "$(dirname "$0")/test.sh"'))
        self.assertIn('mac_association_verify "$mp/Baton.app" || rc=1', source)
        self.assertIn('mac_association_verify "$VERIFY_MP/Baton.app"', source)
        self.assertIn('resume_assert_stapled_dmg "from the stapled DMG"', source)
        self.assertIn('resume_assert_stapled_dmg "before publishing"', source)
        self.assertIn('resume_assert_stapled_dmg "before publishing the qualified DMG"', source)
        self.assertIn('SIGN_ARGS=(--force --options runtime --timestamp)', source)
        self.assertNotIn("-allowProvisioningUpdates", source)


if __name__ == "__main__":
    unittest.main()
