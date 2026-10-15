"""Private one-shot backup/restore job; source-only unless --execute is supplied.

Root admits the existing shared config once, then permanently becomes11036:11036.
No listener, mail, environment configuration, plaintext export or key copying.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
from types import SimpleNamespace

from .backup import CaseBackups, DAY, PERIOD, require
from .custody import AESGCMCodec, SQLiteCustody, JournaledCustody, LIMIT
from .onedrive import (OneDrive, HTTPS, NAME, config_fields, decode_json,
                       fingerprint, read_protected)

OWNER = (11036, 11036)
CONFIG = Path('/etc/baton-private-contact/backup-manifest.json')
STATE = Path('/data/baton-private-contact/state')
EXPORTS = Path('/data/baton-private-contact/exports')
KEYS = Path('/etc/baton-private-contact/keys')
SOURCE = Path('/opt/baton-private-contact/source')
DIRECTORIES = {role: STATE / role for role in ('contact', 'history', 'authority')}
MANIFEST_FIELDS = {'version', 'source_digests', 'runtime_digest', 'cryptography_version',
                   'deployment_card', 'approval_reference', 'allow_create_namespace',
                   'destructive_expiry_enabled', 'shared_env_group_gid'}


class PrivateDirectory:
    def __init__(self, path, owner=OWNER, ancestor_metadata=None):
        self.path, self.owner, self.handles = Path(path), owner, []
        # Explicit metadata seam for local filesystem fixtures only; executable
        # construction never supplies overrides or accepts a CLI path/owner.
        ancestor_metadata = ancestor_metadata or {}
        require(self.path.is_absolute() and self.path.resolve() == self.path)
        try:
            for parent in reversed((self.path, *self.path.parents)):
                info = parent.lstat()
                mode = stat.S_IMODE(info.st_mode)
                private = parent == self.path or str(parent).startswith('/data/baton-private-contact') or str(parent).startswith('/etc/baton-private-contact')
                fixture = (parent != self.path and parent in ancestor_metadata and
                           (info.st_uid, info.st_gid, mode) == ancestor_metadata[parent])
                data = parent == Path('/data') and (info.st_uid, info.st_gid, mode) == (1000, 1000, 0o755)
                require(stat.S_ISDIR(info.st_mode) and
                        ((private and (info.st_uid, info.st_gid, mode) == (*owner, 0o700)) or
                         (not private and (fixture or data or info.st_uid == 0 and not mode & 0o022))))
                fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                require(fingerprint(info) == fingerprint(os.fstat(fd)))
                self.handles.append((parent, fd, info))
            self.fd = self.handles[-1][1]
        except BaseException:
            self.close()
            raise

    def check(self):
        for path, fd, info in self.handles:
            current, opened = path.lstat(), os.fstat(fd)
            # Directory timestamps change after our own exclusive writes. Identity,
            # type/owner/mode must remain unchanged; no canonical path replacement.
            expected = (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)
            require(path.resolve() == path and
                    (current.st_dev, current.st_ino, current.st_mode, current.st_uid, current.st_gid) == expected and
                    (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid, opened.st_gid) == expected)

    def read(self, name, limit):
        self.check()
        raw = read_protected(self.fd, name, self.owner[0], {self.owner[1]}, {0o600}, limit)
        self.check()
        return raw

    def close(self):
        for _, fd, _ in reversed(self.handles):
            os.close(fd)
        self.handles = []

    def __enter__(self): return self
    def __exit__(self, *args): self.close()


class ProtectedExports(PrivateDirectory):
    def write(self, name, sealed):
        require(NAME.fullmatch(name) and type(sealed) is bytes and 28 <= len(sealed) <= LIMIT + 28)
        self.check()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            before = os.fstat(fd)
            require((before.st_uid, before.st_gid, stat.S_IMODE(before.st_mode), before.st_nlink) == (*self.owner, 0o600, 1))
            pending = memoryview(sealed)
            while pending:
                count = os.write(fd, pending)
                require(count > 0)
                pending = pending[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(self.fd)
        require(self.read(name, LIMIT + 28) == sealed)
        self.check()

    @contextmanager
    def locked(self):
        self.check()
        fd = os.open('.backup.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                    and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (*self.owner, 0o600))
            require(fingerprint(info) == fingerprint(os.stat('.backup.lock', dir_fd=self.fd, follow_symlinks=False)))
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.check()
            yield
            self.check()
        finally:
            os.close(fd)  # The lock inode remains; never remove/replace a live lock.

    def remove(self, name, expected_hash):
        require(NAME.fullmatch(name))
        raw = self.read(name, LIMIT + 28)
        require(hashlib.sha256(raw).hexdigest() == expected_hash)
        info = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        # Namespace has one job lock. Revalidate this exact nofollow inode before
        # unlink; do not enumerate or remove any unrelated export/lock/partial path.
        require(fingerprint(info) == fingerprint(os.stat(name, dir_fd=self.fd, follow_symlinks=False)))
        self.check()
        os.unlink(name, dir_fd=self.fd)
        os.fsync(self.fd)
        self.check()


def artifacts(backups, now):
    def read(state):
        _, catalog = backups._catalog(state, now)
        return catalog['artifacts'], state
    return backups.ledger.transact(read)


def bind_namespace(backups, namespace, now):
    def bind(state):
        _, catalog = backups._catalog(state, now)
        previous = catalog.get('remote_namespace')
        require(previous is None or previous == namespace)
        catalog['remote_namespace'] = namespace
        return None, state
    backups.ledger.transact(bind)


def bind_remote(backups, name, binding, now):
    def bind(state):
        _, catalog = backups._catalog(state, now)
        item = catalog['artifacts'][name]
        require(not item.get('remote_deleted') and (item.get('remote') is None or item['remote'] == binding))
        item['remote'] = binding
        return None, state
    backups.ledger.transact(bind)


def is_expirable(catalog, item, now):
    if not item['verified'] or now < item['captured'] + PERIOD:
        return False
    if item['kind'] == 'case':
        record = catalog['records'].get(item['identity'])
        return bool(record and record['status'] == 'released' and record['released_at'] <= now
                    and record['fingerprint'] == item['fingerprint'])
    return item['kind'] == 'ordinary'


class BackupJob:
    def __init__(self, backups, exports, remote, clock=time.time):
        self.backups, self.exports, self.remote, self.clock = backups, exports, remote, clock

    def run(self, *, create=False, expire=False):
        with self.exports.locked():
            now = int(self.clock())
            previous = artifacts(self.backups, now)  # Admission before any target mutation.
            for name, item in previous.items():
                if not item.get('remote_deleted'):
                    require(hashlib.sha256(self.exports.read(name, LIMIT + 28)).hexdigest() == item['sealed_sha256'])
            new = self.backups.capture(now)
            for name, sealed in new.items():
                self.exports.write(name, sealed)
            namespace = self.remote.namespace(create)
            bind_namespace(self.backups, namespace, now)
            listing = self.remote.listing()  # Full listing before resuming/creating uploads.
            uploaded = verified = 0
            current = artifacts(self.backups, now)
            for name, item in current.items():
                if item.get('remote_deleted'):
                    continue
                binding = listing.get(name)
                if item['verified']:
                    require(item.get('remote') is not None and binding == item['remote'])
                    continue
                sealed = self.exports.read(name, LIMIT + 28)
                require(hashlib.sha256(sealed).hexdigest() == item['sealed_sha256'])
                if binding is None:
                    # Never silently recreate an already-bound/verified lost file.
                    require(item.get('remote') is None and not item['verified'])
                    binding = self.remote.upload(name, sealed)
                    uploaded += 1
                bind_remote(self.backups, name, binding, now)
                downloaded = self.remote.download(binding)
                self.backups.confirm(name, sealed, downloaded, int(self.clock()))
                verified += 1
            removed = 0
            if expire:
                listing = self.remote.listing()  # New complete identity listing, not upload-phase data.
                for name in self.backups.expiry_candidates(int(self.clock())):
                    if artifacts(self.backups, int(self.clock()))[name].get('remote_deleted'):
                        continue
                    def destroy(state):
                        now = int(self.clock())
                        _, catalog = self.backups._catalog(state, now)
                        item = catalog['artifacts'][name]
                        # Hold/catalog checks and external action share this actual
                        # authoritative lock. A pending/new hold never races a
                        # committed catalog decision through a stale planner list.
                        require(is_expirable(catalog, item, now) and not item.get('remote_deleted'))
                        require(any(value['kind'] == 'ordinary' and value['verified'] and
                            not value.get('remote_deleted') and now-DAY <= value['captured'] <= now
                            for value in catalog['artifacts'].values()))
                        binding = item.get('remote')
                        require(binding is not None and listing.get(name) == binding)
                        downloaded = self.remote.download(binding)
                        require(hashlib.sha256(downloaded).hexdigest() == item['sealed_sha256'])
                        self.remote.permanent_delete(binding)
                        item['remote_deleted'] = now
                        # Mark remote absence before exact local unlink. A crash or
                        # unlink failure rolls back the private transaction but
                        # keeps remaining local evidence and exits nonzero.
                        self.exports.remove(name, item['sealed_sha256'])
                        return None, state
                    self.backups.ledger.transact(destroy)
                    removed += 1
            return dict(captured=len(new), uploaded=uploaded, byte_verified=verified, expired=removed)

    def restore(self, name):
        require(NAME.fullmatch(name) and name.startswith('ordinary-'))
        with self.exports.locked():
            now = int(self.clock())
            current = artifacts(self.backups, now)
            bind_namespace(self.backups, self.remote.namespace(False), now)
            item = current.get(name)
            require(item and item['kind'] == 'ordinary' and item['verified'] and not item.get('remote_deleted'))
            listing = self.remote.listing()
            require(item.get('remote') is not None and listing.get(name) == item['remote'])
            sealed = self.remote.download(item['remote'])
            require(hashlib.sha256(sealed).hexdigest() == item['sealed_sha256'])
            # New sibling only; never replace current primary, journal or authority.
            target = self.backups.custody.primary.directory.parent / ('restored-' + name.removesuffix('.sealed'))
            restored = SQLiteCustody.restore(target, backup=sealed, codec=self.backups.custody.primary.codec)
            require(not restored.reconciled())
            # Admission blocks authorization until a separately requested existing
            # reconcile path uses current retained authority. Restore does not
            # lift the fence, even though the live journal remains available.
            reopened = SQLiteCustody(target, codec=self.backups.custody.primary.codec)
            require(not reopened.reconciled())
            return {'new_primary_created': True, 'authorization_blocked_after_reopen': True,
                    'live_journal_not_restored': True, 'live_authority_not_restored': True}


def admit_manifest(manifest, source_root=SOURCE):
    from .runtime import SOURCE_FILES
    require(type(manifest) is dict and set(manifest) == MANIFEST_FIELDS and manifest['version'] == 1)
    require(type(manifest['source_digests']) is dict and set(manifest['source_digests']) == set(SOURCE_FILES))
    require(re.fullmatch(r'TBX-\d+', manifest['deployment_card']) and
            type(manifest['approval_reference']) is str and 1 <= len(manifest['approval_reference']) <= 512)
    require(type(manifest['allow_create_namespace']) is bool and type(manifest['destructive_expiry_enabled']) is bool)
    require(type(manifest['shared_env_group_gid']) is int and 0 <= manifest['shared_env_group_gid'] <= 2**32 - 2)
    for name, expected in manifest['source_digests'].items():
        path = source_root / name
        require(path.resolve(strict=True) == path and re.fullmatch(r'[a-f0-9]{64}', expected)
                and hashlib.sha256(path.read_bytes()).hexdigest() == expected)
    require(str(Path(sys.executable).resolve()) == '/usr/local/bin/python3.12'
            and sys.version_info[:3] == (3, 12, 15)
            and manifest['runtime_digest'] == hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest()
            and manifest['cryptography_version'] == version('cryptography') == '50.0.2')


def open_existing_backups():
    # No constructor is permitted to initialize a missing live database.
    for path in DIRECTORIES.values():
        with PrivateDirectory(path) as admitted:
            admitted.read('custody.sqlite', 8 * 1024 * 1024)
    with PrivateDirectory(KEYS) as keys:
        primary_key, journal_key = keys.read('encryption.key', 32), keys.read('journal.key', 32)
        require(len(primary_key) == len(journal_key) == 32 and primary_key != journal_key)
    primary = SQLiteCustody(DIRECTORIES['contact'], codec=AESGCMCodec(primary_key))
    journal = SQLiteCustody(DIRECTORIES['history'], codec=AESGCMCodec(journal_key))
    authority = SQLiteCustody(DIRECTORIES['authority'], codec=AESGCMCodec(journal_key))
    # The job exposes no operator or installation interface. Actual durable case
    # reviews/catalog were admitted by the existing protected worker before this job.
    api = SimpleNamespace(custody=JournaledCustody(primary=primary, journal=journal),
                          authority=SimpleNamespace(ledger=authority))
    return CaseBackups(api)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--create-namespace', action='store_true')
    parser.add_argument('--expire', action='store_true')
    parser.add_argument('--restore')
    args = parser.parse_args(argv)
    if not args.execute:
        print(json.dumps({'task': 'TBX-8936', 'phase': 'source-only', 'writes': 0, 'network_requests': 0}))
        return 0
    receipt = {'task': 'TBX-8936', 'phase': 'refused', 'stage': 'root-admission',
               'network_attempted': 0, 'network_completed': 0, 'private_values_recorded': False}
    http = None
    def expired(signum, frame): raise TimeoutError()
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(180)
    try:
        require(os.geteuid() == 0)
        with PrivateDirectory(CONFIG.parent) as configuration:
            manifest = decode_json(configuration.read(CONFIG.name, 65536))
        receipt['stage'] = 'source-runtime-admission'
        admit_manifest(manifest)
        require(not args.create_namespace or manifest['allow_create_namespace'])
        require(not args.expire or manifest['destructive_expiry_enabled'])
        require(not args.restore or not args.expire and not args.create_namespace)
        receipt['stage'] = 'shared-config-admission'
        fields = config_fields(expected_group_gid=manifest['shared_env_group_gid'])
        receipt['stage'] = 'permanent-identity-drop'
        os.setgroups([])
        os.setgid(OWNER[1])
        os.setuid(OWNER[0])
        require((os.getuid(), os.geteuid(), os.getgid(), os.getegid(), os.getgroups()) == (OWNER[0], OWNER[0], OWNER[1], OWNER[1], []))
        receipt['stage'] = 'existing-store-admission'
        backups = open_existing_backups()
        artifacts(backups, int(time.time()))
        with ProtectedExports(EXPORTS) as exports:
            http = HTTPS(time.monotonic() + 170)
            receipt['stage'] = 'onedrive-job'
            remote = OneDrive(fields, http)
            fields.clear()
            job = BackupJob(backups, exports, remote)
            if args.restore:
                receipt['result'] = job.restore(args.restore)
            else:
                receipt['result'] = job.run(create=args.create_namespace, expire=args.expire)
        receipt.update(phase='complete', stage='complete')
    except BaseException:
        pass  # Emit only the fixed receipt, never exception/config/URL/store payload.
    finally:
        signal.alarm(0)
        if http is not None:
            receipt['network_attempted'], receipt['network_completed'] = http.attempted, http.completed
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt['phase'] == 'complete' else 1


if __name__ == '__main__':
    raise SystemExit(main())
