#!/usr/bin/env python3
"""Narrow actual-wrapper CPU fixtures; no compiler, app, native guards or signals."""
import hashlib,importlib.util,json,os,subprocess,sys,tempfile,time,unittest
from unittest.mock import Mock, patch
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
SHELL=REPO/'scripts/probe-mixtape-ui-walks.sh'
RUNNER=REPO/'ios/scripts/run-app-attest-offline-compiler.py'
class CompilerOwnership(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='baton-9252-standalone-CPU-',dir='/private/tmp');self.base=Path(self.temp.name);self.base.chmod(0o700)
        self.root=self.base/'attempt';self.root.mkdir(mode=0o700);self.repo=self.base/'repo';(self.repo/'scripts').mkdir(parents=True)
        self.controller=self.root/'controller.py'
        self.write(self.controller,b'''import os,sys,time\nfrom pathlib import Path\nROOT=Path(__file__).resolve().parent\nREPO=ROOT.parent/'repo'\ndef preflight():return {}\ndef record_cancel(signum,frame):pass\ndef run():\n    (ROOT/'compiler-born').write_text('mock compiler only')\n    if (ROOT/'hold-fixture').exists():\n        (ROOT/'unknown-custody').write_text('original parent retained')\n        while not (ROOT/'fixture-safe-cleanup').exists():time.sleep(.01)\n    (ROOT/'mock-cleanup-qualified').write_text('no children or native work')\n    os._exit(0)\nif __name__=='__main__':\n    if '--preflight-only' in sys.argv:raise SystemExit(0)\n    run()\n''')
        self.native=self.repo/'native-owner';self.probe=self.repo/'probe-owner';self.write(self.native,b'CPU native owner retained\n');self.write(self.probe,b'CPU probe owner retained\n')
        self.identities={p:(p.stat().st_ino,p.read_bytes()) for p in [self.native,self.probe]}
        self.write(self.repo/'scripts/gate-lock.sh',b'gate_lock_acquire(){ printf native > "'+str(self.root/'native-entered').encode()+b'"; return 3; }\ngate_lock_release(){ :; }\n')
        self.write(self.repo/'scripts/probe-lib.sh',b'probe_lock_acquire(){ return 3; }\nprobe_lock_release(){ :; }\n')
        guard=self.root/'compiler-attempt.lock';self.write(guard,b'');a=guard.stat();guard_identity={'device':a.st_dev,'inode':a.st_ino,'uid':a.st_uid,'links':a.st_nlink,'mode':0o600}
        self.binding=self.root/'command-binding.json'
        pins={str(self.controller):self.sha(self.controller)}
        if RUNNER.exists():pins[str(RUNNER)]=self.sha(RUNNER)
        self.write(self.binding,json.dumps({'schemaVersion':1,'attemptRoot':str(self.root),'repository':str(self.repo),'controllerPath':str(self.controller),'guardPath':str(self.root/'compiler-attempt.lock'),'guardIdentity':guard_identity,'sourceSHA256':pins,'mode':'offline-compiler-only'}).encode())
        self.jobs=[]
    def tearDown(self):
        for child in self.jobs:
            if child.returncode is None:
                # Only the fixture's ordinary cooperative qualified completion is
                # requested. No numeric signal, terminate or unowned cleanup.
                self.write(self.root/'fixture-safe-cleanup',b'qualified synthetic absence')
                child.wait(timeout=3)
        self.temp.cleanup()
    @staticmethod
    def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
    @staticmethod
    def write(path,data):path.write_bytes(data);path.chmod(0o600)
    def command(self):
        if RUNNER.exists():return [sys.executable,'-B',str(RUNNER),'--binding',str(self.binding),'--sha256',self.sha(self.binding),'--coordinated-go']
        shell=self.repo/'scripts/old-wrapper.sh';self.write(shell,SHELL.read_bytes());return ['/bin/bash',str(shell),'--run','--qualify-fixture','--output',str(self.root)]
    def unchanged_shared(self):
        for p,(ino,data) in self.identities.items():self.assertEqual((p.stat().st_ino,p.read_bytes()),(ino,data))
        self.assertFalse((self.root/'native-entered').exists())
    def start(self,environment=None):
        log=self.root/('cpu-'+str(len(self.jobs))+'.log');stream=log.open('xb');log.chmod(0o600)
        child=subprocess.Popen(self.command(),stdout=stream,stderr=subprocess.STDOUT,env=environment);stream.close();self.jobs.append(child);return child
    def wait_for(self,name):
        end=time.monotonic()+2
        while time.monotonic()<end:
            if (self.root/name).exists():return
            time.sleep(.01)
        self.fail('owned CPU fixture admission observation absent: '+name)
    def test_offline_wrapper_never_enters_native_or_probe_guard(self):
        child=self.start();self.assertEqual(child.wait(timeout=3),0)
        self.assertTrue((self.root/'compiler-born').exists());self.assertTrue((self.root/'mock-cleanup-qualified').exists());self.unchanged_shared()
    def test_busy_attempt_refuses_before_second_compiler_birth_then_positive_release(self):
        self.write(self.root/'hold-fixture',b'CPU-only hold');first=self.start();self.wait_for('unknown-custody')
        born=(self.root/'compiler-born').stat().st_mtime_ns
        environment=dict(os.environ);environment.update(BATON_GATE_LOCK_ACTIVE='1',BATON_GATE_LOCK_ACTIVE_OWNER_PID='0',BATON_ALLOW_CONCURRENT_GATE='1')
        second=self.start(environment);self.assertEqual(second.wait(timeout=3),3)
        self.assertEqual((self.root/'compiler-born').stat().st_mtime_ns,born);self.assertIsNone(first.poll());self.unchanged_shared()
        self.write(self.root/'fixture-safe-cleanup',b'qualified synthetic absence');self.assertEqual(first.wait(timeout=3),0)
        third=self.start();self.assertEqual(third.wait(timeout=3),0);self.unchanged_shared()
    def test_changed_binding_refuses_before_compiler_birth(self):
        command=self.command();self.binding.write_bytes(self.binding.read_bytes()+b' ')
        child=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);self.jobs.append(child)
        self.assertEqual(child.wait(timeout=3),2);self.assertFalse((self.root/'compiler-born').exists());self.unchanged_shared()
    def test_replaced_guard_inode_refuses_before_compiler_birth(self):
        guard=self.root/'compiler-attempt.lock';guard.rename(self.root/'retained-original.lock');self.write(guard,b'')
        child=self.start();self.assertEqual(child.wait(timeout=3),2);self.assertFalse((self.root/'compiler-born').exists());self.unchanged_shared()
    def test_no_explicit_go_refuses_before_compiler_birth(self):
        command=self.command();command.remove('--coordinated-go')
        child=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);self.jobs.append(child)
        self.assertEqual(child.wait(timeout=3),2);self.assertFalse((self.root/'compiler-born').exists());self.unchanged_shared()

    def test_dependency_state_drift_refuses_before_compiler_birth(self):
        dependency=self.root/'public-workspace-state.json';self.write(dependency,b'{"publicPinnedDependencies":3}')
        data=json.loads(self.binding.read_bytes());data['sourceSHA256'][str(dependency)]=self.sha(dependency)
        self.write(self.binding,json.dumps(data).encode());command=self.command()
        self.write(dependency,b'{"publicPinnedDependencies":4}')
        child=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);self.jobs.append(child)
        self.assertEqual(child.wait(timeout=3),2);self.assertFalse((self.root/'compiler-born').exists());self.unchanged_shared()

