#!/usr/bin/env python3
"""One private localhost fixture, with an outer 180s deadline INCLUDING cleanup.

No media is launched with --prepare. Actual execution requires --run-authorized
and coordination with the native audio owner. Never accepts inherited service or
credential environment. Timeout failures and cleanup uncertainty are preserved.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


class FixtureRunner:
    def __init__(self, evidence, budget=180):
        self.evidence = Path(evidence)
        self.evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.nonce = uuid.uuid4().hex
        self.container = 'baton-share-startup-' + self.nonce
        self.workspace = Path(tempfile.mkdtemp(prefix='share-startup-' + self.nonce + '-'))
        self.budget = budget
        self.groups = set()
        self.receipt = {'deadlineSeconds': budget, 'container': self.container, 'network': self.container,
                        'syntheticOnly': True, 'cleanup': {}, 'exitCode': None}

    def save(self):
        path = self.evidence / 'run-status.json'
        path.write_text(json.dumps(self.receipt, indent=2))
        path.chmod(0o600)

    def kill_owned_groups(self):
        for group in tuple(self.groups):
            self.kill_group(group)

    def hard_deadline(self, *_):
        # No blocking inspection/cleanup in the final deadline signal handler.
        for group in tuple(self.groups):
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.receipt.update(exitCode=124, hardDeadline=True,
                            elapsedSeconds=round(time.monotonic() - self.started, 3))
        self.receipt['cleanup']['verified'] = False
        self.receipt['cleanup']['limitation'] = 'Hard deadline: container/filesystem cleanup may be incomplete; exact owned paths retained.'
        self.receipt['cleanup']['workspace'] = str(self.workspace)
        self.save()
        os._exit(124)

    def command(self, argv, env, timeout, output=None, fixture=False):
        child = subprocess.Popen(argv, env=env, start_new_session=True,
                                 stdout=output or subprocess.PIPE, stderr=subprocess.STDOUT)
        self.groups.add(child.pid)
        if fixture:
            self.receipt['fixtureGroup'] = child.pid
        try:
            data, _ = child.communicate(timeout=timeout)
            return child.returncode, (data or b'').decode(errors='replace')
        except subprocess.TimeoutExpired:
            # TERM gives the child's normal finally a short chance; its potentially
            # stuck CDP loop cannot delay this independent supervisor indefinitely.
            try:
                self.kill_detached_descendants(child.pid)
            except (subprocess.TimeoutExpired, OSError) as error:
                self.receipt['cleanup']['descendantInspectionUnavailable'] = True
                self.receipt['cleanup']['descendantInspectionErrorCategory'] = type(error).__name__
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.communicate(timeout=min(2, self.budget/20, max(.01, self.deadline-time.monotonic())))
            except subprocess.TimeoutExpired:
                self.kill_group(child.pid)
                child.communicate(timeout=min(1, max(.01, self.deadline-time.monotonic())))
            return 124, ''
        finally:
            # Child/browser descendants share only this explicitly created session.
            if child.poll() is None:
                self.kill_group(child.pid)
                try:
                    child.wait(timeout=min(1,max(.01,self.deadline-time.monotonic())))
                except subprocess.TimeoutExpired:
                    self.receipt['cleanup'].setdefault('unreapedOwnedChildPIDs',[]).append(child.pid)
            if child.poll() is not None:
                self.groups.discard(child.pid)

    def kill_detached_descendants(self, root_pid):
        # Playwright starts the browser in another process group. Read process
        # metadata only (no owner command arguments), then follow ancestry from
        # our still-live child. Never select by a generic browser/process name.
        result = subprocess.run(['ps', '-axo', 'pid=,ppid=,pgid=,uid=,stat='],
                                capture_output=True, text=True, timeout=.5)
        if result.returncode != 0:
            raise OSError('Process ancestry metadata unavailable')
        rows = [(int(pid),int(parent),int(group),int(uid),state) for pid,parent,group,uid,state in (line.split() for line in result.stdout.splitlines() if line.strip())]
        owned = {root_pid}
        while True:
            found = {pid for pid, parent, group, uid, state in rows if parent in owned and uid == os.getuid()}
            if found <= owned:
                break
            owned.update(found)
        groups = {group for pid, parent, group, uid, state in rows if pid in owned and uid == os.getuid() and group != root_pid and not state.startswith("Z")}
        self.receipt.setdefault('ownedDetachedGroupsSignalled', []).extend(sorted(groups))
        for group in groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def kill_group(self, pid):
        try:
            self.kill_detached_descendants(pid)
        except (subprocess.TimeoutExpired, OSError) as error:
            self.receipt['cleanup']['descendantInspectionUnavailable'] = True
            self.receipt['cleanup']['descendantInspectionErrorCategory'] = type(error).__name__
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def verify_process_absence(self, fixture_rc):
        # An abnormal exit can happen before handoff, leaving unknown detached
        # children already reparented. Absence of current descendants is no proof.
        self.receipt['cleanup']['processRegistryPath'] = str(self.evidence/'startup-process-registry.json')
        self.receipt['cleanup']['registrationAvailable'] = (self.evidence/'startup-process-registry.json').is_file()
        if fixture_rc != 0:
            self.receipt['cleanup']['processUncertainty'] = 'Abnormal fixture exit; detached ownership handoff may be incomplete'
            return False
        path = self.evidence/'startup-process-registry.json'
        try:
            registry = json.loads(path.read_text())
            group = registry['browserGroup']
            entries = registry['entries']
            valid = registry['runID'] == self.nonce and registry['uid'] == os.getuid()
            valid = valid and isinstance(group, int) and group > 0 and isinstance(entries, list)
            valid = valid and any(entry['pid'] == group and entry['group'] == group and entry['uid'] == os.getuid()
                and entry['started'] and entry['executable'] == registry['expectedExecutable'] for entry in entries)
            if not valid:
                raise ValueError('registry identity mismatch')
            self.receipt['cleanup']['registeredBrowserGroup'] = group
            self.receipt['cleanup']['browserIdentityRecorded'] = True
            groups = {group, self.receipt['fixtureGroup']}
            until = min(self.deadline-.1,time.monotonic()+2)
            while True:
                result = subprocess.run(['ps','-axo','pid=,pgid=,stat='],capture_output=True,text=True,timeout=.5)
                if result.returncode != 0:
                    raise OSError('process absence inspection unavailable')
                rows = [line.split() for line in result.stdout.splitlines() if line.strip()]
                live = [{'pid':int(pid),'group':int(pgid)} for pid,pgid,state in rows
                        if int(pgid) in groups and not state.startswith('Z')]
                if not live:
                    self.receipt['cleanup']['ownedProcessAbsenceVerified'] = True
                    return True
                if time.monotonic() >= until:
                    self.receipt['cleanup']['remainingRegisteredGroupProcesses'] = live
                    self.receipt['cleanup']['processUncertainty'] = 'Registered group still has live members; no reparented process killed by name/PID alone'
                    return False
                time.sleep(.05)
        except (OSError,ValueError,KeyError,TypeError,subprocess.TimeoutExpired) as error:
            self.receipt['cleanup']['processUncertainty'] = type(error).__name__
            return False

    def run(self, command, env, docker='docker'):
        self.started = time.monotonic()
        self.deadline = self.started + self.budget
        previous = signal.signal(signal.SIGALRM, self.hard_deadline)
        def interrupted(signum, _):
            raise InterruptedError(signum)
        previous_term = signal.signal(signal.SIGTERM, interrupted)
        signal.setitimer(signal.ITIMER_REAL, self.budget)
        self.receipt['workspace'] = str(self.workspace)
        self.receipt['command'] = command
        self.save()
        rc = 1
        try:
            reserve = min(20, self.budget/4)
            with (self.evidence / 'run.log').open('wb') as log:
                rc, _ = self.command(command, env, self.budget-reserve, log, fixture=True)
            self.receipt['fixtureExitCode'] = rc
        except InterruptedError as error:
            rc = 128 + int(error.args[0])
            self.receipt['failureCategory'] = 'interrupted'
        except KeyboardInterrupt:
            rc = 130
            self.receipt['failureCategory'] = 'interrupted'
        except Exception as error:
            rc = 1
            self.receipt['failureCategory'] = type(error).__name__
        finally:
            try:
                remaining = lambda limit: max(.01, min(limit, self.deadline-time.monotonic()))
                remove_rc, remove_output = self.command([docker, 'container', 'rm', '-f', self.container], env, remaining(8))
                inspect_rc, inspect_output = self.command([docker, 'container', 'inspect', self.container], env, remaining(4))
                absent = inspect_rc == 1 and bool(re.search(r'no such (container|object)', inspect_output, re.I))
                self.receipt['cleanup'].update(containerRemoveExitCode=remove_rc,
                    containerAbsent=absent, containerInspectExitCode=inspect_rc)
                if not absent:
                    rc = rc or 1
                network_remove_rc, _ = self.command([docker, 'network', 'rm', self.container], env, remaining(3))
                network_inspect_rc, network_output = self.command([docker, 'network', 'inspect', self.container], env, remaining(2))
                network_absent = network_inspect_rc == 1 and bool(re.search(r'no such network|network[^\n]*not found',network_output,re.I))
                self.receipt['cleanup'].update(networkRemoveExitCode=network_remove_rc,
                    networkAbsent=network_absent,networkInspectExitCode=network_inspect_rc)
                if not network_absent:
                    rc = rc or 1
            except Exception as error:
                self.receipt['cleanup']['errorCategory'] = type(error).__name__
                rc = rc or 1
            self.kill_owned_groups()
            process_absent = self.verify_process_absence(self.receipt.get('fixtureExitCode'))
            self.receipt['cleanup']['ownedProcessAbsenceVerified'] = process_absent
            resources_absent = process_absent and self.receipt['cleanup'].get('containerAbsent',False) and self.receipt['cleanup'].get('networkAbsent',False)
            try:
                if not resources_absent or self.receipt['cleanup'].get('descendantInspectionUnavailable', False):
                    rc = rc or 1
                    self.receipt['cleanup']['workspaceRetainedReason'] = 'Process/container/network cleanup unverified; retain exact owned namespace for recovery'
                else:
                    shutil.rmtree(self.workspace)
            except Exception as error:
                self.receipt['cleanup']['workspaceErrorCategory'] = type(error).__name__
                rc = rc or 1
            self.receipt['cleanup']['workspaceRemoved'] = not self.workspace.exists()
            self.receipt['cleanup']['verified'] = resources_absent and not self.workspace.exists() and not self.receipt['cleanup'].get('descendantInspectionUnavailable', False)
            self.receipt.update(exitCode=rc, elapsedSeconds=round(time.monotonic()-self.started, 3))
            self.save()
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
            signal.signal(signal.SIGTERM, previous_term)
        return rc


def clean_environment(workspace, nonce, playwright, browsers):
    user = pwd.getpwuid(os.getuid()).pw_name
    home = workspace / 'home'
    home.mkdir(mode=0o700)
    return {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME': str(home), 'USER': user, 'LOGNAME': user, 'TMPDIR': str(workspace),
            'LANG': 'en_US.UTF-8', 'DOCKER_HOST': 'unix:///var/run/docker.sock',
            'DOCKER_CONFIG': str(home / '.docker'), 'BATON_SHARE_BIND': '127.0.0.1',
            'SHARE_E2E_PLAYWRIGHT': str(playwright), 'PLAYWRIGHT_BROWSERS_PATH': str(browsers),
            'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD': '1', 'SHARE_E2E_RUN_ID': nonce}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--profile', choices=['local', 'shaped', 'flow'], required=True)
    parser.add_argument('--browser', choices=['chromium','firefox','webkit'], default='chromium')
    parser.add_argument('--browser-executable', type=Path)
    parser.add_argument('--playwright', required=True, type=Path)
    parser.add_argument('--browsers', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare', action='store_true')
    mode.add_argument('--run-authorized', action='store_true')
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    node = shutil.which('node')
    if not node:
        raise SystemExit('Node runtime unavailable')
    if args.profile != 'flow' and (args.browser != 'chromium' or args.browser_executable):
        raise SystemExit('Startup profiles use the reviewed full Chromium runtime only')
    command = [node, str(here/'e2e.mjs'), '--nginx-docker', '--browser='+args.browser]
    if args.browser == 'chromium':
        command.append('--chromium-channel=chromium')
    if args.profile != 'flow':
        command.extend(['--startup-only','--song-seconds=400'])
    if args.profile == 'shaped':
        command.extend(['--download-mbps=10', '--latency-ms=80'])
    command.extend([str(args.binary.resolve()), str(args.evidence.resolve())])
    if args.prepare:
        print(json.dumps({'command': command, 'outerDeadlineSeconds': 180,
            'runBudgetSeconds': 160, 'cleanupReserveSeconds': 20,
            'fixtureCount': 5 if args.profile == 'flow' else 1,
            'syntheticAudioApproxBytes': 4800000 if args.profile == 'flow' else 9600000,
            'browserLaunched': False, 'productionTraffic': False}, indent=2))
        return 0
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        raise SystemExit('Rebuilt share binary unavailable')
    inspection = subprocess.run(['ps', '-axo', 'pid=,ppid=,pgid=,uid=,stat='],
                                capture_output=True, timeout=2)
    if inspection.returncode != 0:
        raise SystemExit('Process ancestry inspection unavailable; no browser launched')
    runner = FixtureRunner(args.evidence)
    repo = here.parents[2]
    runner.receipt.update(sourceCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
        profile=args.profile, engine=args.browser, binarySHA256=hashlib.sha256(args.binary.read_bytes()).hexdigest())
    env = clean_environment(runner.workspace, runner.nonce, args.playwright.resolve(), args.browsers.resolve())
    if args.browser_executable:
        if not args.browser_executable.is_file() or not os.access(args.browser_executable, os.X_OK):
            raise SystemExit('Selected cached browser executable unavailable')
        env['SHARE_E2E_BROWSER_PATH'] = str(args.browser_executable.resolve())
        runner.receipt['browserExecutable'] = str(args.browser_executable.resolve())
    return runner.run(command, env)


if __name__ == '__main__':
    raise SystemExit(main())
