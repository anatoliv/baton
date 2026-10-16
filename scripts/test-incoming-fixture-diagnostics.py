#!/usr/bin/env python3
"""Persisted diagnostics from harmless real owned commands; no native resources."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

from incoming_fixture_lifecycle import Deadline, FixtureDiagnosticFailure, write_failure
from owned_fixture_cpu_support import retained_cpu_fixture
from incoming_fixture_packages import validate_cache


class DiagnosticTests(unittest.TestCase):
    def test_owned_exact_data_capture_excludes_stderr_and_keeps_private_evidence(self):
        revision = '2849f5323265386e200484b0d0f896e73c3411b9'
        marker = 'synthetic-private-stderr-data-marker'
        with retained_cpu_fixture('incoming-data-capture-') as (root, owned):
            data, rc = owned.command([sys.executable, '-c',
                'import sys; print(sys.argv[1]); print(sys.argv[2],file=sys.stderr)',
                revision, marker], cap=2, stdout_only=True)
            self.assertEqual(rc, 0)
            self.assertEqual(data.decode().strip(), revision)
            captures = list(root.glob('command-stderr-*.log'))
            self.assertEqual(len(captures), 1)
            self.assertIn(marker.encode(), captures[0].read_bytes())
            self.assertEqual(captures[0].stat().st_mode & 0o777, 0o600)
            self.assertNotIn(marker, (root/'ownership.json').read_text())
    def test_owned_default_capture_preserves_existing_merged_response(self):
        with retained_cpu_fixture('incoming-default-capture-') as (root, owned):
            data, rc = owned.command([sys.executable, '-c',
                'import sys; print("response",flush=True); print("diagnostic",file=sys.stderr)'], cap=2)
            self.assertEqual(rc, 0)
            self.assertEqual(data.splitlines(), [b'response', b'diagnostic'])
            self.assertEqual(list(root.glob('command-stderr-*.log')), [])
    def test_failed_owned_command_retains_safe_operation_without_private_output(self):
        marker = 'synthetic-private-diagnostic-marker'
        with retained_cpu_fixture('incoming-diagnostic-') as (root, owned):
            with self.assertRaises(RuntimeError) as failure:
                owned.command([sys.executable, '-c',
                               'import sys; print(sys.argv[1]); sys.exit(17)', marker])
            write_failure(root/'failure.json', failure.exception, 'cache', 'manifest-read')
            receipt = json.loads((root/'failure.json').read_text())
            self.assertEqual(receipt['stage'], 'cache')
            self.assertEqual(receipt['operation'], 'manifest-read')
            self.assertEqual(receipt['code'], 'owned-command-nonzero')
            self.assertEqual(receipt['kind'], 'RuntimeError')
            self.assertNotIn(marker, (root/'failure.json').read_text())
            self.assertNotIn(str(root), (root/'failure.json').read_text())
    def test_actual_timeout_retains_safe_code_and_exact_group_cleanup(self):
        marker = 'synthetic-timeout-private-marker'
        with retained_cpu_fixture('incoming-diagnostic-timeout-') as (root, owned):
            with self.assertRaises(RuntimeError) as failure:
                owned.command([sys.executable, '-c',
                    'import sys,time; print(sys.argv[1],flush=True); time.sleep(30)', marker], cap=.05)
            write_failure(root/'failure.json', failure.exception, 'cache', 'manifest-read')
            receipt = json.loads((root/'failure.json').read_text())
            self.assertEqual((receipt['stage'], receipt['operation'], receipt['code']),
                             ('cache', 'manifest-read', 'owned-command-timeout'))
            self.assertNotIn(marker, (root/'failure.json').read_text())
            self.assertNotIn(str(root), (root/'failure.json').read_text())
    def test_cache_refusal_records_fixed_code_without_private_path(self):
        with tempfile.TemporaryDirectory(prefix='incoming-diagnostic-cache-') as temporary:
            root = Path(temporary); pins=root/'synthetic-private-path.json'
            pins.write_text('{"pins":[]}')
            with self.assertRaises(RuntimeError) as failure:
                validate_cache(root, pins, lambda _: self.fail('Refused pins must not launch a command'))
            write_failure(root/'failure.json', failure.exception, 'cache', 'cache-validation')
            receipt = json.loads((root/'failure.json').read_text())
            self.assertEqual((receipt['stage'], receipt['operation'], receipt['code']),
                             ('cache', 'cache-validation', 'cache-validation-refused'))
            self.assertNotIn(str(pins), (root/'failure.json').read_text())
            self.assertNotIn('synthetic-private-path', (root/'failure.json').read_text())

    def test_untrusted_kind_text_and_malformed_context_collapse_without_leakage(self):
        marker='synthetic-private-class-output-env-path'
        untrusted=type(marker, (Exception,), {})
        class UntrustedText(str):
            def __hash__(self): return hash('cache')
            def __eq__(self, other): return True
        with tempfile.TemporaryDirectory(prefix='incoming-diagnostic-unknown-') as temporary:
            path=Path(temporary)/'failure.json'
            for stage,operation in [(marker,marker), ({'private':marker}, [marker]),
                                    (None, 17), (UntrustedText(marker), UntrustedText(marker))]:
                write_failure(path, untrusted(marker), stage, operation)
                receipt=json.loads(path.read_text())
                self.assertEqual((receipt['kind'],receipt['stage'],receipt['operation'],receipt['code']),
                                 ('UnknownError','unknown','unknown','unclassified'))
                self.assertNotIn(marker,path.read_text())
                self.assertEqual(path.stat().st_mode & 0o777,0o600)
            write_failure(path, FixtureDiagnosticFailure(marker,marker), marker, marker)
            receipt=json.loads(path.read_text())
            self.assertEqual((receipt['kind'],receipt['stage'],receipt['operation'],receipt['code']),
                             ('RuntimeError','unknown','unknown','unclassified'))
            self.assertNotIn(marker,path.read_text())


if __name__ == '__main__': unittest.main()
