#!/usr/bin/env python3
"""Validate a privately reviewed incoming binding, then replace this process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
CALLER = './scripts/probe-incoming-share-flow.sh'
SELECTOR = 'testIncomingAboveSetupCoverPreservesTypedServer'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def private_binding(path, digest):
    path = Path(path)
    require(path == path.resolve(), 'Canonical binding path required')
    parent = path.parent.stat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid() and
            stat.S_IMODE(parent.st_mode) == 0o700, 'Owner-only binding parent required')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        attrs = os.fstat(stream.fileno())
        require(stat.S_ISREG(attrs.st_mode) and attrs.st_uid == os.getuid() and
                stat.S_IMODE(attrs.st_mode) == 0o600 and attrs.st_size <= 1024 * 1024,
                'Owner-only regular binding required')
        data = stream.read(1024 * 1024 + 1)
    require(hashlib.sha256(data).hexdigest() == digest, 'Reviewed binding digest mismatch')
    return json.loads(data)


def check_source(binding, repo):
    require(binding['cwd'] == str(repo), 'Binding checkout mismatch')
    head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'],
                                   timeout=3, text=True).strip()
    require(head == binding['executionSource'], 'Binding source mismatch')
    require(not subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'],
                                        timeout=3, text=True).strip(), 'Clean checkout required')
    for name, digest in binding['sourceSHA256'].items():
        path = repo / name
        require(path.resolve().is_relative_to(repo) and not path.is_symlink(),
                'Canonical source required')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest,
                'Binding source bytes mismatch')
    require('scripts/exec-incoming-command-binding.py' in binding['sourceSHA256'],
            'Invocation source must be pinned')


def validate(path, digest, repo=REPO):
    binding = private_binding(path, digest)
    check_source(binding, repo)
    argv = binding['command']['argv']
    require(isinstance(argv, list) and all(isinstance(x, str) for x in argv) and
            argv[0:2] == [CALLER, '--run'] and len(argv) == 14 and
            argv[2::2] == ['--share-bin', '--share-bin-sha256', '--package-cache',
                           '--package-pins', '--navidrome-image', '--only-test'] and
            argv[-1] == SELECTOR, 'Exact incoming command shape required')
    inputs = binding['inputs']
    binary = inputs['serviceBinary']
    require(argv[3] == binary['path'] and Path(argv[3]).name == 'baton-share' and
            argv[5] == binary['sha256'] and argv[7] == inputs['packageCache']['path'] and
            argv[9] == inputs['packagePins']['path'] and
            argv[11] == inputs['navidromeImage']['requested'], 'Bound input arguments mismatch')
    bundle = Path(binary['path']).parent / 'baton-gateway_BatonShareServer.bundle'
    require(str(bundle) == inputs['resourceBundle']['path'] and bundle.is_dir() and
            not bundle.is_symlink(), 'Bound sibling bundle required')
    for item in [binary, inputs['packagePins']] + inputs['resourceBundle']['files']:
        source = Path(item['path'])
        require(source.is_file() and not source.is_symlink() and
                source.stat().st_size == item['bytes'] and
                hashlib.sha256(source.read_bytes()).hexdigest() == item['sha256'],
                'Bound input bytes mismatch')
    log = Path(binding['command']['log'])
    require(log.parent == Path(path).parent and not log.exists() and not log.is_symlink(),
            'Fresh private log required')
    return argv, log


def invoke(path, digest, repo=REPO):
    argv, log = validate(path, digest, repo)
    os.umask(0o077)
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    if fd > 2:
        os.close(fd)
    os.chdir(repo)
    os.execv(argv[0], argv)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binding', required=True)
    parser.add_argument('--sha256', required=True)
    args = parser.parse_args()
    try:
        invoke(args.binding, args.sha256)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('REFUSED: incoming binding or execution precondition failed', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
