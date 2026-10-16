#!/usr/bin/env python3
"""Prepare a private same-App-ID probe; never build, install, launch or contact a service."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat

HOST = 'BatonBackgroundUploadPhysicalHost'
SCHEME = 'BatonBackgroundUploadPhysical'
TESTS = 'BatonBackgroundUploadFixtureTests'
ORIGIN = 'https://dev.batonmusic.app'


def prepare(template, destination, suite, origin=ORIGIN):
    if not re.fullmatch(r'probe-upload-[A-Za-z0-9._-]{1,40}', suite) or origin != ORIGIN:
        raise ValueError('Exact probe namespace and approved HTTPS origin required')
    info = template.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Owned regular private template required')
    spec = json.loads(template.read_text())
    targets = spec['targets']
    for name, bundle in [('BatonMobile', 'io.tonebox.baton'), ('BatonWidgets', 'io.tonebox.baton.widgets')]:
        settings = targets[name]['settings']
        if settings['base']['PRODUCT_BUNDLE_IDENTIFIER'] != bundle:
            raise ValueError('Unexpected signing target')
        debug = settings['configs']['Debug']
        if debug.get('CODE_SIGN_STYLE') != 'Manual' or not debug.get('PROVISIONING_PROFILE_SPECIFIER'):
            raise ValueError('Approved per-target development profile required')
    if HOST in targets or TESTS in targets or SCHEME in spec['schemes']:
        raise ValueError('Probe already exists')
    destination.mkdir(mode=0o700)  # Never overwrite a previous preparation.
    fixture = Path(__file__).resolve().parents[1] / 'Tests/BatonMobileTests/BackgroundShareUploadTests.swift'
    source = fixture.read_text()
    if source.count('@testable import BatonMobile') != 1:
        raise ValueError('Unexpected fixture import')
    test_source = source.replace('@testable import BatonMobile', '@testable import ' + HOST)
    test_path = destination / 'BackgroundShareUploadTests.swift'
    os.umask(0o077)
    with test_path.open('x') as stream:
        stream.write(test_source)
    targets[HOST] = {
        'type': 'application', 'platform': 'iOS',
        'sources': [{'path': 'Tests/BatonBackgroundUploadPhysicalHost'},
                    {'path': '../Shared/BackgroundShareUploadEngine.swift'},
                    {'path': '../Shared/BackgroundShareUploadStore.swift'},
                    {'path': '../Shared/SongShareAppAttest.swift'}],
        'dependencies': [{'target': 'BatonWidgets'}, {'package': 'BatonShareKit'}, {'package': 'BatonSubsonicKit'}],
        'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'io.tonebox.baton',
                             'PRODUCT_NAME': 'BatonBackgroundUploadProbe', 'PRODUCT_MODULE_NAME': HOST,
                             'GENERATE_INFOPLIST_FILE': True, 'INFOPLIST_KEY_UILaunchScreen_Generation': True},
                     'configs': {'Debug': copy.deepcopy(targets['BatonMobile']['settings']['configs']['Debug'])}},
        'info': {'path': str(destination / 'BackgroundUploadProbeInfo.plist'), 'properties': {
            'CFBundleDisplayName': 'Baton Upload Probe',
            'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
            'BatonSourceCommit': '$(BATON_SOURCE_COMMIT)', 'BatonBackgroundUploadProbe': True,
            'BatonBackgroundUploadProbeSuite': suite,
            'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
                'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                    'UISceneConfigurationName': 'Background Upload Probe',
                    'UISceneDelegateClassName': '$(PRODUCT_MODULE_NAME).BackgroundUploadProbeScene'}]}},
        }},
    }
    target = copy.deepcopy(targets['BatonMobileTests'])
    # The private absolute path is outside ios. XcodeGen 2.46.0 loops in its
    # parent-group traversal for that source; keep this file as a root group.
    target['sources'] = [{'path': str(test_path), 'createIntermediateGroups': False}]
    target['dependencies'] = [{'target': HOST}]
    target['settings'] = {'base': {'GENERATE_INFOPLIST_FILE': True, 'BUNDLE_LOADER': '$(TEST_HOST)',
        'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/BatonBackgroundUploadProbe.app/BatonBackgroundUploadProbe',
        'PRODUCT_BUNDLE_IDENTIFIER': 'io.tonebox.baton.upload-fixture-tests'}}
    targets[TESTS] = target
    spec['schemes'][SCHEME] = {
        'build': {'targets': {HOST: 'all', TESTS: ['test']}},
        'test': {'config': 'Debug', 'targets': [TESTS]},
    }
    data = json.dumps(spec, sort_keys=True, indent=2).encode()
    path = destination / 'background-upload-spec.json'
    with path.open('xb') as stream:
        stream.write(data)
    return {'spec': str(path), 'specSHA256': hashlib.sha256(data).hexdigest(),
            'fixtureInputSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
            'fixtureCopySHA256': hashlib.sha256(test_source.encode()).hexdigest(),
            'scheme': SCHEME, 'sessionIDs': ['io.tonebox.baton.probe.share-uploads.' + suite + '.' + name for name in ['success', 'failure']],
            'origin': origin, 'installed': False, 'launched': False, 'networkRequests': 0}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--suite', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.template, args.destination, args.suite), indent=2))
    except Exception as error:
        print(json.dumps({'result': 'REFUSED', 'errorClass': type(error).__name__, 'privateDetailsWithheld': True}))
        raise SystemExit(1)
