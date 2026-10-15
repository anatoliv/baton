"""Read-only validation and owned copying of the exact gate's package cache."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
from incoming_fixture_lifecycle import FixtureDiagnosticFailure

# The six pins recorded by the authoritative 5915089c iPhone gate.
EXPECTED = {
    'networkimage': ('6.0.1', '2849f5323265386e200484b0d0f896e73c3411b9'),
    'sentry-cocoa': ('8.58.4', 'f196cbb98e0388381d57908f2f5a9bdc385cde68'),
    'swift-asn1': ('1.7.3', '3b6410f7dee09eb33cdd26260c5fd47fda19b0e2'),
    'swift-cmark': ('0.9.0', '08ddb528923cc1a6527e02b7a1aee9e516ca749a'),
    'swift-crypto': ('3.15.1', '95ba0316a9b733e92bb6b071255ff46263bbe7dc'),
    'swift-markdown-ui': ('2.4.1', '5f613358148239d0292c0cef674a3c2314737f9e'),
}
SENTRY_TARGETS = {'Sentry','Sentry-Dynamic','Sentry-Dynamic-WithARM64e',
    'Sentry-WithoutUIKitOrAppKit','Sentry-WithoutUIKitOrAppKit-WithARM64e'}


def require(value, message):
    if not value: raise FixtureDiagnosticFailure('cache-validation-refused', message)


def validate_cache(cache, pins_file, command):
    cache, pins_file = Path(cache).resolve(), Path(pins_file).resolve()
    pins_bytes = pins_file.read_bytes()
    pins = json.loads(pins_bytes)['pins']
    indexed = {p['identity']: p for p in pins}
    require(len(indexed) == len(pins) and set(indexed) == set(EXPECTED), 'Pinned package set mismatch')
    state = json.loads((cache/'workspace-state.json').read_bytes())
    dependencies = state['object']['dependencies']
    remote = {d['packageRef']['identity']: d for d in dependencies if d['packageRef']['kind'] == 'remoteSourceControl'}
    require(len(remote) == 6 and set(remote) == set(EXPECTED), 'Cached package set mismatch')
    manifests = {}
    for identity, (version, revision) in EXPECTED.items():
        pin, dependency = indexed[identity], remote[identity]
        require(pin['state'] == {'version': version, 'revision': revision}, 'Pinned package revision mismatch')
        require(dependency['state']['checkoutState'] == pin['state'] and
                dependency['packageRef']['location'] == pin['location'], 'Cached package revision/location mismatch')
        checkout = (cache/'checkouts'/dependency['subpath']).resolve()
        require(checkout.is_relative_to(cache/'checkouts'), 'Cached checkout escaped package directory')
        require(command(['git','-C',str(checkout),'rev-parse','HEAD']).decode().strip() == revision,
                'Cached checkout HEAD mismatch')
        command(['git','-C',str(checkout),'diff','--exit-code','HEAD'])
        manifest = (checkout/'Package.swift').read_bytes()
        require(manifest == command(['git','-C',str(checkout),'show',revision+':Package.swift']),
                'Cached manifest mismatch')
        manifests[identity] = manifest
    artifacts = state['object']['artifacts']
    require(len(artifacts) == 5 and {a['targetName'] for a in artifacts} == SENTRY_TARGETS,
            'Expected exactly five distinct cached pinned Sentry artifacts')
    for artifact in artifacts:
        require(artifact['packageRef']['identity'] == 'sentry-cocoa', 'Unexpected cached binary artifact')
        source = artifact['source']
        require(source['checksum'].encode() in manifests['sentry-cocoa'] and
                source['url'].encode() in manifests['sentry-cocoa'], 'Cached artifact does not match pinned manifest')
        path = Path(artifact['path']).resolve()
        require(path.is_relative_to(cache/'artifacts') and path.is_dir() and (path/'Info.plist').is_file(),
                'Cached artifact missing or outside package directory')
        libraries=plistlib.loads((path/'Info.plist').read_bytes())['AvailableLibraries']
        needed=[library for library in libraries if library.get('SupportedPlatform')=='ios' and
            library.get('SupportedPlatformVariant')=='simulator' and 'arm64' in library['SupportedArchitectures']]
        require(needed, 'Cached artifact lacks required arm64 iOS simulator slice')
        for library in needed:
            binary=(path/library['LibraryIdentifier']/library['BinaryPath']).resolve()
            require(binary.is_relative_to(path) and binary.is_file() and binary.stat().st_size>0,
                    'Cached simulator artifact binary missing or outside package directory')
    return pins_bytes, state, {'pinsSHA256': hashlib.sha256(pins_bytes).hexdigest(),
        'packages': {k: {'version': v[0], 'revision': v[1]} for k,v in EXPECTED.items()},
        'sourceCache': str(cache), 'pinnedManifestsValidated': True, 'cachedArtifacts': 5}


def copy_cache(cache, pins_file, destination, repo, command, on_phase=None):
    cache, destination, repo = Path(cache).resolve(), Path(destination).resolve(), Path(repo).resolve()
    if on_phase: on_phase('cache-validation')
    pins_bytes, state, receipt = validate_cache(cache,pins_file,command)
    if on_phase: on_phase('cache-copy')
    require(not destination.exists(), 'Owned package-cache destination must be fresh')
    destination.mkdir(mode=0o700)
    # Copies only dependencies, never cached object/build products or gate results.
    for name in ('checkouts','repositories','artifacts'):
        shutil.copytree(cache/name,destination/name,symlinks=True)
    for dependency in state['object']['dependencies']:
        if dependency['packageRef']['kind'] == 'fileSystem':
            name = Path(dependency['packageRef']['location']).name
            path = repo/'Packages'/name
            require((path/'Package.swift').is_file(), 'Cached local package missing in fixture source')
            dependency['packageRef']['location'] = str(path)
            dependency['state']['path'] = str(path)
    for artifact in state['object']['artifacts']:
        artifact['path'] = str(destination/Path(artifact['path']).resolve().relative_to(cache))
    (destination/'workspace-state.json').write_text(json.dumps(state,indent=2)+'\n')
    receipt['ownedCopy'] = str(destination)
    return pins_bytes, receipt


def offline_environment(env):
    # Git is denied non-file protocols even if a dependency is unexpectedly missing.
    # URLSession artifact requests also fail immediately through a closed loopback proxy.
    return dict(env,GIT_ALLOW_PROTOCOL='file',GIT_TERMINAL_PROMPT='0',
        HTTP_PROXY='http://127.0.0.1:9',HTTPS_PROXY='http://127.0.0.1:9',ALL_PROXY='http://127.0.0.1:9',
        http_proxy='http://127.0.0.1:9',https_proxy='http://127.0.0.1:9',all_proxy='http://127.0.0.1:9',
        NO_PROXY='127.0.0.1,localhost',no_proxy='127.0.0.1,localhost')
