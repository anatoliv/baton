#!/usr/bin/env python3
"""Reconstruct the exact qualified worker plus the reviewed feedback overlay.

Local Git objects and tracked source only. No provider/configuration/credential
discovery, network, build, service start or production admission.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

BASE = '63e4a33df49b5d9053abe5f8d335b9ebc4267ff2'
REFERENCE = 'docs/engineering/tbx-8936-feedback-integration/qualified-base-source.json'
PATCH = 'docs/engineering/tbx-8936-feedback-integration/runtime-63e4a33.patch'
OVERLAY = ('private_contact/feedback.py', 'private_contact/sns_feedback.py',
           'private_contact/feedback_ingress.py')
GIT_ENV = {'PATH': os.defpath, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}


def stage(source_root, output, with_backup=False):
    source_root, output = Path(source_root).resolve(), Path(output)
    if not output.is_absolute() or output.resolve() != output or output.exists():
        raise ValueError('refused')
    reference = json.loads((source_root / REFERENCE).read_bytes())
    if reference['commit'] != BASE:
        raise ValueError('refused')
    content = {}
    for name, expected in reference['files'].items():
        result = subprocess.run(['git', '-C', str(source_root), 'show', BASE + ':' + name],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=GIT_ENV, timeout=5, check=True)
        if hashlib.sha256(result.stdout).hexdigest() != expected:
            raise ValueError('refused')
        content[name] = result.stdout
    output.mkdir(mode=0o700)
    for name, data in content.items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    subprocess.run(['git', 'apply', '--check', str(source_root / PATCH)], cwd=output,
                   env=GIT_ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=5, check=True)
    subprocess.run(['git', 'apply', str(source_root / PATCH)], cwd=output,
                   env=GIT_ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=5, check=True)
    for name in OVERLAY:
        (output / name).write_bytes((source_root / name).read_bytes())
    if with_backup:
        backup_patch = source_root / 'docs/engineering/tbx-8936-feedback-integration/backup-runtime.patch'
        subprocess.run(['git', 'apply', '--check', str(backup_patch)], cwd=output, env=GIT_ENV,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
        subprocess.run(['git', 'apply', str(backup_patch)], cwd=output, env=GIT_ENV,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
        for name in ('private_contact/backup.py', 'private_contact/backup_job.py', 'private_contact/onedrive.py'):
            (output / name).write_bytes((source_root / name).read_bytes())
    names = sorted(set(content) | set(OVERLAY) | ({'private_contact/backup.py', 'private_contact/backup_job.py', 'private_contact/onedrive.py'} if with_backup else set()))
    digests = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in names}
    receipt = dict(version=1, base=BASE, patch_sha256=hashlib.sha256((source_root / PATCH).read_bytes()).hexdigest(),
                   base_source_digests=reference['files'], integrated_source_digests=digests)
    if with_backup:
        receipt['backup_patch_sha256'] = hashlib.sha256(backup_patch.read_bytes()).hexdigest()
    (output / 'feedback-integration-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-directory', required=True)
    parser.add_argument('--with-backup', action='store_true')
    arguments = parser.parse_args()
    try:
        receipt = stage(Path(__file__).resolve().parent.parent, arguments.output_directory, with_backup=arguments.with_backup)
        print(json.dumps({'staged_files': len(receipt['integrated_source_digests']),
                          'base': BASE, 'production_activation': False}))
        return 0
    except Exception:
        print('feedback-runtime: source staging refused', file=sys.stderr)
        return 78


if __name__ == '__main__':
    raise SystemExit(main())
