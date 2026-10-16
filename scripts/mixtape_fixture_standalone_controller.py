"""Bound standalone fixture compiler/resources/refusals; no native UI branch."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import sys

ROOT = Path(__file__).resolve().parent
INPUTS = json.loads((ROOT / 'fixture-inputs.json').read_bytes())
REPO = Path(INPUTS['repository'])
sys.path.insert(0, str(REPO / 'scripts'))
spec = importlib.util.spec_from_file_location('accepted_mixtape_fixture', REPO / 'scripts/probe-mixtape-ui-walks.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)
FINAL_EXIT = os._exit


def preflight():
    ui.require(set(INPUTS) == {'repository', 'source', 'selectionManifest', 'gatewayCache', 'gatewayPins'})
    ui.require(re.fullmatch(r'[0-9a-f]{40}', INPUTS['source']))
    ui.require(ROOT.parent == Path('/private/tmp') and ROOT == ROOT.resolve())
    ui.require(set(p.name for p in ROOT.iterdir()) ==
        {'controller.py', 'fixture-inputs.json', 'command-binding.json', 'compiler-attempt.lock'})
    ui.require((ROOT / 'controller.py').read_bytes() ==
        (REPO / 'scripts/mixtape_fixture_standalone_controller.py').read_bytes())
    ui.require(Path(INPUTS['gatewayPins']) == REPO / 'gateway/Package.resolved')
    manifest = ui.selector_manifest(INPUTS['selectionManifest'])
    required = {'scripts/mixtape_fixture_standalone_controller.py',
        'ios/scripts/run-app-attest-offline-compiler.py', 'scripts/prepare-mixtape-fixture-standalone.py'}
    ui.require(required.issubset(manifest['sourceSHA256']))
    for name, digest in manifest['sourceSHA256'].items():
        path = REPO / name
        ui.require(path == path.resolve() and path.is_relative_to(REPO)
            and hashlib.sha256(path.read_bytes()).hexdigest() == digest)
    ui.qualify_git_config(INPUTS['gatewayCache'], Path(INPUTS['gatewayPins']).read_bytes())


class FixtureCommands:
    """Exact public process boundary; rejected requests never reach child birth."""
    def __init__(self, owned, root, repo, cache, pins):
        self.owned, self.root, self.repo = owned, Path(root), Path(repo)
        cache = Path(cache)
        indexed = {p['identity']: p for p in json.loads(Path(pins).read_bytes())['pins']}
        state = json.loads((cache / 'workspace-state.json').read_bytes())
        remote = {d['packageRef']['identity']: d for d in state['object']['dependencies']
            if d['packageRef']['kind'] == 'remoteSourceControl'}
        ui.require(set(indexed) == set(remote) == {'swift-asn1', 'swift-certificates', 'swift-crypto'})
        self.requests = [(['git', '-C', str(repo), 'rev-parse', 'HEAD'], 120, False),
            (['git', '-C', str(repo), 'diff', '--exit-code', 'HEAD'], 120, False),
            (['git', '-C', str(repo), 'status', '--porcelain=v1'], 120, False)]
        for identity in ['swift-asn1', 'swift-certificates', 'swift-crypto']:
            path = (cache / 'checkouts' / remote[identity]['subpath']).resolve()
            ui.require(path.is_relative_to(cache / 'checkouts'))
            revision = indexed[identity]['state']['revision']
            for suffix in [['rev-parse', 'HEAD'], ['diff', '--exit-code', 'HEAD'],
                ['status', '--porcelain=v1', '--untracked-files=all', '--ignored=matching'],
                ['show', revision + ':Package.swift']]:
                self.requests.append((['git', '-C', str(path), *suffix], 120, False))
        common = ['swift', 'build', '--package-path', str(repo / 'gateway'),
            '--scratch-path', str(root / 'gateway-build'), '--cache-path', str(root / 'gateway-cache'),
            '--disable-automatic-resolution', '--skip-update']
        self.requests.extend([([*common, '--product', 'baton-mixtape-ui-fixture'], 600, False),
            ([*common, '--show-bin-path'], 120, False)])
        capability = str(root / 'unsafe-synthetic-capabilities.json')
        self.cli = [[], [str(root / 'nested-service'), '49171', capability],
            [str(root.with_name(root.name + '-cli-refusal')), '80', capability],
            [str(root.with_name(root.name + '-cli-refusal')), '49171', capability]]
        self.index = 0
        self.binary = None

    def __call__(self, argv, cap=120, accept_failure=False):
        argv = list(argv)
        if self.index < len(self.requests):
            expected, budget, failure = self.requests[self.index]
            ui.require(argv == expected and cap == budget and accept_failure is failure)
        else:
            index = self.index - len(self.requests)
            ui.require(index < 4 and cap == 5 and accept_failure is True)
            binary = Path(argv[0])
            ui.require(binary == binary.resolve() and binary.is_relative_to(self.root / 'gateway-build')
                and binary.name == 'baton-mixtape-ui-fixture' and argv[1:] == self.cli[index])
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            if self.binary is None: self.binary = (binary, digest)
            ui.require(self.binary == (binary, digest))
        # Typed requests use exact installed system programs, never ambient PATH tools.
        executed = [('/usr/bin/' + argv[0]) if argv[0] in {'git', 'swift'} else argv[0], *argv[1:]]
        if argv[0] == 'swift':
            # Current installed help confirms these explicit private directories
            # and credential-store refusals. Do not repurpose an account HOME.
            executed += ['--config-path', str(self.root / 'gateway-config'),
                '--security-path', str(self.root / 'gateway-security'),
                '--disable-netrc', '--disable-keychain']
        output, rc = self.owned.command(executed, cap=cap, accept_failure=accept_failure)
        self.index += 1
        return output, rc

    def complete(self):
        return self.index == len(self.requests) + 4


def run():
    # All setup before arm is covered by the launcher's original-parent hold.
    os.umask(0o077)
    deadline = ui.Deadline()
    env = dict(ui.offline_environment({'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
        'TMPDIR': str(ROOT), 'LANG': 'en_US.UTF-8'}),
        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_OPTIONAL_LOCKS='0')
    owned = ui.ReservedOwnedFixture(ROOT, env, deadline)
    command = FixtureCommands(owned, ROOT, REPO, INPUTS['gatewayCache'], INPUTS['gatewayPins'])
    def cancel(_signum, _frame):
        ui.best_effort(ui.write_receipt, ROOT.with_name(ROOT.name + '.cancel-requested'), {'requested': True})
    for signum in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]: signal.signal(signum, cancel)
    result, failure = 1, None
    try:
        deadline.arm()
        ui.require(command(['git', '-C', str(REPO), 'rev-parse', 'HEAD'])[0].decode().strip() == INPUTS['source'])
        command(['git', '-C', str(REPO), 'diff', '--exit-code', 'HEAD'])
        ui.require(command(['git', '-C', str(REPO), 'status', '--porcelain=v1'])[0].strip() == b'')
        args = type('FixtureInputs', (), {'gateway_cache': INPUTS['gatewayCache'], 'gateway_pins': INPUTS['gatewayPins']})()
        ui.qualify_fixture(ROOT, args, command)
        ui.require(command.complete())
        result = 0
    except BaseException as error:
        failure = (error, 'unknown', 'command')
    finally:
        ui.finish(ROOT, deadline, owned, [None, None], result, INPUTS['source'], failure, None,
            'Standalone fixture compile/resources/four refusals only; no app/simulator/GUI/phone/service')
    # A lock release is never substituted for the actual accepted cleanup receipts.
    try:
        ui.require(ui.qualify_ui_release(ROOT))
    except BaseException:
        ui.hold_original_parent(ROOT, deadline)
    FINAL_EXIT(result)
