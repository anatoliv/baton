#!/usr/bin/env python3
"""Opt-in, bounded fresh iPhone simulator + localhost-only incoming-share acceptance."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import plistlib
import re
import signal
import subprocess
import struct
import sys
import stat
import uuid
import time
from urllib.parse import urlencode
from incoming_fixture_lifecycle import FixtureTimeout, write_receipt
from mixtape_owned_lifecycle import CustodyDeadline as Deadline, ReservedOwnedFixture as OwnedFixture, cleanup_qualified, best_effort, retain_custody
from incoming_fixture_packages import copy_cache, offline_environment
from incoming_fixture_delivery import DeliveryControl

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("fixture", REPO / "scripts/probe-share-fixture.py")
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


MATCH_RECORDING = "83d9ea58-1a5b-4b02-8dc3-2955c705e326"
OTHER_RECORDING = "46ee9cc6-3f8b-4d12-8b1c-9510663b7fbc"

def verify_simulator_entitlements(entitlements):
    identifier=entitlements.get('application-identifier')
    suffix='.io.tonebox.baton'
    f.require(isinstance(identifier,str) and identifier.endswith(suffix) and
        bool(identifier[:-len(suffix)]) and '.' not in identifier[:-len(suffix)],
        'Owned simulator app lacks its signed application-identifier; refusing UI tests')
    return {'applicationIdentifier':identifier,'entitlementKeys':sorted(entitlements)}

def simulator_entitlement_section(binary):
    # Xcode places simulator entitlements in the executable's Mach-O section,
    # while its normal ad-hoc code-signature entitlement dictionary is empty.
    f.require(32<=len(binary)<=32*1024*1024,'Invalid bounded simulator executable')
    magic,cpu,_,_,count,size,_,_=struct.unpack_from('<IiiIIIII',binary)
    f.require(magic==0xfeedfacf and cpu==0x100000c and count<=4096 and
        size<=len(binary)-32,'Expected bounded thin arm64 simulator Mach-O')
    cursor=32; end=32+size; found=[]
    for _ in range(count):
        f.require(cursor+8<=end,'Truncated Mach-O load command')
        kind,length=struct.unpack_from('<II',binary,cursor)
        f.require(length>=8 and cursor+length<=end,'Invalid Mach-O load command size')
        if kind==0x19:
            f.require(length>=72,'Truncated Mach-O segment')
            sections=struct.unpack_from('<I',binary,cursor+64)[0]
            f.require(sections<=1024 and 72+sections*80<=length,'Invalid Mach-O section count')
            for index in range(sections):
                name,segment,_,section_size,offset,*_=struct.unpack_from('<16s16sQQIIIIIIII',binary,cursor+72+index*80)
                if name.rstrip(b'\0')==b'__entitlements' and segment.rstrip(b'\0')==b'__TEXT':
                    f.require(0<section_size<=65536 and offset<=len(binary)-section_size,
                        'Invalid simulator entitlement section bounds')
                    found.append(binary[offset:offset+section_size].rstrip(b'\0'))
        cursor+=length
    f.require(cursor==end and len(found)==1,'Expected one simulator entitlement section')
    return found[0]

def verify_native_process_check(returncode):
    f.require(returncode==1, 'Active xcodebuild; native fixture refused' if returncode==0 else
        'Native process check unavailable; fixture refused')

def verify_no_package_fetch(log):
    with Path(log).open(errors='replace') as stream:
        for line in stream:
            f.require(not re.match(r'\s*(Fetching from|Downloading|Cloning|Updating from)\b',line),
                'Unexpected package fetch/download activity; fixture refused')

def verify_loopback_listener(output, pid, port):
    # lsof machine fields are independent of column layout and of unrelated
    # mount warnings merged from stderr. Require the exact process, one literal
    # IPv4 socket and LISTEN state; wildcards/additional sockets remain errors.
    fields=output.splitlines()
    processes=[line[1:] for line in fields if line.startswith('p')]
    listeners=[line[1:] for line in fields if line.startswith('n')]
    states=[line for line in fields if line.startswith('TST=')]
    f.require(processes==[str(pid)] and listeners==['127.0.0.1:'+str(port)] and states==['TST=LISTEN'],
        'Share service listener is not exact IPv4 loopback')
    return dict(pid=pid,address=listeners[0],state='LISTEN')

def validate_matching_catalog(songs):
    identities=[song for song in songs if song.get('title')=='Identity Different Title']
    decoys=[song for song in songs if song.get('title')=='Incoming Fixture A']
    copies=[song for song in songs if song.get('title')=='Incoming Fixture B']
    f.require(len(identities)==1 and identities[0].get('musicBrainzId','').lower()==MATCH_RECORDING,
        'Synthetic identity track must retain its recording tag')
    f.require(len(decoys)==1 and decoys[0].get('musicBrainzId','').lower()==OTHER_RECORDING,
        'Synthetic same-text decoy must have a different known recording')
    f.require(len(copies)==2 and len({song['id'] for song in copies})==2 and
        {song.get('album') for song in copies}=={'Fallback Copy One','Fallback Copy Two'} and
        all(not song.get('musicBrainzId') for song in copies),
        'Synthetic title/artist copies must remain distinct and untagged')
    return dict(identitySongID=identities[0]['id'],decoySongID=decoys[0]['id'],fallbackSongIDs=[song['id'] for song in copies])


def wrapper_output(value):
    # The probe-owning wrapper creates this empty directory before driver birth,
    # so it has an exact custody identity even if the driver dies during setup.
    root=Path(value)
    attrs=root.lstat()
    f.require(root==root.resolve() and root.parent==Path('/private/tmp') and
        root.name.startswith('baton-incoming-ui-') and stat.S_ISDIR(attrs.st_mode) and
        attrs.st_uid==os.getuid() and stat.S_IMODE(attrs.st_mode)==0o700 and
        not any(root.iterdir()), 'Canonical private empty wrapper output required')
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='Explicitly create/start owned fixtures and native UI; reserve the native slot first')
    parser.add_argument('--share-bin', required=True)
    parser.add_argument('--share-bin-sha256', help='Exact reviewed retained service SHA-256')
    parser.add_argument('--package-cache', help='Read-only retained gate SourcePackages; automated path requires it')
    parser.add_argument('--package-pins', help='Exact retained gate Package.resolved; automated path requires it')
    parser.add_argument('--navidrome-image', default='deluan/navidrome:latest')
    parser.add_argument('--manual-app', help='Exact retained simulator Debug app; manual CUA path, no Xcode build')
    parser.add_argument('--device-type', default='com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro')
    parser.add_argument('--runtime', default='com.apple.CoreSimulator.SimRuntime.iOS-27-0')
    parser.add_argument("--only-test", action="append", choices=[
        "testDraftSupersessionBackgroundAndPlaybackReaction",
        "testFindMyLibraryPrefersRecordingAndKeepsTextCopiesAmbiguous",
        "testIncomingAboveSetupCoverPreservesTypedServer",
        "testSettingsNestedHelpAndAlertPreserveUnderlyingState"],
        help="Run only named existing incoming cases; omission retains the four-case acceptance")
    args = parser.parse_args()
    selected = list(dict.fromkeys(args.only_test or []))
    expected_count = len(selected) or 4
    if not args.run:
        print('Prepared only. --run requires a reserved native/audio window; nothing started.')
        return 0
    owner = Path('/tmp/baton-probe.lock/owner').read_text().split()[0]
    f.require(owner == str(os.getppid()), 'Use the lock-owning probe-incoming-share-flow.sh wrapper')
    process_check=subprocess.run(['/usr/bin/pgrep','-x','xcodebuild'],stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,timeout=3)
    verify_native_process_check(process_check.returncode)
    binary = Path(args.share_bin).resolve()
    f.require(args.share_bin_sha256 and binary.is_file() and
        hashlib.sha256(binary.read_bytes()).hexdigest()==args.share_bin_sha256, 'Reviewed service SHA-256 mismatch')
    f.require(args.manual_app or (args.package_cache and args.package_pins), 'Automated run requires pinned offline package cache')
    os.umask(0o077)
    root = wrapper_output(os.environ.get('BATON_INCOMING_OUTPUT',''))
    deadline = Deadline()
    env = f.clean_environment(root)
    fixture = OwnedFixture(root, env, deadline)
    deadline.arm()
    result = 1
    delivery = None
    def remaining():
        if not deadline.cleaning and fixture.cancellation_requested(): raise KeyboardInterrupt()
        return deadline.remaining()
    def command(argv, childenv=None):
        return fixture.command(argv, childenv)[0]
    def cache_command(argv): return fixture.command(argv, stdout_only=True)[0]
    def local_request(url, body=None):
        from urllib.parse import urlsplit
        from urllib.request import Request
        parts=urlsplit(url)
        f.require(parts.scheme=='http' and parts.hostname=='127.0.0.1' and parts.port and not parts.username and not parts.password, 'Literal local fixture URL required')
        data=json.dumps(body).encode() if body is not None else None
        headers={'Content-Type':'application/json'} if data is not None else {}
        with f.OPENER.open(Request(url,data=data,headers=headers),timeout=deadline.remaining(5)) as response:
            data=response.read(512_001)
            f.require(len(data)<=512_000,'Local fixture response exceeded bound')
            remaining()
            return data
    def await_http(url, child=None):
        f.require(url.startswith('http://127.0.0.1:'), 'Local readiness URL required')
        for _ in range(60):
            f.require(child is None or fixture.running(child), 'Owned local service exited')
            try:
                return local_request(url)
            except f.FixtureFailure: raise
            except Exception: time.sleep(min(.5, remaining()))
        raise f.FixtureFailure('Owned local fixture did not become ready')
    def stop(signum, frame):
        best_effort(write_receipt,root.with_name(root.name+'.cancel-requested'), {'requested':True})
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): signal.signal(sig, stop)
    print('Private incoming fixture evidence: ' + str(root), flush=True)
    try:
        pin = command(['git','-C',str(REPO),'rev-parse','HEAD']).decode().strip()
        f.save_json(root/'source.json', {'sourceCommit':pin,'reviewedProductCommit':pin,
          'serviceSHA256':args.share_bin_sha256,'serviceBinary':str(binary),
          'scope':'reviewed combined native source plus test/fixture additions; no owner credentials or production links'})
        package_cache=root/'package-cache'
        if not args.manual_app:
            pins_bytes, cache_receipt=copy_cache(args.package_cache,args.package_pins,package_cache,REPO,cache_command)
            write_receipt(root/'package-cache-qualification.json',cache_receipt)
        for name in ('music','navidrome','shares'): (root/name).mkdir(mode=0o700)
        command(['ffmpeg','-nostdin','-loglevel','error','-f','lavfi','-i','sine=frequency=330:duration=40',
            '-metadata','title=Synthetic Incoming Library Song','-metadata','artist=Synthetic Receiver Probe',
            '-metadata','album=Isolated Fixtures','-b:a','48k',str(root/'music/song.mp3')])
        # FLAC's Vorbis MUSICBRAINZ_TRACKID preserves the recording identity.
        # Two untagged, differently albumed MP3 copies exercise ambiguity.
        for filename,title,album,recording in [
            ('identity.flac','Identity Different Title','Identity Match',MATCH_RECORDING),
            ('decoy.flac','Incoming Fixture A','Different Recording',OTHER_RECORDING),
            ('fallback-one.mp3','Incoming Fixture B','Fallback Copy One',None),
            ('fallback-two.mp3','Incoming Fixture B','Fallback Copy Two',None)]:
            tags=['-metadata','title='+title,'-metadata','artist=Synthetic Receiver Probe','-metadata','album='+album]
            if recording: tags += ['-metadata','MUSICBRAINZ_TRACKID='+recording]
            encoding=['-c:a','flac'] if recording else ['-b:a','48k']
            command(['ffmpeg','-nostdin','-loglevel','error','-f','lavfi','-i','sine=frequency=440:duration=40',
                *tags,*encoding,str(root/'music'/filename)])
        navport, shareport = f.unused_ports(2)
        navbase, sharebase = 'http://127.0.0.1:'+str(navport), 'http://127.0.0.1:'+str(shareport)
        command(['docker','image','inspect',args.navidrome_image])
        fixture.container_name = 'baton-incoming-ui-' + secrets.token_hex(12)
        fixture.receipt()
        created_container = command(['docker','create','--pull=never','--name',fixture.container_name,
            '-p','127.0.0.1:'+str(navport)+':4533','-e','ND_LOGLEVEL=error',
            '-v',str(root/'music')+':/music:ro','-v',str(root/'navidrome')+':/data',args.navidrome_image]).decode().strip()
        f.require(len(created_container)==64 and all(c in '0123456789abcdef' for c in created_container), 'Invalid owned container ID')
        fixture.container_id=created_container
        fixture.receipt()
        command(['docker','start',fixture.container_id]); await_http(navbase+'/ping')
        user, password = 'incoming-probe', secrets.token_hex(24)
        local_request(navbase+'/auth/createAdmin', {'username':user,'password':password})
        def subsonic(endpoint, **values):
            salt = secrets.token_hex(8)
            query = dict(u=user,t=hashlib.md5((password+salt).encode()).hexdigest(),s=salt,v='1.16.1',f='json',c='incoming-probe',**values)
            return json.loads(local_request(navbase+'/rest/'+endpoint+'?'+urlencode(query)))['subsonic-response']
        subsonic('startScan')
        for _ in range(60):
            remaining()
            if subsonic('search3',query='Synthetic Incoming',songCount=2).get('searchResult3',{}).get('song'): break
            time.sleep(min(.5,remaining()))
        else: raise f.FixtureFailure('Synthetic local song did not index')
        for _ in range(60):
            catalog=subsonic('search3',query='',songCount=20,artistCount=0,albumCount=0).get('searchResult3',{}).get('song',[])
            write_receipt(root/'matching-catalog-readback.json',catalog)
            try:
                matching=validate_matching_catalog(catalog)
                write_receipt(root/'matching-catalog-qualification.json',matching)
                break
            except f.FixtureFailure: time.sleep(min(.5,remaining()))
        else: raise f.FixtureFailure('Synthetic matching catalog missing identity/distinct copies; private readback retained')
        f.require(binary.name=='baton-share' and binary.is_file(), 'Built local share binary missing')
        f.require((binary.parent/'baton-gateway_BatonShareServer.bundle').is_dir(), 'Share resource bundle missing')
        admin = secrets.token_hex(32)
        service = fixture.start([str(binary)], dict(env,BATON_SHARE_BIND='127.0.0.1',BATON_SHARE_DATA=str(root/'shares'),
          BATON_SHARE_PORT=str(shareport),BATON_SHARE_PUBLIC_BASE=sharebase,BATON_SHARE_BLOB_DELIVERY='direct',BATON_SHARE_ADMIN_TOKEN=admin))
        await_http(sharebase+'/health', service)
        listener = command(['lsof','-nP','-a','-p',str(service.pid),'-iTCP','-sTCP:LISTEN','-FpnT']).decode()
        (root/'listener-machine-readback.txt').write_text(listener)
        write_receipt(root/'listener-qualification.json',verify_loopback_listener(listener,service.pid,shareport))
        f.save_json(root/'seed.json',dict(shareBase=sharebase,song=str(root/'music/song.mp3'),output=str(root/'invitations.json'),recordingID=MATCH_RECORDING))
        command(['node',str(REPO/'scripts/seed-incoming-share-fixture.mjs'),str(root/'seed.json')],dict(env,INCOMING_FIXTURE_REMAINING_MS=str(int(remaining()*1000))))
        shares = json.loads((root/'invitations.json').read_text())['shares']
        variables = dict(INCOMING_SHARE_FLOW_TESTS='1',INCOMING_SHARE_BASE=sharebase,INCOMING_NAV_URL=navbase,
          INCOMING_NAV_USER=user,INCOMING_NAV_SECRET=password,INCOMING_SHARE_ADMIN=admin)
        fixture.simulator_name = 'Baton Incoming '+secrets.token_hex(12)
        fixture.receipt()
        simulator = command(['xcrun','simctl','create',fixture.simulator_name,args.device_type,args.runtime]).decode().strip()
        f.require(len(simulator)==36 and str(uuid.UUID(simulator)).lower()==simulator.lower(), 'Invalid owned simulator identity')
        fixture.simulator = simulator
        fixture.receipt()
        command(['xcrun','simctl','boot',simulator]); command(['xcrun','simctl','bootstatus',simulator,'-b'])
        f.save_json(root/'state.json',dict(simulator=simulator,servicePID=service.pid,container=fixture.container_id,shareBase=sharebase))
        if args.manual_app:
            app = Path(args.manual_app).resolve()
            f.require(app.name=='gate-built-Baton.app' and app.is_dir(), 'Manual path requires retained gate-built app')
            command(['xcrun','simctl','install',simulator,str(app)])
            childenv = dict(env, **{'SIMCTL_CHILD_baton.defaultsSuite':'io.tonebox.tests.incoming.'+secrets.token_hex(12),
              'SIMCTL_CHILD_baton.share.baseURL':sharebase,'SIMCTL_CHILD_baton.launchProbe':secrets.token_hex(16),
              'SIMCTL_CHILD_uitestServer':navbase,'SIMCTL_CHILD_uitestUser':user,'SIMCTL_CHILD_uitestSecret':password,
              'SIMCTL_CHILD_uitestBypassBiometrics':'1','SIMCTL_CHILD_uitestSkipSpeechAuthorization':'1'})
            command(['xcrun','simctl','launch',simulator,'io.tonebox.baton'],childenv)
            print('READY owned simulator '+simulator+'; private invitations.json contains local baton:// URLs. Ctrl-C cleans only this fixture.',flush=True)
            while True: remaining(); time.sleep(1)
        else:
            original_directory = Path.cwd()
            try:
                os.chdir(REPO/'ios'); command(['xcodegen','generate'])
            finally: os.chdir(original_directory)
            scheme = REPO/'ios/BatonMobile.xcodeproj/xcshareddata/xcschemes/BatonMobile.xcscheme'
            fixture.snapshot_scheme(scheme)
            pins_file=REPO/'ios/BatonMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
            pins_file.parent.mkdir(parents=True,exist_ok=True)
            pins_file.write_bytes(pins_bytes)
            common = ['-project',str(REPO/'ios/BatonMobile.xcodeproj'),'-scheme','BatonMobile','-destination','platform=iOS Simulator,id='+simulator,
              '-derivedDataPath',str(root/'derived-data'),'-clonedSourcePackagesDirPath',str(package_cache),
              '-disableAutomaticPackageResolution','-onlyUsePackageVersionsFromResolvedFile','-skipPackageUpdates']
            with (root/'build.log').open('wb') as log:
                process=fixture.start(['xcodebuild','build-for-testing',*common,
                    '-resultBundlePath',str(root/'build.xcresult')],childenv=offline_environment(env),output=log)
                rc=fixture.wait(process,on_tick=lambda:verify_no_package_fetch(root/'build.log'))
                verify_no_package_fetch(root/'build.log')
            f.save_json(root/'build-exit.json',{'exitCode':rc})
            if rc != 0: raise f.FixtureFailure('Owned UI test build failed; private log retained')
            # Preserve the ordinary Debug simulator signing context. An unsigned
            # app can launch but Security rejects its synthetic credentials (-34018).
            app=root/'derived-data/Build/Products/Debug-iphonesimulator/Baton.app'
            entitlement_dump=root/'simulator-app.entitlements'
            command(['/usr/bin/codesign','-d','--entitlements',str(entitlement_dump),'--xml',str(app)])
            f.require(entitlement_dump.is_file() and entitlement_dump.stat().st_size<=65536,
                'Owned simulator app has no bounded signed entitlement dump; refusing UI tests')
            entitlements=plistlib.loads(entitlement_dump.read_bytes())
            command(['/usr/bin/codesign','--verify','--strict',str(app)])
            executable=app/'Baton'
            f.require(executable.stat().st_size<=32*1024*1024,'Owned simulator executable exceeds bound')
            section=simulator_entitlement_section(executable.read_bytes())
            simulated=root/'derived-data/Build/Intermediates.noindex/BatonMobile.build/Debug-iphonesimulator/BatonMobile.build/Baton.app-Simulated.xcent'
            f.require(simulated.is_file() and simulated.stat().st_size<=65536 and
                simulated.read_bytes().rstrip(b'\0')==section,'Actual simulator entitlement section differs from Xcode output')
            qualification=verify_simulator_entitlements(plistlib.loads(section))
            qualification.update(codeSignatureVerified=True,codeSignatureEntitlementKeys=sorted(entitlements),
                source='actual __TEXT,__entitlements section',sectionSHA256=hashlib.sha256(section).hexdigest(),
                matchesGeneratedSimulatedEntitlements=True)
            f.save_json(root/'simulator-signing-qualification.json',qualification)
            original_runs=list((root/'derived-data/Build/Products').glob('*.xctestrun'))
            f.require(len(original_runs)==1,'Expected one generated xctestrun')
            original_run=original_runs[0]
            test_run=plistlib.loads(original_run.read_bytes())
            if 'TestConfigurations' in test_run:
                targets=[target for configuration in test_run['TestConfigurations'] for target in configuration['TestTargets']]
                targets=[target for target in targets if target.get('BlueprintName')=='BatonMobileUITests']
            else: targets=[test_run['BatonMobileUITests']]
            f.require(len(targets)==1,'Expected one UI fixture test target')
            target=targets[0]
            delivery=DeliveryControl(root,simulator,[share['url'] for share in shares],fixture.command,deadline)
            variables.update(INCOMING_CONTROL_URL=delivery.url,INCOMING_CONTROL_TOKEN=delivery.token)
            target.setdefault('EnvironmentVariables',{}).update(variables)
            private_run=original_run.with_name('IncomingFixture.xctestrun')
            private_run.write_bytes(plistlib.dumps(test_run)); private_run.chmod(0o600)
            # TESTROOT placeholders resolve relative to this private copy, beside
            # the original build products; no scheme secrets or path rewriting.
            with (root/'tests.log').open('wb') as log:
                process=fixture.start(['xcodebuild','test-without-building','-xctestrun',str(private_run),
                    '-destination','platform=iOS Simulator,id='+simulator,
                    *(["-only-testing:BatonMobileUITests/IncomingShareFlowUITests/" + name for name in selected]
                      or ["-only-testing:BatonMobileUITests/IncomingShareFlowUITests"]),
                    '-collect-test-diagnostics','never',
                    '-resultBundlePath',str(root/'incoming.xcresult')],output=log)
                rc=fixture.wait(process,on_tick=delivery.serve_one)
            f.save_json(root/'tests-exit.json',{'exitCode':rc})
            if (root/'incoming.xcresult').exists():
                summary = command(['xcrun','xcresulttool','get','test-results','summary','--path',str(root/'incoming.xcresult')])
                (root/'summary.json').write_bytes(summary)
                counts=json.loads(summary); f.require(counts['totalTestCount']==expected_count and counts['passedTests']==expected_count and counts['failedTests']==0 and counts['skippedTests']==0,'Selected incoming UI acceptance did not pass all required cases')
                result = rc
            else: raise f.FixtureFailure('Native UI result bundle unavailable')
    except FixtureTimeout:
        result = 124
        print('Fixture active deadline reached; bounded cleanup starts, ownership retained.',file=sys.stderr)
    except KeyboardInterrupt:
        result = 130
    except Exception as error:
        print('FAIL '+(str(error) if isinstance(error,f.FixtureFailure) else 'fixture error; private details withheld'),file=sys.stderr)
    finally:
        # Repeated cancellation is ignored only inside bounded teardown. SIGALRM
        # remains armed at the absolute 900-second hard bound throughout.
        for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP): signal.signal(sig,signal.SIG_IGN)
        listener_closed=delivery is None
        try:
            if delivery: listener_closed=delivery.close()
        except BaseException:
            listener_closed=False
        cleanup={'launchUncertain':True,'failures':['cleanup interrupted; independently verify retained namespace'],
            'simulatorAbsent':None,'containerAbsent':None,'registeredGroupsAbsent':False,'ownerStateTouched':False,'productionSharesCreated':0}
        try:
            cleanup=fixture.cleanup()
            cleanup['deliveryListenerClosed']=listener_closed
            if not listener_closed: cleanup['failures'].append('owned delivery listener not closed')
            write_receipt(root/'incoming-cleanup.json',cleanup)
            if not cleanup_qualified(cleanup): result=1 if result!=124 else 124
        except BaseException:
            fixture.cleanup_state='incomplete; teardown interrupted, exact ownership retained'
            best_effort(fixture.receipt)
            best_effort(write_receipt,root/'incoming-cleanup.json',cleanup)
            result=124 if result==124 or deadline.clock()>=deadline.cleanup_end else 1
        if not cleanup_qualified(cleanup): retain_custody(root,deadline)
        deadline.disarm()
        write_receipt(root/'fixture-exit.json',{'exitCode':result,'elapsedSeconds':deadline.clock()-deadline.started,
            'executionAndCleanupBoundSeconds':900})
        if cleanup_qualified(cleanup): write_receipt(root/'native-custody-release.json',{'qualified':True})
    return result

if __name__=='__main__': sys.exit(main())
