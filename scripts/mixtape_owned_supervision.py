"""Reviewed reserved-leader supervision; no SDK/guard acquisition on import."""
import os,signal,subprocess,time,tempfile
PENDING_INSPECTIONS=[]

def group_present(group, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('group inspection deadline')
    with tempfile.TemporaryFile() as output:
        inspection = subprocess.Popen(['/bin/ps', '-axo', 'pid=,pgid=,stat='],
                                      stdout=output, stderr=subprocess.DEVNULL)
        try:
            rc = inspection.wait(timeout=min(1, remaining))
        except subprocess.TimeoutExpired:
            inspection.kill()
            remaining = deadline - time.monotonic()
            try:
                if remaining <= 0:
                    raise TimeoutError('inspection reap deadline')
                inspection.wait(timeout=min(.25, remaining))
            except (TimeoutError, subprocess.TimeoutExpired):
                PENDING_INSPECTIONS.append(inspection)
            raise TimeoutError('group inspection timed out')
        if rc != 0:
            raise RuntimeError('group inspection failed')
        output.seek(0)
        metadata = output.read(2 * 1024 * 1024 + 1)
        if len(metadata) > 2 * 1024 * 1024:
            raise RuntimeError('group metadata bound')
    return any(len(fields := line.split()) == 3 and int(fields[1]) == group
               and not fields[2].startswith(b'Z') for line in metadata.splitlines())

def wait_owned(process, execution_seconds=220, outer_seconds=230, term_seconds=5, cancelled=None, registered_group=None, on_tick=None):
    started = time.monotonic()
    deadline = started + outer_seconds
    outcome = {'testExit': 1, 'timedOut': False, 'restoreRequired': True,
               'cleanupComplete': False, 'ownedGroupPending': True,
               'leaderReaped': False, 'groupTeardownAttempted': False}
    # Popen(start_new_session=True) is the only supported caller. Keeping this
    # child unreaped reserves its PID until all group signals are complete. Do
    # not poll()/wait() earlier: leader exit alone is not descendant completion.
    ownership_established = False
    def reserved_child():
        # WNOWAIT proves this PID is still our direct unreaped child. A numeric
        # group lookup alone cannot authorize signalling a reused identifier.
        observed=os.waitid(os.P_PID,process.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT)
        if observed is not None and observed.si_pid!=process.pid:
            raise RuntimeError('direct child identity mismatch')
        return observed
    try:
        if process.pid == os.getpgrp():
            raise RuntimeError('new-session ownership not established')
        try:
            group=os.getpgid(process.pid)
        except ProcessLookupError:
            # Darwin can refuse getpgid for an exited, still-unreaped child.
            # Accept only the exact session previously verified at stopped birth
            # AND a positive direct-child exit observation; arbitrary ESRCH or
            # current PID absence is never evidence of reservation.
            exited=reserved_child()
            if (type(registered_group) is not int or registered_group!=process.pid or
                exited is None or exited.si_code not in (os.CLD_EXITED,os.CLD_KILLED,os.CLD_DUMPED)):
                raise RuntimeError('exited child session reservation unqualified') from None
            group=registered_group
        if group!=process.pid:
            raise RuntimeError('new-session ownership not established')
        reserved_child()
        ownership_established = True
        while time.monotonic() < min(started + execution_seconds, deadline):
            if cancelled is not None and cancelled():
                outcome['cancelled'] = True
                break
            # Synchronous delivery/monitoring stays on the owning controller.
            # Nested commands use their own reserved entries, never this child.
            if on_tick is not None:
                on_tick()
                if cancelled is not None and cancelled():
                    outcome['cancelled'] = True
                    break
            exited = reserved_child()
            if exited is not None:
                break
            time.sleep(min(.05, max(0, min(started + execution_seconds, deadline) - time.monotonic())))
        else:
            outcome['timedOut'] = True
        members = group_present(process.pid, deadline)
        if members:
            outcome['groupTeardownAttempted'] = True
            reserved_child()
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            grace = min(time.monotonic() + term_seconds, deadline - .1)
            while members and time.monotonic() < grace:
                time.sleep(min(.05, max(0, grace - time.monotonic())))
                members = group_present(process.pid, deadline)
            if members:
                # The leader is still our unreaped child, even if it exited on
                # TERM. Its reserved PID makes this original group safe to kill.
                reserved_child()
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('bounded reap deadline')
        rc = process.wait(timeout=min(5, remaining))
        outcome['leaderReaped'] = True
        outcome['testExit'] = 124 if outcome['timedOut'] else rc
        # No more group signals after reap: the original PID is now reusable.
        # Readback can fail closed, but must never kill an unqualified new group.
        while group_present(process.pid, deadline) and time.monotonic() < deadline:
            time.sleep(min(.05, max(0, deadline - time.monotonic())))
        outcome['ownedGroupPending'] = group_present(process.pid, deadline)
        outcome['cleanupComplete'] = not outcome['ownedGroupPending']
    except Exception as error:
        outcome.update(errorClass=type(error).__name__, privateDetailsWithheld=True)
        # Inspection failure also gets a bounded owned-group shutdown, provided
        # its reserved, unreaped leader still establishes ownership.
        if ownership_established and not outcome['leaderReaped']:
            try:
                reserved_child()
                os.killpg(process.pid, signal.SIGKILL)
                remaining = deadline - time.monotonic()
                if remaining > 0:
                    process.wait(timeout=min(5, remaining))
                    outcome['leaderReaped'] = True
                    outcome['ownedGroupPending'] = group_present(process.pid, deadline)
                    outcome['cleanupComplete'] = not outcome['ownedGroupPending']
            except Exception:
                pass
        if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)):
            outcome['timedOut'] = True
            outcome['testExit'] = 124
    outcome['inspectionProcessPending'] = bool(PENDING_INSPECTIONS)
    if PENDING_INSPECTIONS:
        outcome['cleanupComplete'] = False
    outcome['seconds'] = round(time.monotonic() - started, 3)
    return outcome
