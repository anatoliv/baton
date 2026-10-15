"""Actual sealed worker/job paths with public filesystem/HTTP fixtures only."""
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import time
import unittest
from unittest.mock import patch
import urllib.parse

spec = importlib.util.spec_from_file_location('backup_fixtures', Path(__file__).with_name('test_backup.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
from private_contact.backup import DAY, PERIOD, digest
from private_contact.backup_job import BackupJob, ProtectedExports, artifacts, main
from private_contact.onedrive import OneDrive, HTTPS, microsoft_url, parse_fields, config_fields

FIELDS = dict(M365_TENANT_ID='00000000-0000-0000-0000-000000000001',
              M365_CLIENT_ID='00000000-0000-0000-0000-000000000002',
              M365_CLIENT_SECRET='PUBLIC-FIXTURE', ONEDRIVE_BACKUP_USER='fixture@example.invalid')


class HTTP:
    def __init__(self):
        self.calls, self.files, self.sessions, self.deleted = [], {}, {}, []
        self.present, self.corrupt, self.next_link = False, False, None
        self.serial = 0
        self.pages = None

    def folder(self):
        return dict(id='folder', name='baton-private-contact', folder={}, parentReference=dict(id='parent', driveId='drive'))

    def meta(self, name):
        return dict(id=self.files[name]['id'], name=name, file={}, size=len(self.files[name]['raw']),
                    eTag=self.files[name]['tag'], parentReference=dict(id='folder', driveId='drive'),
                    **{'@microsoft.graph.downloadUrl': 'https://fixture.files.1drv.com/' + name})

    def request(self, method, url, body, headers, accepted, limit):
        self.calls.append((method, url, dict(headers)))
        p = urllib.parse.urlsplit(url)
        path, status, value = p.path, 200, None
        if p.hostname == 'login.microsoftonline.com':
            value = {'access_token': 'PUBLIC-FIXTURE-TOKEN'}
        elif p.hostname == 'fixture.up.1drv.com':
            assert 'Authorization' not in headers
            name = self.sessions[path]
            assert name not in self.files
            self.serial += 1
            self.files[name] = dict(id='item-' + str(self.serial), raw=body, tag='fixture-v1')
            status, value = 201, self.meta(name)
        elif p.hostname == 'fixture.files.1drv.com':
            assert 'Authorization' not in headers
            raw = self.files[path[1:]]['raw']
            return 200, b'x' * len(raw) if self.corrupt else raw
        elif '/drive/root:/Backups' in path:
            if path.endswith('baton-private-contact'):
                status, value = (200, self.folder()) if self.present else (404, {})
            else:
                value = dict(id='parent', name='Backups', folder={}, parentReference=dict(driveId='drive'))
        elif path.endswith('/parent/children'):
            assert json.loads(body)['@microsoft.graph.conflictBehavior'] == 'fail'
            self.present, status, value = True, 201, self.folder()
        elif path.endswith('/folder/children'):
            value = {'value': [self.meta(n) for n in self.files] + [{'name': 'unrelated-keep'}]}
            if self.pages:
                page = 1 if '$skiptoken=' in p.query else 0
                value = {'value': self.pages[page]}
                if page == 0:
                    value['@odata.nextLink'] = 'https://graph.microsoft.com' + path + '?$skiptoken=fixture'
            if self.next_link:
                value['@odata.nextLink'] = self.next_link
        elif path.endswith(':/createUploadSession'):
            name = path.split(':/')[1]
            assert json.loads(body)['item']['@microsoft.graph.conflictBehavior'] == 'fail'
            self.sessions['/' + name] = name
            value = {'uploadUrl': 'https://fixture.up.1drv.com/' + name}
        elif path.endswith('/folder'):
            value = self.folder()
        else:
            item = path.split('/')[-2] if path.endswith('/permanentDelete') else path.split('/')[-1]
            name = next((n for n, f in self.files.items() if f['id'] == item), None)
            if name is None:
                status, value = 404, {}
            elif path.endswith('/permanentDelete'):
                self.deleted.append(name)
                del self.files[name]
                status, value = 204, None
            else:
                value = self.meta(name)
        assert status in accepted, (method, path, status, accepted)
        raw = b'' if value is None else json.dumps(value).encode()
        assert len(raw) <= limit
        return status, raw


class BackupJobTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.BackupTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.f.catalog()
        root = Path(self.f.tmp.name).resolve()
        path = root / 'exports'
        path.mkdir(mode=0o700)
        metadata = {p: (p.stat().st_uid, p.stat().st_gid, stat.S_IMODE(p.stat().st_mode)) for p in path.parents}
        self.exports = ProtectedExports(path, owner=(os.getuid(), os.getgid()), ancestor_metadata=metadata)
        self.addCleanup(self.exports.close)
        self.http = HTTP()
        self.remote = OneDrive(FIELDS, self.http)
        self.job = BackupJob(self.f.backup, self.exports, self.remote, clock=lambda: self.f.now)

    def test_roundtrip_restore_and_catalog_namespace_refresh(self):
        result = self.job.run(create=True)
        self.assertEqual(result, dict(captured=2, uploaded=2, byte_verified=2, expired=0))
        for name, item in artifacts(self.f.backup, self.f.now).items():
            self.assertEqual(self.exports.read(name, 4194332), self.http.files[name]['raw'])
            self.assertTrue(item['verified'])
        self.f.catalog()
        self.assertEqual(self.f.ledger.transact(lambda s: (s['backup']['remote_namespace'], s)), dict(drive='drive', folder='folder'))
        ordinary = next(n for n in self.http.files if n.startswith('ordinary-'))
        before = self.f.journal.transact(lambda s: (s, s))
        restored = self.job.restore(ordinary)
        self.assertTrue(restored['authorization_blocked_after_reopen'])
        self.assertEqual(self.f.journal.transact(lambda s: (s, s)), before)
        self.assertTrue(restored['live_authority_not_restored'])
        with self.assertRaises(Exception): self.job.restore(ordinary)

    def test_protected_exclusive_symlink_partial_and_lock(self):
        name = 'ordinary-' + 'a' * 32 + '.sealed'
        self.exports.write(name, b'x' * 28)
        with self.assertRaises(FileExistsError): self.exports.write(name, b'y' * 28)
        symlink = 'ordinary-' + 'b' * 32 + '.sealed'
        (self.exports.path / symlink).symlink_to(self.exports.path / name)
        with self.assertRaises(Exception): self.exports.read(symlink, 100)
        partial = 'ordinary-' + 'c' * 32 + '.sealed'
        with patch('private_contact.backup_job.os.write', side_effect=OSError('fixture')):
            with self.assertRaises(OSError): self.exports.write(partial, b'x' * 28)
        self.assertTrue((self.exports.path / partial).exists())
        with self.exports.locked():
            with self.assertRaises(BlockingIOError):
                with self.exports.locked(): pass

    def test_failed_readback_preserves_unverified_ciphertext(self):
        self.http.corrupt = True
        with self.assertRaises(Exception): self.job.run(create=True, expire=True)
        self.assertEqual(self.http.deleted, [])
        self.assertTrue(all(not x['verified'] for x in artifacts(self.f.backup, self.f.now).values()))
        self.assertEqual(len(list(self.exports.path.glob('*.sealed'))), 2)

    def test_held_release_expiry_and_deleted_resume(self):
        self.job.run(create=True)
        original = set(self.http.files)
        case = next(n for n in original if n.startswith('case-'))
        self.f.now += PERIOD
        self.f.catalog()
        self.job.run(expire=True)
        self.assertIn(case, self.http.files)
        self.assertEqual(len(original & set(self.http.files)), 1)
        generation = self.f.catalog()
        command = dict(identity='op-a:a', fingerprint=digest(self.f.scopes['op-a:a']), generation=generation)
        self.assertEqual(self.f.backup.handle('/operator/backup-release', self.f.ticket('/operator/backup-release', command))[0], 200)
        self.job.run(expire=True)
        self.assertNotIn(case, self.http.files)
        self.job.run(expire=True)  # Already-acknowledged deleted IDs are not retried.
        self.assertEqual(self.http.deleted.count(case), 1)

    def test_fresh_hold_blocks_stale_planner_delete(self):
        self.job.run(create=True)
        self.f.now += PERIOD
        generation = self.f.catalog()
        command = dict(identity='op-a:a', fingerprint=digest(self.f.scopes['op-a:a']), generation=generation)
        self.assertEqual(self.f.backup.handle('/operator/backup-release', self.f.ticket('/operator/backup-release', command))[0], 200)
        original = self.f.backup.expiry_candidates
        def stale(now):
            names = original(now)
            self.f.catalog()  # Re-hold before delete transaction admission.
            return sorted(names, key=lambda n: not n.startswith('case-'))
        with patch.object(self.f.backup, 'expiry_candidates', side_effect=stale):
            with self.assertRaises(Exception): self.job.run(expire=True)
        self.assertEqual(self.http.deleted, [])

    def test_changed_remote_identity_refuses_expiry(self):
        self.job.run(create=True)
        self.f.now += PERIOD
        self.f.catalog()
        next(iter(self.http.files.values()))['tag'] = 'changed'
        with self.assertRaises(Exception): self.job.run(expire=True)
        self.assertEqual(self.http.deleted, [])

    def test_foreign_pagination_refuses(self):
        self.remote.namespace(True)
        self.http.next_link = 'https://example.invalid/v1.0/drives/drive/items/folder/children?$skiptoken=x'
        with self.assertRaises(Exception): self.remote.listing()
        self.assertEqual(self.http.deleted, [])

    def test_complete_pagination_and_duplicate_identity_refusal(self):
        self.job.run(create=True)
        names = list(self.http.files)
        self.http.pages = [[self.http.meta(names[0])], [self.http.meta(names[1])]]
        self.assertEqual(set(self.remote.listing()), set(names))
        self.http.pages[1][0]['id'] = self.http.pages[0][0]['id']
        with self.assertRaises(Exception): self.remote.listing()
        self.assertEqual(self.http.deleted, [])

    def test_direct_https_rejects_redirect_and_credentials_on_signed_hosts(self):
        for url in ('https://evil.invalid/x', 'https://user@fixture.files.1drv.com/x',
                    'https://fixture.files.1drv.com:443/x', 'https://fixture.files.1drv.com/x#fragment'):
            with self.assertRaises(Exception): microsoft_url(url, 'download')
        http = HTTPS(time.monotonic() + 10)
        with self.assertRaises(Exception):
            http.request('GET', 'https://fixture.files.1drv.com/x', None, {'Authorization': 'Bearer PUBLIC'}, {200}, 100)
        self.assertEqual(http.attempted, 0)
        class Connection:
            sock = None
            def __init__(self, *a, **k): pass
            def request(self, *a, **k): pass
            def getresponse(self): return type('Response', (), {'status': 302})()
            def close(self): pass
        with patch('private_contact.onedrive.http.client.HTTPSConnection', Connection):
            with self.assertRaises(Exception): http.request('GET', 'https://graph.microsoft.com/v1.0/x', None, {}, {200}, 100)
        self.assertEqual((http.attempted, http.completed), (1, 0))

    def test_allowlist_parser_and_source_only_entrypoint(self):
        raw = '\n'.join(k + '=' + v for k, v in FIELDS.items()).encode()
        self.assertEqual(parse_fields(raw + b'\nUNRELATED=$(ignored)'), FIELDS)
        with self.assertRaises(Exception): parse_fields(raw.replace(b'PUBLIC-FIXTURE', b'$(forbidden)'))
        with patch('private_contact.backup_job.config_fields', side_effect=AssertionError('must not read')), patch('sys.stdout', new_callable=io.StringIO) as out:
            self.assertEqual(main([]), 0)
            self.assertEqual(json.loads(out.getvalue())['network_requests'], 0)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *fixtures.rest], verbosity=2)
