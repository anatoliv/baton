#!/usr/bin/env python3
"""Once-only owned CPU qualification; reserve no SDK, simulator or native guards."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import time
from incoming_fixture_lifecycle import Deadline, FixtureTimeout, write_receipt, write_failure
from mixtape_owned_lifecycle import ReservedOwnedFixture, cleanup_qualified

REPO=Path(__file__).resolve().parent.parent
SOURCES=['scripts/mixtape_owned_lifecycle.py','scripts/mixtape_owned_supervision.py',
         'scripts/incoming_fixture_lifecycle.py','scripts/test-owned-fixture-reservation-cpu.py']

def best_effort(action,*args):
    # Missing diagnostics must never turn unknown child custody into an exit.
    try: action(*args)
    except BaseException: pass

def qualified(cleanup):
    try: return cleanup is not None and cleanup_qualified(cleanup)
    except BaseException: return False

def retain_custody(root,deadline,result):
    # Observation bounds never authorize terminating an uncertain custodian.
    # No further cleanup/signal/reap is attempted automatically in this hold.
    deadline.disarm()
    def requested(_signum,_frame):
        best_effort(write_receipt,root/'cpu-holder-interruption.json',{'requested':True,'qualified':False})
    for sig in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]: signal.signal(sig,requested)
    best_effort(write_receipt,root/'cpu-result.json',result)
    best_effort(write_receipt,root/'cpu-custody-hold.json',{'qualified':False,'controllerPID':os.getpid(),
        'controllerRemainsAlive':True,'automaticExit':False,'reason':'Owned cleanup unqualified; coordinator reconciliation required'})
    def announce(): print('BLOCKED: owned CPU cleanup unqualified; live controller custody retained:',root,flush=True)
    best_effort(announce)
    while True:
        try: time.sleep(30)
        except (Exception,KeyboardInterrupt,FixtureTimeout): pass

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',required=True)
    parser.add_argument('--output',required=True)
    args=parser.parse_args()
    # No caller module, callback, service or actual native wrapper is imported.
    pin=subprocess.check_output(['git','-C',str(REPO),'rev-parse','HEAD'],timeout=3).decode().strip()
    if len(args.source)!=40 or args.source!=pin:
        parser.error('Exact source pin required')
    if subprocess.run(['git','-C',str(REPO),'diff','--quiet','HEAD','--',*SOURCES],timeout=3).returncode:
        parser.error('Reserved helper sources must match the recorded commit')
    root=Path(args.output)
    if root!=root.resolve() or root.parent!=Path('/private/tmp') or not root.name.startswith('baton-tbx9312-') or root.exists():
        parser.error('Fresh canonical private CPU output required')
    os.umask(0o077); root.mkdir(mode=0o700)
    write_receipt(root/'source.json',{'commit':pin,'sourceSHA256':{
        p:hashlib.sha256((REPO/p).read_bytes()).hexdigest() for p in SOURCES},
        'scope':'Single actual CPU exited-child reservation; no callback, legacy caller or native acceptance'})
    # This synthetic qualification alone has short bounds. Ordinary native
    # Deadline defaults remain 900 total / 810 active / 90 cleanup.
    deadline=Deadline(total=10,reserve=5)
    owned=ReservedOwnedFixture(root,{'PATH':'/usr/bin:/bin'},deadline)
    def cancel(_signum,_frame):
        best_effort(write_receipt,root.with_name(root.name+'.cancel-requested'),{'requested':True})
    for sig in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]: signal.signal(sig,cancel)
    deadline.arm(); result=1; cleanup=None
    try:
        child=owned.start([sys.executable,'-c','pass'])
        end=min(deadline.active_end,time.monotonic()+2)
        observed=None
        while time.monotonic()<end:
            observed=os.waitid(os.P_PID,child.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT)
            if observed is not None: break
            time.sleep(min(.005,deadline.remaining()))
        if (observed is None or observed.si_pid!=child.pid or observed.si_code!=os.CLD_EXITED or
            observed.si_status!=0 or child.returncode is not None or
            owned.groups[0].get('sessionVerified') is not True):
            raise RuntimeError('Owned exited-child precondition refused')
        write_receipt(root/'exited-reservation.json',{'pid':child.pid,'positiveDirectChildExit':True,
            'exitCode':observed.si_status,'leaderUnreaped':True,'stoppedSessionVerified':True})
        rc=owned.wait(child,cap=2)
        entry=owned.groups[0]
        if (rc!=0 or child.returncode!=0 or not entry['closed'] or entry['reservedLeader'] or
            entry['supervision']['leaderReaped'] is not True or
            entry['supervision']['ownedGroupPending'] is not False or
            entry['supervision']['inspectionProcessPending'] is not False):
            raise RuntimeError('Owned exited-child supervision refused')
        result=0
    except (Exception,FixtureTimeout,KeyboardInterrupt) as error:
        best_effort(write_failure,root/'failure.json',error,'setup','command')
    finally:
        try:
            cleanup=owned.cleanup()
            if not qualified(cleanup): result=1
        except (Exception,FixtureTimeout,KeyboardInterrupt) as error:
            result=1
            best_effort(write_failure,root/'cleanup-failure.json',error,'cleanup','cleanup')
        receipt={'exitCode':result,'cleanupQualified':qualified(cleanup),
            'totalBoundSeconds':10,'activeSeconds':5,'cleanupReserveSeconds':5,
            'elapsedSeconds':time.monotonic()-deadline.started,'SDKCommands':0,
            'guardAcquisitions':0,'legacyCallerOrCallbackRuns':0}
        if not qualified(cleanup): retain_custody(root,deadline,receipt)
        deadline.disarm()
        write_receipt(root/'cpu-result.json',receipt)
    print('Owned CPU result:',root/'cpu-result.json')
    return result

if __name__=='__main__': sys.exit(main())