class FixtureCommandAdmission(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='baton-9252-typed-CPU-',dir='/private/tmp')
        self.root=Path(self.temp.name);self.root.chmod(0o700)
        self.cache_temp=tempfile.TemporaryDirectory(prefix='baton-9252-cache-CPU-',dir='/private/tmp')
        self.cache=Path(self.cache_temp.name);self.cache.chmod(0o700)
        self.pins=REPO/'gateway/Package.resolved'
        pin_data=json.loads(self.pins.read_bytes())['pins'];self.pin_by_revision={p['state']['revision']:p for p in pin_data}
        dependencies=[]
        for p in pin_data:
            checkout=self.cache/'checkouts'/p['identity'];(checkout/'.git').mkdir(parents=True)
            repository=self.cache/'repositories'/p['identity'];repository.mkdir(parents=True)
            for target,bare in [(checkout/'.git/config',False),(repository/'config',True)]:
                target.write_text('[core]\n\tbare = '+str(bare).lower()+'\n[remote "origin"]\n\turl = '+p['location']+'\n')
            (checkout/'Package.swift').write_bytes(b'// independent public synthetic package manifest\n')
            dependencies.append({'packageRef':{'identity':p['identity'],'kind':'remoteSourceControl','location':p['location']},
                'state':{'checkoutState':p['state']},'subpath':p['identity']})
        (self.cache/'workspace-state.json').write_text(json.dumps({'object':{'dependencies':dependencies,'artifacts':[]}}))
        inputs={'repository':str(REPO),'source':'237317c8b58318cbb6a6ceb1c9ef3de86dbf8507',
            'selectionManifest':str(REPO/'docs/evidence/tbx-9252/native-ui-walk-source-fixture-repair-2026-10-07.json'),
            'gatewayCache':str(self.cache),'gatewayPins':str(self.pins)}
        (self.root/'fixture-inputs.json').write_text(json.dumps(inputs))
        controller=self.root/'controller.py';controller.write_bytes((REPO/'scripts/mixtape_fixture_standalone_controller.py').read_bytes())
        spec=importlib.util.spec_from_file_location('typed_fixture_controller',controller)
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)
        self.calls=[]
    def tearDown(self):self.temp.cleanup();self.cache_temp.cleanup()
    def test_native_service_network_and_other_product_requests_refuse_before_spawn(self):
        owned=Mock();command=self.module.FixtureCommands(owned,self.root,REPO,self.cache,self.pins)
        forbidden=[['xcrun','simctl','boot','synthetic-device'],['xcodebuild','test'],
            ['/usr/bin/open','Baton.app'],['docker','run','synthetic-image'],['curl','https://example.invalid'],
            ['swift','test'],['swift','build','--product','baton-share']]
        for argv in forbidden:
            with self.subTest(argv=argv),self.assertRaises(ValueError):command(argv)
        owned.command.assert_not_called()
    def public_command(self,argv,cap=120,accept_failure=False):
        self.calls.append((argv,cap,accept_failure))
        if argv[0]=='/usr/bin/git':
            if argv[-2:]==['rev-parse','HEAD']:
                if argv[2]==str(REPO):return b'237317c8b58318cbb6a6ceb1c9ef3de86dbf8507\n',0
                identity=Path(argv[2]).name
                pin=next(p for p in self.pin_by_revision.values() if p['identity']==identity)
                return pin['state']['revision'].encode()+b'\n',0
            if 'show' in argv:return b'// independent public synthetic package manifest\n',0
            return b'',0
        if argv[0]=='/usr/bin/swift':
            directory=self.root/'gateway-build/debug'
            if '--show-bin-path' in argv:return str(directory).encode()+b'\n',0
            import shutil
            directory.mkdir(parents=True)
            binary=directory/'baton-mixtape-ui-fixture';binary.write_bytes(b'public synthetic executable, never launched');binary.chmod(0o700)
            resources=directory/'baton-gateway_BatonShareServer.bundle/Contents/Resources';resources.mkdir(parents=True)
            for area in ['Web','AttestationRoots']:shutil.copytree(REPO/'gateway/Sources/BatonShareServer'/area,resources/area)
            return b'',0
        return b'mixtape UI fixture: invalid disposable inputs\n',64
    def inert_run(self,cleanup_failure=None,qualify=None):
        class Finished(BaseException):pass
        class Held(BaseException):pass
        self.Finished,self.Held=Finished,Held
        patches=[patch.object(self.module.ui.ReservedOwnedFixture,'command',side_effect=self.public_command),
            patch.object(self.module.ui.Deadline,'arm'),patch.object(self.module.ui.Deadline,'enter_cleanup'),
            patch.object(self.module.ui.Deadline,'disarm'),patch.object(self.module.signal,'signal'),
            patch.object(self.module,'FINAL_EXIT',side_effect=Finished),
            patch.object(self.module.ui,'hold_original_parent',side_effect=Held)]
        if cleanup_failure:patches.append(patch.object(self.module.ui.ReservedOwnedFixture,'cleanup',side_effect=cleanup_failure))
        if qualify:patches.append(patch.object(self.module.ui,'qualify_fixture',side_effect=qualify))
        original=self.module.ui.ReservedOwnedFixture
        def controller(root,environment,deadline):
            self.child_environment=environment
            return original(root,environment,deadline)
        patches.append(patch.object(self.module.ui,'ReservedOwnedFixture',side_effect=controller))
        from contextlib import ExitStack
        with ExitStack() as stack:
            active=[stack.enter_context(p) for p in patches]
            try:self.module.run()
            except (Finished,Held) as result:return type(result),active[5],active[6]
        self.fail('An admitted controller must commit qualified exit or retain its original parent')
    def test_complete_public_fixture_flow_uses_only_allowed_private_commands_and_cleanup(self):
        result,exit_call,hold=self.inert_run()
        self.assertIs(result,self.Finished);exit_call.assert_called_once_with(0);hold.assert_not_called()
        receipt=json.loads((self.root/'fixture-artifact.json').read_bytes())
        self.assertEqual(receipt['cliRefusalsPassed'],4)
        self.assertEqual([c['exitCode'] for c in receipt['cliRefusals']],[64,64,64,64])
        self.assertEqual(len(self.calls),21)
        self.assertEqual([cap for a,cap,_ in self.calls if a[0]=='/usr/bin/swift'],[600,120])
        for argv,_,_ in self.calls:
            if argv[0]=='/usr/bin/swift':
                self.assertEqual(argv[-6:],['--config-path',str(self.root/'gateway-config'),
                    '--security-path',str(self.root/'gateway-security'),'--disable-netrc','--disable-keychain'])
        self.assertTrue(self.module.ui.qualify_ui_release(self.root))
    def test_child_environment_discards_owner_auth_and_uses_private_paths_without_account_home_assignment(self):
        # Independent adversarial inputs enter through the public parent process
        # environment; only the admitted process boundary is observed.
        with patch.dict(os.environ,{'AUTH_TOKEN':'synthetic-do-not-inherit',
            'GIT_CONFIG_COUNT':'1','HTTP_PROXY':'https://synthetic.invalid'}):
            result,exit_call,hold=self.inert_run()
        self.assertIs(result,self.Finished);exit_call.assert_called_once_with(0)
        self.assertFalse({'HOME','CODEX_HOME','AUTH_TOKEN','GIT_CONFIG_COUNT'} & self.child_environment.keys())
        self.assertEqual(self.child_environment['TMPDIR'],str(self.root))
        self.assertEqual(self.child_environment['GIT_CONFIG_GLOBAL'],'/dev/null')
        self.assertEqual(self.child_environment['GIT_ALLOW_PROTOCOL'],'file')
        self.assertEqual(self.child_environment['HTTP_PROXY'],'http://127.0.0.1:9')
    def test_read_only_dependency_status_preserves_index_after_source_mtime_changes(self):
        result,exit_call,hold=self.inert_run()
        self.assertIs(result,self.Finished);exit_call.assert_called_once_with(0)
        repository=self.root/'read-only-input';repository.mkdir(mode=0o700)
        scratch=self.root/'git-temporary';scratch.mkdir(mode=0o700)
        environment=dict(self.child_environment,TMPDIR=str(scratch))
        def git(*arguments):
            return subprocess.run(['/usr/bin/git','-C',str(repository),*arguments],
                env=environment,capture_output=True,check=True,timeout=3).stdout
        git('init','-q')
        git('config','user.name','Fixture')
        git('config','user.email','fixture@example.invalid')
        git('config','core.fsmonitor','false')
        source=repository/'Package.swift';source.write_bytes(b'// unchanged public package\n')
        git('add','Package.swift');git('commit','-qm','public fixture')
        index=repository/'.git/index';before=index.read_bytes();source_bytes=source.read_bytes()
        stat=source.stat();os.utime(source,ns=(stat.st_atime_ns,stat.st_mtime_ns+2_000_000_000))
        self.assertEqual(git('status','--porcelain=v1','--untracked-files=all','--ignored=matching'),b'')
        self.assertEqual(source.read_bytes(),source_bytes)
        self.assertEqual(index.read_bytes(),before,'Read-only qualification refreshed the dependency index')
    def test_forbidden_request_during_qualification_never_spawns_or_publishes_artifact(self):
        def qualify(root,args,command):command(['xcrun','simctl','boot','synthetic-device'])
        result,exit_call,hold=self.inert_run(qualify=qualify)
        self.assertIs(result,self.Finished);exit_call.assert_called_once_with(1);hold.assert_not_called()
        self.assertEqual(len(self.calls),3);self.assertFalse((self.root/'fixture-artifact.json').exists())
    def test_unqualified_cleanup_retains_original_parent_and_private_lock(self):
        spec=importlib.util.spec_from_file_location('source_bound_lock',RUNNER)
        launcher=importlib.util.module_from_spec(spec);spec.loader.exec_module(launcher)
        lock=self.root/'compiler-attempt.lock';lock.touch(mode=0o600);a=lock.stat()
        data={'guardPath':str(lock),'guardIdentity':launcher.identity(a)}
        fd=launcher.guard(data)
        try:
            result,exit_call,hold=self.inert_run(cleanup_failure=RuntimeError('synthetic unresolved cleanup'))
            self.assertIs(result,self.Held);hold.assert_called_once();exit_call.assert_not_called()
            with self.assertRaises(BlockingIOError):launcher.guard(data)
            self.assertFalse((self.root/'native-custody-release.json').exists())
        finally:os.close(fd) # This CPU fixture created no child; its own test descriptor only.
if __name__=='__main__':unittest.main()
