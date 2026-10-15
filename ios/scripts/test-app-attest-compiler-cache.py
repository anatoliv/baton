#!/usr/bin/env python3
"""Path-admission regressions with public synthetic inputs; no compiler or SDK."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


class CompilerCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='baton-cache-MOCK-', dir='/private/tmp')
        self.base = Path(self.temporary.name)
        spec = importlib.util.spec_from_file_location('cache_preparer',
            Path(__file__).with_name('prepare-app-attest-offline-verifier.py'))
        self.module = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.module)
        self.repo = self.base / 'repo'; self.dependency = self.base / 'dependency'
        self.module.__file__ = str(self.repo / 'ios/scripts/prepare-app-attest-offline-verifier.py')
        self.parent = self.base / 'attempt'; self.parent.mkdir(mode=0o700)
        self.output = self.parent / 'offline-verifier'
        for root in [self.repo, self.dependency]:
            self.write(root / 'gateway/Package.resolved', b'{"pins":[]}')
        self.write(self.repo / 'ios/scripts/app-attest-offline-proof.swift', b'// synthetic helper')
        self.write(self.repo / 'Packages/BatonShareKit/Sources/BatonShareKit/Share.swift', b'// synthetic share')
        for name in ['AppAttestVerifier', 'AppAttestReceipt', 'AppAttestCBOR']:
            self.write(self.repo / 'gateway/Sources/BatonShareServer' / (name + '.swift'), b'// synthetic verifier')
        prefix = 'baton-gateway_BatonShareServer.bundle/Contents/Resources/AttestationRoots'
        for name in ['Apple_App_Attestation_Root_CA.pem', 'AppleRootCA-G3.cer']:
            self.write(self.repo / 'gateway/Sources/BatonShareServer/AttestationRoots' / name, b'synthetic public root')
            self.write(self.dependency / 'gateway/.build/out/Products/Debug' / prefix / name, b'synthetic public root')

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)

    def invoke(self, destination=None, compiler=None):
        args = ['preparer', '--dependency-checkout', str(self.dependency),
                '--destination', str(destination or self.output)]
        child = compiler or Mock(return_value=subprocess.CompletedProcess([], 0))
        error = None
        with patch.object(sys, 'argv', args), patch.object(self.module.subprocess, 'run', child), contextlib.redirect_stdout(io.StringIO()):
            try: self.module.main()
            except BaseException as caught: error = caught
        return error, child

    def test_symlink_parent_refused_before_output_or_compiler(self):
        alias = self.base / 'alias'; alias.symlink_to(self.parent, target_is_directory=True)
        error, child = self.invoke(alias / 'offline-verifier')
        self.assertEqual(child.call_count, 0, 'Refused destination reached mocked compiler')
        self.assertIsInstance(error, ValueError); self.assertFalse(self.output.exists())

    def test_existing_destination_retains_prior_bytes(self):
        self.output.mkdir(mode=0o700); sentinel = self.output / 'prior'; sentinel.write_bytes(b'retained')
        error, child = self.invoke()
        self.assertIsInstance(error, ValueError); child.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b'retained')
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_destination_symlink_refused_without_touching_target(self):
        target = self.base / 'retained'; target.mkdir(mode=0o700)
        sentinel = target / 'prior'; sentinel.write_bytes(b'retained')
        self.output.symlink_to(target, target_is_directory=True)
        error, child = self.invoke()
        self.assertIsInstance(error, ValueError); child.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b'retained'); self.assertEqual(list(target.iterdir()), [sentinel])

    def test_nonprivate_parent_refused_before_output(self):
        self.parent.chmod(0o755)
        error, child = self.invoke()
        self.assertIsInstance(error, ValueError); child.assert_not_called(); self.assertFalse(self.output.exists())

    def test_relative_destination_refused_before_output(self):
        error, child = self.invoke(Path('synthetic-relative-destination'))
        self.assertIsInstance(error, ValueError); child.assert_not_called(); self.assertFalse(self.output.exists())

    def collision(self, symlink=False):
        original_mkdir = Path.mkdir
        target = self.base / 'other-cache'; target.mkdir(mode=0o700)
        sentinel = target / 'prior'; sentinel.write_bytes(b'retained')
        def mkdir(path, *args, **kwargs):
            result = original_mkdir(path, *args, **kwargs)
            if path == self.output:
                cache = path / 'module-cache'
                if symlink: cache.symlink_to(target, target_is_directory=True)
                else:
                    original_mkdir(cache, mode=0o700); (cache / 'prior').write_bytes(b'retained')
            return result
        with patch.object(Path, 'mkdir', mkdir): error, child = self.invoke()
        self.assertIsInstance(error, ValueError); child.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b'retained')
        self.assertEqual((self.output / 'module-cache/prior').read_bytes(), b'retained')
        self.assertFalse((self.output / 'compile-0.log').exists())

    def test_preexisting_cache_collision_refuses_without_removal(self): self.collision()
    def test_cache_symlink_collision_refuses_without_target_write(self): self.collision(symlink=True)

    def test_private_cache_exists_before_both_mocked_stages(self):
        cache = self.output / 'module-cache'; identities = []
        def compiler(_command, **_kwargs):
            info = cache.lstat(); identities.append(info.st_ino)
            self.assertTrue(stat.S_ISDIR(info.st_mode)); self.assertEqual(info.st_uid, os.getuid())
            self.assertEqual(stat.S_IMODE(info.st_mode), 0o700); self.assertEqual(cache.resolve(), cache)
            (cache / 'synthetic-module').write_bytes(b'private synthetic cache')
            (self.output / ('libBatonShareKit.dylib' if len(identities) == 1 else 'verify-proof')).write_bytes(b'synthetic-runtime')
            return subprocess.CompletedProcess([], 0)
        error, _ = self.invoke(compiler=compiler)
        self.assertIsInstance(error, SystemExit); self.assertEqual(error.code, 0)
        self.assertEqual(len(identities), 2); self.assertEqual(identities[0], identities[1])
        self.assertEqual((cache / 'synthetic-module').read_bytes(), b'private synthetic cache')
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        receipt = json.loads((self.output / 'compile-receipt.json').read_bytes())
        self.assertEqual(receipt['stages'], [{'stage': 0, 'exit': 0}, {'stage': 1, 'exit': 0}])


if __name__ == '__main__': unittest.main(verbosity=2)
