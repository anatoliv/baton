"""Sealed local custody adapter; no key lookup, launcher or production admission.

The caller supplies a codec and its key custody. SQLite sees only authenticated
opaque envelopes. This module does not qualify production encryption/backup roles.
"""
from __future__ import annotations

import copy
import fcntl
import threading
import time
from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import stat

LIMIT = 4 * 1024 * 1024
CONTEXT = b'baton-private-contact-custody-v1'
_SUBMISSIONS = {}
_SUBMISSIONS_LOCK = threading.Lock()


class CustodyError(Exception):
    """Bounded adapter failure, with no private codec/database payload."""


class AESGCMCodec:
    def __init__(self, supplied_key):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        self.cipher = AESGCM(supplied_key)

    def seal(self, plaintext):
        nonce = os.urandom(12)
        return nonce + self.cipher.encrypt(nonce, plaintext, CONTEXT)

    def open(self, envelope):
        if not isinstance(envelope, bytes) or not 28 <= len(envelope) <= LIMIT + 28:
            raise CustodyError('unavailable')
        return self.cipher.decrypt(envelope[:12], envelope[12:], CONTEXT)


def _encode(value):
    # Explicit tags preserve tuples without executable deserialization or reserved
    # dictionary keys colliding with user-supplied notice content.
    if isinstance(value, dict):
        return ['dict', [[key, _encode(item)] for key, item in value.items()]]
    if isinstance(value, (list, tuple)):
        return ['tuple' if isinstance(value, tuple) else 'list', [_encode(item) for item in value]]
    if value is None or type(value) in (str, int, bool):
        return ['scalar', value]
    raise CustodyError('invalid')


def _decode(value):
    tag, body = value
    if tag == 'dict':
        return {key: _decode(item) for key, item in body}
    if tag in ('list', 'tuple'):
        items = [_decode(item) for item in body]
        return tuple(items) if tag == 'tuple' else items
    if tag == 'scalar' and (body is None or type(body) in (str, int, bool)):
        return body
    raise CustodyError('invalid')


class SQLiteCustody:
    def __init__(self, directory, *, codec, synthetic=False, restoring=False):
        self.synthetic = synthetic is True
        self.directory = Path(directory)
        self.codec = codec
        try:
            if not self.directory.is_absolute() or self.directory.is_symlink():
                raise CustodyError('invalidPath')
            try:
                self.directory.mkdir(mode=0o700, parents=False)
                created = True
            except FileExistsError:
                if restoring:
                    raise CustodyError('restoreTargetExists')
                created = False
            self._check(self.directory, directory=True)
            self.path = self.directory / 'custody.sqlite'
            # Only this directory's exclusive creator initializes a database.
            # Reopeners never fill an empty/missing schema during that interval.
            flags = os.O_RDWR | os.O_NOFOLLOW
            if created:
                flags |= os.O_CREAT | os.O_EXCL
            descriptor = os.open(self.path, flags, 0o600)
            os.close(descriptor)
            self._check(self.path)
            with self._connect() as connection:
                connection.execute('BEGIN IMMEDIATE')
                if created:
                    connection.execute('CREATE TABLE custody (id INTEGER PRIMARY KEY CHECK(id=1), envelope BLOB NOT NULL)')
                row = connection.execute('SELECT envelope FROM custody WHERE id=1').fetchone()
                if created:
                    connection.execute('INSERT INTO custody VALUES(1,?)', (self._seal(None, not restoring),))
                else:
                    if row is None:
                        raise CustodyError('unavailable')
                    self._open(row[0])
                connection.commit()
        except Exception:
            raise CustodyError('unavailable') from None

    @staticmethod
    def _check(path, directory=False):
        info = path.lstat()
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if (not expected(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)):
            raise CustodyError('unavailable')

    @contextmanager
    def submission(self):
        """Serialize consent acknowledgments and SMTP submission, across workers.

        The lock is separate from database transactions: consent is committed
        before DATA, and the outcome is committed before the fence is released.
        Reentrancy permits deterministic already-started transport callbacks.
        All wrappers for one directory share the in-process lock and depth.
        """
        self._check(self.directory, directory=True)
        identity = self.directory.stat()
        key = (identity.st_dev, identity.st_ino)
        with _SUBMISSIONS_LOCK:
            lock, depth = _SUBMISSIONS.setdefault(key, (threading.RLock(), threading.local()))
        if not lock.acquire(timeout=4):
            raise CustodyError('unavailable')
        descriptor = None
        try:
            if not getattr(depth, 'active', False):
                path = self.directory / 'submission.lock'
                descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                info = os.fstat(descriptor)
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                    raise CustodyError('unavailable')
                deadline = time.monotonic() + 4
                while True:
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise CustodyError('unavailable') from None
                        time.sleep(0.01)
                current = path.lstat()
                self._check(self.directory, directory=True)
                if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                    raise CustodyError('unavailable')
                depth.active = True
            yield
        finally:
            if descriptor is not None:
                depth.active = False
                os.close(descriptor)
            lock.release()

    @contextmanager
    def _connect(self):
        self._check(self.directory, directory=True)
        self._check(self.path)
        connection = sqlite3.connect(self.path, timeout=4)
        try:
            connection.execute('PRAGMA journal_mode=DELETE')
            connection.execute('PRAGMA synchronous=FULL')
            yield connection
        finally:
            connection.close()

    def _seal(self, state, reconciled):
        raw = json.dumps({'version': 1, 'reconciled': reconciled, 'state': _encode(state)},
                         separators=(',', ':'), ensure_ascii=True).encode('ascii')
        if len(raw) > LIMIT:
            raise CustodyError('stateLimit')
        sealed = self.codec.seal(raw)
        if not isinstance(sealed, bytes) or len(sealed) > LIMIT + 28:
            raise CustodyError('unavailable')
        return sealed

    def _open(self, sealed):
        raw = self.codec.open(sealed)
        if not isinstance(raw, bytes) or len(raw) > LIMIT:
            raise CustodyError('unavailable')
        envelope = json.loads(raw)
        if (set(envelope) != {'version', 'reconciled', 'state'} or envelope['version'] != 1
                or type(envelope['reconciled']) is not bool):
            raise CustodyError('unavailable')
        return _decode(envelope['state']), envelope['reconciled']

    def reconciled(self):
        try:
            with self._connect() as connection:
                row = connection.execute('SELECT envelope FROM custody WHERE id=1').fetchone()
                return self._open(row[0])[1]
        except Exception:
            raise CustodyError('unavailable') from None

    def transact(self, operation):
        try:
            with self._connect() as connection:
                connection.execute('BEGIN IMMEDIATE')
                state, ready = self._open(connection.execute('SELECT envelope FROM custody WHERE id=1').fetchone()[0])
                result, replacement = operation(copy.deepcopy(state))
                connection.execute('UPDATE custody SET envelope=? WHERE id=1', (self._seal(replacement, ready),))
                connection.commit()
                return copy.deepcopy(result)
        except Exception as error:
            # Domain refusals are raised before commit and must retain their
            # bounded category. All other payloads are sanitized by ContactService.
            from .service import _Refusal
            if isinstance(error, _Refusal):
                raise
            raise CustodyError('unavailable') from None

    def export(self):
        """One transaction-consistent sealed snapshot; no plaintext file is made."""
        try:
            with self._connect() as connection:
                sealed = connection.execute('SELECT envelope FROM custody WHERE id=1').fetchone()[0]
                self._open(sealed)
                return sealed
        except Exception:
            raise CustodyError('unavailable') from None

    @classmethod
    def restore(cls, directory, *, backup, codec, synthetic=False):
        """New directory only; restored authorization remains durably blocked."""
        try:
            custody = cls(directory, codec=codec, synthetic=synthetic, restoring=True)
            state, _ = custody._open(backup)
            with custody._connect() as connection:
                connection.execute('BEGIN IMMEDIATE')
                connection.execute('UPDATE custody SET envelope=? WHERE id=1',
                                   (custody._seal(state, False),))
                connection.commit()
            return custody
        except Exception:
            raise CustodyError('unavailable') from None


