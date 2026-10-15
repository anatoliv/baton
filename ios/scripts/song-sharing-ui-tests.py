#!/usr/bin/env python3
"""Run isolated song-sharing UI tests and report authoritative result counts.

Generate ios/BatonMobile.xcodeproj, create fixtures with song-sharing-fixture.py,
and reserve a fresh simulator. Synthetic secrets temporarily enter only the
private generated scheme; they are never passed in subprocess arguments.
"""
import argparse
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--simulator", required=True, help="a fresh simulator reserved for this test")
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--only", default="SongSharingFlowUITests")
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1] / "BatonMobile.xcodeproj")
    args = parser.parse_args()
    os.umask(0o077)
    args.derived_data.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.derived_data.chmod(0o700)
    if args.fixture.stat().st_mode & 0o077:
        parser.error("fixture secrets must be mode 0600")
    environment = json.loads(args.fixture.read_text())["environment"]
    for key in ("SONG_SHARING_NAV_URL", "SONG_SHARING_SHARE_URL", "SONG_SHARING_MODEL_URL"):
        url = urllib.parse.urlsplit(environment[key])
        if url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost", "::1"):
            parser.error("this suite permits only local synthetic fixtures")
    scheme = args.project / "xcshareddata/xcschemes/BatonMobile.xcscheme"
    original = scheme.read_bytes()
    original_mode = scheme.stat().st_mode & 0o777
    tree = ET.fromstring(original)
    action = tree.find("TestAction")
    if action is None:
        parser.error("cannot identify the phone UI test action")
    action.set("shouldUseLaunchSchemeArgsEnv", "NO")
    for previous in action.findall("EnvironmentVariables"):
        action.remove(previous)
    variables = ET.SubElement(action, "EnvironmentVariables")
    for key, value in environment.items():
        ET.SubElement(variables, "EnvironmentVariable", key=key, value=value, isEnabled="YES")
    # Preserve normal simulator code signing: an unsigned phone app cannot use
    # its keychain entitlement (-34018), which blocks the real synthetic login.
    # This .xcodeproj is generated/ignored. Restore it even when the run fails.
    scheme.chmod(0o600)
    scheme.write_bytes(ET.tostring(tree, encoding="utf-8", xml_declaration=True))
    args.results.parent.mkdir(parents=True, exist_ok=True)
    log_path = args.results.with_suffix(".log")
    try:
        with log_path.open("w") as log:
            # Complete the dedicated simulator's boot before the first app login.
            # xcodebuild's implicit boot can launch before its Keychain is ready.
            boot = subprocess.run(["xcrun", "simctl", "boot", args.simulator], stdout=log, stderr=log)
            if boot.returncode not in (0, 149):
                return boot.returncode
            ready = subprocess.run(["xcrun", "simctl", "bootstatus", args.simulator, "-b"],
                                   stdout=log, stderr=log, timeout=90)
            if ready.returncode:
                return ready.returncode
            process = subprocess.Popen(["xcodebuild", "-project", str(args.project), "-scheme", "BatonMobile",
                                     "-configuration", "Debug", "-derivedDataPath", str(args.derived_data),
                                     "-destination", "platform=iOS Simulator,id=" + args.simulator,
                                     "-only-testing:BatonMobileUITests/" + args.only, "-parallel-testing-enabled", "NO",
                                     "-test-timeouts-enabled", "YES", "-collect-test-diagnostics", "never", "-maximum-test-execution-time-allowance", "180",
                                     "-resultBundlePath", str(args.results), "test"],
                                    stdout=log, stderr=log, start_new_session=True)
            try:
                rc = process.wait(timeout=420)
            except subprocess.TimeoutExpired:
                # Stop only this fixture's process group; preserve logs and the real failure.
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                rc = 124
    finally:
        scheme.write_bytes(original)
        scheme.chmod(original_mode)
    summary = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(args.results)],
                             capture_output=True, text=True)
    if summary.returncode:
        print(json.dumps({"rc": rc, "counts": "unavailable", "result_bundle": str(args.results), "log": str(log_path)}))
        return rc or 1
    counts = json.loads(summary.stdout)
    print(json.dumps({"rc": rc, "passed": counts.get("passedTests", 0),
                      "failed": counts.get("failedTests", 0), "skipped": counts.get("skippedTests", 0),
                      "result_bundle": str(args.results), "log": str(log_path)}))
    return rc if rc else (0 if counts.get("passedTests", 0) > 0 else 1)


if __name__ == "__main__":
    sys.exit(main())
