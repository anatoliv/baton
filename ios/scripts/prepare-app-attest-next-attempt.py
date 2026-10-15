#!/usr/bin/env python3
"""Prepare an explicit immutable local packet; never execute SDK/device commands.

An independently reviewed owned 0600 JSON input supplies expected identities.
Qualification happens before any output. Phone GO, guards, deployment tracking,
unused-on-phone namespace qualification and unconditional restore remain external.
"""
import argparse
import ast
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat

RUNNER_SHA = '8bf6a641c00ae70b6e6df56b24fd5f6b8f049d6a5d9379dfa0a74b59e5b975f8'
COPY_SHA = '34e05272c1d3c8c30498c3c7bc62488b37450011e1f43d9da8c93c9dc5db5a39'
OWNED_SHA = 'b18531a1981f541340d459e43ddc3f2e43fbf23dfac093af0ecf3bb208b1b553'
SHARED_SOURCES = {'scripts/incoming_fixture_lifecycle.py': '3c7239ca012c056bfb7c01253b08d9ce15f8167725f7bf44367ec8e4f26fdb37', 'scripts/mixtape_owned_supervision.py': 'f5e911c5c57bd2021611b0f7263e1ee1775513b6480e98ef5db38e2bd67ae93d', 'scripts/mixtape_owned_lifecycle.py': '3a7f33ecc37fa6aba98ffeeff0f55f93f3e80866ed23c081877141f54c775882'}
ROOT_NAMES = ['Apple_App_Attestation_Root_CA.pem', 'AppleRootCA-G3.cer']
ROOT_PREFIX = 'baton-gateway_BatonShareServer.bundle/Contents/Resources/AttestationRoots/'
RUNTIME_NAMES = ['verify-proof', 'libBatonShareKit.dylib', *[ROOT_PREFIX + n for n in ROOT_NAMES]]
SOURCE_NAMES = [*['gateway/Sources/BatonShareServer/' + n + '.swift' for n in
                 ['AppAttestVerifier', 'AppAttestReceipt', 'AppAttestCBOR']],
                *['Packages/BatonShareKit/Sources/BatonShareKit/' + n + '.swift' for n in
                 ['ShareLedger', 'ShareClient', 'ShareWire', 'ShareLink', 'ShareLimits', 'ShareCrypto', 'ShareAttestation']]]
INPUT_KEYS = {'schemaVersion', 'attemptRoot', 'namespace', 'originalXctestrun',
              'originalXctestrunSHA256', 'originalNamespace', 'appTreeSHA256',
              'testBundleTreeSHA256', 'captureSource', 'captureBuild', 'compileReceipt', 'compileReceiptSHA256',
              'helperSHA256', 'sourceSHA256', 'dependencyPinsSHA256', 'runtimeSHA256'}


def require(condition):
    if not condition:
        raise ValueError('Packet qualification refused')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular(path, private=False, bound=64 * 1024 * 1024):
    info = path.lstat()
    require(path.is_absolute() and path.resolve() == path)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and 0 < info.st_size <= bound)
    if private:
        require(stat.S_IMODE(info.st_mode) == 0o600)


def absent(path):
    require(not os.path.lexists(path))


def tree_digest(app):
    h = hashlib.sha256(); count = 0
    for p in sorted(app.rglob('*'), key=lambda x: x.relative_to(app).as_posix()):
        rel = p.relative_to(app).as_posix().encode()
        if p.is_symlink():
            h.update(rel + b'\0' + os.readlink(p).encode() + b'\0')
        elif p.is_file():
            count += 1
            h.update(rel + b'\0' + hashlib.sha256(p.read_bytes()).digest())
    return h.hexdigest(), count


def test_bundle_path(original):
    x = plistlib.loads(original.read_bytes())
    test = x['BatonAppAttestPhysicalTests']
    name = test['TestBundlePath']
    host = '__TESTROOT__/Debug-iphoneos/BatonPhysicalProbe.app'
    require(test.get('TestHostPath') in [host, host + '/BatonPhysicalProbe'])
    require(name in ['__TESTROOT__/Debug-iphoneos/BatonAppAttestPhysicalTests.xctest',
        host + '/PlugIns/BatonAppAttestPhysicalTests.xctest',
        '__TESTHOST__/PlugIns/BatonAppAttestPhysicalTests.xctest'])
    # Xcode's retained embedded bundle uses TESTHOST. Resolve only that exact
    # alias to the already allowlisted app directory, never arbitrary expansion
    # or the optional executable suffix of TestHostPath.
    if name == '__TESTHOST__/PlugIns/BatonAppAttestPhysicalTests.xctest':
        name = host + '/PlugIns/BatonAppAttestPhysicalTests.xctest'
    bundle = original.parent / name.removeprefix('__TESTROOT__/')
    require(bundle == bundle.resolve() and bundle.is_dir() and not bundle.is_symlink())
    return bundle


