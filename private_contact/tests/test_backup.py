"""Narrow sealed-disk/operator path against the staged production worker."""
import argparse
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--staged-runtime', required=True)
args, rest = parser.parse_known_args()
sys.path.insert(0, args.staged_runtime)
from private_contact.backup import CaseBackups, DAY, PERIOD, digest
from private_contact.bridge import BridgeAuthority, signed
from private_contact.custody import AESGCMCodec, SQLiteCustody, JournaledCustody
from private_contact.runtime import PrivateAPI, SOURCE_FILES
from private_contact.service import Denied


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.now = 1700000000
        self.key = b'p' * 32
        self.operator = b'o' * 32
        self.primary = SQLiteCustody(root / 'primary', codec=AESGCMCodec(self.key))
        self.journal = SQLiteCustody(root / 'journal', codec=AESGCMCodec(b'j' * 32))
        self.ledger = SQLiteCustody(root / 'authority', codec=AESGCMCodec(b'j' * 32))
        self.custody = JournaledCustody(primary=self.primary, journal=self.journal)
        self.authority = BridgeAuthority(key=b'v' * 32, ledger=self.ledger,
            source=types.SimpleNamespace(action=lambda operation, share, now: dict(
                installation='fixture-origin', case='case-' + share, operation=operation,
                revision=1, share=share, created=10, action='disable-share')), recipient=None)
        self.scopes = {}
        for share in ('a', 'b'):
            scope = dict(installation=self.authority.handle('fixture-origin'), case='case-' + share,
                operation='op-' + share, revision=1, share=share, created=10,
                notice=dict(instructions='reserved case ' + share, location='/s/' + share, action='disable-share'))
            self.authority.review(scope, self.now)
            self.scopes['op-' + share + ':' + share] = scope
        jobs = {}
        for identity, scope in self.scopes.items():
            jobs[identity] = dict(identity=(scope['case'], scope['operation'], 1, 1, scope['share'], scope['installation']),
                installation=scope['installation'], share=scope['share'], share_created=10,
                notice=scope['notice'], state='queued', created=self.now, attempts=0, messages=[],
                delivered=False, history=[('queued', self.now)], escalations=[],
                code='NEVER-ARCHIVE-ACCESS-CODE', grant='NEVER-ARCHIVE-GRANT', lease='NEVER-ARCHIVE-LEASE')
        self.custody.transact(lambda _: (None, dict(contacts={'x': {'address': 'NEVER-ARCHIVE-ADDRESS'}}, jobs=jobs, withdrawal=False)))
        self.api = PrivateAPI(service=types.SimpleNamespace(aggregates=lambda: {'active': 0}),
            authority=self.authority, operator_key=self.operator, clock=lambda: self.now, custody=self.custody)
        self.backup = CaseBackups(self.api)
        self.addCleanup(self.tmp.cleanup)

    def ticket(self, path, body):
        return json.dumps({'authorization': signed(self.operator, dict(path=path, body=body,
            issued=self.now, expires=self.now + 60, nonce=uuid.uuid4().hex))}).encode()

    def catalog(self):
        cases = {identity: {'scope': scope, 'fingerprint': digest(scope)} for identity, scope in self.scopes.items()}
        command = dict(case_digest=digest(cases), review_until=self.now + PERIOD,
            records={identity: dict(fingerprint=digest(scope), held=identity == 'op-a:a') for identity, scope in self.scopes.items()})
        status, body = self.backup.handle('/operator/backup-catalog', self.ticket('/operator/backup-catalog', command))
        self.assertEqual(status, 200, body)
        return body['generation']

    def capture_verified(self):
        files = self.backup.capture(self.now)
        for name, raw in files.items():
            self.backup.confirm(name, raw, bytes(raw), self.now)
        return files

    def test_operator_signature_path_and_replay(self):
        self.assertEqual(self.backup.handle('/operator/backup-catalog', b'{"authorization":"bad"}')[0], 403)
        raw = self.ticket('/operator/backup-release', {})
        self.assertEqual(self.backup.handle('/operator/backup-catalog', raw)[0], 403)
        self.catalog()
        command = dict(identity='op-a:a', fingerprint=digest(self.scopes['op-a:a']), generation=1)
        raw = self.ticket('/operator/backup-release', command)
        self.assertEqual(self.backup.handle('/operator/backup-release', raw)[0], 200)
        self.assertNotEqual(self.backup.handle('/operator/backup-release', raw)[0], 200)

    def test_worker_wrap_preserves_existing_route_and_pin(self):
        self.assertIn('private_contact/backup.py', SOURCE_FILES)
        raw = self.ticket('/operator/aggregates', {})
        self.assertEqual(self.backup.handle('/operator/aggregates', raw), (200, {'active': 0}))
        runtime = Path(args.staged_runtime, 'private_contact/runtime.py').read_text()
        self.assertIn('return CaseBackups(PrivateAPI(', runtime)

    def test_missing_stale_or_expired_catalog_refuses(self):
        with self.assertRaises(Denied): self.backup.capture(self.now)
        self.catalog()
        self.now += PERIOD
        with self.assertRaises(Denied): self.backup.capture(self.now)
        with self.assertRaises(Denied): self.backup.expiry_candidates(self.now)

    def test_restricted_case_sealed_evidence_and_latest_frontier(self):
        self.catalog()
        # Simulate a committed journal ahead of its stale primary cache.
        def newer(history):
            history['sequence'] += 1
            history['state']['withdrawal'] = True
            return None, history
        self.journal.transact(newer)
        files = self.backup.capture(self.now)
        self.assertEqual(len(files), 2)
        case = next(raw for name, raw in files.items() if name.startswith('case-'))
        read = self.backup.read_case(case)
        self.assertEqual(read['scope']['case'], 'case-a')
        self.assertEqual(len(read['jobs']), 1)
        clear = self.primary.codec.open(case)
        for marker in (b'NEVER-ARCHIVE-', b'reserved case b', b'operator_replays', b'contacts'):
            self.assertNotIn(marker, clear)
        ordinary = next(raw for name, raw in files.items() if name.startswith('ordinary-'))
        restored = SQLiteCustody.restore(Path(self.tmp.name) / 'restored', backup=ordinary, codec=AESGCMCodec(self.key))
        self.assertFalse(restored.reconciled())
        state, ready = restored._open(ordinary)
        self.assertTrue(state['withdrawal'])
        self.assertNotIn('operator_replays', state)
        with self.assertRaises(Exception):
            SQLiteCustody.restore(Path(self.tmp.name) / 'wrong-kind', backup=case, codec=AESGCMCodec(self.key))

    def test_byte_readback_is_bound_to_original_capture(self):
        self.catalog()
        files = self.backup.capture(self.now)
        name, raw = next(iter(files.items()))
        with self.assertRaises(Denied): self.backup.confirm(name, raw, raw + b'x', self.now)
        with self.assertRaises(Denied): self.backup.confirm(name, b'other', b'other', self.now)
        self.backup.confirm(name, raw, raw, self.now)

    def test_held_case_retention_release_and_rehold(self):
        self.catalog()
        old = self.capture_verified()
        self.now += PERIOD + 1
        self.catalog()
        self.capture_verified()
        candidates = self.backup.expiry_candidates(self.now)
        self.assertEqual(candidates, [next(name for name in old if name.startswith('ordinary-'))])
        release = dict(identity='op-a:a', fingerprint=digest(self.scopes['op-a:a']), generation=2)
        self.assertEqual(self.backup.handle('/operator/backup-release', self.ticket('/operator/backup-release', release))[0], 200)
        self.assertEqual(set(self.backup.expiry_candidates(self.now)), set(old))
        self.catalog()  # Explicit re-hold protects the old case artifact again.
        self.assertEqual(len(self.backup.expiry_candidates(self.now)), 1)

    def test_fresh_readback_required_and_catalog_cannot_drop_hold(self):
        self.catalog()
        self.capture_verified()
        self.now += PERIOD + 1
        self.catalog()
        with self.assertRaises(Denied): self.backup.expiry_candidates(self.now)
        cases = {identity: {'scope': scope, 'fingerprint': digest(scope)} for identity, scope in self.scopes.items()}
        command = dict(case_digest=digest(cases), review_until=self.now + PERIOD,
            records={identity: dict(fingerprint=digest(scope), held=False) for identity, scope in self.scopes.items()})
        self.assertEqual(self.backup.handle('/operator/backup-catalog', self.ticket('/operator/backup-catalog', command))[0], 503)

    def test_new_case_requires_fresh_operator_catalog(self):
        self.catalog()
        scope = dict(self.scopes['op-b:b'], operation='op-new')
        self.authority.review(scope, self.now)
        with self.assertRaises(Denied): self.backup.capture(self.now)

    def test_restore_reconcile_preserves_newer_withdrawal(self):
        self.catalog()
        old = self.capture_verified()
        self.custody.transact(lambda state: (None, dict(state, withdrawal=True)))
        ordinary = next(raw for name, raw in old.items() if name.startswith('ordinary-'))
        restored = SQLiteCustody.restore(Path(self.tmp.name) / 'restored', backup=ordinary, codec=AESGCMCodec(self.key))
        reopened = SQLiteCustody(Path(self.tmp.name) / 'restored', codec=AESGCMCodec(self.key))
        custody = JournaledCustody(primary=reopened, journal=self.journal)
        with self.assertRaises(Exception): custody.transact(lambda state: (None, state))
        custody.reconcile_restore()
        self.assertTrue(custody.transact(lambda state: (state['withdrawal'], state)))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=2)
