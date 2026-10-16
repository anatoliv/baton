"""Retain CPU test ownership evidence; never discard unqualified child custody."""
from contextlib import contextmanager
from pathlib import Path
import tempfile
from incoming_fixture_lifecycle import write_receipt
from mixtape_owned_lifecycle import CustodyDeadline as Deadline, ReservedOwnedFixture, cleanup_qualified, best_effort, retain_custody


def finish_cpu_fixture(owned):
    qualified=False
    try:
        cleanup=owned.cleanup()
        qualified=cleanup_qualified(cleanup)
    except BaseException:
        best_effort(write_receipt,owned.root/'cpu-cleanup-failure.json',{'qualified':False,'privateDetailsWithheld':True})
    if not qualified: retain_custody(owned.root,owned.deadline)
    owned.deadline.disarm()


@contextmanager
def retained_cpu_fixture(prefix):
    # Leave all successes and failures available for independent readback.
    root=Path(tempfile.mkdtemp(prefix=prefix,dir='/private/tmp')); root.chmod(0o700)
    owned=ReservedOwnedFixture(root,{'PATH':'/usr/bin:/bin'},Deadline())
    try: yield root,owned
    finally: finish_cpu_fixture(owned)