def execution_inputs(config, repo, run, root, prepared=False):
    """Exact prospective sources/runtime/artifacts; never execute or mutate."""
    compiled = Path(config['compileReceipt'])
    original = Path(config['originalXctestrun'])
    app = original.parent / 'Debug-iphoneos/BatonPhysicalProbe.app'
    result = {str(repo / name): expected for name, expected in config['sourceSHA256'].items()}
    result.update({str(repo / name): expected for name, expected in SHARED_SOURCES.items()})
    for path in test_bundle_path(original).rglob('*'):
        if path.is_file():
            regular(path); result[str(path)] = digest(path)
    result.update({str(repo / 'ios/scripts/app-attest-offline-proof.swift'): config['helperSHA256'],
        str(repo / 'gateway/Package.resolved'): config['dependencyPinsSHA256'],
        str(compiled): config['compileReceiptSHA256'], str(original): config['originalXctestrunSHA256'],
        str(repo / 'ios/scripts/run-app-attest-physical-test.py'): RUNNER_SHA,
        str(repo / 'ios/scripts/copy-app-attest-probe-evidence.py'): COPY_SHA,
        str(repo / 'ios/scripts/app_attest_owned_controller.py'): OWNED_SHA,
        str(repo / 'ios/scripts/prepare-app-attest-next-attempt.py'): digest(repo / 'ios/scripts/prepare-app-attest-next-attempt.py'),
        str(app / 'Info.plist'): digest(app / 'Info.plist')})
    for name, expected in config['runtimeSHA256'].items():
        result[str(compiled.parent / name)] = expected
    for name in ROOT_NAMES:
        result[str(repo / 'gateway/Sources/BatonShareServer/AttestationRoots' / name)] = config['runtimeSHA256'][ROOT_PREFIX + name]
    if prepared:
        result.update({str(run): digest(run), str(root / 'run-physical-test.py'): RUNNER_SHA,
            str(root / 'copy-probe-evidence.py'): COPY_SHA, str(root / 'app_attest_owned_controller.py'): OWNED_SHA})
    return result


