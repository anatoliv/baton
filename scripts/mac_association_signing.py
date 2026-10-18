#!/usr/bin/env python3
"""Fail-closed, local Mac association release checks. Never discovers credentials/profiles."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid

DOMAINS = ["applinks:batonmusic.app", "applinks:baton.tonebox.io"]
PHONE_APP_ID = "Q8822GNL2H.io.tonebox.baton"  # Verified phone identity, not a Mac prefix inference.
BUNDLE_ID = "io.tonebox.baton"
EXPECTED_TEAM_ID = "Q8822GNL2H"  # Independently verified owner team, never used to derive App ID.
APP_ID_KEY = "com.apple.application-identifier"
TEAM_KEY = "com.apple.developer.team-identifier"
DOMAIN_KEY = "com.apple.developer.associated-domains"
CORE_KEYS = {"com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.network.server"}
MAX_INPUT = 4 * 1024 * 1024


class QualificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise QualificationError(message)


def read(path, limit=MAX_INPUT):
    with Path(path).open("rb") as file:
        data = file.read(limit + 1)
    require(len(data) <= limit, "qualification input exceeds size limit")
    return data


def digest(data):
    return hashlib.sha256(data).hexdigest()


def decode_profile(path):
    # Checks the CMS signature over the profile and reads its payload without any keychain.
    # (`security cms -D -k <System.keychain>` tried to import the signer into that keychain and
    # failed without root on the first real profile; the login keychain is never consulted.)
    # Chain trust is not decided here: Apple's own checks at build, sign and launch do that.
    return plistlib.loads(run(["/usr/bin/openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)]))


def write_private(path, data):
    with open(path, "wb") as file:
        os.fchmod(file.fileno(), 0o600)
        file.write(data)


def check_workspace(workspace):
    workspace = Path(workspace)
    require(workspace.is_dir() and workspace.stat().st_uid == os.getuid() and workspace.stat().st_mode & 0o077 == 0,
            "qualification workspace must be private and owned by this user")


def run(arguments):
    # Only local inspectors, explicit files and bounded execution. Raw output/errors never logged.
    try:
        result = subprocess.run(arguments, capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise QualificationError("local signing inspector unavailable or timed out") from error
    require(result.returncode == 0, "local signing inspector rejected qualification")
    require(len(result.stdout) <= MAX_INPUT, "local signing inspector output exceeds size limit")
    return result.stdout


def check_aasa(aasa, mac_app_id=None):
    details = aasa.get("applinks", {}).get("details", [])
    require(len(details) == 1, "association must have exactly one reviewed route entry")
    expected = {PHONE_APP_ID}
    if mac_app_id:
        require(re.fullmatch(r"[A-Z0-9]{10}\.io\.tonebox\.baton", mac_app_id), "invalid exact Mac App ID")
        expected.add(mac_app_id)
    ids = details[0].get("appIDs", [])
    require(isinstance(ids, list) and len(ids) == len(expected) and set(ids) == expected,
            "AASA must contain verified phone and exact qualified Mac identities only")
    rules = details[0].get("components", [])
    require(len(rules) == 3 and rules[0].get("?") == {"web": "1"} and rules[0].get("exclude") is True,
            "browser exclusion must precede association")
    require(set(rules[0]) <= {"?", "exclude", "comment"} and
            all(set(rule) <= {"/", "comment"} for rule in rules[1:]),
            "AASA route constraints differ from the reviewed contract")
    require([rule.get("/") for rule in rules[1:]] == ["/s/*", "/m/*"], "only exact song and mixtape routes are associated")
    require("#" not in json.dumps(aasa), "association must not contain fragment keys")


def utc(value):
    require(isinstance(value, dt.datetime), "profile validity date is missing")
    return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value.astimezone(dt.timezone.utc)


def authorized_groups(groups, allowances):
    return (isinstance(groups, list) and 0 < len(groups) <= 8 and isinstance(allowances, list)
            and all(isinstance(group, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,255}", group)
                    and any(isinstance(pattern, str) and (pattern == group or
                            (pattern.endswith("*") and pattern.count("*") == 1 and group.startswith(pattern[:-1])))
                            for pattern in allowances) for group in groups))


def profile_claims(profile, source, certificate, now):
    require(profile.get("Platform") in (["OSX"], ["macOS"]), "profile is not exclusively macOS")
    require(profile.get("ProvisionsAllDevices") is True and not profile.get("ProvisionedDevices"),
            "an all-computers Developer ID distribution profile is required")
    require(utc(profile.get("CreationDate")) <= now < utc(profile.get("ExpirationDate")), "profile is not currently valid")
    require(isinstance(profile.get("UUID"), str) and re.fullmatch(r"[A-Fa-f0-9-]{36}", profile["UUID"]), "profile UUID is missing or malformed")
    require(str(uuid.UUID(profile["UUID"])).lower() == profile["UUID"].lower(), "profile UUID is not canonical")
    allowed = profile.get("Entitlements", {})
    app_id = allowed.get(APP_ID_KEY)
    require(isinstance(app_id, str) and re.fullmatch(r"[A-Z0-9]{10}\.io\.tonebox\.baton", app_id),
            "profile needs an exact Mac application identifier, not a wildcard or phone identifier")
    prefix = app_id.split(".", 1)[0]
    require(profile.get("ApplicationIdentifierPrefix") == [prefix], "profile App ID prefix disagrees with its exact App ID")
    team = allowed.get(TEAM_KEY)
    require(isinstance(team, str) and re.fullmatch(r"[A-Z0-9]{10}", team) and profile.get("TeamIdentifier") == [team],
            "profile team identifiers disagree")
    require(team == EXPECTED_TEAM_ID, "profile is not for the reviewed Baton developer team")
    require(allowed.get("get-task-allow", False) is False and allowed.get("com.apple.security.get-task-allow", False) is False,
            "development/debug profile is not a Developer ID release profile")
    require(certificate in profile.get("DeveloperCertificates", []), "approved signing leaf is not authorized by profile")
    domains = source.get(DOMAIN_KEY)
    require(domains == DOMAINS, "source must request exactly the two reviewed applinks domains")
    authorization = allowed.get(DOMAIN_KEY, [])
    # Apple's Developer ID profiles grant the capability as the plain string "*".
    require(authorization == "*" or (isinstance(authorization, list) and
                                     all(domain in authorization or "*" in authorization for domain in domains)),
            "profile does not authorize every requested associated domain")
    claims = dict(source)
    for key, value in [(APP_ID_KEY, app_id), (TEAM_KEY, team)]:
        require(key not in claims or claims[key] == value, "source identity conflicts with exact profile identity")
        claims[key] = value
    # Preserve reviewed source claims only. Never copy arbitrary profile allowances into the app.
    for key, value in claims.items():
        if key in CORE_KEYS:
            require(type(value) is bool, "core security entitlement must be boolean")
        elif key == "com.apple.security.get-task-allow":
            require(value is False, "debug entitlement forbidden in release")
        elif key == "keychain-access-groups":
            require(authorized_groups(value, allowed.get(key)), "keychain group is not authorized by exact profile")
        elif key not in {APP_ID_KEY, TEAM_KEY, DOMAIN_KEY}:
            require(key in allowed and value == allowed[key], "additional restricted entitlement needs exact profile authorization")
    require(not claims.get("get-task-allow", False) and not claims.get("com.apple.security.get-task-allow", False),
            "debug entitlement forbidden in release")
    return claims


def check_certificate(path, team, now):
    subject = run(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", str(path), "-noout", "-subject", "-nameopt", "sep_multiline,sname,utf8"]).decode()
    common_name = re.search(r"^\s*CN\s*=\s*(Developer ID Application: [^\n]+?)\s*$", subject, re.M)
    require(common_name and re.fullmatch(r"Developer ID Application: [\w .,'&-]{1,120} \(" + re.escape(team) + r"\)", common_name[1]),
            "signing leaf is not a Developer ID Application certificate for this team")
    require(re.search(r"^\s*OU\s*=\s*" + re.escape(team) + r"\s*$", subject, re.M), "signing leaf team disagrees with profile")
    dates = run(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", str(path), "-noout", "-dates"]).decode().splitlines()
    values = dict(line.split("=", 1) for line in dates)
    def parse(value):
        return dt.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    require(parse(values["notBefore"]) <= now < parse(values["notAfter"]), "signing certificate is not currently valid")
    text = run(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", str(path), "-noout", "-text"]).decode()
    require("1.2.840.113635.100.6.1.13" in text, "Developer ID Application extension is missing")
    return common_name[1]


def preflight(source_path, aasa_path, workspace, environment):
    workspace = Path(workspace)
    check_workspace(workspace)
    source_data = read(source_path)
    source = plistlib.loads(source_data)
    require(isinstance(source, dict), "source entitlements must be a dictionary")
    state = {"associated": DOMAIN_KEY in source, "source": str(Path(source_path).resolve()),
             "sourceSHA256": digest(source_data), "aasa": str(Path(aasa_path).resolve()), "claims": source}
    if state["associated"]:
        names = ["MAC_ASSOCIATION_PROFILE_FILE", "MAC_ASSOCIATION_PROFILE_SHA256",
                 "MAC_ASSOCIATION_CERTIFICATE_SHA256", "SIGN_ID"]
        require(all(environment.get(name) for name in names), "associated-domain signing needs explicit approved profile file, profile and certificate hashes and SIGN_ID")
        profile_bytes = read(environment["MAC_ASSOCIATION_PROFILE_FILE"])
        require(re.fullmatch(r"[0-9a-fA-F]{64}", environment["MAC_ASSOCIATION_PROFILE_SHA256"]) and digest(profile_bytes) == environment["MAC_ASSOCIATION_PROFILE_SHA256"].lower(), "approved profile hash mismatch")
        require(re.fullmatch(r"[0-9a-fA-F]{64}", environment["MAC_ASSOCIATION_CERTIFICATE_SHA256"]), "approved certificate hash is malformed")
        profile_path = workspace / "approved.provisionprofile"
        cert_path = workspace / "approved.cer"
        write_private(profile_path, profile_bytes)
        # Decoding is inspection, not a substitute for Apple/OS profile trust or DER acceptance.
        profile = decode_profile(profile_path)
        if environment.get("MAC_ASSOCIATION_CERTIFICATE_FILE"):
            certificate = read(environment["MAC_ASSOCIATION_CERTIFICATE_FILE"], 65536)
        else:
            # The approved profile embeds its public signing leaf; select it by the pinned hash.
            leaves = [leaf for leaf in profile.get("DeveloperCertificates", [])
                      if isinstance(leaf, bytes) and digest(leaf) == environment["MAC_ASSOCIATION_CERTIFICATE_SHA256"].lower()]
            require(len(leaves) == 1, "approved certificate is not in the approved profile")
            certificate = leaves[0]
        require(digest(certificate) == environment["MAC_ASSOCIATION_CERTIFICATE_SHA256"].lower(), "approved certificate hash mismatch")
        write_private(cert_path, certificate)
        now = dt.datetime.now(dt.timezone.utc)
        claims = profile_claims(profile, source, certificate, now)
        name = check_certificate(cert_path, claims[TEAM_KEY], now)
        # SIGN_ID is the certificate's SHA1 or its full common name; either selects this leaf,
        # and the signed-artifact readback below proves which leaf actually signed.
        require(environment["SIGN_ID"].lower() == hashlib.sha1(certificate).hexdigest() or environment["SIGN_ID"] == name,
                "SIGN_ID must name or hash the exact approved leaf certificate")
        aasa_data = read(aasa_path)
        check_aasa(json.loads(aasa_data), claims[APP_ID_KEY])
        state.update(claims=claims, profileSHA256=digest(profile_bytes), certificateSHA256=digest(certificate),
                     profileUUID=profile["UUID"], profileExpiry=utc(profile["ExpirationDate"]).isoformat(),
                     profile=str(profile_path), certificate=str(cert_path), aasaSHA256=digest(aasa_data))
        # Xcode signs the nested product normally using an already installed exact profile.
        # No provisioning-update flag or installation/account mutation is performed here.
        # An -xcconfig reaches every target, and package targets refuse any profile, so the
        # UUID travels in a variable only the Baton target's Release configuration reads
        # (app/project.yml: PROVISIONING_PROFILE_SPECIFIER = $(BATON_MAC_RELEASE_PROFILE)).
        settings = (
            "CODE_SIGN_STYLE = Manual\nCODE_SIGN_IDENTITY = " + name + "\n"
            "DEVELOPMENT_TEAM = " + claims[TEAM_KEY] + "\n"
            # An `xcodebuild build` otherwise injects get-task-allow, which a Developer ID
            # release must not carry and which the qualification below refuses.
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO\n"
            "BATON_MAC_RELEASE_PROFILE = " + profile["UUID"] + "\n").encode()
        state["xcconfigSHA256"] = digest(settings)
        write_private(workspace / "association.xcconfig", settings)
    else:
        require(set(source) <= CORE_KEYS and all(type(value) is bool for value in source.values()),
                "core-only release cannot contain unqualified restricted entitlements")
    write_private(workspace / "state.json", json.dumps(state, sort_keys=True).encode())
    write_private(workspace / "signing.entitlements", plistlib.dumps(state["claims"]))
    print("associated" if state["associated"] else "core-only")
    return state


def load_state(workspace):
    check_workspace(workspace)
    state = json.loads(read(Path(workspace) / "state.json"))
    require(digest(read(state["source"])) == state["sourceSHA256"], "source entitlements changed after preflight")
    require(plistlib.loads(read(Path(workspace) / "signing.entitlements")) == state["claims"], "prepared entitlements changed after preflight")
    if state["associated"]:
        require(digest(read(Path(workspace) / "association.xcconfig")) == state["xcconfigSHA256"], "qualified build settings changed")
        require(digest(read(state["profile"])) == state["profileSHA256"], "approved profile snapshot changed")
        require(digest(read(state["certificate"])) == state["certificateSHA256"], "approved certificate snapshot changed")
        require(digest(read(state["aasa"])) == state["aasaSHA256"], "AASA source changed after preflight")
        profile = decode_profile(state["profile"])
        now = dt.datetime.now(dt.timezone.utc)
        claims = profile_claims(profile, state["claims"], read(state["certificate"]), now)
        require(claims == state["claims"], "profile authorization changed")
        check_certificate(state["certificate"], claims[TEAM_KEY], now)
        check_aasa(json.loads(read(state["aasa"])), claims[APP_ID_KEY])
    return state


def qualify_generated(state, generated):
    # Also used on resume, whose fresh preflight lacks the previous run's temporary state.
    require(all(key in generated and generated[key] == value for key, value in state["claims"].items()),
            "Xcode-generated entitlements differ from qualified release claims")
    extras = set(generated) - set(state["claims"])
    require(extras <= {"com.apple.security.get-task-allow", "keychain-access-groups"},
            "unreviewed generated restricted entitlement")
    if "keychain-access-groups" in extras:
        require(generated["keychain-access-groups"] == [state["claims"][APP_ID_KEY]],
                "generated keychain access may preserve only this exact app's self group")
    # Retain only narrowly recognized generated claims, still checked against this profile.
    profile = decode_profile(state["profile"])
    return profile_claims(profile, generated, read(state["certificate"]), dt.datetime.now(dt.timezone.utc))


def prepare_app(workspace, app):
    state = load_state(workspace)
    require(state["associated"], "profile preparation is only for associated-domain releases")
    require(plistlib.loads(read(Path(app) / "Contents/Info.plist"))["CFBundleIdentifier"] == BUNDLE_ID, "built bundle ID mismatch")
    # An Xcode-generated identity may not be discarded silently by the outer re-sign.
    generated = plistlib.loads(run(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)]))
    qualified = qualify_generated(state, generated)
    require(digest(read(Path(app) / "Contents/embedded.provisionprofile")) == state["profileSHA256"],
            "Xcode did not embed the exact approved profile")
    state["claims"] = qualified
    write_private(Path(workspace) / "signing.entitlements", plistlib.dumps(qualified))
    write_private(Path(workspace) / "state.json", json.dumps(state, sort_keys=True).encode())
    write_private(Path(app) / "Contents/embedded.provisionprofile", read(state["profile"]))


def verify_app(workspace, app):
    state = load_state(workspace)
    app = Path(app)
    require(plistlib.loads(read(app / "Contents/Info.plist"))["CFBundleIdentifier"] == BUNDLE_ID, "signed bundle ID mismatch")
    run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)])
    actual = plistlib.loads(run(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)]))
    expected = qualify_generated(state, actual) if state["associated"] else state["claims"]
    require(actual == expected, "actual signed entitlements differ from qualified claims")
    if state["associated"]:
        require(digest(read(app / "Contents/embedded.provisionprofile")) == state["profileSHA256"], "actual embedded profile differs from approved profile")
        team = state["claims"][TEAM_KEY]
        requirement = ('anchor apple generic and identifier "' + BUNDLE_ID + '" and '
                       'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
                       'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                       'certificate leaf[subject.OU] = "' + team + '"')
        # -R <argument> means a requirement FILE; -R=<argument> supplies inline source.
        run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, str(app)])
        with tempfile.TemporaryDirectory(prefix="baton-signing-leaf-") as temp:
            prefix = str(Path(temp) / "certificate")
            # This option's optional prefix must be attached, or it is parsed as an app path.
            run(["/usr/bin/codesign", "--display", "--extract-certificates=" + prefix, str(app)])
            require(digest(read(prefix + "0", 65536)) == state["certificateSHA256"], "actual signing leaf differs from approved certificate")
    print("Mac signing qualification passed (artifact readback; installed association unverified).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["preflight", "revalidate", "prepare", "verify"])
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--source-entitlements")
    parser.add_argument("--aasa")
    parser.add_argument("--app")
    args = parser.parse_args()
    try:
        if args.operation == "preflight":
            require(args.source_entitlements and args.aasa, "source entitlements and AASA paths required")
            preflight(args.source_entitlements, args.aasa, args.workspace, os.environ)
        elif args.operation == "revalidate":
            load_state(args.workspace)
        else:
            require(args.app, "app path required")
            (prepare_app if args.operation == "prepare" else verify_app)(args.workspace, args.app)
    except (QualificationError, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        # Never include raw inspector output, profile payloads or owner filesystem contents.
        print("Mac signing qualification refused: " + (str(error) if isinstance(error, QualificationError) else "malformed or unavailable qualification input"), file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
