#!/usr/bin/env python3
"""Prepared two-walk UI controller; no operation without a fresh reviewed --run."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import signal
import stat
import sys
import time
from urllib.parse import urlencode, urlparse
from urllib.request import Request
from incoming_fixture_lifecycle import Deadline as BaseDeadline, write_receipt, write_failure
from incoming_fixture_packages import copy_cache, offline_environment
from mixtape_owned_lifecycle import ReservedOwnedFixture, cleanup_qualified, release_qualified, retain_custody, best_effort
from mixtape_ui_control import MixtapeUIActions, MixtapeUIControl
from mixtape_owned_http import OwnedHTTPOutbound
from mixtape_ui_packages import gateway_copy, qualify_git_config
from mixtape_ui_pending import create_pending
from mixtape_ui_proxy import MixtapeUIProxy

REPO = Path(__file__).resolve().parent.parent
SELECTION = (
    'MixtapeComposerFlowUITests/testMixtapeRecipientOrderedControlsBackgroundAndAccessibleFailures',
    'MixtapeComposerFlowUITests/testMixtapeSharedLinksRefreshExtendReviewRevokeAndForget',
)


class UICustodyDeadline(BaseDeadline):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.custody_unqualified = False
    def alarm(self, signum, frame):
        # Installed by inherited arm() from the start. No active behavior is
        # changed; this one-way abandoned state never resumes commands/release.
        if self.custody_unqualified: return
        return super().alarm(signum, frame)


Deadline = UICustodyDeadline


def require(value, message='Prepared UI fixture refused'):
    if not value: raise ValueError(message)


def owned_json(path, maximum=1_048_576):
    path = Path(path); attrs = path.lstat()
    require(path.is_absolute() and path == path.resolve() and stat.S_ISREG(attrs.st_mode)
        and stat.S_IMODE(attrs.st_mode) == 0o600 and attrs.st_uid == os.getuid()
        and attrs.st_size <= maximum)
    return json.loads(path.read_bytes())


def selector_manifest(path):
    path = Path(path)
    require(path.resolve().is_relative_to(REPO / 'docs/evidence/tbx-9252'))
    data = json.loads(path.read_bytes())
    require(data['selectors'] == list(SELECTION))
    source = (REPO / 'ios/Tests/BatonMobileUITests/MixtapeComposerFlowUITests.swift').read_bytes()
    for name in SELECTION:
        require(source.count(('func ' + name.split('/')[1] + '(').encode()) == 1)
    return data


def gateway_source_closure(repo=REPO):
    names = {'gateway/Package.swift', 'gateway/Package.resolved',
        'gateway/Sources/baton-mixtape-ui-fixture/main.swift'}
    for area in ['gateway/Sources/BatonShareServer', 'gateway/Sources/BatonGatewayCore',
                 'gateway/Sources/CSQLite', 'Packages/BatonMCPProtocol', 'Packages/BatonDocuments', 'Packages/BatonShareKit']:
        for source in (repo / area).rglob('*'):
            if source.is_file() and '.build' not in source.parts and '.git' not in source.parts:
                if area.startswith('gateway/Sources/') or source.name == 'Package.swift' or 'Sources' in source.relative_to(repo / area).parts:
                    require(source == source.resolve())
                    names.add(str(source.relative_to(repo)))
    return {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in sorted(names)}


def local_request(custody, deadline, base, method, path, body=None, authority=None, json_response=True):
    from mixtape_ui_control import origin
    port = origin(base).port
    require(path.startswith('/') and not path.startswith('//'))
    headers = {'Content-Type': 'application/json'} if body is not None else {}
    if authority is not None: headers['Authorization'] = 'Bearer ' + authority
    encoded = None if body is None else json.dumps(body).encode()
    def action(connection):
        connection.request(method, path, body=encoded, headers=headers)
        response = custody.response(connection)
        data = response.read(512_001)
        require(200 <= response.status < 300 and len(data) <= 512_000)
        return (json.loads(data) if data else None) if json_response else data
    return custody.run(port, action)


def fixture_artifact(path):
    receipt = owned_json(path)
    require(receipt.get('qualified') is True and receipt.get('product') == 'baton-mixtape-ui-fixture'
        and type(receipt.get('cliRefusalsPassed')) is int and receipt['cliRefusalsPassed'] >= 4)
    require(receipt['sourceSHA256'] == gateway_source_closure())
    binary = Path(receipt['binary']); resources = Path(receipt['resourceDirectory']); artifact_root = Path(receipt['artifactRoot'])
    protection = artifact_root.lstat()
    require(artifact_root.is_relative_to('/private/tmp') and artifact_root == artifact_root.resolve()
        and stat.S_ISDIR(protection.st_mode) and stat.S_IMODE(protection.st_mode) == 0o700
        and protection.st_uid == os.getuid() and binary.is_relative_to(artifact_root) and resources.is_relative_to(artifact_root))
    attrs = binary.lstat()
    require(binary.is_relative_to('/private/tmp') and binary == binary.resolve()
        and binary.name == 'baton-mixtape-ui-fixture' and stat.S_ISREG(attrs.st_mode)
        and attrs.st_uid == os.getuid() and attrs.st_mode & 0o111
        and hashlib.sha256(binary.read_bytes()).hexdigest() == receipt['binarySHA256'])
    require(resources.is_relative_to('/private/tmp') and resources == resources.resolve() and resources.is_dir())
    expected = {}
    for area in ['Web', 'AttestationRoots']:
        for source in sorted((REPO / 'gateway/Sources/BatonShareServer' / area).rglob('*')):
            if source.is_file(): expected[str(source.relative_to(REPO / 'gateway/Sources/BatonShareServer'))] = hashlib.sha256(source.read_bytes()).hexdigest()
    actual = {}
    for resource in sorted(resources.rglob('*')):
        if resource.is_file():
            attrs = resource.lstat()
            require(resource == resource.resolve() and stat.S_ISREG(attrs.st_mode) and attrs.st_uid == os.getuid()
                and not attrs.st_mode & 0o022 and attrs.st_size <= 16_777_216)
            actual[str(resource.relative_to(resources))] = hashlib.sha256(resource.read_bytes()).hexdigest()
    require(actual == expected == receipt['resourcesSHA256'])
    for name, digest in receipt['sourceSHA256'].items():
        source = REPO / name
        require(source.resolve().is_relative_to(REPO) and hashlib.sha256(source.read_bytes()).hexdigest() == digest)
    return binary, receipt


def qualify_fixture(root, args, command):
    """Build this exact local product and qualify its public refusal contract."""
    sources = gateway_source_closure()
    scratch = root / 'gateway-build'
    cache = root / 'gateway-cache'
    dependency_receipt = gateway_copy(args.gateway_cache, args.gateway_pins,
        scratch, REPO, lambda argv: command(argv)[0])
    cache.mkdir(mode=0o700)
    common = ['swift', 'build', '--package-path', str(REPO / 'gateway'),
        '--scratch-path', str(scratch), '--cache-path', str(cache),
        '--disable-automatic-resolution', '--skip-update']
    _, build_rc = command([*common, '--product', 'baton-mixtape-ui-fixture'], cap=600)
    require(build_rc == 0)
    output, bin_rc = command([*common, '--show-bin-path'])
    require(bin_rc == 0)
    directory = Path(output.decode().strip())
    require(directory.is_absolute() and directory == directory.resolve()
        and directory.is_relative_to(scratch) and directory.is_dir())
    binary = directory / 'baton-mixtape-ui-fixture'
    resources = directory / 'baton-gateway_BatonShareServer.bundle' / 'Contents/Resources'
    attrs = binary.lstat()
    require(binary == binary.resolve() and stat.S_ISREG(attrs.st_mode)
        and attrs.st_uid == os.getuid() and attrs.st_mode & 0o111 and not attrs.st_mode & 0o022)
    require(resources == resources.resolve() and resources.is_dir())
    expected = {}
    for area in ['Web', 'AttestationRoots']:
        for source in sorted((REPO / 'gateway/Sources/BatonShareServer' / area).rglob('*')):
            if source.is_file():
                expected[str(source.relative_to(REPO / 'gateway/Sources/BatonShareServer'))] = hashlib.sha256(source.read_bytes()).hexdigest()
    actual = {}
    for resource in sorted(resources.rglob('*')):
        require(resource == resource.resolve())
        attrs = resource.lstat()
        require(attrs.st_uid == os.getuid() and not attrs.st_mode & 0o022)
        if resource.is_file():
            require(stat.S_ISREG(attrs.st_mode) and attrs.st_size <= 16_777_216)
            actual[str(resource.relative_to(resources))] = hashlib.sha256(resource.read_bytes()).hexdigest()
        else: require(stat.S_ISDIR(attrs.st_mode))
    require(actual == expected and sources == gateway_source_closure())
    candidate = root.with_name(root.name + '-cli-refusal')
    require(not candidate.exists())
    capability_file = root / 'unsafe-synthetic-capabilities.json'
    # Deliberately public constants and unsafe mode: this refusal must occur
    # before service creation, and supplies no owner/provider authority.
    write_receipt(capability_file, {'admin': 'a' * 32, 'operator': 'o' * 32})
    capability_file.chmod(0o644)
    cases = [([], 'missing-arguments'),
        ([str(root / 'nested-service'), '49171', str(capability_file)], 'nested-root'),
        ([str(candidate), '80', str(capability_file)], 'privileged-port'),
        ([str(candidate), '49171', str(capability_file)], 'unsafe-capability-file')]
    refusals = []
    for arguments, name in cases:
        output, rc = command([str(binary), *arguments], cap=5, accept_failure=True)
        require(rc == 64 and output == b'mixtape UI fixture: invalid disposable inputs\n'
            and not candidate.exists() and not (root / 'nested-service').exists())
        refusals.append({'case': name, 'exitCode': rc, 'serviceRootAbsent': True})
    require(sources == gateway_source_closure())
    receipt = {'qualified': True, 'product': 'baton-mixtape-ui-fixture',
        'artifactRoot': str(root), 'binary': str(binary), 'resourceDirectory': str(resources),
        'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'resourcesSHA256': actual, 'sourceSHA256': sources,
        'cliRefusalsPassed': len(refusals), 'cliRefusals': refusals,
        'dependencyCache': dependency_receipt}
    path = root / 'fixture-artifact.json'
    write_receipt(path, receipt)
    fixture_artifact(path)
    return receipt


def qualify_ui_release(root):
    root = Path(root)
    if not release_qualified(root): return False
    for name in ['mixtape-ui-control-ownership.json', 'mixtape-ui-proxy-ownership.json']:
        receipt = owned_json(root / name)
        if not (receipt.get('closed') is True and receipt.get('listenerClosed') is True
                and receipt.get('acceptedRequestsClosed') is True and receipt.get('acceptUncertain') is False
                and receipt.get('listenerUncertain') is False and receipt.get('additionalResourcesClosed') is True): return False
    return (owned_json(root / 'ui-resources-cleanup.json').get('qualified') is True
        and owned_json(root / 'mixtape-ui-controller-http.json').get('additionalResourcesClosed') is True)


def _park_original_parent():
    # No setup, diagnostics, signals, cleanup or automatic retry in this loop.
    while True:
        try: time.sleep(30)
        except BaseException: pass


def hold_original_parent(root, deadline):
    # ONE WAY: this abandoned deadline may never govern an active command again.
    # If disarm fails, the accepted alarm must no longer take its hard os._exit.
    deadline.custody_unqualified = True
    deadline.hard_end = float('inf')
    try: retain_custody(root, deadline)
    except BaseException: pass
    _park_original_parent()


def finish(root, deadline, owned, listeners, result, current, failure=None, outbound=None,
           scope='Exactly two native UI walks; no Mac/physical/browser/distribution acceptance'):
    # Faults go directly to original-parent retention, before diagnostic I/O.
    try: deadline.enter_cleanup()
    except BaseException: hold_original_parent(root, deadline)
    for name, listener in zip(['mixtape-ui-proxy-ownership.json', 'mixtape-ui-control-ownership.json'], listeners):
        if listener is None:
            try: write_receipt(root / name, {'notStarted': True, 'closed': True, 'listenerClosed': True,
                'acceptedRequestsClosed': True, 'acceptUncertain': False, 'listenerUncertain': False,
                'additionalResourcesClosed': True})
            except BaseException: hold_original_parent(root, deadline)
            continue
        try: qualified = listener.close()
        except BaseException: qualified = False
        if not qualified: hold_original_parent(root, deadline)
    try:
        http_status = {'additionalResourcesClosed': True, 'notStarted': True} if outbound is None else outbound.status()
        if http_status.get('additionalResourcesClosed') is not True: hold_original_parent(root, deadline)
        write_receipt(root / 'mixtape-ui-controller-http.json', http_status)
    except BaseException: hold_original_parent(root, deadline)
    try: cleanup = owned.cleanup()
    except BaseException: hold_original_parent(root, deadline)
    if not cleanup_qualified(cleanup): hold_original_parent(root, deadline)
    try:
        deadline.disarm()
        if failure is not None: write_failure(root / 'failure.json', *failure)
        write_receipt(root / 'ui-resources-cleanup.json', {'qualified': True, 'originalParentRetainedUntilQualification': True})
        write_receipt(root / 'result.json', {'exitCode': result, 'commit': current, 'scope': scope})
        write_receipt(root / 'native-custody-release.json', {'qualified': True,
            'registeredGroupsAbsent': True, 'schemeRestoredExactly': True,
            'simulatorAbsent': cleanup['simulatorAbsent'], 'containerAbsent': cleanup['containerAbsent']})
    except BaseException: hold_original_parent(root, deadline)


def actual_cases(tree):
    pending, cases = list(tree.get('testNodes', [])), []
    while pending:
        node = pending.pop(); pending.extend(node.get('children', []))
        if node.get('nodeType') != 'Test Case': continue
        parts = urlparse(node.get('nodeIdentifierURL', '')).path.strip('/').split('/')
        cases.append((parts[1] if len(parts) >= 2 else 'unknown', node.get('nodeIdentifier', '').removesuffix('()'), node.get('result')))
    return cases


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--qualify-release':
        try: return 0 if qualify_ui_release(sys.argv[2]) else 1
        except BaseException: return 1
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['source', 'output', 'selection-manifest', 'gateway-cache', 'gateway-pins']:
        parser.add_argument('--' + key, required=True)
    for key in ['fixture-receipt', 'package-cache', 'package-pins', 'navidrome-image']:
        parser.add_argument('--' + key)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--qualify-fixture', action='store_true')
    args = parser.parse_args()
    if args.qualify_fixture:
        if any(getattr(args, key) is not None for key in ['fixture_receipt', 'package_cache', 'package_pins', 'navidrome_image']):
            parser.error('Fixture qualification does not accept UI inputs')
    elif any(getattr(args, key) is None for key in ['fixture_receipt', 'package_cache', 'package_pins', 'navidrome_image']):
        parser.error('The UI walks require their fixture, iOS cache/pins and catalog image')
    selection = selector_manifest(args.selection_manifest)
    require(re.fullmatch(r'[0-9a-f]{40}', args.source))
    if not args.run:
        print('Preparation only: caller/executable qualification and fresh root GO required.'); return 0
    root = Path(args.output)
    service_root = root.with_name(root.name + '-service')
    require(root.is_absolute() and root == root.resolve() and root.parent == Path('/private/tmp')
        and not root.exists() and not service_root.exists() and not root.with_name(root.name + '.cancel-requested').exists())
    require(Path('/tmp/baton-probe.lock/owner').read_text().split()[0] == str(os.getppid()))
    os.umask(0o077); root.mkdir(mode=0o700)
    deadline = Deadline(); stage, operation = 'setup', 'command'
    spec = importlib.util.spec_from_file_location('ui_fixture_helpers', REPO / 'scripts/probe-share-fixture.py')
    f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
    env = f.clean_environment(root)
    env = dict(offline_environment(env), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
    owned = ReservedOwnedFixture(root, env, deadline)
    outbound = OwnedHTTPOutbound(deadline)
    result, proxy, control, current = 1, None, None, args.source
    failure = None
    scope = ('Local fixture build/resources/CLI only; zero UI tests, simulator or service starts'
        if args.qualify_fixture else 'Exactly two native UI walks; no Mac/physical/browser/distribution acceptance')
    def command(argv, cap=120): return owned.command(argv, childenv=env, cap=cap, stdout_only=True)[0]
    def cancel(_signum, _frame): best_effort(write_receipt, root.with_name(root.name + '.cancel-requested'), {'requested': True})
    for signum in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]: signal.signal(signum, cancel)
    try:
        deadline.arm()
        require(command(['git', '-C', str(REPO), 'rev-parse', 'HEAD']).decode().strip() == current)
        command(['git', '-C', str(REPO), 'diff', '--exit-code', 'HEAD'])
        require(command(['git', '-C', str(REPO), 'status', '--porcelain=v1']).strip() == b'')
        _, quiet = owned.command(['/usr/bin/pgrep', '-x', 'xcodebuild'], cap=3, accept_failure=True)
        require(quiet == 1)
        for name, digest in selection['sourceSHA256'].items():
            path = REPO / name
            require(path.resolve().is_relative_to(REPO) and hashlib.sha256(path.read_bytes()).hexdigest() == digest)
        if args.qualify_fixture:
            stage, operation = 'fixture', 'fixture-build-and-cli'
            qualify_fixture(root, args, owned.command)
            result = 0
            return result
        binary, fixture = fixture_artifact(args.fixture_receipt)
        require(qualify_ui_release(Path(fixture['artifactRoot'])),
            'Fixture compiler custody is not qualified')
        stage, operation = 'cache', 'cache-validation'
        require(hashlib.sha256(Path(args.gateway_pins).read_bytes()).hexdigest() == fixture['sourceSHA256']['gateway/Package.resolved'])
        gateway_receipt = gateway_copy(args.gateway_cache, args.gateway_pins, root / 'gateway-source-cache', REPO, command)
        public_ios = qualify_git_config(args.package_cache, Path(args.package_pins).read_bytes())
        pins, ios_receipt = copy_cache(args.package_cache, args.package_pins, root / 'package-cache', REPO, command)
        write_receipt(root / 'source.json', {'commit': current, 'selectors': list(SELECTION), 'fixtureBinarySHA256': fixture['binarySHA256'],
            'resourceSHA256': fixture['resourcesSHA256'], 'iosCache': ios_receipt, 'iosPublicConfiguration': public_ios,
            'gatewayCache': gateway_receipt, 'serviceDataRoot': str(service_root), 'fixtureTrackDurationSeconds': 12})
        def request(base, method, path, body=None, authority=None, json_response=True):
            return local_request(outbound, deadline, base, method, path, body, authority, json_response)
        stage, operation = 'media', 'media-generate'
        for name in ['music', 'navidrome']: (root / name).mkdir(mode=0o700)
        for index in range(3):
            command(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i',
                'sine=frequency=' + str(330 + index * 110) + ':duration=12', '-metadata',
                'title=Mixtape Fixture ' + chr(65 + index), '-metadata', 'artist=Synthetic Mixtape',
                '-metadata', 'album=Owned UI Fixture', '-b:a', '48k', str(root / 'music' / (str(index) + '.mp3'))])
        command(['python3', '-B', str(REPO / 'gateway/Tests/share-player/make-mixtape-media.py'), str(root / 'pending-material')])
        material_path = root / 'pending-material/material.json'; material = owned_json(material_path)
        stage, operation = 'service', 'service-start'
        navport, port = f.unused_ports(2); navbase = 'http://127.0.0.1:' + str(navport); backend = 'http://127.0.0.1:' + str(port)
        image = command(['docker', 'image', 'inspect', '--format', '{{.Id}}', args.navidrome_image]).decode().strip()
        require(re.fullmatch(r'sha256:[0-9a-f]{64}', image))
        owned.container_name = 'baton-mixtape-ui-' + secrets.token_hex(12); owned.receipt()
        owned.container_id = command(['docker', 'create', '--pull=never', '--name', owned.container_name,
            '-p', '127.0.0.1:' + str(navport) + ':4533', '-e', 'ND_LOGLEVEL=error',
            '-v', str(root / 'music') + ':/music:ro', '-v', str(root / 'navidrome') + ':/data', args.navidrome_image]).decode().strip()
        require(re.fullmatch(r'[0-9a-f]{64}', owned.container_id)); owned.receipt(); command(['docker', 'start', owned.container_id])
        for _ in range(60):
            try: request(navbase, 'GET', '/ping', json_response=False); break
            except (OSError, ValueError):
                if not outbound.qualified(): raise
                time.sleep(deadline.remaining(.5))
        else: raise ValueError('Synthetic catalog readiness refused')
        stage, operation = 'catalog', 'catalog-read'
        username, password = 'mixtape-ui-fixture', secrets.token_hex(24)
        request(navbase, 'POST', '/auth/createAdmin', {'username': username, 'password': password})
        def subsonic(endpoint, **values):
            salt = secrets.token_hex(8); query = dict(u=username, t=hashlib.md5((password + salt).encode()).hexdigest(),
                s=salt, v='1.16.1', f='json', c='mixtape-ui-fixture', **values)
            return request(navbase, 'GET', '/rest/' + endpoint + '?' + urlencode(query))['subsonic-response']
        subsonic('startScan')
        for _ in range(60):
            songs = subsonic('search3', query='', songCount=10, albumCount=0, artistCount=0).get('searchResult3', {}).get('song', [])
            if sorted(song.get('title') for song in songs) == ['Mixtape Fixture A', 'Mixtape Fixture B', 'Mixtape Fixture C']: break
            time.sleep(deadline.remaining(.5))
        else: raise ValueError('Exact synthetic catalog refused')
        require(all(song.get('duration') == 12 for song in songs))
        for song in songs: subsonic('star', id=song['id'])
        require(len(subsonic('getStarred2').get('starred2', {}).get('song', [])) == 3)
        capabilities = {'admin': secrets.token_urlsafe(32), 'operator': secrets.token_urlsafe(32)}
        capability_file = root / 'synthetic-capabilities.json'; write_receipt(capability_file, capabilities)
        with (root / 'service.log').open('xb') as output:
            service = owned.start([str(binary), str(service_root), str(port), str(capability_file)], output=output)
        for _ in range(60):
            require(owned.running(service))
            try: request(backend, 'GET', '/health', json_response=False); break
            except (OSError, ValueError):
                if not outbound.qualified(): raise
                time.sleep(deadline.remaining(.5))
        else: raise ValueError('Synthetic share readiness refused')
        proxy_token = secrets.token_urlsafe(32)
        proxy = MixtapeUIProxy(root, backend, proxy_token, deadline); proxy.start()
        pending_authority = secrets.token_urlsafe(32)
        pending = create_pending(material, backend, proxy.base,
            lambda method, path, body=None: request(backend, method, path, body, pending_authority))
        write_receipt(root / 'pending.json', {'invitation': pending})
        write_receipt(root / 'pending-evidence.json', {'materialSHA256': hashlib.sha256(material_path.read_bytes()).hexdigest(),
            'publicStatus': 'pending', 'createOnly': True, 'finalizationSent': False})
        stage, operation = 'simulator', 'simulator-start'
        owned.simulator_name = 'Baton Mixtape UI ' + secrets.token_hex(12); owned.receipt()
        owned.simulator = command(['xcrun', 'simctl', 'create', owned.simulator_name,
            'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0']).decode().strip(); owned.receipt()
        command(['xcrun', 'simctl', 'boot', owned.simulator]); command(['xcrun', 'simctl', 'bootstatus', owned.simulator, '-b'])
        actions = MixtapeUIActions(root, owned.simulator, proxy.base, backend, owned.command, deadline,
            capabilities['admin'], capabilities['operator'], pending=pending)
        control_token = secrets.token_urlsafe(32); control = MixtapeUIControl(actions, control_token); control.start()
        variables = dict(MIXTAPE_COMPOSER_FLOW_TESTS='1', MIXTAPE_UI_WALKS='1', MIXTAPE_COMPOSER_BASE=proxy.base,
            MIXTAPE_COMPOSER_CONTROL_TOKEN=proxy_token, MIXTAPE_COMPOSER_NAV_URL=navbase,
            MIXTAPE_COMPOSER_NAV_USER=username, MIXTAPE_COMPOSER_NAV_SECRET=password,
            MIXTAPE_UI_CONTROL_URL=control.url, MIXTAPE_UI_CONTROL_TOKEN=control_token)
        previous = Path.cwd()
        try: os.chdir(REPO / 'ios'); command(['xcodegen', 'generate'])
        finally: os.chdir(previous)
        owned.snapshot_scheme(REPO / 'ios/BatonMobile.xcodeproj/xcshareddata/xcschemes/BatonMobile.xcscheme')
        destination = REPO / 'ios/BatonMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        destination.parent.mkdir(parents=True, exist_ok=True); destination.write_bytes(pins)
        common = ['-project', str(REPO / 'ios/BatonMobile.xcodeproj'), '-scheme', 'BatonMobile',
            '-destination', 'platform=iOS Simulator,id=' + owned.simulator, '-derivedDataPath', str(root / 'derived-data'),
            '-clonedSourcePackagesDirPath', str(root / 'package-cache'), '-disableAutomaticPackageResolution',
            '-onlyUsePackageVersionsFromResolvedFile', '-skipPackageUpdates']
        stage, operation = 'sdk', 'sdk-build'
        with (root / 'build.log').open('xb') as output:
            process = owned.start(['xcodebuild', 'build-for-testing', *common, '-resultBundlePath', str(root / 'build.xcresult')], output=output)
            owned.wait(process)
        write_receipt(root / 'build-exit.json', {'exitCode': process.returncode}); require(process.returncode == 0)
        runs = list((root / 'derived-data/Build/Products').glob('*.xctestrun')); require(len(runs) == 1)
        run = plistlib.loads(runs[0].read_bytes())
        targets = [t for c in run.get('TestConfigurations', []) for t in c['TestTargets']] if 'TestConfigurations' in run else [run['BatonMobileUITests']]
        targets = [t for t in targets if t.get('BlueprintName', 'BatonMobileUITests') == 'BatonMobileUITests']; require(len(targets) == 1)
        targets[0].setdefault('EnvironmentVariables', {}).update(variables)
        private_run = runs[0].with_name('MixtapeUIWalks.xctestrun'); private_run.write_bytes(plistlib.dumps(run)); private_run.chmod(0o600)
        stage, operation = 'ui', 'ui-tests'
        def service_tick():
            proxy.serve_one(); control.serve_one()
        with (root / 'tests.log').open('xb') as output:
            process = owned.start(['xcodebuild', 'test-without-building', '-xctestrun', str(private_run),
                '-destination', 'platform=iOS Simulator,id=' + owned.simulator,
                *['-only-testing:BatonMobileUITests/' + case for case in selection['selectors']],
                '-collect-test-diagnostics', 'never', '-resultBundlePath', str(root / 'walks.xcresult')], output=output)
            owned.wait(process, on_tick=service_tick)
        write_receipt(root / 'tests-exit.json', {'exitCode': process.returncode})
        stage, operation = 'ui', 'result-read'
        counts = json.loads(command(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(root / 'walks.xcresult')]))
        tree = json.loads(command(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(root / 'walks.xcresult')]))
        write_receipt(root / 'counts.json', counts); write_receipt(root / 'test-tree.json', tree)
        require(process.returncode == 0 and counts['totalTestCount'] == counts['passedTests'] == 2
            and counts['failedTests'] == counts['skippedTests'] == 0
            and set(actual_cases(tree)) == {('BatonMobileUITests', name, 'Passed') for name in SELECTION})
        result = 0
    except BaseException as error:
        failure = (error, stage, operation)
    finally:
        finish(root, deadline, owned, [proxy, control], result, current, failure, outbound, scope)
    try: print('Baton two-walk UI receipt:', root / 'result.json')
    except BaseException: hold_original_parent(root, deadline)
    return result


if __name__ == '__main__': sys.exit(main())