def qualify(config, repo, prepared=False):
    require(set(config) == INPUT_KEYS and config['schemaVersion'] == 1)
    suite = config['namespace']; old_suite = config['originalNamespace']
    require(isinstance(suite, str) and re.fullmatch(r'probe-attest-[a-f0-9]{32}', suite))
    require(isinstance(old_suite, str) and re.fullmatch(r'probe-attest-[A-Za-z0-9._-]{1,40}', old_suite))
    require(suite != old_suite)
    root = Path(config['attemptRoot']); info = root.lstat()
    require(root.is_absolute() and root.resolve() == root and stat.S_ISDIR(info.st_mode)
            and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700)
    if not prepared:
        require(not any(root.iterdir()))
    original = Path(config['originalXctestrun']); regular(original, bound=1024 * 1024)
    require(original.suffix == '.xctestrun' and digest(original) == config['originalXctestrunSHA256'])
    run = original.with_name('BatonAppAttestPhysical-' + suite + '.xctestrun')
    output = root / 'attempt-plan'
    runner_output = root / 'run-physical-test.py'; copy_output = root / 'copy-probe-evidence.py'
    if not prepared:
        for path in [run, output, runner_output, copy_output, root / 'app_attest_owned_controller.py']: absent(path)
    else:
        for path in [run, runner_output, copy_output, root / 'app_attest_owned_controller.py']:
            regular(path, private=True, bound=1024 * 1024)
    app = original.parent / 'Debug-iphoneos/BatonPhysicalProbe.app'
    require(app.is_dir() and not app.is_symlink())
    app_sha, count = tree_digest(app)
    require(app_sha == config['appTreeSHA256'] and count == 21)
    regular(app / 'Info.plist', bound=1024 * 1024)
    app_info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(app_info.get('CFBundleIdentifier') == 'io.tonebox.baton'
            and app_info.get('BatonPhysicalAttestProbe') is True
            and app_info.get('BatonSourceCommit') == config['captureSource']
            and app_info.get('CFBundleVersion') == config['captureBuild'])
    require(re.fullmatch(r'[a-f0-9]{40}', config['captureSource']) and config['captureBuild'] == '1')
    x = plistlib.loads(original.read_bytes())
    require(set(x) == {'BatonAppAttestPhysicalTests', '__xctestrun_metadata__'})
    test = x['BatonAppAttestPhysicalTests']; environment = test['EnvironmentVariables']
    require(environment.get('BATON_APP_ATTEST_PHYSICAL_ACCEPTANCE') == '1'
            and environment.get('baton.defaultsSuite') == old_suite)
    host = '__TESTROOT__/Debug-iphoneos/BatonPhysicalProbe.app'
    require(test.get('TestHostPath') in [host, host + '/BatonPhysicalProbe'])
    bundle = test_bundle_path(original)
    bundle_sha, bundle_count = tree_digest(bundle)
    require(0 < bundle_count <= 1024 and bundle_sha == config['testBundleTreeSHA256'])
    environment['baton.defaultsSuite'] = suite
    helper = repo / 'ios/scripts/app-attest-offline-proof.swift'
    regular(helper, bound=1024 * 1024)
    helper_text = helper.read_text()
    require(digest(helper) == config['helperSHA256'])
    # Bind exact equality guards, not an arbitrary occurrence in a comment.
    require(re.findall(r'e\.probeSuite == "([^"]+)"', helper_text) == [suite]
            and re.findall(r'e\.sourceCommit == "([^"]+)"', helper_text) == [config['captureSource']]
            and re.findall(r'e\.appBundleVersion == "([^"]+)"', helper_text) == [config['captureBuild']])
    require(set(config['sourceSHA256']) == set(SOURCE_NAMES))
    require(set(p.name for p in (repo / 'Packages/BatonShareKit/Sources/BatonShareKit').glob('*.swift'))
            == set(Path(p).name for p in SOURCE_NAMES if p.startswith('Packages/')))
    for name in SOURCE_NAMES:
        regular(repo / name, bound=1024 * 1024)
        require(digest(repo / name) == config['sourceSHA256'][name])
    require(digest(repo / 'gateway/Package.resolved') == config['dependencyPinsSHA256'])
    compiled = Path(config['compileReceipt']); regular(compiled, private=True, bound=1024 * 1024)
    require(compiled.name == 'compile-receipt.json' and digest(compiled) == config['compileReceiptSHA256'])
    receipt = json.loads(compiled.read_text())
    require(receipt['stages'] == [{'stage': 0, 'exit': 0}, {'stage': 1, 'exit': 0}]
            and receipt['helperSHA256'] == config['helperSHA256']
            and receipt['dependencyPinsMatch'] is True and receipt['deviceActions'] == 0
            and receipt['sourceSHA256'] == config['sourceSHA256'])
    runtime = receipt['runtimeSHA256']
    require(set(runtime) == set(RUNTIME_NAMES) and runtime == config['runtimeSHA256']
            and runtime['verify-proof'] == receipt['binarySHA256'])
    for name in RUNTIME_NAMES:
        regular(compiled.parent / name)
        require(digest(compiled.parent / name) == runtime[name])
    for name in ROOT_NAMES:
        require(runtime[ROOT_PREFIX + name] == digest(repo / 'gateway/Sources/BatonShareServer/AttestationRoots' / name))
    inputs = execution_inputs(config, repo, run, root)
    for name, expected in inputs.items():
        regular(Path(name)); require(digest(Path(name)) == expected)
    runner = (repo / 'ios/scripts/run-app-attest-physical-test.py').read_bytes()
    copy = (repo / 'ios/scripts/copy-app-attest-probe-evidence.py').read_bytes()
    owned = (repo / 'ios/scripts/app_attest_owned_controller.py').read_bytes()
    if prepared:
        require(runner_output.read_bytes() == runner and copy_output.read_bytes() == copy and
                (root / 'app_attest_owned_controller.py').read_bytes() == owned and
                plistlib.loads(run.read_bytes()) == x)
    # No text path replacement: exact copies obtain all paths from the pinned packet.
    for source in [runner, copy, owned]: ast.parse(source)
    return {'root': root, 'output': output, 'run': run, 'original': original, 'app': app,
            'appSHA': app_sha, 'xctestrun': plistlib.dumps(x), 'runner': runner, 'copy': copy,
            'owned': owned, 'compiled': compiled, 'runtime': runtime,
            'testBundle': bundle, 'testBundleSHA': bundle_sha, 'testBundleFiles': bundle_count}


