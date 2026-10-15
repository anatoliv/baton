"""Fixed public metadata fixtures only; no staged runtime or private input."""
import importlib.util
import io
import json
from pathlib import Path
import stat
import unittest
from unittest.mock import patch
from types import SimpleNamespace

path=Path(__file__).resolve().parents[2]/'docs/engineering/tbx-8936-feedback-integration/backup-operating-admission.py'
spec=importlib.util.spec_from_file_location('admission',path)
admission=importlib.util.module_from_spec(spec);spec.loader.exec_module(admission)

class PrivateInputTests(unittest.TestCase):
    def test_cli_selects_private_mode_and_default_full_mode_still_visits_monitoring(self):
        with patch('os.geteuid',return_value=0),patch.object(admission,'host_metadata',return_value={}) as host,patch('sys.stdout',new_callable=io.StringIO) as out:
            self.assertEqual(admission.main(['--execute','--metadata','--private-inputs']),0)
            host.assert_called_once_with(private_inputs=True)
        visited=[]
        def fake(path,**kwargs):
            visited.append(str(path))
            return SimpleNamespace(st_gid=24731,st_mode=stat.S_IFREG|(0o755 if str(path).startswith('/usr/local/bin/') else 0o640))
        with patch.object(admission,'metadata',side_effect=fake),patch('pathlib.Path.exists',return_value=True),patch('grp.getgrnam',return_value=SimpleNamespace(gr_gid=24731)),patch('os.open',side_effect=AssertionError('content open')):
            value=admission.host_metadata()
        self.assertTrue(set(admission.MONITOR).issubset(visited))
        self.assertTrue({p for p,_ in admission.SCRIPTS.values()}.issubset(visited))
        self.assertNotIn('metadata_scope',value)
        self.assertFalse(value['monitoring_destination_verified'])

    def test_private_mode_keeps_all_private_roles_and_never_visits_monitoring(self):
        visited=[]
        def fake(path,**kwargs):
            visited.append(str(path))
            self.assertNotIn(str(path),admission.MONITOR)
            self.assertNotIn(str(path),[p for p,_ in admission.SCRIPTS.values()])
            return SimpleNamespace(st_gid=24731,st_mode=stat.S_IFREG|0o640)
        with patch.object(admission,'metadata',side_effect=fake),patch('pathlib.Path.exists',return_value=True),patch('grp.getgrnam',return_value=SimpleNamespace(gr_gid=24731)),patch('os.open',side_effect=AssertionError('content open')):
            value=admission.host_metadata(private_inputs=True)
        self.assertEqual(len(value['directories']),7)
        self.assertEqual(len(value['files']),6)
        self.assertEqual(len(visited),14)
        self.assertEqual(value['shared_env_group_gid'],24731)
        self.assertEqual(value['metadata_scope'],'private-inputs')
        self.assertEqual(value['monitoring'],{})
        self.assertFalse(value['monitoring_destination_verified'])

    def test_actual_private_guards_still_refuse_in_private_mode(self):
        key=admission.KEYS/'encryption.key'
        changes=(('key_owner',key,dict(st_uid=0)),
                 ('key_mode',key,dict(st_mode=stat.S_IFREG|0o640)),
                 ('key_links',key,dict(st_nlink=2)),
                 ('key_type',key,dict(st_mode=stat.S_IFDIR|0o600)),
                 ('private_ancestor_owner',admission.KEYS,dict(st_gid=0)),
                 ('private_ancestor_mode',admission.KEYS,dict(st_mode=stat.S_IFDIR|0o750)),
                 ('data_owner',Path('/data'),dict(st_uid=0,st_mode=stat.S_IFDIR|0o775)))
        files={Path('/etc/offsite-backup.env'),admission.CONFIG/'backup-manifest.json',
               admission.KEYS/'encryption.key',admission.KEYS/'journal.key',
               *(admission.STATE/role/'custody.sqlite' for role in ('contact','history','authority'))}
        for label,target,change in changes:
            with self.subTest(label=label):
                def info(path):
                    private=str(path).startswith(('/etc/baton-private-contact','/data/baton-private-contact'))
                    values=dict(st_dev=1,st_ino=2,st_uid=11036 if private else 0,
                                st_gid=11036 if private else 0,st_nlink=1,
                                st_mode=(stat.S_IFREG|0o600) if path in files else
                                        (stat.S_IFDIR|(0o700 if private else 0o755)))
                    if path==Path('/etc/offsite-backup.env'): values.update(st_gid=24731,st_mode=stat.S_IFREG|0o640)
                    if path==Path('/data'): values.update(st_uid=1000,st_gid=1000)
                    if path==target: values.update(change)
                    return SimpleNamespace(**values)
                with patch.object(Path,'resolve',lambda p:p),patch.object(Path,'lstat',info),patch.object(Path,'exists',return_value=True),patch('grp.getgrnam',return_value=SimpleNamespace(gr_gid=24731)),patch('os.geteuid',return_value=0),patch('os.open',side_effect=AssertionError('content open')),patch('sys.stdout',new_callable=io.StringIO) as out:
                    self.assertEqual(admission.main(['--execute','--metadata','--private-inputs']),1)
                self.assertEqual(json.loads(out.getvalue())['phase'],'refused')

    def test_private_mode_rejects_incompatible_modes_before_metadata(self):
        for args in (['--metadata','--private-inputs','--public-scripts'],
                     ['--content','--private-inputs','--shared-env-gid','24731'],
                     ['--metadata','--private-inputs','--provider']):
            with self.subTest(args=args),patch('os.geteuid',return_value=0),patch.object(admission,'host_metadata',side_effect=AssertionError('must not run')),patch.object(admission,'private_content',side_effect=AssertionError('must not run')),patch('sys.stdout',new_callable=io.StringIO) as out:
                self.assertEqual(admission.main(['--execute',*args]),1)
                self.assertEqual(json.loads(out.getvalue())['stage'],'root-admission')


if __name__=='__main__':
    unittest.main(verbosity=2)