class JournaledCustody:
    """Authoritative history is a separate sealed, non-restored custody instance.

    Commit the journal first, then the primary cache. A crash after journal commit
    loses no withdrawal, lease or send outcome; the next transaction reads history.
    Both active and restored workers serialize on the authoritative transaction.
    Restoring/rolling back the journal itself is never authorized by this adapter.
    """
    def __init__(self, *, primary: SQLiteCustody, journal: SQLiteCustody):
        if primary.directory.resolve() == journal.directory.resolve():
            raise CustodyError('unavailable')
        if not journal.reconciled():
            raise CustodyError('unavailable')
        self.primary, self.journal = primary, journal
        self.synthetic = primary.synthetic and journal.synthetic
        self.production_ready = True

    def submission(self):
        # Restored primary caches must share the live authoritative fence.
        return self.journal.submission()

    def reconciled(self):
        return self.primary.reconciled() and self.journal.reconciled()

    def transact(self, operation):
        def apply(primary_state):
            if not self.reconciled():
                from .service import _Refusal
                raise _Refusal('custodyReviewRequired')
            def authoritative(history):
                if history is None and primary_state is not None:
                    raise CustodyError('historyMissing')
                result, replacement = operation(copy.deepcopy(history['state'] if history else None))
                checkpoint = dict(version=1, sequence=(history['sequence'] + 1 if history else 1), state=replacement)
                return (result, replacement), checkpoint
            return self.journal.transact(authoritative)
        return self.primary.transact(apply)

    def reconcile_restore(self):
        """Read latest live history under its write lock; never trust restored consent."""
        try:
            with self.primary._connect() as connection:
                connection.execute('BEGIN IMMEDIATE')
                _, ready = self.primary._open(connection.execute('SELECT envelope FROM custody WHERE id=1').fetchone()[0])
                if ready:
                    raise CustodyError('restoreRequired')
                def reconcile(history):
                    if not self.journal.reconciled() or not history or history.get('version') != 1:
                        raise CustodyError('historyMissing')
                    # Reconcile all consent/revisions/withdrawals AND leases, outcomes,
                    # grants and reviewed actions. Old exported state is discarded.
                    connection.execute('UPDATE custody SET envelope=? WHERE id=1',
                        (self.primary._seal(history['state'], True),))
                    connection.commit()
                    return None, history
                self.journal.transact(reconcile)
        except Exception:
            raise CustodyError('unavailable') from None
