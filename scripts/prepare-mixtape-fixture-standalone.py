#!/usr/bin/env python3
"""Prepare a private source-bound attempt; never acquire a lock or run a compiler."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mixtape_ui_packages import qualify_git_config

REPO = Path(__file__).resolve().parent.parent


def require(condition):
    if not condition: raise ValueError("Standalone fixture preparation refused")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['output', 'source', 'selection-manifest', 'gateway-cache', 'gateway-pins']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    root, cache, pins = Path(args.output), Path(args.gateway_cache), Path(args.gateway_pins)
    manifest = Path(args.selection_manifest)
    require(root.is_absolute() and root == root.resolve() and root.parent == Path('/private/tmp') and not root.exists())
    require(not root.with_name(root.name + '.cancel-requested').exists())
    require(re.fullmatch(r'[0-9a-f]{40}', args.source))
    require(pins == REPO / 'gateway/Package.resolved' and manifest == manifest.resolve()
        and manifest.is_relative_to(REPO / 'docs/evidence/tbx-9252'))
    qualify_git_config(cache, pins.read_bytes())
    selection = json.loads(manifest.read_bytes())
    source_hashes = {}
    for name, digest in selection['sourceSHA256'].items():
        source = REPO / name
        require(source == source.resolve() and source.is_relative_to(REPO))
        require(hashlib.sha256(source.read_bytes()).hexdigest() == digest)
        source_hashes[str(source)] = digest
    for path in [manifest, cache / 'workspace-state.json', pins]:
        require(path == path.resolve() and path.is_file())
        source_hashes[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    for area in ['checkouts', 'repositories']:
        for repository in (cache / area).iterdir():
            config = repository / ('.git/config' if area == 'checkouts' else 'config')
            source_hashes[str(config)] = hashlib.sha256(config.read_bytes()).hexdigest()
    os.umask(0o077)
    root.mkdir(mode=0o700)
    controller = root / 'controller.py'
    controller.write_bytes((REPO / 'scripts/mixtape_fixture_standalone_controller.py').read_bytes())
    inputs = root / 'fixture-inputs.json'
    inputs.write_text(json.dumps({'repository': str(REPO), 'source': args.source,
        'selectionManifest': str(manifest), 'gatewayCache': str(cache), 'gatewayPins': str(pins)}, indent=2) + '\n')
    guard = root / 'compiler-attempt.lock'
    guard.touch()
    for path in [controller, inputs, guard]: path.chmod(0o600)
    for path in [controller, inputs]: source_hashes[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    a = guard.stat()
    binding = root / 'command-binding.json'
    binding.write_text(json.dumps({'schemaVersion': 1, 'attemptRoot': str(root),
        'repository': str(REPO), 'controllerPath': str(controller), 'guardPath': str(guard),
        'guardIdentity': {'device': a.st_dev, 'inode': a.st_ino, 'uid': a.st_uid, 'links': a.st_nlink, 'mode': 0o600},
        'sourceSHA256': source_hashes, 'mode': 'offline-compiler-only'}, indent=2) + '\n')
    binding.chmod(0o600)
    require(binding.stat().st_size <= 65_536)
    print('Preparation only:', binding)
    print('Binding SHA256:', hashlib.sha256(binding.read_bytes()).hexdigest())


if __name__ == '__main__': main()