def prepare(config, repo):
    packet = qualify(config, repo)
    # Requalify all inputs immediately before exclusive writes. No overwrites or
    # deletion/rollback on a partial write; retain evidence for external review.
    require(packet == qualify(config, repo))
    os.umask(0o077)
    packet['output'].mkdir(mode=0o700)
    entries = [(packet['run'], packet['xctestrun']),
               (packet['root'] / 'run-physical-test.py', packet['runner']),
               (packet['root'] / 'copy-probe-evidence.py', packet['copy']),
               (packet['root'] / 'app_attest_owned_controller.py', packet['owned'])]
    for path, data in entries:
        with path.open('xb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
    # The sibling preserves TESTROOT; only the suite differs semantically.
    restored = plistlib.loads(packet['run'].read_bytes())
    restored['BatonAppAttestPhysicalTests']['EnvironmentVariables']['baton.defaultsSuite'] = config['originalNamespace']
    require(restored == plistlib.loads(packet['original'].read_bytes())
            and digest(packet['original']) == config['originalXctestrunSHA256']
            and tree_digest(packet['app']) == (config['appTreeSHA256'], 21)
            and tree_digest(packet['testBundle']) == (config['testBundleTreeSHA256'], packet['testBundleFiles']))
    result = {'observedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'suite': config['namespace'], 'attemptRoot': str(packet['root']), 'sourceRepository': str(repo),
        'qualificationConfig': config, 'preparerSHA256': digest(repo / 'ios/scripts/prepare-app-attest-next-attempt.py'),
        'ownedAdapterSHA256': OWNED_SHA, 'runnerReplacementCount': 0, 'copyReplacementCount': 0,
        'xctestrunSuiteReplacementCount': 1,
        'originalXctestrunPath': str(packet['original']), 'retainedAppPath': str(packet['app']),
        'runtimeDirectory': str(packet['compiled'].parent),
        'testBundlePath': str(packet['testBundle']), 'testBundleTreeSHA256': packet['testBundleSHA'],
        'testBundleRegularFiles': packet['testBundleFiles'],
        'executionInputSHA256': execution_inputs(config, repo, packet['run'], packet['root'], prepared=True), 'captureSource': config['captureSource'], 'captureBuild': config['captureBuild'],
        'appTreeSHA256': packet['appSHA'], 'regularFiles': 21,
        'originalXctestrunSHA256': config['originalXctestrunSHA256'],
        'newXctestrunPath': str(packet['run']), 'newXctestrunSHA256': digest(packet['run']),
        'namespaceOnlySemanticDelta': True, 'testRootUnchanged': True,
        'acceptedRunnerTemplateSHA256': RUNNER_SHA, 'runnerSHA256': digest(entries[1][0]),
        'acceptedCopyTemplateSHA256': COPY_SHA, 'copyHelperSHA256': digest(entries[2][0]),
        'offlineBinarySHA256': packet['runtime']['verify-proof'], 'offlineRuntimeSHA256': packet['runtime'],
        'compileReceiptSHA256': config['compileReceiptSHA256'], 'offlineHelperSHA256': config['helperSHA256'],
        'verifierSourceSHA256': config['sourceSHA256'], 'dependencyPinsSHA256': config['dependencyPinsSHA256'],
        'historicalXctestrunUnchanged': True, 'physicalTestsRun': 0, 'deviceActions': 0,
        'policyActivated': False, 'executionAdmitted': False, 'unusedOnPhoneNamespaceQualified': False,
        'restoreRequired': True,
        'qualificationInputSHA256': hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()}
    with (packet['output'] / 'manifest.json').open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n'); stream.flush(); os.fsync(stream.fileno())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    args = parser.parse_args()
    regular(args.inputs, private=True, bound=1024 * 1024)
    result = prepare(json.loads(args.inputs.read_text()), Path(__file__).resolve().parents[2])
    print(json.dumps(result))


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(json.dumps({'result': 'FAIL', 'errorClass': type(error).__name__, 'privateDetailsWithheld': True}))
        raise SystemExit(1)
