"""Bounded simulator teardown for the composer harness (TBX-1000000540).

Under heavy load an `xcrun simctl` cleanup step can outlive its cap, or exit and be left
unreaped. The reserved fixture treated either as an unknown outcome: the delete never ran, the
simulator's absence was never checked, and the controller kept the gate and probe locks until
someone ended it by hand.

Here a teardown step (terminate, shutdown, delete, and the device inventory) that overruns its
cap is still bounded by the ordinary reserved supervision: its own group is ended and its
leader reaped. If that first pass leaves the leader unreaped (an exited leader whose group
inspection overran, which Darwin then refuses to signal), one more bounded pass reaps it. Only
then is the timeout tolerated, and only a fresh device inventory that no longer lists the
simulator lets cleanup qualify, with one bounded retry of the delete. Anything less (a group
still present, an unreaped child, an inventory that cannot be read, the simulator still listed,
or the cleanup reserve spent) keeps custody exactly as before.

The three shared lifecycle modules are pinned by digest elsewhere (the App Attest packet,
ios/scripts/prepare-app-attest-next-attempt.py), so this subclass changes nothing they define.
"""
import json
import time

from incoming_fixture_lifecycle import FixtureDiagnosticFailure, write_receipt
from mixtape_owned_lifecycle import ReservedOwnedFixture
import mixtape_owned_supervision as supervision

TEARDOWN = ('terminate', 'shutdown', 'delete')


def reap_finished_inspections():
    """Drop group inspections (our own `ps` children) that have exited since they overran.

    One that overran its bound and was not reaped in time otherwise stays pending for the life
    of the controller and marks every later supervision incomplete. poll() only reaps our own
    exited child; nothing is signalled.
    """
    for inspection in list(supervision.PENDING_INSPECTIONS):
        if inspection.poll() is not None:
            supervision.PENDING_INSPECTIONS.remove(inspection)


