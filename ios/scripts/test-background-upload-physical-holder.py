"""One dummy-lock behavioral regression; no native/device/ordinary guard execution."""
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).with_name('hold-background-upload-physical-window.sh')

class HolderTest(unittest.TestCase):
    def test_expiry_interruption_and_unqualified_release_keep_custody(self):
        with tempfile.TemporaryDirectory(prefix='baton-holder-dummy-') as directory:
            root = Path(directory).resolve()
            script = root / 'ios/scripts/holder.sh'
            script.parent.mkdir(parents=True)
            (root / 'scripts').mkdir()
            window = root / 'window'
            window.mkdir(mode=0o700)
            # Only the private test copy shortens clocks. Production has no override.
            text = SOURCE.read_text().replace('acceptance_seconds=900', 'acceptance_seconds=1')
            text = text.replace('planning_seconds=1200', 'planning_seconds=2')
            text = text.replace('sleep 1', 'sleep 0.02')
            script.write_text(text)
            script.chmod(0o700)
            (root / 'scripts/gate-lock.sh').write_text('''
GATE_LOCK="$window/gate-record"
GATE_LOCK_HELD=1
gate_lock_acquire(){ printf '%s\n' "$$" > "$GATE_LOCK"; printf held > "$window/gate-dummy"; }
gate_lock_release(){ : > "$GATE_LOCK"; GATE_LOCK_HELD=""; printf released > "$window/gate-dummy"; }
''')
            (root / 'scripts/probe-lib.sh').write_text('''
PROBE_LOCK="$window/probe-record"
PROBE_LOCK_HELD=1
probe_lock_acquire(){ mkdir "$PROBE_LOCK"; printf '%s\n' "$$" > "$PROBE_LOCK/owner"; printf held > "$window/probe-dummy"; }
probe_lock_release(){ rm "$PROBE_LOCK/owner"; rmdir "$PROBE_LOCK"; PROBE_LOCK_HELD=0; printf released > "$window/probe-dummy"; }
''')
            marker = window / 'restore-complete'
            def wait_file(path):
                end = time.monotonic() + 5
                while not path.exists() and time.monotonic() < end:
                    time.sleep(.02)
                self.assertTrue(path.exists(), str(path.name))
            with (root / 'private.log').open('wb') as log:
                child = subprocess.Popen([str(script), '--coordinated-go', 'TBX-8680', str(window)],
                    stdout=log, stderr=log)
                try:
                    wait_file(window / 'acquired.json')
                    pid = json.loads((window / 'acquired.json').read_text())['holderPID']
                    self.assertEqual(pid, child.pid)
                    wait_file(window / 'acceptance-stopped.json')
                    wait_file(window / 'expired.json')
                    child.send_signal(signal.SIGTERM)  # Exact original direct test child.
                    time.sleep(.1)
                    self.assertIsNone(child.poll())
                    for name in ('gate-dummy', 'probe-dummy'):
                        self.assertEqual((window / name).read_text(), 'held')
                    # Mere existence, foreign PID and broad readability cannot release.
                    marker.write_text('restored-and-owned-cleanup-verified:0\n')
                    marker.chmod(0o600)
                    time.sleep(.1)
                    self.assertIsNone(child.poll())
                    marker.write_text(f'restored-and-owned-cleanup-verified:{pid}\n')
                    marker.chmod(0o644)
                    time.sleep(.1)
                    self.assertIsNone(child.poll())
                    for name in ('gate-dummy', 'probe-dummy'):
                        self.assertEqual((window / name).read_text(), 'held')
                    marker.chmod(0o600)
                    self.assertEqual(child.wait(timeout=5), 0)
                    for name in ('gate-dummy', 'probe-dummy'):
                        self.assertEqual((window / name).read_text(), 'released')
                    self.assertTrue(json.loads((window / 'released.json').read_text())['ownedCleanupConfirmed'])
                finally:
                    # No unqualified kill/recovery: unblock only this dummy holder by
                    # its own accepted confirmation, then reap our original child.
                    if child.poll() is None:
                        marker.write_text(f'restored-and-owned-cleanup-verified:{child.pid}\n')
                        marker.chmod(0o600)
                        child.wait(timeout=5)

if __name__ == '__main__':
    unittest.main()
