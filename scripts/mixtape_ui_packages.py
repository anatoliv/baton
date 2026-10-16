"""Public configuration qualification and isolated dependency-only copying."""
import hashlib
import json
from pathlib import Path
import re
import shutil
from urllib.parse import urlsplit

GATEWAY_VERSIONS = {'swift-asn1': '1.6.0', 'swift-certificates': '1.10.0', 'swift-crypto': '3.15.1'}


def require(value):
    if not value: raise ValueError('Public pinned dependency configuration refused')


def public_url(value):
    p = urlsplit(value)
    require(p.scheme == 'https' and p.netloc == 'github.com' and not p.query and not p.fragment
        and re.fullmatch(r'/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?', p.path))
    return value


def public_config(text, allowed):
    # Key/section allowlist before interpreting a value. Unknown settings such
    # as credential helpers, extra headers, hooks, filters and includes refuse.
    section = None; origin = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(('#', ';')): continue
        if stripped.startswith('['):
            match = re.fullmatch(r'\[(core|remote "origin"|branch "[A-Za-z0-9_.-]+")\]', stripped)
            require(match is not None); section = match[1]; continue
        key, separator, value = stripped.partition('='); key = key.strip().lower()
        require(separator and section is not None)
        if section == 'core':
            require(key in {'repositoryformatversion', 'filemode', 'bare', 'logallrefupdates', 'ignorecase', 'precomposeunicode', 'symlinks'})
            value = value.strip().lower()
            require(value in ({'0', '1'} if key == 'repositoryformatversion' else {'true', 'false'}))
        elif section == 'remote "origin"':
            require(key in {'url', 'fetch', 'mirror'})
            value = value.strip()
            if key == 'url':
                require(origin is None and value in allowed); public_url(value); origin = value
            elif key == 'fetch': require(value in {'+refs/heads/*:refs/remotes/origin/*', '+refs/*:refs/*'})
            else: require(value.lower() in {'true', 'false'})
        else:
            require(key in {'remote', 'merge'})
            value = value.strip()
            require(value == 'origin' if key == 'remote' else re.fullmatch(r'refs/heads/[A-Za-z0-9_.-]+', value))
    require(origin is not None)
    return origin


def qualify_git_config(cache, pins_bytes):
    cache = Path(cache).resolve(); pins = json.loads(pins_bytes)['pins']
    allowed = {public_url(p['location']) for p in pins}
    seen = set(); count = 0
    for area in ['checkouts', 'repositories']:
        directory = cache / area
        require(directory.is_dir())
        for repository in sorted(directory.iterdir()):
            require(repository.is_dir() and repository == repository.resolve() and repository.resolve().is_relative_to(directory))
            config = repository / ('.git/config' if area == 'checkouts' else 'config')
            require(config.is_file() and config == config.resolve() and config.resolve().is_relative_to(cache) and config.stat().st_size <= 65_536)
            seen.add(public_config(config.read_text(), allowed)); count += 1
    require(seen == allowed)
    return {'publicConfigurations': count, 'allowedPublicOrigins': len(allowed), 'configurationQualified': True}


def gateway_copy(cache, pins_path, destination, repo, command):
    cache, destination, repo = Path(cache).resolve(), Path(destination).resolve(), Path(repo).resolve()
    pins_bytes = Path(pins_path).read_bytes(); pins = json.loads(pins_bytes)['pins']
    indexed = {p['identity']: p for p in pins}
    require(len(indexed) == len(pins) == 3 and set(indexed) == set(GATEWAY_VERSIONS))
    config = qualify_git_config(cache, pins_bytes)
    state = json.loads((cache / 'workspace-state.json').read_bytes())
    remote = {d['packageRef']['identity']: d for d in state['object']['dependencies'] if d['packageRef']['kind'] == 'remoteSourceControl'}
    require(set(remote) == set(indexed) and not state['object']['artifacts'])
    for identity, version in GATEWAY_VERSIONS.items():
        pin = indexed[identity]; dependency = remote[identity]
        require(pin['state']['version'] == version and dependency['state']['checkoutState'] == pin['state']
            and dependency['packageRef']['location'] == pin['location'])
        checkout = (cache / 'checkouts' / dependency['subpath']).resolve()
        require(checkout.is_relative_to(cache / 'checkouts'))
        require(command(['git', '-C', str(checkout), 'rev-parse', 'HEAD']).decode().strip() == pin['state']['revision'])
        command(['git', '-C', str(checkout), 'diff', '--exit-code', 'HEAD'])
        require(command(['git', '-C', str(checkout), 'status', '--porcelain=v1', '--untracked-files=all', '--ignored=matching']).strip() == b'')
        require((checkout / 'Package.swift').read_bytes() == command(['git', '-C', str(checkout), 'show', pin['state']['revision'] + ':Package.swift']))
    require(not destination.exists()); destination.mkdir(mode=0o700)
    # The gateway has three source dependencies and no binary artifacts. Never
    # copy object products, previous test results or another writer's scratch.
    for name in ['checkouts', 'repositories']:
        require(all(not item.is_symlink() for item in (cache / name).rglob('*')))
    for name in ['checkouts', 'repositories']:
        shutil.copytree(cache / name, destination / name, symlinks=True)
    for dependency in state['object']['dependencies']:
        if dependency['packageRef']['kind'] == 'fileSystem':
            path = repo / 'Packages' / Path(dependency['packageRef']['location']).name
            require((path / 'Package.swift').is_file())
            dependency['packageRef']['location'] = str(path); dependency['state']['path'] = str(path)
    (destination / 'workspace-state.json').write_text(json.dumps(state, indent=2) + '\n')
    return {'pinsSHA256': hashlib.sha256(pins_bytes).hexdigest(), 'remotePackages': 3,
        'sourceCache': str(cache), 'ownedCopy': str(destination), 'noBuildProductsCopied': True, **config}
