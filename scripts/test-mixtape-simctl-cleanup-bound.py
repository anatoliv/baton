#!/usr/bin/env python3
"""The composer harness releases its gate and probe locks once a hung or defunct `simctl`
cleanup child is reaped and its simulator is confirmed gone (TBX-1000000540).

Each case runs the real scripts/probe-mixtape-composer-flow.sh, with three changes only: its
`unset` of the lock-path variables is dropped so the locks live in a private directory, never
/tmp/baton-gate.lock or /tmp/baton-probe.lock; SCRIPT_DIR names this checkout's scripts; and
its python child is a stub controller. That stub builds the composer controller's own fixture
class and deadline, registers a simulator, and then runs the controller's real final routing
(the `finally:` block of probe-mixtape-composer-flow.py, extracted from the source), so
cleanup, custody, the release qualifier and the lock libraries are all the real ones. Only
`xcrun` is a stub on PATH, which keeps a fake device list and misbehaves as each case says:

  hang            shutdown hangs (dies on TERM); delete deletes, then hangs ignoring TERM
  zombie          delete deletes, leaves a defunct child, and its leader hangs ignoring TERM
  defunct-leader  delete deletes and exits, and the first group inspection after it overruns
                  (a slow `ps` under load), which used to leave the exited leader unreaped
  ps-overrun-after-reap
                  delete deletes and exits, and the inspection after its leader is reaped overruns:
                  the group can then only be confirmed gone by a read-only recheck, no signal
  stuck           delete hangs ignoring TERM and never deletes: the simulator is still there,
                  so custody must be kept and both locks stay held

No real simulator, Docker, SDK or shared lock is touched. Run: python3 scripts/test-mixtape-simctl-cleanup-bound.py
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parent.parent
WRAPPER = REPO / 'scripts/probe-mixtape-composer-flow.sh'
UDID = '5E1F0000-0000-4000-8000-00000000C0DE'
NAME = 'Baton Mixtape Composer stub-cleanup-bound'
# Small step caps keep the cases quick. The real ones are the class defaults; the bound that
# matters for the shared locks is the cleanup reserve, and the test asserts against it.
CAPS = {'list': 2, 'terminate': 1, 'shutdown': 2, 'delete': 2}
TOTAL, RESERVE = 120, 45
SLACK = 8   # wrapper start, lock acquisition, qualifier and release, on a loaded machine

STUB_XCRUN = '''#!{python}
import json, os, signal, sys, time
from pathlib import Path
state = Path(os.environ['STUB_SIMCTL_STATE']); mode = os.environ['STUB_SIMCTL_MODE']
devices = state / 'devices.json'
if sys.argv[1:2] != ['simctl']: sys.exit(64)
op = sys.argv[2]
with open(state / 'calls.log', 'a') as log: log.write(op + '\\n')
def hang(ignore_term):
    if ignore_term: signal.signal(signal.SIGTERM, signal.SIG_IGN)
    end = time.monotonic() + 60          # bounded, so no stub outlives a failed case for long
    while time.monotonic() < end: time.sleep(.2)
    sys.exit(0)
def delete():
    data = json.loads(devices.read_text())
    for runtime in data['devices'].values():
        runtime[:] = [d for d in runtime if d['udid'] != sys.argv[3]]
    pending = devices.with_name('devices.pending'); pending.write_text(json.dumps(data)); os.replace(pending, devices)
if op == 'list':
    sys.stdout.write(devices.read_text()); sys.exit(0)
if op == 'terminate': sys.exit(0)
if op == 'shutdown':
    if mode == 'hang': hang(False)
    sys.exit(0)
if op == 'delete':
    if mode == 'stuck': hang(True)
    delete()
    if mode == 'hang': hang(True)
    if mode == 'zombie':
        if os.fork() == 0: os._exit(0)   # never waited for: a defunct simctl child in the group
        hang(True)
    if mode in ('defunct-leader', 'ps-overrun-after-reap'): (state / 'delete-exited').touch()
    sys.exit(0)
sys.exit(64)
'''

STUB_CONTROLLER = '''#!{python}
"""Stub composer controller: the real fixture class, deadline and final routing."""
import importlib.util, json, os, sys, time
from pathlib import Path
REPO = Path(os.environ['STUB_REPO']); sys.path.insert(0, str(REPO / 'scripts'))
spec = importlib.util.spec_from_file_location('composer', REPO / 'scripts/probe-mixtape-composer-flow.py')
composer = importlib.util.module_from_spec(spec); spec.loader.exec_module(composer)
import mixtape_owned_supervision as supervision
root = Path(sys.argv[sys.argv.index('--output') + 1])
mode = os.environ['STUB_SIMCTL_MODE']; state = Path(os.environ['STUB_SIMCTL_STATE'])
os.umask(0o077); root.mkdir(mode=0o700)
composer.OwnedFixture.SIMCTL_TEARDOWN_CAPS = json.loads(os.environ['STUB_TEARDOWN_CAPS'])
env = {{'PATH': os.environ['STUB_BIN'] + ':/usr/bin:/bin', 'STUB_SIMCTL_MODE': mode, 'STUB_SIMCTL_STATE': str(state)}}
deadline = composer.Deadline(total=float(os.environ['STUB_TOTAL']), reserve=float(os.environ['STUB_RESERVE']))
owned = composer.OwnedFixture(root, env, deadline); deadline.arm()
if mode == 'defunct-leader':
    real, fired = supervision.group_present, []
    def overrunning_inspection(group, limit):
        if not fired and (state / 'delete-exited').exists():
            fired.append(True); raise TimeoutError('synthetic ps overrun under load')
        return real(group, limit)
    supervision.group_present = overrunning_inspection
if mode == 'ps-overrun-after-reap':
    real, seen = supervision.group_present, []
    def overrun_after_reap(group, limit):
        if (state / 'delete-exited').exists():
            seen.append(group)
            # wait_owned inspects once before the reap and then reads back after it.
            if len(seen) == 2: raise TimeoutError('synthetic ps overrun after the reap')
        return real(group, limit)
    supervision.group_present = overrun_after_reap
owned.simulator_name = {name!r}; owned.simulator = {udid!r}; owned.receipt()
source = (REPO / 'scripts/probe-mixtape-composer-flow.py').read_text()
tail = source.rsplit('    finally:\\n', 1)[1].split('\\nif __name__', 1)[0]
scope = dict(observer=None, owned=owned, root=root, deadline=deadline, result=0, current='0' * 40,
             best_effort=composer.best_effort, write_receipt=composer.write_receipt,
             cleanup_qualified=composer.cleanup_qualified, retain_custody=composer.retain_custody)
exec('def controller_tail():\\n    try:\\n        pass\\n    finally:\\n' + tail, scope)
sys.exit(scope['controller_tail']())
'''


def wrapper_text():
    text = WRAPPER.read_text()
    unset = ('unset BATON_GATE_LOCK BATON_GATE_LOCK_TEST_BARRIER BATON_ALLOW_CONCURRENT_GATE BATON_PROBE_LOCK '
             'BATON_PROBE_LOCK_TIMEOUT BATON_PROBE_LOCK_GRACE BATON_PROBE_LOCK_TEST_RECLAIM_DELAY\n')
    script_dir = 'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"\n'
    controller = '"$SCRIPT_DIR/probe-mixtape-composer-flow.py"'
    assert text.count(unset) == 1 and text.count(script_dir) == 1 and text.count(controller) == 2, 'wrapper shape changed'
    return (text.replace(unset, '').replace(script_dir, 'SCRIPT_DIR=' + str(REPO / 'scripts') + '\n')
            .replace(controller, '"$STUB_CONTROLLER"'))


class SimctlCleanupBoundTests(unittest.TestCase):
    def run_case(self, mode):
        tmp = Path(tempfile.mkdtemp(prefix='baton-simctl-bound-', dir='/private/tmp')); tmp.chmod(0o700)
        for name in ['bin', 'state', 'locks']: (tmp / name).mkdir(mode=0o700)
        xcrun = tmp / 'bin/xcrun'; xcrun.write_text(STUB_XCRUN.format(python=sys.executable)); xcrun.chmod(0o700)
        controller = tmp / 'controller.py'
        controller.write_text(STUB_CONTROLLER.format(python=sys.executable, name=NAME, udid=UDID))
        (tmp / 'state/devices.json').write_text(json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-27-0':
            [{'name': NAME, 'udid': UDID, 'state': 'Booted'}]}}))
        wrapper = tmp / 'wrapper.sh'; wrapper.write_text(wrapper_text())
        gate, probe = tmp / 'locks/baton-gate.lock', tmp / 'locks/baton-probe.lock'
        env = {k: v for k, v in os.environ.items() if not k.startswith(('BATON_', 'NATIVE_LOCK'))}
        env.update(BATON_GATE_LOCK=str(gate), BATON_PROBE_LOCK=str(probe), BATON_GATE_LOCK_WAIT='0',
                   STUB_REPO=str(REPO), STUB_BIN=str(tmp / 'bin'), STUB_CONTROLLER=str(controller),
                   STUB_SIMCTL_MODE=mode, STUB_SIMCTL_STATE=str(tmp / 'state'),
                   STUB_TEARDOWN_CAPS=json.dumps(CAPS), STUB_TOTAL=str(TOTAL), STUB_RESERVE=str(RESERVE))
        out = tmp / 'run'
        log = (tmp / 'wrapper.log').open('wb')
        started = time.monotonic()
        process = subprocess.Popen(['/bin/bash', str(wrapper), '--run', '--output', str(out)], env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = process.wait(timeout=RESERVE + SLACK)
        except subprocess.TimeoutExpired:
            rc = None
        elapsed = time.monotonic() - started
        result = dict(tmp=tmp, out=out, rc=rc, elapsed=elapsed, env=env, gate=gate, probe=probe,
                      probe_held=probe.exists(), gate_free=self.gate_free(env))
        if rc is None:
            # Our own unreaped child leads this session, so its group is still ours to end.
            os.killpg(process.pid, signal.SIGKILL); process.wait()
        log.close()
        result['log'] = (tmp / 'wrapper.log').read_text(errors='replace')
        result['calls'] = (tmp / 'state/calls.log').read_text().split() if (tmp / 'state/calls.log').exists() else []
        result['devices'] = (tmp / 'state/devices.json').read_text()
        def receipt(name):
            path = out / name
            return json.loads(path.read_text()) if path.exists() else None
        for name in ['native-lock-release.json', 'native-custody-release.json', 'incoming-cleanup.json', 'custody-hold.json']:
            result[name] = receipt(name)
        print('\n[%s] rc=%s elapsed=%.1fs probeHeld=%s gateFree=%s calls=%s' % (
            mode, rc, elapsed, result['probe_held'], result['gate_free'], ' '.join(result['calls'])), flush=True)
        print('[%s] incoming-cleanup: %s' % (mode, json.dumps(result['incoming-cleanup.json'])), flush=True)
        print('[%s] native-lock-release: %s' % (mode, json.dumps(result['native-lock-release.json'])), flush=True)
        self.addCleanup(shutil.rmtree, tmp, True)
        return result

    def gate_free(self, env):
        probe = ('. "%s/scripts/gate-lock.sh"; gate_lock_acquire bound-check /dev/null >/dev/null 2>&1 && gate_lock_release'
                 % REPO)
        return subprocess.run(['/bin/bash', '-c', probe], env=env, capture_output=True, timeout=20).returncode == 0

    def assert_released(self, result, timed_out):
        self.assertIsNotNone(result['rc'], 'wrapper still holding the locks after %ss:\n%s' % (RESERVE + SLACK, result['log'][-1500:]))
        self.assertEqual(result['rc'], 0, result['log'][-1500:])
        self.assertLessEqual(result['elapsed'], RESERVE + SLACK)
        self.assertFalse(result['probe_held'], 'probe lock still held')
        self.assertTrue(result['gate_free'], 'gate (mac-app-host) lock still held')
        self.assertNotIn(UDID, result['devices'])
        cleanup = result['incoming-cleanup.json']
        self.assertEqual(cleanup['failures'], []); self.assertIs(cleanup['simulatorAbsent'], True)
        self.assertIs(cleanup['registeredGroupsAbsent'], True)
        steps = {step['operation']: step for step in cleanup['simulatorTeardown']}
        for operation in timed_out:
            self.assertIs(steps[operation]['timedOut'], True, operation)
            self.assertIs(steps[operation]['childReaped'], True, operation)
            self.assertIs(steps[operation]['groupAbsent'], True, operation)
        self.assertIs(cleanup['simulatorAbsenceConfirmed'], True)
        self.assertIs(result['native-custody-release.json']['qualified'], True)
        release = result['native-lock-release.json']
        self.assertIs(release['qualified'], True)
        self.assertEqual((release['gateLock'], release['probeLock']), (str(result['gate']), str(result['probe'])))
        self.assertIs(release['gateLockReleased'], True); self.assertIs(release['probeLockReleased'], True)
        self.assertIsNone(result['custody-hold.json'])

    def test_hung_shutdown_and_delete_release_locks_once_simulator_gone(self):
        self.assert_released(self.run_case('hang'), ['shutdown', 'delete'])

    def test_defunct_child_under_hung_delete_releases_locks_once_simulator_gone(self):
        self.assert_released(self.run_case('zombie'), ['delete'])

    def test_exited_leader_left_unreaped_by_overrunning_inspection_is_reaped(self):
        self.assert_released(self.run_case('defunct-leader'), ['delete'])

    def test_inspection_overrun_after_reap_is_closed_by_a_read_only_recheck(self):
        result = self.run_case('ps-overrun-after-reap')
        self.assert_released(result, ['delete'])
        steps = {step['operation']: step for step in result['incoming-cleanup.json']['simulatorTeardown']}
        self.assertIs(steps['delete']['readback'], True)

    def test_simulator_still_present_keeps_custody_and_both_locks(self):
        result = self.run_case('stuck')
        self.assertIsNone(result['rc'], 'an unconfirmed simulator must not release the locks')
        self.assertTrue(result['probe_held']); self.assertFalse(result['gate_free'])
        self.assertIn(UDID, result['devices'])
        self.assertIs(result['custody-hold.json']['qualified'], False)
        self.assertIsNot(result['incoming-cleanup.json']['simulatorAbsent'], True)
        self.assertIsNone(result['native-lock-release.json'])
        self.assertEqual(result['calls'].count('delete'), 2, 'one bounded delete retry before custody is kept')


if __name__ == '__main__':
    unittest.main(verbosity=2)
