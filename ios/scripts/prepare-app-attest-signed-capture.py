#!/usr/bin/env python3
"""Source-only preparation for the fixed signed capture adapter; never launch SDKs.

The accepted private specification supplies existing manual signing selections.
Its unused ordinary targets/packages are omitted from a new private specification.
No profile, keychain, provider, device or credential is read or changed.
"""
import hashlib
import json
import os
from pathlib import Path
import stat

REPO = Path('/private/tmp/baton-tbx-8711-fresh-capture')
ROOT = Path('/private/tmp/baton-tbx8711-fresh-capture-20261008-2')
TEMPLATE = Path('/private/tmp/baton-tbx8711-minimal-host-20261005/spec/physical-probe-spec.json')
TEMPLATE_SHA = '94b29835b1a35a4a68463d2c78241c8c2c364b7b4c77f53a5f597ce89c631b0a'
CLOSURE = {
    'ios/Tests/BatonAppAttestPhysicalHost/AppAttestPhysicalHost.swift': 'c62cb6f918dccd88dc0a397b400a8742ec713420f95fb14e2aebaf65826e0788',
    'ios/Tests/BatonAppAttestPhysicalHost/PhysicalAttestProbeStorage.swift': '09e9e245a243b6c273815567775a90f3853fa191ccda8b2071da54f6e6a07525',
    'ios/Tests/BatonAppAttestPhysicalTests/AppAttestIssuancePhysicalTests.swift': '65c585d9c369983d35cade6c1ff4cdc73c704618e792b405d8a5d0b70af5a8cd',
    'ios/scripts/prepare-app-attest-physical-probe.py': 'b86cf00e6fc88152f52c7e98c3996196a20f07f894640c2f2d459631af200bf6',
    'ios/BatonMobile.Debug.entitlements': '6a7ae3a9a215a0b2c10b8f4307b978b373549b3493f00b966b10fc36c7b903a2',
    'ios/Sources/BatonWidgets/BatonWidgets.swift': 'c908ac43bf0401ed26bdc2cbf781399680fa4e6f58015767fc573ba6981c522d',
    'ios/Sources/Shared/NowPlayingActivityAttributes.swift': '2477953a343ad3b2c70396226a353fc1e8c7beaacfc50931538bbc31860d88a7',
    'ios/Sources/Shared/TransportIntents.swift': 'cf07866c8c4dc5f2e6d1da110045ddeea0b534b8e8f71d7cddf2d59bfadf8456',
    'ios/Sources/Shared/WidgetFreshness.swift': 'dd8a6520f0a0e9a4e7d6b5143b4278d76892ca7e4ac4b81701d93c07892bd841',
}


def digest(path):
    assert path == path.resolve() and path.is_file() and not path.is_symlink()
    assert path.stat().st_uid == os.getuid()
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, data):
    with path.open('xb') as f:
        f.write(data)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def prepare(execution_commit):
    import re
    assert re.fullmatch(r'[0-9a-f]{40}', execution_commit)
    assert digest(TEMPLATE) == TEMPLATE_SHA
    assert stat.S_IMODE(TEMPLATE.stat().st_mode) == 0o600
    for name, expected in CLOSURE.items():
        assert digest(REPO / name) == expected
    os.umask(0o077)
    ROOT.mkdir(mode=0o700)  # An existing attempt is never overwritten.
    spec = json.loads(TEMPLATE.read_bytes())
    names = ['BatonWidgets', 'BatonAppAttestPhysicalHost', 'BatonAppAttestPhysicalTests']
    spec['targets'] = {name: spec['targets'][name] for name in names}
    spec['schemes'] = {'BatonAppAttestPhysical': spec['schemes']['BatonAppAttestPhysical']}
    spec['packages'] = {}  # None of the three selected targets declares a package.
    spec['options'].pop('preGenCommand', None)  # Unused ordinary help-resource sync.
    allowed = {'BATON_SOURCE_COMMIT', 'CODE_SIGN_STYLE', 'CURRENT_PROJECT_VERSION',
               'DEVELOPMENT_TEAM', 'GENERATE_INFOPLIST_FILE', 'MARKETING_VERSION',
               'SWIFT_STRICT_CONCURRENCY', 'SWIFT_TREAT_WARNINGS_AS_ERRORS', 'SWIFT_VERSION'}
    spec['settings']['base'] = {k: v for k, v in spec['settings']['base'].items() if k in allowed}
    # The two plist outputs belong to this attempt, not the source checkout.
    spec['targets']['BatonAppAttestPhysicalHost']['info']['path'] = str(ROOT / 'PhysicalProbeInfo.plist')
    widget = spec['targets']['BatonWidgets']
    widget['info']['path'] = str(ROOT / 'WidgetInfo.plist')
    widget['entitlements']['path'] = str(ROOT / 'Widget.entitlements')
    spec['targets']['BatonAppAttestPhysicalHost']['settings']['configs']['Debug'][
        'CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]'] = str(REPO / 'ios/BatonMobile.Debug.entitlements')
    build_namespace = 'probe-attest-minimal-20261005-8711'
    assert spec['schemes']['BatonAppAttestPhysical']['test']['environmentVariables']['baton.defaultsSuite'] == build_namespace
    data = (json.dumps(spec, sort_keys=True, indent=2) + '\n').encode()
    write(ROOT / 'physical-probe-spec.json', data)
    (ROOT / 'package-cache').mkdir(mode=0o700)  # No dependencies; private Xcode cache only.
    paths = [*CLOSURE, 'ios/BatonMobile.Debug.entitlements',
        'ios/scripts/prepare-app-attest-signed-capture.py',
        'ios/scripts/run-app-attest-signed-capture-build.py',
        'ios/scripts/build-app-attest-signed-capture.sh',
        'ios/scripts/app_attest_owned_controller.py',
        'scripts/gate-lock.sh', 'scripts/probe-lib.sh',
        'scripts/incoming_fixture_lifecycle.py', 'scripts/mixtape_owned_supervision.py',
        'scripts/mixtape_owned_lifecycle.py']
    paths += [str(p.relative_to(REPO)) for folder in ['ios/Sources/BatonWidgets', 'ios/Sources/Shared']
              for p in sorted((REPO / folder).rglob('*')) if p.is_file()]
    pins = {str(REPO / name): digest(REPO / name) for name in paths}
    for path in [TEMPLATE, ROOT / 'physical-probe-spec.json',
                 REPO / 'docs/evidence/tbx-8711/cached-compiler-preparation/controller.py',
                 Path('/private/tmp/baton-tbx-8680-physical/scripts/incoming_fixture_packages.py')]:
        pins[str(path)] = digest(path)
    manifest = {'schemaVersion': 1, 'executionSourceCommit': execution_commit,
        'namespace': 'probe-attest-2450a4e63e0e426eb1c3f76b43cee77a',
        'buildNamespace': build_namespace,
        'captureCompatibilityTag': '60368d111db2c58285ffb93beef5f85093ee8257',
        'inputSHA256': pins}
    write(ROOT / 'input-pins.json', (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode())
    return {'prepared': True, 'nativeActions': 0, 'inputFiles': len(pins),
            'generatedSpecSHA256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--execution-commit', required=True)
    args = p.parse_args()
    try:
        print(json.dumps(prepare(args.execution_commit)))
    except Exception as error:
        print(json.dumps({'prepared': False, 'errorClass': type(error).__name__, 'privateDetailsWithheld': True}))
        raise SystemExit(1)
