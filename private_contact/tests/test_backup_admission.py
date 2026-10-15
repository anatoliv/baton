"""New admission-only paths with public metadata, encrypted stores and fake HTTP."""
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import unittest
from unittest.mock import patch
from contextlib import ExitStack
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('job_fixtures',Path(__file__).with_name('test_backup_job.py'))
fixtures=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixtures)
path=Path(__file__).resolve().parents[2]/'docs/engineering/tbx-8936-feedback-integration/backup-operating-admission.py'
spec=importlib.util.spec_from_file_location('admission',path)
admission=importlib.util.module_from_spec(spec);spec.loader.exec_module(admission)
from private_contact.backup_job import PrivateDirectory
from private_contact.custody import AESGCMCodec


class AdmissionTests(unittest.TestCase):
    def test_default_is_source_only_and_refusal_has_no_exception_text(self):
        with patch.object(admission,'host_metadata',side_effect=AssertionError('PRIVATE-MARKER')),patch('sys.stdout',new_callable=io.StringIO) as out:
            self.assertEqual(admission.main([]),0)
            self.assertEqual(json.loads(out.getvalue())['phase'],'source-only')
        with patch('os.geteuid',return_value=0),patch.object(admission,'host_metadata',side_effect=ValueError('PRIVATE-MARKER')),patch('sys.stdout',new_callable=io.StringIO) as out:
            self.assertEqual(admission.main(['--execute','--metadata']),1)
            self.assertNotIn('PRIVATE-MARKER',out.getvalue())
            self.assertEqual(json.loads(out.getvalue())['stage'],'metadata-admission')

    def test_metadata_extracts_numeric_gid_without_any_content_open(self):
        def fake(path,**kwargs):
            mode=0o755 if str(path).startswith('/usr/local/bin/') else 0o640
            return SimpleNamespace(st_gid=24731,st_mode=stat.S_IFREG|mode)
        with patch.object(admission,'metadata',side_effect=fake),patch('pathlib.Path.exists',return_value=True),patch('grp.getgrnam',return_value=SimpleNamespace(gr_gid=24731)),patch('os.open',side_effect=AssertionError('content open')):
            value=admission.host_metadata()
        self.assertEqual(value['shared_env_group_gid'],24731)
        self.assertTrue(all(value['directories'].values()))
        self.assertFalse(value['monitoring_destination_verified'])

    def test_readonly_store_authentication_preserves_original_bytes(self):
        f=fixtures.fixtures.BackupTests();f.setUp();self.addCleanup(f.doCleanups);f.catalog()
        directory=f.journal.directory.resolve();db=directory/'custody.sqlite'
        before=db.read_bytes();members={p.name for p in directory.iterdir()}
        real=PrivateDirectory
        def fixture_directory(path):
            metadata={p:(p.stat().st_uid,p.stat().st_gid,stat.S_IMODE(p.stat().st_mode)) for p in path.parents}
            return real(path,owner=(os.getuid(),os.getgid()),ancestor_metadata=metadata)
        with patch('private_contact.backup_job.PrivateDirectory',side_effect=fixture_directory),patch.object(admission,'metadata',side_effect=lambda p,**k:p.lstat()):
            with ExitStack() as stack:
                state,ready=admission.read_store(directory,AESGCMCodec(b'j'*32),stack)
                self.assertTrue(ready)
                self.assertGreater(state['sequence'],0)
            with ExitStack() as stack:
                with self.assertRaises(Exception): admission.read_store(directory,AESGCMCodec(b'x'*32),stack)
        self.assertEqual(db.read_bytes(),before)
        self.assertEqual({p.name for p in directory.iterdir()},members)

    def test_get_only_parent_and_namespace_admission(self):
        http=fixtures.HTTP();http.attempted=http.completed=0
        request=http.request
        def counted(*args,**kwargs):
            http.attempted+=1
            result=request(*args,**kwargs);http.completed+=1;return result
        http.request=counted
        with patch('private_contact.onedrive.HTTPS',return_value=http):
            value=admission.provider_metadata(dict(fixtures.FIELDS),None)
        self.assertTrue(value['parent_present'] and value['namespace_absent'])
        self.assertEqual((value['requests_attempted'],value['requests_completed']),(3,3))
        self.assertEqual([c[0] for c in http.calls],['POST','GET','GET'])
        self.assertFalse(http.present)

    def test_bound_missing_namespace_refuses_and_retains_request_counts(self):
        http=fixtures.HTTP();http.attempted=http.completed=0
        request=http.request
        def counted(*args,**kwargs):
            http.attempted+=1;result=request(*args,**kwargs);http.completed+=1;return result
        http.request=counted;progress={}
        with patch('private_contact.onedrive.HTTPS',return_value=http):
            with self.assertRaises(Exception):
                admission.provider_metadata(dict(fixtures.FIELDS),dict(drive='drive',folder='folder'),progress)
        self.assertEqual((progress['requests_attempted'],progress['requests_completed']),(3,3))
        self.assertFalse(http.present)


if __name__=='__main__':
    unittest.main(argv=[sys.argv[0],*fixtures.fixtures.rest],verbosity=2)
