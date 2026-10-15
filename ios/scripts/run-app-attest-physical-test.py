"""One original parent owns an explicitly admitted physical capture and proof checks.

A prepared packet is inert. Root must separately qualify source/namespace, active
phone facts, exclusive continuous custody and new deployment/restore tracking, then
supply a protected admission binding. No automatic retry, install or policy change.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time

OWNED_SHA = 'b18531a1981f541340d459e43ddc3f2e43fbf23dfac093af0ecf3bb208b1b553'
BINDING_KEYS = {'schemaVersion', 'deployment', 'restoreDeployment', 'packetPath',
                'packetSHA256', 'selectionPath', 'selectionSHA256', 'rootGO',
                'executionAdmitted', 'unusedOnPhoneNamespaceQualified',
                'exclusiveContinuousCustodyQualified', 'compiledCaptureNamespaceQualified',
                'captureNamespaceEvidencePath', 'captureNamespaceEvidenceSHA256'}


def require(value):
    if not value:
        raise ValueError('Physical admission refused')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_json(path, bound=1024 * 1024):
    attrs = path.lstat()
    require(path == path.resolve() and stat.S_ISREG(attrs.st_mode) and
            attrs.st_uid == os.getuid() and stat.S_IMODE(attrs.st_mode) == 0o600 and
            0 < attrs.st_size <= bound)
    return json.loads(path.read_bytes())


def load_pinned(name, path, expected):
    require(path.is_file() and not path.is_symlink() and digest(path) == expected)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_inputs(packet):
    for name, expected in packet['executionInputSHA256'].items():
        path = Path(name)
        require(path == path.resolve() and path.is_file() and not path.is_symlink() and
                path.stat().st_uid == os.getuid() and digest(path) == expected)
    require(packet['ownedAdapterSHA256'] == OWNED_SHA and
            packet['captureBuild'] == '1' and
            re.fullmatch(r'probe-attest-[a-f0-9]{32}', packet['suite']))
    repo = Path(packet['sourceRepository'])
    preparer = load_pinned('physical_packet_validation', repo / 'ios/scripts/prepare-app-attest-next-attempt.py',
                          packet['preparerSHA256'])
    preparer.qualify(packet['qualificationConfig'], repo, prepared=True)
    expected = preparer.execution_inputs(packet['qualificationConfig'], repo,
        Path(packet['newXctestrunPath']), Path(packet['attemptRoot']), prepared=True)
    require(expected == packet['executionInputSHA256'])
    require(preparer.tree_digest(Path(packet['retainedAppPath'])) == (packet['appTreeSHA256'], 21))
    require(preparer.test_bundle_path(Path(packet['originalXctestrunPath'])) == Path(packet['testBundlePath']) and
            preparer.tree_digest(Path(packet['testBundlePath'])) == (packet['testBundleTreeSHA256'], packet['testBundleRegularFiles']))
    x = preparer.plistlib.loads(Path(packet['newXctestrunPath']).read_bytes())
    require(x['BatonAppAttestPhysicalTests']['EnvironmentVariables']['baton.defaultsSuite'] == packet['suite'])
    x['BatonAppAttestPhysicalTests']['EnvironmentVariables']['baton.defaultsSuite'] = packet['qualificationConfig']['originalNamespace']
    require(x == preparer.plistlib.loads(Path(packet['originalXctestrunPath']).read_bytes()))
    return repo


TEST_IDENTIFIER = 'BatonAppAttestPhysicalTests/AppAttestIssuancePhysicalTests/testCaptureAppleIssuanceAndAssertionForDevelopmentClassification'


def qualify_capture_namespace(binding_path, binding, packet, repo):
    # Root's independently qualified source/build/artifact association is required;
    # a caller boolean or xctestrun suite transformation alone supplies no proof.
    path = Path(binding['captureNamespaceEvidencePath'])
    require(path == binding_path.parent / 'capture-namespace-evidence.json' and
            digest(path) == binding['captureNamespaceEvidenceSHA256'])
    evidence = private_json(path, 65536)
    keys = {'schemaVersion', 'namespace', 'testIdentifier', 'appTreeSHA256',
        'testBundleTreeSHA256', 'newXctestrunSHA256', 'testSourceSHA256',
        'buildReceiptSHA256', 'independentNamespaceAssociationQualified'}
    require(set(evidence) == keys and evidence['schemaVersion'] == 1 and
        evidence['independentNamespaceAssociationQualified'] is True and
        evidence['namespace'] == packet['suite'] and evidence['testIdentifier'] == TEST_IDENTIFIER and
        evidence['appTreeSHA256'] == packet['appTreeSHA256'] and
        evidence['testBundleTreeSHA256'] == packet['testBundleTreeSHA256'] and
        evidence['newXctestrunSHA256'] == packet['newXctestrunSHA256'])
    source = repo / 'ios/Tests/BatonAppAttestPhysicalTests/AppAttestIssuancePhysicalTests.swift'
    require(source == source.resolve() and source.is_file() and not source.is_symlink() and
            source.stat().st_uid == os.getuid() and digest(source) == evidence['testSourceSHA256'])
    # Fixed safe aggregate build receipt, never an arbitrary owner/config path.
    build = path.parent / 'capture-build-receipt.json'
    build_receipt = private_json(build, 1024 * 1024)
    require(digest(build) == evidence['buildReceiptSHA256'] and
        build_receipt.get('schemaVersion') == 1 and
        build_receipt.get('sourceBuildAssociationQualified') is True and
        all(build_receipt.get(key) == evidence[key] for key in ['namespace',
            'testIdentifier', 'testSourceSHA256', 'appTreeSHA256', 'testBundleTreeSHA256']))


def admission(binding_path, deployment, finishing=False):
    binding = private_json(binding_path, 65536)
    require(set(binding) == BINDING_KEYS and binding['schemaVersion'] == 1 and
            binding['deployment'] == deployment and re.fullmatch(r'TBX-[0-9]+', deployment) and
            re.fullmatch(r'TBX-[0-9]+', binding['restoreDeployment']) and
            deployment != binding['restoreDeployment'])
    require(all(binding[key] is True for key in ['rootGO', 'executionAdmitted',
        'unusedOnPhoneNamespaceQualified', 'exclusiveContinuousCustodyQualified', 'compiledCaptureNamespaceQualified']))
    packet_path = Path(binding['packetPath'])
    packet = private_json(packet_path)
    require(digest(packet_path) == binding['packetSHA256'] and
            packet_path == Path(__file__).resolve().parent / 'attempt-plan/manifest.json' and
            packet['executionAdmitted'] is False and packet['physicalTestsRun'] == 0 and
            packet['restoreRequired'] is True)
    base = Path(packet['attemptRoot'])
    require(base == packet_path.parent.parent and base == base.resolve() and
            base.stat().st_uid == os.getuid() and stat.S_IMODE(base.stat().st_mode) == 0o700)
    require(packet['executionInputSHA256'].get(str(Path(__file__).resolve())) == digest(Path(__file__)))
    repo = validate_inputs(packet)
    qualify_capture_namespace(binding_path, binding, packet, repo)
    selection = Path(binding['selectionPath']); attrs = selection.lstat()
    require(selection == selection.resolve() and stat.S_ISREG(attrs.st_mode) and
            attrs.st_uid == os.getuid() and stat.S_IMODE(attrs.st_mode) == 0o600 and
            0 < attrs.st_size <= 1024 and digest(selection) == binding['selectionSHA256'])
    device = selection.read_text().strip()
    require(re.fullmatch(r'[a-zA-Z0-9-]{8,128}', device))
    root = base / ('test-' + deployment)
    proof = base / ('proof-' + deployment)
    if not finishing:
        require(not os.path.lexists(root) and not os.path.lexists(proof))
    return binding, packet, repo, device, root, proof


def qualify_release(binding_path, deployment):
    """Metadata-only strict readback; no guard release, restore or child call."""
    binding, packet, repo, device, root, proof = admission(binding_path, deployment, finishing=True)
    attrs = root.lstat()
    require(root == root.resolve() and stat.S_ISDIR(attrs.st_mode) and
            attrs.st_uid == os.getuid() and stat.S_IMODE(attrs.st_mode) == 0o700)
    for name, expected in [('cleanup-complete', b'owned-cleanup-verified\n'),
                           ('driver-finished', b'finished\n')]:
        path = root / name; attrs = path.lstat()
        require(stat.S_ISREG(attrs.st_mode) and attrs.st_uid == os.getuid() and
                stat.S_IMODE(attrs.st_mode) == 0o600 and attrs.st_size <= 64 and
                path.read_bytes() == expected)
    result = private_json(root / 'safe-test-receipt.json', 65536)
    require(result['deployment'] == deployment and
            result['restoreDeployment'] == binding['restoreDeployment'] and
            result['restoreRequired'] is True and result['allOwnedCleanupVerified'] is True and
            result['ownedCleanupState']['unknown'] is False and
            result['ownedCleanupState']['launchUncertain'] is False and
            type(result['phases']) is list)
    require(all(row.get('cleanupComplete') is True and row.get('leaderReaped') is True and
                row.get('ownedGroupPending') is False and row.get('inspectionProcessPending') is False
                for row in result['phases']))
    return 0


def environment():
    require(not any(k.startswith('DYLD') or k.startswith('LD_') for k in os.environ))
    return {key: os.environ[key] for key in ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL',
        'USER', 'LOGNAME', 'DEVELOPER_DIR'] if key in os.environ}


def summary_counts(path):
    data = private_json(path, 65536)
    keys = ['totalTestCount', 'passedTests', 'failedTests', 'skippedTests']
    counts = {key: data.get(key) for key in keys}
    require(all(type(value) is int and value >= 0 for value in counts.values()))
    require(counts['totalTestCount'] == sum(counts[k] for k in keys[1:]))
    return counts


def classification(path, packet):
    data = private_json(path, 4096)
    required = {'result', 'appleChainNonceAppIDAAGUIDReceiptVerified', 'assertionVerified',
        'environment', 'pinnedCaptureBuild', 'pinnedCaptureSource', 'authenticatedCategories',
        'attestationExtensionsPresent', 'assertionExtensionsPresent', 'assertionCounterPositive',
        'receiptFreshnessEnforced', 'policyActivated'}
    require(set(data) in [required, required | {'authenticatedBundleVersion'}])
    require(data['result'] == 'PASS' and data['environment'] == 'development' and
            data['pinnedCaptureBuild'] == packet['captureBuild'] and
            data['pinnedCaptureSource'] == packet['captureSource'] and
            data.get('authenticatedBundleVersion', packet['captureBuild']) == packet['captureBuild'])
    require(all(data[k] is True for k in ['appleChainNonceAppIDAAGUIDReceiptVerified',
        'assertionVerified', 'assertionCounterPositive', 'receiptFreshnessEnforced']) and
        data['policyActivated'] is False)
    require(all(type(data[k]) is bool for k in ['attestationExtensionsPresent', 'assertionExtensionsPresent']))
    categories = data['authenticatedCategories']
    require(type(categories) is list and len(categories) <= 1 and
            all(type(n) is int and 0 <= n <= 0xffffffff for n in categories))
    return data


def run(binding_path, deployment):
    os.umask(0o077)
    binding, packet, repo, device, root, proof = admission(binding_path, deployment)
    env = environment()
    base = Path(packet['attemptRoot'])
    owned = load_pinned('physical_owned_adapter', base / 'app_attest_owned_controller.py', OWNED_SHA)
    copy = load_pinned('physical_copy_checks', base / 'copy-probe-evidence.py', packet['copyHelperSHA256'])
    # All admission/source/artifact checks precede the first output mutation.
    root.mkdir(mode=0o700)
    owned.configure(root, repo)
    owned.private_file(root / 'input-pins.json',
        (json.dumps({'inputSHA256': packet['executionInputSHA256']}) + '\n').encode())
    supervisor = owned.supervisor()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, owned.record_cancel)
    start = time.monotonic(); deadline = start + 290
    custody = {'unknown': False, 'launchUncertain': False, '_processes': []}
    result = {'deployment': deployment, 'restoreDeployment': binding['restoreDeployment'],
        'startedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'phases': [],
        'restoreRequired': True, 'testsPassed': False, 'authenticatedClassification': False,
        'policyActivated': False, 'privateDetailsWithheld': True, 'acceptedSuccess': False}
    accepted_success = False
    def phase(name, command, execution, outer, reserve):
        require(private_json(binding_path, 65536) == binding)
        qualify_capture_namespace(binding_path, binding, packet, repo)
        validate_inputs(packet)
        row = owned.stage(name, command, supervisor, env, deadline, execution, outer, reserve, custody)
        result['phases'].append(row)
        require(row['cleanupComplete'] is True and row['leaderReaped'] is True and
                row['ownedGroupPending'] is False and row['inspectionProcessPending'] is False)
        return row
    try:
        command = ['xcodebuild', 'test-without-building', '-xctestrun', packet['newXctestrunPath'],
            '-destination', 'platform=iOS,id=' + device,
            '-only-testing:' + TEST_IDENTIFIER,
            '-collect-test-diagnostics', 'never', '-parallel-testing-enabled', 'NO',
            '-maximum-concurrent-test-device-destinations', '1', '-test-timeouts-enabled', 'YES',
            '-maximum-test-execution-time-allowance', '180', '-resultBundlePath', str(root / 'physical.xcresult')]
        row = phase('test', command, 220, 230, 55)
        require(row['testExit'] == 0 and row['timedOut'] is False)
        row = phase('summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
            '--path', str(root / 'physical.xcresult')], 10, 10, 40)
        require(row['testExit'] == 0 and row['timedOut'] is False)
        result['counts'] = summary_counts(root / 'summary.log')
        result['testsPassed'] = result['counts'] == {'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}
        require(result['testsPassed'])
        proof.mkdir(mode=0o700)
        copied_at = time.monotonic()
        row = phase('copy', copy.command(device, packet['suite'], proof / 'issuance.json', proof / 'copy-raw.json'), 20, 25, 15)
        result['copyExit'] = row['testExit']
        require(row['testExit'] == 0 and row['timedOut'] is False and time.monotonic() - copied_at <= 20)
        result['copyReceipt'] = copy.receipt(proof / 'issuance.json')
        verified_at = time.monotonic()
        row = phase('verify', [str(Path(packet['runtimeDirectory']) / 'verify-proof'), str(proof / 'issuance.json')], 10, 10, 5)
        result['offlineVerifierExit'] = row['testExit']
        require(row['testExit'] == 0 and row['timedOut'] is False and time.monotonic() - verified_at <= 10)
        result['classification'] = classification(root / 'verify.log', packet)
        result['authenticatedClassification'] = True
        require(not owned.cancel_requested())
        validate_inputs(packet)
        accepted_success = True
    except (ValueError, RuntimeError, AssertionError) as error:
        result['errorClass'] = type(error).__name__
    except BaseException:
        # Unexpected artifact/metadata I/O is not a qualified diagnostic exit.
        # Keep the original parent before any receipt/print, even if the last
        # child was positively closed; coordinator reconciliation is required.
        owned.retain_original(supervisor)
    if custody['unknown'] or custody['launchUncertain'] is not False:
        owned.retain_original(supervisor)
    try:
        finished_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        seconds = round(time.monotonic() - start, 3)
        sampled_cancellation = owned.cancel_requested()
        result.update(finishedAtUTC=finished_at, seconds=seconds,
            cancellationRequested=sampled_cancellation,
            acceptedSuccess=(accepted_success and result['testsPassed'] and
                result['authenticatedClassification'] and not sampled_cancellation),
            allOwnedCleanupVerified=True, ownedCleanupState={k:v for k,v in custody.items() if not k.startswith('_')})
        require(custody['launchUncertain'] is False and custody['unknown'] is False)
        require(all(p['cleanupComplete'] is True and p['leaderReaped'] is True and
            p['ownedGroupPending'] is False and p['inspectionProcessPending'] is False for p in result['phases']))
        owned.private_file(root / 'safe-test-receipt.json', (json.dumps(result, indent=2) + '\n').encode())
        owned.private_file(root / 'cleanup-complete', b'owned-cleanup-verified\n')
        # Printing is still inside original-parent custody; failure cannot publish finished.
        print(json.dumps(result))
        owned.private_file(root / 'driver-finished', b'finished\n')
    except BaseException:
        owned.retain_original(supervisor)
    return 0 if result['acceptedSuccess'] is True else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deployment', required=True)
    parser.add_argument('--binding', type=Path, required=True)
    parser.add_argument('--qualify-release', action='store_true')
    args = parser.parse_args()
    if args.qualify_release:
        return qualify_release(args.binding, args.deployment)
    return run(args.binding, args.deployment)

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        # Child uncertainty/finalization faults never return from run's hold.
        # Remaining prebirth refusal exposes neither exception text nor inputs.
        print(json.dumps({'result': 'FAIL', 'errorClass': type(error).__name__,
                          'privateDetailsWithheld': True, 'restoreRequired': True}))
        raise SystemExit(1)
