#!/usr/bin/env python3
"""Isolated real API regressions; no shared machine guard, app or browser."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

LIB = Path(__file__).resolve().parent / 'probe-lib.sh'
STARTED = time.time()
CASES = []

def run(lock, script, extra=None):
    env = {**os.environ, 'LIB': str(LIB), 'BATON_PROBE_LOCK': str(lock), **(extra or {})}
    return subprocess.run(['/bin/bash', '-c', '. "$LIB"; ' + script], env=env,
                          capture_output=True, timeout=8)

def snapshot(path):
    i = path.lstat()
    entries = {}
    if path.is_dir() and not path.is_symlink():
        for p in sorted(path.iterdir()):
            j = p.lstat()
            entries[p.name] = (j.st_dev, j.st_ino, j.st_mode, j.st_size,
                               hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
    return i.st_dev, i.st_ino, i.st_mode, entries

def passed(name):
    CASES.append({'case': name, 'passed': True})

with tempfile.TemporaryDirectory(prefix='baton-tbx-9558-check-') as tmp:
    root = Path(tmp)
    # Every existing state is unchanged, without liveness authorizing recovery.
    dead = subprocess.Popen(['/bin/sh', '-c', 'exit 0']); dead.wait()
    for state in ('live', 'dead', 'ownerless', 'malformed', 'file', 'symlink'):
        lock = root / state
        if state == 'file': lock.write_bytes(b'isolated existing object\n')
        elif state == 'symlink': lock.symlink_to(root / 'missing-target')
        else:
            lock.mkdir()
            if state != 'ownerless':
                owner = {'live': f'{os.getpid()} fixture\n', 'dead': f'{dead.pid} fixture\n',
                         'malformed': 'not-a-pid invalid\n'}[state]
                (lock / 'owner').write_text(owner)
        before = snapshot(lock)
        r = run(lock, 'probe_lock_try_acquire_no_reclaim')
        assert r.returncode == 3 and snapshot(lock) == before, (state, r.returncode)
        passed('refuses unchanged ' + state + ' lock')

    lock = root / 'busy'
    side = str(lock) + '.reclaim'
    holder = subprocess.Popen(['/usr/bin/perl', '-MFcntl=:flock', '-e',
        'open(my $m,">>",$ARGV[0]) or die; flock($m,LOCK_EX) or die; $|=1; print "ready\\n"; <STDIN>;', side],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        assert holder.stdout.readline() == b'ready\n'
        r = run(lock, 'probe_lock_try_acquire_no_reclaim')
        assert r.returncode == 3 and not lock.exists()
    finally:
        holder.communicate(b'release\n', timeout=5)
    passed('busy reclaim critical section refuses immediately without directory creation')

    lock = root / 'contenders'
    env = {**os.environ, 'LIB': str(LIB), 'BATON_PROBE_LOCK': str(lock)}
    script = '. "$LIB"; read -r start; probe_lock_try_acquire_no_reclaim; rc=$?; echo "$rc"; if [ "$rc" = 0 ]; then read -r release; probe_lock_release_no_reclaim || exit 8; fi; exit "$rc"'
    children = [subprocess.Popen(['/bin/bash', '-c', script], env=env,
                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
    try:
        for p in children: p.stdin.write(b'start\n'); p.stdin.flush()
        codes = [int(p.stdout.readline()) for p in children]
        assert sorted(codes) == [0, 3] and lock.is_dir(), codes
        winner = codes.index(0)
        children[winner].stdin.write(b'release\n'); children[winner].stdin.flush()
        for p, code in zip(children, codes): assert p.wait(timeout=5) == code
        assert not lock.exists()
    finally:
        for p in children:
            if p.poll() is None: p.kill(); p.wait()
    passed('two non-reclaim contenders have one winner and exact own release')

    lock = root / 'legacy-race'
    lock.mkdir(); (lock / 'owner').write_text(f'{dead.pid} fixture\n')
    ident = subprocess.check_output(['/usr/bin/stat', '-f', '%i:%B', str(lock)]).decode().strip()
    lock.rename(root / 'legacy-old-owned-fixture')
    env = {**os.environ, 'LIB': str(LIB), 'BATON_PROBE_LOCK': str(lock)}
    owner = subprocess.Popen(['/bin/bash', '-c', '. "$LIB"; probe_lock_try_acquire_no_reclaim || exit 8; echo ready; read -r release; probe_lock_release_no_reclaim'],
                             env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert owner.stdout.readline() == b'ready\n'
        before = snapshot(lock)
        reclaim = run(lock, 'probe_lock_reclaim "$OLD_IDENT"', {'OLD_IDENT': ident})
        assert reclaim.returncode == 0 and not reclaim.stdout and snapshot(lock) == before
        refused = run(lock, 'probe_lock_try_acquire_no_reclaim')
        assert refused.returncode == 3 and snapshot(lock) == before
    finally:
        owner.communicate(b'release\n', timeout=5)
    assert owner.returncode == 0 and not lock.exists()
    passed('legacy stale judgement and concurrent new contender cannot remove fresh non-reclaim owner')

    # Fault only the fixture mkdir: newly created owner directory makes publication fail.
    lock = root / 'publication-failure'; shim = root / 'shim'; shim.mkdir()
    wrapper = shim / 'mkdir'
    wrapper.write_text('#!/bin/bash\n/bin/mkdir "$@" || exit $?\n/bin/mkdir "$1/owner"\n')
    wrapper.chmod(0o700)
    r = run(lock, 'probe_lock_try_acquire_no_reclaim; rc=$?; [ "$PROBE_LOCK_NO_RECLAIM_HELD" = 0 ] || exit 8; exit "$rc"',
            {'PATH': str(shim) + ':' + os.environ['PATH']})
    assert r.returncode == 1 and lock.is_dir() and (lock / 'owner').is_dir()
    passed('metadata publication failure retains exclusively created uncertain directory')

    lock = root / 'qualified-release'
    r = run(lock, 'probe_lock_try_acquire_no_reclaim || exit 8; '
        '(probe_lock_release_no_reclaim); [ "$?" = 1 ] || exit 9; [ -d "$PROBE_LOCK" ] || exit 10; '
        'old="$PROBE_LOCK_NO_RECLAIM_PROCESS"; PROBE_LOCK_NO_RECLAIM_PROCESS="${old%%:*}:invented birth"; '
        'probe_lock_release_no_reclaim; [ "$?" = 1 ] || exit 11; PROBE_LOCK_NO_RECLAIM_PROCESS="$old"; '
        'printf "\\n" >> "$PROBE_LOCK/owner"; probe_lock_release_no_reclaim; [ "$?" = 1 ] || exit 12; '
        'printf "%s\\n" "$PROBE_LOCK_NO_RECLAIM_OWNER" > "$PROBE_LOCK/owner"; '
        'touch "$PROBE_LOCK/.extra"; probe_lock_release_no_reclaim; [ "$?" = 1 ] || exit 13; '
        'rm "$PROBE_LOCK/.extra"; probe_lock_release_no_reclaim || exit 14; '
        'probe_lock_release_no_reclaim || exit 15')
    assert r.returncode == 0 and not lock.exists(), (r.returncode, r.stderr)
    passed('inherited process birth owner bytes and extra entries refuse; exact own release is idempotent')

    lock = root / 'replacement-release'
    r = run(lock, 'probe_lock_try_acquire_no_reclaim || exit 8; '
        'mv "$PROBE_LOCK" "$PROBE_LOCK.owned-old"; mkdir "$PROBE_LOCK"; '
        'printf "%s\\n" "$PROBE_LOCK_NO_RECLAIM_OWNER" > "$PROBE_LOCK/owner"; '
        'probe_lock_release_no_reclaim; [ "$?" = 1 ] || exit 9; '
        '[ -f "$PROBE_LOCK/owner" ] && [ -f "$PROBE_LOCK.owned-old/owner" ]')
    assert r.returncode == 0 and lock.is_dir()
    passed('replaced directory with matching PID and owner bytes is not released')

    lock = root / 'replacement-owner'
    r = run(lock, 'probe_lock_try_acquire_no_reclaim || exit 8; '
        'mv "$PROBE_LOCK/owner" "$PROBE_LOCK/owner.owned-old"; '
        'printf "%s\\n" "$PROBE_LOCK_NO_RECLAIM_OWNER" > "$PROBE_LOCK/owner"; '
        'rm "$PROBE_LOCK/owner.owned-old"; probe_lock_release_no_reclaim; [ "$?" = 1 ]')
    assert r.returncode == 0 and (lock / 'owner').exists()
    passed('replacement owner inode with matching contents is not released')

result = {'executed': len(CASES), 'passed': len(CASES), 'failed': 0, 'skipped': 0,
          'cases': CASES, 'started_at': STARTED, 'finished_at': time.time(),
          'actual_machine_guard_access': False, 'native_or_browser_launched': False}
print(json.dumps(result, indent=2, sort_keys=True))
