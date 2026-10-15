#!/usr/bin/env python3
"""Isolated host-workflow checks; no SSH, credentials or providers."""
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

def module(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

deployment=module('deploy-quota-monitor');runner=module('run-share-quota')

class HostWorkflow(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.home=Path(self.tmp.name)
        self.root=self.home/'baton-share/monitor';self.root.mkdir(parents=True,mode=0o700)
        self.cron=self.home/'cron';self.cron.write_text('7 * * * * existing-job\n')
        binpath=self.home/'bin';binpath.mkdir()
        stub=binpath/'crontab';stub.write_text('#!/usr/bin/env python3\nimport sys,pathlib,os\np=pathlib.Path(os.environ["QUOTA_TEST_CRON"])\nif sys.argv[1]=="-l":sys.stdout.write(p.read_text())\nelse:p.write_bytes(sys.stdin.buffer.read())\n');stub.chmod(0o755)
        self.env={**os.environ,'PATH':str(binpath)+':'+os.environ['PATH'],'QUOTA_TEST_CRON':str(self.cron)}
        self.files={};self.old={}
        for name in ('notify','share-quota-monitor.py','share-quota-check.py','share-quota-notify-ses.py','run-share-quota.py'):
            content=('reviewed '+name).encode();self.files[name]={'content':base64.b64encode(content).decode(),'sha256':hashlib.sha256(content).hexdigest()}
            if name in ('notify','share-quota-monitor.py','share-quota-check.py'):
                previous=('old '+name).encode();p=self.root/name;p.write_bytes(previous);p.chmod(0o755);self.old[name]=hashlib.sha256(previous).hexdigest()
        for name in ('ses-smtp.json','tonebox-push.json'):
            p=self.root/name;p.write_text('{}');p.chmod(0o600)
        self.payload={'task':'TBX-9077','source':'a'*40,'files':self.files,'expectedOld':self.old,'phoneAcceptance':None,'mode':'install'}
    def tearDown(self):self.tmp.cleanup()
    def execute(self):
        prefix='import pathlib;pathlib.Path.home=staticmethod(lambda:pathlib.Path('+repr(str(self.home))+'));\n'
        r=subprocess.run(['python3','-c',prefix+deployment.REMOTE],input=json.dumps(self.payload),capture_output=True,text=True,env=self.env,timeout=5)
        return r.returncode,json.loads(r.stdout)
    def test_install_preserves_inputs_backup_and_schedule(self):
        before=self.cron.read_bytes();rc,out=self.execute();self.assertEqual(rc,0);self.assertFalse(out['schedulerChanged'])
        self.assertEqual(self.cron.read_bytes(),before)
        for n in self.old:self.assertEqual(hashlib.sha256((Path(out['backup'])/n).read_bytes()).hexdigest(),self.old[n])
        for n in ('ses-smtp.json','tonebox-push.json'):self.assertEqual((self.root/n).read_text(),'{}')
    def test_drift_refuses_before_backup(self):
        (self.root/'notify').write_text('different');self.assertEqual(self.execute()[0],1);self.assertFalse((self.root/'rollback-tbx-9077').exists())
    def test_symlink_input_refused(self):
        p=self.root/'tonebox-push.json';p.unlink();p.symlink_to(self.root/'ses-smtp.json');self.assertEqual(self.execute()[0],1)
    def test_repeat_install_refused(self):
        self.assertEqual(self.execute()[0],0);self.assertEqual(self.execute()[0],1)
    def test_missing_phone_proof_preserves_cron(self):
        self.assertEqual(self.execute()[0],0);before=self.cron.read_bytes();self.payload['mode']='activate'
        self.assertEqual(self.execute()[0],1);self.assertEqual(self.cron.read_bytes(),before)
    def test_concurrent_cron_change_refused(self):
        self.assertEqual(self.execute()[0],0);self.cron.write_text('new-owner-job\n');self.payload.update(mode='activate',phoneAcceptance=dict(warning=True,unknown=True,recovery=True,macAppStopped=True))
        self.assertEqual(self.execute()[0],1);self.assertEqual(self.cron.read_text(),'new-owner-job\n')
    def test_activation_keeps_unrelated_entries_and_has_one_schedule(self):
        self.assertEqual(self.execute()[0],0);self.payload.update(mode='activate',phoneAcceptance=dict(warning=True,unknown=True,recovery=True,macAppStopped=True))
        rc,out=self.execute();self.assertEqual(rc,0);self.assertTrue(out['schedulerChanged']);self.assertTrue(self.cron.read_text().startswith('7 * * * * existing-job\n'));self.assertEqual(self.cron.read_text().count('*/5'),1)
    def test_unreadable_cron_refuses_without_backup(self):
        (self.home/'bin/crontab').write_text('#!/bin/sh\necho "permission denied" >&2\nexit 1\n')
        self.assertEqual(self.execute()[0],1);self.assertFalse((self.root/'rollback-tbx-9077').exists())
    def test_numeric_phone_proof_refused(self):
        self.assertEqual(self.execute()[0],0);before=self.cron.read_bytes()
        self.payload.update(mode='activate',phoneAcceptance=dict(warning=1,unknown=1,recovery=1,macAppStopped=1))
        self.assertEqual(self.execute()[0],1);self.assertEqual(self.cron.read_bytes(),before)
    def test_ambiguous_schedule_apply_is_reported_honestly(self):
        self.assertEqual(self.execute()[0],0)
        stub=self.home/'bin/crontab'
        stub.write_text('#!/usr/bin/env python3\nimport sys,pathlib,os\np=pathlib.Path(os.environ["QUOTA_TEST_CRON"])\nif sys.argv[1]=="-l":sys.stdout.write(p.read_text())\nelse:\n p.write_bytes(sys.stdin.buffer.read());sys.exit(1)\n')
        self.payload.update(mode='activate',phoneAcceptance=dict(warning=True,unknown=True,recovery=True,macAppStopped=True))
        rc,out=self.execute();self.assertEqual(rc,1);self.assertNotEqual(out['schedulerChanged'],False)

class Runner(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.root.chmod(0o700)
        for name in ('notify','share-quota-check.py','share-quota-monitor.py','share-quota-notify-ses.py'):
            p=self.root/name;p.write_text('# synthetic executable');p.chmod(0o755)
    def tearDown(self):self.tmp.cleanup()
    def test_healthy_scheduled_receipt_contains_no_child_payload(self):
        seen=[]
        def invoke(argv,**kw):seen.append(argv);return subprocess.CompletedProcess(argv,0,'OK private child output','private provider output')
        self.assertEqual(runner.run(self.root,True,invoke),0);r=json.loads((self.root/'last-run.json').read_text());self.assertTrue(r['scheduled']);self.assertEqual(r['level'],'ok');self.assertNotIn('private',(self.root/'last-run.json').read_text());self.assertIn('--container',seen[0])
    def test_delivered_warning_is_not_delivery_failure(self):
        self.assertEqual(runner.run(self.root,False,lambda *a,**kw:subprocess.CompletedProcess(a,1,'WARNING share quota','')),1)
        self.assertFalse(json.loads((self.root/'last-run.json').read_text())['deliveryOrStateUnavailable'])
    def test_failed_delivery_recorded(self):
        self.assertEqual(runner.run(self.root,True,lambda *a,**kw:subprocess.CompletedProcess(a,2,'UNKNOWN share quota monitor: state or approved notifier unavailable','')),2)
        self.assertTrue(json.loads((self.root/'last-run.json').read_text())['deliveryOrStateUnavailable'])
    def test_timeout_bounded_and_recorded(self):
        def failed(*a,**kw):self.assertEqual(kw['timeout'],45);raise subprocess.TimeoutExpired(a,45)
        self.assertEqual(runner.run(self.root,True,failed),2)
    def test_overlapping_run_does_not_invoke_or_replace_receipt(self):
        p=self.root/'runner.lock';p.touch(mode=0o600)
        with p.open('w') as f:
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(runner.run(self.root,True,lambda *a,**k:self.fail('unexpected invocation')),0)
        self.assertFalse((self.root/'last-run.json').exists())

if __name__=='__main__':unittest.main()
