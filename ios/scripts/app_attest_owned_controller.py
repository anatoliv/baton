"""One accepted App Attest original-parent adapter; import/configuration is inert.

Custody function bodies are byte-identical extractions from accepted9cdb1375.
No compiler/guard/device call occurs on import. One owning Python parent configures
this module once; it is not a concurrent or independently executing driver.
"""
import hashlib,importlib.util,json,os,signal,stat,subprocess,sys,time
from pathlib import Path
from types import SimpleNamespace
ROOT = None
REPO = None
SHARED = None
CANCELLED = False

def configure(root, repo):
    global ROOT, REPO, SHARED, CANCELLED
    ROOT = Path(root)
    REPO = Path(repo)
    SHARED = REPO / 'scripts'
    CANCELLED = False

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_file(path, data):
    with path.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def require(value, message):
    if not value:
        raise RuntimeError(message)


def cancel_requested():
    return CANCELLED or (ROOT / 'cancel-requested').exists()


def record_cancel(signum, frame):
    global CANCELLED
    # Never raise into Popen or reap its child outside the reviewed supervisor.
    CANCELLED = True


def supervisor():
    # Exact accepted shared source modules, never the physical TEMPLATE main.
    # All three import dependencies are pinned before any output/child birth.
    pins = json.loads((ROOT / 'input-pins.json').read_bytes())['inputSHA256']
    loaded = {}
    names = ['incoming_fixture_lifecycle', 'mixtape_owned_supervision', 'mixtape_owned_lifecycle']
    for name in names:
        path = SHARED / (name + '.py')
        require(path.is_file() and not path.is_symlink() and
                digest(path) == pins[str(path)], 'shared custody source identity changed')
    for name in names:
        path = SHARED / (name + '.py')
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
        loaded[name] = module
    return SimpleNamespace(wait_owned=loaded['mixtape_owned_supervision'].wait_owned,
        retain_custody=loaded['mixtape_owned_lifecycle'].retain_custody)


def retain_original(runner):
    # This controller uses monotonic phase clocks, never an armed exit timer.
    # Reuse the exact accepted retainer; absorb even a setup/handler failure so
    # it cannot return the original Python direct-child parent into shell-only hold.
    deadline = SimpleNamespace(disarm=lambda: None)
    while True:
        try:
            runner.retain_custody(ROOT, deadline)
        except BaseException:
            pass
        try:
            time.sleep(30)
        except BaseException:
            pass


def stopped_original(child):
    require(child.returncode is None, 'original child already reaped')
    observed = os.waitid(os.P_PID, child.pid,
        os.WSTOPPED | os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if observed is not None:
        require(observed.si_pid == child.pid and observed.si_code == os.CLD_STOPPED,
                'original direct-child stopped handshake refused')
    return observed


def stage(name, command, runner, environment, deadline, execution, outer, reserve, custody):
    require(not cancel_requested(), 'cancellation requested')
    require(deadline - time.monotonic() >= outer + reserve, 'window reserve insufficient')
    started = time.monotonic()
    phase_deadline = min(started + outer, deadline - reserve)
    with (ROOT / (name + '.log')).open('xb') as stream:
        custody.update(unknown=True, launchUncertain=True, sessionVerified=False, phase=name)
        private_file(ROOT / (name + '-launch-uncertain.json'),
            b'{"launchUncertain":true,"sessionVerified":false}\n')
        # Stop before exec. start_new_session is a request, not ownership proof.
        child = subprocess.Popen(['/bin/sh', '-c', 'kill -STOP $$; exec "$@"',
                    'app-attest-compiler', *command], cwd=REPO, stdout=stream,
                    stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                    start_new_session=True, env=environment)
        # Retain returned Popen objects even if registration/handshake throws.
        # Popen.__del__ may otherwise poll/reap an exited leader before hold.
        custody.setdefault('_processes', []).append(child)
        custody['candidatePID'] = child.pid
        private_file(ROOT / (name + '-owned-start.json'),
            (json.dumps({'candidatePID': child.pid, 'phase': name,
                'launchUncertain': True, 'sessionVerified': False}) + '\n').encode())
        require(child.pid != os.getpgrp() and os.getpgid(child.pid) == child.pid,
                'new stopped session not verified')
        while stopped_original(child) is None:
            require(time.monotonic() < min(started + execution, phase_deadline),
                    'stopped handshake deadline')
            time.sleep(.01)
        private_file(ROOT / (name + '-session-verified.json'),
            (json.dumps({'candidatePID': child.pid, 'registeredGroup': child.pid,
                'sessionVerified': True, 'launchUncertain': False,
                'directChildStoppedUnreaped': True}) + '\n').encode())
        # Clear only after exact original child/session registration is durable.
        custody['launchUncertain'] = False
        custody['sessionVerified'] = True
        if not cancel_requested():
            require(stopped_original(child) is not None,
                    'original reservation lost before resume')
            # WNOWAIT can deliver a handled cancellation before it returns.
            # Recheck after positive reservation, immediately before resume.
            if not cancel_requested():
                os.killpg(child.pid, signal.SIGCONT)
        remaining = phase_deadline - time.monotonic()
        require(remaining > 0, 'owned supervision deadline')
        outcome = runner.wait_owned(child,
            execution_seconds=0 if cancel_requested() else max(0, min(started + execution, phase_deadline) - time.monotonic()),
            outer_seconds=remaining, registered_group=child.pid, cancelled=cancel_requested)
        custody['unknown'] = not (
            custody['launchUncertain'] is False and
            outcome.get('cleanupComplete') is True and outcome.get('leaderReaped') is True and
            outcome.get('ownedGroupPending') is False and outcome.get('inspectionProcessPending') is False)
        custody['lastOutcome'] = {key: value for key, value in outcome.items() if key != 'restoreRequired'}
        # Uncertain cleanup must reach original-parent hold before diagnostic I/O.
        if custody['unknown']:
            retain_original(runner)
    row = {'phase': name, 'ownedPID': child.pid, **outcome}
    row.pop('restoreRequired', None)
    try:
        private_file(ROOT / (name + '-supervision.json'),
                     (json.dumps(row, sort_keys=True, indent=2) + '\n').encode())
    except BaseException:
        retain_original(runner)
    return row
