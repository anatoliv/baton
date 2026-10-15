#!/usr/bin/env python3
"""Synthetic local packet admission checks. No child process, SDK or real artifact."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent
PREFIX = 'baton-gateway_BatonShareServer.bundle/Contents/Resources/AttestationRoots/'
ROOTS = ['Apple_App_Attestation_Root_CA.pem', 'AppleRootCA-G3.cer']
NAMES = ['verify-proof', 'libBatonShareKit.dylib', *[PREFIX + n for n in ROOTS]]
SHARING = ['ShareLedger', 'ShareClient', 'ShareWire', 'ShareLink', 'ShareLimits', 'ShareCrypto', 'ShareAttestation']

def load():
    spec = importlib.util.spec_from_file_location('next_attempt', SCRIPTS / 'prepare-app-attest-next-attempt.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data); path.chmod(0o600)

class NextAttemptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='baton-next-MOCK-', dir='/private/tmp')
        self.base = Path(self.temp.name); self.repo = self.base / 'repo'
        self.root = self.base / 'fresh'; self.root.mkdir(mode=0o700)
        self.prepare = load(); self.prepare.__file__ = str(self.repo / 'ios/scripts/prepare-app-attest-next-attempt.py')
        self.suite = 'probe-attest-0123456789abcdef0123456789abcdef'
        self.original_suite = 'probe-attest-minimal-20261005-8711'
        self.app = self.base / 'retained/Products/Debug-iphoneos/BatonPhysicalProbe.app'
        info = {'CFBundleIdentifier': 'io.tonebox.baton', 'CFBundleVersion': '1',
                'BatonPhysicalAttestProbe': True, 'BatonSourceCommit': '60368d111db2c58285ffb93beef5f85093ee8257'}
        write(self.app / 'Info.plist', plistlib.dumps(info))
        for i in range(20): write(self.app / ('synthetic-' + str(i)), b'public synthetic artifact')
        self.test_bundle = self.app.parent / 'BatonAppAttestPhysicalTests.xctest'
        write(self.test_bundle / 'BatonAppAttestPhysicalTests', b'SYNTHETIC test executable')
        self.original = self.app.parent.parent / 'Original.xctestrun'
        write(self.original, plistlib.dumps({'BatonAppAttestPhysicalTests': {'EnvironmentVariables': {
            'BATON_APP_ATTEST_PHYSICAL_ACCEPTANCE': '1', 'baton.defaultsSuite': self.original_suite},
            'TestHostPath': '__TESTROOT__/Debug-iphoneos/BatonPhysicalProbe.app',
            'TestBundlePath': '__TESTROOT__/Debug-iphoneos/BatonAppAttestPhysicalTests.xctest',
            'TestingEnvironmentVariables': {'DYLD_FRAMEWORK_PATH': '__TESTROOT__/Debug-iphoneos'}},
            '__xctestrun_metadata__': {'FormatVersion': 2}}))
        self.source = {}
        for path in [*['gateway/Sources/BatonShareServer/' + n + '.swift' for n in ['AppAttestVerifier', 'AppAttestReceipt', 'AppAttestCBOR']],
                     *['Packages/BatonShareKit/Sources/BatonShareKit/' + n + '.swift' for n in SHARING]]:
            write(self.repo / path, ('// synthetic ' + path).encode()); self.source[path] = sha(self.repo / path)
        for name in ROOTS: write(self.repo / 'gateway/Sources/BatonShareServer/AttestationRoots' / name, ('public synthetic ' + name).encode())
        write(self.repo / 'gateway/Package.resolved', b'{"pins":[]}')
        helper = re.sub(rb'(e\.probeSuite == ")[^"]+(")', lambda m: m[1] + self.suite.encode() + m[2], (SCRIPTS / 'app-attest-offline-proof.swift').read_bytes(), count=1)
        write(self.repo / 'ios/scripts/app-attest-offline-proof.swift', helper)
        for name in ['run-app-attest-physical-test.py', 'copy-app-attest-probe-evidence.py', 'app_attest_owned_controller.py', 'prepare-app-attest-next-attempt.py']:
            write(self.repo / 'ios/scripts' / name, (SCRIPTS / name).read_bytes())
        for name in ['incoming_fixture_lifecycle.py', 'mixtape_owned_supervision.py', 'mixtape_owned_lifecycle.py']:
            write(self.repo / 'scripts' / name, (SCRIPTS.parents[1] / 'scripts' / name).read_bytes())
        self.runtime_dir = self.base / 'qualified-runtime'
        for name in NAMES:
            data = (self.repo / 'gateway/Sources/BatonShareServer/AttestationRoots' / Path(name).name).read_bytes() if name.startswith(PREFIX) else ('SYNTHETIC ' + name).encode()
            write(self.runtime_dir / name, data)
        self.runtime = {name: sha(self.runtime_dir / name) for name in NAMES}
        self.receipt = self.runtime_dir / 'compile-receipt.json'
        receipt = {'stages': [{'stage': 0, 'exit': 0}, {'stage': 1, 'exit': 0}], 'dependencyPinsMatch': True,
                   'sourceSHA256': self.source, 'helperSHA256': sha(self.repo / 'ios/scripts/app-attest-offline-proof.swift'),
                   'binarySHA256': self.runtime['verify-proof'], 'runtimeSHA256': self.runtime, 'deviceActions': 0}
        write(self.receipt, json.dumps(receipt).encode())
        self.config = {'schemaVersion': 1, 'attemptRoot': str(self.root), 'namespace': self.suite,
            'originalXctestrun': str(self.original), 'originalXctestrunSHA256': sha(self.original),
            'originalNamespace': self.original_suite, 'testBundleTreeSHA256': self.prepare.tree_digest(self.test_bundle)[0], 'appTreeSHA256': self.prepare.tree_digest(self.app)[0],
            'captureSource': info['BatonSourceCommit'], 'captureBuild': '1',
            'compileReceipt': str(self.receipt), 'compileReceiptSHA256': sha(self.receipt),
            'helperSHA256': receipt['helperSHA256'], 'sourceSHA256': self.source,
            'dependencyPinsSHA256': sha(self.repo / 'gateway/Package.resolved'), 'runtimeSHA256': self.runtime}
        self.inputs = self.base / 'inputs.json'; self.save_config()
        # A baseline run must never inspect hardcoded historical real paths.
        self.prepare.OLD = self.base / 'old-MOCK'; self.prepare.NEXT = self.base / 'obsolete-MOCK'
        self.before = sha(self.original)

    def tearDown(self): self.temp.cleanup()
    def save_config(self): write(self.inputs, json.dumps(self.config).encode())
    def run_prepare(self):
        self.save_config()
        with patch.object(sys, 'argv', ['prepare', '--inputs', str(self.inputs)]), contextlib.redirect_stdout(io.StringIO()):
            self.prepare.main()
    def refused(self):
        with self.assertRaises((AssertionError, ValueError, KeyError, FileNotFoundError, FileExistsError)):
            self.run_prepare()
        self.assertEqual(sha(self.original), self.before)
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertEqual(list(self.original.parent.glob('BatonAppAttestPhysical-*.xctestrun')), [])

    def test_explicit_fresh_namespace_paths_and_complete_runtime(self):
        self.run_prepare()
        manifest = json.loads((self.root / 'attempt-plan/manifest.json').read_text())
        self.assertEqual(manifest['suite'], self.suite)
        self.assertEqual(manifest['offlineRuntimeSHA256'], self.runtime)
        self.assertEqual(manifest['verifierSourceSHA256'], self.source)
        run = Path(manifest['newXctestrunPath']); x = plistlib.loads(run.read_bytes())
        x['BatonAppAttestPhysicalTests']['EnvironmentVariables']['baton.defaultsSuite'] = self.original_suite
        self.assertEqual(x, plistlib.loads(self.original.read_bytes()))
        self.assertEqual(sha(self.original), self.before)
        runner = (self.root / 'run-physical-test.py').read_text()
        self.assertEqual(manifest['runtimeDirectory'], str(self.runtime_dir))
        self.assertEqual(runner.encode(), (SCRIPTS / 'run-app-attest-physical-test.py').read_bytes())
        self.assertIn(str(self.root / 'app_attest_owned_controller.py'), manifest['executionInputSHA256'])
        self.assertNotIn('/private/tmp/baton-tbx8711-minimal-host-20261005', runner)
        copy = (self.root / 'copy-probe-evidence.py').read_text()
        self.assertEqual(copy.encode(), (SCRIPTS / 'copy-app-attest-probe-evidence.py').read_bytes()); self.assertNotIn('probe-attest-minimal-20261006-8711', copy)
        for p in [run, self.root / 'run-physical-test.py', self.root / 'copy-probe-evidence.py', self.root / 'app_attest_owned_controller.py', self.root / 'attempt-plan/manifest.json']:
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        self.assertEqual(manifest['physicalTestsRun'], 0)

    def use_embedded_test_host_bundle(self, bundle_path='__TESTHOST__/PlugIns/BatonAppAttestPhysicalTests.xctest',
                                      host_path='__TESTROOT__/Debug-iphoneos/BatonPhysicalProbe.app'):
        self.test_bundle = self.app / 'PlugIns/BatonAppAttestPhysicalTests.xctest'
        write(self.test_bundle / 'BatonAppAttestPhysicalTests', b'SYNTHETIC embedded test executable')
        (self.app / 'synthetic-19').unlink()  # Preserve the qualified 21-file synthetic app.
        x = plistlib.loads(self.original.read_bytes())
        x['BatonAppAttestPhysicalTests']['TestBundlePath'] = bundle_path
        x['BatonAppAttestPhysicalTests']['TestHostPath'] = host_path
        write(self.original, plistlib.dumps(x))
        self.before = sha(self.original)
        self.config.update(originalXctestrunSHA256=self.before,
                           appTreeSHA256=self.prepare.tree_digest(self.app)[0],
                           testBundleTreeSHA256=self.prepare.tree_digest(self.test_bundle)[0])

    def test_xcode_embedded_testhost_alias_preserves_artifact_and_only_changes_namespace(self):
        self.use_embedded_test_host_bundle()
        self.run_prepare()
        manifest = json.loads((self.root / 'attempt-plan/manifest.json').read_text())
        self.assertEqual(manifest['testBundlePath'], str(self.test_bundle))
        self.assertEqual(manifest['testBundleTreeSHA256'], self.config['testBundleTreeSHA256'])
        x = plistlib.loads(Path(manifest['newXctestrunPath']).read_bytes())
        x['BatonAppAttestPhysicalTests']['EnvironmentVariables']['baton.defaultsSuite'] = self.original_suite
        self.assertEqual(x, plistlib.loads(self.original.read_bytes()))
        self.assertEqual(sha(self.original), self.before)
        self.assertFalse(manifest['executionAdmitted'])
        self.assertFalse(manifest['unusedOnPhoneNamespaceQualified'])
        self.assertEqual(manifest['deviceActions'], 0)

    def test_testhost_alias_with_host_executable_path_uses_app_directory(self):
        self.use_embedded_test_host_bundle(host_path='__TESTROOT__/Debug-iphoneos/BatonPhysicalProbe.app/BatonPhysicalProbe')
        self.run_prepare()
        manifest = json.loads((self.root / 'attempt-plan/manifest.json').read_text())
        self.assertEqual(manifest['testBundlePath'], str(self.test_bundle))

    def test_testhost_bundle_traversal_is_refused(self):
        self.use_embedded_test_host_bundle('__TESTHOST__/PlugIns/../PlugIns/BatonAppAttestPhysicalTests.xctest')
        self.refused()

    def test_testhost_foreign_host_is_refused(self):
        self.use_embedded_test_host_bundle(host_path='__TESTROOT__/Debug-iphoneos/Another.app')
        self.refused()

    def test_testhost_host_traversal_is_refused(self):
        self.use_embedded_test_host_bundle(host_path='__TESTROOT__/Debug-iphoneos/../Debug-iphoneos/BatonPhysicalProbe.app')
        self.refused()

    def test_testhost_symlink_parent_is_refused_even_with_matching_tree_digest(self):
        self.use_embedded_test_host_bundle()
        (self.app / 'PlugIns').rename(self.app / 'actual-plugins')
        (self.app / 'PlugIns').symlink_to(self.app / 'actual-plugins')
        self.config['appTreeSHA256'] = self.prepare.tree_digest(self.app)[0]
        self.refused()

    def test_testhost_foreign_owned_bundle_file_is_refused(self):
        self.use_embedded_test_host_bundle()
        executable = self.test_bundle / 'BatonAppAttestPhysicalTests'
        original_lstat = Path.lstat
        def foreign_lstat(path):
            value = original_lstat(path)
            if path == executable:
                fields = list(value); fields[4] = os.getuid() + 1
                return os.stat_result(fields)
            return value
        with patch.object(Path, 'lstat', foreign_lstat):
            self.refused()

    def test_testhost_test_bundle_tree_identity_mismatch_is_refused(self):
        self.use_embedded_test_host_bundle()
        self.config['testBundleTreeSHA256'] = '0' * 64
        self.refused()

    def test_testhost_capture_build_identity_mismatch_is_refused(self):
        self.use_embedded_test_host_bundle()
        self.config['captureBuild'] = '2'
        self.refused()

    def capture_association_fixture(self):
        spec = importlib.util.spec_from_file_location('physical_runner', SCRIPTS / 'run-app-attest-physical-test.py')
        runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
        source = self.repo / 'ios/Tests/BatonAppAttestPhysicalTests/AppAttestIssuancePhysicalTests.swift'
        write(source, b'// SYNTHETIC capture source, never compiled')
        build = self.root / 'capture-build-receipt.json'
        # Match the retained receipt's missing association fields. A successful
        # historical build is not a fresh namespace/source/build proof.
        write(build, json.dumps({'exit': 0, 'generationExit': 0, 'source': 'a' * 40,
                                 'inputSHA256': {str(source): sha(source)}, 'inputsUnchanged': True}).encode())
        evidence = {'schemaVersion': 1, 'namespace': self.suite,
                    'testIdentifier': runner.TEST_IDENTIFIER,
                    'appTreeSHA256': self.config['appTreeSHA256'],
                    'testBundleTreeSHA256': self.config['testBundleTreeSHA256'],
                    'newXctestrunSHA256': '0' * 64, 'testSourceSHA256': sha(source),
                    'buildReceiptSHA256': sha(build), 'independentNamespaceAssociationQualified': True}
        path = self.root / 'capture-namespace-evidence.json'; write(path, json.dumps(evidence).encode())
        binding = {'captureNamespaceEvidencePath': str(path), 'captureNamespaceEvidenceSHA256': sha(path)}
        packet = {'suite': self.suite, 'appTreeSHA256': evidence['appTreeSHA256'],
                  'testBundleTreeSHA256': evidence['testBundleTreeSHA256'],
                  'newXctestrunSHA256': evidence['newXctestrunSHA256']}
        return runner, binding, packet, source

    def test_historical_build_receipt_cannot_be_promoted_to_namespace_association(self):
        runner, binding, packet, source = self.capture_association_fixture()
        with self.assertRaises(ValueError):
            runner.qualify_capture_namespace(self.root / 'binding.json', binding, packet, self.repo)

    def test_missing_capture_source_refuses_namespace_association(self):
        runner, binding, packet, source = self.capture_association_fixture()
        source.unlink()
        with self.assertRaises(ValueError):
            runner.qualify_capture_namespace(self.root / 'binding.json', binding, packet, self.repo)

    def test_changed_namespace_requires_matching_new_compilation(self):
        self.config['namespace'] = self.suite.replace('0123456789abcdef', 'fedcba9876543210'); self.refused()
    def test_missing_runtime_part_is_not_historical_qualification(self):
        self.config['runtimeSHA256'] = {'verify-proof': self.runtime['verify-proof']}; self.refused()
    def test_changed_linked_runtime_is_refused(self):
        write(self.runtime_dir / 'libBatonShareKit.dylib', b'TAMPER'); self.refused()
    def test_changed_trust_root_is_refused(self):
        write(self.runtime_dir / (PREFIX + ROOTS[0]), b'TAMPER'); self.refused()
    def test_partial_verifier_source_set_is_refused(self):
        self.config['sourceSHA256'] = dict(list(self.source.items())[:1]); self.refused()
    def test_changed_source_is_refused(self):
        write(self.repo / next(iter(self.source)), b'TAMPER'); self.refused()
    def test_changed_dependency_pin_is_refused(self):
        write(self.repo / 'gateway/Package.resolved', b'{"pins":["drift"]}'); self.refused()
    def test_changed_retained_app_is_refused(self):
        write(self.app / 'synthetic-0', b'TAMPER'); self.refused()
    def test_changed_retained_xctestrun_is_refused(self):
        write(self.original, b'TAMPER'); self.before = sha(self.original); self.refused()
    def test_original_namespace_cannot_be_reused(self):
        self.config['namespace'] = self.original_suite; self.refused()
    def test_existing_root_is_preserved(self):
        sentinel = self.root / 'retained'; write(sentinel, b'keep')
        with self.assertRaises((AssertionError, ValueError, FileExistsError)): self.run_prepare()
        self.assertEqual(sentinel.read_bytes(), b'keep'); self.assertEqual(sha(self.original), self.before)
    def test_non_private_root_is_refused(self):
        self.root.chmod(0o755); self.refused()
    def test_symlink_root_is_refused(self):
        self.root.rmdir(); self.root.symlink_to(self.base / 'elsewhere'); self.config['attemptRoot'] = str(self.root)
        with self.assertRaises((AssertionError, ValueError, FileNotFoundError)): self.run_prepare()
        self.assertFalse((self.base / 'elsewhere').exists())
    def test_changed_runner_template_is_refused(self):
        write(self.repo / 'ios/scripts/run-app-attest-physical-test.py', b'TAMPER'); self.refused()
    def test_historical_nonunique_namespace_is_refused(self):
        self.config['namespace'] = 'probe-attest-minimal-20261006-8711'; self.refused()
    def test_existing_sibling_xctestrun_is_preserved(self):
        sibling = self.original.with_name('BatonAppAttestPhysical-' + self.suite + '.xctestrun')
        write(sibling, b'retained sibling evidence')
        with self.assertRaises(ValueError): self.run_prepare()
        self.assertEqual(sibling.read_bytes(), b'retained sibling evidence')
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertEqual(sha(self.original), self.before)
    def test_capture_identity_mismatch_is_refused(self):
        self.config['captureSource'] = 'f' * 40; self.refused()
    def test_unknown_configuration_field_is_refused(self):
        self.config['override'] = True; self.refused()
    def test_nonprivate_input_is_refused_before_any_output(self):
        self.inputs.chmod(0o644)
        with patch.object(sys, 'argv', ['prepare', '--inputs', str(self.inputs)]):
            with self.assertRaises(ValueError): self.prepare.main()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_changed_copy_template_is_refused(self):
        write(self.repo / 'ios/scripts/copy-app-attest-probe-evidence.py', b'TAMPER'); self.refused()

if __name__ == '__main__': unittest.main(verbosity=2)
