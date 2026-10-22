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


def read_config(text):
    # Key/section allowlist before interpreting a value. Unknown settings such
    # as credential helpers, extra headers, hooks, filters and includes refuse.
    # Returns the origin URL as recorded; callers decide what it may name.
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
            # fsmonitor and longpaths are what current SwiftPM writes (false and true).
            require(key in {'repositoryformatversion', 'filemode', 'bare', 'logallrefupdates', 'ignorecase',
                            'precomposeunicode', 'symlinks', 'fsmonitor', 'longpaths'})
            value = value.strip().lower()
            require(value in ({'0', '1'} if key == 'repositoryformatversion' else {'true', 'false'}))
            # fsmonitor = true would start git's fsmonitor daemon, a process outside the owned
            # command and an IPC socket inside the cache, on gateway_copy's git diff/status.
            require(key != 'fsmonitor' or value == 'false')
        elif section == 'remote "origin"':
            require(key in {'url', 'fetch', 'mirror', 'tagopt'})
            value = value.strip()
            if key == 'url':
                require(origin is None and value); origin = value
            elif key == 'fetch': require(value in {'+refs/heads/*:refs/remotes/origin/*', '+refs/*:refs/*'})
            elif key == 'tagopt': require(value == '--no-tags')
            else: require(value.lower() in {'true', 'false'})
        else:
            require(key in {'remote', 'merge'})
            value = value.strip()
            require(value == 'origin' if key == 'remote' else re.fullmatch(r'refs/heads/[A-Za-z0-9_.-]+', value))
    require(origin is not None)
    return origin


def public_config(text, allowed):
    origin = read_config(text)
    require(origin in allowed); public_url(origin)
    return origin


def owned_file(path, root, limit):
    require(path.is_file() and not path.is_symlink() and path == path.resolve()
        and path.resolve().is_relative_to(root) and path.stat().st_size <= limit)
    return path.read_text()


def qualify_git_config(cache, pins_bytes):
    """Every mirror in repositories/ names an allowed public pin. Every checkout either names
    one too, or (current SwiftPM) names the local path of one of this cache's own mirrors, and
    then its detached HEAD must be exactly that pin's revision. The revision decides, not the
    spelling of the origin, and nothing in the cache is changed (TBX-1000000539)."""
    cache = Path(cache).resolve(); pins = json.loads(pins_bytes)['pins']
    allowed = {public_url(p['location']) for p in pins}
    revisions = {p['location']: p['state']['revision'] for p in pins}
    identities = {p['location']: p['identity'] for p in pins}
    require(all(re.fullmatch(r'[0-9a-f]{40}', revision) for revision in revisions.values()))
    seen = set(); count = 0; local = 0; mirrors = {}
    for area in ['repositories', 'checkouts']:
        directory = cache / area
        require(directory.is_dir())
        for repository in sorted(directory.iterdir()):
            require(repository.is_dir() and repository == repository.resolve() and repository.resolve().is_relative_to(directory))
            config = repository / ('.git/config' if area == 'checkouts' else 'config')
            text = owned_file(config, cache, 65_536)
            if area == 'repositories':
                origin = public_config(text, allowed); mirrors[repository] = origin
            else:
                origin = read_config(text)
                if origin not in allowed:
                    recorded = Path(origin)
                    # SwiftPM records the path as it was given (/tmp for /private/tmp), so symlinks
                    # resolve; a '..' never names a mirror.
                    require(recorded.is_absolute() and '..' not in recorded.parts and recorded.resolve() in mirrors)
                    origin = mirrors[recorded.resolve()]
                    # Bound to its own package: a checkout is named for the package's identity.
                    require(repository.name.lower() == identities[origin])
                    head = owned_file(repository / '.git/HEAD', cache, 128)
                    require(head.strip() == revisions[origin] and head in (revisions[origin], revisions[origin] + '\n'))
                    local += 1
                public_url(origin)
            seen.add(origin); count += 1
    require(seen == allowed)
    return {'publicConfigurations': count, 'allowedPublicOrigins': len(allowed), 'configurationQualified': True,
            'localMirrorCheckouts': local, 'revisionVerifiedCheckouts': local}


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
