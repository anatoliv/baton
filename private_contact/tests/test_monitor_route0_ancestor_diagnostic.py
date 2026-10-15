"""One narrow mocked boundary check; no operating metadata or contents observed."""
import importlib.util
import io
import json
from pathlib import Path
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[2]/'docs/engineering/tbx-8936-feedback-integration/backup-monitor-route0-ancestor-diagnostic.py'
spec = importlib.util.spec_from_file_location('route0_ancestors', source)
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class Route0Tests(unittest.TestCase):
    def test_fixed_chain_refuses_unsafe_metadata_without_content_or_value_output(self):
        with patch.object(Path, 'resolve', side_effect=AssertionError('metadata')), patch.object(Path, 'lstat', side_effect=AssertionError('metadata')), patch('sys.stdout', new_callable=io.StringIO) as out:
            self.assertEqual(diagnostic.main([]), 0)
            self.assertEqual(json.loads(out.getvalue())['phase'], 'source-only')
        cases = [('owner', 'root_owner'), ('world_write', 'non_group_world_writable'),
                 ('group_write', 'non_group_world_writable'), ('type', 'directory_type'),
                 ('missing', 'missing'), ('symlink', 'canonical_path'),
                 ('error', 'metadata_unavailable'), ('valid', None)]
        for case, predicate in cases:
            calls=[]
            def lstat(path):
                calls.append(path)
                if path == Path('/etc/deadman'):
                    if case=='missing': raise FileNotFoundError('PRIVATE-PATH SECRET 65432')
                    if case=='error': raise OSError('PRIVATE-PATH SECRET 65432')
                    return SimpleNamespace(st_uid=65432 if case=='owner' else 0,
                        st_mode=(stat.S_IFREG if case=='type' else stat.S_IFDIR)|
                        (0o757 if case=='world_write' else 0o775 if case=='group_write' else 0o755))
                return SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR|0o755)
            def resolve(path):
                return Path('/PRIVATE-PATH-SECRET') if case=='symlink' and path==Path('/etc/deadman') else path
            with self.subTest(case=case), patch.object(Path, 'resolve', new=resolve), patch.object(Path, 'lstat', new=lstat), patch('os.geteuid', return_value=0), patch('builtins.open', side_effect=AssertionError('content open')), patch('os.open', side_effect=AssertionError('content open')), patch('sys.stdout', new_callable=io.StringIO) as out:
                self.assertEqual(diagnostic.main(['--execute']), 0 if predicate is None else 1)
                value=json.loads(out.getvalue())
                self.assertEqual(value['phase'], 'complete' if predicate is None else 'refused')
                if predicate is not None:
                    self.assertEqual((value['ancestor'], value['failed_predicate']), ('direct_parent', predicate))
                    self.assertEqual(set(value), {'task','phase','writes','content_reads','provider_requests','private_values_recorded','ancestor','failed_predicate'})
                self.assertEqual(value['writes'], 0)
                self.assertEqual(value['content_reads'], 0)
                self.assertEqual(value['provider_requests'], 0)
                self.assertIs(value['private_values_recorded'], False)
                for marker in ('/', '65432', '755', '757', '775', 'SECRET', 'PRIVATE'):
                    self.assertNotIn(marker, out.getvalue())
            self.assertEqual(calls, [] if case=='symlink' else [Path('/etc/deadman')] if predicate is not None else [Path('/etc/deadman'), Path('/etc'), Path('/')])


if __name__ == '__main__':
    unittest.main(verbosity=2)
