"""Opt-in reserved-leader lifecycle for explicitly migrated native fixture callers."""
import os
import json
import stat
import sys
from pathlib import Path
import signal
import subprocess
import time
from incoming_fixture_lifecycle import Deadline, OwnedFixture, FixtureDiagnosticFailure, FixtureTimeout, write_receipt
from mixtape_owned_supervision import wait_owned, group_present

class CustodyDeadline(Deadline):
    """Keep ordinary bounds; an entered unknown-custody hold cannot auto-exit."""
    def __init__(self, *args, **kwargs):
        self.custody_retained = False
        super().__init__(*args, **kwargs)

    def alarm(self, signum, frame):
        # A failed disarm may leave SIGALRM armed. Once original custody is held,
        # that existing handler must neither hard-exit nor raise/rearm a timer.
        if self.custody_retained:
            return
        return super().alarm(signum, frame)


class ReservedOwnedFixture(OwnedFixture):
    def __init__(self, root, env, deadline):
        self.launch_uncertain=False
        super().__init__(root,env,deadline)

    def receipt(self):
        super().receipt()
        path=self.root/'ownership.json'
        receipt=json.loads(path.read_bytes())
        receipt['launchUncertain']=self.launch_uncertain
        write_receipt(path,receipt)

    def cancellation_requested(self):
        return self.root.with_name(self.root.name+'.cancel-requested').exists()

    def start(self, argv, childenv=None, output=subprocess.DEVNULL, stderr=subprocess.STDOUT):
        self.deadline.remaining()
        if not self.deadline.cleaning and self.cancellation_requested():
            raise FixtureDiagnosticFailure('interrupted','Cancellation requested before launch')
        if self.launch_uncertain:
            raise FixtureDiagnosticFailure('owned-launch-handshake','Earlier unregistered launch requires coordinator reconciliation')
        # Persist uncertainty before entering Popen: an asynchronous exception can
        # arrive after child birth but before Popen returns or registration runs.
        self.launch_uncertain=True; self.receipt()
        process = subprocess.Popen(['/bin/sh','-c','kill -STOP $$; exec "$@"','incoming-fixture',*argv],
            env=childenv or self.env, stdin=subprocess.DEVNULL, stdout=output,
            stderr=stderr, start_new_session=True)
        self.processes.append(process)
        entry = {'pid':process.pid,'pgid':process.pid,'tool':Path(argv[0]).name,
                 'closed':False,'started':False,'reservedLeader':True}
        self.groups.append(entry); self.receipt()
        # Registration is now durable. Only this successful path clears the flag;
        # no exception handler or later cleanup command may erase an unknown birth.
        self.launch_uncertain=False; self.receipt()
        if os.getpgid(process.pid) != process.pid:
            raise FixtureDiagnosticFailure('owned-group-registration','Owned group registration failed')
        while True:
            self.deadline.remaining()
            stopped = os.waitid(os.P_PID, process.pid, os.WSTOPPED|os.WEXITED|os.WNOHANG|os.WNOWAIT)
            if stopped:
                if stopped.si_code != os.CLD_STOPPED:
                    raise FixtureDiagnosticFailure('owned-launch-handshake','Owned launch handshake failed')
                break
            time.sleep(min(.01,self.deadline.remaining()))
        entry['started']=True; entry['sessionVerified']=True; self.receipt()
        if not self.deadline.cleaning and self.cancellation_requested():
            raise FixtureDiagnosticFailure('interrupted','Cancellation requested before owned group resume')
        os.killpg(process.pid,signal.SIGCONT)
        return process

    def running(self, process):
        entry=next(e for e in self.groups if e['pid']==process.pid)
        if entry['closed']: return False
        self.deadline.remaining()
        if not self.deadline.cleaning and self.cancellation_requested():
            raise FixtureDiagnosticFailure('interrupted','Cancellation requested during observation')
        try:
            if (process.returncode is not None or entry.get('reservedLeader') is not True or
                entry.get('sessionVerified') is not True):
                raise ChildProcessError('Original verified reservation unavailable')
            observed=os.waitid(os.P_PID,process.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT)
            if observed is not None and observed.si_pid!=process.pid:
                raise ChildProcessError('Original direct-child identity unavailable')
        except ChildProcessError:
            entry['ownershipUncertain']=True; self.receipt()
            raise FixtureDiagnosticFailure('owned-group-registration','Non-reaping child observation refused') from None
        return observed is None

    def wait(self, process, cap=None, cleaning=False, on_tick=None):
        entry = next(e for e in self.groups if e['pid']==process.pid)
        if entry['closed']:
            return entry['exitCode']
        # Never signal a PID/PGID after a caller or interrupted supervision reaped it.
        if process.returncode is not None:
            entry['reservedLeader']=False
            entry['ownershipUncertain']=True
            self.receipt()
            raise FixtureDiagnosticFailure('owned-group-registration','Previously reaped group retained without signalling')
        execution = 0 if cleaning else self.deadline.remaining(cap)
        outer = min(execution+15,self.deadline.remaining() if cleaning else self.deadline.hard_end-self.deadline.clock())
        try:
            outcome=wait_owned(process,execution_seconds=execution,outer_seconds=outer,
                cancelled=lambda:not self.deadline.cleaning and self.cancellation_requested(),
                registered_group=entry['pgid'] if entry.get('sessionVerified') is True else None,
                on_tick=on_tick)
        except BaseException:
            entry['reservedLeader']=process.returncode is None
            entry['ownershipUncertain']=True; self.receipt()
            raise
        outcome.pop('restoreRequired',None)
        entry['supervision']=outcome; entry['exitCode']=outcome['testExit']
        entry['reservedLeader']=not outcome['leaderReaped']
        entry['closed']=(outcome['cleanupComplete'] and outcome['leaderReaped'] and
            not outcome['ownedGroupPending'] and not outcome['inspectionProcessPending'])
        self.receipt()
        if not entry['closed']:
            raise FixtureDiagnosticFailure('owned-group-registration','Owned cleanup incomplete; custody retained')
        if outcome['timedOut'] and not cleaning:
            raise FixtureDiagnosticFailure('owned-command-timeout','Owned command timed out')
        return outcome['testExit']

    def finished(self, process):
        return self.wait(process)

    def command(self, argv, childenv=None, cap=120, accept_failure=False, stdout_only=False):
        index=len(self.groups)
        stdout_path=self.root/('command-stdout-%04d.log'%index)
        with stdout_path.open('xb') as output:
            if stdout_only:
                stderr_path=self.root/('command-stderr-%04d.log'%index)
                with stderr_path.open('xb') as errors:
                    process=self.start(argv,childenv,output,errors)
                    rc=self.wait(process,cap)
            else:
                process=self.start(argv,childenv,output)
                rc=self.wait(process,cap)
        if rc and not accept_failure:
            raise FixtureDiagnosticFailure('owned-command-nonzero','Owned command failed; private output withheld')
        if stdout_path.stat().st_size>16*1024*1024:
            raise FixtureDiagnosticFailure('owned-command-nonzero','Owned response bound exceeded')
        return stdout_path.read_bytes(),rc

    def stop_groups(self):
        failures=[]
        by_pid={p.pid:p for p in self.processes}
        for entry in self.groups:
            if entry['closed']: continue
            process=by_pid.get(entry['pid'])
            if process is None or process.returncode is not None or not entry.get('reservedLeader'):
                # Existence after reap cannot authorize a signal. Retain uncertainty,
                # even if an unrelated group later uses the same numeric identifier.
                failures.append('unreserved registered group requires coordinator reconciliation')
                continue
            try: self.wait(process,cleaning=True)
            except Exception: failures.append('reserved registered group cleanup incomplete')
        self.receipt()
        return failures

    def cleanup(self):
        cleanup=super().cleanup()
        cleanup['launchUncertain']=self.launch_uncertain
        if self.launch_uncertain:
            cleanup['failures'].append('unregistered launch requires coordinator reconciliation')
            self.cleanup_state='incomplete; unregistered launch custody retained'
        self.receipt()
        write_receipt(self.root/'incoming-cleanup.json',cleanup)
        return cleanup

