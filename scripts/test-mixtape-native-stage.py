#!/usr/bin/env python3
"""Narrow SDK and app-hosted URLSession checks in an owned fresh simulator."""
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import stat
from pathlib import Path
import secrets
import signal
import subprocess
import sys
from incoming_fixture_lifecycle import FixtureTimeout, write_receipt
from mixtape_owned_lifecycle import CustodyDeadline as Deadline, ReservedOwnedFixture as OwnedFixture, cleanup_qualified, retain_custody
from incoming_fixture_packages import copy_cache, offline_environment

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("fixture", REPO / "scripts/probe-share-fixture.py")
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)
SELECTION = [
    "MixtapeBackgroundUploadTests/testOrderedFileDispatchHandsOffOnlyThisProtectedJob",
    "MixtapeBackgroundUploadTests/testLostResponseRelaunchKeepsOneContainerKeyAndReceipt",
    "MixtapeBackgroundUploadTests/testCorruptOwnerReadyResponseKeepsRecoverableTicketWithoutReceipt",
    "MixtapeBackgroundUploadTests/testCompletionReturnsMixtapeWhenSongUsesTheSameRawID",
    "BackgroundShareUploadEngineTests/testHandOffIsPerJobAfterDurabilityAndNotUnlockedByAnotherPendingUpload",
    "BackgroundShareUploadEngineTests/testUnmeasurableFinalizationRetainsKeyUntilNextLaunchResolvesIt",
    "BackgroundShareUploadTests/testLostFinalizeCommitReplaysWithoutDuplicateLedgerRows",
    "BackgroundShareUploadTests/testUnreadableTicketDoesNotBecomeAnOrphanOrDeleteItsPayload",
    "BackgroundShareUploadTests/testCorruptTicketAndInterruptedStagingAreOrphans",
]
OVERFLOW_CASE = "MixtapeSelectionLimitTests/testOverflowingDurationsRefuseBeforeCredentialsOrNetwork"
ADMISSION_CASE = "SharedMixtapeModelTests/testCanceledAdmissionCannotSpendAnotherPlayWithoutConfirmation"
MEDIA_CASE = "SharedMixtapeModelTests/testRealOrderedMediaRequiresFreshSessionAnalyticsAndReaction"
PREPARED_ADDITIONAL = [
    "SignedShareIntegrationTests/testSignedCreateUploadFinalizeAndSubsequentAssertion",
    "SignedShareIntegrationTests/testLostEnrollmentResponseReusesObjectAfterCoordinatorAndEngineReopen",
    "SignedShareIntegrationTests/testLostSignedCreateReplaysExactRequestAfterReopenWithoutDuplicateShare",
    "SignedShareIntegrationTests/testSupportedDeviceProofFailureNeverSendsUnsignedCreate",
    MEDIA_CASE,
    ADMISSION_CASE,
    "SharedMixtapeModelTests/testUnknownDeliveryRemainsChargedAndRenewalNeedsExplicitConfirmation",
    "SharedMixtapeModelTests/testLateAudioCannotRestoreSupersededTrackAndDoesNotReadmit",
    "MixtapeBackgroundUploadTests/testCorruptPendingOwnerResponseCannotMutateOrRedispatchProtectedJob",
    "MixtapeBackgroundUploadTests/testExplicitRetryReturnsTheContainerCompletedDuringRestore",
    OVERFLOW_CASE,
    "MixtapeSelectionLimitTests/testTwentyMinutesPlusOneSecondRefusesBeforeCredentialsOrNetwork",
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--package-cache", required=True)
    parser.add_argument("--package-pins", required=True)
    parser.add_argument("--media-fixture", help="Protected independent synthetic MP3 fixture; real-media case only")
    parser.add_argument("--only-test", action="append", choices=SELECTION + PREPARED_ADDITIONAL)
    args = parser.parse_args()
    selection = list(dict.fromkeys(args.only_test or SELECTION))
    if OVERFLOW_CASE in selection and len(selection) != 1:
        parser.error("The potentially crashing overflow reproduction must run alone")
    media = None
    if MEDIA_CASE in selection:
        if len(selection) != 1 or not args.media_fixture:
            parser.error("The real-media public regression runs alone with an explicit protected fixture")
        media = Path(args.media_fixture)
        if not media.is_absolute() or not media.is_relative_to('/private/tmp') or media != media.resolve():
            parser.error("The media fixture must have a canonical private temporary path")
        try:
            attrs = media.lstat()
            if not stat.S_ISREG(attrs.st_mode) or stat.S_IMODE(attrs.st_mode) != 0o600 or attrs.st_uid != os.getuid() or not 0 < attrs.st_size <= 1_048_576:
                parser.error("The media fixture must be owned, regular, 0600 and bounded")
        except OSError:
            parser.error("The protected media fixture is unavailable")
    elif args.media_fixture:
        parser.error("A media fixture may only accompany the single real-media regression")
    if not args.run:
        print("Prepared only; reserve the ordinary native window before --run.")
        return 0
    owner = Path("/tmp/baton-probe.lock/owner").read_text().split()[0]
    f.require(owner == str(os.getppid()), "Use the normal lock-owning wrapper")
    quiet = subprocess.run(["/usr/bin/pgrep", "-x", "xcodebuild"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    f.require(quiet.returncode == 1, "Native process preflight refused; no override")
    current = subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD"]).decode().strip()
    f.require(len(args.source) == 40 and current == args.source, "Immutable source pin mismatch")
    f.require(subprocess.run(["git", "-C", str(REPO), "diff", "--quiet", "HEAD"]).returncode == 0, "Source must be frozen clean")
    root = Path(args.output).resolve()
    f.require(root.parent == Path("/private/tmp") and not root.exists(), "Fresh private temporary output required")
    os.umask(0o077); root.mkdir(mode=0o700)
    deadline = Deadline(); env = f.clean_environment(root)
    owned = OwnedFixture(root, env, deadline); deadline.arm()
    def stop(_signum, _frame):
        write_receipt(root.with_name(root.name+'.cancel-requested'), {'requested':True})
    for name in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]: signal.signal(name, stop)
    result = 1
    scope = "SDK plus real public AV playback/session regression; no physical-device or whole-feature acceptance" if media else "SDK plus synthetic URLSession job dispatch; no actual composer/media/physical-device acceptance"
    def command(argv, cap=120): return owned.command(argv, cap=cap)[0]
    def cache_command(argv): return owned.command(argv, stdout_only=True)[0]
    try:
        cache = root / "package-cache"
        pins, cache_receipt = copy_cache(args.package_cache, args.package_pins, cache, REPO, cache_command)
        write_receipt(root / "source.json", {"commit": current, "cache": cache_receipt,
            "mediaFixtureSHA256": hashlib.sha256(media.read_bytes()).hexdigest() if media else None,
            "sharePackageSHA256": {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted((REPO / "Packages/BatonShareKit/Sources").rglob("*.swift"))}, "selection": selection})
        owned.simulator_name = "Baton Mixtape " + secrets.token_hex(12); owned.receipt()
        owned.simulator = command(["xcrun", "simctl", "create", owned.simulator_name,
            "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"]).decode().strip()
        owned.receipt()
        command(["xcrun", "simctl", "boot", owned.simulator])
        command(["xcrun", "simctl", "bootstatus", owned.simulator, "-b"])
        previous = Path.cwd()
        try: os.chdir(REPO / "ios"); command(["xcodegen", "generate"])
        finally: os.chdir(previous)
        owned.snapshot_scheme(REPO / "ios/BatonMobile.xcodeproj/xcshareddata/xcschemes/BatonMobile.xcscheme")
        destination = REPO / "ios/BatonMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        destination.parent.mkdir(parents=True, exist_ok=True); destination.write_bytes(pins)
        common = ["-project", str(REPO / "ios/BatonMobile.xcodeproj"), "-scheme", "BatonMobile",
            "-destination", "platform=iOS Simulator,id=" + owned.simulator, "-derivedDataPath", str(root / "derived-data"),
            "-clonedSourcePackagesDirPath", str(cache), "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
            *["-only-testing:BatonMobileTests/" + case for case in selection]]
        for phase in ["build-for-testing", "test-without-building"]:
            phase_args = common
            if phase == "test-without-building" and media:
                runs = list((root / "derived-data/Build/Products").glob("*.xctestrun"))
                f.require(len(runs) == 1, "One generated test run required")
                run = plistlib.loads(runs[0].read_bytes())
                targets = [t for c in run.get("TestConfigurations", []) for t in c["TestTargets"]] if "TestConfigurations" in run else [run["BatonMobileTests"]]
                targets = [t for t in targets if t.get("BlueprintName", "BatonMobileTests") == "BatonMobileTests"]
                f.require(len(targets) == 1, "One app-unit target required")
                targets[0].setdefault("EnvironmentVariables", {})["BATON_NATIVE_MIXTAPE_MEDIA_FILE"] = str(media)
                private_run = runs[0].with_name("MixtapeRecipient.xctestrun")
                private_run.write_bytes(plistlib.dumps(run)); private_run.chmod(0o600)
                phase_args = ["-xctestrun", str(private_run), "-destination", "platform=iOS Simulator,id=" + owned.simulator,
                    "-only-testing:BatonMobileTests/" + MEDIA_CASE]
            bundle = root / (phase + ".xcresult")
            with (root / (phase + ".log")).open("wb") as log:
                process = owned.start(["xcodebuild", phase, *phase_args, "-resultBundlePath", str(bundle)],
                    childenv=offline_environment(env), output=log)
                owned.wait(process)
            write_receipt(root / (phase + "-exit.json"), {"exitCode": process.returncode})
            if phase == "test-without-building" and bundle.exists():
                counts = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
                write_receipt(root / "counts.json", counts)
            f.require(process.returncode == 0, "Owned targeted native phase failed; private log retained")
        f.require(counts["totalTestCount"] == len(selection) and counts["passedTests"] == len(selection)
            and counts["failedTests"] == 0 and counts["skippedTests"] == 0, "Actual executed selection failed or skipped")
        result = 0
    except (Exception, FixtureTimeout, KeyboardInterrupt) as error:
        write_receipt(root / "failure.json", {"kind": type(error).__name__, "scope": scope + "; private diagnostics retained"})
    finally:
        qualified=False
        try:
            cleanup = owned.cleanup()
            qualified=cleanup_qualified(cleanup)
        except BaseException:
            pass
        if not qualified:
            retain_custody(root,deadline)
        try:
            deadline.disarm()
            write_receipt(root / "result.json", {"exitCode": result, "commit": current, "scope": scope})
            write_receipt(root / "native-custody-release.json", {"qualified":True,
                "registeredGroupsAbsent":True,"schemeRestoredExactly":True,
                "simulatorAbsent":cleanup["simulatorAbsent"],"containerAbsent":cleanup["containerAbsent"]})
        except BaseException:
            retain_custody(root,deadline)
    print("Baton targeted native check:", "passed" if result == 0 else "failed", "receipt", str(root / "result.json"))
    return result

if __name__ == "__main__": sys.exit(main())
