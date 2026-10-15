"""Fixed signed capture build adapter using the accepted original-parent custody path.

No install/test/device/provider action. Requires independent source acceptance and GO.
Historical capture metadata is a compatibility tag; execution source is independently pinned.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import posix
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
from types import SimpleNamespace, BuiltinFunctionType

ROOT = Path('/private/tmp/baton-tbx8711-fresh-capture-20261008-2')
REPO = Path('/private/tmp/baton-tbx-8711-fresh-capture')
DEPENDENCY = Path('/private/tmp/baton-sharing-attest-receipt')
ENV_HELPER = Path('/private/tmp/baton-tbx-8680-physical/scripts/incoming_fixture_packages.py')
SHARED = REPO / 'scripts'
CANCELLED = False

OWNED_SHA = 'b18531a1981f541340d459e43ddc3f2e43fbf23dfac093af0ecf3bb208b1b553'
OWNED_PATH = REPO / 'ios/scripts/app_attest_owned_controller.py'
if hashlib.sha256(OWNED_PATH.read_bytes()).hexdigest() != OWNED_SHA:
    raise RuntimeError('shared adapter identity changed')
_owned_spec = importlib.util.spec_from_file_location('app_attest_owned_controller', OWNED_PATH)
OWNED = importlib.util.module_from_spec(_owned_spec)
_owned_spec.loader.exec_module(OWNED)
for _name in ['digest', 'private_file', 'require', 'cancel_requested', 'record_cancel', 'supervisor', 'retain_original', 'stopped_original', 'stage']:
    globals()[_name] = getattr(OWNED, _name)

def configure_owned():
    OWNED.configure(ROOT, REPO)





def qualified_file(name, bound):
    path = ROOT / name
    attrs = path.lstat()
    require(stat.S_ISREG(attrs.st_mode) and attrs.st_uid == os.getuid() and
            stat.S_IMODE(attrs.st_mode) == 0o600 and attrs.st_size <= bound,
            'release receipt metadata refused')
    return path.read_bytes()

def qualify_release(*, before_marker=False):
    # Metadata-only readback after the original controller's completed wait.
    # A sentinel alone cannot admit releasing the ordinary guards.
    require(ROOT == ROOT.resolve() and not ROOT.is_symlink() and
            ROOT.lstat().st_uid == os.getuid() and
            stat.S_IMODE(ROOT.stat().st_mode) == 0o700, 'release root refused')
    pins = json.loads(qualified_file('input-pins.json', 65536))['inputSHA256']
    for name, expected in pins.items():
        path = Path(name)
        require(path.is_file() and not path.is_symlink() and digest(path) == expected,
                'release source identity changed')
    require(qualified_file('cleanup-complete', 64) == b'owned-cleanup-verified\n',
            'required cleanup marker absent')
    if not before_marker:
        require(qualified_file('driver-finished', 64) == b'finished\n',
                'required driver marker absent')
    report = json.loads(qualified_file('safe-run-receipt.json', 65536))
    require(report['allOwnedCleanupVerified'] is True and
            report['ownedCleanupState']['launchUncertain'] is False and
            report['ownedCleanupState']['unknown'] is False and
            report['deviceActions'] == 0 and report['providerActions'] == 0,
            'controller release state unqualified')
    require(type(report['phases']) is list, 'release phase list refused')
    for row in report['phases']:
        require(row.get('cleanupComplete') is True and row.get('leaderReaped') is True and
                row.get('ownedGroupPending') is False and row.get('inspectionProcessPending') is False,
                'phase release receipt unqualified')
    return 0

def safe_environment(environment):
    # Reject by key presence; never inspect, print or retain supplied values.
    require(not any(k.startswith('DYLD') or k.startswith('LD_') for k in environment),
            'loader injection key present')
    spec = importlib.util.spec_from_file_location('offline_environment_helper', ENV_HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.offline_environment(environment)

def preflight():
    require(ROOT == ROOT.resolve() and not ROOT.is_symlink() and
            ROOT.lstat().st_uid == os.getuid() and
            stat.S_IMODE(ROOT.stat().st_mode) == 0o700, 'private output root')
    manifest = json.loads(qualified_file('input-pins.json', 65536))
    require(not any((ROOT / n).exists() for n in ['run-started.json', 'cleanup-complete',
        'driver-finished', 'derived-data', 'project']), 'attempt already started')
    for name, expected in manifest['inputSHA256'].items():
        path = Path(name)
        require(path == path.resolve() and path.is_file() and not path.is_symlink()
            and path.stat().st_uid == os.getuid() and digest(path) == expected,
            'input identity changed')
    require(manifest['namespace'] == 'probe-attest-2450a4e63e0e426eb1c3f76b43cee77a'
        and manifest['buildNamespace'] == 'probe-attest-minimal-20261005-8711'
        and manifest['captureCompatibilityTag'] == '60368d111db2c58285ffb93beef5f85093ee8257',
        'fixed capture binding changed')
    require(not any(k.startswith('DYLD') or k.startswith('LD_') for k in os.environ),
            'loader injection key present')
    return manifest


def artifact_receipt(manifest):
    require((ROOT / 'source-commit.log').read_text().strip() == manifest['executionSourceCommit'],
        'execution commit changed')
    # Pure bounded metadata/hash readback after the separately supervised signatures.
    import plistlib
    products = ROOT / 'derived-data/Build/Products'
    runs = list(products.glob('*.xctestrun'))
    require(len(runs) == 1, 'exact generated test run required')
    run = runs[0]
    require(run.stat().st_size <= 1024 * 1024, 'test run exceeds bound')
    app = products / 'Debug-iphoneos/BatonPhysicalProbe.app'
    test = app / 'PlugIns/BatonAppAttestPhysicalTests.xctest'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    x = plistlib.loads(run.read_bytes())
    target = x['BatonAppAttestPhysicalTests']
    require(set(x) == {'BatonAppAttestPhysicalTests', '__xctestrun_metadata__'} and
        target['EnvironmentVariables']['baton.defaultsSuite'] == manifest['buildNamespace'] and
        target['EnvironmentVariables']['BATON_APP_ATTEST_PHYSICAL_ACCEPTANCE'] == '1' and
        target['TestBundlePath'] == '__TESTHOST__/PlugIns/BatonAppAttestPhysicalTests.xctest' and
        target['TestHostBundleIdentifier'] == 'io.tonebox.baton', 'generated test binding refused')
    require(info['CFBundleIdentifier'] == 'io.tonebox.baton' and
        info['CFBundleVersion'] == '1' and info['BatonPhysicalAttestProbe'] is True and
        info['BatonSourceCommit'] == manifest['captureCompatibilityTag'], 'capture metadata refused')
    def tree(path):
        h = hashlib.sha256(); count = 0
        for item in sorted(path.rglob('*'), key=lambda p: p.relative_to(path).as_posix()):
            relative = item.relative_to(path).as_posix().encode()
            require(not item.is_symlink(), 'unexpected artifact symlink')
            if item.is_file():
                require(item.stat().st_uid == os.getuid(), 'foreign artifact owner')
                h.update(relative + b'\0' + hashlib.sha256(item.read_bytes()).digest()); count += 1
        return h.hexdigest(), count
    entitlements_output = (ROOT / 'signature-entitlements.log').read_bytes()
    require(len(entitlements_output) <= 65536 and b'<?xml' in entitlements_output, 'signed entitlements unavailable')
    entitlements = plistlib.loads(entitlements_output[entitlements_output.index(b'<?xml'):].split(b'</plist>', 1)[0] + b'</plist>')
    require(entitlements.get('application-identifier') == 'Q8822GNL2H.io.tonebox.baton' and
        entitlements.get('com.apple.developer.devicecheck.appattest-environment') == 'development' and
        entitlements.get('get-task-allow') is True and
        entitlements.get('com.apple.security.application-groups') == ['group.io.tonebox.baton'] and
        'aps-environment' not in entitlements, 'signed development environment refused')
    app_sha, count = tree(app); test_sha, test_count = tree(test)
    require(count == 21 and test_count == 3 and not (app / 'Frameworks').exists(),
            'minimal host tree shape refused')
    for name, expected in manifest['inputSHA256'].items():
        require(digest(Path(name)) == expected, 'input changed during build')
    # This receipt binds effective runtime suite through the unchanged runtime-dynamic
    # capture source and generator. A later independently accepted namespace-only
    # xctestrun sibling is still required by physical admission, plus its own digest.
    return {'schemaVersion': 1, 'sourceBuildAssociationQualified': True,
        'namespace': manifest['namespace'], 'buildNamespace': manifest['buildNamespace'],
        'captureCompatibilityTag': manifest['captureCompatibilityTag'],
        'compatibilityTagIsExecutionCommit': False,
        'executionSourceCommit': manifest['executionSourceCommit'],
        'executionSourceClosureSHA256': manifest['inputSHA256'],
        'testIdentifier': 'BatonAppAttestPhysicalTests/AppAttestIssuancePhysicalTests/testCaptureAppleIssuanceAndAssertionForDevelopmentClassification',
        'testSourceSHA256': digest(REPO / 'ios/Tests/BatonAppAttestPhysicalTests/AppAttestIssuancePhysicalTests.swift'),
        'appTreeSHA256': app_sha, 'appRegularFiles': count,
        'testBundleTreeSHA256': test_sha, 'testBundleRegularFiles': test_count,
        'generatedSpecSHA256': digest(ROOT / 'physical-probe-spec.json'),
        'originalXctestrunPath': str(run), 'originalXctestrunSHA256': digest(run),
        'runtimeNamespaceFromValidatedEnvironment': True,
        'signatureVerificationPassed': True, 'signedDevelopmentAppAttest': True,
        'physicalTestsRun': 0,
        'installed': False, 'launched': False, 'policyActivated': False}


def capture_exit():
    # Capture before commitment; a replaced callback cannot authorize final publication.
    require(os._exit is posix._exit and type(os._exit) is BuiltinFunctionType and
            os._exit.__module__ == 'posix' and os._exit.__name__ == '_exit',
            'nonreturning exit binding refused')
    return os._exit

def run():
    os.umask(0o077)
    manifest = preflight()
    environment = safe_environment(os.environ)
    configure_owned()
    runner = supervisor()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, record_cancel)
    start = time.monotonic()
    deadline = start + 295  # Keep five seconds for shell release/readback within the 5min gap.
    report = {'startedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'phases': [], 'SDKWindowSeconds': 300, 'deviceActions': 0,
              'providerActions': 0, 'result': 'FAIL', 'allOwnedCleanupVerified': True,
              'allReadinessPhasesPassed': False, 'acceptedSuccess': False}
    accepted_success = False
    custody = {'unknown': False, 'launchUncertain': False, '_processes': []}
    try:
        private_file(ROOT / 'run-started.json', (json.dumps(report) + '\n').encode())
        project = ROOT / 'project'
        project.mkdir(mode=0o700)  # Fresh owned output parent required by XcodeGen.
        app = ROOT / 'derived-data/Build/Products/Debug-iphoneos/BatonPhysicalProbe.app'
        phases = [
            ('generate', ['xcodegen', 'generate', '--spec', str(ROOT / 'physical-probe-spec.json'),
             '--project-root', str(REPO / 'ios'), '--project', str(project)], 40, 50, 240),
            ('build', ['xcodebuild', 'build-for-testing', '-project', str(project / 'BatonMobile.xcodeproj'),
             '-scheme', 'BatonAppAttestPhysical', '-configuration', 'Debug', '-sdk', 'iphoneos',
             '-destination', 'generic/platform=iOS', '-derivedDataPath', str(ROOT / 'derived-data'),
             '-clonedSourcePackagesDirPath', str(ROOT / 'package-cache'),
             '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
             '-skipPackageUpdates', '-jobs', '2',
             'BATON_SOURCE_COMMIT=' + manifest['captureCompatibilityTag']], 200, 215, 28),
            ('signature-app', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], 5, 8, 16),
            ('source-commit', ['git', 'rev-parse', 'HEAD'], 3, 5, 10),
            ('signature-test', ['/usr/bin/codesign', '--verify', '--strict',
             str(app / 'PlugIns/BatonAppAttestPhysicalTests.xctest')], 5, 8, 10),
            ('signature-entitlements', ['/usr/bin/codesign', '--display', '--entitlements', ':-', str(app)], 5, 8, 1),
        ]
        for name, command, execution, outer, reserve in phases:
            row = stage(name, command, runner, environment, deadline, execution, outer, reserve, custody)
            report['phases'].append(row)
            require(not custody['unknown'] and not row.get('inspectionProcessPending'),
                    'owned build cleanup incomplete')
            require(row['testExit'] == 0 and not row['timedOut'], 'signed build phase failed')
        receipt = artifact_receipt(manifest)
        private_file(ROOT / 'capture-build-receipt.json',
            (json.dumps(receipt, sort_keys=True, indent=2) + '\n').encode())
        report['allReadinessPhasesPassed'] = True
        require(not cancel_requested(), 'cancellation requested')
        for name, expected in manifest['inputSHA256'].items():
            require(digest(Path(name)) == expected, 'input changed during run')
        artifact_receipt(manifest)
        accepted_success = True
    except BaseException as error:
        report.update(errorClass=type(error).__name__, privateDetailsWithheld=True)
    if custody['unknown'] or custody['launchUncertain'] is not False:
        retain_original(runner)
    # Before commitment, any uncertainty/fallible receipt work retains the original
    # parent. After all strict requirements except the final marker are validated,
    # publication commits to immediate self-exit; it can never return to hold.
    try:
        finished_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        seconds = round(time.monotonic() - start, 3)
        sampled_cancellation = cancel_requested()
        accepted_success = (accepted_success and report['allReadinessPhasesPassed']
                            and not sampled_cancellation)
        report.update(allOwnedCleanupVerified=not custody['unknown'],
                      ownedCleanupState={key: value for key, value in custody.items() if not key.startswith('_')},
                      cancellationRequested=sampled_cancellation,
                      finishedAtUTC=finished_at, seconds=seconds,
                      acceptedSuccess=accepted_success,
                      result='PASS' if accepted_success else 'FAIL')
        require(custody['launchUncertain'] is False and not custody['unknown'],
                'controller release unqualified')
        for row in report['phases']:
            require(row.get('cleanupComplete') is True and row.get('leaderReaped') is True and
                    row.get('ownedGroupPending') is False and row.get('inspectionProcessPending') is False,
                    'phase release receipt unqualified')
        private_file(ROOT / 'safe-run-receipt.json',
                     (json.dumps(report, sort_keys=True, indent=2) + '\n').encode())
        private_file(ROOT / 'cleanup-complete', b'owned-cleanup-verified\n')
        qualify_release(before_marker=True)
        final_exit = capture_exit()
        accepted_exit = 0 if report['acceptedSuccess'] is True else 1
    except BaseException:
        retain_original(runner)
    marker_complete = False
    try:
        private_file(ROOT / 'driver-finished', b'finished\n')
        marker_complete = True
    finally:
        # A partial/missing marker refuses shell release, but all owned work was
        # already absent. No diagnostic/qualifier/hold call follows publication.
        final_exit(accepted_exit if marker_complete else 1)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight-only', action='store_true')
    parser.add_argument('--coordinated-go', action='store_true')
    parser.add_argument('--qualify-release', action='store_true')
    args = parser.parse_args()
    if args.qualify_release:
        require(not args.preflight_only and not args.coordinated_go, 'release mode exclusive')
        return qualify_release()
    if args.preflight_only and not args.coordinated_go:
        preflight()
        print(json.dumps({'preflight': 'PASS', 'SDKOperations': 0, 'guardAcquisitions': 0}))
        return 0
    require(args.coordinated_go and not args.preflight_only, 'explicit coordinated GO required')
    return run()

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'result': 'FAIL', 'errorClass': type(error).__name__,
                          'privateDetailsWithheld': True}))
        raise SystemExit(1)
