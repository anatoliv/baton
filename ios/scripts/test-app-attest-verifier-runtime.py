#!/usr/bin/env python3
"""Public preparer regressions with synthetic inputs and a mocked compiler: NO SDK."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent
ROOT_NAMES = ['Apple_App_Attestation_Root_CA.pem', 'AppleRootCA-G3.cer']
ROOT_PREFIX = 'baton-gateway_BatonShareServer.bundle/Contents/Resources/AttestationRoots/'
RUNTIME_NAMES = ['verify-proof', 'libBatonShareKit.dylib', *[ROOT_PREFIX + n for n in ROOT_NAMES]]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SCRIPTS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class VerifierRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='baton-verifier-runtime-', dir='/private/tmp')
        self.base = Path(self.temporary.name)
        self.repo = self.base / 'repo'
        self.dependency = self.base / 'dependency'
        self.old = self.base / 'old'
        self.next = self.base / 'next'
        self.next.mkdir(mode=0o700)
        self.compile = load('prepare-app-attest-offline-verifier')
        self.prepare = load('prepare-app-attest-next-attempt')
        self.compile.__file__ = str(self.repo / 'ios/scripts/prepare-app-attest-offline-verifier.py')
        self.prepare.__file__ = str(self.repo / 'ios/scripts/prepare-app-attest-next-attempt.py')
        self.verifier = self.base / 'offline-verifier-MOCK'
        self.products = self.dependency / 'gateway/.build/out/Products/Debug'
        for parent in [self.repo, self.dependency]:
            self.write(parent / 'gateway/Package.resolved', json.dumps({'pins': [{'identity': 'synthetic-dependency', 'state': {'revision': '0' * 40}}]}).encode())
        for name in ['ShareLedger', 'ShareClient', 'ShareWire', 'ShareLink', 'ShareLimits', 'ShareCrypto', 'ShareAttestation']:
            self.write(self.repo / 'Packages/BatonShareKit/Sources/BatonShareKit' / (name + '.swift'), b'// Synthetic compiler input\n')
        for name in ['AppAttestVerifier.swift', 'AppAttestReceipt.swift', 'AppAttestCBOR.swift']:
            self.write(self.repo / 'gateway/Sources/BatonShareServer' / name, b'// Synthetic verifier input\n')
        for name in ROOT_NAMES:
            data = ('Synthetic public root ' + name).encode()
            self.write(self.repo / 'gateway/Sources/BatonShareServer/AttestationRoots' / name, data)
            self.write(self.products / ROOT_PREFIX / name, data)
        self.suite = 'probe-attest-minimal-20261007-8711-0123456789abcdef0123456789abcdef'
        self.old_suite = 'probe-attest-minimal-20261005-8711'
        self.write(self.repo / 'ios/scripts/app-attest-offline-proof.swift', re.sub(rb'(e\.probeSuite == ")[^"]+(")', lambda m: m[1] + self.suite.encode() + m[2], (SCRIPTS / 'app-attest-offline-proof.swift').read_bytes(), count=1))
        self.runner = self.repo / 'ios/scripts/run-app-attest-physical-test.py'
        self.write(self.runner, (SCRIPTS / 'run-app-attest-physical-test.py').read_bytes())
        self.write(self.repo / 'ios/scripts/copy-app-attest-probe-evidence.py', (SCRIPTS / 'copy-app-attest-probe-evidence.py').read_bytes())
        self.original = self.old / 'derived-data/Build/Products/BatonAppAttestPhysical_iphoneos27.0-arm64.xctestrun'
        data = {'BatonAppAttestPhysicalTests': {'EnvironmentVariables': {
            'BATON_APP_ATTEST_PHYSICAL_ACCEPTANCE': '1', 'baton.defaultsSuite': self.old_suite}, 'TestHostPath': '__TESTROOT__/Debug-iphoneos/BatonPhysicalProbe.app', 'TestBundlePath': '__TESTROOT__/Debug-iphoneos/BatonAppAttestPhysicalTests.xctest'}, '__xctestrun_metadata__': {}}
        self.write(self.original, plistlib.dumps(data)); self.original_sha = sha(self.original)
        app = self.original.parent / 'Debug-iphoneos/BatonPhysicalProbe.app'
        self.write(app / 'Info.plist', plistlib.dumps({'CFBundleIdentifier': 'io.tonebox.baton', 'BatonPhysicalAttestProbe': True, 'BatonSourceCommit': '60368d111db2c58285ffb93beef5f85093ee8257', 'CFBundleVersion': '1'}))
        for index in range(20): self.write(app / ('synthetic-' + str(index)), str(index).encode())
        self.app_sha = self.prepare.tree_digest(app)[0]
        self.compiler_calls = []
        def mocked_compiler(command, **kwargs):
            self.compiler_calls.append(command)
            self.write(Path(command[command.index('-o') + 1]), b'synthetic-library' if '-emit-library' in command else b'synthetic-main')
            return subprocess.CompletedProcess(command, 0)
        args = ['prepare-app-attest-offline-verifier.py', '--dependency-checkout', str(self.dependency), '--destination', str(self.verifier)]
        with patch.object(sys, 'argv', args), patch.object(self.compile.subprocess, 'run', mocked_compiler), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as stopped: self.compile.main()
        self.assertEqual(stopped.exception.code, 0)
        self.assertEqual(len(self.compiler_calls), 2, 'Two mocked calls, zero native compiler executions')

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def receipt(self):
        return json.loads((self.verifier / 'compile-receipt.json').read_text())

    def qualify_synthetic_receipt(self):
        # Deliberately complete SYNTHETIC receipt for acceptance/drift regressions.
        # Never augment a retained real compilation receipt.
        receipt = self.receipt()
        receipt['runtimeSHA256'] = {name: sha(self.verifier / name) for name in RUNTIME_NAMES}
        (self.verifier / 'compile-receipt.json').write_text(json.dumps(receipt))
        return receipt['runtimeSHA256']

    def prepare_attempt(self):
        receipt = self.receipt()
        config = {'schemaVersion': 1, 'attemptRoot': str(self.next), 'namespace': self.suite,
            'originalXctestrun': str(self.original), 'originalXctestrunSHA256': self.original_sha,
            'originalNamespace': self.old_suite, 'appTreeSHA256': self.app_sha,
            'captureSource': '60368d111db2c58285ffb93beef5f85093ee8257', 'captureBuild': '1',
            'compileReceipt': str(self.verifier / 'compile-receipt.json'), 'compileReceiptSHA256': sha(self.verifier / 'compile-receipt.json'),
            'helperSHA256': receipt['helperSHA256'], 'sourceSHA256': receipt['sourceSHA256'],
            'dependencyPinsSHA256': sha(self.repo / 'gateway/Package.resolved'), 'runtimeSHA256': receipt.get('runtimeSHA256', {})}
        with contextlib.redirect_stdout(io.StringIO()): self.prepare.prepare(config, self.repo)

    def assert_refused_before_output(self):
        with self.assertRaises((AssertionError, KeyError, FileNotFoundError, ValueError)):
            self.prepare_attempt()
        self.assertFalse((self.next / 'attempt-plan').exists())
        self.assertFalse(self.original.with_name('BatonAppAttestPhysical-' + self.suite + '.xctestrun').exists())
        self.assertEqual(sha(self.original), self.original_sha)

    def test_new_compilation_receipt_pins_all_four_runtime_parts(self):
        self.assertEqual(self.receipt().get('runtimeSHA256'), {name: sha(self.verifier / name) for name in RUNTIME_NAMES})

    def test_qualified_unchanged_runtime_is_pinned_in_attempt(self):
        expected = self.qualify_synthetic_receipt()
        self.prepare_attempt()
        manifest = json.loads((self.next / 'attempt-plan/manifest.json').read_text())
        self.assertEqual(manifest.get('offlineRuntimeSHA256'), expected)
        self.assertEqual(manifest['offlineBinarySHA256'], expected['verify-proof'])

    def test_changed_library_refused_with_unchanged_main(self):
        expected = self.qualify_synthetic_receipt()
        (self.verifier / 'libBatonShareKit.dylib').write_bytes(b'changed-runtime-library')
        self.assertEqual(sha(self.verifier / 'verify-proof'), expected['verify-proof'])
        self.assert_refused_before_output()

    def test_missing_library_refused_with_unchanged_main(self):
        expected = self.qualify_synthetic_receipt()
        (self.verifier / 'libBatonShareKit.dylib').unlink()
        self.assertEqual(sha(self.verifier / 'verify-proof'), expected['verify-proof'])
        self.assert_refused_before_output()

    def test_unqualified_old_receipt_refused(self):
        receipt = self.receipt(); receipt.pop('runtimeSHA256', None)
        (self.verifier / 'compile-receipt.json').write_text(json.dumps(receipt))
        self.assert_refused_before_output()

    def test_changed_public_root_refused(self):
        self.qualify_synthetic_receipt()
        (self.verifier / (ROOT_PREFIX + ROOT_NAMES[0])).write_bytes(b'changed-root')
        self.assert_refused_before_output()

    def test_missing_public_root_refused(self):
        self.qualify_synthetic_receipt()
        (self.verifier / (ROOT_PREFIX + ROOT_NAMES[1])).unlink()
        self.assert_refused_before_output()

    def test_namespace_refusal_preserved(self):
        self.qualify_synthetic_receipt()
        (self.repo / 'ios/scripts/app-attest-offline-proof.swift').write_text(self.old_suite)
        self.assert_refused_before_output()

    def test_existing_attempt_destination_is_not_overwritten(self):
        self.qualify_synthetic_receipt()
        output = self.next / 'attempt-plan'; output.mkdir(mode=0o700)
        sentinel = output / 'retained'; sentinel.write_bytes(b'retained-evidence')
        with self.assertRaises((AssertionError, ValueError)): self.prepare_attempt()
        self.assertEqual(sentinel.read_bytes(), b'retained-evidence')
        self.assertEqual(sha(self.original), self.original_sha)


if __name__ == '__main__': unittest.main(verbosity=2)
