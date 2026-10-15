"""Bounded ownership and cleanup for the opt-in incoming iPhone fixture only."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time


class FixtureTimeout(BaseException):
    pass


class Deadline:
    def __init__(self, total=900, reserve=90, clock=time.monotonic):
        self.clock = clock
        self.started = clock()
        self.active_end = self.started + total - reserve
        self.hard_end = self.started + total
        self.cleaning = False
        self.reserve = reserve
        self.cleanup_end = self.hard_end
    def remaining(self, cap=None):
        value = (self.cleanup_end if self.cleaning else self.active_end) - self.clock()
        if value <= 0: raise FixtureTimeout()
        return min(value, cap) if cap is not None else value
    def arm(self):
        signal.signal(signal.SIGALRM, self.alarm)
        signal.setitimer(signal.ITIMER_REAL, self.remaining())
    def alarm(self, signum, frame):
        if self.clock() >= self.hard_end - .001:
            # Ownership/uncertainty was persisted before every launch. Do not run
            # arbitrary handlers or assume cleanup succeeded at this hard bound.
            os._exit(124)
        signal.setitimer(signal.ITIMER_REAL, max(.001, self.hard_end - self.clock()))
        raise FixtureTimeout()
    def enter_cleanup(self):
        self.cleaning = True
        self.cleanup_end = min(self.hard_end,self.clock()+self.reserve)
        signal.setitimer(signal.ITIMER_REAL, max(.001, self.cleanup_end - self.clock()))
    def disarm(self):
        signal.setitimer(signal.ITIMER_REAL, 0)


def write_receipt(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.pending')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(value, output, indent=2)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


FAILURE_CODES = frozenset({'unclassified', 'owned-group-registration',
    'owned-launch-handshake', 'owned-command-timeout', 'owned-command-nonzero',
    'cache-validation-refused', 'deadline-expired', 'interrupted'})
FAILURE_STAGES = frozenset({'unknown', 'setup', 'cache', 'media', 'service',
    'catalog', 'simulator', 'sdk', 'ui', 'cleanup'})
FAILURE_OPERATIONS = frozenset({'unknown', 'command', 'cache-validation',
    'cache-copy', 'cache-head', 'cache-diff', 'manifest-read', 'media-generate',
    'service-start', 'catalog-read', 'simulator-start', 'sdk-build', 'ui-tests',
    'result-read', 'cleanup'})


class FixtureDiagnosticFailure(RuntimeError):
    """Fixed failure code; compatible with existing RuntimeError handlers."""
    def __init__(self, code, message):
        self.diagnostic_code = code if type(code) is str and code in FAILURE_CODES else 'unclassified'
        super().__init__(message)


def _allowed(value, allowed, fallback):
    return value if type(value) is str and value in allowed else fallback


def write_failure(path, error, stage='unknown', operation='unknown'):
    # Never serialize exception text/class names supplied by a caller, argv,
    # stdout, environment or source paths. Unknown inputs fail closed.
    known = (RuntimeError, ValueError, OSError, KeyboardInterrupt, FixtureTimeout)
    kind = next((base.__name__ for base in known if isinstance(error, base)), 'UnknownError')
    code = 'unclassified'
    if isinstance(error, FixtureDiagnosticFailure):
        code = _allowed(error.diagnostic_code, FAILURE_CODES, 'unclassified')
    elif isinstance(error, FixtureTimeout): code = 'deadline-expired'
    elif isinstance(error, KeyboardInterrupt): code = 'interrupted'
    write_receipt(path, {'kind':kind, 'stage':_allowed(stage, FAILURE_STAGES, 'unknown'),
        'operation':_allowed(operation, FAILURE_OPERATIONS, 'unknown'), 'code':code,
        'diagnostics':'Private receipts retained; no configuration values emitted'})


def group_exists(group):
    try: os.killpg(group, 0)
    except ProcessLookupError: return False
    except PermissionError: return True
    return True


class OwnedFixture:
    def __init__(self, root, env, deadline):
        self.root, self.env, self.deadline = Path(root), env, deadline
        self.groups = []
        self.processes = []
        self.container_name = None
        self.container_id = None
        self.simulator_name = None
        self.simulator = None
        self.scheme = None
        self.scheme_bytes = None
        self.scheme_mode = None
        self.cleanup_state = 'not started; ownership retained, cleanup not qualified'
        self.receipt()
    def receipt(self):
        write_receipt(self.root/'ownership.json', {
            'supervisorPID':os.getpid(), 'groups':self.groups,
            'containerName':self.container_name, 'containerID':self.container_id,
            'simulatorName':self.simulator_name, 'simulatorUUID':self.simulator,
            'scheme':str(self.scheme) if self.scheme else None,
            'cleanup':self.cleanup_state,
            'deadlinePolicy':{'totalSeconds':self.deadline.hard_end-self.deadline.started,
                              'activeSeconds':self.deadline.active_end-self.deadline.started,
                              'reservedCleanupSeconds':self.deadline.reserve,
                              'hardExit':124,'missingSuccessfulCleanupReceiptMeansUncertain':True}})
    def start(self, argv, childenv=None, output=subprocess.DEVNULL, stderr=subprocess.STDOUT):
        self.deadline.remaining()
        # Stop this new, independently owned process group before exec. Register
        # its exact PID/PGID durably before any tool/service/native launch.
        process = subprocess.Popen(['/bin/sh','-c','kill -STOP $$; exec "$@"','incoming-fixture',*argv],
            env=childenv or self.env, stdin=subprocess.DEVNULL, stdout=output,
            stderr=stderr, start_new_session=True)
        self.processes.append(process)
        entry = {'pid':process.pid,'pgid':process.pid,'tool':Path(argv[0]).name,'closed':False,'started':False}
        self.groups.append(entry)
        self.receipt()
        if os.getpgid(process.pid) != process.pid:
            raise FixtureDiagnosticFailure('owned-group-registration', 'Owned group registration failed')
        while True:
            self.deadline.remaining()
            pid,status = os.waitpid(process.pid,os.WNOHANG | os.WUNTRACED)
            if pid:
                if not os.WIFSTOPPED(status):
                    raise FixtureDiagnosticFailure('owned-launch-handshake', 'Owned launch handshake failed')
                break
            time.sleep(min(.01,self.deadline.remaining()))
        entry['started'] = True
        self.receipt()
        os.killpg(process.pid,signal.SIGCONT)
        return process
    def finished(self, process):
        for entry in self.groups:
            if entry['pid'] == process.pid:
                # Once an exact group is observed absent it is never signalled
                # again, even if an unrelated future process reuses this number.
                if not group_exists(entry['pgid']): entry['closed'] = True
                entry['exitCode'] = process.returncode
                break
        self.receipt()
    def command(self, argv, childenv=None, cap=120, accept_failure=False, stdout_only=False):
        capture = None
        try:
            if stdout_only:
                # Exact data callers must not parse diagnostics as response bytes.
                # Retain stderr only in the private owned directory, never receipts.
                path = self.root / ('command-stderr-%04d.log' % len(self.groups))
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                capture = os.fdopen(fd, 'wb')
            process = self.start(argv, childenv, subprocess.PIPE,
                                 stderr=capture if capture is not None else subprocess.STDOUT)
            try: output,_ = process.communicate(timeout=self.deadline.remaining(cap))
            except subprocess.TimeoutExpired:
                raise FixtureDiagnosticFailure('owned-command-timeout', 'Owned command timed out; exact group retained') from None
            finally:
                if process.poll() is not None: self.finished(process)
            if process.returncode != 0 and not accept_failure:
                raise FixtureDiagnosticFailure('owned-command-nonzero', 'Owned command failed; private output withheld')
            return output,process.returncode
        finally:
            if capture is not None: capture.close()
    def snapshot_scheme(self, path):
        self.scheme = Path(path)
        self.scheme_bytes = self.scheme.read_bytes()
        self.scheme_mode = self.scheme.stat().st_mode & 0o777
        # This baseline has no fixture variables; it remains only private evidence.
        (self.root/'scheme-before.xml').write_bytes(self.scheme_bytes)
        self.receipt()
    def restore_scheme(self):
        if self.scheme is None: return True
        # The runtime never injects variables into a scheme. Still restore the
        # exact generated bytes if this fixture's own operations changed them.
        if self.scheme.read_bytes() != self.scheme_bytes:
            self.scheme.write_bytes(self.scheme_bytes)
            self.scheme.chmod(self.scheme_mode)
        return self.scheme.read_bytes() == self.scheme_bytes
    def stop_groups(self):
        failures=[]
        open_groups=[entry for entry in self.groups if not entry['closed']]
        for entry in open_groups:
            if not group_exists(entry['pgid']): entry['closed']=True; continue
            try:
                # A pre-exec stopped wrapper must never be resumed into a launch
                # during failed setup; kill only its registered own group.
                os.killpg(entry['pgid'],signal.SIGTERM if entry['started'] else signal.SIGKILL)
            except ProcessLookupError: pass
        end=min(self.deadline.hard_end,self.deadline.clock()+8)
        while self.deadline.clock()<end:
            for process in self.processes: process.poll()
            if all(entry['closed'] or not group_exists(entry['pgid']) for entry in open_groups): break
            time.sleep(min(.05,self.deadline.remaining()))
        for entry in open_groups:
            if entry['closed']: continue
            if group_exists(entry['pgid']):
                try: os.killpg(entry['pgid'],signal.SIGKILL)
                except ProcessLookupError: pass
        end=min(self.deadline.hard_end,self.deadline.clock()+4)
        while self.deadline.clock()<end:
            for process in self.processes: process.poll()
            if all(entry['closed'] or not group_exists(entry['pgid']) for entry in open_groups): break
            time.sleep(min(.05,self.deadline.remaining()))
        for entry in open_groups:
            entry['closed']=entry['closed'] or not group_exists(entry['pgid'])
            if not entry['closed']: failures.append('registered group '+str(entry['pgid'])+' still present')
        for process in self.processes:
            if process.poll() is not None:
                for pipe in (process.stdin,process.stdout,process.stderr):
                    if pipe is not None and not pipe.closed: pipe.close()
        self.receipt()
        return failures
    def inventory(self):
        output,_=self.command(['xcrun','simctl','list','devices','-j'],cap=8)
        return [device for devices in json.loads(output)['devices'].values() for device in devices]
    def containers(self):
        output,_=self.command(['docker','container','ls','--all','--no-trunc','--format','{{.ID}} {{.Names}}'],cap=8)
        entries=[]
        for line in output.decode().splitlines():
            parts=line.split(maxsplit=1)
            if len(parts)!=2 or len(parts[0])!=64: raise RuntimeError('Container inventory malformed')
            entries.append(parts)
        return entries
    def cleanup(self):
        self.deadline.enter_cleanup()
        self.cleanup_state='in progress; absence not yet qualified'
        self.receipt()
        failures=[]
        scheme_restored=False; simulator_absent=None; container_absent=None
        try: scheme_restored=self.restore_scheme()
        except Exception: failures.append('exact generated scheme restoration')
        failures += self.stop_groups()
        # Creation may have completed without stdout (for example timeout). The
        # pre-registered unique namespace is retained before creating anything.
        if self.simulator_name:
            try:
                devices=self.inventory()
                matching=[d for d in devices if d['name']==self.simulator_name]
                if self.simulator is None:
                    if len(matching)>1: raise RuntimeError('Ambiguous own simulator namespace')
                    if matching: self.simulator=matching[0]['udid']; self.receipt()
                if self.simulator:
                    for operation,cap in [('terminate',5),('shutdown',12),('delete',12)]:
                        argv=['xcrun','simctl',operation,self.simulator]
                        if operation=='terminate': argv.append('io.tonebox.baton')
                        self.command(argv,cap=cap,accept_failure=True)
                simulator_absent=not any(d['udid']==self.simulator or d['name']==self.simulator_name for d in self.inventory())
                if not simulator_absent: failures.append('own simulator still present')
            except Exception: failures.append('own simulator removal/independent absence uncertain')
        if self.container_name:
            try:
                entries=self.containers()
                matching=[entry for entry in entries if entry[1]==self.container_name]
                if self.container_id is None:
                    if len(matching)>1: raise RuntimeError('Ambiguous own container namespace')
                    if matching: self.container_id=matching[0][0]; self.receipt()
                if self.container_id: self.command(['docker','rm','-f',self.container_id],cap=10,accept_failure=True)
                container_absent=not any(cid==self.container_id or name==self.container_name for cid,name in self.containers())
                if not container_absent: failures.append('own container still present')
            except Exception: failures.append('own container removal/independent absence uncertain')
        # Include cleanup/control command groups too, and check descendants even
        # when their immediate subprocess parent exited successfully.
        failures += self.stop_groups()
        groups_absent=all(entry['closed'] for entry in self.groups)
        try:
            scheme_restored=self.restore_scheme()
            if not scheme_restored: failures.append('exact generated scheme final readback')
        except Exception: failures.append('exact generated scheme final readback')
        self.cleanup_state='qualified' if not failures and scheme_restored and groups_absent else 'incomplete; retained exact namespace requires follow-up'
        self.receipt()
        receipt={'failures':failures,'schemeRestoredExactly':scheme_restored,'simulatorAbsent':simulator_absent,
                 'containerAbsent':container_absent,'registeredGroupsAbsent':groups_absent,
                 'productionSharesCreated':0,'ownerStateTouched':False}
        write_receipt(self.root/'incoming-cleanup.json',receipt)
        return receipt
