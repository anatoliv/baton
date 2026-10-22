#!/usr/bin/env python3
"""Prepared bounded real-composer acceptance; --run requires a reserved native window."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import secrets
import signal
import subprocess
import sys
import time
from urllib.parse import urlencode, urlparse
from incoming_fixture_lifecycle import FixtureTimeout, write_receipt, write_failure
from mixtape_owned_lifecycle import CustodyDeadline as Deadline, cleanup_qualified, best_effort, retain_custody
from mixtape_simulator_teardown import BoundedTeardownFixture as OwnedFixture
from incoming_fixture_packages import copy_cache, offline_environment
from mixtape_composer_observer import ComposerObserver

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("fixture", REPO / "scripts/probe-share-fixture.py")
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
BOUNDARY_CASE = "testExactlyTwentyMinutesCreatesOneOrderedContainer"
DURATION_REFUSAL_CASE = "MixtapeSelectionLimitTests/testTwentyMinutesPlusOneSecondRefusesBeforeCredentialsOrNetwork"
DEFAULT_CASES = ["testSelectionOrderingRemovalAndPrivateConsentCreateOneContainer",
                 "testInterruptedUploadFreezesDraftAndExplicitRetryKeepsOneContainer"]
CASES = DEFAULT_CASES + [BOUNDARY_CASE]


def actual_cases(tree):
    pending, cases = list(tree.get("testNodes", [])), []
    while pending:
        node = pending.pop(); pending.extend(node.get("children", []))
        if node.get("nodeType") != "Test Case": continue
        parts = urlparse(node.get("nodeIdentifierURL", "")).path.strip("/").split("/")
        cases.append({"target": parts[1] if len(parts) >= 2 else "unknown",
                      "case": node.get("nodeIdentifier", "").removesuffix("()"), "result": node.get("result", "unknown")})
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ["source", "output", "share-bin", "share-bin-sha256", "package-cache", "package-pins", "navidrome-image"]:
        parser.add_argument("--" + key, required=True)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--include-duration-refusal", action="store_true",
                        help="Also run the single public 1201-second app-unit refusal in this SDK batch")
    parser.add_argument("--only-test", action="append", choices=CASES)
    args = parser.parse_args(); selection = list(dict.fromkeys(args.only_test or DEFAULT_CASES))
    if BOUNDARY_CASE in selection and len(selection) != 1:
        parser.error("The 1200-second boundary uses its own three 400-second tracks; select it alone")
    track_seconds = 400 if BOUNDARY_CASE in selection else 3
    unit_selection = [DURATION_REFUSAL_CASE] if args.include_duration_refusal else []
    if not args.run:
        print("Prepared only; no services, simulator or native build started."); return 0
    f.require(Path("/tmp/baton-probe.lock/owner").read_text().split()[0] == str(os.getppid()), "Normal lock-owning wrapper required")
    quiet = subprocess.run(["/usr/bin/pgrep", "-x", "xcodebuild"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    f.require(quiet.returncode == 1, "Native quiet preflight refused; no override")
    current = subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD"]).decode().strip()
    f.require(len(args.source) == 40 and current == args.source, "Immutable source pin mismatch")
    f.require(subprocess.run(["git", "-C", str(REPO), "diff", "--quiet", "HEAD"]).returncode == 0, "Clean source required")
    binary = Path(args.share_bin).resolve()
    f.require(binary.name == "baton-share-fixture" and binary.is_file() and
              hashlib.sha256(binary.read_bytes()).hexdigest() == args.share_bin_sha256,
              "Exact independently accepted loopback runner required")
    root = Path(args.output).resolve()
    f.require(root.parent == Path("/private/tmp") and not root.exists(), "Fresh disposable output required")
    os.umask(0o077); root.mkdir(mode=0o700)
    deadline = Deadline(); env = f.clean_environment(root)
    owned = OwnedFixture(root, env, deadline); deadline.arm()
    def stop(_signum, _frame): best_effort(write_receipt,root.with_name(root.name+'.cancel-requested'), {'requested':True})
    for name in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]: signal.signal(name, stop)
    result, observer = 1, None
    stage, operation = 'setup', 'command'
    def cache_phase(value):
        nonlocal operation
        operation = value  # copy_cache emits only its fixed phase identifiers.
    def command(argv, cap=120):
        nonlocal operation
        if stage == 'cache' and len(argv) > 3 and argv[0] == 'git':
            operation = {'rev-parse':'cache-head', 'diff':'cache-diff', 'show':'manifest-read'}.get(argv[3], 'command')
        return owned.command(argv, cap=cap, stdout_only=stage == 'cache')[0]
    def local_request(url, body=None):
        from urllib.request import Request
        f.require(url.startswith("http://127.0.0.1:"), "Only owned loopback HTTP allowed")
        headers = {"Content-Type": "application/json"} if body is not None else {}
        with f.OPENER.open(Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers),
                           timeout=deadline.remaining(5)) as response:
            data = response.read(512_001); f.require(len(data) <= 512_000, "Bounded fixture response required")
            return data
    try:
        stage, operation = 'cache', 'cache-validation'
        cache = root / "package-cache"
        pins, cache_receipt = copy_cache(args.package_cache, args.package_pins, cache, REPO, command, on_phase=cache_phase)
        write_receipt(root / "source.json", {"commit": current, "runnerSHA256": args.share_bin_sha256,
            "cache": cache_receipt, "selectedCases": selection,
            "selectedAppUnitCases": unit_selection,
            "fixtureTrackDurationSeconds": track_seconds,
            "scope": "Real composer selection/upload/retry and optional public duration refusal; no media, device, association or production capacity acceptance",
            "originAdaptation": "Only canonical owned backend CreateMixtapeResponse.url maps to the owned observer origin; upload paths unchanged"})
        stage, operation = 'media', 'media-generate'
        for name in ["music", "navidrome"]: (root / name).mkdir(mode=0o700)
        for index in range(3):
            title = "Mixtape Fixture " + chr(65 + index)
            command(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                "sine=frequency=" + str(330 + index * 110) + ":duration=" + str(track_seconds), "-metadata", "title=" + title,
                "-metadata", "artist=Synthetic Mixtape", "-metadata", "album=Owned Composer Fixture",
                "-b:a", "48k", str(root / "music" / (str(index) + ".mp3"))])
        stage, operation = 'service', 'service-start'
        navport, shareport = f.unused_ports(2)
        navbase, backend = "http://127.0.0.1:" + str(navport), "http://127.0.0.1:" + str(shareport)
        image_id = command(["docker", "image", "inspect", "--format", "{{.Id}}", args.navidrome_image]).decode().strip()
        f.require(image_id.startswith("sha256:") and len(image_id) == 71, "Existing image digest required")
        write_receipt(root / "navidrome-image.json", {"requested": args.navidrome_image, "imageID": image_id, "pullAllowed": False})
        owned.container_name = "baton-mixtape-composer-" + secrets.token_hex(12); owned.receipt()
        owned.container_id = command(["docker", "create", "--pull=never", "--name", owned.container_name,
            "-p", "127.0.0.1:" + str(navport) + ":4533", "-e", "ND_LOGLEVEL=error",
            "-v", str(root / "music") + ":/music:ro", "-v", str(root / "navidrome") + ":/data",
            args.navidrome_image]).decode().strip(); owned.receipt()
        f.require(len(owned.container_id) == 64 and all(c in "0123456789abcdef" for c in owned.container_id), "Owned container identity invalid")
        command(["docker", "start", owned.container_id])
        for _ in range(60):
            try: local_request(navbase + "/ping"); break
            except Exception: time.sleep(deadline.remaining(.5))
        else: raise f.FixtureFailure("Owned Navidrome readiness failed")
        stage, operation = 'catalog', 'catalog-read'
        username, password = "mixtape-probe", secrets.token_hex(24)
        local_request(navbase + "/auth/createAdmin", {"username": username, "password": password})
        def subsonic(endpoint, **values):
            salt = secrets.token_hex(8)
            query = dict(u=username, t=hashlib.md5((password + salt).encode()).hexdigest(), s=salt,
                         v="1.16.1", f="json", c="mixtape-composer-fixture", **values)
            return json.loads(local_request(navbase + "/rest/" + endpoint + "?" + urlencode(query)))["subsonic-response"]
        subsonic("startScan")
        for _ in range(60):
            songs = subsonic("search3", query="", songCount=10, albumCount=0, artistCount=0).get("searchResult3", {}).get("song", [])
            if sorted(s.get("title") for s in songs) == ["Mixtape Fixture A", "Mixtape Fixture B", "Mixtape Fixture C"]: break
            time.sleep(deadline.remaining(.5))
        else: raise f.FixtureFailure("Exact three-song catalog unavailable")
        if BOUNDARY_CASE in selection:
            f.require(all(song.get("duration") == 400 for song in songs), "Independent catalog must declare exactly 400 seconds per track")
        for song in songs: subsonic("star", id=song["id"])
        starred = subsonic("getStarred2").get("starred2", {}).get("song", [])
        f.require(len(starred) == 3, "Three independently starred synthetic tracks required")
        write_receipt(root / "catalog.json", songs)
        stage, operation = 'service', 'service-start'
        with (root / "fixture-service.log").open("wb") as log:
            service = owned.start([str(binary), str(root / "share-fixture"), str(shareport)], output=log)
        for _ in range(60):
            f.require(owned.running(service), "Owned fixture runner exited")
            try: local_request(backend + "/health"); break
            except Exception: time.sleep(deadline.remaining(.5))
        else: raise f.FixtureFailure("Owned share runner readiness failed")
        token = secrets.token_hex(32); observer = ComposerObserver(backend, token)
        write_receipt(root / "observer-ownership.json", {"address": "127.0.0.1", "base": observer.base, "closed": False})
        variables = dict(MIXTAPE_COMPOSER_FLOW_TESTS="1", MIXTAPE_COMPOSER_BASE=observer.base,
            MIXTAPE_COMPOSER_CONTROL_TOKEN=token, MIXTAPE_COMPOSER_NAV_URL=navbase,
            MIXTAPE_COMPOSER_NAV_USER=username, MIXTAPE_COMPOSER_NAV_SECRET=password)
        stage, operation = 'simulator', 'simulator-start'
        owned.simulator_name = "Baton Mixtape Composer " + secrets.token_hex(12); owned.receipt()
        owned.simulator = command(["xcrun", "simctl", "create", owned.simulator_name,
            "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"]).decode().strip(); owned.receipt()
        command(["xcrun", "simctl", "boot", owned.simulator]); command(["xcrun", "simctl", "bootstatus", owned.simulator, "-b"])
        previous = Path.cwd()
        try: os.chdir(REPO / "ios"); command(["xcodegen", "generate"])
        finally: os.chdir(previous)
        owned.snapshot_scheme(REPO / "ios/BatonMobile.xcodeproj/xcshareddata/xcschemes/BatonMobile.xcscheme")
        destination = REPO / "ios/BatonMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        destination.parent.mkdir(parents=True, exist_ok=True); destination.write_bytes(pins)
        common = ["-project", str(REPO / "ios/BatonMobile.xcodeproj"), "-scheme", "BatonMobile",
            "-destination", "platform=iOS Simulator,id=" + owned.simulator, "-derivedDataPath", str(root / "derived-data"),
            "-clonedSourcePackagesDirPath", str(cache), "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates"]
        stage, operation = 'sdk', 'sdk-build'
        with (root / "build.log").open("wb") as log:
            process = owned.start(["xcodebuild", "build-for-testing", *common, "-resultBundlePath", str(root / "build.xcresult")],
                                  childenv=offline_environment(env), output=log)
            owned.wait(process)
        write_receipt(root / "build-exit.json", {"exitCode": process.returncode})
        f.require(process.returncode == 0, "Owned composer SDK build failed")
        runs = list((root / "derived-data/Build/Products").glob("*.xctestrun")); f.require(len(runs) == 1, "One generated test run required")
        run = plistlib.loads(runs[0].read_bytes())
        targets = [t for c in run.get("TestConfigurations", []) for t in c["TestTargets"]] if "TestConfigurations" in run else [run["BatonMobileUITests"]]
        targets = [t for t in targets if t.get("BlueprintName", "BatonMobileUITests") == "BatonMobileUITests"]
        f.require(len(targets) == 1, "One UI target required")
        targets[0].setdefault("EnvironmentVariables", {}).update(variables)
        private_run = runs[0].with_name("MixtapeComposer.xctestrun"); private_run.write_bytes(plistlib.dumps(run)); private_run.chmod(0o600)
        stage, operation = 'ui', 'ui-tests'
        with (root / "tests.log").open("wb") as log:
            process = owned.start(["xcodebuild", "test-without-building", "-xctestrun", str(private_run),
                "-destination", "platform=iOS Simulator,id=" + owned.simulator,
                *["-only-testing:BatonMobileUITests/MixtapeComposerFlowUITests/" + case for case in selection],
                *["-only-testing:BatonMobileTests/" + case for case in unit_selection],
                "-collect-test-diagnostics", "never", "-resultBundlePath", str(root / "composer.xcresult")], output=log)
            owned.wait(process)
        write_receipt(root / "tests-exit.json", {"exitCode": process.returncode})
        stage, operation = 'ui', 'result-read'
        counts = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(root / "composer.xcresult")]))
        write_receipt(root / "counts.json", counts)
        tree = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(root / "composer.xcresult")]))
        write_receipt(root / "test-tree.json", tree)
        cases = actual_cases(tree)
        expected = {("BatonMobileUITests", "MixtapeComposerFlowUITests/" + case) for case in selection}
        expected.update(("BatonMobileTests", case) for case in unit_selection)
        expected_count = len(selection) + len(unit_selection)
        write_receipt(root / "selected-counts.json", {"expectedUITests": len(selection), "expectedAppUnitTests": len(unit_selection),
            "actualTotalTests": counts["totalTestCount"], "actualPassedTests": counts["passedTests"],
            "actualFailedTests": counts["failedTests"], "actualSkippedTests": counts["skippedTests"],
            "actualUITests": sum(case["target"] == "BatonMobileUITests" for case in cases),
            "actualAppUnitTests": sum(case["target"] == "BatonMobileTests" for case in cases), "cases": cases})
        f.require(process.returncode == 0 and counts["totalTestCount"] == expected_count and counts["passedTests"] == expected_count
                  and counts["failedTests"] == 0 and counts["skippedTests"] == 0
                  and len(cases) == expected_count and {(case["target"], case["case"]) for case in cases} == expected
                  and all(case["result"] == "Passed" for case in cases), "Actual composer cases failed, skipped or differed from selection")
        result = 0
    except (Exception, FixtureTimeout, KeyboardInterrupt) as error:
        write_failure(root / "failure.json", error, stage, operation)
    finally:
        closed=observer is None
        try:
            if observer: closed=observer.close()
        except BaseException: closed=False
        best_effort(write_receipt,root/'observer-ownership.json',{'closed':closed})
        cleanup=None
        try:
            cleanup=owned.cleanup()
            if not closed:
                cleanup['failures'].append('owned composer observer not closed')
                best_effort(write_receipt,root/'incoming-cleanup.json',cleanup)
        except BaseException:
            best_effort(write_receipt,root/'cleanup-failure.json',{'qualified':False,'privateDetailsWithheld':True})
        if cleanup is None or not cleanup_qualified(cleanup): retain_custody(root,deadline)
        deadline.disarm()
        write_receipt(root / "result.json", {"exitCode": result, "commit": current, "scope": "Composer and selected duration-refusal check; no media/device/association/capacity qualification"})
        write_receipt(root/'native-custody-release.json',{'qualified':True})
    print("Baton composer fixture receipt:", root / "result.json"); return result


if __name__ == "__main__": sys.exit(main())