def best_effort(action,*args):
    try: action(*args)
    except BaseException: pass


def retain_custody(root,deadline):
    # Preserve the original parent reservation on unknown cleanup. Diagnostic
    # I/O and handled interruptions cannot turn this holder into an exit.
    if isinstance(deadline, CustodyDeadline):
        # Set this before disarm, handler installation or any diagnostic I/O.
        deadline.custody_retained = True
    best_effort(lambda: deadline.disarm())
    def notice(name, value):
        # Include path conversion/evaluation in the protected diagnostic boundary.
        try: write_receipt(Path(root)/name,value)
        except BaseException: pass
    def requested(_sig,_frame):
        notice('custody-interruption.json',{'requested':True,'qualified':False})
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):
        best_effort(signal.signal,sig,requested)
    notice('custody-hold.json',{'qualified':False,
        'controllerPID':os.getpid(),'automaticExit':False,'reason':'Owned cleanup unqualified; coordinator reconciliation required'})
    best_effort(print,'BLOCKED: original controller custody retained:',root)
    while True:
        try: time.sleep(30)
        except BaseException: pass


def cleanup_qualified(cleanup):
    return (cleanup.get('launchUncertain') is False and
            cleanup.get('failures')==[] and cleanup.get('registeredGroupsAbsent') is True and
            cleanup.get('schemeRestoredExactly') is True and
            (cleanup.get('simulatorAbsent') is None or cleanup.get('simulatorAbsent') is True) and
            (cleanup.get('containerAbsent') is None or cleanup.get('containerAbsent') is True))

def release_qualified(root):
    root=Path(root)
    attrs=root.lstat()
    if root != root.resolve() or not stat.S_ISDIR(attrs.st_mode) or attrs.st_uid!=os.getuid() or stat.S_IMODE(attrs.st_mode)!=0o700:
        return False
    receipts={}
    for name in ['native-custody-release.json','incoming-cleanup.json','ownership.json']:
        path=root/name; attrs=path.lstat()
        if not stat.S_ISREG(attrs.st_mode) or attrs.st_uid!=os.getuid() or stat.S_IMODE(attrs.st_mode)!=0o600 or attrs.st_size>1024*1024:
            return False
        receipts[name]=json.loads(path.read_bytes())
    release=receipts['native-custody-release.json']; cleanup=receipts['incoming-cleanup.json']; ownership=receipts['ownership.json']
    return (release.get('qualified') is True and ownership.get('launchUncertain') is False and cleanup_qualified(cleanup) and
            (not ownership.get('simulatorName') or cleanup['simulatorAbsent'] is True) and
            (not ownership.get('containerName') or cleanup['containerAbsent'] is True) and
            ownership.get('cleanup')=='qualified' and all(
            e.get('closed') is True and e.get('reservedLeader') is False and
            e.get('supervision',{}).get('cleanupComplete') is True and
            e.get('supervision',{}).get('leaderReaped') is True and
            e.get('supervision',{}).get('ownedGroupPending') is False and
            e.get('supervision',{}).get('inspectionProcessPending') is False
            for e in ownership['groups']))

if __name__ == '__main__':
    try:
        if len(sys.argv)!=3 or sys.argv[1]!='--qualify-release': sys.exit(2)
        sys.exit(0 if release_qualified(sys.argv[2]) else 1)
    except Exception: sys.exit(1)
