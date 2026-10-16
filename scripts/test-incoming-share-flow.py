#!/usr/bin/env python3
"""Lifecycle guards: mocks and disposable Python groups; no native/UI/network actions."""
import contextlib
import importlib.util
import io
import json
import plistlib
import os
from pathlib import Path
import signal
import socket
import subprocess
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from incoming_fixture_lifecycle import Deadline, FixtureTimeout, group_exists
from mixtape_owned_lifecycle import ReservedOwnedFixture as OwnedFixture
from owned_fixture_cpu_support import retained_cpu_fixture
from incoming_fixture_packages import EXPECTED, SENTRY_TARGETS, validate_cache, copy_cache, offline_environment

path=Path(__file__).with_name('probe-incoming-share-flow.py')
spec=importlib.util.spec_from_file_location('incoming_flow',path)
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class IncomingFixtureGuards(unittest.TestCase):
    def test_simulator_entitlement_section_reads_bytes_and_refuses_invalid_bounds(self):
        payload=plistlib.dumps({'application-identifier':'SIMFIXTURE.io.tonebox.baton'})
        header=struct.pack('<IiiIIIII',0xfeedfacf,0x100000c,0,2,1,152,0,0)
        segment=struct.pack('<II16sQQQQiiII',0x19,152,b'__TEXT',0,0,0,0,0,0,1,0)
        section=struct.pack('<16s16sQQIIIIIIII',b'__entitlements',b'__TEXT',0,len(payload),184,0,0,0,0,0,0,0)
        binary=header+segment+section+payload
        self.assertEqual(module.simulator_entitlement_section(binary),payload)
        for bad in [b'',binary[:32],binary.replace(b'__entitlements',b'__wrongsection'),
                binary[:152]+struct.pack('<I',2**32-1)+binary[156:]]:
            with self.assertRaises(module.f.FixtureFailure): module.simulator_entitlement_section(bad)
    def test_simulator_signing_refuses_unsigned_and_wrong_application(self):
        # The retained unsigned app that produced real Keychain -34018 had {}.
        for entitlements in [{},{'application-identifier':'io.tonebox.baton'},
                {'application-identifier':'PREFIX.other.app'}, {'application-identifier':42},
                {'application-identifier':'.io.tonebox.baton'}]:
            with self.assertRaises(module.f.FixtureFailure):
                module.verify_simulator_entitlements(entitlements)
        # Read the signed prefix; do not infer it from Team ID or use it as a
        # qualification of production signing/AASA.
        proof=module.verify_simulator_entitlements({'application-identifier':'SIMFIXTURE.io.tonebox.baton'})
        self.assertEqual(proof['applicationIdentifier'],'SIMFIXTURE.io.tonebox.baton')
    def test_native_process_check_refuses_active_and_indeterminate_results(self):
        module.verify_native_process_check(1)
        for value in [0,2,-9]:
            with self.assertRaises(module.f.FixtureFailure): module.verify_native_process_check(value)
    def test_listener_machine_fields_ignore_mount_warning_without_weakening_scope(self):
        warning='lsof: WARNING: unrelated mount unavailable\n      Output information may be incomplete.\n'
        fields='p42\nn127.0.0.1:12345\nTST=LISTEN\n'
        self.assertEqual(module.verify_loopback_listener(warning+fields,42,12345)['address'],'127.0.0.1:12345')
        for bad in [fields.replace('p42','p43'),fields.replace('127.0.0.1','0.0.0.0'),
                    fields.replace('127.0.0.1','*'),fields.replace('LISTEN','ESTABLISHED'),
                    fields+'n127.0.0.1:23456\nTST=LISTEN\n',warning]:
            with self.assertRaises(module.f.FixtureFailure): module.verify_loopback_listener(bad,42,12345)
    def test_actual_owned_listener_is_qualified_by_machine_fields(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); listener.listen()
            result=subprocess.run(['/usr/sbin/lsof','-nP','-a','-p',str(os.getpid()),'-iTCP','-sTCP:LISTEN','-FpnT'],
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=3)
            self.assertEqual(result.returncode,0)
            proof=module.verify_loopback_listener(result.stdout.decode(),os.getpid(),listener.getsockname()[1])
            self.assertEqual(proof['state'],'LISTEN')
    def package_fixture(self, root):
        cache=root/'cache'; repo=root/'repo'; cache.mkdir(); repo.mkdir()
        (cache/'checkouts').mkdir(); (cache/'repositories').mkdir(); (cache/'artifacts').mkdir()
        local=repo/'Packages/BatonMCPProtocol'; local.mkdir(parents=True); (local/'Package.swift').write_text('local')
        pins=[]; dependencies=[]
        for identity,(version,revision) in EXPECTED.items():
            location='https://example.invalid/'+identity
            state={'version':version,'revision':revision}
            pins.append(dict(identity=identity,location=location,state=state))
            dependencies.append(dict(packageRef=dict(identity=identity,kind='remoteSourceControl',location=location),
                state=dict(checkoutState=state),subpath=identity))
            checkout=cache/'checkouts'/identity; checkout.mkdir(); (checkout/'Package.swift').write_text(identity)
        artifacts=[]; manifest=[]
        for n,target in enumerate(sorted(SENTRY_TARGETS)):
            artifact=cache/'artifacts'/('target'+str(n)); artifact.mkdir()
            (artifact/'ios-arm64-simulator').mkdir(); (artifact/'ios-arm64-simulator/binary').write_bytes(b'fixture')
            (artifact/'Info.plist').write_bytes(plistlib.dumps(dict(AvailableLibraries=[dict(SupportedPlatform='ios',
                SupportedPlatformVariant='simulator',SupportedArchitectures=['arm64'],LibraryIdentifier='ios-arm64-simulator',BinaryPath='binary')])))
            checksum=str(n)*64; url='https://example.invalid/artifact'+str(n)
            manifest.append(checksum+' '+url)
            artifacts.append(dict(targetName=target,packageRef=dict(identity='sentry-cocoa'),source=dict(checksum=checksum,url=url),path=str(artifact)))
        (cache/'checkouts/sentry-cocoa/Package.swift').write_text('\n'.join(manifest))
        dependencies.append(dict(packageRef=dict(kind='fileSystem',location='/old/Packages/BatonMCPProtocol'),state=dict(path='/old/Packages/BatonMCPProtocol')))
        (cache/'workspace-state.json').write_text(json.dumps(dict(object=dict(dependencies=dependencies,artifacts=artifacts))))
        pins_file=root/'Package.resolved'; pins_file.write_text(json.dumps(dict(pins=pins)))
        def command(argv):
            identity=Path(argv[2]).name
            if argv[3]=='rev-parse': return EXPECTED[identity][1].encode()
            if argv[3]=='diff': return b''
            if argv[3]=='show': return (cache/'checkouts'/identity/'Package.swift').read_bytes()
            raise AssertionError(argv)
        return cache,pins_file,repo,command
    def test_offline_cache_copies_exact_pins_and_rebinds_only_owned_paths(self):
        with tempfile.TemporaryDirectory(prefix='incoming-packages-') as temporary:
            root=Path(temporary); cache,pins,repo,command=self.package_fixture(root)
            original=(cache/'workspace-state.json').read_bytes()
            phases=[]
            pins_bytes,receipt=copy_cache(cache,pins,root/'owned',repo,command,on_phase=phases.append)
            self.assertEqual(phases,['cache-validation','cache-copy'])
            self.assertEqual(pins_bytes,pins.read_bytes()); self.assertEqual(receipt['cachedArtifacts'],5)
            self.assertEqual((cache/'workspace-state.json').read_bytes(),original)
            state=json.loads((root/'owned/workspace-state.json').read_text())['object']
            self.assertEqual(state['dependencies'][-1]['state']['path'],str((repo/'Packages/BatonMCPProtocol').resolve()))
            self.assertTrue(all(Path(a['path']).is_relative_to((root/'owned/artifacts').resolve()) for a in state['artifacts']))
            with self.assertRaises(RuntimeError): copy_cache(cache,pins,root/'owned',repo,command)
    def test_offline_cache_rejects_mismatched_pin_manifest_and_missing_artifact(self):
        with tempfile.TemporaryDirectory(prefix='incoming-packages-') as temporary:
            cache,pins,repo,command=self.package_fixture(Path(temporary))
            original=pins.read_bytes(); data=json.loads(original); data['pins'][0]['state']['revision']='a'*40
            pins.write_text(json.dumps(data))
            with self.assertRaises(RuntimeError): validate_cache(cache,pins,command)
            pins.write_bytes(original)
            def bad_manifest(argv): return b'changed' if argv[3]=='show' else command(argv)
            with self.assertRaises(RuntimeError): validate_cache(cache,pins,bad_manifest)
            (cache/'artifacts/target0/ios-arm64-simulator/binary').unlink()
            with self.assertRaises(RuntimeError): validate_cache(cache,pins,command)
    def test_offline_environment_refuses_actual_http_git_transport(self):
        env=offline_environment({'PATH':'/usr/bin:/bin','HOME':'/owned','HTTP_PROXY':'https://untrusted',
            'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'})
        self.assertEqual(env['GIT_ALLOW_PROTOCOL'],'file'); self.assertEqual(env['GIT_TERMINAL_PROMPT'],'0')
        self.assertEqual(env['HTTPS_PROXY'],'http://127.0.0.1:9'); self.assertEqual(env['https_proxy'],env['HTTPS_PROXY'])
        self.assertEqual(env['HOME'],'/owned')
        # A real Git process must refuse HTTP transport without reaching even a
        # listening, disposable loopback endpoint. No DNS/external host is used.
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); listener.listen(); listener.settimeout(.1)
            result=subprocess.run(['/usr/bin/git','ls-remote',
                'http://127.0.0.1:'+str(listener.getsockname()[1])+'/fixture.git'],
                env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=3)
            self.assertNotEqual(result.returncode,0)
            self.assertIn(b"transport 'http' not allowed",result.stderr)
            with self.assertRaises(socket.timeout): listener.accept()
    def test_unexpected_package_fetch_log_fails_without_claiming_kernel_denial(self):
        with tempfile.TemporaryDirectory(prefix='incoming-fetch-guard-') as temporary:
            log=Path(temporary)/'build.log'; log.write_text('Resolve Package Graph\nBuild complete\n')
            module.verify_no_package_fetch(log)
            for line in ['Fetching from https://example.invalid/repo (cached)',
                'Downloading artifact', 'Cloning package', 'Updating from remote']:
                log.write_text(line+'\n')
                with self.assertRaises(module.f.FixtureFailure): module.verify_no_package_fetch(log)
    def test_preparation_without_run_has_no_side_effects(self):
        with patch('sys.argv',['probe','--share-bin','/unopened/baton-share']), \
             patch.object(module.subprocess,'Popen',side_effect=AssertionError('process launch forbidden')), \
             patch.object(module,'wrapper_output',side_effect=AssertionError('fixture mutation forbidden')) as output_boundary, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(module.main(),0)
            self.assertIn('nothing started',output.getvalue())
            output_boundary.assert_not_called()
    def test_run_refuses_without_exact_parent_lock_before_mutation(self):
        with patch('sys.argv',['probe','--run','--share-bin','/unopened/baton-share']), \
             patch.object(Path,'read_text',return_value='0 somebody-else'), \
             patch.object(module,'wrapper_output',side_effect=AssertionError('fixture mutation forbidden')) as output_boundary:
            with self.assertRaises(module.f.FixtureFailure): module.main()
            output_boundary.assert_not_called()
    def test_active_budget_reserves_cleanup_and_cleanup_has_own_bound(self):
        now=[0.0]; deadline=Deadline(clock=lambda:now[0])
        now[0]=809; self.assertEqual(deadline.remaining(),1)
        now[0]=810
        with self.assertRaises(FixtureTimeout): deadline.remaining()
        with patch('signal.setitimer'): deadline.enter_cleanup()
        self.assertEqual(deadline.remaining(),90)
        now[0]=900
        with self.assertRaises(FixtureTimeout): deadline.remaining()
        now[0]=10; early=Deadline(clock=lambda:now[0])
        now[0]=20
        with patch('signal.setitimer'): early.enter_cleanup()
        self.assertEqual(early.remaining(),90)
    def test_alarm_transitions_to_cleanup_budget_then_hard_exits_124(self):
        now=[0.0]; deadline=Deadline(clock=lambda:now[0])
        now[0]=810
        with patch('signal.setitimer') as timer:
            with self.assertRaises(FixtureTimeout): deadline.alarm(signal.SIGALRM,None)
            timer.assert_called_once_with(signal.ITIMER_REAL,90)
        now[0]=900
        with patch('os._exit',side_effect=SystemExit) as exit_call:
            with self.assertRaises(SystemExit): deadline.alarm(signal.SIGALRM,None)
            exit_call.assert_called_once_with(124)
    def test_real_disposable_hard_alarm_exits_124_with_uncertain_receipt(self):
        with tempfile.TemporaryDirectory(prefix='incoming-hard-alarm-') as temporary:
            code = """import json,sys,time
from pathlib import Path
from incoming_fixture_lifecycle import Deadline,FixtureTimeout
from mixtape_owned_lifecycle import ReservedOwnedFixture as OwnedFixture
root=Path(sys.argv[1]); d=Deadline(total=.3,reserve=.15); fixture=OwnedFixture(root,{},d); d.arm()
try: time.sleep(3)
except FixtureTimeout:
 d.enter_cleanup(); fixture.cleanup_state='in progress; deliberately blocked test'; fixture.receipt(); time.sleep(3)
"""
            result=subprocess.run([sys.executable,'-c',code,temporary],cwd=path.parent,
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=2,start_new_session=True)
            self.assertEqual(result.returncode,124)
            receipt=json.loads((Path(temporary)/'ownership.json').read_text())
            self.assertIn('in progress',receipt['cleanup'])
            self.assertTrue(receipt['deadlinePolicy']['missingSuccessfulCleanupReceiptMeansUncertain'])
            self.assertFalse((Path(temporary)/'incoming-cleanup.json').exists())
    def test_matching_catalog_qualifies_real_tag_and_distinct_server_ids(self):
        songs=[{'id':'identity','title':'Identity Different Title','musicBrainzId':module.MATCH_RECORDING},
            {'id':'decoy','title':'Incoming Fixture A','musicBrainzId':module.OTHER_RECORDING},
            {'id':'one','title':'Incoming Fixture B','album':'Fallback Copy One'},
            {'id':'two','title':'Incoming Fixture B','album':'Fallback Copy Two'}]
        self.assertEqual(module.validate_matching_catalog(songs)['identitySongID'],'identity')
        songs[0].pop('musicBrainzId')
        with self.assertRaises(module.f.FixtureFailure): module.validate_matching_catalog(songs)
    def test_matching_catalog_rejects_coalesced_copies(self):
        songs=[{'id':'identity','title':'Identity Different Title','musicBrainzId':module.MATCH_RECORDING},
            {'id':'decoy','title':'Incoming Fixture A','musicBrainzId':module.OTHER_RECORDING},
            {'id':'same','title':'Incoming Fixture B','album':'Fallback Copy One'},
            {'id':'same','title':'Incoming Fixture B','album':'Fallback Copy Two'}]
        with self.assertRaises(module.f.FixtureFailure): module.validate_matching_catalog(songs)
    def fixture(self,root): return OwnedFixture(root,{'PATH':'/usr/bin:/bin'},Deadline())
    def test_scheme_exact_bytes_restored_preserving_unrelated_variables(self):
        with tempfile.TemporaryDirectory(prefix='incoming-scheme-') as temporary:
            root=Path(temporary); fixture=self.fixture(root); scheme=root/'original.xcscheme'
            original=b'<Scheme><EnvironmentVariable key="unrelated" value="retain"/></Scheme>'
            scheme.write_bytes(original); fixture.snapshot_scheme(scheme)
            scheme.write_bytes(b'fixture mutation')
            self.assertTrue(fixture.restore_scheme()); self.assertEqual(scheme.read_bytes(),original)
    def test_failed_rm_does_not_claim_container_absent(self):
        with tempfile.TemporaryDirectory(prefix='incoming-cleanup-') as temporary:
            fixture=self.fixture(temporary); fixture.container_name='owned-test'; fixture.container_id='a'*64
            with patch('signal.setitimer'), patch.object(fixture,'stop_groups',return_value=[]), \
                 patch.object(fixture,'containers',return_value=[['a'*64,'owned-test']]), \
                 patch.object(fixture,'command',return_value=(b'',1)):
                result=fixture.cleanup()
            self.assertFalse(result['containerAbsent']); self.assertTrue(result['failures'])
            retained=json.loads((Path(temporary)/'ownership.json').read_text())
            self.assertEqual(retained['containerID'],'a'*64); self.assertIn('incomplete',retained['cleanup'])
    def test_unknown_container_create_outcome_recovers_exact_namespace_only(self):
        with tempfile.TemporaryDirectory(prefix='incoming-namespace-') as temporary:
            fixture=self.fixture(temporary); fixture.container_name='owned-test'; fixture.receipt()
            with patch('signal.setitimer'), patch.object(fixture,'stop_groups',return_value=[]), \
                 patch.object(fixture,'containers',side_effect=[[['b'*64,'owned-test'],['c'*64,'other-owner']], [['c'*64,'other-owner']]]), \
                 patch.object(fixture,'command',return_value=(b'',0)) as commands:
                result=fixture.cleanup()
            self.assertTrue(result['containerAbsent']); self.assertEqual(result['failures'],[])
            self.assertEqual(commands.call_args.args[0],['docker','rm','-f','b'*64])
    def test_inventory_failure_retains_exact_namespace_and_unknown_absence(self):
        with tempfile.TemporaryDirectory(prefix='incoming-unknown-') as temporary:
            fixture=self.fixture(temporary); fixture.simulator_name='own-name'; fixture.simulator='own-uuid'; fixture.receipt()
            with patch('signal.setitimer'), patch.object(fixture,'stop_groups',return_value=[]), \
                 patch.object(fixture,'inventory',side_effect=RuntimeError('inventory unavailable')):
                result=fixture.cleanup()
            self.assertIsNone(result['simulatorAbsent']); self.assertTrue(result['failures'])
            self.assertEqual(json.loads((Path(temporary)/'ownership.json').read_text())['simulatorUUID'],'own-uuid')
    def test_closed_group_is_never_signalled_if_pid_number_reappears(self):
        with tempfile.TemporaryDirectory(prefix='incoming-reused-pid-') as temporary:
            fixture=self.fixture(temporary); fixture.groups=[{'pid':77,'pgid':77,'closed':True,'started':True}]
            with patch('incoming_fixture_lifecycle.group_exists',return_value=True), patch('os.killpg') as kill:
                self.assertEqual(fixture.stop_groups(),[])
                kill.assert_not_called()
    def test_disposable_descendant_is_cleaned_after_parent_completed(self):
        # Only disposable local Python processes, no Xcode/Docker/simctl/media.
        with retained_cpu_fixture('incoming-group-') as (root,fixture):
            code="import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)"
            _,rc=fixture.command([sys.executable,'-c',code],cap=5)
            self.assertEqual(rc,0)
            group=fixture.groups[0]['pgid']; self.assertFalse(group_exists(group))
            self.assertEqual(fixture.stop_groups(),[])
            self.assertTrue(fixture.groups[0]['closed'])
            record=json.loads((root/'ownership.json').read_text())
            self.assertEqual(record['groups'][0]['pgid'],group)
            self.assertTrue(record['groups'][0]['supervision']['leaderReaped'])

    def test_disposable_command_timeout_keeps_receipt_and_stops_exact_group(self):
        with retained_cpu_fixture('incoming-timeout-') as (root,fixture):
            with self.assertRaises(RuntimeError): fixture.command([sys.executable,'-c','import time;time.sleep(30)'],cap=.1)
            record=json.loads((root/'ownership.json').read_text())
            self.assertTrue(record['groups'][0]['closed'])
            self.assertTrue(record['groups'][0]['supervision']['leaderReaped'])
            self.assertEqual(fixture.stop_groups(),[])
            self.assertFalse(group_exists(fixture.groups[0]['pgid']))

if __name__=='__main__': unittest.main()