class BoundedTeardownFixture(ReservedOwnedFixture):
    SIMCTL_TEARDOWN_CAPS = {'list': 8, 'terminate': 5, 'shutdown': 12, 'delete': 12}
    INVENTORY_ATTEMPTS = 3
    READBACK_ATTEMPTS = 3

    def __init__(self, root, env, deadline):
        self.simulator_teardown = []
        self.delete_retried = False
        super().__init__(root, env, deadline)

    def command(self, argv, childenv=None, cap=120, accept_failure=False, stdout_only=False):
        if (self.deadline.cleaning and self.simulator and argv[:2] == ['xcrun', 'simctl']
                and len(argv) >= 4 and argv[2] in TEARDOWN and argv[3] == self.simulator):
            return self.teardown(argv)
        return super().command(argv, childenv, cap, accept_failure, stdout_only)

    def inventory(self):
        if not self.deadline.cleaning:
            return super().inventory()
        for _ in range(self.INVENTORY_ATTEMPTS):
            output, rc = self.step(['xcrun', 'simctl', 'list', 'devices', '-j'], stdout_only=True)
            if output is not None and rc == 0:
                try:
                    return [device for devices in json.loads(output)['devices'].values() for device in devices]
                except (ValueError, KeyError, TypeError, AttributeError):
                    self.simulator_teardown[-1]['unreadable'] = True
        raise FixtureDiagnosticFailure('owned-command-timeout', 'Simulator inventory unavailable within its bound')

    def teardown(self, argv):
        result = self.step(argv)
        if argv[2] == 'delete' and not self.delete_retried:
            self.delete_retried = True
            listed = any(d['udid'] == self.simulator or d['name'] == self.simulator_name for d in self.inventory())
            # Retry once, and only when the reserve still covers one bounded pass (its cap plus
            # wait_owned's 15 s outer margin, which includes the TERM grace and the reap) with
            # 10 s to spare. A retry that also needs a second pass or the readback can outrun
            # the reserve; that ends in FixtureTimeout and kept custody, never a release.
            if listed and self.deadline.remaining() > self.SIMCTL_TEARDOWN_CAPS['delete'] + 25:
                result = self.step(argv)
        return result

    def step(self, argv, stdout_only=False):
        """One bounded simctl step. A timeout is tolerated only once its own child is reaped
        and its group observed absent; otherwise the original failure stands."""
        operation = argv[2]
        cap = self.SIMCTL_TEARDOWN_CAPS[operation]
        index = len(self.groups)
        record = {'operation': operation, 'capSeconds': cap, 'timedOut': False, 'secondPass': False, 'readback': False}
        self.simulator_teardown.append(record)
        reap_finished_inspections()
        output = rc = None
        try:
            output, rc = super().command(argv, cap=cap, accept_failure=True, stdout_only=stdout_only)
        except FixtureDiagnosticFailure as error:
            entry = self.groups[index] if len(self.groups) > index else None
            # Only a timeout, or a first pass that left the child unreaped, is bounded here.
            if (entry is None or self.launch_uncertain or
                    error.diagnostic_code not in ('owned-command-timeout', 'owned-group-registration')):
                raise
            if not entry['closed']:
                record['secondPass'] = self.second_pass(entry)
            if not entry['closed']:
                record['readback'] = self.readback(entry)
            if not entry['closed']:
                raise
            record['timedOut'] = True
        outcome = self.groups[index].get('supervision', {})
        record.update(exitCode=rc, childReaped=outcome.get('leaderReaped') is True,
                      groupAbsent=outcome.get('ownedGroupPending') is False)
        self.receipt()
        return output, rc

    def second_pass(self, entry):
        process = next((p for p in self.processes if p.pid == entry['pid']), None)
        # The same reservation rule as stop_groups: only our own still-unreaped leader.
        if process is None or process.returncode is not None or not entry.get('reservedLeader'):
            return False
        reap_finished_inspections()
        try:
            self.wait(process, cleaning=True)
        except FixtureDiagnosticFailure:
            pass
        return True

    def readback(self, entry):
        """Close an entry whose leader is already reaped but whose group absence went unconfirmed
        (a `ps` inspection overran after the reap), by inspection alone (TBX-1000000540).

        A reaped PID may be reused, so nothing is signalled. A process group id cannot be reused
        while any member of the group exists, so an observed absence means our group is gone; an
        id seen present, ours or a newcomer's, or an inspection still pending, keeps custody.
        """
        process = next((p for p in self.processes if p.pid == entry['pid']), None)
        outcome = dict(entry.get('supervision') or {})
        if (entry['closed'] or process is None or process.returncode is None
                or outcome.get('leaderReaped') is not True):
            return False
        for attempt in range(self.READBACK_ATTEMPTS):
            if attempt: time.sleep(min(.5, self.deadline.remaining()))
            reap_finished_inspections()
            try:
                present = supervision.group_present(entry['pgid'], time.monotonic() + min(5, self.deadline.remaining()))
            except (TimeoutError, RuntimeError):
                continue
            reap_finished_inspections()
            if not present and not supervision.PENDING_INSPECTIONS:
                outcome.update(ownedGroupPending=False, inspectionProcessPending=False,
                               cleanupComplete=True, readbackAfterReap=True)
                entry.update(supervision=outcome, closed=True, reservedLeader=False)
                self.receipt()
                return True
        return False

    def stop_groups(self):
        # Reaped leaders whose absence went unconfirmed get the read-only recheck first; the
        # inherited rule then still refuses to signal anything it cannot reserve.
        for entry in self.groups:
            if not entry['closed']:
                self.readback(entry)
        return super().stop_groups()

    def cleanup(self):
        cleanup = super().cleanup()
        cleanup['simulatorTeardown'] = self.simulator_teardown
        cleanup['simulatorAbsenceConfirmed'] = cleanup.get('simulatorAbsent') is True
        cleanup['cleanupBoundSeconds'] = self.deadline.reserve
        write_receipt(self.root / 'incoming-cleanup.json', cleanup)
        return cleanup
