#!/usr/bin/env python3
"""Narrow actual-wrapper CPU fixtures; no compiler, app, native guards or signals."""
import hashlib,json,os,subprocess,sys,tempfile,time,unittest
from pathlib import Path
REPO=Path(__file__).resolve().parents[2]
SHELL=REPO/'docs/evidence/tbx-8711/cached-compiler-preparation/compile-readiness.sh'
RUNNER=REPO/'ios/scripts/run-app-attest-offline-compiler.py'
class CompilerOwnership(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='baton-9411-ownership-CPU-',dir='/private/tmp');self.base=Path(self.temp.name);self.base.chmod(0o700)
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
        shell=self.base/'old-wrapper.sh';text=SHELL.read_text().replace('/private/tmp/baton-tbx8711-cached-runtime-20261007-2450a4e6',str(self.root)).replace('/private/tmp/baton-tbx-8711-cached-compiler-readiness',str(self.repo));self.write(shell,text.encode());return ['/bin/bash',str(shell),'--coordinated-go']
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
if __name__=='__main__':unittest.main()
