#!/usr/bin/env python3
"""CPU-only incoming invocation boundaries; no wrapper or child is launched."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('incoming_binding',
    Path(__file__).with_name('exec-incoming-command-binding.py'))
binding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binding)


class IncomingBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        os.chmod(self.root, 0o700)
        self.repo = self.root / 'repo'
        (self.repo / 'scripts').mkdir(parents=True)
        self.runner = self.repo / 'scripts/exec-incoming-command-binding.py'
        self.runner.write_bytes(b'pinned source')
        binary = self.root / 'baton-share'
        binary.write_bytes(b'synthetic executable bytes; never executed')
        self.bundle = self.root / 'baton-gateway_BatonShareServer.bundle'
        self.bundle.mkdir()
        resource = self.bundle / 'resource'
        resource.write_bytes(b'synthetic resource')
        pins = self.root / 'project.xcworkspace/Package.resolved'
        pins.parent.mkdir()
        pins.write_bytes(b'synthetic pins')
        def item(p):
            return dict(path=str(p), bytes=p.stat().st_size,
                        sha256=hashlib.sha256(p.read_bytes()).hexdigest())
        self.data = dict(cwd=str(self.repo), executionSource='a'*40,
            sourceSHA256={'scripts/exec-incoming-command-binding.py':
                hashlib.sha256(self.runner.read_bytes()).hexdigest()},
            inputs=dict(serviceBinary=item(binary), packagePins=item(pins),
                resourceBundle=dict(path=str(self.bundle), files=[item(resource)]),
                packageCache=dict(path=str(self.root/'cache')),
                navidromeImage=dict(requested='sha256:'+'b'*64)),
            command=dict(log=str(self.root/'future.log'), argv=[binding.CALLER, '--run',
                '--share-bin', str(binary), '--share-bin-sha256', item(binary)['sha256'],
                '--package-cache', str(self.root/'cache'), '--package-pins', str(pins),
                '--navidrome-image', 'sha256:'+'b'*64, '--only-test', binding.SELECTOR]))
        self.path = self.root / 'binding.json'
        self.write()
        self.git = patch.object(binding.subprocess, 'check_output',
                                side_effect=['a'*40+'\n', ''])
        self.git.start()

    def write(self):
        self.path.write_text(json.dumps(self.data))
        os.chmod(self.path, 0o600)
        self.digest = hashlib.sha256(self.path.read_bytes()).hexdigest()

    def tearDown(self):
        self.git.stop()
        self.temp.cleanup()

    def test_execv_receives_entire_bound_argv_without_transcription(self):
        argv, log = binding.validate(self.path, self.digest, self.repo)
        self.assertEqual(argv, self.data['command']['argv'])
        self.assertIn('project.xcworkspace', argv[9])
        with patch.object(binding, 'validate', return_value=(argv, log)), \
             patch.object(binding.os, 'open', return_value=99), \
             patch.object(binding.os, 'dup2'), patch.object(binding.os, 'close'), \
             patch.object(binding.os, 'chdir'), patch.object(binding.os, 'umask'), \
             patch.object(binding.os, 'execv') as replace:
            binding.invoke(self.path, self.digest, self.repo)
        replace.assert_called_once_with(argv[0], self.data['command']['argv'])
        self.assertFalse(log.exists())

    def test_changed_binding_refuses_before_exec(self):
        self.path.write_bytes(self.path.read_bytes()+b' ')
        with patch.object(binding.os, 'execv') as replace, self.assertRaisesRegex(ValueError, 'digest'):
            binding.invoke(self.path, self.digest, self.repo)
        replace.assert_not_called()

    def test_owner_only_modes_and_regular_file_required(self):
        for file_mode, parent_mode in [(0o644,0o700),(0o600,0o755)]:
            with self.subTest(file=file_mode,parent=parent_mode):
                os.chmod(self.path,file_mode);os.chmod(self.root,parent_mode)
                with self.assertRaisesRegex(ValueError,'Owner-only'):
                    binding.private_binding(self.path,self.digest)
        os.chmod(self.root,0o700);os.chmod(self.path,0o600)
        link=self.root/'alias.json';link.symlink_to(self.path)
        with self.assertRaisesRegex(ValueError,'Canonical'):
            binding.private_binding(link,self.digest)

    def test_changed_source_refuses_before_exec(self):
        self.runner.write_bytes(b'changed source')
        with patch.object(binding.os,'execv') as replace, self.assertRaisesRegex(ValueError,'source bytes'):
            binding.invoke(self.path,self.digest,self.repo)
        replace.assert_not_called()

    def test_wrong_workspace_argument_refuses_even_with_new_digest(self):
        self.data['command']['argv'][9]=self.data['command']['argv'][9].replace('xcworkspace','xworkspace')
        self.write()
        with patch.object(binding.os,'execv') as replace, self.assertRaisesRegex(ValueError,'arguments mismatch'):
            binding.invoke(self.path,self.digest,self.repo)
        replace.assert_not_called()


if __name__ == '__main__':
    unittest.main()
